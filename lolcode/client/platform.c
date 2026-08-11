#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <jansson.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "binding.h"

// This extension deliberately exposes only ordinary runtime primitives.
// Convex request envelopes, response rules, Live state, and adapter behavior
// stay in the checked-in LOLCODE sources.

static ReturnObject *string_result(char *value)
{
    if (!value) value = strdup("");
    return createReturnObject(RT_RETURN, createStringValueObject(value));
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

static ReturnObject *json_escape_wrapper(ScopeObject *scope)
{
    json_t *value = json_string(string_arg(scope, "text"));
    char *encoded = value
        ? json_dumps(value, JSON_COMPACT | JSON_ENSURE_ASCII | JSON_ENCODE_ANY)
        : NULL;
    json_decref(value);
    return string_result(encoded);
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
    loadBinding(library, "NOW", "", now_wrapper);
    loadBinding(library, "SLEEP", "millis", sleep_wrapper);
    loadBinding(library, "RANDOMHEX", "bytes", random_hex_wrapper);
    loadBinding(library, "JSONVALID", "json", json_valid_wrapper);
    loadBinding(library, "JSONESCAPE", "text", json_escape_wrapper);
    return install_library(scope, "TRANSPORT", library);
}
