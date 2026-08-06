# Convex from Ada

This is a small native Ada client for Convex HTTP functions and reactive Live queries.

It is an educational, unofficial experiment. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/convex_example.adb`](examples/basics/convex_example.adb). It queries a fresh counter, starts Live before changing it, applies one idempotent mutation, and checks that HTTP, the mutation result, and Live all agree on `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, logs, and structured errors | Implemented, awaiting shared evidence |
| Live initial values, updates, and `QueryFailed` recovery | Implemented, awaiting shared evidence |
| Remove, five reconnects, generation barriers, and bounded global delivery | Implemented, awaiting shared evidence |
| Production SDK compatibility | Not claimed |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/convex_example.adb -->
```ada
with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Convex;
with Convex.Live;
with GNATCOLL.JSON;
with GNATCOLL.Random;
with Interfaces;

procedure Convex_Example is
   package JSON renames GNATCOLL.JSON;
   package US renames Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Convex.Error_Kind;
   use type JSON.JSON_Value_Type;

   Client : Convex.Client;
   Live   : Convex.Live.Manager;
   Stream : Convex.Live.Subscription;

   function Count_From
     (Value : JSON.JSON_Value; Operation : String) return Long_Long_Integer
   is
      Count  : constant JSON.JSON_Value := Value.Get ("count");
      Number : Long_Float;
   begin
      if Count.Kind = JSON.JSON_Int_Type then
         return Count.Get;
      elsif Count.Kind /= JSON.JSON_Float_Type then
         raise Constraint_Error with Operation & " count is not a JSON number";
      end if;
      Number := Count.Get_Long_Float;
      if Number /= Long_Float'Floor (Number)
        or else Number < Long_Float (Long_Long_Integer'First)
        or else Number > Long_Float (Long_Long_Integer'Last)
      then
         raise Constraint_Error
           with Operation & " count is not a whole 64-bit integer";
      end if;
      return Long_Long_Integer (Number);
   end Count_From;

   function Image (Value : Long_Long_Integer) return String is
      Raw : constant String := Long_Long_Integer'Image (Value);
   begin
      return
        (if Raw (Raw'First) = ' '
         then Raw (Raw'First + 1 .. Raw'Last)
         else Raw);
   end Image;

   -- Keep the OS-random id compact and free of Ada's leading numeric space.
   function Random_Run_Id return String is
      Raw : constant String :=
        Interfaces.Unsigned_32'Image (GNATCOLL.Random.Random_Unsigned_32);
   begin
      return
        "ada-"
        & (if Raw (Raw'First) = ' '
           then Raw (Raw'First + 1 .. Raw'Last)
           else Raw);
   end Random_Run_Id;

   function Next_Value (Operation : String) return JSON.JSON_Value is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (10.0);
   begin
      loop
         declare
            Found : Boolean;
            Item  : Convex.Live.Update;
         begin
            Convex.Live.Try_Next (Live, Stream, Found, Item);
            if Found then
               if Item.Has_Value then
                  declare
                     Value : constant JSON.JSON_Value := Item.Value;
                  begin
                     Convex.Live.Release (Live, Item);
                     return Value;
                  end;
               elsif Item.Has_Error
                 and then Item.Error.Kind /= Convex.Transport_Error
               then
                  declare
                     Message : constant String :=
                       US.To_String (Item.Error.Message);
                  begin
                     Convex.Live.Release (Live, Item);
                     raise Constraint_Error with Operation & ": " & Message;
                  end;
               end if;
               Convex.Live.Release (Live, Item);
            end if;
         end;
         if Ada.Real_Time.Clock >= Deadline then
            raise Constraint_Error with "timed out waiting for " & Operation;
         end if;
         delay 0.01;
      end loop;
   end Next_Value;

begin
   if not Ada.Environment_Variables.Exists ("CONVEX_URL") then
      raise Constraint_Error with "CONVEX_URL is required";
   end if;
   declare
      Deployment : constant String :=
        Ada.Environment_Variables.Value ("CONVEX_URL");
      Room       : constant String :=
        (if Ada.Command_Line.Argument_Count > 0
         then Ada.Command_Line.Argument (1)
         else "ada-example");
      Args       : constant JSON.JSON_Value := JSON.Create_Object;
      Success    : Boolean;
      Message    : US.Unbounded_String;
   begin
      -- Configure one native Ada client for the deployment supplied by Docker.
      Convex.Open (Client, Deployment);
      Convex.Live.Open (Live, Deployment);
      Args.Set_Field ("room", Room);

      -- Query the room through Convex's documented HTTP endpoint.
      declare
         Current_Result : constant Convex.Call_Result :=
           Convex.Query (Client, "demo:state", Args);
      begin
         if not Current_Result.Success then
            raise Constraint_Error
              with US.To_String (Current_Result.Error.Message);
         end if;
         -- Decode either 0 or 0.0 into the integral counter this example needs.
         declare
            Before : constant Long_Long_Integer :=
              Count_From (Current_Result.Value, "current query");
         begin
            Ada.Text_IO.Put_Line ("current count: " & Image (Before));

            -- Start Live before mutating so the reactive change cannot be missed.
            Convex.Live.Subscribe
              (Live, "demo:state", Args, Stream, Success, Message);
            if not Success then
               raise Constraint_Error with US.To_String (Message);
            end if;

            -- The first Live value hydrates the same query observed over HTTP.
            declare
               Initial : constant Long_Long_Integer :=
                 Count_From
                   (Next_Value ("initial Live value"), "initial Live value");
            begin
               if Initial /= Before then
                  raise Constraint_Error
                    with "initial Live value disagreed with HTTP";
               end if;
               Ada.Text_IO.Put_Line ("live initial count: " & Image (Initial));
            end;

            -- Use an OS-random runId as Convex's mutation idempotency key.
            declare
               Mutation_Args : constant JSON.JSON_Value := JSON.Create_Object;
               Run_Id        : constant String := Random_Run_Id;
            begin
               Mutation_Args.Set_Field ("room", Room);
               Mutation_Args.Set_Field ("language", "ada");
               Mutation_Args.Set_Field ("runId", Run_Id);
               declare
                  Mutation : constant Convex.Call_Result :=
                    Convex.Mutation (Client, "demo:increment", Mutation_Args);
               begin
                  if not Mutation.Success then
                     raise Constraint_Error
                       with US.To_String (Mutation.Error.Message);
                  end if;
                  if not Mutation.Value.Get ("applied") then
                     raise Constraint_Error with "mutation was not applied";
                  end if;
                  declare
                     After : constant Long_Long_Integer :=
                       Count_From (Mutation.Value.Get ("state"), "mutation");
                  begin
                     if After /= Before + 1 then
                        raise Constraint_Error
                          with "mutation returned an unexpected count";
                     end if;
                     Ada.Text_IO.Put_Line ("mutation applied: true");
                     Ada.Text_IO.Put_Line ("mutation count: " & Image (After));

                     -- Receive the mutation through Live without polling HTTP.
                     declare
                        Updated : constant Long_Long_Integer :=
                          Count_From
                            (Next_Value ("updated Live value"),
                             "updated Live value");
                     begin
                        if Updated /= After then
                           raise Constraint_Error
                             with "Live update disagreed with mutation";
                        end if;
                        Ada.Text_IO.Put_Line
                          ("live updated count: " & Image (Updated));
                        Ada.Text_IO.Put_Line
                          ("verified count: "
                           & Image (Before)
                           & " -> "
                           & Image (Updated));
                     end;
                  end;
               end;
            end;
         end;
      end;
   end;
   -- Retire the Live query and both native transports on the success path.
   Convex.Live.Unsubscribe (Live, Stream);
   Convex.Live.Close (Live);
   Convex.Close (Client);
exception
   when E : others =>
      begin
         Convex.Live.Unsubscribe (Live, Stream);
      exception
         when others =>
            null;
      end;
      begin
         Convex.Live.Close (Live);
      exception
         when others =>
            null;
      end;
      begin
         Convex.Close (Client);
      exception
         when others =>
            null;
      end;
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "Ada example failed: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Convex_Example;
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test ada
./run build ada
```

