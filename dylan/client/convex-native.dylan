module: convex

// -------------------------------------------------------------------------
// Native transport boundary.
//
// Everything in this file is a direct C-FFI declaration of a POSIX libc or
// OpenSSL entry point -- there is no C source file anywhere in this client.
// This file has no knowledge of HTTP, JSON, WebSocket framing, or the
// Convex sync protocol; it only opens sockets, drives a TLS handshake, and
// moves bytes. Every other file in client/ is pure Dylan built on top of
// the small surface exported here: cx-connect-tcp, cx-connect-tls,
// cx-read, cx-write, cx-close, cx-now-ms, cx-random-bytes, and cx-getenv.
// -------------------------------------------------------------------------

define constant $af-inet = 2;
define constant $af-inet6 = 10;
define constant $sock-stream = 1;
define constant $sock-nonblock = 2048; // Linux-specific socket() flag.
define constant $ipproto-tcp = 6;

define constant $pollin = 1;
define constant $pollout = 4;

define constant $sol-socket = 1;
define constant $so-error = 4;

define constant $clock-monotonic = 1;

define constant $ssl-ctrl-set-tlsext-hostname = 55;
define constant $tlsext-nametype-host-name = 0;
define constant $ssl-error-want-read = 2;
define constant $ssl-error-want-write = 3;

// -- addrinfo: only the fields this client actually reads. ai-addr,
// ai-canonname, and ai-next are kept as raw <C-void*> rather than typed
// pointers so this struct never needs to reference itself; each is cast
// to the type it actually is at the point of use. --
define C-struct <addrinfo>
  slot ai-flags :: <C-int>;
  slot ai-family :: <C-int>;
  slot ai-socktype :: <C-int>;
  slot ai-protocol :: <C-int>;
  slot ai-addrlen :: <C-unsigned-int>;
  slot ai-addr :: <C-void*>;
  slot ai-canonname :: <C-void*>;
  slot ai-next :: <C-void*>;
  pointer-type-name: <addrinfo*>;
end C-struct;

define C-pointer-type <addrinfo**> => <addrinfo*>;

// Used only by cx-listen-accept, to bind the adapter's own IPv4 listen
// socket when ADAPTER_LISTEN is set; every outbound connection instead
// goes through getaddrinfo above, which never needs this struct's layout
// exposed to Dylan directly.
define C-struct <sockaddr-in>
  slot sin-family :: <C-unsigned-short>;
  slot sin-port :: <C-unsigned-short>;
  slot sin-addr :: <C-unsigned-int>;
  array slot sin-zero :: <C-char>, length: 8;
  pointer-type-name: <sockaddr-in*>;
end C-struct;

define C-struct <pollfd>
  slot pfd-fd :: <C-int>;
  slot pfd-events :: <C-short>;
  slot pfd-revents :: <C-short>;
  pointer-type-name: <pollfd*>;
end C-struct;

define C-struct <timespec>
  slot ts-sec :: <C-long>;
  slot ts-nsec :: <C-long>;
  pointer-type-name: <timespec*>;
end C-struct;

define C-function c-getaddrinfo
  parameter node :: <C-string>;
  parameter service :: <C-string>;
  parameter hints :: <addrinfo*>;
  parameter res :: <addrinfo**>;
  result rc :: <C-int>;
  c-name: "getaddrinfo";
end C-function;

define C-function c-freeaddrinfo
  parameter res :: <addrinfo*>;
  c-name: "freeaddrinfo";
end C-function;

define C-function c-socket
  parameter afamily :: <C-int>;
  parameter socktype :: <C-int>;
  parameter proto :: <C-int>;
  result fd :: <C-int>;
  c-name: "socket";
end C-function;

define C-function c-connect
  parameter fd :: <C-int>;
  parameter addr :: <C-void*>;
  parameter addrlen :: <C-unsigned-int>;
  result rc :: <C-int>;
  c-name: "connect";
end C-function;

define C-function c-poll
  parameter fds :: <pollfd*>;
  parameter nfds :: <C-unsigned-long>;
  parameter timeout-ms :: <C-int>;
  result rc :: <C-int>;
  c-name: "poll";
end C-function;

define C-function c-getsockopt
  parameter fd :: <C-int>;
  parameter level :: <C-int>;
  parameter optname :: <C-int>;
  parameter optval :: <C-void*>;
  parameter optlen :: <C-void*>;
  result rc :: <C-int>;
  c-name: "getsockopt";
end C-function;

