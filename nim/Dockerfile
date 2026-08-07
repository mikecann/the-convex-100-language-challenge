# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG NIM_IMAGE=nimlang/nim:2.2.4@sha256:5c7c425b6060830de60b99bd9436b8e1a17931912b629dafc71240b18ae1eb26
FROM --platform=linux/amd64 ${NIM_IMAGE} AS build
WORKDIR /src
ADD --checksum=sha256:d4f66d6f840084738e04eda36763f5a1badb2ddf5522cdae28d587035d39e1e2 https://github.com/treeform/ws/archive/refs/tags/0.6.0.tar.gz /tmp/ws.tgz
RUN tar -xzf /tmp/ws.tgz -C /opt
COPY client ./client
COPY examples ./examples
RUN httpclient_source="$(find /opt /usr/local -path '*/lib/pure/httpclient.nim' -print -quit)" && \
    test -n "$httpclient_source" && \
    perl /src/client/patch-httpclient.pl "$httpclient_source" && \
    perl /src/client/patch-ws.pl /opt/ws-0.6.0/src/ws.nim && \
    grep -F 'convexHttpResponseLimit' "$httpclient_source" && \
    grep -F 'Convex-Client' /opt/ws-0.6.0/src/ws.nim
# Each compilation is its own layer. The commands and assertions are identical
# to a single combined step, but an emulated amd64 lane whose gcc dies randomly
# resumes from the last good binary instead of restarting all twelve.
# nimpretty has no --check flag: an unrecognised long option makes it print its
# usage and exit 0, and `find -exec` discards the exit status anyway, so the
# previous gate formatted nothing and could never fail. Reformat a copy of each
# source into a scratch tree and compare, so a difference is a build failure
# with the offending diff attached.
RUN set -eu; \
    rm -rf /tmp/format-check; \
    mkdir -p /tmp/format-check; \
    find client examples -name '*.nim' -print | sort > /tmp/format-check/sources; \
    test -s /tmp/format-check/sources; \
    unformatted=0; \
    while IFS= read -r source; do \
      copy="/tmp/format-check/tree/$source"; \
      mkdir -p "$(dirname "$copy")"; \
      if ! nimpretty --out:"$copy" "$source"; then \
        echo "nimpretty failed on: $source" >&2; \
        exit 1; \
      fi; \
      if test ! -s "$copy"; then \
        echo "nimpretty produced no output for: $source" >&2; \
        exit 1; \
      fi; \
      if ! cmp -s "$source" "$copy"; then \
        echo "unformatted source: $source" >&2; \
        diff -u "$source" "$copy" >&2 || true; \
        unformatted=$((unformatted + 1)); \
      fi; \
    done < /tmp/format-check/sources; \
    if test "$unformatted" -ne 0; then \
      echo "$unformatted checked-in Nim source(s) are not nimpretty-clean" >&2; \
      exit 1; \
    fi; \
    echo "PASS every checked-in Nim source is nimpretty-clean"; \
    rm -rf /tmp/format-check
RUN ulimit -s 65536 && \
    test "$(uname -m)" = x86_64 && \
    nim check -d:ssl --threads:on --mm:orc --path:/opt/ws-0.6.0/src client/convex.nim
RUN ulimit -s 65536 && \
    nim c -d:ssl -d:convexadapter --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-convex-adapter client/tests/conformance/main.nim
RUN ulimit -s 65536 && \
    nim c -d:ssl --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-convex-example examples/basics/main.nim
RUN ulimit -s 65536 && \
    nim c -d:ssl -d:convexadapter --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-reconnect-test client/tests/conformance/reconnect_test.nim
RUN ulimit -s 65536 && \
    nim c --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --out:/out-client-test client/tests/client_test.nim
RUN ulimit -s 65536 && \
    nim c --threads:on --mm:orc --hints:off --warnings:on --styleCheck:hint --out:/out-adapter-protocol-test client/tests/conformance/adapter_protocol_test.nim
RUN ulimit -s 65536 && \
    nim c --threads:on --mm:orc --hints:off --warnings:on --styleCheck:hint --out:/out-output-test client/tests/conformance/output_test.nim
RUN ulimit -s 65536 && \
    nim c --threads:on --mm:orc --hints:off --warnings:on --styleCheck:hint --out:/out-adapter-tcp-test client/tests/conformance/adapter_tcp_test.nim
RUN ulimit -s 65536 && \
    nim c -d:ssl -d:nimtesthooks --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-live-state-test client/tests/live_state_test.nim
RUN ulimit -s 65536 && \
    nim c -d:ssl -d:convexadapter --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-live-socket-test client/tests/live_socket_test.nim
