#ifndef CHAPEL_CONVEX_TRANSPORT_H
#define CHAPEL_CONVEX_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

typedef struct chapel_ws chapel_ws;

/* All returned strings are heap allocated and released with ct_free(). */
void ct_free(void *value);
char *ct_getenv_copy(const char *name);
int64_t ct_monotonic_ms(void);
void ct_random_uuid(char output[37]);
char *ct_json_quote(const char *value);
char *ct_deployment_url(const char *value, int websocket);
int ct_json_is_object(const char *json);
int ct_json_get_raw(const char *json, const char *field, char **output);
int ct_json_get_string(const char *json, const char *field, char **output);
int ct_json_get_uint32(const char *json, const char *field, uint32_t *output);
int ct_json_array_length(const char *json, const char *field);
int ct_json_array_raw(const char *json, const char *field, int index,
                      char **output);
/* 1 = present valid string array, 0 = absent, -1 = invalid. */
int ct_json_get_string_array(const char *json, const char *field,
                             char **output);
int ct_json_equal(const char *left, const char *right);
int ct_json_integral_field(const char *json, const char *field,
                           int64_t *output);
int ct_timestamp_compare(const char *left, const char *right, int *comparison);
int ct_validate_adapter_command(const char *json, char **safe_id,
                                char **error_message);
int ct_valid_http_field_value(const char *value, size_t length);
int ct_valid_text_boundary(const char *value, size_t length);

int ct_http_post(const char *url, size_t url_length,
                 const char *client_version, size_t client_version_length,
                 const char *token, size_t token_length,
                 const char *body, size_t body_length, int64_t deadline_ms,
                 char **response, size_t *response_length,
                 char **error_message);

chapel_ws *ct_ws_connect(const char *url, size_t url_length,
                         const char *client_version,
                         size_t client_version_length,
                         int64_t deadline_ms,
                         char **error_message);
int ct_ws_send(chapel_ws *socket, const char *message, size_t length,
               int64_t deadline_ms, char **error_message);
#ifdef CHAPEL_TRANSPORT_TEST
int ct_ws_send_sequence_selftest(void);
#endif
/* 1 = complete UTF-8 text message, 0 = deadline, -1 = closed/error. */
int ct_ws_receive(chapel_ws *socket, int64_t deadline_ms, char **message,
                  size_t *message_length, char **error_message);
void ct_ws_interrupt(chapel_ws *socket);
void ct_ws_close(chapel_ws *socket, int64_t deadline_ms);

/* Adapter stream helpers. A negative listen result carries an allocated error. */
int ct_adapter_accept(const char *address, size_t address_length,
                      char **error_message);
int ct_read_line(int fd, size_t limit, char **line, size_t *line_length,
                 char **error_message);
int ct_write_line(int fd, const char *line, size_t length, int64_t deadline_ms,
                  char **error_message);
void ct_interrupt_fd(int fd);
void ct_close_fd(int fd);
#ifdef CHAPEL_TRANSPORT_TEST
int ct_adapter_close_test_input(void);
int ct_adapter_stalled_test_output(void);
int ct_adapter_close_test_saw_closed(void);
#endif
void ct_exit_process(int status);

#endif