define C-function c-recv
  parameter fd :: <C-int>;
  parameter buf :: <C-void*>;
  parameter len :: <C-unsigned-long>;
  parameter flags :: <C-int>;
  result n :: <C-long>;
  c-name: "recv";
end C-function;

define C-function c-send
  parameter fd :: <C-int>;
  parameter buf :: <C-void*>;
  parameter len :: <C-unsigned-long>;
  parameter flags :: <C-int>;
  result n :: <C-long>;
  c-name: "send";
end C-function;

define C-function c-close
  parameter fd :: <C-int>;
  result rc :: <C-int>;
  c-name: "close";
end C-function;

// read()/write() (rather than recv()/send()) so the same <connection>
// wrapper works uniformly over a real socket, an inherited stdin/stdout
// pipe, and a TTY -- all of which the adapter's command channel may be,
// depending on whether ADAPTER_LISTEN is set.
define C-function c-read
  parameter fd :: <C-int>;
  parameter buf :: <C-void*>;
  parameter count :: <C-unsigned-long>;
  result n :: <C-long>;
  c-name: "read";
end C-function;

define C-function c-write
  parameter fd :: <C-int>;
  parameter buf :: <C-void*>;
  parameter count :: <C-unsigned-long>;
  result n :: <C-long>;
  c-name: "write";
end C-function;

define C-function c-bind
  parameter fd :: <C-int>;
  parameter addr :: <C-void*>;
  parameter addrlen :: <C-unsigned-int>;
  result rc :: <C-int>;
  c-name: "bind";
end C-function;

define C-function c-listen
  parameter fd :: <C-int>;
  parameter backlog :: <C-int>;
  result rc :: <C-int>;
  c-name: "listen";
end C-function;

define C-function c-accept
  parameter fd :: <C-int>;
  parameter addr :: <C-void*>;
  parameter addrlen :: <C-void*>;
  result client-fd :: <C-int>;
  c-name: "accept";
end C-function;

define C-function c-setsockopt
  parameter fd :: <C-int>;
  parameter level :: <C-int>;
  parameter optname :: <C-int>;
  parameter optval :: <C-void*>;
  parameter optlen :: <C-unsigned-int>;
  result rc :: <C-int>;
  c-name: "setsockopt";
end C-function;

define constant $so-reuseaddr = 2;

define C-function c-htons
  parameter host-short :: <C-unsigned-short>;
  result value :: <C-unsigned-short>;
  c-name: "htons";
end C-function;

define C-function c-htonl
  parameter host-long :: <C-unsigned-int>;
  result value :: <C-unsigned-int>;
  c-name: "htonl";
end C-function;

define C-function c-errno-location
  result loc :: <C-int*>;
  c-name: "__errno_location";
end C-function;

define C-function c-clock-gettime
  parameter clk-id :: <C-int>;
  parameter tp :: <timespec*>;
  result rc :: <C-int>;
  c-name: "clock_gettime";
end C-function;

define C-function c-getrandom
  parameter buf :: <C-void*>;
  parameter buflen :: <C-unsigned-long>;
  parameter flags :: <C-unsigned-int>;
  result n :: <C-long>;
  c-name: "getrandom";
end C-function;

define C-function c-exit
  parameter code :: <C-int>;
  c-name: "exit";
end C-function;

define C-function c-getenv
  parameter name :: <C-string>;
  result value :: <C-string>;
  c-name: "getenv";
end C-function;

// SHA-1 is used only for the WebSocket handshake's Sec-WebSocket-Accept
// check (RFC 6455 section 1.3) -- borrowed from libcrypto rather than
// hand-written, the same way this client borrows TLS from libssl rather
// than implementing a cipher suite.
define C-function c-sha1
  parameter data :: <C-void*>;
  parameter data-len :: <C-unsigned-long>;
  parameter out-md :: <C-void*>;
  result md :: <C-void*>;
  c-name: "SHA1";
end C-function;

define function cx-sha1 (data :: <byte-vector>) => (digest :: <byte-vector>)
  let in-buf :: <C-char*> = make(<C-char*>, element-count: max(data.size, 1));
  for (i from 0 below data.size)
    pointer-value(in-buf, index: i) := data[i];
  end for;
  let out-buf :: <C-char*> = make(<C-char*>, element-count: 20);
  c-sha1(as(<C-void*>, in-buf), data.size, as(<C-void*>, out-buf));
  let result = make(<byte-vector>, size: 20);
  for (i from 0 below 20)
    result[i] := logand(as(<integer>, pointer-value(out-buf, index: i)), 255);
  end for;
  destroy(in-buf);
  destroy(out-buf);
  result
