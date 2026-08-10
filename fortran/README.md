<img src="logo.png" alt="Fortran logo" width="128">
<!-- Logo source: https://github.com/fortran-lang/webpage/blob/main/source/_static/images/fortran-logo-256x256.png -->

# Fortran

Fortran began at IBM in 1954 under John Backus and reached users in 1957. Its name comes from "formula translation", which still fits a language built for numeric work. Modern Fortran is statically and strongly typed, supports several programming styles, and remains active in science, engineering, weather modelling, and high-performance computing. The [Fortran community site](https://fortran-lang.org/) is the best starting point for the language today, while [IBM's history](https://www.ibm.com/history/fortran) tells the origin story.

This repository is an educational experiment. The client is unofficial and is not a production Convex SDK.

## Getting Started

The canonical [`examples/basics/main.f90`](examples/basics/main.f90) program queries a counter, starts a Live subscription, performs an idempotent mutation, and observes the reactive update from 0 to 1.

From the repository root, Docker builds and runs that exact program against the approved test deployment:

```sh
./run verify-example fortran
```

## Interesting Parts

### React owns the subscription; this client makes it visible

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  // React subscribes on mount and unsubscribes on unmount.
  const state = useQuery(api.demo.state, { room: "fortran-readme" });
  return <p>{state?.count ?? "Loading..."}</p>; // state.count is type-safe here.
}
```

**Fortran**

```fortran
program live_counter
  use convex_fortran
  implicit none

  type(convex_client) :: client
  type(convex_live) :: live
  character(:), allocatable :: url, value, error
  logical :: ok
  integer :: count, url_length

  ! Read the deployment selected by the caller, then create the client.
  call get_environment_variable('CONVEX_URL', length=url_length)
  if (url_length == 0) error stop 'CONVEX_URL is required'
  allocate(character(url_length) :: url)
  call get_environment_variable('CONVEX_URL', url)
  call convex_new(url, client, ok, error)
  if (.not. ok) error stop error

  ! The arguments are JSON text because this small client has no value tree.
  call convex_live_start(client, 'demo:state', &
    '{"room":"fortran-readme"}', live, ok, error)
  if (.not. ok) error stop error

  ! next blocks until the subscription produces its initial value.
  call convex_live_next(live, value, ok, error)
  if (.not. ok) error stop error
  count = convex_count(value, ok) ! Decode the returned state object's count.
  if (.not. ok) error stop 'invalid counter state'
  write (*, '(I0)') count

  ! There is no component unmount, so cleanup is explicit.
  call convex_live_close(live)
  call convex_live_close()
end program live_counter
```

Both snippets subscribe to `api.demo.state` with the same room argument. React rerenders whenever `useQuery` changes. This client instead exposes a blocking `convex_live_next` call so a command-line program can decide when to consume each value. That blocking API is a choice made by this client, not a limitation of Fortran.

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action, auth, logs, and structured errors | Works in language-local and hosted smoke tests |
| Live query Add/Remove, updates, failure recovery, and reconnect | Works in deterministic state tests and hosted smoke tests |
| NDJSON adapter over stdin or one TCP controller | Works with partial input, isolated malformed commands, bounded output, and EOF cleanup |
| Capability badges | HTTP and Live earned from root-owned local and hosted conformance evidence |

## Example

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

## Implementation Notes

The Fortran module implements Convex request encoding, JSON decoding, HTTP operations, Live subscription state, reconnects, and bounded delivery. A single worker owns WebSocket activity. The public Live API then lets application code start a subscription, wait for values, unsubscribe, and close it explicitly.

Fortran's standard C interoperability is used only at the transport boundary. [`client/curl_transport.c`](client/curl_transport.c) supplies HTTPS through libcurl, cancellable DNS through c-ares, and TLS plus RFC6455 WebSockets through OpenSSL and sockets. Convex paths, messages, and state decisions remain in Fortran, so the implementation is classified as native rather than a bridge.

The build uses GNU Fortran 14.2.0 and a digest-pinned Debian Bookworm toolchain. The runtime keeps the compiled program, its dynamic-library closure, certificates, OpenSSL providers, `/bin/sh`, and basic text tools required by the shared verifier. It does not contain a compiler, package manager, Convex CLI, Node.js, Python, or the curl command.

Language-local Docker tests cover compilation, JSON edge cases, Live recovery, WebSocket framing, bounded shutdown, and the adapter process. The capability table above comes from the separate root-owned local and hosted conformance evidence, not from compilation alone.

## Known Issues

1. Live authentication is not implemented.
2. Values are JSON text instead of an idiomatic Fortran value tree.
3. WebSocket mutations and actions, optimistic updates, journals, replay, and `TransitionChunk` assembly are deferred.
4. Live delivery is capped at 64 subscriptions and the newest 16 encoded events or 32 MiB. An unknown server transition reports `ProtocolError` and reconnects.
