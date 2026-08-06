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
