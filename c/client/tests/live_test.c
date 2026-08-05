#include "convex.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct {
  pthread_mutex_t mutex;
  pthread_cond_t changed;
  pthread_t thread;
  int listener;
  int port;
  int stop;
  int connections;
  int connection_base;
  int remove_seen;
  int generation;
  int sent_generation;
  int desired_count;
  int desired_failure;
  int desired_malformed;
  int desired_fragment;
  int failed;
  char failure[256];
} fixture;

static void check(int condition, const char *message) {
  if (!condition) { fprintf(stderr, "FAIL %s\n", message); exit(1); }
}

static int receive_exact(int fd, unsigned char *data, size_t length) {
  while (length) { ssize_t got=recv(fd,data,length,0);if(got<=0)return 0;data+=got;length-=(size_t)got; }
  return 1;
}

static int read_frame(int fd, char **output) {
  unsigned char header[2];
  if (!receive_exact(fd,header,2)) return 0;
  uint64_t length=header[1]&127;int masked=header[1]&128;
  if(length==126){unsigned char wide[2];if(!receive_exact(fd,wide,2))return 0;length=((uint64_t)wide[0]<<8)|wide[1];}
  else if(length==127){unsigned char wide[8];if(!receive_exact(fd,wide,8))return 0;length=0;for(int n=0;n<8;n++)length=(length<<8)|wide[n];}
  if(length>2097152)return 0;
  unsigned char mask[4]={0};if(masked&&!receive_exact(fd,mask,4))return 0;
  char *value=malloc((size_t)length+1);if(!value||!receive_exact(fd,(unsigned char*)value,(size_t)length)){free(value);return 0;}
  for(uint64_t n=0;masked&&n<length;n++)value[n]^=mask[n%4];
  value[length]=0;
  if((header[0]&15)==8){free(value);return 0;}*output=value;return 1;
}

static int send_frame(int fd, int opcode, int final, const char *data, size_t length) {
  unsigned char header[10];size_t h=0;header[h++]=(unsigned char)((final?128:0)|opcode);
  if(length<126)header[h++]=(unsigned char)length;else{header[h++]=126;header[h++]=(unsigned char)(length>>8);header[h++]=(unsigned char)length;}
  return send(fd,header,h,MSG_NOSIGNAL)==(ssize_t)h && send(fd,data,length,MSG_NOSIGNAL)==(ssize_t)length;
}

static int send_all(int fd, const char *data, size_t length) {
  while(length){ssize_t sent=send(fd,data,length,MSG_NOSIGNAL);if(sent<=0)return 0;data+=sent;length-=(size_t)sent;}
  return 1;
}

static int complete_fixture_auth(const char *request) {
  static const char prefix[]="Authorization: Bearer ";
  const char *header=strstr(request,prefix);
  if(!header)return 0;
  const char *token=header+sizeof(prefix)-1,*end=strstr(token,"\r\n");
  if(!end||end-token!=4096||token[4095]!='Z')return 0;
  for(size_t n=0;n<4095;n++)if(token[n]!='a')return 0;
  return 1;
}