end function;

// -- OpenSSL boundary --

define C-function c-tls-client-method
  result m :: <C-void*>;
  c-name: "TLS_client_method";
end C-function;

define C-function c-ssl-ctx-new
  parameter tls-method :: <C-void*>;
  result ctx :: <C-void*>;
  c-name: "SSL_CTX_new";
end C-function;

define C-function c-ssl-ctx-set-default-verify-paths
  parameter ctx :: <C-void*>;
  result rc :: <C-int>;
  c-name: "SSL_CTX_set_default_verify_paths";
end C-function;

define C-function c-ssl-ctx-set-verify
  parameter ctx :: <C-void*>;
  parameter mode :: <C-int>;
  parameter callback :: <C-void*>;
  c-name: "SSL_CTX_set_verify";
end C-function;

define C-function c-ssl-new
  parameter ctx :: <C-void*>;
  result ssl :: <C-void*>;
  c-name: "SSL_new";
end C-function;

define C-function c-ssl-free
  parameter ssl :: <C-void*>;
  c-name: "SSL_free";
end C-function;

define C-function c-ssl-set-fd
  parameter ssl :: <C-void*>;
  parameter fd :: <C-int>;
  result rc :: <C-int>;
  c-name: "SSL_set_fd";
end C-function;

define C-function c-ssl-set1-host
  parameter ssl :: <C-void*>;
  parameter hostname :: <C-string>;
  result rc :: <C-long>;
  c-name: "SSL_set1_host";
end C-function;

define C-function c-ssl-ctrl
  parameter ssl :: <C-void*>;
  parameter cmd :: <C-int>;
  parameter larg :: <C-long>;
  parameter parg :: <C-string>;
  result rc :: <C-long>;
  c-name: "SSL_ctrl";
end C-function;

define C-function c-ssl-connect
  parameter ssl :: <C-void*>;
  result rc :: <C-int>;
  c-name: "SSL_connect";
end C-function;

define C-function c-ssl-get-error
  parameter ssl :: <C-void*>;
  parameter ret :: <C-int>;
  result e :: <C-int>;
  c-name: "SSL_get_error";
end C-function;

define C-function c-ssl-get-verify-result
  parameter ssl :: <C-void*>;
  result v :: <C-long>;
  c-name: "SSL_get_verify_result";
end C-function;

define C-function c-ssl-read
  parameter ssl :: <C-void*>;
  parameter buf :: <C-void*>;
  parameter num :: <C-int>;
  result n :: <C-int>;
  c-name: "SSL_read";
end C-function;

define C-function c-ssl-write
  parameter ssl :: <C-void*>;
  parameter buf :: <C-void*>;
  parameter num :: <C-int>;
  result n :: <C-int>;
  c-name: "SSL_write";
end C-function;

define C-function c-ssl-shutdown
  parameter ssl :: <C-void*>;
  result rc :: <C-int>;
  c-name: "SSL_shutdown";
end C-function;

// One process-wide SSL_CTX, created lazily. Its default-verify-paths call
// is what makes hosted (real Convex) TLS verification honest: it loads
// exactly the system trust store the container's OpenSSL was built to
// look at, rather than a bundled or skipped check.
define variable *ssl-ctx* :: false-or(<C-void*>) = #f;

define function cx-ssl-ctx () => (ctx :: <C-void*>)
  if (~*ssl-ctx*)
    let ctx = c-ssl-ctx-new(c-tls-client-method());
    c-ssl-ctx-set-default-verify-paths(ctx);
    c-ssl-ctx-set-verify(ctx, 1 /* SSL_VERIFY_PEER */, null-pointer(<C-void*>));
    *ssl-ctx* := ctx;
  end if;
  *ssl-ctx*
end function;

define function cx-now-ms () => (ms :: <integer>)
  let ts :: <timespec*> = make(<timespec*>);
  c-clock-gettime($clock-monotonic, ts);
  let result = ts-sec(ts) * 1000 + truncate/(ts-nsec(ts), 1000000);
  destroy(ts);
  result
end function;

define function cx-getenv (name :: <string>) => (value :: false-or(<byte-string>))
  let raw = c-getenv(name);
  // c-getenv's result is a <C-string> wrapper, not a real Dylan string;
  // every caller here needs genuine <byte-string> content (indexing,
  // copy-sequence, = comparison against literals), so it is converted
  // explicitly rather than relying on it merely looking string-like.
  if (raw & raw.size > 0) as(<byte-string>, raw) else #f end if
