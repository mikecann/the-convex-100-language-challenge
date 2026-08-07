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
