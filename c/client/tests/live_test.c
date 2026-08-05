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

static void base64(const unsigned char *source, size_t length, char *output) {
  static const char table[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";size_t at=0;
  for(size_t n=0;n<length;n+=3){uint32_t value=(uint32_t)source[n]<<16;if(n+1<length)value|=(uint32_t)source[n+1]<<8;if(n+2<length)value|=source[n+2];output[at++]=table[(value>>18)&63];output[at++]=table[(value>>12)&63];output[at++]=n+1<length?table[(value>>6)&63]:'=';output[at++]=n+2<length?table[value&63]:'=';}output[at]=0;
}

static int handshake(int fd) {
  char request[8192]={0};size_t used=0;
  while(used+1<sizeof(request)&&!strstr(request,"\r\n\r\n")){ssize_t got=recv(fd,request+used,sizeof(request)-used-1,0);if(got<=0)return 0;used+=(size_t)got;request[used]=0;}
  char *key=strstr(request,"Sec-WebSocket-Key:");if(!key)return 0;key+=18;while(*key==' ')key++;char *end=strstr(key,"\r\n");if(!end)return 0;*end=0;
  char joined[256];snprintf(joined,sizeof(joined),"%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",key);unsigned char digest[SHA_DIGEST_LENGTH];SHA1((unsigned char*)joined,strlen(joined),digest);char accept[64];base64(digest,sizeof(digest),accept);
  char response[512];int length=snprintf(response,sizeof(response),"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",accept);return send(fd,response,(size_t)length,0)==length;
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

static void *fixture_thread(void *opaque) {
  fixture *server=opaque;int serial=0;
  while(!server->stop){int fd=accept(server->listener,NULL,NULL);if(fd<0){if(server->stop)break;continue;}if(!handshake(fd)){close(fd);fixture_fail(server,"WebSocket handshake failed");continue;}
    char *text=NULL;if(!read_frame(fd,&text)){close(fd);continue;}json_object *connect=json_tokener_parse(text);free(text);int connection_count=-1;if(!connect||!integer_field(connect,"connectionCount",&connection_count)){if(connect)json_object_put(connect);close(fd);fixture_fail(server,"invalid Connect");continue;}pthread_mutex_lock(&server->mutex);int expected=server->connections++;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);if(connection_count!=expected){json_object_put(connect);close(fd);fixture_fail(server,"connectionCount did not advance exactly");continue;}json_object_put(connect);
    if(!read_frame(fd,&text)){close(fd);continue;}json_object *add=json_tokener_parse(text);free(text);json_object *mods=NULL,*mod=NULL,*field=NULL;int query_id=-1,query_set=0;if(!add||!json_object_object_get_ex(add,"modifications",&mods)||(mod=json_object_array_get_idx(mods,0))==NULL||!json_object_object_get_ex(mod,"type",&field)||strcmp(json_object_get_string(field),"Add")||!integer_field(mod,"queryId",&query_id)||!integer_field(add,"newVersion",&query_set)){if(add)json_object_put(add);close(fd);fixture_fail(server,"invalid Add");continue;}json_object_put(add);
    serial++;char current_ts[64];snprintf(current_ts,sizeof(current_ts),"%010d=",serial);pthread_mutex_lock(&server->mutex);int generation=server->generation,count=server->desired_count,failure=server->desired_failure,fragment=server->desired_fragment;server->sent_generation=generation;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);if(!send_transition(fd,query_id,0,query_set,"AAAAAAAAAAA=",serial,count,failure,fragment)){close(fd);continue;}
    for(;;){pthread_mutex_lock(&server->mutex);int stop=server->stop,new_generation=server->generation,malformed=server->desired_malformed;count=server->desired_count;failure=server->desired_failure;fragment=server->desired_fragment;pthread_mutex_unlock(&server->mutex);if(stop)break;if(new_generation!=generation){generation=new_generation;if(malformed){send_frame(fd,1,1,"{not-json",9);}else{serial++;if(!send_transition(fd,query_id,query_set,query_set,current_ts,serial,count,failure,fragment))break;snprintf(current_ts,sizeof(current_ts),"%010d=",serial);}pthread_mutex_lock(&server->mutex);server->sent_generation=generation;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);}
      struct pollfd poller={.fd=fd,.events=POLLIN};int ready=poll(&poller,1,5);if(ready>0){if(!read_frame(fd,&text))break;json_object *message=json_tokener_parse(text);free(text);json_object *type=NULL;if(message&&json_object_object_get_ex(message,"type",&type)&&!strcmp(json_object_get_string(type),"ModifyQuerySet")){json_object *items=NULL;json_object_object_get_ex(message,"modifications",&items);json_object *item=items?json_object_array_get_idx(items,0):NULL;json_object *kind=NULL;if(item&&json_object_object_get_ex(item,"type",&kind)&&!strcmp(json_object_get_string(kind),"Remove")){pthread_mutex_lock(&server->mutex);server->remove_seen++;pthread_cond_broadcast(&server->changed);pthread_mutex_unlock(&server->mutex);json_object_put(message);break;}}if(message)json_object_put(message);}}
    close(fd);
  }return NULL;
}

