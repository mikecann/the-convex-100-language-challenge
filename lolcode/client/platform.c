#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <curl/curl.h>
#include <jansson.h>
#include <openssl/rand.h>
#include <poll.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "binding.h"

#define MAX_MESSAGE_BYTES (2 * 1024 * 1024)

typedef struct {
    long status;
    char *body;
    size_t length;
    size_t capacity;
    char error[CURL_ERROR_SIZE];
    int overflow;
} HttpResponse;

typedef struct {
    int read_fd;
    int write_fd;
    int listener_fd;
    int owns_fds;
    char *buffer;
    size_t length;
    size_t capacity;
    int last_status;
    char error[256];
} Controller;

// This extension deliberately exposes only ordinary runtime primitives.
// Convex request envelopes, response rules, Live state, and adapter behavior
// stay in the checked-in LOLCODE sources.

static ReturnObject *string_result(char *value)
{
    if (!value) value = strdup("");

    // lci treats ':' as its string escape prefix whenever a value crosses an
    // expression boundary. External bytes are data, so double literal colons
    // here and let lci decode them once. Without this, JSON object separators,
    // URLs, and Convex function names silently lose their colons.
    size_t length = strlen(value);
    size_t colons = 0;
    for (size_t i = 0; i < length; i++) {
        if (value[i] == ':') colons++;
    }
    char *escaped = malloc(length + colons + 1);
    if (!escaped) {
        free(value);
        return NULL;
    }
    size_t output = 0;
    for (size_t i = 0; i < length; i++) {
        escaped[output++] = value[i];
        if (value[i] == ':') escaped[output++] = ':';
    }
    escaped[output] = '\0';
    free(value);
    return createReturnObject(RT_RETURN, createStringValueObject(escaped));
}

static ReturnObject *integer_result(long long value)
{
    return createReturnObject(RT_RETURN, createIntegerValueObject(value));
}

static ReturnObject *boolean_result(int value)
{
    return createReturnObject(RT_RETURN, createBooleanValueObject(value != 0));
}

static char *string_arg(ScopeObject *scope, const char *name)
{
    ValueObject *value = getArg(scope, (char *)name);
    return getString(castStringImplicit(value, scope));
}

static ReturnObject *env_wrapper(ScopeObject *scope)
{
    const char *value = getenv(string_arg(scope, "name"));
    return string_result(strdup(value ? value : ""));
}

static ReturnObject *stderr_wrapper(ScopeObject *scope)
{
    fputs(string_arg(scope, "message"), stderr);
    fputc('\n', stderr);
    return createReturnObject(RT_DEFAULT, NULL);
}

static ReturnObject *abort_wrapper(ScopeObject *scope)
{
    fputs(string_arg(scope, "message"), stderr);
    fputc('\n', stderr);
    fflush(stderr);
    exit(EXIT_FAILURE);
}

