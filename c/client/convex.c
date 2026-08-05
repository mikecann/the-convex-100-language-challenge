#include "convex.h"
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct live_manager live_manager;
struct convex_client { char *url; char *version; char *token; live_manager *live; int closed; };
struct bytes { char *data; size_t length; };

#define LIVE_QUEUE_CAPACITY 16
#define LIVE_MAX_MESSAGE 2097152
#define LIVE_INITIAL_TS "AAAAAAAAAAA="

struct convex_subscription {
  live_manager *manager;
  uint32_t query_id;
  char *path;
  json_object *args;
  int active;
  int add_pending;
  int remove_pending;
  int remove_done;
  convex_update queue[LIVE_QUEUE_CAPACITY];
  size_t queue_start;
  size_t queue_count;
  struct convex_subscription *next;
};

struct live_manager {
  convex_client *client;
  pthread_t worker;
  pthread_mutex_t mutex;
  pthread_cond_t changed;
  pthread_cond_t updates;
  convex_subscription *subscriptions;
  uint32_t next_query_id;
  uint32_t query_set_version;
  uint32_t remote_query_set;
  uint32_t remote_identity;
  char remote_ts[128];
  char max_observed_ts[128];
  uint32_t connection_count;
  char last_close_reason[256];
  int closing;
  int stopped;
  int debug_requested;
  int connected;
  unsigned long debug_generation;
  unsigned long debug_completed;
  CURL *socket;
};

static char *duplicate(const char *s) { size_t n = strlen(s) + 1; char *p = malloc(n); if (p) memcpy(p, s, n); return p; }
static void fail(convex_error *e, const char *name, const char *message, json_object *data) {
  if (!e) return;
  e->name = duplicate(name); e->message = duplicate(message); e->data = data ? json_object_get(data) : NULL; e->logs = NULL;
}
void convex_error_free(convex_error *e) { if (!e) return; free(e->name); free(e->message); if(e->data) json_object_put(e->data); if(e->logs) json_object_put(e->logs); memset(e,0,sizeof(*e)); }
void convex_result_free(convex_result *r) { if (!r) return; if(r->value) json_object_put(r->value); if(r->logs) json_object_put(r->logs); memset(r,0,sizeof(*r)); }
static size_t receive(void *contents, size_t size, size_t nmemb, void *opaque) {
  struct bytes *b=opaque; size_t add=size*nmemb; char *next=realloc(b->data,b->length+add+1); if(!next || b->length+add > 2097152) return 0;
  b->data=next; memcpy(b->data+b->length,contents,add); b->length+=add; b->data[b->length]=0; return add;
}
convex_client *convex_new(const char *url, const char *version, convex_error *e) {
  if (!url || (strncmp(url,"http://",7) && strncmp(url,"https://",8))) { fail(e,"ProtocolError","Convex deployment URL must use http or https",NULL); return NULL; }
  convex_client *c=calloc(1,sizeof(*c)); if(!c) { fail(e,"Error","out of memory",NULL); return NULL; }
  c->url=duplicate(url); while(strlen(c->url)>0 && c->url[strlen(c->url)-1]=='/') c->url[strlen(c->url)-1]=0;
  c->version=duplicate(version ? version : "c-0.1.0"); return c;
}
void convex_free(convex_client *c) { if(c){convex_error ignored={0};convex_close(c,-1,&ignored);convex_error_free(&ignored);free(c->url);free(c->version);free(c->token);free(c);} }
int convex_set_auth(convex_client *c,const char *token,convex_error *e) { if(!c){fail(e,"Error","client is closed",NULL);return 0;} free(c->token); c->token=token&&*token?duplicate(token):NULL; return 1; }
int convex_call(convex_client *c,const char *operation,const char *path,json_object *args,convex_result *r,convex_error *e) {
  if(!c || !path || !*path || !args || json_object_get_type(args)!=json_type_object){ fail(e,"ProtocolError","Convex arguments must be a JSON object",NULL); return 0; }
  json_object *request=json_object_new_object(); json_object_object_add(request,"path",json_object_new_string(path)); json_object_object_add(request,"args",json_object_get(args)); json_object_object_add(request,"format",json_object_new_string("json"));
  char endpoint[2048]; snprintf(endpoint,sizeof(endpoint),"%s/api/%s",c->url,operation);
  CURL *curl=curl_easy_init(); struct bytes body={0}; if(!curl){json_object_put(request);fail(e,"TransportError","could not create HTTP client",NULL);return 0;}
  struct curl_slist *headers=NULL; headers=curl_slist_append(headers,"Content-Type: application/json"); headers=curl_slist_append(headers,"Accept: application/json"); char client_header[256]; snprintf(client_header,sizeof(client_header),"Convex-Client: %s",c->version); headers=curl_slist_append(headers,client_header); char auth[2048]; if(c->token){snprintf(auth,sizeof(auth),"Authorization: Bearer %s",c->token);headers=curl_slist_append(headers,auth);}
  curl_easy_setopt(curl,CURLOPT_URL,endpoint); curl_easy_setopt(curl,CURLOPT_POST,1L); curl_easy_setopt(curl,CURLOPT_POSTFIELDS,json_object_to_json_string_ext(request,JSON_C_TO_STRING_PLAIN)); curl_easy_setopt(curl,CURLOPT_HTTPHEADER,headers); curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,receive); curl_easy_setopt(curl,CURLOPT_WRITEDATA,&body); curl_easy_setopt(curl,CURLOPT_TIMEOUT,30L);
  CURLcode code=curl_easy_perform(curl); curl_slist_free_all(headers); curl_easy_cleanup(curl); json_object_put(request);
  if(code!=CURLE_OK){free(body.data);fail(e,"TransportError",curl_easy_strerror(code),NULL);return 0;}
  json_object *response=json_tokener_parse(body.data ? body.data : ""); free(body.data); if(!response){fail(e,"ProtocolError","HTTP response was not valid Convex JSON",NULL);return 0;}
  json_object *status=NULL,*value=NULL,*message=NULL,*data=NULL,*logs=NULL; json_object_object_get_ex(response,"status",&status); json_object_object_get_ex(response,"value",&value); json_object_object_get_ex(response,"errorMessage",&message); json_object_object_get_ex(response,"errorData",&data); json_object_object_get_ex(response,"logLines",&logs);
  if(status && !strcmp(json_object_get_string(status),"success") && value){r->value=json_object_get(value); r->logs=logs?json_object_get(logs):NULL; json_object_put(response); return 1;}
  if(status && !strcmp(json_object_get_string(status),"error")){ fail(e,"FunctionError",message?json_object_get_string(message):"Convex function failed",data); if(logs)e->logs=json_object_get(logs); json_object_put(response); return 0; }
  json_object_put(response);fail(e,"ProtocolError","HTTP response had an unknown status",NULL);return 0;
}