RUN ulimit -s 65536 && \
    nim c -d:ssl -d:nimtesthooks --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-http-stream-test client/tests/http_stream_test.nim
RUN ulimit -s 65536 && \
    nim c -d:ssl --threads:on --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-large-value-fixture client/tests/conformance/large_value_fixture.nim
RUN ulimit -s 65536 && \
    nim c --threads:on --mm:orc --hints:off --warnings:on --styleCheck:hint --out:/out-final-adapter-rss-test client/tests/conformance/final_adapter_rss_test.nim
RUN test -x /out-convex-adapter && test -x /out-convex-example && test -x /out-reconnect-test && test -x /out-client-test && \
    test -x /out-adapter-protocol-test && test -x /out-output-test && test -x /out-adapter-tcp-test && test -x /out-live-state-test && test -x /out-live-socket-test && test -x /out-http-stream-test && test -x /out-large-value-fixture && test -x /out-final-adapter-rss-test

FROM build AS test
RUN /out-client-test && /out-adapter-protocol-test && /out-output-test && /out-adapter-tcp-test && /out-live-state-test && /out-live-socket-test && /out-http-stream-test && /out-final-adapter-rss-test && \
    long_id="$(perl -e 'print "x" x 129')" && \
    printf '%s\n' '{' '{"id":7,"op":"close"}' '{"id":null,"op":"close"}' "{\"id\":\"$long_id\",\"op\":\"close\"}" '{"id":"wrong-op","op":7}' '{"id":"extra","op":"close","extra":true}' '{"id":"null-token","op":"setAuth","token":null}' '{"id":"hello","op":"hello","protocolVersion":1}' '{"id":"close","op":"close"}' | /out-convex-adapter >/tmp/adapter.ndjson && \
    test "$(wc -l </tmp/adapter.ndjson)" -eq 9 && \
    test "$(grep -c -F '"type":"error"' /tmp/adapter.ndjson)" -eq 7 && \
    ! grep -F '"id":""' /tmp/adapter.ndjson && ! grep -F '"id":7' /tmp/adapter.ndjson && \
    grep -F '"id":"extra"' /tmp/adapter.ndjson >/dev/null && \
    grep -F '"id":"wrong-op"' /tmp/adapter.ndjson >/dev/null && \
    grep -F '"id":"null-token"' /tmp/adapter.ndjson >/dev/null && \
    grep -F '"type":"ready"' /tmp/adapter.ndjson >/dev/null && \
    grep -F '"type":"closed"' /tmp/adapter.ndjson >/dev/null

FROM --platform=linux/amd64 debian:12.11-slim@sha256:b1a741487078b369e78119849663d7f1a5341ef2768798f7b7406c4240f86aef AS runtime-files
RUN apt-get update && apt-get install --yes --no-install-recommends ca-certificates=20230311+deb12u1
COPY --from=build /out-convex-adapter /tmp/closure/convex-adapter
COPY --from=build /out-convex-example /tmp/closure/convex-example
RUN set -eu; \
    runtime_libs=/usr/lib/x86_64-linux-gnu.runtime; \
    mkdir -p "$runtime_libs"; \
    for executable in \
      /tmp/closure/convex-adapter /tmp/closure/convex-example \
      /usr/lib/x86_64-linux-gnu/libssl.so.3 \
      /usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
      /usr/bin/mawk /usr/bin/basename /usr/bin/cat /usr/bin/cmp \
      /usr/bin/cut /usr/bin/dash /usr/bin/dirname /usr/bin/env \
      /usr/bin/find /usr/bin/grep /usr/bin/head /usr/bin/id /usr/bin/ls \
      /usr/bin/ln /usr/bin/mkdir /usr/bin/printf /usr/bin/readlink /usr/bin/rm /usr/bin/sed /usr/bin/sort \
      /usr/bin/tail /usr/bin/tr /usr/bin/true /usr/bin/uname /usr/bin/wc; do \
      ldd "$executable" | awk '{ for (field = 1; field <= NF; field++) if ($field ~ /^\//) print $field }'; \
    done | sort -u > /tmp/runtime-library-paths; \
    while IFS= read -r library; do cp -L "$library" "$runtime_libs/$(basename "$library")"; done < /tmp/runtime-library-paths; \
    for library in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      test ! -e "/usr/lib/x86_64-linux-gnu/$library" || cp -L "/usr/lib/x86_64-linux-gnu/$library" "$runtime_libs/$library"; \
    done; \
    # Nim's -d:ssl loads OpenSSL through dlopen, so ldd above reports neither
    # library. Copy both explicitly or the pruned runtime has no TLS at all.
    for library in libssl.so.3 libcrypto.so.3; do \
      cp -L "/usr/lib/x86_64-linux-gnu/$library" "$runtime_libs/$library"; \
    done; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$runtime_libs/ossl-modules"