static void base64(const unsigned char *source, size_t length, char *output) {
  static const char table[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";size_t at=0;
  for(size_t n=0;n<length;n+=3){uint32_t value=(uint32_t)source[n]<<16;if(n+1<length)value|=(uint32_t)source[n+1]<<8;if(n+2<length)value|=source[n+2];output[at++]=table[(value>>18)&63];output[at++]=table[(value>>12)&63];output[at++]=n+1<length?table[(value>>6)&63]:'=';output[at++]=n+2<length?table[value&63]:'=';}output[at]=0;
}

/* Returns 1 for an upgraded WebSocket, 2 for a completed HTTP fixture call. */
static int accept_request(int fd) {
  char request[8192]={0};size_t used=0;
  while(used+1<sizeof(request)&&!strstr(request,"\r\n\r\n")){ssize_t got=recv(fd,request+used,sizeof(request)-used-1,0);if(got<=0)return 0;used+=(size_t)got;request[used]=0;}
  char *headers_end=strstr(request,"\r\n\r\n");
  if(!strstr(request,"Upgrade: websocket")&&!strstr(request,"Upgrade: WebSocket")){
    size_t header_length=(size_t)(headers_end+4-request),content_length=0;char *length_header=strstr(request,"Content-Length:");if(length_header)content_length=(size_t)strtoul(length_header+15,NULL,10);
    while(used<header_length+content_length&&used+1<sizeof(request)){ssize_t got=recv(fd,request+used,sizeof(request)-used-1,0);if(got<=0)return 0;used+=(size_t)got;request[used]=0;}
    const char *body=headers_end+4;
    if(strstr(body,"\"path\":\"demo:oversize\"")){
      const size_t body_length=2097153;
      char header[256];int header_length=snprintf(header,sizeof(header),"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",body_length);
      if(!send_all(fd,header,(size_t)header_length))return 0;
      char chunk[16384];memset(chunk,'x',sizeof(chunk));size_t remaining=body_length;
      while(remaining){size_t amount=remaining<sizeof(chunk)?remaining:sizeof(chunk);if(!send_all(fd,chunk,amount))break;remaining-=amount;}
      return 2;
    }
    const char *payload;
    if(strstr(body,"\"path\":\"demo:null\""))payload="{\"status\":\"success\",\"value\":null,\"logLines\":[\"null fixture\"]}";
    else if(strstr(body,"\"path\":\"demo:fail\""))payload="{\"status\":\"error\",\"errorMessage\":\"expected fixture failure\",\"errorData\":{\"code\":\"EXPECTED\"},\"logLines\":[\"failure fixture\"]}";
    else if(strstr(body,"\"path\":\"demo:auth\""))payload=complete_fixture_auth(request)?"{\"status\":\"success\",\"value\":{\"auth\":true}}":"{\"status\":\"error\",\"errorMessage\":\"truncated auth header\"}";
    else payload="{\"status\":\"success\",\"value\":{\"unicode\":\"世界\",\"nested\":{\"nil\":null}},\"logLines\":[\"success fixture\"]}";
    char response[1024];int response_length=snprintf(response,sizeof(response),"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",strlen(payload),payload);return send(fd,response,(size_t)response_length,0)==response_length?2:0;
  }
  char *key=strstr(request,"Sec-WebSocket-Key:");if(!key)return 0;key+=18;while(*key==' ')key++;char *end=strstr(key,"\r\n");if(!end)return 0;*end=0;
  char joined[256];snprintf(joined,sizeof(joined),"%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",key);unsigned char digest[SHA_DIGEST_LENGTH];SHA1((unsigned char*)joined,strlen(joined),digest);char accept[64];base64(digest,sizeof(digest),accept);
  char response[512];int length=snprintf(response,sizeof(response),"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",accept);return send(fd,response,(size_t)length,0)==length?1:0;
}

static void fixture_fail(fixture *server, const char *message) { pthread_mutex_lock(&server->mutex);server->failed=1;snprintf(server->failure,sizeof(server->failure),"%s",message);pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex); }

static int integer_field(json_object *object,const char *name,int *value){json_object *field=NULL;if(!json_object_object_get_ex(object,name,&field))return 0;*value=json_object_get_int(field);return 1;}

static int send_transition(int fd,int query_id,int start_query_set,int end_query_set,const char *start_ts,int serial,
                           int count,int failure,int fragmented) {
  char end_ts[64];snprintf(end_ts,sizeof(end_ts),"%010d=",serial);
  json_object *root=json_object_new_object(),*start=json_object_new_object(),*end=json_object_new_object(),*mods=json_object_new_array(),*mod=json_object_new_object();
  json_object_object_add(root,"type",json_object_new_string("Transition"));json_object_object_add(start,"querySet",json_object_new_int(start_query_set));json_object_object_add(start,"identity",json_object_new_int(0));json_object_object_add(start,"ts",json_object_new_string(start_ts));json_object_object_add(end,"querySet",json_object_new_int(end_query_set));json_object_object_add(end,"identity",json_object_new_int(0));json_object_object_add(end,"ts",json_object_new_string(end_ts));json_object_object_add(root,"startVersion",start);json_object_object_add(root,"endVersion",end);
  json_object_object_add(mod,"type",json_object_new_string(failure?"QueryFailed":"QueryUpdated"));json_object_object_add(mod,"queryId",json_object_new_int(query_id));json_object_object_add(mod,"logLines",json_object_new_array());
  if(failure){json_object *data=json_object_new_object();json_object_object_add(data,"code",json_object_new_string("ROOM_EMPTY"));json_object_object_add(mod,"errorMessage",json_object_new_string("room must be nonzero"));json_object_object_add(mod,"errorData",data);}else{json_object *value=json_object_new_object();json_object_object_add(value,"count",json_object_new_double((double)count));json_object_object_add(value,"text",json_object_new_string("Hello, 世界 👋"));json_object_object_add(mod,"value",value);}
  json_object_array_add(mods,mod);json_object_object_add(root,"modifications",mods);const char *text=json_object_to_json_string_ext(root,JSON_C_TO_STRING_PLAIN);size_t length=strlen(text);int okay;
  if(fragmented){size_t split=length/2;while(split<length&&(((unsigned char)text[split]&0xc0)==0x80))split++;okay=send_frame(fd,1,0,text,split)&&send_frame(fd,0,1,text+split,length-split);}else okay=send_frame(fd,1,1,text,length);
  json_object_put(root);return okay;
}

