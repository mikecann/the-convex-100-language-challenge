#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "convex_transport.h"

#include <arpa/inet.h>
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <math.h>
#include <netdb.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CT_MAX_HTTP (2u * 1024u * 1024u)
#define CT_MAX_WS (2u * 1024u * 1024u)

struct buffer {
  char *data;
  size_t length;
  size_t capacity;
};

struct chapel_ws {
  CURL *curl;
  struct buffer partial;
  int partial_text;
  int64_t frame_deadline_ms;
  int may_have_internal;
  int interrupted;
  int64_t last_yield_ms;
};

struct websocket_handshake {
  int saw_upgrade;
  int saw_connection_upgrade;
  char accept[128];
  size_t accept_length;
};

// Provided by the Chapel runtime (runtime/include/chpl-tasks.h) and linked
// into every Chapel executable; declared directly here rather than
// including that header to avoid pulling in its other runtime-internal
// dependencies for the one function this file needs. A qthreads worker
// that spends its whole turn inside an extern/FFI call -- even one that
// is itself blocked in a real kernel wait, such as poll(2) -- never hands
// control back to the Chapel scheduler on its own: measured directly,
// nothing else runs on this program's other qthreads tasks until this
// call is made, no matter how short the C-side wait is bounded to.
// ct_read_line's poll loop below calls this after every timed-out poll so
// the adapter's bounded output-writer task actually gets scheduled.
extern void chpl_task_yield(void);

static char *copy_string(const char *value);
static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static pthread_once_t interrupt_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t reader_lock = PTHREAD_MUTEX_INITIALIZER;
static int reader_fd = -1;
static atomic_int reader_interrupted;
static int interrupt_pipe_read = -1;
static int interrupt_pipe_write = -1;

static void initialize_curl(void) {
  (void)curl_global_init(CURL_GLOBAL_DEFAULT);
}

static int curl_is_ready(void) {
  return pthread_once(&curl_once, initialize_curl) == 0;
}

// The libcurl build this binary links against (libcurl4-openssl-dev on
// Debian) is configured with a fixed default CAfile/CApath baked in at
// compile time. That default never consults OpenSSL's usual SSL_CERT_FILE
// / SSL_CERT_DIR environment variables, so operators (and this project's
// own test fixtures) cannot point the client at a private trust root
// without this explicit opt-in. Honoring these two conventional variables
// keeps the sensible system default when they are unset.
static void apply_environment_ca_trust(CURL *curl) {
  const char *cert_file = getenv("SSL_CERT_FILE");
  if (cert_file && *cert_file)
    curl_easy_setopt(curl, CURLOPT_CAINFO, cert_file);
  const char *cert_dir = getenv("SSL_CERT_DIR");
  if (cert_dir && *cert_dir)
    curl_easy_setopt(curl, CURLOPT_CAPATH, cert_dir);
}

// ct_read_line's blocked reader is woken by a write to this self-pipe (the
// classic self-pipe trick) rather than by a signal: poll(2) can watch the
// pipe's read end directly alongside the fd being read, so one poll loop
// covers both "new input arrived" and "interrupted" without racing a
// signal handler against the moment the thread actually enters the
// blocking call. Errors here are deliberately swallowed: if pipe(2) or
// fcntl(2) fails, reader_interrupted (checked every poll iteration) is
// still a correct, if slower, fallback.
static void initialize_interrupt(void) {
  int descriptors[2];
  if (pipe(descriptors) != 0)
    return;
  (void)fcntl(descriptors[0], F_SETFL,
             fcntl(descriptors[0], F_GETFL, 0) | O_NONBLOCK);
  (void)fcntl(descriptors[1], F_SETFL,
             fcntl(descriptors[1], F_GETFL, 0) | O_NONBLOCK);
  interrupt_pipe_read = descriptors[0];
  interrupt_pipe_write = descriptors[1];
}

void ct_free(void *value) { free(value); }

char *ct_getenv_copy(const char *name) {
  const char *value = getenv(name);
  return copy_string(value ? value : "");
}

int64_t ct_monotonic_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static char *copy_string(const char *value) {
  size_t length = strlen(value) + 1;
  char *copy = malloc(length);
  if (copy)
    memcpy(copy, value, length);
  return copy;
}

static void set_error(char **target, const char *message) {
  if (target)
    *target = copy_string(message ? message : "unknown transport error");
}

static int append(struct buffer *buffer, const void *data, size_t length,
                  size_t limit) {
  if (length > limit || buffer->length > limit - length)
    return 0;
  size_t wanted = buffer->length + length + 1;
  if (wanted > buffer->capacity) {
    size_t capacity = buffer->capacity ? buffer->capacity : 4096;
    while (capacity < wanted && capacity <= limit / 2)
      capacity *= 2;
    if (capacity < wanted)
      capacity = wanted;
    char *next = realloc(buffer->data, capacity);
    if (!next)
      return 0;
    buffer->data = next;
    buffer->capacity = capacity;
  }
  memcpy(buffer->data + buffer->length, data, length);
  buffer->length += length;
  buffer->data[buffer->length] = '\0';
  return 1;
}

static int valid_utf8(const unsigned char *value, size_t length) {
  size_t index = 0;
  while (index < length) {
    unsigned char first = value[index++];
    if (first < 0x80)
      continue;
    size_t continuation;
    uint32_t codepoint;
    if (first >= 0xc2 && first <= 0xdf) {
      continuation = 1;
      codepoint = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
      continuation = 2;
      codepoint = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      continuation = 3;
      codepoint = first & 0x07;
    } else {
      return 0;
    }
    if (continuation > length - index)
      return 0;
    for (size_t offset = 0; offset < continuation; offset++) {
      unsigned char next = value[index++];
      if ((next & 0xc0) != 0x80)
        return 0;
      codepoint = (codepoint << 6) | (next & 0x3f);
    }
    if ((continuation == 2 && codepoint < 0x800) ||
        (continuation == 3 && codepoint < 0x10000) ||
        codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff))
      return 0;
  }
  return 1;
}

static int valid_text_boundary(const char *value, size_t length) {
  // A zero-length span is trivially valid text even when the caller's
  // buffer pointer is NULL: Chapel's empty string ("") does not always
  // allocate a backing buffer, so c_str() can legitimately return NULL
  // for a value whose length is zero. Only a non-empty span needs an
  // actual buffer to inspect.
  if (length == 0) return 1;
  return value && value[length] == '\0' && !memchr(value, '\0', length) &&
         valid_utf8((const unsigned char *)value, length);
}

int ct_valid_text_boundary(const char *value, size_t length) {
  return valid_text_boundary(value, length);
}

void ct_random_uuid(char output[37]) {
  unsigned char raw[16];
  int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  ssize_t got = fd >= 0 ? read(fd, raw, sizeof(raw)) : -1;
  if (fd >= 0)
    close(fd);
  if (got != (ssize_t)sizeof(raw)) {
    uint64_t seed = (uint64_t)ct_monotonic_ms() ^ (uintptr_t)output;
    for (size_t index = 0; index < sizeof(raw); index++) {
      seed = seed * UINT64_C(6364136223846793005) + 1;
      raw[index] = (unsigned char)(seed >> 32);
    }
  }
  raw[6] = (raw[6] & 0x0f) | 0x40;
  raw[8] = (raw[8] & 0x3f) | 0x80;
  snprintf(output, 37,
           "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
           "%02x%02x%02x%02x%02x%02x",
           raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14],
           raw[15]);
}

char *ct_json_quote(const char *value) {
  json_object *string = json_object_new_string(value ? value : "");
  if (!string)
    return NULL;
  char *result = copy_string(
      json_object_to_json_string_ext(string, JSON_C_TO_STRING_PLAIN));
  json_object_put(string);
  return result;
}

char *ct_deployment_url(const char *value, int websocket) {
  if (!value) return NULL;
  const char *rest;
  const char *scheme;
  if (!strncmp(value, "https://", 8)) {
    rest = value + 8;
    scheme = websocket ? "wss://" : "https://";
  } else if (!strncmp(value, "http://", 7)) {
    rest = value + 7;
    scheme = websocket ? "ws://" : "http://";
  } else {
    return NULL;
  }
  const char *authority_end = strpbrk(rest, "/?#");
  size_t authority_length = authority_end ? (size_t)(authority_end - rest)
                                          : strlen(rest);
  if (!authority_length || memchr(rest, '@', authority_length) ||
      strchr(rest, '?') || strchr(rest, '#'))
    return NULL;
  if (authority_end) {
    for (const char *cursor = authority_end; *cursor; cursor++)
      if (*cursor != '/')
        return NULL;
  }
  size_t rest_length = strlen(rest);
  while (rest_length && rest[rest_length - 1] == '/') rest_length--;
  const char *suffix = websocket ? "/api/sync" : "";
  size_t length = strlen(scheme) + rest_length + strlen(suffix) + 1;
  char *result = malloc(length);
  if (!result) return NULL;
  snprintf(result, length, "%s%.*s%s", scheme, (int)rest_length, rest, suffix);
  return result;
}

