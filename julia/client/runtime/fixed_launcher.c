// PackageCompiler's stock launcher exposes Julia's command-line frontend via
// --julia-args. This fixed launcher accepts one inert room argument, disables
// runtime compilation, and calls one build-time-selected main function.
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "julia.h"
#include "uv.h"

JULIA_DEFINE_FAST_TLS

static int configure_paths(char *executable) {
  char *separator = strrchr(executable, '/');
  if (separator == NULL) {
    return 0;
  }
  *separator = '\0';
  separator = strrchr(executable, '/');
  if (separator == NULL) {
    return 0;
  }
  *separator = '\0';

  size_t length = strlen(executable) + strlen("/share/julia") + 1;
  char *share = calloc(length, 1);
  if (share == NULL) {
    return 0;
  }
  strcat(share, executable);
  strcat(share, "/share/julia");
  setenv("JULIA_DEPOT_PATH", share, 1);
  setenv("JULIA_LOAD_PATH", share, 1);
  free(share);
  return 1;
}

static jl_function_t *compiled_main(void) {
  char qualified_name[] = JULIA_MAIN;
  char *separator = strchr(qualified_name, '.');
  if (separator == NULL) {
    return NULL;
  }
  *separator = '\0';
  const char *function_name = separator + 1;
  jl_value_t *module = jl_get_global(jl_main_module, jl_symbol(qualified_name));
  if (module == NULL || !jl_is_module(module)) {
    return NULL;
  }
  return jl_get_function((jl_module_t *)module, function_name);
}

int main(int argc, char *argv[]) {
  argv = uv_setup_args(argc, argv);
  if (argc > 1) {
    // The example reads this value; the adapter ignores it. Strings such as
    // --help remain plain data and are never interpreted as Julia options.
    setenv("EXAMPLE_ROOM", argv[1], 1);
  }

  char *executable = malloc(PATH_MAX);
  size_t executable_size = PATH_MAX;
  if (executable == NULL || uv_exepath(executable, &executable_size) != 0 ||
      !configure_paths(executable)) {
    fprintf(stderr, "fatal error: cannot configure runtime paths: %s\n",
            strerror(errno));
    free(executable);
    return 1;
  }

  // No argv value is parsed as a Julia option. Compilation cannot be
  // re-enabled by a caller because it is fixed before Julia initializes.
  jl_options.compile_enabled = JL_OPTIONS_COMPILE_OFF;
  jl_init();
  jl_function_t *entrypoint = compiled_main();
  if (entrypoint == NULL) {
    fprintf(stderr, "fatal error: compiled entrypoint is unavailable\n");
    free(executable);
    jl_atexit_hook(1);
    return 1;
  }

  jl_value_t *result = jl_call0(entrypoint);
  int32_t exit_code = 1;
  if (jl_exception_occurred()) {
    fprintf(stderr, "fatal error: compiled entrypoint raised an exception\n");
    // A stripped image cannot fall back to Julia's normal display stack. The
    // static printer still exposes the concrete missing method or runtime
    // failure without enabling eval, parsing, or command-line compilation.
    jl_static_show(JL_STDERR, jl_exception_occurred());
    fprintf(stderr, "\n");
  } else if (!jl_typeis(result, jl_int32_type)) {
    fprintf(stderr, "fatal error: compiled entrypoint must return Cint\n");
  } else {
    exit_code = jl_unbox_int32(result);
  }
  free(executable);
  jl_atexit_hook(exit_code);
  return exit_code;
}