static int send_malformed_version(int fd,int query_set,const char *start_ts,int kind) {
  json_object *root=json_object_new_object(),*start=json_object_new_object(),*end=json_object_new_object(),*mods=json_object_new_array();
  json_object_object_add(root,"type",json_object_new_string("Transition"));
  json_object_object_add(start,"querySet",json_object_new_int(query_set));json_object_object_add(start,"identity",json_object_new_int(0));
  json_object_object_add(start,"ts",kind==2?NULL:json_object_new_int(42));
  json_object_object_add(end,"querySet",json_object_new_int(query_set));json_object_object_add(end,"identity",json_object_new_int(0));json_object_object_add(end,"ts",json_object_new_string(start_ts));
  json_object_object_add(root,"startVersion",start);json_object_object_add(root,"endVersion",end);json_object_object_add(root,"modifications",mods);
  const char *text=json_object_to_json_string_ext(root,JSON_C_TO_STRING_PLAIN);int okay=send_frame(fd,1,1,text,strlen(text));json_object_put(root);return okay;
}

static void *fixture_thread(void *opaque) {
  fixture *server=opaque;int serial=0;
  while(!server->stop){int fd=accept(server->listener,NULL,NULL);if(fd<0){if(server->stop)break;continue;}int request_kind=accept_request(fd);if(request_kind==2){close(fd);continue;}if(request_kind!=1){close(fd);fixture_fail(server,"request handshake failed");continue;}
    char *text=NULL;if(!read_frame(fd,&text)){close(fd);continue;}json_object *connect=json_tokener_parse(text);free(text);int connection_count=-1;if(!connect||!integer_field(connect,"connectionCount",&connection_count)){if(connect)json_object_put(connect);close(fd);fixture_fail(server,"invalid Connect");continue;}pthread_mutex_lock(&server->mutex);int base=server->connection_base,expected=server->connections-base;server->connections++;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);if(connection_count!=expected){json_object_put(connect);close(fd);fixture_fail(server,"connectionCount did not advance exactly");continue;}if(base==0&&expected>=1&&expected<=5){json_object *reason=NULL,*timestamp=NULL;char expected_timestamp[64];snprintf(expected_timestamp,sizeof(expected_timestamp),"%010d=",serial);if(!json_object_object_get_ex(connect,"lastCloseReason",&reason)||strcmp(json_object_get_string(reason),"DebugDisconnect")||!json_object_object_get_ex(connect,"maxObservedTimestamp",&timestamp)||strcmp(json_object_get_string(timestamp),expected_timestamp)){json_object_put(connect);close(fd);fixture_fail(server,"debug reconnect metadata was not preserved");continue;}}json_object_put(connect);
    if(!read_frame(fd,&text)){close(fd);continue;}json_object *add=json_tokener_parse(text);free(text);json_object *mods=NULL,*mod=NULL,*field=NULL;int query_id=-1,query_set=0;if(!add||!json_object_object_get_ex(add,"modifications",&mods)||(mod=json_object_array_get_idx(mods,0))==NULL||!json_object_object_get_ex(mod,"type",&field)||strcmp(json_object_get_string(field),"Add")||!integer_field(mod,"queryId",&query_id)||!integer_field(add,"newVersion",&query_set)){if(add)json_object_put(add);close(fd);fixture_fail(server,"invalid Add");continue;}json_object_put(add);
    serial++;char current_ts[64];snprintf(current_ts,sizeof(current_ts),"%010d=",serial);pthread_mutex_lock(&server->mutex);int generation=server->generation,count=server->desired_count,failure=server->desired_failure,fragment=server->desired_fragment;server->sent_generation=generation;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);if(!send_transition(fd,query_id,0,query_set,"AAAAAAAAAAA=",serial,count,failure,fragment)){close(fd);continue;}
    for(;;){pthread_mutex_lock(&server->mutex);int stop=server->stop,new_generation=server->generation,malformed=server->desired_malformed;count=server->desired_count;failure=server->desired_failure;fragment=server->desired_fragment;pthread_mutex_unlock(&server->mutex);if(stop)break;if(new_generation!=generation){generation=new_generation;if(malformed==1){send_frame(fd,1,1,"{not-json",9);}else if(malformed==2||malformed==3){send_malformed_version(fd,query_set,current_ts,malformed);}else{serial++;if(!send_transition(fd,query_id,query_set,query_set,current_ts,serial,count,failure,fragment))break;snprintf(current_ts,sizeof(current_ts),"%010d=",serial);}pthread_mutex_lock(&server->mutex);server->sent_generation=generation;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);}
      struct pollfd poller={.fd=fd,.events=POLLIN};int ready=poll(&poller,1,5);if(ready>0){if(!read_frame(fd,&text))break;json_object *message=json_tokener_parse(text);free(text);json_object *type=NULL;if(message&&json_object_object_get_ex(message,"type",&type)&&!strcmp(json_object_get_string(type),"ModifyQuerySet")){json_object *items=NULL,*new_version=NULL;json_object_object_get_ex(message,"modifications",&items);json_object *item=items?json_object_array_get_idx(items,0):NULL;json_object *kind=NULL;if(item&&json_object_object_get_ex(item,"type",&kind)&&!strcmp(json_object_get_string(kind),"Remove")){pthread_mutex_lock(&server->mutex);server->remove_seen++;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);json_object_put(message);break;}if(item&&kind&&!strcmp(json_object_get_string(kind),"Add")&&integer_field(item,"queryId",&query_id)&&json_object_object_get_ex(message,"newVersion",&new_version)){int next_query_set=json_object_get_int(new_version);serial++;if(!send_transition(fd,query_id,query_set,next_query_set,current_ts,serial,count,failure,fragment)){json_object_put(message);break;}query_set=next_query_set;snprintf(current_ts,sizeof(current_ts),"%010d=",serial);}}if(message)json_object_put(message);}}
    close(fd);
  }return NULL;
}