static json_object *parse_json(const char *json) {
  if (!json)
    return NULL;
  json_tokener *tokener = json_tokener_new();
  if (!tokener)
    return NULL;
  json_object *value = json_tokener_parse_ex(tokener, json, (int)strlen(json));
  enum json_tokener_error error = json_tokener_get_error(tokener);
  size_t offset = json_tokener_get_parse_end(tokener);
  while (json[offset] == ' ' || json[offset] == '\t' || json[offset] == '\r' ||
         json[offset] == '\n')
    offset++;
  if (error != json_tokener_success || json[offset] != '\0') {
    if (value)
      json_object_put(value);
    value = NULL;
  }
  json_tokener_free(tokener);
  return value;
}

int ct_json_is_object(const char *json) {
  json_object *value = parse_json(json);
  int result = value && json_object_get_type(value) == json_type_object;
  if (value)
    json_object_put(value);
  return result;
}

static int get_field(const char *json, const char *field, json_object **root,
                     json_object **value) {
  *root = parse_json(json);
  if (!*root || json_object_get_type(*root) != json_type_object)
    return 0;
  return json_object_object_get_ex(*root, field, value);
}

int ct_json_get_raw(const char *json, const char *field, char **output) {
  json_object *root = NULL, *value = NULL;
  if (!get_field(json, field, &root, &value)) {
    if (root)
      json_object_put(root);
    return 0;
  }
  const char *raw = value ? json_object_to_json_string_ext(
                                value, JSON_C_TO_STRING_PLAIN)
                          : "null";
  *output = copy_string(raw);
  json_object_put(root);
  return *output ? 1 : -1;
}

int ct_json_get_string(const char *json, const char *field, char **output) {
  json_object *root = NULL, *value = NULL;
  if (!get_field(json, field, &root, &value) || !value ||
      json_object_get_type(value) != json_type_string) {
    if (root)
      json_object_put(root);
    return 0;
  }
  const char *text = json_object_get_string(value);
  size_t length = (size_t)json_object_get_string_len(value);
  if (memchr(text, '\0', length)) {
    json_object_put(root);
    return -1;
  }
  *output = malloc(length + 1);
  if (*output) {
    memcpy(*output, text, length);
    (*output)[length] = '\0';
  }
  json_object_put(root);
  return *output ? 1 : -1;
}

int ct_json_get_uint32(const char *json, const char *field, uint32_t *output) {
  json_object *root = NULL, *value = NULL;
  if (!get_field(json, field, &root, &value) || !value ||
      json_object_get_type(value) != json_type_int) {
    if (root)
      json_object_put(root);
    return 0;
  }
  int64_t number = json_object_get_int64(value);
  json_object_put(root);
  if (number < 0 || number > UINT32_MAX)
    return 0;
  *output = (uint32_t)number;
  return 1;
}

int ct_json_array_length(const char *json, const char *field) {
  json_object *root = NULL, *value = NULL;
  if (!get_field(json, field, &root, &value) || !value ||
      json_object_get_type(value) != json_type_array) {
    if (root)
      json_object_put(root);
    return -1;
  }
  int length = (int)json_object_array_length(value);
  json_object_put(root);
  return length;
}

int ct_json_array_raw(const char *json, const char *field, int index,
                      char **output) {
  json_object *root = NULL, *array = NULL;
  if (!get_field(json, field, &root, &array) || !array || index < 0 ||
      json_object_get_type(array) != json_type_array ||
      (size_t)index >= json_object_array_length(array)) {
    if (root)
      json_object_put(root);
    return 0;
  }
  json_object *value = json_object_array_get_idx(array, (size_t)index);
  const char *raw = value ? json_object_to_json_string_ext(
                                value, JSON_C_TO_STRING_PLAIN)
                          : "null";
  *output = copy_string(raw);
  json_object_put(root);
  return *output ? 1 : -1;
}

int ct_json_get_string_array(const char *json, const char *field,
                             char **output) {
  json_object *root = NULL, *array = NULL;
  if (!get_field(json, field, &root, &array)) {
    if (root)
      json_object_put(root);
    return 0;
  }
  if (!array || json_object_get_type(array) != json_type_array) {
    json_object_put(root);
    return -1;
  }
  size_t length = json_object_array_length(array);
  for (size_t index = 0; index < length; index++) {
    json_object *entry = json_object_array_get_idx(array, index);
    if (!entry || json_object_get_type(entry) != json_type_string) {
      json_object_put(root);
      return -1;
    }
  }
  *output = copy_string(
      json_object_to_json_string_ext(array, JSON_C_TO_STRING_PLAIN));
  json_object_put(root);
  return *output ? 1 : -1;
}

int ct_json_equal(const char *left, const char *right) {
  json_object *a = parse_json(left), *b = parse_json(right);
  int equal = a && b && json_object_equal(a, b);
  if (a)
    json_object_put(a);
  if (b)
    json_object_put(b);
  return equal;
}

/* Parse a JSON decimal lexeme exactly. Floating-point conversion would accept
 * out-of-range values after rounding, which is precisely what the teaching
 * example is meant to reject. */
static int decimal_to_int64(const char *text, int64_t *output) {
  const char *cursor = text;
  int negative = *cursor == '-';
  if (negative)
    cursor++;
  const char *integer = cursor;
  if (*cursor == '0') {
    cursor++;
  } else {
    if (*cursor < '1' || *cursor > '9')
      return 0;
    while (*cursor >= '0' && *cursor <= '9')
      cursor++;
  }
  size_t integer_digits = (size_t)(cursor - integer);
  const char *fraction = NULL;
  size_t fraction_digits = 0;
  if (*cursor == '.') {
    fraction = ++cursor;
    while (*cursor >= '0' && *cursor <= '9')
      cursor++;
    fraction_digits = (size_t)(cursor - fraction);
    if (!fraction_digits)
      return 0;
  }
  int exponent = 0;
  if (*cursor == 'e' || *cursor == 'E') {
    cursor++;
    int exponent_negative = *cursor == '-';
    if (*cursor == '-' || *cursor == '+')
      cursor++;
    if (*cursor < '0' || *cursor > '9')
      return 0;
    while (*cursor >= '0' && *cursor <= '9') {
      if (exponent < 1000)
        exponent = exponent * 10 + (*cursor - '0');
      cursor++;
    }
    if (exponent_negative)
      exponent = -exponent;
  }
  if (*cursor != '\0')
    return 0;

  size_t all_length = integer_digits + fraction_digits;
  char *digits = malloc(all_length + 1);
  if (!digits)
    return 0;
  memcpy(digits, integer, integer_digits);
  if (fraction_digits)
    memcpy(digits + integer_digits, fraction, fraction_digits);
  digits[all_length] = '\0';
  long scale = (long)exponent - (long)fraction_digits;
  size_t first_digit = 0;
  while (first_digit < all_length && digits[first_digit] == '0')
    first_digit++;
  size_t significant_length = all_length - first_digit;
  while (scale < 0 && significant_length &&
         digits[first_digit + significant_length - 1] == '0') {
    significant_length--;
    scale++;
  }
  if (!significant_length) {
    free(digits);
    *output = 0;
    return 1;
  }
  if (scale < 0) {
    free(digits);
    return 0;
  }
  if (scale > 19 || significant_length + (size_t)scale > 19) {
    free(digits);
    return 0;
  }
  uint64_t magnitude = 0;
  for (size_t index = 0; index < significant_length; index++)
    magnitude = magnitude * 10 +
                (uint64_t)(digits[first_digit + index] - '0');
  for (long index = 0; index < scale; index++)
    magnitude *= 10;
  free(digits);
  uint64_t limit = negative ? UINT64_C(9223372036854775808)
                            : UINT64_C(9223372036854775807);
  if (magnitude > limit)
    return 0;
  if (negative && magnitude == UINT64_C(9223372036854775808))
    *output = INT64_MIN;
  else
    *output = negative ? -(int64_t)magnitude : (int64_t)magnitude;
  return 1;
}