static long long monotonic_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static struct timespec realtime_after_ms(int timeout_ms) {
  struct timespec value;
  clock_gettime(CLOCK_REALTIME, &value);
  value.tv_sec += timeout_ms / 1000;
  value.tv_nsec += (long)(timeout_ms % 1000) * 1000000;
  if (value.tv_nsec >= 1000000000L) { value.tv_sec++; value.tv_nsec -= 1000000000L; }
  return value;
}

static void copy_error(convex_error *target, const convex_error *source) {
  memset(target, 0, sizeof(*target));
  target->name = duplicate(source->name ? source->name : "Error");
  target->message = duplicate(source->message ? source->message : "unknown error");
  target->data = source->data ? json_object_get(source->data) : NULL;
  target->logs = source->logs ? json_object_get(source->logs) : NULL;
}

void convex_update_free(convex_update *update) {
  if (!update) return;
  if (update->value) json_object_put(update->value);
  if (update->logs) json_object_put(update->logs);
  convex_error_free(&update->error);
  memset(update, 0, sizeof(*update));
}

static void enqueue_update_locked(convex_subscription *sub, const convex_update *source) {
  size_t index;
  if (sub->queue_count == LIVE_QUEUE_CAPACITY) {
    convex_update_free(&sub->queue[sub->queue_start]);
    sub->queue_start = (sub->queue_start + 1) % LIVE_QUEUE_CAPACITY;
    sub->queue_count--;
  }
  index = (sub->queue_start + sub->queue_count) % LIVE_QUEUE_CAPACITY;
  memset(&sub->queue[index], 0, sizeof(sub->queue[index]));
  sub->queue[index].value = source->value ? json_object_get(source->value) : NULL;
  sub->queue[index].logs = source->logs ? json_object_get(source->logs) : NULL;
  if (source->error.name) copy_error(&sub->queue[index].error, &source->error);
  sub->queue_count++;
}