static ReturnObject *now_wrapper(ScopeObject *scope)
{
    (void)scope;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long long millis = (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    return createReturnObject(RT_RETURN, createIntegerValueObject(millis));
}

static ReturnObject *sleep_wrapper(ScopeObject *scope)
{
    long long millis = getInteger(getArg(scope, "millis"));
    if (millis < 0) millis = 0;
    struct timespec delay = { millis / 1000, (millis % 1000) * 1000000 };
    while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
    return createReturnObject(RT_DEFAULT, NULL);
}

static ReturnObject *random_hex_wrapper(ScopeObject *scope)
{
    long long count = getInteger(getArg(scope, "bytes"));
    if (count < 1 || count > 64) return string_result(strdup(""));
    unsigned char bytes[64];
    if (RAND_bytes(bytes, (int)count) != 1) return string_result(strdup(""));
    char *hex = malloc((size_t)count * 2 + 1);
    if (!hex) return string_result(NULL);
    for (long long i = 0; i < count; i++) sprintf(hex + i * 2, "%02x", bytes[i]);
    return string_result(hex);
}

static ReturnObject *json_valid_wrapper(ScopeObject *scope)
{
    json_error_t error;
    json_t *value = json_loads(
        string_arg(scope, "json"), JSON_REJECT_DUPLICATES | JSON_DECODE_ANY, &error);
    int valid = value != NULL;
    json_decref(value);
    return createReturnObject(RT_RETURN, createBooleanValueObject(valid));
}

static json_t *parse_json_any(const char *source)
{
    json_error_t error;
    return json_loads(source, JSON_REJECT_DUPLICATES | JSON_DECODE_ANY, &error);
}

static char *dump_json_any(json_t *value)
{
    if (!value) return strdup("");
    return json_dumps(value, JSON_COMPACT | JSON_ENSURE_ASCII | JSON_ENCODE_ANY);
}

static ReturnObject *json_has_wrapper(ScopeObject *scope)
{
    json_t *root = parse_json_any(string_arg(scope, "json"));
    const char *key = string_arg(scope, "key");
    int result = root && json_is_object(root) && json_object_get(root, key) != NULL;
    json_decref(root);
    return boolean_result(result);
}

static ReturnObject *json_get_wrapper(ScopeObject *scope)
{
    json_t *root = parse_json_any(string_arg(scope, "json"));
    const char *key = string_arg(scope, "key");
    char *result = NULL;
    if (root && json_is_object(root)) result = dump_json_any(json_object_get(root, key));
    json_decref(root);
    return string_result(result);
}

static ReturnObject *json_type_wrapper(ScopeObject *scope)
{
    json_t *value = parse_json_any(string_arg(scope, "json"));
    const char *kind = "invalid";
    if (json_is_object(value)) kind = "object";
    else if (json_is_array(value)) kind = "array";
    else if (json_is_string(value)) kind = "string";
    else if (json_is_integer(value) || json_is_real(value)) kind = "number";
    else if (json_is_true(value) || json_is_false(value)) kind = "boolean";
    else if (json_is_null(value)) kind = "null";
    json_decref(value);
    return string_result(strdup(kind));
}

static ReturnObject *json_string_wrapper(ScopeObject *scope)
{
    json_t *value = parse_json_any(string_arg(scope, "json"));
    char *result = json_is_string(value) ? strdup(json_string_value(value)) : strdup("");
    json_decref(value);
    return string_result(result);
}

static ReturnObject *json_array_len_wrapper(ScopeObject *scope)
{
    json_t *value = parse_json_any(string_arg(scope, "json"));
    long long result = json_is_array(value) ? (long long)json_array_size(value) : -1;
    json_decref(value);
    return integer_result(result);
}

static ReturnObject *json_array_at_wrapper(ScopeObject *scope)
{
    json_t *value = parse_json_any(string_arg(scope, "json"));
    long long index = getInteger(getArg(scope, "index"));
    char *result = NULL;
    if (json_is_array(value) && index >= 0)
        result = dump_json_any(json_array_get(value, (size_t)index));
    json_decref(value);
    return string_result(result);
}

static ReturnObject *json_equal_wrapper(ScopeObject *scope)
{
    json_t *left = parse_json_any(string_arg(scope, "left"));
    json_t *right = parse_json_any(string_arg(scope, "right"));
    int equal = left && right && json_equal(left, right);
    json_decref(left);
    json_decref(right);
    return boolean_result(equal);
}

static ReturnObject *json_set_wrapper(ScopeObject *scope)
{
    json_t *root = parse_json_any(string_arg(scope, "json"));
    const char *key = string_arg(scope, "key");
    json_t *value = parse_json_any(string_arg(scope, "value"));
    char *result = NULL;
    if (json_is_object(root) && value && json_object_set(root, key, value) == 0)
        result = dump_json_any(root);
    json_decref(root);
    json_decref(value);
    return string_result(result);
}

static ReturnObject *json_append_wrapper(ScopeObject *scope)
{
    json_t *root = parse_json_any(string_arg(scope, "json"));
    json_t *value = parse_json_any(string_arg(scope, "value"));
    char *result = NULL;
    if (json_is_array(root) && value && json_array_append(root, value) == 0)
        result = dump_json_any(root);
    json_decref(root);
    json_decref(value);
    return string_result(result);
}

static ReturnObject *json_integer_wrapper(ScopeObject *scope)
{
    json_t *value = parse_json_any(string_arg(scope, "json"));
    char buffer[64] = "";
    if (json_is_integer(value)) {
        snprintf(buffer, sizeof buffer, "%lld", (long long)json_integer_value(value));
    } else if (json_is_real(value)) {
        double number = json_real_value(value);
        long long integer = (long long)number;
        if ((double)integer == number)
            snprintf(buffer, sizeof buffer, "%lld", integer);
    }
    json_decref(value);
    return string_result(strdup(buffer));
}

static ReturnObject *json_escape_wrapper(ScopeObject *scope)
{
    json_t *value = json_string(string_arg(scope, "text"));
    char *encoded = value
        ? json_dumps(value, JSON_COMPACT | JSON_ENSURE_ASCII | JSON_ENCODE_ANY)
        : NULL;
    json_decref(value);
    return string_result(encoded);
}

static int reserve_bytes(char **buffer, size_t *capacity, size_t required)
{
    if (required > MAX_MESSAGE_BYTES + 1) return 0;
    if (*capacity >= required) return 1;
    size_t next = *capacity ? *capacity : 4096;
    while (next < required) next *= 2;
    if (next > MAX_MESSAGE_BYTES + 1) next = MAX_MESSAGE_BYTES + 1;
    char *grown = realloc(*buffer, next);
    if (!grown) return 0;
    *buffer = grown;
    *capacity = next;
    return 1;
}

static size_t http_receive(char *data, size_t width, size_t count, void *opaque)
{
    HttpResponse *response = opaque;
    size_t incoming = width * count;
    if (incoming > MAX_MESSAGE_BYTES || response->length > MAX_MESSAGE_BYTES - incoming ||
        !reserve_bytes(&response->body, &response->capacity, response->length + incoming + 1)) {
        response->overflow = 1;
        return 0;
    }
    memcpy(response->body + response->length, data, incoming);
    response->length += incoming;
    response->body[response->length] = '\0';
    return incoming;
}

static ReturnObject *http_wrapper(ScopeObject *scope)
{
    const char *method = string_arg(scope, "method");
    const char *url = string_arg(scope, "url");
    const char *headers_json = string_arg(scope, "headers");
    const char *body = string_arg(scope, "body");
    long long timeout = getInteger(getArg(scope, "timeout"));
    HttpResponse *response = calloc(1, sizeof *response);
    CURL *curl = curl_easy_init();
    struct curl_slist *headers = NULL;
    json_t *header_values = parse_json_any(headers_json);
    if (!response || !curl || !json_is_object(header_values)) goto invalid;

    const char *key;
    json_t *value;
    json_object_foreach(header_values, key, value) {
        if (!json_is_string(value)) goto invalid;
        size_t needed = strlen(key) + json_string_length(value) + 3;
        char *line = malloc(needed);
        if (!line) goto invalid;
        snprintf(line, needed, "%s: %s", key, json_string_value(value));
        headers = curl_slist_append(headers, line);
        free(line);
        if (!headers) goto invalid;
    }

    response->error[0] = '\0';
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(body));
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, http_receive);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, response);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, response->error);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, timeout > 0 ? timeout : 15000);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, timeout > 0 ? timeout : 15000);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_CAINFO, "/etc/ssl/certs/ca-certificates.crt");
    curl_easy_setopt(curl, CURLOPT_NOPROXY, "*");
    CURLcode result = curl_easy_perform(curl);
    if (result != CURLE_OK && !response->error[0])
        snprintf(response->error, sizeof response->error, "%s", curl_easy_strerror(result));
    if (response->overflow)
        snprintf(response->error, sizeof response->error, "HTTP response exceeds 2 MiB");
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response->status);
    if (!response->body) response->body = strdup("");
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    json_decref(header_values);
    return createReturnObject(RT_RETURN, createBlobValueObject(response));