static const char *skip_space(const char *cursor) {
  while (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' ||
         *cursor == '\n')
    cursor++;
  return cursor;
}

static int hex_digit(unsigned char value) {
  return (value >= '0' && value <= '9') ||
         (value >= 'a' && value <= 'f') ||
         (value >= 'A' && value <= 'F');
}

static const char *skip_json_string_token(const char *cursor) {
  if (*cursor++ != '"')
    return NULL;
  while (*cursor) {
    unsigned char value = (unsigned char)*cursor++;
    if (value == '"')
      return cursor;
    if (value < 0x20)
      return NULL;
    if (value != '\\')
      continue;
    unsigned char escape = (unsigned char)*cursor++;
    if (escape == 'u') {
      for (int index = 0; index < 4; index++)
        if (!hex_digit((unsigned char)*cursor++))
          return NULL;
    } else if (!strchr("\"\\/bfnrt", escape)) {
      return NULL;
    }
  }
  return NULL;
}

static const char *skip_json_number_token(const char *cursor) {
  if (*cursor == '-')
    cursor++;
  if (*cursor == '0') {
    cursor++;
  } else {
    if (*cursor < '1' || *cursor > '9')
      return NULL;
    while (*cursor >= '0' && *cursor <= '9')
      cursor++;
  }
  if (*cursor == '.') {
    cursor++;
    if (*cursor < '0' || *cursor > '9')
      return NULL;
    while (*cursor >= '0' && *cursor <= '9')
      cursor++;
  }
  if (*cursor == 'e' || *cursor == 'E') {
    cursor++;
    if (*cursor == '+' || *cursor == '-')
      cursor++;
    if (*cursor < '0' || *cursor > '9')
      return NULL;
    while (*cursor >= '0' && *cursor <= '9')
      cursor++;
  }
  return cursor;
}

static const char *skip_json_value(const char *cursor, int depth) {
  if (depth > 128)
    return NULL;
  cursor = skip_space(cursor);
  if (*cursor == '"')
    return skip_json_string_token(cursor);
  if (*cursor == '-' || (*cursor >= '0' && *cursor <= '9'))
    return skip_json_number_token(cursor);
  if (!strncmp(cursor, "true", 4))
    return cursor + 4;
  if (!strncmp(cursor, "false", 5))
    return cursor + 5;
  if (!strncmp(cursor, "null", 4))
    return cursor + 4;
  if (*cursor == '[') {
    cursor = skip_space(cursor + 1);
    if (*cursor == ']')
      return cursor + 1;
    for (;;) {
      cursor = skip_json_value(cursor, depth + 1);
      if (!cursor)
        return NULL;
      cursor = skip_space(cursor);
      if (*cursor == ']')
        return cursor + 1;
      if (*cursor++ != ',')
        return NULL;
    }
  }
  if (*cursor == '{') {
    cursor = skip_space(cursor + 1);
    if (*cursor == '}')
      return cursor + 1;
    for (;;) {
      cursor = skip_json_string_token(cursor);
      if (!cursor || *skip_space(cursor) != ':')
        return NULL;
      cursor = skip_json_value(skip_space(cursor) + 1, depth + 1);
      if (!cursor)
        return NULL;
      cursor = skip_space(cursor);
      if (*cursor == '}')
        return cursor + 1;
      if (*cursor++ != ',')
        return NULL;
      cursor = skip_space(cursor);
    }
  }
  return NULL;
}

static int json_key_equals(const char *start, const char *end,
                           const char *field) {
  size_t length = (size_t)(end - start);
  char *encoded = malloc(length + 1);
  if (!encoded)
    return 0;
  memcpy(encoded, start, length);
  encoded[length] = '\0';
  json_object *key = parse_json(encoded);
  free(encoded);
  size_t field_length = strlen(field);
  int equal = key && json_object_get_type(key) == json_type_string &&
              (size_t)json_object_get_string_len(key) == field_length &&
              !memcmp(json_object_get_string(key), field, field_length);
  if (key)
    json_object_put(key);
  return equal;
}

static int find_top_level_field(const char *json, const char *field,
                                const char **value_start,
                                const char **value_end) {
  const char *cursor = skip_space(json);
  if (*cursor++ != '{')
    return 0;
  cursor = skip_space(cursor);
  int found = 0;
  while (*cursor && *cursor != '}') {
    const char *key_start = cursor;
    const char *key_end = skip_json_string_token(cursor);
    if (!key_end)
      return 0;
    cursor = skip_space(key_end);
    if (*cursor++ != ':')
      return 0;
    cursor = skip_space(cursor);
    const char *start = cursor;
    const char *end = skip_json_value(cursor, 1);
    if (!end)
      return 0;
    if (json_key_equals(key_start, key_end, field)) {
      *value_start = start;
      *value_end = end;
      found = 1;
    }
    cursor = skip_space(end);
    if (*cursor == '}')
      break;
    if (*cursor++ != ',')
      return 0;
    cursor = skip_space(cursor);
  }
  return found;
}

int ct_json_integral_field(const char *json, const char *field,
                           int64_t *output) {
  json_object *root = parse_json(json);
  if (!root || json_object_get_type(root) != json_type_object) {
    if (root) json_object_put(root);
    return 0;
  }
  json_object_put(root);
  const char *start = NULL, *end = NULL;
  if (!find_top_level_field(json, field, &start, &end))
    return 0;
  size_t length = (size_t)(end - start);
  char *lexeme = malloc(length + 1);
  if (!lexeme)
    return 0;
  memcpy(lexeme, start, length);
  lexeme[length] = '\0';
  int result = decimal_to_int64(lexeme, output);
  free(lexeme);
  return result;
}

static int utf8_scalar_count(const char *value, size_t maximum,
                             int require_nonblank) {
  const unsigned char *bytes = (const unsigned char *)value;
  size_t length = strlen(value), index = 0, count = 0;
  int nonblank = 0;
  if (!valid_utf8(bytes, length))
    return -1;
  while (index < length) {
    unsigned char first = bytes[index++];
    size_t continuation = first < 0x80 ? 0 :
                          first < 0xe0 ? 1 : first < 0xf0 ? 2 : 3;
    uint32_t codepoint = continuation == 0 ? first :
                         continuation == 1 ? first & 0x1f :
                         continuation == 2 ? first & 0x0f : first & 0x07;
    for (size_t offset = 0; offset < continuation; offset++)
      codepoint = (codepoint << 6) | (bytes[index + offset] & 0x3f);
    const int whitespace =
        (codepoint >= 0x09 && codepoint <= 0x0d) || codepoint == 0x20 ||
        codepoint == 0x85 || codepoint == 0xa0 || codepoint == 0x1680 ||
        (codepoint >= 0x2000 && codepoint <= 0x200a) ||
        codepoint == 0x2028 || codepoint == 0x2029 || codepoint == 0x202f ||
        codepoint == 0x205f || codepoint == 0x3000;
    if (!whitespace)
      nonblank = 1;
    index += continuation;
    if (++count > maximum)
      return -1;
  }
  if (!count || (require_nonblank && !nonblank))
    return -1;
  return (int)count;
}

static int exact_fields(json_object *root, const char *const *fields,
                        size_t count) {
  if (json_object_object_length(root) != count)
    return 0;
  for (size_t index = 0; index < count; index++) {
    json_object *ignored = NULL;
    if (!json_object_object_get_ex(root, fields[index], &ignored))
      return 0;
  }
  return 1;
}

static int string_field(json_object *root, const char *name,
                        const char **output) {
  json_object *value = NULL;
  if (!json_object_object_get_ex(root, name, &value) || !value ||
      json_object_get_type(value) != json_type_string)
    return 0;
  const char *text = json_object_get_string(value);
  size_t length = (size_t)json_object_get_string_len(value);
  if (memchr(text, '\0', length))
    return 0;
  *output = text;
  return 1;
}

static int object_field(json_object *root, const char *name) {
  json_object *value = NULL;
  return json_object_object_get_ex(root, name, &value) && value &&
         json_object_get_type(value) == json_type_object;
}