end function;

define function cx-random-bytes (count :: <integer>) => (bytes :: <byte-vector>)
  let buf :: <C-char*> = make(<C-char*>, element-count: count);
  let got = c-getrandom(as(<C-void*>, buf), count, 0);
  let result = make(<byte-vector>, size: count);
  for (i from 0 below count)
    result[i] := logand(as(<integer>, pointer-value(buf, index: i)), 255);
  end for;
  destroy(buf);
  if (got ~= count)
    error("getrandom short read");
  end if;
  result
end function;

// -- connection: a small handle bundling an fd with an optional TLS
// session. Every other module reads and writes through this, never the
// raw fd, so TLS and plaintext connections share one call shape. --
define class <connection> (<object>)
  slot conn-fd :: <integer>, required-init-keyword: fd:;
  slot conn-ssl :: false-or(<C-void*>) = #f, init-keyword: ssl:;
end class <connection>;

define function connection-tls? (conn :: <connection>) => (well? :: <boolean>)
  conn.conn-ssl & #t
end function;

// Waits up to deadline-ms (relative, from now) for the fd to become
// readable and/or writable. Returns the poll revents mask, or -1 on
// timeout. A single poll() primitive backs every wait in this client:
// connect readiness, TLS handshake readiness (which can want either
// direction independent of application intent), and ordinary read/write.
define function cx-poll-wait
    (fd :: <integer>, want-read? :: <boolean>, want-write? :: <boolean>,
     deadline-ms :: <integer>)
 => (revents :: <integer>)
  let remaining = deadline-ms - cx-now-ms();
  if (remaining < 0) remaining := 0 end if;
  let pfd :: <pollfd*> = make(<pollfd*>);
  pfd-fd(pfd) := fd;
  pfd-events(pfd) :=
    logior(if (want-read?) $pollin else 0 end if,
           if (want-write?) $pollout else 0 end if);
  pfd-revents(pfd) := 0;
  let rc = c-poll(pfd, 1, remaining);
  let revents = if (rc > 0) pfd-revents(pfd) else -1 end if;
  destroy(pfd);
  revents
end function;