invalid:
    if (response) snprintf(response->error, sizeof response->error, "invalid HTTP arguments");
    curl_slist_free_all(headers);
    if (curl) curl_easy_cleanup(curl);
    json_decref(header_values);
    if (!response) response = calloc(1, sizeof *response);
    return createReturnObject(RT_RETURN, createBlobValueObject(response));
}

static HttpResponse *http_arg(ScopeObject *scope)
{
    return (HttpResponse *)getBlob(getArg(scope, "response"));
}

static ReturnObject *http_status_wrapper(ScopeObject *scope)
{
    HttpResponse *response = http_arg(scope);
    return integer_result(response ? response->status : 0);
}

static ReturnObject *http_body_wrapper(ScopeObject *scope)
{
    HttpResponse *response = http_arg(scope);
    return string_result(strdup(response && response->body ? response->body : ""));
}

static ReturnObject *http_error_wrapper(ScopeObject *scope)
{
    HttpResponse *response = http_arg(scope);
    return string_result(strdup(response ? response->error : "invalid response"));
}

static ReturnObject *http_free_wrapper(ScopeObject *scope)
{
    HttpResponse *response = http_arg(scope);
    if (response) {
        free(response->body);
        free(response);
    }
    return createReturnObject(RT_DEFAULT, NULL);
}