The `test` target checks GNATformat, builds every source with GNAT 14.2.1 for real `linux/amd64`, runs focused unit tests and deterministic loopback HTTP/WebSocket tests, and exercises the real NDJSON adapter lifecycle. The build target creates the non-root adapter image. Root owns `verify-example`, `verify`, and `verify-hosted` because those commands serialize the shared backend and evidence store.

## Protocol and runtime notes

The client implements Convex's HTTP envelopes and the repository's pinned `/api/sync` profile directly in Ada. AWS 25.2.0 supplies ordinary HTTP, TLS, sockets, and JSON support. The WebSocket handshake, RFC 6455 framing, reconnect state, query-set changes, transition validation, and publication rules are Ada code in `client/`; the implementation does not invoke another Convex client, the Convex CLI, `curl`, Node.js, or Python.

One Ada task exclusively owns the Live socket, reconnect metadata, and query-set version. Add, replacement, remove, forced reconnect, and close are synchronous owner barriers. A complete outgoing WebSocket frame has one absolute 500 ms transmission deadline, so a slow-reading peer cannot keep that owner away from remove or close commands by accepting one chunk at a time. A complete transition is validated before any state or timestamp is committed, and only its final modification for each query is published. `QueryFailed` is delivered as a structured function error without ending the subscription, so a later value recovers normally. Timestamps are decoded as canonical little-endian unsigned 64-bit values and their numeric maximum is retained across reconnects. Backoff starts at 100 ms, caps at 15 seconds, and resets after valid traffic.