// Resolves host:port (preferring whichever address family getaddrinfo
// offers first, per RFC 6724's usual IPv6-then-IPv4 ordering) and tries
// each candidate address in turn until one connects or the deadline
// passes. Trying every candidate -- not just the first -- is what keeps
// this correct on Docker's IPv6-disabled default bridge: an IPv6 result
// simply fails fast and the loop falls back to the next (IPv4) address
// instead of hanging on an unreachable family.
define function cx-connect-tcp
    (host :: <string>, target-port :: <integer>, deadline-ms :: <integer>)
 => (conn :: false-or(<connection>))
  let hints :: <addrinfo*> = make(<addrinfo*>);
  ai-flags(hints) := 0;
  ai-family(hints) := 0; // AF_UNSPEC: accept both v4 and v6 candidates.
  ai-socktype(hints) := $sock-stream;
  ai-protocol(hints) := $ipproto-tcp;
  let res-holder :: <addrinfo**> = make(<addrinfo**>);
  let service = integer-to-string(target-port);
  let rc = c-getaddrinfo(host, service, hints, res-holder);
  destroy(hints);
  if (rc ~= 0)
    destroy(res-holder);
    #f
  else
    let result = #f;
    let cur = pointer-value(res-holder);
    block (done)
      while (~null-pointer?(cur))
        let afamily = ai-family(cur);
        let fd = c-socket(afamily, logior($sock-stream, $sock-nonblock), 0);
        if (fd >= 0)
          let addr = ai-addr(cur);
          let addrlen = ai-addrlen(cur);
          c-connect(fd, addr, addrlen);
          let revents = cx-poll-wait(fd, #f, #t, deadline-ms);
          if (revents > 0)
            let err-buf :: <C-int*> = make(<C-int*>);
            let len-buf :: <C-unsigned-int*> = make(<C-unsigned-int*>);
            pointer-value(len-buf) := 4;
            c-getsockopt(fd, $sol-socket, $so-error,
                         as(<C-void*>, err-buf), as(<C-void*>, len-buf));
            let sock-err = pointer-value(err-buf);
            destroy(err-buf);
            destroy(len-buf);
            if (sock-err = 0)
              result := make(<connection>, fd: fd);
              done();
            else
              c-close(fd);
            end if;
          else
            c-close(fd);
          end if;
        end if;
        cur := if (null-pointer?(ai-next(cur)))
                 make(<addrinfo*>, address: 0)
               else
                 pointer-cast(<addrinfo*>, ai-next(cur))
               end if;
      end while;
    end block;
    c-freeaddrinfo(pointer-value(res-holder));
    destroy(res-holder);
    result
  end if
end function;

// Upgrades an already-connected plaintext connection to TLS in place,
// verifying the peer against the system trust store and sending SNI (via
// raw SSL_ctrl, since SSL_set_tlsext_host_name is a macro over SSL_ctrl in
// the real OpenSSL headers and so has no linkable symbol of its own).
define function cx-start-tls
    (conn :: <connection>, hostname :: <string>, deadline-ms :: <integer>)
 => (ok? :: <boolean>)
  let ssl = c-ssl-new(cx-ssl-ctx());
  c-ssl-set-fd(ssl, conn.conn-fd);
  c-ssl-set1-host(ssl, hostname);
  c-ssl-ctrl(ssl, $ssl-ctrl-set-tlsext-hostname, $tlsext-nametype-host-name, hostname);
  conn.conn-ssl := ssl;
  block (done)
    while (#t)
      let rc = c-ssl-connect(ssl);
      if (rc = 1)
        done(c-ssl-get-verify-result(ssl) = 0);
      end if;
      let err = c-ssl-get-error(ssl, rc);
      let want-read? = err = $ssl-error-want-read;
      let want-write? = err = $ssl-error-want-write;
      if (~want-read? & ~want-write?)
        done(#f);
      end if;
      let revents = cx-poll-wait(conn.conn-fd, want-read?, want-write?, deadline-ms);
      if (revents <= 0)
        done(#f);
      end if;
    end while;
    #f
  end block
end function;

define function cx-connect-tls
    (host :: <string>, target-port :: <integer>, deadline-ms :: <integer>)
 => (conn :: false-or(<connection>))
  let conn = cx-connect-tcp(host, target-port, deadline-ms);
  if (conn & cx-start-tls(conn, host, deadline-ms))
    conn
  else
    if (conn) cx-close(conn) end if;
    #f
  end if
end function;

// Reads at most count bytes into a fresh byte-vector, waiting for
// readiness under deadline-ms. Returns an empty vector on a bare timeout
// (the caller decides whether that is an error) and #f on a hard I/O
// error or peer close, so timeout and close are never confused.
define function cx-read
    (conn :: <connection>, count :: <integer>, deadline-ms :: <integer>)
 => (data :: false-or(<byte-vector>))
  let buf :: <C-char*> = make(<C-char*>, element-count: count);
  block (done)
    while (#t)
      let n =
        if (connection-tls?(conn))
          c-ssl-read(conn.conn-ssl, as(<C-void*>, buf), count)
        else
          c-read(conn.conn-fd, as(<C-void*>, buf), count)
        end if;
      if (connection-tls?(conn))
        if (n > 0)
          let out = make(<byte-vector>, size: n);
          for (i from 0 below n)
            out[i] := logand(as(<integer>, pointer-value(buf, index: i)), 255);
          end for;
          done(out);
        elseif (n = 0)
          done(#f);
        else
          let err = c-ssl-get-error(conn.conn-ssl, n);
          let want-read? = err = $ssl-error-want-read;
          let want-write? = err = $ssl-error-want-write;
          if (~want-read? & ~want-write?)
            done(#f);
          end if;
          if (cx-poll-wait(conn.conn-fd, want-read?, want-write?, deadline-ms) <= 0)
            done(make(<byte-vector>, size: 0));
          end if;
        end if;
      else
        if (n > 0)
          let out = make(<byte-vector>, size: n);
          for (i from 0 below n)
            out[i] := logand(as(<integer>, pointer-value(buf, index: i)), 255);
          end for;
          done(out);
        elseif (n = 0)
          done(#f);
        else
          if (cx-poll-wait(conn.conn-fd, #t, #f, deadline-ms) <= 0)
            done(make(<byte-vector>, size: 0));
          end if;
        end if;
      end if;
    end while;
    #f
  end block
end function;

// Writes every byte of data, retrying through EAGAIN/WANT_READ/WANT_WRITE
// until either everything is sent or the deadline passes. A short write
// is invisible to callers -- HTTP request bodies and WebSocket frames are
// small enough here that "wrote some" is never a useful partial state.
define function cx-write
    (conn :: <connection>, data :: <byte-vector>, deadline-ms :: <integer>)
 => (ok? :: <boolean>)
  let total = data.size;
  let sent = 0;
  block (done)
    while (sent < total)
      // Re-materializing the unsent tail into a fresh, zero-based C buffer
      // on every retry avoids pointer arithmetic on a <C-void*> (which
      // c-ffi does not overload the way it does element indexing); writes
      // here are small adapter/HTTP/WebSocket frames, so the recopy cost
      // is not a real concern.
      let remaining-len = total - sent;
      let buf :: <C-char*> = make(<C-char*>, element-count: remaining-len);
      for (i from 0 below remaining-len)
        pointer-value(buf, index: i) := data[sent + i];
      end for;
      let n =
        if (connection-tls?(conn))
          c-ssl-write(conn.conn-ssl, as(<C-void*>, buf), remaining-len)
        else
          c-write(conn.conn-fd, as(<C-void*>, buf), remaining-len)
        end if;
      destroy(buf);
      if (n > 0)
        sent := sent + n;
      else
        let want-read? = #f;
        let want-write? = #t;
        if (connection-tls?(conn))
          let err = c-ssl-get-error(conn.conn-ssl, n);
          want-read? := err = $ssl-error-want-read;
          want-write? := err = $ssl-error-want-write;
          if (~want-read? & ~want-write?)
            done(#f);
          end if;
        end if;
        if (cx-poll-wait(conn.conn-fd, want-read?, want-write?, deadline-ms) <= 0)
          done(#f);
        end if;
      end if;
    end while;
    #t
  end block
end function;

define function cx-close (conn :: <connection>) => ()
  if (connection-tls?(conn))
    c-ssl-shutdown(conn.conn-ssl);
    c-ssl-free(conn.conn-ssl);
    conn.conn-ssl := #f;
  end if;
  c-close(conn.conn-fd);
end function;

// Wraps an already-open fd (0 for stdin, 1 for stdout, or an accepted
// socket) as a <connection>, for the adapter's command channel.
define function cx-wrap-fd (fd :: <integer>) => (conn :: <connection>)
  make(<connection>, fd: fd)
end function;

// Binds host:port (IPv4; host "" or "0.0.0.0" means any interface),
// listens, and accepts exactly one connection -- the shape ADAPTER_LISTEN
// mode needs. Returns #f on any setup failure.
define function cx-listen-accept
    (host :: <byte-string>, target-port :: <integer>, deadline-ms :: <integer>)
 => (conn :: false-or(<connection>))
  let listen-fd = c-socket($af-inet, $sock-stream, 0);
  if (listen-fd < 0)
    #f
  else
    let reuse :: <C-int*> = make(<C-int*>);
    pointer-value(reuse) := 1;
    c-setsockopt(listen-fd, $sol-socket, $so-reuseaddr, as(<C-void*>, reuse), 4);
    destroy(reuse);
    let addr :: <sockaddr-in*> = make(<sockaddr-in*>);
    sin-family(addr) := $af-inet;
    sin-port(addr) := c-htons(target-port);
    if (host.size = 0 | host = "0.0.0.0")
      sin-addr(addr) := 0;
    else
      let parts = split-on(host, '.');
      let value = 0;
      for (part in parts)
        value := ash(value, 8) + string-to-integer(part);
      end for;
      sin-addr(addr) := c-htonl(value);
    end if;
    let bind-rc = c-bind(listen-fd, as(<C-void*>, addr), 16);
    destroy(addr);
    if (bind-rc ~= 0 | c-listen(listen-fd, 1) ~= 0)
      c-close(listen-fd);
      #f
    else
      let revents = cx-poll-wait(listen-fd, #t, #f, deadline-ms);
      if (revents <= 0)
        c-close(listen-fd);
        #f
      else
        let client-fd = c-accept(listen-fd, null-pointer(<C-void*>), null-pointer(<C-void*>));
        c-close(listen-fd);
        if (client-fd < 0) #f else make(<connection>, fd: client-fd) end if;
      end if;
    end if;
  end if
end function;

define function split-on (s :: <byte-string>, sep :: <byte-character>) => (parts :: <sequence>)
  let parts = make(<stretchy-vector>);
  let start = 0;
  for (i from 0 below s.size)
    if (s[i] = sep)
      add!(parts, copy-sequence(s, start: start, end: i));
      start := i + 1;
    end if;
  end for;
  add!(parts, copy-sequence(s, start: start));
  parts
end function;