static void fixture_start(fixture *server) {memset(server,0,sizeof(*server));pthread_mutex_init(&server->mutex,NULL);pthread_cond_init(&server->changed,NULL);server->listener=socket(AF_INET,SOCK_STREAM,0);int yes=1;setsockopt(server->listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK),.sin_port=0};check(!bind(server->listener,(struct sockaddr*)&address,sizeof(address))&&!listen(server->listener,8),"fixture listen");socklen_t size=sizeof(address);getsockname(server->listener,(struct sockaddr*)&address,&size);server->port=ntohs(address.sin_port);pthread_create(&server->thread,NULL,fixture_thread,server);}
static void fixture_stop(fixture *server){pthread_mutex_lock(&server->mutex);server->stop=1;pthread_mutex_unlock(&server->mutex);shutdown(server->listener,SHUT_RDWR);close(server->listener);pthread_join(server->thread,NULL);check(!server->failed,server->failure);pthread_mutex_destroy(&server->mutex);pthread_cond_destroy(&server->changed);}
static void fixture_change(fixture *server,int count,int failure,int malformed,int fragmented){pthread_mutex_lock(&server->mutex);server->desired_count=count;server->desired_failure=failure;server->desired_malformed=malformed;server->desired_fragment=fragmented;int generation=++server->generation;while(server->sent_generation<generation&&!server->failed)pthread_cond_wait(&server->changed,&server->mutex);pthread_mutex_unlock(&server->mutex);}
static void fixture_configure(fixture *server,int count,int failure,int malformed,int fragmented){pthread_mutex_lock(&server->mutex);server->desired_count=count;server->desired_failure=failure;server->desired_malformed=malformed;server->desired_fragment=fragmented;server->generation++;pthread_mutex_unlock(&server->mutex);}
static void wait_connections(fixture *server,int count){pthread_mutex_lock(&server->mutex);while(server->connections<count&&!server->failed)pthread_cond_wait(&server->changed,&server->mutex);pthread_mutex_unlock(&server->mutex);}
static void wait_removes(fixture *server,int count){pthread_mutex_lock(&server->mutex);while(server->remove_seen<count&&!server->failed)pthread_cond_wait(&server->changed,&server->mutex);pthread_mutex_unlock(&server->mutex);}
static int fixture_connections(fixture *server){pthread_mutex_lock(&server->mutex);int count=server->connections;pthread_mutex_unlock(&server->mutex);return count;}