static int active_count_locked(live_manager *manager) {
  int count = 0;
  for (convex_subscription *sub = manager->subscriptions; sub; sub = sub->next)
    if (sub->active && !sub->remove_pending) count++;
  return count;
}

static convex_subscription *find_subscription_locked(live_manager *manager, uint32_t id) {
  for (convex_subscription *sub = manager->subscriptions; sub; sub = sub->next)
    if (sub->query_id == id) return sub;
  return NULL;
}

static void publish_error_locked(live_manager *manager, const char *name,
                                 const char *message, json_object *data,
                                 json_object *logs) {
  convex_update update = {0};
  update.error.name = (char *)(name ? name : "ProtocolError");
  update.error.message = (char *)(message ? message : "Live protocol error");
  update.error.data = data;
  update.error.logs = logs;
  update.logs = logs;
  for (convex_subscription *sub = manager->subscriptions; sub; sub = sub->next)
    if (sub->active && !sub->remove_pending) enqueue_update_locked(sub, &update);
  pthread_cond_broadcast(&manager->updates);
}

static void session_id(char output[37]) {
  unsigned char raw[16];
  int fd = open("/dev/urandom", O_RDONLY);
  ssize_t got = fd >= 0 ? read(fd, raw, sizeof(raw)) : -1;
  if (fd >= 0) close(fd);
  if (got != (ssize_t)sizeof(raw)) {
    uint64_t seed = (uint64_t)monotonic_ms() ^ (uint64_t)(uintptr_t)output;
    for (size_t i = 0; i < sizeof(raw); i++) { seed = seed * 6364136223846793005ULL + 1; raw[i] = (unsigned char)(seed >> 32); }
  }
  raw[6] = (raw[6] & 0x0f) | 0x40;
  raw[8] = (raw[8] & 0x3f) | 0x80;
  snprintf(output, 37,
    "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    raw[0],raw[1],raw[2],raw[3],raw[4],raw[5],raw[6],raw[7],
    raw[8],raw[9],raw[10],raw[11],raw[12],raw[13],raw[14],raw[15]);
}

static json_object *connect_message(live_manager *manager) {
  char id[37]; session_id(id);
  json_object *message = json_object_new_object();
  json_object_object_add(message, "type", json_object_new_string("Connect"));
  json_object_object_add(message, "sessionId", json_object_new_string(id));
  json_object_object_add(message, "connectionCount", json_object_new_int64(manager->connection_count));
  json_object_object_add(message, "lastCloseReason", json_object_new_string(manager->last_close_reason));
  if (*manager->max_observed_ts)
    json_object_object_add(message, "maxObservedTimestamp", json_object_new_string(manager->max_observed_ts));
  json_object_object_add(message, "clientTs", json_object_new_int64(0));
  return message;
}

static json_object *modify_message_locked(live_manager *manager, convex_subscription *only,
                                          int remove) {
  json_object *message = json_object_new_object();
  json_object *mods = json_object_new_array();
  uint32_t base = manager->query_set_version;
  json_object_object_add(message, "type", json_object_new_string("ModifyQuerySet"));
  json_object_object_add(message, "baseVersion", json_object_new_int64(base));
  json_object_object_add(message, "newVersion", json_object_new_int64(base + 1));
  for (convex_subscription *sub = only ? only : manager->subscriptions; sub; sub = only ? NULL : sub->next) {
    if ((!only && (!sub->active || sub->remove_pending)) || (remove && !only)) continue;
    json_object *mod = json_object_new_object();
    json_object_object_add(mod, "type", json_object_new_string(remove ? "Remove" : "Add"));
    json_object_object_add(mod, "queryId", json_object_new_int64(sub->query_id));
    if (!remove) {
      json_object *args = json_object_new_array();
      json_object_object_add(mod, "udfPath", json_object_new_string(sub->path));
      json_object_array_add(args, json_object_get(sub->args));
      json_object_object_add(mod, "args", args);
    }
    json_object_array_add(mods, mod);
  }
  json_object_object_add(message, "modifications", mods);
  return message;
}

