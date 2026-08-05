#include "convex.h"
#include <arpa/inet.h>
#include <curl/curl.h>
#include <json-c/json.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct {
  FILE *stream;
  pthread_mutex_t mutex;
} adapter_output;

typedef struct adapter_subscription {
  char *id;
  convex_subscription *subscription;
  pthread_t thread;
  adapter_output *output;
  pthread_mutex_t state_mutex;
  unsigned long generation;
  int active;
#ifdef CONVEX_ADAPTER_TESTING
  int test_pause_used;
#endif
  struct adapter_subscription *next;
} adapter_subscription;

#ifdef CONVEX_ADAPTER_TESTING
static int test_fd(const char *name) { const char *value=getenv(name);return value&&*value?atoi(value):-1; }
static void test_signal(const char *name) { int fd=test_fd(name);char byte='x';if(fd>=0)(void)write(fd,&byte,1); }
static void test_pause_relay(adapter_subscription *record) {
  if(record->test_pause_used)return;
  record->test_pause_used=1;
  test_signal("ADAPTER_TEST_RELAY_DEQUEUED_FD");
  int fd=test_fd("ADAPTER_TEST_RELAY_RESUME_FD");char byte;if(fd>=0)(void)read(fd,&byte,1);
}
#endif

static char *copy_string(const char *value) {
  size_t length = strlen(value) + 1;
  char *copy = malloc(length);
  if (copy) memcpy(copy, value, length);
  return copy;
}

static void emit(adapter_output *output, json_object *event) {
  pthread_mutex_lock(&output->mutex);
  fputs(json_object_to_json_string_ext(event, JSON_C_TO_STRING_PLAIN), output->stream);
  fputc('\n', output->stream);
  fflush(output->stream);
  pthread_mutex_unlock(&output->mutex);
  json_object_put(event);
}

static json_object *error_object(convex_error *error) {
  json_object *object = json_object_new_object();
  json_object_object_add(object, "name", json_object_new_string(error->name ? error->name : "Error"));
  json_object_object_add(object, "message", json_object_new_string(error->message ? error->message : "unknown error"));
  if (error->data) json_object_object_add(object, "data", json_object_get(error->data));
  return object;
}

static void emit_error(adapter_output *output, const char *id,
                       const char *subscription_id, convex_error *error) {
  json_object *event = json_object_new_object();
  if (subscription_id && *subscription_id) {
    json_object_object_add(event, "type", json_object_new_string("subscription"));
    json_object_object_add(event, "subscriptionId", json_object_new_string(subscription_id));
  } else {
    json_object_object_add(event, "type", json_object_new_string("error"));
    if (id && *id) json_object_object_add(event, "id", json_object_new_string(id));
  }
  json_object_object_add(event, "error", error_object(error));
  if (error->logs) json_object_object_add(event, "logs", json_object_get(error->logs));
  emit(output, event);
}

static void simple_event(adapter_output *output, const char *id, const char *type) {
  json_object *event = json_object_new_object();
  json_object_object_add(event, "id", json_object_new_string(id));
  json_object_object_add(event, "type", json_object_new_string(type));
  emit(output, event);
}

static void *forward_updates(void *opaque) {
  adapter_subscription *record = opaque;
  pthread_mutex_lock(&record->state_mutex);
  unsigned long generation=record->generation;
  pthread_mutex_unlock(&record->state_mutex);
  convex_update update = {0};
  while (convex_subscription_next(record->subscription, &update, -1) == 1) {
#ifdef CONVEX_ADAPTER_TESTING
    test_pause_relay(record);
#endif
    /* Invalidation and publication share this lock. Once unsubscribe or a
     * same-ID replacement advances generation, a dequeued old value cannot
     * cross the relay boundary. */
    pthread_mutex_lock(&record->state_mutex);
    int publish=record->active&&record->generation==generation;
    if (!publish) { pthread_mutex_unlock(&record->state_mutex);convex_update_free(&update);continue; }
    if (update.error.name) {
      emit_error(record->output, "", record->id, &update.error);
    } else {
      json_object *event = json_object_new_object();
      json_object_object_add(event, "type", json_object_new_string("subscription"));
      json_object_object_add(event, "subscriptionId", json_object_new_string(record->id));
      json_object_object_add(event, "value", update.value); update.value = NULL;
      if (update.logs) { json_object_object_add(event, "logs", update.logs); update.logs = NULL; }
      emit(record->output, event);
    }
    pthread_mutex_unlock(&record->state_mutex);
    convex_update_free(&update);
  }
  return NULL;
}