static int update_count(convex_subscription *sub,int expected,int expect_error){convex_update update={0};int got=convex_subscription_next(sub,&update,5000);if(got!=1){fprintf(stderr,"update wait returned %d\n",got);return 0;}int okay;if(expect_error==1)okay=update.error.name&&update.error.data;else if(expect_error==2)okay=update.error.name&&!strcmp(update.error.name,"ProtocolError");else{json_object *count=NULL,*text=NULL;okay=!update.error.name&&update.value&&json_object_object_get_ex(update.value,"count",&count)&&json_object_get_int(count)==expected&&json_object_object_get_ex(update.value,"text",&text)&&!strcmp(json_object_get_string(text),"Hello, 世界 👋");}if(!okay)fprintf(stderr,"unexpected update error=%s message=%s value=%s\n",update.error.name?update.error.name:"",update.error.message?update.error.message:"",update.value?json_object_to_json_string(update.value):"null");convex_update_free(&update);return okay;}

typedef struct { pid_t pid; FILE *input; FILE *output; } adapter_process;
typedef struct { int dequeued[2]; int resume[2]; int inactive[2]; } relay_control;

static adapter_process start_adapter(const char *url) {
  int commands[2],events[2];check(!pipe(commands)&&!pipe(events),"adapter pipes");pid_t pid=fork();check(pid>=0,"fork adapter");
  if(pid==0){dup2(commands[0],STDIN_FILENO);dup2(events[1],STDOUT_FILENO);close(commands[0]);close(commands[1]);close(events[0]);close(events[1]);setenv("CONVEX_URL",url,1);unsetenv("ADAPTER_LISTEN");execl("/out-adapter","/out-adapter",(char*)NULL);_exit(127);}
  close(commands[0]);close(events[1]);adapter_process process={.pid=pid,.input=fdopen(commands[1],"w"),.output=fdopen(events[0],"r")};setvbuf(process.input,NULL,_IOLBF,0);return process;
}

static adapter_process start_paused_adapter(const char *url,relay_control *control) {
  int commands[2],events[2];check(!pipe(commands)&&!pipe(events)&&!pipe(control->dequeued)&&!pipe(control->resume)&&!pipe(control->inactive),"paused adapter pipes");pid_t pid=fork();check(pid>=0,"fork paused adapter");
  if(pid==0){dup2(commands[0],STDIN_FILENO);dup2(events[1],STDOUT_FILENO);close(commands[0]);close(commands[1]);close(events[0]);close(events[1]);close(control->dequeued[0]);close(control->resume[1]);close(control->inactive[0]);char value[32];snprintf(value,sizeof(value),"%d",control->dequeued[1]);setenv("ADAPTER_TEST_RELAY_DEQUEUED_FD",value,1);snprintf(value,sizeof(value),"%d",control->resume[0]);setenv("ADAPTER_TEST_RELAY_RESUME_FD",value,1);snprintf(value,sizeof(value),"%d",control->inactive[1]);setenv("ADAPTER_TEST_RELAY_INACTIVE_FD",value,1);setenv("CONVEX_URL",url,1);unsetenv("ADAPTER_LISTEN");execl("/out-adapter-test","/out-adapter-test",(char*)NULL);_exit(127);}
  close(commands[0]);close(events[1]);close(control->dequeued[1]);close(control->resume[0]);close(control->inactive[1]);adapter_process process={.pid=pid,.input=fdopen(commands[1],"w"),.output=fdopen(events[0],"r")};setvbuf(process.input,NULL,_IOLBF,0);return process;
}

static void adapter_send(adapter_process *process,const char *command){fprintf(process->input,"%s\n",command);fflush(process->input);}
static json_object *adapter_read(adapter_process *process){char line[8192];check(fgets(line,sizeof(line),process->output)!=NULL,"adapter event");json_object *event=json_tokener_parse(line);check(event!=NULL,"adapter event JSON");return event;}
static const char *event_type(json_object *event){json_object *type=NULL;return json_object_object_get_ex(event,"type",&type)?json_object_get_string(type):"";}
static void require_absent(json_object *event,const char *name){json_object *ignored=NULL;check(!json_object_object_get_ex(event,name,&ignored),name);}
static void relay_byte(int fd){char byte;check(read(fd,&byte,1)==1,"relay barrier");}
static void relay_resume(relay_control *control){char byte='x';check(write(control->resume[1],&byte,1)==1,"relay resume");}
static void require_no_adapter_event(adapter_process *process){struct pollfd descriptor={.fd=fileno(process->output),.events=POLLIN};check(poll(&descriptor,1,100)==0,"stale adapter subscription event");}