int ct_valid_http_field_value(const char *value, size_t length) {
  // As in valid_text_boundary above: an empty field value (length 0) is
  // valid regardless of whether Chapel handed us a NULL buffer pointer
  // for it, since there are no bytes to reject.
  if (length == 0)
    return 1;
  if (!value)
    return 0;
  for (size_t index = 0; index < length; index++) {
    unsigned char byte = (unsigned char)value[index];
    if (byte == 0 || byte == '\r' || byte == '\n' || byte == 0x7f ||
        (byte < 0x20 && byte != '\t'))
      return 0;
  }
  return 1;
}

int ct_validate_adapter_command(const char *json, char **safe_id,
                                char **error_message) {
  *safe_id = NULL;
  json_object *root = parse_json(json);
  if (!root || json_object_get_type(root) != json_type_object) {
    if (root) json_object_put(root);
    set_error(error_message, "adapter command must be one JSON object");
    return 0;
  }
  const char *id = NULL, *operation = NULL;
  if (string_field(root, "id", &id) &&
      utf8_scalar_count(id, 128, 1) > 0)
    *safe_id = copy_string(id);
  if (!*safe_id || !string_field(root, "op", &operation)) {
    set_error(error_message, "adapter id and op are required");
    goto invalid;
  }
  const char *hello[] = {"protocolVersion", "id", "op"};
  const char *call[] = {"id", "op", "path", "args"};
  const char *subscribe[] = {"id", "op", "subscriptionId", "path", "args"};
  const char *unsubscribe[] = {"id", "op", "subscriptionId"};
  const char *auth[] = {"id", "op", "token"};
  const char *control[] = {"id", "op"};
  const char *path = NULL, *subscription_id = NULL, *token = NULL;
  int valid = 0;
  if (!strcmp(operation, "hello")) {
    json_object *version = NULL;
    valid = exact_fields(root, hello, 3) &&
            json_object_object_get_ex(root, "protocolVersion", &version) &&
            version && json_object_get_type(version) == json_type_int &&
            json_object_get_int64(version) == 1;
  } else if (!strcmp(operation, "query") ||
             !strcmp(operation, "mutation") ||
             !strcmp(operation, "action")) {
    valid = exact_fields(root, call, 4) && string_field(root, "path", &path) &&
            utf8_scalar_count(path, 1024, 0) >= 3 && object_field(root, "args");
  } else if (!strcmp(operation, "subscribe")) {
    valid = exact_fields(root, subscribe, 5) &&
            string_field(root, "subscriptionId", &subscription_id) &&
            utf8_scalar_count(subscription_id, 128, 1) > 0 &&
            string_field(root, "path", &path) &&
            utf8_scalar_count(path, 1024, 0) >= 3 && object_field(root, "args");
  } else if (!strcmp(operation, "unsubscribe")) {
    valid = exact_fields(root, unsubscribe, 3) &&
            string_field(root, "subscriptionId", &subscription_id) &&
            utf8_scalar_count(subscription_id, 128, 1) > 0;
  } else if (!strcmp(operation, "setAuth")) {
    valid = exact_fields(root, auth, 3) && string_field(root, "token", &token) &&
            ct_valid_http_field_value(token, strlen(token));
  } else if (!strcmp(operation, "debugDisconnect") ||
             !strcmp(operation, "close")) {
    valid = exact_fields(root, control, 2);
  }
  if (!valid) {
    set_error(error_message, "adapter command does not match protocol v1");
    goto invalid;
  }
  json_object_put(root);
  return 1;

invalid:
  json_object_put(root);
  return 0;
}

static int base64_value(unsigned char value) {
  if (value >= 'A' && value <= 'Z') return value - 'A';
  if (value >= 'a' && value <= 'z') return value - 'a' + 26;
  if (value >= '0' && value <= '9') return value - '0' + 52;
  if (value == '+') return 62;
  if (value == '/') return 63;
  return -1;
}

static int decode_timestamp(const char *encoded, unsigned char output[8]) {
  if (!encoded || strlen(encoded) != 12 || encoded[11] != '=') return 0;
  size_t out = 0;
  for (size_t index = 0; index < 12; index += 4) {
    int a = base64_value((unsigned char)encoded[index]);
    int b = base64_value((unsigned char)encoded[index + 1]);
    int c = encoded[index + 2] == '=' ? 0 : base64_value((unsigned char)encoded[index + 2]);
    int d = encoded[index + 3] == '=' ? 0 : base64_value((unsigned char)encoded[index + 3]);
    if (a < 0 || b < 0 || c < 0 || d < 0) return 0;
    if (out < 8) output[out++] = (unsigned char)((a << 2) | (b >> 4));
    if (encoded[index + 2] != '=' && out < 8)
      output[out++] = (unsigned char)((b << 4) | (c >> 2));
    if (encoded[index + 3] != '=' && out < 8)
      output[out++] = (unsigned char)((c << 6) | d);
  }
  return out == 8;
}

int ct_timestamp_compare(const char *left, const char *right, int *comparison) {
  unsigned char a[8], b[8];
  if (!decode_timestamp(left, a) || !decode_timestamp(right, b)) return 0;
  *comparison = 0;
  /* Convex encodes the numeric uint64 timestamp in little-endian order. */
  for (int index = 7; index >= 0; index--) {
    if (a[index] == b[index]) continue;
    *comparison = a[index] > b[index] ? 1 : -1;
    break;
  }
  return 1;
}

static size_t http_receive(void *contents, size_t size, size_t nmemb,
                           void *opaque) {
  if (size && nmemb > SIZE_MAX / size)
    return 0;
  size_t length = size * nmemb;
  return append(opaque, contents, length, CT_MAX_HTTP) ? length : 0;
}

static int header_has_token(const char *value, size_t length,
                            const char *wanted) {
  size_t wanted_length = strlen(wanted), index = 0;
  while (index < length) {
    while (index < length &&
           (value[index] == ' ' || value[index] == '\t' || value[index] == ','))
      index++;
    size_t start = index;
    while (index < length && value[index] != ',')
      index++;
    size_t end = index;
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t'))
      end--;
    if (end - start == wanted_length &&
        strncasecmp(value + start, wanted, wanted_length) == 0)
      return 1;
  }
  return 0;
}

static size_t websocket_header(char *data, size_t size, size_t count,
                               void *opaque) {
  if (size && count > SIZE_MAX / size)
    return 0;
  size_t length = size * count;
  struct websocket_handshake *handshake = opaque;
  if (length >= 5 && !strncasecmp(data, "HTTP/", 5)) {
    memset(handshake, 0, sizeof(*handshake));
    return length;
  }
  const char *colon = memchr(data, ':', length);
  if (!colon)
    return length;
  size_t name_length = (size_t)(colon - data);
  const char *value = colon + 1;
  size_t value_length = length - name_length - 1;
  while (value_length && (*value == ' ' || *value == '\t')) {
    value++;
    value_length--;
  }
  while (value_length && (value[value_length - 1] == '\r' ||
                          value[value_length - 1] == '\n' ||
                          value[value_length - 1] == ' ' ||
                          value[value_length - 1] == '\t'))
    value_length--;
  if (name_length == 7 && !strncasecmp(data, "Upgrade", 7))
    handshake->saw_upgrade = header_has_token(value, value_length, "websocket");
  else if (name_length == 10 && !strncasecmp(data, "Connection", 10))
    handshake->saw_connection_upgrade =
        header_has_token(value, value_length, "upgrade");
  else if (name_length == 20 && !strncasecmp(data, "Sec-WebSocket-Accept", 20)) {
    if (value_length >= sizeof(handshake->accept))
      return 0;
    memcpy(handshake->accept, value, value_length);
    handshake->accept[value_length] = '\0';
    handshake->accept_length = value_length;
  }
  return length;
}

