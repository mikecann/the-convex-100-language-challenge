/*
convexlaunch.c -- the /usr/local/bin entrypoint for a BCPL Cintcode program.

A Cintcode program is not an ELF binary: it is a Cintcode object loaded by the
`cintsys` interpreter, exactly as a .class file is loaded by a JVM. This
launcher is the ELF file the Docker entrypoint contract requires, and it does
three jobs before handing over:

  1. It moves the real stdout onto a spare descriptor and points descriptor 1
     at stderr. The Cintcode system prints a banner, a CLI prompt and a
     trailing newline of its own on startup and shutdown; without this the
     adapter's NDJSON stream and the canonical example's transcript would be
     corrupted by runtime chatter. Everything the runtime prints therefore
     becomes a stderr diagnostic, which is where this repository wants it.
  2. It passes the caller's first argument through the environment rather than
     through the Cintcode CLI command line, so a room identifier can never be
     re-split or re-quoted by the CLI's argument reader.
  3. It points the interpreter at the installed BCPL tree and fixes the
     Cintcode memory size, which is the client's hard memory ceiling.

Compiled twice, with CONVEX_PROGRAM set to the Cintcode object to run.
*/

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef CONVEX_PROGRAM
#define CONVEX_PROGRAM "convexadapter"
#endif

#ifndef CONVEX_BCPLROOT
#define CONVEX_BCPLROOT "/usr/local/lib/bcpl"
#endif

/* Cintcode memory is allocated once, at startup, and every BCPL allocation in
   this client comes out of it. Fixing it here is what makes the client's
   memory ceiling a property of the process rather than a promise: 6,000,000
   32-bit words is 24 MiB, comfortably inside the shared 128 MiB limit even
   with the interpreter, OpenSSL and the CA store loaded alongside it. */
#ifndef CONVEX_CINTCODE_WORDS
#define CONVEX_CINTCODE_WORDS "6000000"
#endif

int main(int argc, char **argv) {
  char descriptor[16];
  int saved = dup(1);
  char *interpreter = CONVEX_BCPLROOT "/bin/cintsys";
  char *arguments[6];

  if (saved < 0) {
    perror("convex: cannot duplicate stdout");
    return 70;
  }
  /* The spare descriptor must survive execv, so clear FD_CLOEXEC explicitly. */
  if (fcntl(saved, F_SETFD, 0) < 0) {
    perror("convex: cannot preserve stdout");
    return 70;
  }
  if (dup2(2, 1) < 0) {
    perror("convex: cannot redirect runtime output");
    return 70;
  }
  snprintf(descriptor, sizeof(descriptor), "%d", saved);
  setenv("CONVEX_OUT_FD", descriptor, 1);

  if (argc > 1 && argv[1] != NULL && argv[1][0] != '\0') {
    setenv("CONVEX_ROOM_ARG", argv[1], 1);
  }

  setenv("BCPLROOT", CONVEX_BCPLROOT, 1);
  setenv("BCPLPATH", CONVEX_BCPLROOT "/cin", 1);
  setenv("BCPLHDRS", CONVEX_BCPLROOT "/g", 1);

  arguments[0] = interpreter;
  arguments[1] = "-m";
  arguments[2] = CONVEX_CINTCODE_WORDS;
  arguments[3] = "-c";
  arguments[4] = CONVEX_PROGRAM;
  arguments[5] = NULL;

  execv(interpreter, arguments);
  perror("convex: cannot start the BCPL Cintcode system");
  return 70;
}