static void test_http_guards(const char *url) {
  convex_error error={0};convex_result result={0};json_object *args=json_object_new_object();
  convex_client *client=convex_new(url,"c-http-fixture",&error);check(client!=NULL,"HTTP fixture client");
  char *token=malloc(4097);check(token!=NULL,"long auth token allocation");memset(token,'a',4095);token[4095]='Z';token[4096]=0;
  check(convex_set_auth(client,token,&error),"long bearer token accepted");free(token);
  check(convex_call(client,"query","demo:auth",args,&result,&error),"long bearer token transmitted without truncation");
  json_object *auth=NULL;check(result.value&&json_object_object_get_ex(result.value,"auth",&auth)&&json_object_get_boolean(auth),"fixture observed complete bearer token");convex_result_free(&result);
  check(!convex_call(client,"query","demo:oversize",args,&result,&error),"oversized HTTP response rejected");
  check(error.name&&!strcmp(error.name,"TransportError"),"oversized HTTP response reports transport error");convex_error_free(&error);
  check(convex_close(client,5000,&error),"HTTP-only client closes");
  check(!convex_call(client,"query","demo:echo",args,&result,&error)&&error.message&&!strcmp(error.message,"client is closed"),"HTTP call rejects closed client");convex_error_free(&error);
  check(!convex_set_auth(client,"replacement",&error)&&error.message&&!strcmp(error.message,"client is closed"),"auth replacement rejects closed client");convex_error_free(&error);
  convex_free(client);json_object_put(args);
}

static void test_snapshot_add_race(fixture *server,const char *url) {
  int ready[2],resume[2];check(!pipe(ready)&&!pipe(resume),"snapshot race pipes");
  char value[32];snprintf(value,sizeof(value),"%d",ready[1]);setenv("CONVEX_TEST_SNAPSHOT_READY_FD",value,1);snprintf(value,sizeof(value),"%d",resume[0]);setenv("CONVEX_TEST_SNAPSHOT_RESUME_FD",value,1);
  pthread_mutex_lock(&server->mutex);server->connection_base=server->connections;pthread_mutex_unlock(&server->mutex);fixture_configure(server,30,0,0,0);
  convex_error error={0};convex_client *client=convex_new(url,"c-snapshot-race",&error);json_object *args=json_object_new_object();json_object_object_add(args,"room",json_object_new_string("snapshot-race"));
  convex_subscription *first=convex_subscribe(client,"demo:state",args,&error);check(first!=NULL,"first snapshot subscription");char byte;check(read(ready[0],&byte,1)==1,"initial Add snapshot captured");
  convex_subscription *second=convex_subscribe(client,"demo:state",args,&error);check(second!=NULL,"concurrent snapshot subscription");unsetenv("CONVEX_TEST_SNAPSHOT_READY_FD");unsetenv("CONVEX_TEST_SNAPSHOT_RESUME_FD");byte='x';check(write(resume[1],&byte,1)==1,"release initial Add snapshot");
  check(update_count(first,30,0),"snapshot subscription receives initial value");check(update_count(second,30,0),"concurrent Add remains pending and receives initial value");
  check(convex_close(client,5000,&error),"snapshot client closes");convex_update after_close={0};check(convex_subscription_next(first,&after_close,0)==-1,"first subscription handle survives close");check(convex_subscription_next(second,&after_close,0)==-1,"second subscription handle survives close");
  convex_free(client);json_object_put(args);close(ready[0]);close(ready[1]);close(resume[0]);close(resume[1]);
}

