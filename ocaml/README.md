<a href="https://ocaml.org/"><img src="logo.png" alt="OCaml" width="360"></a>
<!-- Logo source: https://github.com/ocaml/ocaml-logo/blob/master/Colour/PNG/colour-logo.png -->

# OCaml

[OCaml](https://ocaml.org/) is a statically typed functional programming language in the ML family. It was created at INRIA in 1996, building on Caml and earlier ML research, and combines type inference, pattern matching, first-class functions, garbage collection, and native-code compilation. Today it has a focused but active niche in areas such as financial systems, developer tools, static analysis, and verification-heavy software.

This repository's client is educational and unofficial. It demonstrates what a native OCaml Convex client can look like, but it is not a production SDK or a package intended for publication.

## Getting Started

Start with the [canonical counter example](examples/basics/main.ml). From the repository root, run:

```sh
./run verify-example ocaml
```

The command builds and runs the exact example shown below in Docker against a unique room. It queries the current count, subscribes before mutating, increments once, and checks that HTTP, the mutation result, and Live agree.

## Interesting Parts

### Pattern matching makes success and failure explicit

Convex's generated TypeScript API gives React code the query's return type. This OCaml client instead returns `('a, Convex.error) result`, so callers must handle `Ok` and `Error` explicitly. The outer result is type-safe, but this client deliberately represents function values as `Yojson.Safe.t`; a field such as `count` becomes trustworthy only after the program validates and converts it.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function RoomCount() {
  const state = useQuery(api.demo.state, { room: "readme-room" });
  if (state === undefined) return <p>Loading...</p>;

  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**OCaml**

```ocaml
let room = "readme-room"

let deployment =
  match Sys.getenv_opt "CONVEX_URL" with
  | Some url -> url
  | None -> failwith "CONVEX_URL is required"

let client =
  match Convex.create deployment with
  | Ok client -> client (* The result proves this is a usable client. *)
  | Error error -> failwith (Convex.error_message error)

let () =
  Fun.protect
    ~finally:(fun () -> Convex.close client)
    (fun () ->
      let response =
        match Convex.query client "demo:state" (`Assoc [ ("room", `String room) ]) with
        | Ok response -> response (* The HTTP call succeeded, type-safely. *)
        | Error error -> failwith (Convex.error_message error)
      in
      match
        Convex.parse_integral_int64
          (Yojson.Safe.Util.member "count" response.value)
      with
      | Ok count -> Printf.printf "%Ld\n" count (* count is an int64 here. *)
      | Error message -> failwith message)
```

The TypeScript hook is reactive and its generated types describe `demo:state`. The OCaml call above is a one-off HTTP query, not an equivalent subscription, and its JSON boundary is a design choice in this client rather than an OCaml limitation.

### Live is an explicit resource in this command-line API

React owns a `useQuery` subscription while the component is mounted and rerenders when its value changes. The OCaml API used here exposes the subscription directly: the caller pulls the next update with a timeout and must unsubscribe. OCaml supports callbacks, streams, and lightweight concurrency; the blocking `subscription_next` shape is this small client's API choice.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveRoomCount() {
  const state = useQuery(api.demo.state, { room: "readme-live-room" });
  if (state === undefined) return <p>Connecting...</p>;

  return <p>{state.count}</p>; // React rerenders with a type-safe count.
}
```

**OCaml**

```ocaml
let deployment =
  match Sys.getenv_opt "CONVEX_URL" with
  | Some url -> url
  | None -> failwith "CONVEX_URL is required"

let client =
  match Convex.create deployment with
  | Ok client -> client
  | Error error -> failwith (Convex.error_message error)

let subscription =
  match
    Convex.subscribe client "demo:state"
      (`Assoc [ ("room", `String "readme-live-room") ])
  with
  | Ok subscription -> subscription (* An abstract, type-safe handle. *)
  | Error error -> failwith (Convex.error_message error)

let () =
  Fun.protect
    ~finally:(fun () ->
      ignore (Convex.unsubscribe subscription);
      Convex.close client)
    (fun () ->
      match Convex.subscription_next subscription 10.0 with
      | Ok (Some { value = Some json; error = None; _ }) ->
          print_endline (Yojson.Safe.to_string json) (* JSON still needs decoding. *)
      | Ok (Some { error = Some error; _ }) ->
          failwith (Convex.error_message error)
      | Ok (Some { value = None; _ }) -> failwith "Live update omitted value"
      | Ok None -> failwith "Live subscription closed or timed out"
      | Error error -> failwith (Convex.error_message error))
```

The full example starts Live before the mutation so it cannot miss the change, then disposes both resources even when validation fails.

## Status

| Capability | Status |
| --- | --- |
| Native HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Structured HTTP errors and bearer authentication | Verified by shared local and hosted conformance |
| Native Live initial values, updates, removal, and reconnects | Verified by shared local and hosted conformance |

The manifest records both `http` and `live` as earned capabilities. These badges describe what this implementation passed in the repository's black-box suite, not general guarantees about every possible OCaml client.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ml -->
```ocaml
(* The example accepts the verifier's unique room as argv[1] so parallel runs
   never share mutable Convex demo state. *)
let room = if Array.length Sys.argv > 1 then Sys.argv.(1) else "ocaml-example"
let expect condition message = if not condition then failwith message

(* Convex sends JSON numbers, so an integral count can arrive as 0 or as 0.0.
   This accepts either and refuses anything fractional, quoted, or out of
   range rather than silently rounding it into an int64. *)
let get_count json =
  match Convex.parse_integral_int64 (Yojson.Safe.Util.member "count" json) with
  | Ok count -> count
  | Error message -> failwith ("decode count: " ^ message)

let state_count (result : Convex.result) = get_count result.value

let () =
  let deployment =
    match Sys.getenv_opt "CONVEX_URL" with
    | Some value -> value
    | None -> failwith "CONVEX_URL is required"
  in
  (* Create a client connected to the deployment selected by the verifier. *)
  let client =
    match Convex.create deployment with
    | Ok value -> value
    | Error error -> failwith (Convex.error_message error)
  in
  Fun.protect
    ~finally:(fun () -> Convex.close client)
    (fun () ->
      (* The HTTP query gives us the room's current state before Live starts. *)
      let current =
        match
          Convex.query client "demo:state" (`Assoc [ ("room", `String room) ])
        with
        | Ok value -> value
        | Error error -> failwith (Convex.error_message error)
      in
      let current_count = state_count current in
      Printf.printf "current count: %Ld\n%!" current_count;

      (* Start Live before the mutation so the initial snapshot and later update
         belong to the same subscription. *)
      let subscription =
        match
          Convex.subscribe client "demo:state"
            (`Assoc [ ("room", `String room) ])
        with
        | Ok value -> value
        | Error error -> failwith (Convex.error_message error)
      in
      let next_update label =
        match Convex.subscription_next subscription 10.0 with
        | Error error -> failwith (label ^ ": " ^ Convex.error_message error)
        | Ok None -> failwith (label ^ ": Live subscription closed or timed out")
        | Ok (Some update) -> (
            match (update.error, update.value) with
            | Some error, _ ->
                failwith (label ^ ": " ^ Convex.error_message error)
            | None, Some value -> value
            | None, None -> failwith (label ^ ": Live update omitted value"))
      in
      Fun.protect
        ~finally:(fun () -> ignore (Convex.unsubscribe subscription))
        (fun () ->
          (* Read the initial Live value and prove it agrees with HTTP. *)
          let initial = next_update "initial Live value" in
          let initial_count = get_count initial in
          expect
            (initial_count = current_count)
            "initial Live value disagreed with HTTP";
          Printf.printf "live initial count: %Ld\n%!" initial_count;

          (* The run ID is Convex's idempotency key for this mutation. *)
          let run_id =
            Printf.sprintf "ocaml-%d"
              (int_of_float (Unix.gettimeofday () *. 1_000_000.0))
          in
          let mutation =
            match
              Convex.mutation client "demo:increment"
                (`Assoc
                   [
                     ("room", `String room);
                     ("language", `String "OCaml");
                     ("runId", `String run_id);
                   ])
            with
            | Ok value -> value
            | Error error -> failwith (Convex.error_message error)
          in
          let applied =
            match Yojson.Safe.Util.member "applied" mutation.value with
            | `Bool value -> value
            | _ -> failwith "mutation omitted boolean applied"
          in
          expect applied "mutation was not applied";
          Printf.printf "mutation applied: %b\n%!" applied;
          let mutation_state = Yojson.Safe.Util.member "state" mutation.value in
          let mutation_count = get_count mutation_state in
          expect
            (mutation_count = Int64.add current_count 1L)
            "mutation returned an unexpected count";
          Printf.printf "mutation count: %Ld\n%!" mutation_count;

          (* Live should now deliver the mutation result without another query. *)
          let updated = next_update "updated Live value" in
          let updated_count = get_count updated in
          expect
            (updated_count = mutation_count)
            "Live update disagreed with mutation";
          Printf.printf "live updated count: %Ld\n%!" updated_count;
          Printf.printf "verified count: %Ld -> %Ld\n%!" current_count
            updated_count))
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The public client implements Convex's documented JSON HTTP function endpoints directly in OCaml. It uses OCaml's Unix sockets for transport, `ocaml-ssl` for TLS, and Yojson for JSON representation. It does not delegate Convex behavior to another SDK, the Convex CLI, `curl`, Node.js, or Python. The Docker build pins OCaml 5.2.1, Dune 3.17.2, Yojson 2.2.2, `ssl` 0.7.0, and ocamlformat 0.27.0.

HTTP operations return OCaml's polymorphic `result` type and keep function, HTTP, protocol, transport, and closed-client failures distinct. TLS verifies both the certificate chain and hostname. The example's `parse_integral_int64` helper also handles a wire-level wrinkle: a Convex integer may arrive as `0.0`, so decoding accepts mathematically integral JSON numbers while rejecting fractions, quoted values, non-finite values, and overflow.

Live uses the repository's pinned `/api/sync` profile and a hand-written RFC 6455 WebSocket implementation. One worker thread exclusively owns reads, writes, reconnects, and query-set versions. That avoids concurrent socket access while controller threads submit commands. The implementation validates the opening handshake, fragmented UTF-8 messages, control frames, close data, and frame lengths, then resets reconnect backoff after a valid connection or transition.

Delivery is bounded process-wide at 256 retained updates and 16 MiB of accounted memory, with at most 16 updates per subscription. If those limits are crossed, the oldest update in the process is dropped. The test-only adapter has its own bounded ordered output writer and exposes `debugDisconnect` only so conformance can exercise five real reconnects. Those adapter details are evidence machinery, not part of the educational client API.

For local checks, `./run test ocaml` formats, compiles, and exercises language-local fixtures inside Docker. `./run verify ocaml`, `./run verify-hosted ocaml`, and `./run verify-all ocaml` are separate shared evidence gates; this README update does not claim to have rerun them.

## Known Issues

1. Live authentication is incomplete. The WebSocket handshake carries the last bearer token, but token refresh, the sync-protocol `Authenticate` message, and `AuthError` recovery are deferred and unverified.
2. Live values cover the JSON-safe subset. Tagged Convex values and `TransitionChunk` assembly are rejected as protocol errors rather than decoded.
3. Mutations and actions use HTTP. WebSocket mutations, WebSocket actions, and optimistic updates are not implemented.
4. Delivery limits are deliberate. A slow consumer can cause the oldest queued update to be dropped once the process-wide or per-subscription budget is reached.
5. HTTPS deployment URLs using an IP address are unsupported because TLS hostname validation expects a DNS hostname.
