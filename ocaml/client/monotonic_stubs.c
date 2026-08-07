/* OCaml 5.2 does not expose clock_gettime through Unix. Keep the deadline
   clock native and dependency-free by binding the libc monotonic clock. */
#define _POSIX_C_SOURCE 200809L

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <time.h>

CAMLprim value convex_monotonic_now(value unit) {
  CAMLparam1(unit);
  struct timespec now;

  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    caml_failwith("clock_gettime(CLOCK_MONOTONIC) failed");
  }

  double seconds = (double)now.tv_sec + (double)now.tv_nsec / 1e9;
  CAMLreturn(caml_copy_double(seconds));
}