int ct_http_post(const char *url, size_t url_length,
                 const char *client_version, size_t client_version_length,
                 const char *token, size_t token_length,
                 const char *body, size_t body_length, int64_t deadline_ms,
                 char **response, size_t *response_length,
                 char **error_message) {
  *response = NULL;
  *response_length = 0;
  if (!valid_text_boundary(url, url_length) ||
      !valid_text_boundary(client_version, client_version_length) ||
      !valid_text_boundary(token, token_length) ||
      !valid_text_boundary(body, body_length) ||
      !ct_valid_http_field_value(client_version, client_version_length) ||
      !ct_valid_http_field_value(token, token_length)) {
    set_error(error_message, "invalid HTTP text boundary");
    return 0;
  }
  if (!curl_is_ready()) {
    set_error(error_message, "could not initialize libcurl");
    return 0;
  }
  CURL *curl = curl_easy_init();
  if (!curl) {
    set_error(error_message, "could not create HTTP client");
    return 0;
  }
  apply_environment_ca_trust(curl);
  int64_t remaining = deadline_ms - ct_monotonic_ms();
  if (remaining <= 0) {
    curl_easy_cleanup(curl);
    set_error(error_message, "HTTP deadline expired");
    return 0;
  }
  struct buffer output = {0};
  struct curl_slist *headers = NULL;
  headers = curl_slist_append(headers, "Content-Type: application/json");
  headers = curl_slist_append(headers, "Accept: application/json");
  char version[256];
  snprintf(version, sizeof(version), "Convex-Client: %s", client_version);
  headers = curl_slist_append(headers, version);
  char *auth = NULL;
  if (token && *token) {
    size_t length = token_length + 23;
    auth = malloc(length);
    if (!auth) {
      set_error(error_message, "out of memory");
      goto failed;
    }
    snprintf(auth, length, "Authorization: Bearer %s", token);
    headers = curl_slist_append(headers, auth);
  }
  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_POST, 1L);
  curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
  curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE,
                   (curl_off_t)body_length);
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, http_receive);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &output);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)remaining);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  CURLcode code = curl_easy_perform(curl);
  if (code != CURLE_OK) {
    set_error(error_message, curl_easy_strerror(code));
    goto failed;
  }
  long response_code = 0;
  if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code) !=
          CURLE_OK ||
      response_code < 200 || response_code >= 300) {
    char status_error[96];
    snprintf(status_error, sizeof(status_error),
             "HTTP request failed with status %ld", response_code);
    set_error(error_message, status_error);
    goto failed;
  }
  if (!output.data)
    output.data = copy_string("");
  if (!output.data ||
      !valid_text_boundary(output.data, output.length)) {
    set_error(error_message, "HTTP response is not exact UTF-8 text");
    goto failed;
  }
  *response = output.data;
  *response_length = output.length;
  free(auth);
  curl_slist_free_all(headers);
  curl_easy_cleanup(curl);
  return 1;

failed:
  free(output.data);
  free(auth);
  curl_slist_free_all(headers);
  curl_easy_cleanup(curl);
  return 0;
}

// Every "nothing to report yet" exit from ct_ws_receive returns to the
// Chapel run() loop's tight while-!closing polling loop, which calls
// straight back in -- there is no Chapel-visible sleep()/blocking-I/O call
// in between for the qthreads scheduler to treat as a yield point. The same
// starvation ct_read_line documents applies here: a qthreads worker that
// never explicitly yields keeps re-entering this same task and never hands
// the OS thread to another ready task (e.g. the main task polling
// Subscription.next()/Client.subscribe()), which was measured stalling
// that task for 15+ seconds. With multiple qthreads workers this is
// invisible; under a single-core container or a `--cpus` cap it
// deterministically starves the other task for as long as this one keeps
// polling.
//
// Two guards keep that fix from fighting the hostile_peer.py "partial"
// fixture, which stalls mid frame and expects ct_ws_receive to notice the
// 1-second frame_deadline_ms expiry and retire the connection promptly:
// skip yielding entirely while a frame is actively being assembled
// (frame_deadline_ms set -- nothing to gain by yielding, since the
// deadline is the whole point), and even during a genuine idle wait,
// throttle to at most one yield per interval. An earlier version yielded
// on every idle "no data" return (up to ~40/second at this function's
// 25ms polling cadence) and that alone, even always gated on
// frame_deadline_ms being unset, was still measured occasionally letting
// the fixture's patience run out under this host's load -- each yield can
// hand the OS thread to another ready task that does not yield back
// quickly, and enough of those compounding before a frame even starts
// arriving pushes the whole connection's timeline out unpredictably. A
// throttled yield still closes the multi-second starvation gap (the
// original bug) while bounding how often this function hands the thread
// away during any one connection's lifetime.
#define CT_WS_YIELD_INTERVAL_MS 200

static void maybe_yield_idle(chapel_ws *socket) {
  if (socket->frame_deadline_ms)
    return;
  int64_t now = ct_monotonic_ms();
  if (socket->last_yield_ms &&
      now - socket->last_yield_ms < CT_WS_YIELD_INTERVAL_MS)
    return;
  socket->last_yield_ms = now;
  chpl_task_yield();
}

static int wait_socket(CURL *curl, short events, int64_t deadline_ms) {
  curl_socket_t fd = CURL_SOCKET_BAD;
  if (curl_easy_getinfo(curl, CURLINFO_ACTIVESOCKET, &fd) != CURLE_OK ||
      fd == CURL_SOCKET_BAD)
    return -1;
  for (;;) {
    int64_t remaining = deadline_ms - ct_monotonic_ms();
    if (remaining <= 0)
      return 0;
    struct pollfd descriptor = {.fd = fd, .events = events};
    int result = poll(&descriptor, 1, remaining > INT32_MAX ? INT32_MAX
                                                            : (int)remaining);
    if (result >= 0)
      return result;
    if (errno != EINTR)
      return -1;
  }
}

chapel_ws *ct_ws_connect(const char *url, size_t url_length,
                         const char *client_version,
                         size_t client_version_length,
                         int64_t deadline_ms,
                         char **error_message) {
  if (!valid_text_boundary(url, url_length) ||
      !valid_text_boundary(client_version, client_version_length) ||
      !ct_valid_http_field_value(client_version, client_version_length)) {
    set_error(error_message, "invalid WebSocket text boundary");
    return NULL;
  }
  if (!curl_is_ready()) {
    set_error(error_message, "could not initialize libcurl");
    return NULL;
  }
  CURL *curl = curl_easy_init();
  if (!curl) {
    set_error(error_message, "could not create WebSocket client");
    return NULL;
  }
  apply_environment_ca_trust(curl);
  int64_t remaining = deadline_ms - ct_monotonic_ms();
  if (remaining <= 0) {
    curl_easy_cleanup(curl);
    set_error(error_message, "WebSocket deadline expired");
    return NULL;
  }
  curl_easy_setopt(curl, CURLOPT_URL, url);
  struct curl_slist *headers = NULL;
  unsigned char key_raw[16];
  int random_fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  ssize_t random_length =
      random_fd >= 0 ? read(random_fd, key_raw, sizeof(key_raw)) : -1;
  if (random_fd >= 0)
    close(random_fd);
  if (random_length != (ssize_t)sizeof(key_raw)) {
    set_error(error_message, "could not generate WebSocket key");
    curl_easy_cleanup(curl);
    return NULL;
  }
  char key_base64[25];
  if (EVP_EncodeBlock((unsigned char *)key_base64, key_raw,
                      sizeof(key_raw)) != 24) {
    set_error(error_message, "could not encode WebSocket key");
    curl_easy_cleanup(curl);
    return NULL;
  }
  key_base64[24] = '\0';
  char key_header[64];
  snprintf(key_header, sizeof(key_header), "Sec-WebSocket-Key: %s", key_base64);
  headers = curl_slist_append(headers, key_header);
  char version[256];
  snprintf(version, sizeof(version), "Convex-Client: %s", client_version);
  headers = curl_slist_append(headers, version);
  struct websocket_handshake handshake = {0};
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, websocket_header);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, &handshake);
  curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 2L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)remaining);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  CURLcode code = curl_easy_perform(curl);
  curl_slist_free_all(headers);
  if (code != CURLE_OK) {
    set_error(error_message, curl_easy_strerror(code));
    curl_easy_cleanup(curl);
    return NULL;
  }
  long response_code = 0;
  char accept_source[128];
  snprintf(accept_source, sizeof(accept_source), "%s%s", key_base64,
           "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int digest_length = 0;
  unsigned char expected_accept[64];
  int expected_length = 0;
  if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code) !=
          CURLE_OK ||
      !EVP_Digest(accept_source, strlen(accept_source), digest,
                  &digest_length, EVP_sha1(), NULL) ||
      (expected_length = EVP_EncodeBlock(expected_accept, digest,
                                         digest_length)) <= 0 ||
      response_code != 101 || !handshake.saw_upgrade ||
      !handshake.saw_connection_upgrade ||
      handshake.accept_length != (size_t)expected_length ||
      CRYPTO_memcmp(handshake.accept, expected_accept,
                    (size_t)expected_length) != 0) {
    set_error(error_message, "invalid WebSocket upgrade response");
    curl_easy_cleanup(curl);
    return NULL;
  }
  chapel_ws *socket = calloc(1, sizeof(*socket));
  if (!socket) {
    set_error(error_message, "out of memory");
    curl_easy_cleanup(curl);
    return NULL;
  }
  socket->curl = curl;
  // CURLOPT_CONNECT_ONLY level 2 (set above) opts into libcurl's own
  // connection-state gathering, which buffers internally any bytes it reads
  // past the HTTP upgrade response while parsing the handshake -- a peer
  // that pipelines its first WebSocket frame(s) immediately behind the 101
  // reply (as a real server legitimately may) lands those bytes in curl's
  // private buffer during this function's curl_easy_perform() above, never
  // through our own curl_ws_recv() loop. ct_ws_receive's raw-fd poll() in
  // wait_socket() cannot see that buffered data -- it watches the kernel
  // socket for a *new* readability edge, and if the peer sends nothing
  // further on this connection, no such edge ever arrives, so the first
  // receive would poll forever until the peer eventually tears the
  // connection down (observed: a peer with a ~50s idle-then-close timeout
  // made this look like a ~50s client hang, though the client was never
  // actually blocked -- see the hostile_peer.py "partial" fixture's
  // TCP-teardown-visibility margin comment, which measures exactly this
  // symptom from the peer's side). Seed the speculative-internal-buffer
  // probe (the same one that already runs after a successful frame chunk,
  // see the "may_have_internal" comment below in ct_ws_receive) so the very
  // first receive attempt checks curl's internal buffer before ever waiting
  // on the raw socket.
  socket->may_have_internal = 1;
  return socket;
}