static void fixture_start(fixture *server) {memset(server,0,sizeof(*server));pthread_mutex_init(&server->mutex,NULL);pthread_cond_init(&server->changed,NULL);server->listener=socket(AF_INET,SOCK_STREAM,0);int yes=1;setsockopt(server->listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK),.sin_port=0};check(!bind(server->listener,(struct sockaddr*)&address,sizeof(address))&&!listen(server->listener,8),"fixture listen");socklen_t size=sizeof(address);getsockname(server->listener,(struct sockaddr*)&address,&size);server->port=ntohs(address.sin_port);pthread_create(&server->thread,NULL,fixture_thread,server);}
static void fixture_stop(fixture *server){pthread_mutex_lock(&server->mutex);server->stop=1;pthread_mutex_unlock(&server->mutex);shutdown(server->listener,SHUT_RDWR);close(server->listener);pthread_join(server->thread,NULL);check(!server->failed,server->failure);pthread_mutex_destroy(&server->mutex);pthread_cond_destroy(&server->changed);}
static void fixture_change(fixture *server,int count,int failure,int malformed,int fragmented){pthread_mutex_lock(&server->mutex);server->desired_count=count;server->desired_failure=failure;server->desired_malformed=malformed;server->desired_fragment=fragmented;int generation=++server->generation;while(server->sent_generation<generation&&!server->failed)pthread_cond_wait(&server->changed,&server->mutex);pthread_mutex_unlock(&server->mutex);}
static void fixture_configure(fixture *server,int count,int failure,int malformed,int fragmented){pthread_mutex_lock(&server->mutex);server->desired_count=count;server->desired_failure=failure;server->desired_malformed=malformed;server->desired_fragment=fragmented;server->generation++;pthread_mutex_unlock(&server->mutex);}
static void wait_connections(fixture *server,int count){pthread_mutex_lock(&server->mutex);while(server->connections<count&&!server->failed)pthread_cond_wait(&server->changed,&server->mutex);pthread_mutex_unlock(&server->mutex);}
static void wait_removes(fixture *server,int count){pthread_mutex_lock(&server->mutex);while(server->remove_seen<count&&!server->failed)pthread_cond_wait(&server->changed,&server->mutex);pthread_mutex_unlock(&server->mutex);}

static int update_count(convex_subscription *sub,int expected,int expect_error){convex_update update={0};int got=convex_subscription_next(sub,&update,5000);if(got!=1){fprintf(stderr,"update wait returned %d\n",got);return 0;}int okay;if(expect_error==1)okay=update.error.name&&update.error.data;else if(expect_error==2)okay=update.error.name&&!strcmp(update.error.name,"ProtocolError");else{json_object *count=NULL,*text=NULL;okay=!update.error.name&&update.value&&json_object_object_get_ex(update.value,"count",&count)&&json_object_get_int(count)==expected&&json_object_object_get_ex(update.value,"text",&text)&&!strcmp(json_object_get_string(text),"Hello, 世界 👋");}if(!okay)fprintf(stderr,"unexpected update error=%s message=%s value=%s\n",update.error.name?update.error.name:"",update.error.message?update.error.message:"",update.value?json_object_to_json_string(update.value):"null");convex_update_free(&update);return okay;}

int main(void) {
  fixture server;fixture_start(&server);char url[128];snprintf(url,sizeof(url),"http://127.0.0.1:%d",server.port);convex_error error={0};convex_client *client=convex_new(url,"c-live-fixture",&error);json_object *args=json_object_new_object();json_object_object_add(args,"room",json_object_new_string("fixture"));
  convex_subscription *sub=convex_subscribe(client,"demo:state",args,&error);check(sub&&update_count(sub,0,0),"initial fragmented Live update");
  fixture_change(&server,1,0,0,1);check(update_count(sub,1,0),"fragmented UTF-8 update");
  for(int n=1;n<=5;n++){check(convex_debug_disconnect(client,&error),"debug disconnect ack");wait_connections(&server,n+1);check(update_count(sub,1,0),"reconnect update");}
  check(convex_unsubscribe(sub,&error),"unsubscribe");wait_removes(&server,1);pthread_mutex_lock(&server.mutex);int remove_seen=server.remove_seen;pthread_mutex_unlock(&server.mutex);check(remove_seen==1,"exactly one Remove");
  fixture_configure(&server,0,1,0,0);sub=convex_subscribe(client,"demo:requiresNonzero",args,&error);check(update_count(sub,0,1),"QueryFailed");fixture_change(&server,1,0,0,0);check(update_count(sub,1,0),"same subscription recovery");
  for(int n=2;n<=21;n++)fixture_change(&server,n,0,0,0);
  struct timespec settle={.tv_sec=0,.tv_nsec=100000000L};nanosleep(&settle,NULL);
  check(update_count(sub,6,0),"bounded newest-16 queue drops oldest");
  for(int n=7;n<=21;n++)check(update_count(sub,n,0),"bounded queue preserves newest order");
  fixture_change(&server,1,0,1,0);check(update_count(sub,0,2),"malformed server message becomes protocol error");wait_connections(&server,8);
  check(convex_unsubscribe(sub,&error),"final unsubscribe");check(convex_close(client,5000,&error),"blocked close completes");convex_free(client);json_object_put(args);fixture_stop(&server);puts("PASS native C Live fixtures");return 0;
}