static adapter_subscription **find_record(adapter_subscription **head, const char *id) {
  while (*head && strcmp((*head)->id, id)) head = &(*head)->next;
  return head;
}

static int stop_record(adapter_subscription **slot, convex_error *error) {
  adapter_subscription *record = *slot;
  if (!record) return 1;
  pthread_mutex_lock(&record->state_mutex);
  record->active=0;
  record->generation++;
  pthread_mutex_unlock(&record->state_mutex);
#ifdef CONVEX_ADAPTER_TESTING
  test_signal("ADAPTER_TEST_RELAY_INACTIVE_FD");
#endif
  if (!convex_unsubscribe(record->subscription, error)) return 0;
  pthread_join(record->thread, NULL);
  *slot = record->next;
  pthread_mutex_destroy(&record->state_mutex);
  free(record->id);
  free(record);
  return 1;
}

static convex_client *ensure_client(convex_client **client, convex_error *error) {
  if (*client) return *client;
  const char *url = getenv("CONVEX_URL");
  if (!url || !*url) { error->name=copy_string("ProtocolError");error->message=copy_string("CONVEX_URL is required");return NULL; }
  *client = convex_new(url, "c-0.1.0", error);
  if (*client && getenv("CONVEX_AUTH_TOKEN")) convex_set_auth(*client, getenv("CONVEX_AUTH_TOKEN"), error);
  return *client;
}

static void serve(FILE *input, FILE *stream) {
  adapter_output output = {.stream = stream};
  pthread_mutex_init(&output.mutex, NULL);
  convex_client *client = NULL;
  adapter_subscription *subscriptions = NULL;
  char *line = malloc(2097153);
  while (line && fgets(line, 2097153, input)) {
    enum json_tokener_error parse_error = json_tokener_success;
    json_object *command = json_tokener_parse_verbose(line, &parse_error);
    if (!command || json_object_get_type(command) != json_type_object) {
      convex_error error = {.name=copy_string("ProtocolError"),.message=copy_string("malformed adapter command")};
      emit_error(&output, "", "", &error); convex_error_free(&error);
      if (command) json_object_put(command);
      continue;
    }
    json_object *field = NULL;
    const char *id = json_object_object_get_ex(command,"id",&field) ? json_object_get_string(field) : "";
    const char *op = json_object_object_get_ex(command,"op",&field) ? json_object_get_string(field) : "";
    if (!strcmp(op, "hello")) {
      json_object *version=NULL;
      if (!json_object_object_get_ex(command,"protocolVersion",&version) || json_object_get_int(version)!=1) {
        convex_error error={.name=copy_string("ProtocolError"),.message=copy_string("unsupported adapter protocol version")};emit_error(&output,id,"",&error);convex_error_free(&error);
      } else {
        json_object *event=json_object_new_object();json_object_object_add(event,"protocolVersion",json_object_new_int(1));json_object_object_add(event,"id",json_object_new_string(id));json_object_object_add(event,"type",json_object_new_string("ready"));json_object_object_add(event,"language",json_object_new_string("c"));json_object_object_add(event,"implementation",json_object_new_string("native-c17-libcurl-websocket-json-c"));json_object_object_add(event,"runtime",json_object_new_string("C17 musl"));emit(&output,event);
      }
    } else if (!strcmp(op,"query") || !strcmp(op,"mutation") || !strcmp(op,"action")) {
      json_object *path=NULL,*args=NULL;json_object_object_get_ex(command,"path",&path);json_object_object_get_ex(command,"args",&args);convex_error error={0};convex_result result={0};convex_client *active=ensure_client(&client,&error);
      if(active&&convex_call(active,op,path?json_object_get_string(path):"",args,&result,&error)){json_object *event=json_object_new_object();json_object_object_add(event,"id",json_object_new_string(id));json_object_object_add(event,"type",json_object_new_string("result"));json_object_object_add(event,"value",result.value);result.value=NULL;if(result.logs){json_object_object_add(event,"logs",result.logs);result.logs=NULL;}emit(&output,event);}else emit_error(&output,id,"",&error);convex_result_free(&result);convex_error_free(&error);
    } else if (!strcmp(op,"setAuth")) {
      json_object *token=NULL;json_object_object_get_ex(command,"token",&token);convex_error error={0};convex_client *active=ensure_client(&client,&error);if(active&&convex_set_auth(active,token?json_object_get_string(token):"",&error))simple_event(&output,id,"ack");else emit_error(&output,id,"",&error);convex_error_free(&error);
    } else if (!strcmp(op,"subscribe")) {
      json_object *sid=NULL,*path=NULL,*args=NULL;json_object_object_get_ex(command,"subscriptionId",&sid);json_object_object_get_ex(command,"path",&path);json_object_object_get_ex(command,"args",&args);const char *subscription_id=sid?json_object_get_string(sid):"";convex_error error={0};convex_client *active=ensure_client(&client,&error);adapter_subscription **old=find_record(&subscriptions,subscription_id);
      if(*old&&!stop_record(old,&error)){emit_error(&output,id,"",&error);convex_error_free(&error);json_object_put(command);continue;}
      convex_subscription *subscription=active?convex_subscribe(active,path?json_object_get_string(path):"",args,&error):NULL;
      if(subscription){adapter_subscription *record=calloc(1,sizeof(*record));record->id=copy_string(subscription_id);record->subscription=subscription;record->output=&output;record->generation=1;record->active=1;pthread_mutex_init(&record->state_mutex,NULL);record->next=subscriptions;subscriptions=record;pthread_create(&record->thread,NULL,forward_updates,record);simple_event(&output,id,"ack");}else emit_error(&output,id,"",&error);convex_error_free(&error);
    } else if (!strcmp(op,"unsubscribe")) {
      json_object *sid=NULL;json_object_object_get_ex(command,"subscriptionId",&sid);const char *subscription_id=sid?json_object_get_string(sid):"";convex_error error={0};adapter_subscription **slot=find_record(&subscriptions,subscription_id);if(stop_record(slot,&error))simple_event(&output,id,"ack");else emit_error(&output,id,"",&error);convex_error_free(&error);
    } else if (!strcmp(op,"debugDisconnect")) {
      convex_error error={0};convex_client *active=ensure_client(&client,&error);if(active&&convex_debug_disconnect(active,&error))simple_event(&output,id,"ack");else emit_error(&output,id,"",&error);convex_error_free(&error);
    } else if (!strcmp(op,"close")) {
      convex_error error={0};while(subscriptions){if(!stop_record(&subscriptions,&error)){emit_error(&output,id,"",&error);convex_error_free(&error);break;}}if(client){convex_close(client,-1,&error);convex_free(client);client=NULL;}simple_event(&output,id,"closed");json_object_put(command);break;
    } else {
      convex_error error={.name=copy_string("ProtocolError"),.message=copy_string("unknown adapter operation")};emit_error(&output,id,"",&error);convex_error_free(&error);
    }
    json_object_put(command);
  }
  convex_error ignored={0};while(subscriptions)stop_record(&subscriptions,&ignored);convex_error_free(&ignored);convex_free(client);free(line);pthread_mutex_destroy(&output.mutex);
}