static int ws_wait(CURL *socket, short events, int timeout_ms) {
  curl_socket_t fd = CURL_SOCKET_BAD;
  if (curl_easy_getinfo(socket, CURLINFO_ACTIVESOCKET, &fd) != CURLE_OK || fd == CURL_SOCKET_BAD) return -1;
  struct pollfd descriptor = {.fd = fd, .events = events};
  do { int result = poll(&descriptor, 1, timeout_ms); if (result >= 0) return result; } while (errno == EINTR);
  return -1;
}

static int ws_send_json(CURL *socket, json_object *message, char *reason, size_t reason_size) {
  const char *data = json_object_to_json_string_ext(message, JSON_C_TO_STRING_PLAIN);
  size_t length = strlen(data), sent_total = 0;
  while (sent_total < length) {
    size_t sent = 0;
    CURLcode code = curl_ws_send(socket, data + sent_total, length - sent_total,
                                 &sent, length, sent_total ? CURLWS_CONT : CURLWS_TEXT);
    if (code == CURLE_AGAIN) { if (ws_wait(socket, POLLOUT, 1000) >= 0) continue; }
    if (code != CURLE_OK) { snprintf(reason, reason_size, "live write: %s", curl_easy_strerror(code)); return 0; }
    sent_total += sent;
  }
  return 1;
}

/* The worker owns the CURL handle. Callers hold mutex so controller threads
 * can observe connected state without racing the transport owner. */
static void disconnect_socket_locked(live_manager *manager, const char *reason) {
  if (manager->socket) { curl_easy_cleanup(manager->socket); manager->socket = NULL; }
  manager->connected = 0;
  manager->connection_count++;
  snprintf(manager->last_close_reason, sizeof(manager->last_close_reason), "%s", reason ? reason : "TransportError");
  manager->query_set_version = 0;
  manager->remote_query_set = 0;
  manager->remote_identity = 0;
  snprintf(manager->remote_ts, sizeof(manager->remote_ts), "%s", LIVE_INITIAL_TS);
}

