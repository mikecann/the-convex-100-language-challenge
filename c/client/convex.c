#include "convex.h"
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct convex_client { char *url; char *version; char *token; };
struct bytes { char *data; size_t length; };

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
void convex_free(convex_client *c) { if(c){free(c->url);free(c->version);free(c->token);free(c);} }
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