static int install_library(ScopeObject *scope, const char *name, ScopeObject *library)
{
    IdentifierNode *id = createIdentifierNode(IT_DIRECT, copyString((char *)name), NULL, NULL, 0);
    if (!id || !createScopeValue(scope, scope, id)) return 0;
    ValueObject *value = createArrayValueObject(library);
    if (!value || !updateScopeValue(scope, scope, id, value)) return 0;
    deleteIdentifierNode(id);
    return 1;
}

int loadTransportLibrary(ScopeObject *scope)
{
    ScopeObject *library = createScopeObject(scope);
    if (!library) return 0;
    loadBinding(library, "ENV", "name", env_wrapper);
    loadBinding(library, "DIAG", "message", stderr_wrapper);
    loadBinding(library, "ABORT", "message", abort_wrapper);
    loadBinding(library, "NOW", "", now_wrapper);
    loadBinding(library, "SLEEP", "millis", sleep_wrapper);
    loadBinding(library, "RANDOMHEX", "bytes", random_hex_wrapper);
    loadBinding(library, "JSONVALID", "json", json_valid_wrapper);
    loadBinding(library, "JSONESCAPE", "text", json_escape_wrapper);
    loadBinding(library, "JSONHAS", "json key", json_has_wrapper);
    loadBinding(library, "JSONGET", "json key", json_get_wrapper);
    loadBinding(library, "JSONTYPE", "json", json_type_wrapper);
    loadBinding(library, "JSONSTRING", "json", json_string_wrapper);
    loadBinding(library, "JSONARRAYLEN", "json", json_array_len_wrapper);
    loadBinding(library, "JSONARRAYAT", "json index", json_array_at_wrapper);
    loadBinding(library, "JSONEQUAL", "left right", json_equal_wrapper);
    loadBinding(library, "JSONSET", "json key value", json_set_wrapper);
    loadBinding(library, "JSONAPPEND", "json value", json_append_wrapper);
    loadBinding(library, "JSONINTEGER", "json", json_integer_wrapper);
    loadBinding(library, "HTTP", "method url headers body timeout", http_wrapper);
    loadBinding(library, "HTTPSTATUS", "response", http_status_wrapper);
    loadBinding(library, "HTTPBODY", "response", http_body_wrapper);
    loadBinding(library, "HTTPERROR", "response", http_error_wrapper);
    loadBinding(library, "HTTPFREE", "response", http_free_wrapper);
    return install_library(scope, "TRANSPORT", library);
}