static int connect_socket(live_manager *manager, char *reason, size_t reason_size) {
  size_t url_length = strlen(manager->client->url) + 16;
  char *url = malloc(url_length);
  if (!url) { snprintf(reason, reason_size, "out of memory"); return 0; }
  if (!strncmp(manager->client->url, "https://", 8)) snprintf(url, url_length, "wss://%s/api/sync", manager->client->url + 8);
  else snprintf(url, url_length, "ws://%s/api/sync", manager->client->url + 7);
  CURL *socket = curl_easy_init();
  struct curl_slist *headers = NULL;
  char client_header[256]; snprintf(client_header, sizeof(client_header), "Convex-Client: %s", manager->client->version);
  headers = curl_slist_append(headers, client_header);
  curl_easy_setopt(socket, CURLOPT_URL, url);
  curl_easy_setopt(socket, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(socket, CURLOPT_CONNECT_ONLY, 2L);
  curl_easy_setopt(socket, CURLOPT_TIMEOUT, 10L);
  CURLcode code = curl_easy_perform(socket);
  curl_slist_free_all(headers); free(url);
  if (code != CURLE_OK) { snprintf(reason, reason_size, "live dial: %s", curl_easy_strerror(code)); curl_easy_cleanup(socket); return 0; }
  manager->socket = socket;
  json_object *connect = connect_message(manager);
  int okay = ws_send_json(socket, connect, reason, reason_size); json_object_put(connect);
  if (!okay) { curl_easy_cleanup(manager->socket);manager->socket=NULL; return 0; }
  pthread_mutex_lock(&manager->mutex);
  if (active_count_locked(manager)) {
    json_object *modify = modify_message_locked(manager, NULL, 0);
    pthread_mutex_unlock(&manager->mutex);
    okay = ws_send_json(socket, modify, reason, reason_size); json_object_put(modify);
    pthread_mutex_lock(&manager->mutex);
    if (okay) {
      manager->query_set_version = 1;
      for (convex_subscription *sub=manager->subscriptions;sub;sub=sub->next) sub->add_pending=0;
    }
  }
  pthread_mutex_unlock(&manager->mutex);
  if (!okay) { curl_easy_cleanup(manager->socket);manager->socket=NULL; return 0; }
  pthread_mutex_lock(&manager->mutex);manager->connected=1;pthread_cond_broadcast(&manager->changed);pthread_mutex_unlock(&manager->mutex);
  return 1;
}

static int state_version(json_object *root, const char *name, uint32_t *query_set,
                         uint32_t *identity, const char **timestamp) {
  json_object *version=NULL,*q=NULL,*i=NULL,*ts=NULL;
  return json_object_object_get_ex(root,name,&version) &&
    json_object_object_get_ex(version,"querySet",&q) &&
    json_object_object_get_ex(version,"identity",&i) &&
    json_object_object_get_ex(version,"ts",&ts) &&
    ((*query_set=(uint32_t)json_object_get_int64(q)),(*identity=(uint32_t)json_object_get_int64(i)),(*timestamp=json_object_get_string(ts)),1);
}

static int handle_transition(live_manager *manager, json_object *message,
                             char *reason, size_t reason_size) {
  uint32_t start_q=0,start_i=0,end_q=0,end_i=0; const char *start_ts=NULL,*end_ts=NULL;
  json_object *mods=NULL;
  if (!state_version(message,"startVersion",&start_q,&start_i,&start_ts) ||
      !state_version(message,"endVersion",&end_q,&end_i,&end_ts) ||
      !json_object_object_get_ex(message,"modifications",&mods) || json_object_get_type(mods)!=json_type_array) {
    snprintf(reason, reason_size, "Transition omitted required version fields"); return 0;
  }
  pthread_mutex_lock(&manager->mutex);
  if (start_q!=manager->remote_query_set || start_i!=manager->remote_identity || strcmp(start_ts,manager->remote_ts)) {
    pthread_mutex_unlock(&manager->mutex); snprintf(reason,reason_size,"Transition start version does not match local version"); return 0;
  }
  size_t length=json_object_array_length(mods);
  for(size_t n=0;n<length;n++){
    json_object *mod=json_object_array_get_idx(mods,n),*field=NULL; const char *type=NULL; uint32_t id=0;
    if(json_object_object_get_ex(mod,"type",&field))type=json_object_get_string(field);
    if(json_object_object_get_ex(mod,"queryId",&field))id=(uint32_t)json_object_get_int64(field);
    convex_subscription *sub=find_subscription_locked(manager,id); if(!type){pthread_mutex_unlock(&manager->mutex);snprintf(reason,reason_size,"Transition modification omitted type");return 0;}
    if(!strcmp(type,"QueryRemoved")) continue;
    if(strcmp(type,"QueryUpdated") && strcmp(type,"QueryFailed")){pthread_mutex_unlock(&manager->mutex);snprintf(reason,reason_size,"unknown Transition modification %s",type);return 0;}
    if(!sub || !sub->active || sub->remove_pending) continue;
    convex_update update={0}; json_object *logs=NULL; json_object_object_get_ex(mod,"logLines",&logs); update.logs=logs;
    if(!strcmp(type,"QueryUpdated")){json_object *value=NULL;if(!json_object_object_get_ex(mod,"value",&value)){pthread_mutex_unlock(&manager->mutex);snprintf(reason,reason_size,"QueryUpdated omitted value");return 0;}update.value=value;}
    else {json_object *text=NULL,*data=NULL;json_object_object_get_ex(mod,"errorMessage",&text);json_object_object_get_ex(mod,"errorData",&data);update.error.name="FunctionError";update.error.message=(char *)(text?json_object_get_string(text):"Live query failed");update.error.data=data;update.error.logs=logs;}
    enqueue_update_locked(sub,&update);
  }
  manager->remote_query_set=end_q;manager->remote_identity=end_i;snprintf(manager->remote_ts,sizeof(manager->remote_ts),"%s",end_ts);snprintf(manager->max_observed_ts,sizeof(manager->max_observed_ts),"%s",end_ts);
  pthread_cond_broadcast(&manager->updates);pthread_mutex_unlock(&manager->mutex);return 1;
}

/* 1 means a complete valid server message, 0 means no data, -1 transport, -2 protocol. */
static int receive_message(live_manager *manager, struct bytes *assembled,
                           char *reason, size_t reason_size) {
  char chunk[16384]; size_t received=0; const struct curl_ws_frame *meta=NULL;
  CURLcode code=curl_ws_recv(manager->socket,chunk,sizeof(chunk),&received,&meta);
  if(code==CURLE_AGAIN)return 0;
  if(code!=CURLE_OK){snprintf(reason,reason_size,"live read: %s",curl_easy_strerror(code));return -1;}
  if(meta && (meta->flags&CURLWS_CLOSE)){snprintf(reason,reason_size,"server closed Live WebSocket");return -1;}
  if(assembled->length+received>LIVE_MAX_MESSAGE){snprintf(reason,reason_size,"Live message exceeds %d bytes",LIVE_MAX_MESSAGE);return -2;}
  char *next=realloc(assembled->data,assembled->length+received+1);if(!next){snprintf(reason,reason_size,"out of memory");return -2;}assembled->data=next;memcpy(next+assembled->length,chunk,received);assembled->length+=received;next[assembled->length]=0;
  if(meta && meta->bytesleft)return 0;
  enum json_tokener_error parse_error=json_tokener_success;json_object *message=json_tokener_parse_verbose(assembled->data,&parse_error);
  if(!message){if(parse_error==json_tokener_continue||parse_error==json_tokener_error_parse_eof)return 0;snprintf(reason,reason_size,"decode server message: %s",json_tokener_error_desc(parse_error));assembled->length=0;return -2;}
  assembled->length=0;json_object *type_field=NULL;const char *type=json_object_object_get_ex(message,"type",&type_field)?json_object_get_string(type_field):NULL;int result=1;
  if(!type){snprintf(reason,reason_size,"server message omitted type");result=-2;}
  else if(!strcmp(type,"Transition")){if(!handle_transition(manager,message,reason,reason_size))result=-2;}
  else if(strcmp(type,"Ping")&&strcmp(type,"MutationResponse")&&strcmp(type,"ActionResponse")){json_object *error=NULL;json_object_object_get_ex(message,"error",&error);snprintf(reason,reason_size,"%s%s%s",type,error?": ":"",error?json_object_get_string(error):"");result=-2;}
  json_object_put(message);return result;
}

static void *live_worker(void *opaque) {
  live_manager *manager=opaque; long long reconnect_at=0; int backoff=100; struct bytes assembled={0}; char reason[256]={0};
  for(;;){
    pthread_mutex_lock(&manager->mutex);
    if(manager->closing){pthread_mutex_unlock(&manager->mutex);break;}
    int active=active_count_locked(manager),debug=manager->debug_requested;
    if(debug){manager->debug_requested=0;disconnect_socket_locked(manager,"DebugDisconnect");manager->debug_completed=manager->debug_generation;reconnect_at=monotonic_ms()+100;pthread_cond_broadcast(&manager->changed);}
    if(!manager->socket){for(convex_subscription *sub=manager->subscriptions;sub;sub=sub->next)if(sub->remove_pending&&!sub->remove_done){sub->active=0;sub->remove_done=1;pthread_cond_broadcast(&manager->changed);}}
    if(manager->socket){
      for(convex_subscription *sub=manager->subscriptions;sub;sub=sub->next)if(sub->active&&sub->add_pending&&!sub->remove_pending){json_object *add=modify_message_locked(manager,sub,0);pthread_mutex_unlock(&manager->mutex);int sent=ws_send_json(manager->socket,add,reason,sizeof(reason));json_object_put(add);pthread_mutex_lock(&manager->mutex);if(sent){manager->query_set_version++;sub->add_pending=0;}else{disconnect_socket_locked(manager,reason);reconnect_at=monotonic_ms()+backoff;backoff=backoff<7500?backoff*2:15000;}break;}
      for(convex_subscription *sub=manager->subscriptions;sub;sub=sub->next)if(sub->remove_pending&&!sub->remove_done){json_object *remove=modify_message_locked(manager,sub,1);pthread_mutex_unlock(&manager->mutex);int sent=ws_send_json(manager->socket,remove,reason,sizeof(reason));json_object_put(remove);pthread_mutex_lock(&manager->mutex);if(sent){manager->query_set_version++;sub->active=0;sub->remove_done=1;pthread_cond_broadcast(&manager->changed);}else{disconnect_socket_locked(manager,reason);reconnect_at=monotonic_ms()+backoff;backoff=backoff<7500?backoff*2:15000;}break;}
    }
    active=active_count_locked(manager);
    pthread_mutex_unlock(&manager->mutex);
    if(!manager->socket&&active&&monotonic_ms()>=reconnect_at){if(connect_socket(manager,reason,sizeof(reason))){backoff=100;}else{pthread_mutex_lock(&manager->mutex);if(manager->socket)disconnect_socket_locked(manager,reason);else{manager->connection_count++;snprintf(manager->last_close_reason,sizeof(manager->last_close_reason),"%s",reason);}pthread_mutex_unlock(&manager->mutex);reconnect_at=monotonic_ms()+backoff;backoff=backoff<7500?backoff*2:15000;}continue;}
    if(manager->socket){int received=receive_message(manager,&assembled,reason,sizeof(reason));if(received==0){int ready=ws_wait(manager->socket,POLLIN,20);if(ready>0)received=receive_message(manager,&assembled,reason,sizeof(reason));}if(received==1)backoff=100;else if(received<0){pthread_mutex_lock(&manager->mutex);if(received==-2)publish_error_locked(manager,"ProtocolError",reason,NULL,NULL);disconnect_socket_locked(manager,reason);pthread_mutex_unlock(&manager->mutex);assembled.length=0;reconnect_at=monotonic_ms()+backoff;backoff=backoff<7500?backoff*2:15000;}}
    else {pthread_mutex_lock(&manager->mutex);if(!manager->closing){struct timespec until=realtime_after_ms(20);pthread_cond_timedwait(&manager->changed,&manager->mutex,&until);}pthread_mutex_unlock(&manager->mutex);}
  }
  if(manager->socket){size_t sent=0;curl_ws_send(manager->socket,"",0,&sent,0,CURLWS_CLOSE);curl_easy_cleanup(manager->socket);manager->socket=NULL;}
  free(assembled.data);pthread_mutex_lock(&manager->mutex);manager->stopped=1;for(convex_subscription *sub=manager->subscriptions;sub;sub=sub->next)sub->active=0;pthread_cond_broadcast(&manager->updates);pthread_cond_broadcast(&manager->changed);pthread_mutex_unlock(&manager->mutex);return NULL;
}

static live_manager *ensure_live(convex_client *client, convex_error *error) {
  if(client->closed){fail(error,"Error","client is closed",NULL);return NULL;}
  if(client->live)return client->live;
  live_manager *manager=calloc(1,sizeof(*manager));if(!manager){fail(error,"Error","out of memory",NULL);return NULL;}
  manager->client=client;pthread_mutex_init(&manager->mutex,NULL);pthread_cond_init(&manager->changed,NULL);pthread_cond_init(&manager->updates,NULL);snprintf(manager->last_close_reason,sizeof(manager->last_close_reason),"InitialConnect");snprintf(manager->remote_ts,sizeof(manager->remote_ts),"%s",LIVE_INITIAL_TS);
  if(pthread_create(&manager->worker,NULL,live_worker,manager)){fail(error,"TransportError","could not start Live worker",NULL);pthread_mutex_destroy(&manager->mutex);pthread_cond_destroy(&manager->changed);pthread_cond_destroy(&manager->updates);free(manager);return NULL;}
  client->live=manager;return manager;
}

convex_subscription *convex_subscribe(convex_client *client,const char *path,json_object *args,convex_error *error){
  if(!client||!path||!*path||!args||json_object_get_type(args)!=json_type_object){fail(error,"ProtocolError","Live query path and object arguments are required",NULL);return NULL;}live_manager *manager=ensure_live(client,error);if(!manager)return NULL;convex_subscription *sub=calloc(1,sizeof(*sub));if(!sub){fail(error,"Error","out of memory",NULL);return NULL;}sub->manager=manager;sub->path=duplicate(path);sub->args=json_object_get(args);sub->active=1;sub->add_pending=1;pthread_mutex_lock(&manager->mutex);sub->query_id=manager->next_query_id++;sub->next=manager->subscriptions;manager->subscriptions=sub;pthread_cond_broadcast(&manager->changed);pthread_mutex_unlock(&manager->mutex);return sub;
}

int convex_subscription_next(convex_subscription *sub,convex_update *update,int timeout_ms){if(!sub||!update)return -1;memset(update,0,sizeof(*update));live_manager *manager=sub->manager;pthread_mutex_lock(&manager->mutex);struct timespec deadline={0};if(timeout_ms>=0)deadline=realtime_after_ms(timeout_ms);while(!sub->queue_count&&sub->active&&!manager->stopped){int result=timeout_ms<0?pthread_cond_wait(&manager->updates,&manager->mutex):pthread_cond_timedwait(&manager->updates,&manager->mutex,&deadline);if(result==ETIMEDOUT){pthread_mutex_unlock(&manager->mutex);return 0;}}if(!sub->queue_count){pthread_mutex_unlock(&manager->mutex);return -1;}*update=sub->queue[sub->queue_start];memset(&sub->queue[sub->queue_start],0,sizeof(*update));sub->queue_start=(sub->queue_start+1)%LIVE_QUEUE_CAPACITY;sub->queue_count--;pthread_mutex_unlock(&manager->mutex);return 1;}

int convex_unsubscribe(convex_subscription *sub,convex_error *error){if(!sub)return 1;live_manager *manager=sub->manager;pthread_mutex_lock(&manager->mutex);if(!sub->active){pthread_mutex_unlock(&manager->mutex);return 1;}sub->remove_pending=1;pthread_cond_broadcast(&manager->changed);while(!sub->remove_done&&!manager->stopped)pthread_cond_wait(&manager->changed,&manager->mutex);if(manager->stopped&&!sub->remove_done){pthread_mutex_unlock(&manager->mutex);fail(error,"TransportError","client closed before Live Remove completed",NULL);return 0;}pthread_mutex_unlock(&manager->mutex);return 1;}

int convex_debug_disconnect(convex_client *client,convex_error *error){if(!client||!client->live){fail(error,"TransportError","Live WebSocket is not connected",NULL);return 0;}live_manager *manager=client->live;pthread_mutex_lock(&manager->mutex);if(!manager->connected){pthread_mutex_unlock(&manager->mutex);fail(error,"TransportError","Live WebSocket is not connected",NULL);return 0;}unsigned long generation=++manager->debug_generation;manager->debug_requested=1;pthread_cond_broadcast(&manager->changed);while(manager->debug_completed<generation&&!manager->stopped)pthread_cond_wait(&manager->changed,&manager->mutex);int okay=manager->debug_completed>=generation;pthread_mutex_unlock(&manager->mutex);if(!okay)fail(error,"TransportError","client closed during debug disconnect",NULL);return okay;}

int convex_close(convex_client *client,int timeout_ms,convex_error *error){if(!client)return 1;if(client->closed&&!client->live)return 1;client->closed=1;live_manager *manager=client->live;if(!manager)return 1;pthread_mutex_lock(&manager->mutex);manager->closing=1;pthread_cond_broadcast(&manager->changed);struct timespec deadline={0};if(timeout_ms>=0)deadline=realtime_after_ms(timeout_ms);while(!manager->stopped){int result=timeout_ms<0?pthread_cond_wait(&manager->changed,&manager->mutex):pthread_cond_timedwait(&manager->changed,&manager->mutex,&deadline);if(result==ETIMEDOUT){pthread_mutex_unlock(&manager->mutex);fail(error,"TransportError","timed out waiting for Live worker to close",NULL);return 0;}}pthread_mutex_unlock(&manager->mutex);pthread_join(manager->worker,NULL);convex_subscription *sub=manager->subscriptions;while(sub){convex_subscription *next=sub->next;for(size_t n=0;n<sub->queue_count;n++)convex_update_free(&sub->queue[(sub->queue_start+n)%LIVE_QUEUE_CAPACITY]);free(sub->path);json_object_put(sub->args);free(sub);sub=next;}pthread_mutex_destroy(&manager->mutex);pthread_cond_destroy(&manager->changed);pthread_cond_destroy(&manager->updates);free(manager);client->live=NULL;return 1;}