At most 64 subscriptions and 8 MiB of conservatively charged paths and arguments are active. One manager-wide queue keeps the newest 16 deliveries and drops the globally oldest intermediate state first within a 20 MiB encoded and runtime-overhead budget. The adapter has a separate single output owner with limits of 16 events and 20 MiB, including its in-flight encoded line, copies, and conservative runtime overhead. Output uses one absolute three-second write deadline, and unsubscribe, same-ID replacement, and close wait on bounded old-generation retirement barriers before acknowledging. Each UTF-8 NDJSON command and emitted line is capped at 2 MiB. `debugDisconnect` is exposed only for conformance.

Alire 2.1.0 pins GNAT 14.2.1, GPRbuild 25.0.1, AWS 25.2.0, GNATCOLL 25.0.0, libgpr 25.0.0, and XMLAda 25.0.0 inside Docker. AWS is explicitly built with its OpenSSL socket backend, while the client uses its native AWS.Net socket API and a small checked-in URL parser. The final digest-pinned Debian images contain only the native executable closure, CA/OpenSSL data, `/bin/sh`, and individual POSIX text tools. They run as `65532:65532` with a read-only filesystem, dropped capabilities, no new privileges, and the shared 128 MiB limit. Compilers, Alire, apt/dpkg, network helpers, delegated runtimes, service residue, and multicall binaries are absent.

## Limitations

Live authentication, optimistic updates, mutations and actions over the WebSocket, journals, and `TransitionChunk` assembly are deferred. Receiving an unsupported or malformed Live shape produces a structured protocol event, retires that socket, and reconnects active subscriptions. Values cover Convex's JSON-safe subset; tagged Convex value conversions are not implemented. Capability badges stay empty until the root-owned local and hosted evaluators pass from a clean reviewed commit.

HTTP connect plus complete request transmission has one absolute five-second deadline, and the complete response has a separate absolute five-second deadline. HTTP responses are capped at 2 MiB and WebSocket messages at 4 MiB. A Live write temporarily builds one complete masked frame, up to that 4 MiB cap, so AWS can apply one TLS-aware deadline to the whole transmission rather than renew it per chunk. Response trees are capped at 128 levels and 65,536 structural nodes; adapter commands use the same depth limit, a stricter 8,192-node limit, and an eight-command input queue. These are deliberate memory bounds for the 128 MiB runtime, not claims of official SDK compatibility.
