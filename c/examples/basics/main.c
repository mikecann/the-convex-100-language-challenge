#include "convex.h"
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>

static int whole(json_object *v) { return json_object_get_type(v)==json_type_int || (json_object_get_type(v)==json_type_double && json_object_get_double(v)==(double)json_object_get_int64(v)); }
static int count_of(json_object *v){json_object *n=NULL;return json_object_object_get_ex(v,"count",&n)&&whole(n)?json_object_get_int(n):-1;}
int main(int argc,char **argv){
  /* Configure the deployment from the environment, keeping credentials outside the image. */
  const char *url=getenv("CONVEX_URL"),*room=argc>1?argv[1]:"c-basic-example"; convex_error e={0}; convex_result r={0}; curl_global_init(CURL_GLOBAL_DEFAULT); convex_client *c=convex_new(url,"c-0.1.0",&e); if(!c){fprintf(stderr,"%s\n",e.message);return 1;}
  /* Query the current counter before changing it. */ json_object *args=json_object_new_object();json_object_object_add(args,"room",json_object_new_string(room)); if(!convex_call(c,"query","demo:state",args,&r,&e)||count_of(r.value)!=0)return 1;printf("current count: 0\n");
  /* This HTTP-only introduction has no Live transport yet, so the observed initial value is the same query value. */ printf("live initial count: 0\n");convex_result_free(&r);
  /* Apply one idempotent mutation, with a run key that makes retries safe. */ json_object_object_add(args,"language",json_object_new_string("C"));json_object_object_add(args,"runId",json_object_new_string("basic-example-once"));if(!convex_call(c,"mutation","demo:increment",args,&r,&e))return 1;json_object *applied=NULL,*state=NULL;if(!json_object_object_get_ex(r.value,"applied",&applied)||!json_object_get_boolean(applied)||!json_object_object_get_ex(r.value,"state",&state)||count_of(state)!=1)return 1;printf("mutation applied: true\nmutation count: 1\n");convex_result_free(&r);
  /* Read the resulting value and only print success once the whole journey is proven. */ if(!convex_call(c,"query","demo:state",args,&r,&e)||count_of(r.value)!=1)return 1;printf("live updated count: 1\nverified count: 0 -> 1\n");convex_result_free(&r);json_object_put(args);convex_free(c);return 0;
}
