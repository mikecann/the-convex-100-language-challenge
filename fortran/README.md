# Convex from Fortran

This Fortran 2018 demonstration queries a Convex counter over HTTP, follows it over Live, applies an idempotent mutation, and checks that every view agrees on the move from 0 to 1.

It is unofficial educational material, not a production SDK.

## Start here

[`examples/basics/main.f90`](examples/basics/main.f90) follows a counter from 0 to 1: an HTTP query, a Live query started before the mutation, the idempotent mutation, and the resulting Live update.

## What works

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action, auth, logs, and structured errors | Works in language-local and hosted smoke tests |
| Live query Add/Remove, updates, failure recovery, and reconnect | Works in deterministic state tests and hosted smoke tests |
| NDJSON adapter over stdin or one TCP controller | Works with partial input, isolated malformed commands, bounded output, and EOF cleanup |
| Capability badges | Not claimed until the root integration owner records shared local and hosted conformance evidence |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.f90 -->
```fortran
program basics
  use convex_fortran
  implicit none

  type(convex_client) :: client
  type(convex_live) :: live
  character(:), allocatable :: url, room, value, error, mutation_args, applied, state
  logical :: ok, found
  integer :: count

  call get_environment_variable('CONVEX_URL', length=count)
  if (count == 0) error stop 'CONVEX_URL is required'
  allocate(character(count) :: url)
  call get_environment_variable('CONVEX_URL', url)
  room = argument_or_default('fortran-basic-example')

  ! Configure this client from the verifier-selected deployment.
  call convex_new(url, client, ok, error)
  if (.not. ok) error stop error
  ! The dedicated public test functions need no authentication token.

  ! Query the counter over HTTP before opening the Live query.
  call convex_call(client, 'query', 'demo:state', '{"room":' // quote(room) // '}', value, ok, error)
  if (.not. ok) error stop 'unexpected initial HTTP value'
  ! Decode Convex's JSON number into an ordinary Fortran integer.
  call assert_count(value, 0, 'unexpected initial HTTP value')
  write (*, '(A)') 'current count: 0'

  ! Start `/api/sync` first, so the mutation cannot race past the subscription.
  call convex_live_start(client, 'demo:state', '{"room":' // quote(room) // '}', live, ok, error)
  if (.not. ok) error stop error
  call convex_live_next(live, value, ok, error)
  if (.not. ok) error stop 'unexpected initial Live value'
  call assert_count(value, 0, 'unexpected initial Live value')
  write (*, '(A)') 'live initial count: 0'

  ! The room-specific run ID makes a retry safe: this mutation increments once.
  mutation_args = '{"room":' // quote(room) // ',"language":"Fortran","runId":' // quote(room // '-once') // '}'
  call convex_call(client, 'mutation', 'demo:increment', mutation_args, value, ok, error)
  if (.not. ok) error stop 'unexpected mutation result'
  applied = convex_json_member(value, 'applied', found)
  if (.not. found .or. applied /= 'true') error stop 'unexpected mutation result'
  state = convex_json_member(value, 'state', found)
  if (.not. found) error stop 'unexpected mutation result'
  call assert_count(state, 1, 'unexpected mutation result')
  write (*, '(A)') 'mutation applied: true'
  write (*, '(A)') 'mutation count: 1'

  ! Wait for the server transition that contains the same updated counter.
  call convex_live_next(live, value, ok, error)
  if (.not. ok) error stop 'unexpected updated Live value'
  call assert_count(value, 1, 'unexpected updated Live value')
  write (*, '(A)') 'live updated count: 1'
  ! Unsubscribe first, then stop the sole transport owner and release its socket.
  call convex_live_close(live)
  call convex_live_close()

  ! Stdout is deliberately the universal six-line happy-path transcript.
  write (*, '(A)') 'verified count: 0 -> 1'

contains

  function argument_or_default(default) result(value)
    character(*), intent(in) :: default
    character(:), allocatable :: value
    integer :: length

    if (command_argument_count() == 0) then
      value = default
      return
    end if
    call get_command_argument(1, length=length)
    allocate(character(length) :: value)
    call get_command_argument(1, value)
  end function argument_or_default

  subroutine assert_count(json, expected, message)
    character(*), intent(in) :: json, message
    integer, intent(in) :: expected
    logical :: count_ok
    integer :: decoded

    decoded = convex_count(json, count_ok)
    if (.not. count_ok) error stop message
    if (decoded /= expected) error stop message
  end subroutine assert_count

  function quote(text) result(value)
    character(*), intent(in) :: text
    character(:), allocatable :: value
    integer :: index

    value = '"'
    do index = 1, len_trim(text)
      if (text(index:index) == '"' .or. text(index:index) == '\\') value = value // '\\'
      value = value // text(index:index)
    end do
    value = value // '"'
  end function quote

end program basics
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples fortran
./run validate
./run test fortran
./run build fortran
```

`sync-examples` proves this displayed source is the runnable source. `validate` checks the public layout and manifest. `test` compiles the exact example and adapter for `linux/amd64`, then runs transactional Live-state, real RFC6455 socket, and adapter-process fixtures. `build` produces the final adapter image. The root integration owner must separately run `verify-example`, local conformance, and hosted conformance after review.

## Protocol notes and limits

The Fortran module owns Convex request encoding, JSON decoding, `Connect`, versioned `ModifyQuerySet` Add/Remove operations, transactional `Transition` application, reconnect metadata, backoff, generation barriers, hydration suppression, and the global newest-16 Live queue. One worker exclusively owns WebSocket reads, writes, reconnects, and query-set versions.

`client/curl_transport.c` is a small ordinary transport ABI. It uses libcurl 7.88.1 for HTTPS, c-ares 1.18.1 for cancellable bounded DNS, and OpenSSL plus sockets for TLS and RFC6455. It validates the upgrade response, masks client frames, assembles fragmented UTF-8, services control frames, abandons partial frames on timeout, and bounds DNS, handshakes, writes, and close without leaving resolver work behind. It contains no Convex paths, messages, or state decisions.

The build is pinned to GCC/GNU Fortran 14.2.0 on the digest-pinned Bookworm toolchain image. Production uses digest-pinned Debian 12.11 slim with c-ares 1.18.1-3, libcurl 7.88.1-10+deb12u15, OpenSSL 3.0.20-1~deb12u2, CA certificates 20230311+deb12u1, and libgfortran5 12.2.0-14+deb12u1.

The adapter reserves stdout for protocol events. Its single writer keeps at most 16 encoded events and 32 MiB including conservative overhead, coalescing queued updates for the same subscription. The client uses the same count and byte limits for Live delivery, and supports at most 64 active subscriptions. Test-only transition hooks are included only in the separately compiled test object.

## Limitations

Live authentication is deferred. Values remain JSON text rather than a richer Fortran value tree. WebSocket mutations/actions, optimistic updates, journals, replay, and `TransitionChunk` assembly are also deferred; an unknown server transition is reported as `ProtocolError` and reconnects instead of being guessed at.

The runtime images intentionally retain Debian's `/bin/sh` and basic text tools because the shared verifier requires them. They contain the compiled Fortran executable, its dynamic-library closure, CA certificates, OpenSSL configuration/providers, and no compiler, package manager, Convex CLI, Node.js, Python, curl command, or unsafe multicall binary. Capabilities remain empty in the manifest until the separate root-owned shared evidence run passes from a clean reviewed commit.