# Perl is a build-stage pruner only. This single running process can replace
# its own library directory without leaving Perl or package residue behind.
#
# The regular-file branch below used to open($to, '>') and stop there. Perl
# creates a new file at mode 0666 minus umask -- buildkit's RUN umask is 0022,
# so every copied file landed at 0644 regardless of its source permissions.
# Nobody noticed for the shared libraries (dlopen doesn't check the execute
# bit), but /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 is in this same
# closure, and the kernel's loader opens an ELF interpreter through the same
# MAY_EXEC path it uses for the binary itself. With ld.so at 0644, every
# dynamically linked executable in the image -- starting with the very next
# RUN's /bin/sh -- fails to exec with "permission denied". Reading each
# source file's mode with stat and chmod-ing the copy to match, the same way
# the shell-based rootfs stagers in this repo preserve bits with
# `stat -c %a`, keeps the copy a single self-contained Perl process while no
# longer flattening every mode to 0644.
RUN perl -MFile::Path=make_path,remove_tree -e '\
      my $source = q{/usr/lib/x86_64-linux-gnu.runtime}; \
      my $target = q{/usr/lib/x86_64-linux-gnu}; \
      remove_tree($target); \
      sub copy_tree { \
        my ($from, $to) = @_; \
        if (-d $from) { \
          make_path($to); \
          opendir(my $directory, $from) or die $!; \
          for my $name (grep { $_ ne q{.} && $_ ne q{..} } readdir($directory)) { \
            copy_tree(qq{$from/$name}, qq{$to/$name}); \
          } \
          closedir($directory); \
        } elsif (-l $from) { \
          symlink(readlink($from), $to) or die $!; \
        } else { \
          my $mode = (stat($from))[2] & 07777; \
          open(my $input, q{<}, $from) or die $!; \
          open(my $output, q{>}, $to) or die $!; \
          binmode($input); binmode($output); \
          my $buffer; \
          while (read($input, $buffer, 1048576)) { print {$output} $buffer or die $! } \
          close($input); close($output); \
          chmod($mode, $to) or die $!; \
        } \
      } \
      copy_tree($source, $target); \
      remove_tree($source);'