static void test_adapter_events(fixture *server,const char *url) {
  pthread_mutex_lock(&server->mutex);server->connection_base=server->connections;pthread_mutex_unlock(&server->mutex);
  adapter_process adapter=start_adapter(url);json_object *event,*field=NULL;fprintf(stderr,"adapter fixture: HTTP result\n");
  adapter_send(&adapter,"{\"id\":\"result\",\"op\":\"query\",\"path\":\"demo:echo\",\"args\":{}}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"result"),"adapter result event");check(json_object_object_get_ex(event,"value",&field)&&field,"result value present");check(json_object_object_get_ex(event,"logs",&field),"result logs present");require_absent(event,"error");require_absent(event,"subscriptionId");json_object_put(event);
  fprintf(stderr,"adapter fixture: HTTP null\n");adapter_send(&adapter,"{\"id\":\"null\",\"op\":\"query\",\"path\":\"demo:null\",\"args\":{}}");event=adapter_read(&adapter);field=(json_object*)1;check(!strcmp(event_type(event),"result")&&json_object_object_get_ex(event,"value",&field)&&field==NULL,"JSON null result is successful");require_absent(event,"error");json_object_put(event);
  fprintf(stderr,"adapter fixture: HTTP error\n");adapter_send(&adapter,"{\"id\":\"failure\",\"op\":\"query\",\"path\":\"demo:fail\",\"args\":{}}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"error"),"adapter FunctionError event");json_object *error=NULL,*data=NULL,*code=NULL;check(json_object_object_get_ex(event,"error",&error)&&json_object_object_get_ex(error,"data",&data)&&json_object_object_get_ex(data,"code",&code)&&!strcmp(json_object_get_string(code),"EXPECTED"),"structured FunctionError data");check(json_object_object_get_ex(event,"logs",&field),"FunctionError logs");require_absent(event,"value");require_absent(event,"subscriptionId");json_object_put(event);
  fprintf(stderr,"adapter fixture: Live result\n");fixture_configure(server,2,0,0,0);adapter_send(&adapter,"{\"id\":\"subscribe\",\"op\":\"subscribe\",\"subscriptionId\":\"fixture-live\",\"path\":\"demo:state\",\"args\":{\"room\":\"adapter\"}}");json_object *ack=NULL,*update=NULL;for(int n=0;n<2;n++){event=adapter_read(&adapter);if(!strcmp(event_type(event),"ack"))ack=event;else update=event;}check(ack&&update,"subscribe ack and value");require_absent(update,"id");require_absent(update,"error");check(json_object_object_get_ex(update,"subscriptionId",&field)&&!strcmp(json_object_get_string(field),"fixture-live")&&json_object_object_get_ex(update,"value",&field),"subscription value shape");json_object_put(ack);json_object_put(update);
  fprintf(stderr,"adapter fixture: Live error\n");fixture_change(server,2,1,0,0);event=adapter_read(&adapter);check(!strcmp(event_type(event),"subscription"),"subscription error event");require_absent(event,"id");require_absent(event,"value");check(json_object_object_get_ex(event,"error",&error)&&json_object_object_get_ex(error,"data",&data),"subscription structured error");json_object_put(event);
  fprintf(stderr,"adapter fixture: close\n");adapter_send(&adapter,"{\"id\":\"unsubscribe\",\"op\":\"unsubscribe\",\"subscriptionId\":\"fixture-live\"}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"ack"),"unsubscribe ack");json_object_put(event);
  adapter_send(&adapter,"{\"id\":\"close\",\"op\":\"close\"}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"closed"),"adapter close");json_object_put(event);fclose(adapter.input);fclose(adapter.output);int status=0;waitpid(adapter.pid,&status,0);check(WIFEXITED(status)&&WEXITSTATUS(status)==0,"adapter process exit");
}

static void test_adapter_relay_races(fixture *server,const char *url) {
  pthread_mutex_lock(&server->mutex);server->connection_base=server->connections;pthread_mutex_unlock(&server->mutex);fixture_configure(server,10,0,0,0);relay_control control;adapter_process adapter=start_paused_adapter(url,&control);json_object *event,*value=NULL,*count=NULL;
  adapter_send(&adapter,"{\"id\":\"subscribe-old\",\"op\":\"subscribe\",\"subscriptionId\":\"race\",\"path\":\"demo:state\",\"args\":{\"room\":\"unsubscribe-race\"}}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"ack"),"race subscribe ack");json_object_put(event);relay_byte(control.dequeued[0]);
  adapter_send(&adapter,"{\"id\":\"unsubscribe-race\",\"op\":\"unsubscribe\",\"subscriptionId\":\"race\"}");relay_byte(control.inactive[0]);relay_resume(&control);event=adapter_read(&adapter);check(!strcmp(event_type(event),"ack"),"race unsubscribe ack");json_object_put(event);require_no_adapter_event(&adapter);

  fixture_configure(server,10,0,0,0);adapter_send(&adapter,"{\"id\":\"subscribe-replace-old\",\"op\":\"subscribe\",\"subscriptionId\":\"race\",\"path\":\"demo:state\",\"args\":{\"room\":\"old-room\"}}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"ack"),"replacement old ack");json_object_put(event);relay_byte(control.dequeued[0]);fixture_change(server,20,0,0,0);
  adapter_send(&adapter,"{\"id\":\"subscribe-replacement\",\"op\":\"subscribe\",\"subscriptionId\":\"race\",\"path\":\"demo:state\",\"args\":{\"room\":\"new-room\"}}");relay_byte(control.inactive[0]);relay_resume(&control);event=adapter_read(&adapter);check(!strcmp(event_type(event),"ack"),"replacement ack");json_object_put(event);relay_byte(control.dequeued[0]);require_no_adapter_event(&adapter);relay_resume(&control);event=adapter_read(&adapter);check(!strcmp(event_type(event),"subscription")&&json_object_object_get_ex(event,"value",&value)&&json_object_object_get_ex(value,"count",&count)&&json_object_get_int(count)==20,"only replacement value is relayed");json_object_put(event);
  adapter_send(&adapter,"{\"id\":\"race-unsubscribe\",\"op\":\"unsubscribe\",\"subscriptionId\":\"race\"}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"ack"),"replacement unsubscribe");json_object_put(event);adapter_send(&adapter,"{\"id\":\"race-close\",\"op\":\"close\"}");event=adapter_read(&adapter);check(!strcmp(event_type(event),"closed"),"race close");json_object_put(event);fclose(adapter.input);fclose(adapter.output);close(control.dequeued[0]);close(control.resume[1]);close(control.inactive[0]);int status=0;waitpid(adapter.pid,&status,0);check(WIFEXITED(status)&&WEXITSTATUS(status)==0,"race adapter exit");
}

int main(void) {
  fixture server;fixture_start(&server);char url[128];snprintf(url,sizeof(url),"http://127.0.0.1:%d",server.port);convex_error error={0};convex_client *client=convex_new(url,"c-live-fixture",&error);json_object *args=json_object_new_object();json_object_object_add(args,"room",json_object_new_string("fixture"));
  test_http_guards(url);
  convex_subscription *sub=convex_subscribe(client,"demo:state",args,&error);check(sub&&update_count(sub,0,0),"initial fragmented Live update");
  fixture_change(&server,1,0,0,1);check(update_count(sub,1,0),"fragmented UTF-8 update");
  for(int n=1;n<=5;n++){check(convex_debug_disconnect(client,&error),"debug disconnect ack");wait_connections(&server,n+1);check(update_count(sub,1,0),"reconnect update");}
  check(convex_unsubscribe(sub,&error),"unsubscribe");wait_removes(&server,1);pthread_mutex_lock(&server.mutex);int remove_seen=server.remove_seen;pthread_mutex_unlock(&server.mutex);check(remove_seen==1,"exactly one Remove");
  convex_subscription *removed=sub;fixture_configure(&server,0,1,0,0);sub=convex_subscribe(client,"demo:requiresNonzero",args,&error);check(update_count(sub,0,1),"QueryFailed");fixture_change(&server,1,0,0,0);check(update_count(sub,1,0),"same subscription recovery");convex_update stale={0};check(convex_subscription_next(removed,&stale,50)==-1,"removed subscription never receives replacement updates");
  for(int n=2;n<=21;n++)fixture_change(&server,n,0,0,0);
  struct timespec settle={.tv_sec=0,.tv_nsec=100000000L};nanosleep(&settle,NULL);
  check(update_count(sub,6,0),"bounded newest-16 queue drops oldest");
  for(int n=7;n<=21;n++)check(update_count(sub,n,0),"bounded queue preserves newest order");
  for(int malformed=1;malformed<=3;malformed++){int before=fixture_connections(&server);fixture_change(&server,1,0,malformed,0);check(update_count(sub,0,2),malformed==1?"invalid JSON becomes protocol error":malformed==2?"null version timestamp becomes protocol error":"non-string version timestamp becomes protocol error");wait_connections(&server,before+1);check(update_count(sub,1,0),"Live query recovers after malformed Transition");}
  check(convex_unsubscribe(sub,&error),"final unsubscribe");check(convex_close(client,5000,&error),"blocked close completes");convex_free(client);json_object_put(args);test_snapshot_add_race(&server,url);test_adapter_events(&server,url);test_adapter_relay_races(&server,url);fixture_stop(&server);puts("PASS native C Live and adapter fixtures");return 0;
}
