#ifndef FORTRAN_CURL_TRANSPORT_H
#define FORTRAN_CURL_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

/* These functions deliberately expose only ordinary transport. The Fortran
 * module owns every Convex-specific HTTP and sync protocol decision. */
int ft_http_post(const char *url, const char *payload, const char *token,
                 char **body, size_t *body_length, char **error);
void *ft_ws_open(const char *url, const char *client_version, char **error);
int ft_ws_send(void *handle, const char *text, size_t length, char **error);
int ft_ws_receive(void *handle, char **text, size_t *length, int timeout_ms,
                  char **error);
void ft_ws_close(void *handle);

typedef void *(*ft_thread_function)(void *);
void *ft_mutex_new(void);
void ft_mutex_lock(void *mutex);
void ft_mutex_unlock(void *mutex);
void ft_mutex_free(void *mutex);
void *ft_cond_new(void);
int ft_cond_wait(void *condition, void *mutex, int timeout_ms);
void ft_cond_broadcast(void *condition);
void ft_cond_free(void *condition);
void *ft_thread_start(ft_thread_function function, void *argument);
void ft_thread_join(void *thread);
int ft_thread_join_bounded(void *thread, int timeout_ms);
int64_t ft_monotonic_ms(void);

void *ft_stream_open(const char *listen_address, char **error);
int ft_stream_readline(void *stream, char **line, size_t *length,
                       size_t maximum, char **error);
int ft_stream_write(void *stream, const char *text, size_t length,
                    int timeout_ms, char **error);
void ft_stream_close(void *stream);
size_t ft_string_length(const char *text);
void ft_free(void *pointer);

#endif