typedef CURLcode (*ws_send_call)(void *, const char *, size_t, size_t *,
                                 curl_off_t, unsigned int);
typedef int (*ws_send_wait)(void *, int64_t);

static CURLcode production_ws_send(void *context, const char *message,
                                   size_t length, size_t *sent,
                                   curl_off_t frame_size,
                                   unsigned int flags) {
  return curl_ws_send(context, message, length, sent, frame_size, flags);
}

static int production_ws_wait(void *context, int64_t deadline_ms) {
  return wait_socket(context, POLLIN | POLLOUT, deadline_ms);
}

static int ws_send_all(void *context, const char *message, size_t length,
                       int64_t deadline_ms, char **error_message,
                       ws_send_call send_call, ws_send_wait send_wait) {
  size_t offset = 0;
  int call_issued = 0;
  do {
    if (ct_monotonic_ms() >= deadline_ms) {
      set_error(error_message, "WebSocket send deadline expired");
      return 0;
    }
    size_t sent = 0;
    CURLcode code = send_call(
        context, message + offset, length - offset, &sent,
        call_issued ? 0 : (curl_off_t)length, CURLWS_TEXT | CURLWS_OFFSET);
    call_issued = 1;
    /* libcurl may report progress together with CURLE_AGAIN. */
    offset += sent;
    if (code == CURLE_OK) {
      continue;
    }
    if (code != CURLE_AGAIN ||
        send_wait(context, deadline_ms) <= 0) {
      set_error(error_message, code == CURLE_AGAIN ? "WebSocket send deadline expired"
                                                   : curl_easy_strerror(code));
      return 0;
    }
  } while (offset < length);
  return 1;
}

int ct_ws_send(chapel_ws *socket, const char *message, size_t length,
               int64_t deadline_ms, char **error_message) {
  if (!valid_text_boundary(message, length)) {
    set_error(error_message, "WebSocket message is not exact UTF-8 text");
    return 0;
  }
  if (!socket || socket->interrupted) {
    set_error(error_message, "WebSocket is closed");
    return 0;
  }
  return ws_send_all(socket->curl, message, length, deadline_ms,
                     error_message, production_ws_send, production_ws_wait);
}

#ifdef CHAPEL_TRANSPORT_TEST
struct ws_send_script {
  int call;
  int waits;
  int valid;
  size_t total;
  const char *base;
};

static CURLcode scripted_ws_send(void *context, const char *message,
                                 size_t length, size_t *sent,
                                 curl_off_t frame_size, unsigned int flags) {
  struct ws_send_script *script = context;
  (void)message;
  const unsigned int expected_flags = CURLWS_TEXT | CURLWS_OFFSET;
  const size_t expected_offset = script->call < 2 ? 0 : 7;
  if (flags != expected_flags ||
      frame_size != (script->call == 0 ? (curl_off_t)script->total : 0) ||
      message != script->base + expected_offset ||
      length != script->total - expected_offset)
    script->valid = 0;
  if (script->call == 0) {
    *sent = 0;
    script->call++;
    return CURLE_AGAIN;
  }
  if (script->call == 1) {
    *sent = length > 7 ? 7 : length;
    script->call++;
    return CURLE_AGAIN;
  }
  *sent = length;
  script->call++;
  return CURLE_OK;
}

static int scripted_ws_wait(void *context, int64_t deadline_ms) {
  struct ws_send_script *script = context;
  if (deadline_ms <= ct_monotonic_ms())
    script->valid = 0;
  script->waits++;
  return 1;
}

int ct_ws_send_sequence_selftest(void) {
  static const char payload[] = "0123456789abcdef";
  struct ws_send_script script = {
      .valid = 1, .total = sizeof(payload) - 1, .base = payload};
  char *error = NULL;
  int result = ws_send_all(&script, payload, sizeof(payload) - 1,
                           ct_monotonic_ms() + 1000, &error,
                           scripted_ws_send, scripted_ws_wait);
  free(error);
  return result && script.valid && script.call == 3 && script.waits == 2;
}
#endif

struct receive_watchdog {
  pthread_mutex_t mutex;
  pthread_cond_t condition;
  curl_socket_t fd;
  int64_t deadline_ms;
  int done;
  int fired;
};

static void *receive_watchdog_run(void *opaque) {
  struct receive_watchdog *watchdog = opaque;
  struct timespec deadline = {
      .tv_sec = watchdog->deadline_ms / 1000,
      .tv_nsec = (watchdog->deadline_ms % 1000) * 1000000};
  pthread_mutex_lock(&watchdog->mutex);
  while (!watchdog->done) {
    int status = pthread_cond_timedwait(
        &watchdog->condition, &watchdog->mutex, &deadline);
    if (status == ETIMEDOUT) {
      watchdog->fired = 1;
      (void)shutdown(watchdog->fd, SHUT_RDWR);
      break;
    }
  }
  pthread_mutex_unlock(&watchdog->mutex);
  return NULL;
}

static int watched_ws_receive(chapel_ws *socket, char *chunk,
                              size_t chunk_length, size_t *received,
                              const struct curl_ws_frame **meta,
                              int64_t watchdog_deadline, CURLcode *code) {
  curl_socket_t active = CURL_SOCKET_BAD;
  if (curl_easy_getinfo(socket->curl, CURLINFO_ACTIVESOCKET, &active) !=
          CURLE_OK ||
      active == CURL_SOCKET_BAD)
    return -1;
  struct receive_watchdog watchdog = {
      .fd = active, .deadline_ms = watchdog_deadline};
  pthread_condattr_t attributes;
  pthread_t thread;
  if (pthread_mutex_init(&watchdog.mutex, NULL) != 0)
    return -1;
  if (pthread_condattr_init(&attributes) != 0) {
    pthread_mutex_destroy(&watchdog.mutex);
    return -1;
  }
  int setup = pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC) == 0 &&
              pthread_cond_init(&watchdog.condition, &attributes) == 0;
  pthread_condattr_destroy(&attributes);
  if (!setup) {
    pthread_mutex_destroy(&watchdog.mutex);
    return -1;
  }
  if (pthread_create(&thread, NULL, receive_watchdog_run, &watchdog) != 0) {
    pthread_cond_destroy(&watchdog.condition);
    pthread_mutex_destroy(&watchdog.mutex);
    return -1;
  }
  *code = curl_ws_recv(socket->curl, chunk, chunk_length, received, meta);
  pthread_mutex_lock(&watchdog.mutex);
  watchdog.done = 1;
  pthread_cond_signal(&watchdog.condition);
  pthread_mutex_unlock(&watchdog.mutex);
  // Joining here is the stale-fd boundary: curl cleanup or another receive
  // cannot reuse the descriptor while this watchdog can still shut it down.
  pthread_join(thread, NULL);
  int fired = watchdog.fired;
  pthread_cond_destroy(&watchdog.condition);
  pthread_mutex_destroy(&watchdog.mutex);
  return fired;
}

