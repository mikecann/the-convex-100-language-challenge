# Build the convexext gawk extension.
#
# Two objects are produced from one source file: the extension the runtime
# images ship, and a test build that additionally exposes the TLS server hook
# the language-local TLS test needs. Keeping them in separate directories means
# `@load "convexext"` picks the right one from AWKLIBPATH alone.

CC ?= cc
CFLAGS ?= -O2 -std=gnu11 -D_GNU_SOURCE -Wall -Wextra -fPIC
LDFLAGS ?=
LIBS ?= -lssl -lcrypto
BUILD ?= build

RUNTIME_LIBRARY = $(BUILD)/runtime/convexext.so
TEST_LIBRARY = $(BUILD)/test/convexext.so

.PHONY: all clean

all: $(RUNTIME_LIBRARY) $(TEST_LIBRARY)

$(RUNTIME_LIBRARY): convexext.c
	mkdir -p $(BUILD)/runtime
	$(CC) $(CFLAGS) -shared -o $@ convexext.c $(LDFLAGS) $(LIBS)

$(TEST_LIBRARY): convexext.c
	mkdir -p $(BUILD)/test
	$(CC) $(CFLAGS) -DCONVEX_TEST_HOOKS -shared -o $@ convexext.c $(LDFLAGS) $(LIBS)

clean:
	rm -rf $(BUILD)
