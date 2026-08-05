# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
FROM gcc:14.2.0-bookworm@sha256:b99b86a28812b1e6453a231a947dc43d76fe192788a12f344a9b568bf9f5d24c AS build
RUN apt-get update && \
    apt-get install --no-install-recommends -y libc-ares-dev=1.18.1-3 libcurl4-openssl-dev=7.88.1-10+deb12u15 libssl-dev=3.0.20-1~deb12u2 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN mkdir -p /build && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread -c client/curl_transport.c -o /build-curl_transport.o && \
    gfortran -cpp -std=f2018 -O2 -Wall -Wextra -Werror -ffree-line-length-none -J /build -c client/convex.f90 -o /build-convex.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-curl_transport.o examples/basics/main.f90 -lcares -lcurl -lssl -lcrypto -o /out-example && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -J /build -I /build -c client/tests/conformance/transport.f90 -o /build-adapter-transport.o && \
    gfortran -cpp -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-adapter-transport.o /build-curl_transport.o client/tests/conformance/main.f90 -lcares -lcurl -lssl -lcrypto -o /out-adapter && \
    gfortran -cpp -DFORTRAN_ADAPTER_TESTING -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-adapter-transport.o /build-curl_transport.o client/tests/conformance/main.f90 -lcares -lcurl -lssl -lcrypto -o /out-adapter-test && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread -c client/tests/live_owner_fixture.c -o /build-live-owner-fixture.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-curl_transport.o /build-live-owner-fixture.o client/tests/test_live_owner.f90 -lcares -lcurl -lssl -lcrypto -o /out-live-owner-test && \
    mkdir -p /build-relay && \
    gfortran -cpp -DFORTRAN_ADAPTER_TESTING -DFORTRAN_ADAPTER_MODULE_ONLY -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -J /build-relay -I /build -c client/tests/conformance/main.f90 -o /build-adapter-state-test.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build-relay -I /build /build-convex.o /build-adapter-transport.o /build-curl_transport.o /build-adapter-state-test.o client/tests/conformance/test_relay_barrier.f90 -lcares -lcurl -lssl -lcrypto -o /out-relay-barrier-test && \
    gfortran -cpp -DFORTRAN_TESTING -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -g -fcheck=all -J /build -c client/convex.f90 -o /build-convex-test.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex-test.o /build-curl_transport.o client/tests/test_client.f90 -lcares -lcurl -lssl -lcrypto -o /out-test && \
    gcc -DFORTRAN_TRANSPORT_TESTING -std=c17 -Wall -Wextra -Werror -pthread -c client/curl_transport.c -o /build-curl-transport-stall.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex-test.o /build-curl-transport-stall.o client/tests/test_close_dns.f90 -lcares -lcurl -lssl -lcrypto -o /out-close-dns-test && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread client/tests/transport_socket_test.c /build-curl_transport.o -lcares -lcurl -lssl -lcrypto -o /out-transport-test && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread client/tests/conformance/adapter_process_test.c /build-live-owner-fixture.o -lcrypto -o /out-adapter-process-test && \
    file /out-adapter | grep -F 'x86-64' && \
    strip /out-example /out-adapter

FROM build AS test
RUN test "$(uname -m)" = x86_64 && /out-test && /out-transport-test && /out-live-owner-test && /out-close-dns-test && /out-relay-barrier-test && /out-adapter-process-test && \
    actual=$(printf '%s\n' \
      '{"id":"hello","protocolVersion":1,"op":"hello"}' \
      '{"id":"close","op":"close"}' | /out-adapter) && \
    printf '%s\n' "$actual" | grep -F '"id":"hello","type":"ready"' && \
    printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
CMD ["/bin/sh", "-c", "true"]

FROM debian:12.11-slim@sha256:b1a741487078b369e78119849663d7f1a5341ef2768798f7b7406c4240f86aef AS runtime-base
RUN apt-get update && \
    apt-get install --no-install-recommends -y libc-ares2=1.18.1-3 libcurl4=7.88.1-10+deb12u15 libssl3=3.0.20-1~deb12u2 \
      openssl=3.0.20-1~deb12u2 ca-certificates=20230311+deb12u1 libgfortran5=12.2.0-14+deb12u1 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /out-adapter /tmp/convex-adapter