static void shutdown_active_websocket(chapel_ws *socket) {
  curl_socket_t active = CURL_SOCKET_BAD;
  if (curl_easy_getinfo(socket->curl, CURLINFO_ACTIVESOCKET, &active) ==
          CURLE_OK &&
      active != CURL_SOCKET_BAD)
    (void)shutdown(active, SHUT_RDWR);
}

int ct_ws_receive(chapel_ws *socket, int64_t deadline_ms, char **message,
                  size_t *message_length, char **error_message) {
  *message = NULL;
  *message_length = 0;
  if (!socket || socket->interrupted) {
    set_error(error_message, "WebSocket is closed");
    return -1;
  }
  if (socket->frame_deadline_ms &&
      ct_monotonic_ms() >= socket->frame_deadline_ms) {
    shutdown_active_websocket(socket);
    set_error(error_message, "WebSocket frame deadline expired");
    return -1;
  }
  for (;;) {
    if (ct_monotonic_ms() >= deadline_ms) {
      maybe_yield_idle(socket);
      return 0;
    }
    if (socket->frame_deadline_ms &&
        ct_monotonic_ms() >= socket->frame_deadline_ms) {
      shutdown_active_websocket(socket);
      set_error(error_message, "WebSocket frame deadline expired");
      return -1;
    }
    int speculative_internal = socket->may_have_internal;
    if (!speculative_internal) {
      int64_t wait_deadline = deadline_ms;
      if (socket->frame_deadline_ms &&
          socket->frame_deadline_ms < wait_deadline)
        wait_deadline = socket->frame_deadline_ms;
      int ready = wait_socket(socket->curl, POLLIN, wait_deadline);
      if (ready == 0) {
        if (socket->frame_deadline_ms &&
            ct_monotonic_ms() >= socket->frame_deadline_ms) {
          shutdown_active_websocket(socket);
          set_error(error_message, "WebSocket frame deadline expired");
          return -1;
        }
        maybe_yield_idle(socket);
        return 0;
      }
      if (ready < 0) {
        set_error(error_message, "could not poll WebSocket");
        return -1;
      }
    }
    socket->may_have_internal = 0;
    if (!socket->frame_deadline_ms)
      socket->frame_deadline_ms = ct_monotonic_ms() + 1000;
    char chunk[16384];
    size_t received = 0;
    const struct curl_ws_frame *meta = NULL;
    CURLcode code = CURLE_OK;
    int watchdog = watched_ws_receive(
        socket, chunk, sizeof(chunk), &received, &meta,
        socket->frame_deadline_ms, &code);
    if (watchdog < 0) {
      set_error(error_message, "could not start WebSocket receive watchdog");
      return -1;
    }
    if (watchdog > 0) {
      set_error(error_message, "WebSocket frame deadline expired");
      return -1;
    }
    if (code == CURLE_AGAIN) {
      // frame_deadline_ms exists to bound an in-progress, not-yet-complete
      // frame/message (socket->partial.*). A CURLE_AGAIN with no bytes and
      // no partial data in flight is just an idle wait producing nothing --
      // whether this attempt was triggered by a real poll(2) wakeup (a
      // routine TLS-record-boundary false readiness, since a decryptable
      // application frame is not guaranteed just because raw socket bytes
      // arrived) or a speculative internal-buffer probe. Gating the reset on
      // speculative_internal left the deadline armed after any real,
      // non-speculative spurious wakeup, so it would fire "frame deadline
      // expired" up to a second later even though the connection was simply
      // idle between messages. Reset whenever there is genuinely nothing
      // pending, regardless of which kind of attempt this was.
      if (!received && !meta && !socket->partial.length &&
          !socket->partial_text)
        socket->frame_deadline_ms = 0;
      continue;
    }
    if (code != CURLE_OK) {
      set_error(error_message, curl_easy_strerror(code));
      return -1;
    }
    if (meta && (meta->flags & CURLWS_CLOSE)) {
      set_error(error_message, "WebSocket peer closed the connection");
      return -1;
    }
    if (meta && (meta->flags & CURLWS_PING)) {
      /* libcurl automatically replies unless CURLWS_NOAUTOPONG is requested. */
      if (meta->bytesleft == 0) {
        if (!socket->partial.length && !socket->partial_text)
          socket->frame_deadline_ms = 0;
        socket->may_have_internal = 1;
      }
      continue;
    }
    if (meta && (meta->flags & CURLWS_PONG)) {
      if (meta->bytesleft == 0) {
        if (!socket->partial.length && !socket->partial_text)
          socket->frame_deadline_ms = 0;
        socket->may_have_internal = 1;
      }
      continue;
    }
    if (meta && (meta->flags & CURLWS_TEXT))
      socket->partial_text = 1;
    if (!socket->partial_text) {
      set_error(error_message, "WebSocket delivered a non-text message");
      return -1;
    }
    if (!append(&socket->partial, chunk, received, CT_MAX_WS)) {
      set_error(error_message, "WebSocket message exceeds 2 MiB");
      return -1;
    }
    if (meta && meta->bytesleft == 0 && !(meta->flags & CURLWS_CONT)) {
      if (!valid_text_boundary(socket->partial.data,
                               socket->partial.length)) {
        set_error(error_message, "WebSocket text is not exact UTF-8");
        return -1;
      }
      *message = socket->partial.data;
      *message_length = socket->partial.length;
      memset(&socket->partial, 0, sizeof(socket->partial));
      socket->partial_text = 0;
      socket->frame_deadline_ms = 0;
      socket->may_have_internal = 1;
      return 1;
    }
    // A successful decoder call may have pulled more frame bytes into
    // libcurl than it returned in this chunk. Probe that private buffer under
    // the same absolute frame deadline before waiting for a new OS edge.
    socket->may_have_internal = 1;
  }
}

void ct_ws_interrupt(chapel_ws *socket) {
  if (socket)
    socket->interrupted = 1;
}

void ct_ws_close(chapel_ws *socket, int64_t deadline_ms) {
  if (!socket)
    return;
  if (!socket->interrupted) {
    for (;;) {
      size_t sent = 0;
      CURLcode code =
          curl_ws_send(socket->curl, "", 0, &sent, 0, CURLWS_CLOSE);
      if (code == CURLE_OK)
        break;
      if (code != CURLE_AGAIN ||
          wait_socket(socket->curl, POLLIN | POLLOUT, deadline_ms) <= 0)
        break;
    }
  }
  curl_easy_cleanup(socket->curl);
  free(socket->partial.data);
  free(socket);
}

static int parse_address(const char *address, char **host, char **port) {
  const char *colon = strrchr(address, ':');
  if (!colon || colon == address || !colon[1])
    return 0;
  size_t host_length = (size_t)(colon - address);
  *host = malloc(host_length + 1);
  *port = copy_string(colon + 1);
  if (!*host || !*port) {
    free(*host);
    free(*port);
    return 0;
  }
  memcpy(*host, address, host_length);
  (*host)[host_length] = '\0';
  return 1;
}

int ct_adapter_accept(const char *address, size_t address_length,
                      char **error_message) {
  if (!valid_text_boundary(address, address_length)) {
    set_error(error_message, "invalid adapter listen address text");
    return -1;
  }
  char *host = NULL, *port = NULL;
  if (!parse_address(address, &host, &port)) {
    set_error(error_message, "ADAPTER_LISTEN must be host:port");
    return -1;
  }
  struct addrinfo hints = {.ai_family = AF_UNSPEC,
                           .ai_socktype = SOCK_STREAM,
                           .ai_flags = AI_PASSIVE};
  struct addrinfo *addresses = NULL;
  int gai = getaddrinfo(*host ? host : NULL, port, &hints, &addresses);
  free(host);
  free(port);
  if (gai != 0) {
    set_error(error_message, gai_strerror(gai));
    return -1;
  }
  int listener = -1;
  for (struct addrinfo *entry = addresses; entry; entry = entry->ai_next) {
    listener = socket(entry->ai_family, entry->ai_socktype | SOCK_CLOEXEC,
                      entry->ai_protocol);
    if (listener < 0)
      continue;
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(listener, entry->ai_addr, entry->ai_addrlen) == 0 &&
        listen(listener, 1) == 0)
      break;
    close(listener);
    listener = -1;
  }
  freeaddrinfo(addresses);
  if (listener < 0) {
    set_error(error_message, strerror(errno));
    return -1;
  }
  int connection;
  do {
    connection = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
  } while (connection < 0 && errno == EINTR);
  close(listener);
  if (connection < 0)
    set_error(error_message, strerror(errno));
  return connection;
}