int main(void) {
  curl_global_init(CURL_GLOBAL_DEFAULT);
  const char *address = getenv("ADAPTER_LISTEN");
  if (!address || !*address) { serve(stdin, stdout); return 0; }
  char *copy=copy_string(address),*colon=strrchr(copy,':');
  if(!colon||colon==copy||!colon[1]){fprintf(stderr,"ADAPTER_LISTEN must be host:port\n");free(copy);return 1;}
  *colon=0;char *port_end=NULL;long parsed_port=strtol(colon+1,&port_end,10);
  if(!port_end||*port_end||parsed_port<1||parsed_port>65535){fprintf(stderr,"ADAPTER_LISTEN has invalid port\n");free(copy);return 1;}
  int port=(int)parsed_port;
  int listener=socket(AF_INET,SOCK_STREAM,0),yes=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
  struct sockaddr_in local={.sin_family=AF_INET,.sin_port=htons((uint16_t)port)};
  if(inet_pton(AF_INET,copy,&local.sin_addr)!=1){fprintf(stderr,"ADAPTER_LISTEN host must be an IPv4 address\n");close(listener);free(copy);return 1;}
  if(bind(listener,(struct sockaddr*)&local,sizeof(local))||listen(listener,1)){perror("adapter listen");free(copy);return 1;}
  int peer=accept(listener,NULL,NULL);FILE *input=fdopen(dup(peer),"r"),*output=fdopen(peer,"w");
  serve(input,output);fclose(input);fclose(output);close(listener);free(copy);return 0;
}