COPY --from=build /out-example /tmp/convex-example
RUN set -eu; \
    runtime_libs=/usr/lib/x86_64-linux-gnu.runtime; \
    mkdir -p "$runtime_libs"; \
    for executable in \
      /tmp/convex-adapter /tmp/convex-example \
      /usr/bin/mawk /usr/bin/basename /usr/bin/cmp /usr/bin/cut \
      /usr/bin/dash /usr/bin/dirname /usr/bin/env /usr/bin/find \
      /usr/bin/grep /usr/bin/head /usr/bin/id /usr/bin/ls \
      /usr/bin/printf /usr/bin/readlink /usr/bin/sed /usr/bin/sort \
      /usr/bin/tail /usr/bin/tr /usr/bin/true /usr/bin/uname /usr/bin/wc; do \
      ldd "$executable" | awk '{ for (field = 1; field <= NF; field++) if ($field ~ /^\//) print $field }'; \
    done | sort -u > /tmp/runtime-library-paths; \
    while IFS= read -r library; do \
      cp -L "$library" "$runtime_libs/$(basename "$library")"; \
    done < /tmp/runtime-library-paths; \
    for library in libnss_dns.so.2 libnss_files.so.2; do \
      if test -e "/usr/lib/x86_64-linux-gnu/$library"; then \
        cp -L "/usr/lib/x86_64-linux-gnu/$library" "$runtime_libs/$library"; \
      fi; \
    done; \
    cp -a /usr/lib/x86_64-linux-gnu/engines-3 "$runtime_libs/engines-3"; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$runtime_libs/ossl-modules"
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
          open(my $input, q{<}, $from) or die $!; \
          open(my $output, q{>}, $to) or die $!; \
          binmode($input); binmode($output); \
          my $buffer; \
          while (read($input, $buffer, 1048576)) { print {$output} $buffer or die $! } \
          close($input); close($output); \
        } \
      } \
      copy_tree($source, $target); \
      remove_tree($source);'
RUN set -eu; \
    rm -f /usr/bin/awk; \
    ln -s mawk /usr/bin/awk; \
    find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cmp|/usr/bin/cut|/usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head|/usr/bin/id|/usr/bin/ls|/usr/bin/printf|/usr/bin/readlink|/usr/bin/rm|/usr/bin/sed|/usr/bin/sh|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname|/usr/bin/wc) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    rm -rf \
      /etc/alternatives /etc/apt /etc/cron.d /etc/cron.daily \
      /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly /etc/crontab \
      /etc/debconf.conf /etc/dpkg /etc/init.d /etc/logrotate.conf \
      /etc/logrotate.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d \
      /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d /etc/systemd \
      /usr/games /usr/include /usr/lib/apt /usr/lib/dpkg /usr/lib/systemd \
      /usr/libexec /usr/share /usr/src /usr/local/man /usr/local/share \
      /var/backups /var/cache /var/lib /var/local /var/mail /var/opt \
      /var/spool /var/tmp /var/log/* /tmp/convex-adapter \
      /tmp/convex-example /tmp/runtime-commands /tmp/runtime-library-paths \
      /tmp/runtime-libs; \
    find /etc -mindepth 1 -maxdepth 1 -print > /tmp/runtime-etc; \
    while IFS= read -r path; do \
      case "$path" in \
        /etc/gai.conf|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf|/etc/ld.so.conf.d|/etc/localtime|/etc/nsswitch.conf|/etc/resolv.conf|/etc/ssl|/etc/timezone) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-etc; \
    rm -f /tmp/runtime-etc; \
    find /usr/lib -mindepth 1 -maxdepth 1 -print > /tmp/runtime-usr-lib; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/lib/locale|/usr/lib/ssl|/usr/lib/x86_64-linux-gnu) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-usr-lib; \
    rm -f /tmp/runtime-usr-lib; \
    for path in \
      /etc/alternatives /etc/apt /etc/cron.d /etc/cron.daily /etc/dpkg \
      /etc/init.d /etc/logrotate.d /etc/systemd /usr/lib/apt /usr/lib/dpkg \
      /usr/lib/systemd /usr/libexec /usr/share /var/cache /var/lib /var/spool; do \
      if test -e "$path"; then echo "forbidden runtime artifact: $path" >&2; exit 1; fi; \
    done; \
    for path in /etc/*; do \
      if test ! -e "$path" && test ! -L "$path"; then continue; fi; \
      case "$path" in \
        /etc/gai.conf|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf|/etc/ld.so.conf.d|/etc/localtime|/etc/nsswitch.conf|/etc/resolv.conf|/etc/ssl|/etc/timezone) ;; \
        *) echo "unexpected runtime config: $path" >&2; exit 1 ;; \
      esac; \
    done; \
    for path in /usr/lib/*; do \
      if test ! -e "$path" && test ! -L "$path"; then continue; fi; \
      case "$path" in \
        /usr/lib/locale|/usr/lib/ssl|/usr/lib/x86_64-linux-gnu) ;; \
        *) echo "unexpected runtime library tree: $path" >&2; exit 1 ;; \
      esac; \
    done; \
    if find /usr/lib/x86_64-linux-gnu -xdev \
      \( -name 'libapt*' -o -name 'libdebconf*' -o -name 'perl-base' \) \
      -print -quit | grep -q .; then \
      echo 'forbidden package library remains' >&2; exit 1; \
    fi; \
    rm -f /usr/bin/rm; \
    if test -e /usr/bin/rm; then echo 'forbidden runtime command: rm' >&2; exit 1; fi; \
    for command in apt apt-get apt-cache dpkg dpkg-query debconf update-alternatives openssl curl wget gcc gfortran perl python python3 node npm convex cp mv chmod chown dd mkfifo mktemp xargs; do \
      if command -v "$command" >/dev/null 2>&1; then echo "forbidden runtime command: $command" >&2; exit 1; fi; \
    done; \
    true
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