int ct_read_line(int fd, size_t limit, char **line, size_t *line_length,
                 char **error_message) {
  (void)pthread_once(&interrupt_once, initialize_interrupt);
  pthread_mutex_lock(&reader_lock);
  reader_fd = fd;
  pthread_mutex_unlock(&reader_lock);
  if (atomic_load(&reader_interrupted)) {
    set_error(error_message, "adapter input interrupted");
    return -1;
  }
  struct buffer value = {0};
  *line_length = 0;
  for (;;) {
    // A raw blocking read(2) here would hold the OS thread it runs on for
    // as long as the peer stays silent, starving the adapter's bounded
    // output-writer task -- a qthreads worker parked inside any extern/C
    // blocking call, however briefly, does not hand control back to the
    // Chapel scheduler on its own; a single-core container or a `--cpus`
    // cap makes this deterministic rather than a rare race, since qthreads
    // then has nowhere else to run the writer task at all. On a live
    // connection that leaves an already-enqueued reply unsent forever.
    // Bounding the poll(2) call (matching the discipline the WebSocket
    // receive path already uses) turns that one unbounded wait into
    // repeated short ones, and the explicit chpl_task_yield() below each
    // timed-out poll is what actually lets the writer run in between. The
    // interrupt pipe's read end sits in the same poll(2) set so
    // ct_interrupt_fd can wake this loop immediately rather than waiting
    // out the timeout.
    char byte;
    ssize_t got;
    for (;;) {
      if (atomic_load(&reader_interrupted)) {
        set_error(error_message, "adapter input interrupted");
        free(value.data);
        return -1;
      }
      struct pollfd descriptors[2] = {
          {.fd = fd, .events = POLLIN},
          {.fd = interrupt_pipe_read, .events = POLLIN},
      };
      nfds_t watched = interrupt_pipe_read >= 0 ? 2 : 1;
      int ready = poll(descriptors, watched, 75 /* ms */);
      if (ready < 0) {
        if (errno == EINTR)
          continue;
        set_error(error_message, strerror(errno));
        free(value.data);
        return -1;
      }
      if (ready == 0) {
        // Bounding the poll(2) call keeps this an occasional wait rather
        // than one unbounded block, but qthreads still will not run the
        // output-writer task on its own during that wait -- this explicit
        // yield is what actually lets it in.
        chpl_task_yield();
        continue;
      }
      if (watched == 2 && (descriptors[1].revents & POLLIN)) {
        char drain[64];
        while (read(interrupt_pipe_read, drain, sizeof(drain)) > 0) { }
        set_error(error_message, "adapter input interrupted");
        free(value.data);
        return -1;
      }
      if (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR))
        break;
    }
    got = read(fd, &byte, 1);
    if (got == 0) {
      if (!value.length) {
        free(value.data);
        return 0;
      }
      break;
    }
    if (got < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        continue;
      set_error(error_message, atomic_load(&reader_interrupted)
                                   ? "adapter input interrupted"
                                   : strerror(errno));
      free(value.data);
      return -1;
    }
    if (byte == '\n')
      break;
    if (!append(&value, &byte, 1, limit)) {
      set_error(error_message, "adapter command exceeds 2 MiB");
      free(value.data);
      return -1;
    }
  }
  if (value.length && value.data[value.length - 1] == '\r')
    value.data[--value.length] = '\0';
  if (!value.data)
    value.data = copy_string("");
  if (!value.data || !valid_text_boundary(value.data, value.length)) {
    set_error(error_message, "adapter command is not exact UTF-8 text");
    free(value.data);
    return -2; /* The complete invalid line was consumed; reading may resume. */
  }
  *line = value.data;
  *line_length = value.length;
  return 1;
}

void ct_interrupt_fd(int fd) {
  (void)pthread_once(&interrupt_once, initialize_interrupt);
  pthread_mutex_lock(&reader_lock);
  atomic_store(&reader_interrupted, 1);
  // shutdown() only applies to sockets (the ADAPTER_LISTEN accept-mode
  // path); for a plain pipe fd (stdin/stdout mode) it is a harmless
  // no-op and the interrupt pipe below is what actually wakes the
  // blocked poll(2) in ct_read_line.
  if (reader_fd == fd)
    (void)shutdown(fd, SHUT_RD);
  pthread_mutex_unlock(&reader_lock);
  if (interrupt_pipe_write >= 0) {
    const char signal_byte = 0;
    // Best-effort: reader_interrupted, checked every poll iteration in
    // ct_read_line, is the fallback if the pipe write is ever lost
    // (e.g. a full pipe from repeated interrupts), just with a delay
    // bounded by that loop's own poll timeout rather than instant.
    ssize_t written = write(interrupt_pipe_write, &signal_byte, 1);
    (void)written;
  }
}

int ct_write_line(int fd, const char *line, size_t length, int64_t deadline_ms,
                  char **error_message) {
  if (!valid_text_boundary(line, length)) {
    set_error(error_message, "adapter event is not exact UTF-8 text");
    return 0;
  }
  int socket_type = 0;
  socklen_t socket_type_length = sizeof(socket_type);
  int is_socket = getsockopt(fd, SOL_SOCKET, SO_TYPE, &socket_type,
                             &socket_type_length) == 0;
  int original_flags = fcntl(fd, F_GETFL, 0);
  int restore_flags = !is_socket && original_flags >= 0 &&
                      !(original_flags & O_NONBLOCK);
  if (restore_flags && fcntl(fd, F_SETFL, original_flags | O_NONBLOCK) < 0) {
    set_error(error_message, strerror(errno));
    return 0;
  }
  size_t offset = 0;
  while (offset <= length) {
    const char newline = '\n';
    const char *data = offset < length ? line + offset : &newline;
    size_t remaining = offset < length ? length - offset : 1;
    struct pollfd descriptor = {.fd = fd, .events = POLLOUT};
    int64_t wait = deadline_ms - ct_monotonic_ms();
    if (wait <= 0 ||
        poll(&descriptor, 1,
             wait > INT32_MAX ? INT32_MAX : (int)wait) <= 0) {
      set_error(error_message, "adapter write deadline expired");
      break;
    }
    ssize_t written = is_socket
                          ? send(fd, data, remaining,
                                 MSG_DONTWAIT | MSG_NOSIGNAL)
                          : write(fd, data, remaining);
    if (written < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        continue;
      set_error(error_message, strerror(errno));
      break;
    }
    if (offset == length) {
      if (restore_flags)
        (void)fcntl(fd, F_SETFL, original_flags);
      return 1;
    }
    offset += (size_t)written;
  }
  if (restore_flags)
    (void)fcntl(fd, F_SETFL, original_flags);
  return 0;
}

void ct_close_fd(int fd) {
  if (fd > 2)
    close(fd);
}

#ifdef CHAPEL_TRANSPORT_TEST
int ct_adapter_close_test_input(void) {
  FILE *commands = tmpfile();
  if (!commands)
    return -1;
  for (int index = 0; index < 64; index++)
    fprintf(commands,
            "{\"id\":\"sub-%d\",\"op\":\"subscribe\","
            "\"subscriptionId\":\"subscription-%d\","
            "\"path\":\"fixture:stalled\",\"args\":{}}\n",
            index, index);
  fputs("{\"id\":\"close-budget\",\"op\":\"close\"}\n", commands);
  fflush(commands);
  rewind(commands);
  int result = dup(fileno(commands));
  fclose(commands);
  return result;
}

static int close_test_output_peer = -1;

int ct_adapter_stalled_test_output(void) {
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
    return -1;
  close_test_output_peer = pair[1];
  return pair[0];
}

int ct_adapter_close_test_saw_closed(void) {
  if (close_test_output_peer < 0)
    return 0;
  struct buffer captured = {0};
  char chunk[4096];
  ssize_t length;
  while ((length = read(close_test_output_peer, chunk, sizeof(chunk))) > 0)
    if (!append(&captured, chunk, (size_t)length, 2u * 1024u * 1024u))
      break;
  close(close_test_output_peer);
  close_test_output_peer = -1;
  int saw_closed = captured.data &&
      memmem(captured.data, captured.length, "\"type\":\"closed\"", 15);
  free(captured.data);
  return saw_closed;
}
#endif

void ct_exit_process(int status) { exit(status); }