RUN set -eu; \
    rm -f /usr/bin/awk; \
    ln -s mawk /usr/bin/awk; \
    find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /bin /sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /bin/sh|/usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cat|/usr/bin/cmp|/usr/bin/cut|/usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head|/usr/bin/id|/usr/bin/ln|/usr/bin/ls|/usr/bin/mkdir|/usr/bin/printf|/usr/bin/readlink|/usr/bin/rm|/usr/bin/sed|/usr/bin/sh|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname|/usr/bin/wc) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    rm -rf \
      /etc/alternatives /etc/apt /etc/cron.d /etc/cron.daily /etc/cron.hourly \
      /etc/cron.monthly /etc/cron.weekly /etc/crontab /etc/debconf.conf \
      /etc/dpkg /etc/init.d /etc/logrotate.conf /etc/logrotate.d /etc/rc0.d \
      /etc/rc1.d /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d \
      /etc/rcS.d /etc/systemd /usr/games /usr/include /usr/lib/apt \
      /usr/lib/dpkg /usr/lib/init /usr/lib/systemd /usr/lib/udev \
      /usr/libexec /usr/share /usr/src \
      /usr/local/man /usr/local/share /var/backups /var/cache /var/lib \
      /var/local /var/mail /var/opt /var/spool /var/tmp /var/log/* \
      /tmp/closure /tmp/runtime-commands /tmp/runtime-library-paths; \
    rm -rf /usr/lib/ssl; \
    find /etc/ssl/certs -mindepth 1 ! -name ca-certificates.crt -delete; \
    rm -rf /etc/ssl/misc /etc/ssl/private; \
    mkdir -p /usr/lib/ssl; \
    ln -s /etc/ssl/openssl.cnf /usr/lib/ssl/openssl.cnf; \
    ln -s /etc/ssl/certs/ca-certificates.crt /usr/lib/ssl/cert.pem; \
    ln -s /etc/ssl/certs /usr/lib/ssl/certs; \
    find /etc -mindepth 1 -maxdepth 1 -print > /tmp/runtime-etc; \
    while IFS= read -r path; do \
      case "$path" in \
        /etc/gai.conf|/etc/group|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf|/etc/ld.so.conf.d|/etc/localtime|/etc/nsswitch.conf|/etc/passwd|/etc/resolv.conf|/etc/ssl|/etc/timezone) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-etc; \
    printf '%s\n' 'app:x:65532:65532:app:/nonexistent:/bin/sh' > /etc/passwd; \
    printf '%s\n' 'app:x:65532:' > /etc/group; \
    rm -f /tmp/runtime-etc /usr/bin/ln /usr/bin/mkdir /usr/bin/rm; \
    expected_commands='awk basename cat cmp cut dash dirname env find grep head id ls mawk printf readlink sed sh sort tail tr true uname wc '; \
    actual_commands="$(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' | sort -u | tr '\n' ' ')"; \
    if test "$actual_commands" != "$expected_commands"; then \
      echo "command surface mismatch" >&2; \
      echo "expected: $expected_commands" >&2; \
      echo "actual:   $actual_commands" >&2; \
      exit 1; \
    fi; \
    for command in apt apt-get apt-cache dpkg dpkg-query debconf update-alternatives openssl c_rehash curl wget nc netcat socat telnet ftp ssh scp sftp ping hostname getent gcc g++ cc make cmake ld as ar nm strip objcopy objdump readelf perl ruby php lua java go rustc cargo dotnet python python3 pip pip3 node npm npx convex cp mv chmod chown dd mkfifo mktemp xargs; do \
      if command -v "$command" >/dev/null 2>&1; then echo "forbidden runtime command: $command" >&2; exit 1; fi; \
    done; \
    for required in /etc/ssl/certs/ca-certificates.crt /etc/ssl/openssl.cnf \
      /usr/lib/ssl/cert.pem /usr/lib/x86_64-linux-gnu/libssl.so.3 \
      /usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
      /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; do \
      if test ! -r "$required"; then echo "missing TLS file: $required" >&2; exit 1; fi; \
    done; \
    if test ! -d /usr/lib/ssl/certs; then echo "missing TLS dir: /usr/lib/ssl/certs" >&2; exit 1; fi; \
    residue="$(find /etc /usr /var \( -iname 'apt' -o -iname 'apt-*' -o -iname 'dpkg' -o -iname 'dpkg-*' -o -iname 'perl' -o -iname 'perl-*' -o -iname '*.pl' -o -iname '*.pm' -o -iname 'libapt*' -o -iname 'openssl' -o -iname 'curl' -o -iname 'wget' -o -iname 'nc' -o -iname 'node' -o -iname 'python*' \) 2>/dev/null)"; \
    if test -n "$residue"; then echo "forbidden residue remained:" >&2; echo "$residue" >&2; exit 1; fi; \
    find /etc /usr /var -type f -print > /tmp/runtime-files; \
    remaining_scripts=""; \
    while IFS= read -r path; do \
      if test "$(head -c 2 "$path")" = '#!'; then remaining_scripts="$remaining_scripts $path"; fi; \
    done < /tmp/runtime-files; \
    if test -n "$remaining_scripts"; then \
      echo "scripts remained in runtime:" >&2; \
      for path in $remaining_scripts; do echo "  $path" >&2; done; \
      exit 1; \
    fi; \
    find /tmp/runtime-files -delete
FROM runtime-files AS runtime-base
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=build --chown=65532:65532 --chmod=0555 /out-convex-example /usr/local/bin/convex-example
RUN set -eu; \
    expected_commands='awk basename cat cmp convex-example cut dash dirname env find grep head id ls mawk printf readlink sed sh sort tail tr true uname wc '; \
    actual_commands="$(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' | sort -u | tr '\n' ' ')"; \
    if test "$actual_commands" != "$expected_commands"; then \
      echo "command surface mismatch" >&2; \
      echo "expected: $expected_commands" >&2; \
      echo "actual:   $actual_commands" >&2; \
      exit 1; \
    fi; \
    test ! -e /usr/bin/perl; \
    test ! -e /usr/bin/openssl
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=build --chown=65532:65532 --chmod=0555 /out-convex-adapter /usr/local/bin/convex-adapter
RUN set -eu; \
    expected_commands='awk basename cat cmp convex-adapter cut dash dirname env find grep head id ls mawk printf readlink sed sh sort tail tr true uname wc '; \
    actual_commands="$(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' | sort -u | tr '\n' ' ')"; \
    if test "$actual_commands" != "$expected_commands"; then \
      echo "command surface mismatch" >&2; \
      echo "expected: $expected_commands" >&2; \
      echo "actual:   $actual_commands" >&2; \
      exit 1; \
    fi; \
    test ! -e /usr/bin/perl; \
    test ! -e /usr/bin/openssl
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
