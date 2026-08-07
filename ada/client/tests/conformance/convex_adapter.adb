with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Convex;
with Convex.Live;
with Convex.Live.Testing;
with Convex_WebSocket;
with Convex_Adapter_Events;
with Convex_Adapter_Output;
with GNAT.Sockets;
with GNATCOLL.JSON;

procedure Convex_Adapter is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;
   use type JSON.JSON_Value_Type;
   use type GNAT.Sockets.Socket_Type;
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;

   -- Input and output are bounded separately because they are bounded by
   -- different things. Every command the shared schema defines is small, so
   -- 2 MiB of NDJSON is already far more than a command can need. An emitted
   -- event is as large as the deployment's data: one Live delivery may carry
   -- a value close to the client's 4 MiB message ceiling, so refusing it here
   -- would reject valid traffic rather than bound memory.
   Max_Command_Bytes : constant := 2 * 1024 * 1024;
   Max_Output_Bytes  : constant := Convex_Adapter_Output.Max_Line_Bytes;
   pragma
     Compile_Time_Error
       (Max_Output_Bytes < Convex_WebSocket.Max_Message_Bytes,
        "adapter output ceiling must cover the Live message ceiling");

   -- Keep controller input bounded independently of the line cap. The shared
   -- controller is request/response oriented, so eight pending commands leave
   -- useful burst tolerance without consuming the 128 MiB runtime limit.
   Command_Capacity : constant := 8;

   type Line_Array is
     array (Positive range 1 .. Command_Capacity) of US.Unbounded_String;

   protected Commands is
      entry Push (Line : US.Unbounded_String);
      procedure Try_Pop (Found : out Boolean; Line : out US.Unbounded_String);
   private
      Lines : Line_Array;
      First : Positive := 1;
      Count : Natural := 0;
   end Commands;

   protected body Commands is
      entry Push (Line : US.Unbounded_String) when Count < Command_Capacity is
         Last : constant Positive :=
           ((First - 1 + Count) mod Command_Capacity) + 1;
      begin
         Lines (Last) := Line;
         Count := Count + 1;
      end Push;

      procedure Try_Pop (Found : out Boolean; Line : out US.Unbounded_String)
      is
      begin
         Found := Count > 0;
         if Found then
            Line := Lines (First);
            Lines (First) := US.Null_Unbounded_String;
            First := (if First = Command_Capacity then 1 else First + 1);
            Count := Count - 1;
         else
            Line := US.Null_Unbounded_String;
         end if;
      end Try_Pop;
   end Commands;

   Use_TCP    : Boolean := False;
   Listener   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
   Controller : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;

   Output_Backpressure : exception;

   --  A full queue is transient. The writer owns one absolute three-second
   --  deadline per line, so a controller that is merely slow drains and a
   --  controller that is gone fails the whole output owner; both end this
   --  wait, and the main loop reports the failure once with its peak
   --  evidence. Only an event the output contract cannot carry at all is
   --  unrecoverable here, and the two callers that can produce one substitute
   --  a structured error before reaching this point.
   procedure Write_Line
     (Line : String; Subscription_Id : String := ""; Generation : Natural := 0)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock
        + Ada.Real_Time.To_Time_Span (Convex_Adapter_Output.Write_Deadline)
        + Ada.Real_Time.To_Time_Span (1.0);
      Accepted : Boolean;
      Failed   : Boolean;
      Message  : US.Unbounded_String;
      Events   : Natural;
      Bytes    : Natural;
   begin
      if Line'Length > Max_Output_Bytes then
         raise Output_Backpressure
           with "adapter event exceeds the output line ceiling";
      end if;
      loop
         Convex_Adapter_Output.Try_Emit
           (Line, Accepted, Subscription_Id, Generation);
         exit when Accepted;
         Convex_Adapter_Output.Status (Failed, Message, Events, Bytes);
         exit when Failed;
         if Ada.Real_Time.Clock >= Deadline then
            raise Output_Backpressure
              with "adapter output count or byte budget exhausted";
         end if;
         delay 0.001;
      end loop;
   end Write_Line;

   task type Reader_Task;
   type Reader_Access is access Reader_Task;

   task body Reader_Task is
      procedure Publish
        (Line : in out US.Unbounded_String; Oversize : in out Boolean) is
      begin
         if Oversize then
            Commands.Push (US.To_Unbounded_String ("!oversize"));
         else
            Commands.Push (Line);
         end if;
         Line := US.Null_Unbounded_String;
         Oversize := False;
      end Publish;

      procedure Read_Stdin is
         Buffer   : String (1 .. 4096);
         Last     : Natural;
         Line     : US.Unbounded_String;
         Oversize : Boolean := False;
      begin
         loop
            begin
               Ada.Text_IO.Get_Line (Buffer, Last);
               if not Oversize then
                  if US.Length (Line) + Last > Max_Command_Bytes then
                     Oversize := True;
                     Line := US.Null_Unbounded_String;
                  else
                     US.Append (Line, Buffer (1 .. Last));
                  end if;
               end if;
               if Last < Buffer'Length then
                  Publish (Line, Oversize);
               end if;
            exception
               when Ada.Text_IO.End_Error =>
                  if US.Length (Line) > 0 or else Oversize then
                     Publish (Line, Oversize);
                  end if;
                  exit;
            end;
         end loop;
      end Read_Stdin;

      procedure Read_TCP is
         Data     : Ada.Streams.Stream_Element_Array (1 .. 16 * 1024);
         Last     : Ada.Streams.Stream_Element_Offset;
         Line     : US.Unbounded_String;
         Oversize : Boolean := False;
      begin
         loop
            GNAT.Sockets.Receive_Socket (Controller, Data, Last);
            exit when Last < Data'First;
            for I in Data'First .. Last loop
               declare
                  C : constant Character := Character'Val (Data (I));
               begin
                  if C = ASCII.LF then
                     if not Oversize
                       and then US.Length (Line) > 0
                       and then US.Element (Line, US.Length (Line)) = ASCII.CR
                     then
                        US.Delete (Line, US.Length (Line), US.Length (Line));
                     end if;
                     Publish (Line, Oversize);
                  elsif not Oversize then
                     if US.Length (Line) = Max_Command_Bytes then
                        Oversize := True;
                        Line := US.Null_Unbounded_String;
                     else
                        US.Append (Line, C);
                     end if;
                  end if;
               end;
            end loop;
         end loop;
         if US.Length (Line) > 0 or else Oversize then
            Publish (Line, Oversize);
         end if;
      exception
         when others =>
            null;
      end Read_TCP;
   begin
      if Use_TCP then
         Read_TCP;
      else
         Read_Stdin;
      end if;
      Commands.Push (US.To_Unbounded_String ("!eof"));
   end Reader_Task;

   type Adapter_Sub is record
      Active           : Boolean := False;
      Name             : US.Unbounded_String;
      Relay_Generation : Natural := 0;
      Value            : Convex.Live.Subscription;
   end record;
   type Adapter_Sub_Array is array (Positive range 1 .. 64) of Adapter_Sub;

   Client                : Convex.Client;
   Live_Manager          : Convex.Live.Manager;
   Subscriptions         : Adapter_Sub_Array;
   Reader                : Reader_Access;
   Finished              : Boolean := False;
   Next_Relay_Generation : Natural := 1;

   procedure Retire_Subscription (Slot : Positive) is
      Success : Boolean;
   begin
      Convex.Live.Unsubscribe (Live_Manager, Subscriptions (Slot).Value);
      Subscriptions (Slot).Active := False;
      Convex_Adapter_Output.Retire
        (US.To_String (Subscriptions (Slot).Name),
         Subscriptions (Slot).Relay_Generation,
         Success);
      if not Success then
         raise Output_Backpressure
           with "adapter output retirement exceeded its deadline";
      end if;
   end Retire_Subscription;

   procedure Emit_Error (Id : String; Message : String) is
   begin
      Write_Line (Convex_Adapter_Events.Protocol_Error_Event (Id, Message));
   end Emit_Error;

   function Required_Field
     (Object : JSON.JSON_Value; Name : String) return JSON.JSON_Value is
   begin
      --  GNATCOLL returns JSON_Null for an absent field, which the shared
      --  schema never accepts in place of a required value. Treat missing and
      --  explicitly null identically rather than letting one through.
      if not Object.Has_Field (Name) then
         raise Constraint_Error with "command field " & Name & " is required";
      end if;
      return Object.Get (Name);
   end Required_Field;

   function Required_String
     (Object : JSON.JSON_Value; Name : String) return String
   is
      Value : constant JSON.JSON_Value := Required_Field (Object, Name);
   begin
      if Value.Kind /= JSON.JSON_String_Type then
         raise Constraint_Error with Name & " must be a string";
      end if;
      return Value.Get;
   end Required_String;

   function Required_Object
     (Object : JSON.JSON_Value; Name : String) return JSON.JSON_Value
   is
      Value : constant JSON.JSON_Value := Required_Field (Object, Name);
   begin
      if Value.Kind /= JSON.JSON_Object_Type then
         raise Constraint_Error with Name & " must be an object";
      end if;
      return Value;
   end Required_Object;

   --  One predicate decides whether an identifier may be retained and echoed.
   --  The event builders apply the same one, so nothing an operation refuses
   --  here can still be serialized somewhere else.
   function Required_Id (Object : JSON.JSON_Value; Name : String) return String
   is
      Value : constant String := Required_String (Object, Name);
   begin
      if not Convex_Adapter_Events.Valid_Id (Value) then
         raise Constraint_Error
           with Name & " must contain 1 to 128 Unicode characters";
      end if;
      return Value;
   end Required_Id;

   --  additionalProperties is false for every command, so an exact match
   --  against the allowed set is required. A substring test would accept a
   --  field literally named "id|op" because "|id|op|" appears in the list.
   procedure Validate_Fields (Object : JSON.JSON_Value; Allowed : String) is
      procedure Check_Field (Name : String; Value : JSON.JSON_Value) is
         pragma Unreferenced (Value);
         First : Natural := Allowed'First;
      begin
         if Name'Length = 0 then
            raise Constraint_Error with "command field name is empty";
         end if;
         while First <= Allowed'Last loop
            declare
               Stop : constant Natural :=
                 Ada.Strings.Fixed.Index (Allowed, "|", First);
            begin
               exit when Stop = 0;
               if Allowed (First .. Stop - 1) = Name then
                  return;
               end if;
               First := Stop + 1;
            end;
         end loop;
         raise Constraint_Error with "unexpected command field " & Name;
      end Check_Field;
   begin
      JSON.Map_JSON_Object (Object, Check_Field'Access);
   end Validate_Fields;

   procedure Validate_Input (Text : String) is
      Depth     : Natural := 0;
      Nodes     : Natural := 0;
      In_String : Boolean := False;
      Escaped   : Boolean := False;
   begin
      if Text'Length = 0 then
         raise Constraint_Error with "empty NDJSON line";
      end if;
      if not Convex_WebSocket.Valid_UTF8 (Text) then
         raise Constraint_Error with "NDJSON line is not UTF-8";
      end if;
      for C of Text loop
         if In_String then
            if Escaped then
               Escaped := False;
            elsif C = '\' then
               Escaped := True;
            elsif C = '"' then
               In_String := False;
            end if;
         elsif C = '"' then
            In_String := True;
         elsif C = '{' or else C = '[' then
            Depth := Depth + 1;
            Nodes := Nodes + 1;
            if Depth > 128 then
               raise Constraint_Error with "JSON nesting exceeds 128";
            end if;
         elsif C = '}' or else C = ']' then
            if Depth = 0 then
               raise Constraint_Error with "unbalanced JSON container";
            end if;
            Depth := Depth - 1;
         elsif C = ',' then
            Nodes := Nodes + 1;
         end if;
         if Nodes > 8_192 then
            raise Constraint_Error with "JSON node limit exceeds 8192";
         end if;
      end loop;
      if In_String or else Depth /= 0 then
         raise Constraint_Error with "unterminated JSON input";
      end if;
   end Validate_Input;

   function Find_Sub (Name : String) return Natural is
   begin
      for I in Subscriptions'Range loop
         if Subscriptions (I).Active
           and then US.To_String (Subscriptions (I).Name) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Sub;

   function Free_Sub return Natural is
   begin
      for I in Subscriptions'Range loop
         if not Subscriptions (I).Active then
            return I;
         end if;
      end loop;
      return 0;
   end Free_Sub;

   procedure Ack (Id : String) is
   begin
      Write_Line (Convex_Adapter_Events.Ack (Id));
   end Ack;

   procedure Handle (Text : String) is
      Parsed     : JSON.Read_Result;
      Command_Id : US.Unbounded_String;
   begin
      if Text = "!oversize" then
         Emit_Error ("", "NDJSON line exceeds 2 MiB");
         return;
      end if;
      Validate_Input (Text);
      Parsed := JSON.Read (Text);
      if not Parsed.Success or else Parsed.Value.Kind /= JSON.JSON_Object_Type
      then
         Emit_Error ("", "invalid NDJSON command");
         return;
      end if;
      declare
         Root : constant JSON.JSON_Value := Parsed.Value;
      begin
         --  Validate the id before retaining it, and retain it before anything
         --  else can fail. Echoing an unvalidated id back in the error path is
         --  how an over-long or wrongly typed id reaches the controller inside
         --  an otherwise well-formed event.
         Command_Id := US.To_Unbounded_String (Required_Id (Root, "id"));
         declare
            Id : constant String := US.To_String (Command_Id);
            Op : constant String := Required_String (Root, "op");
         begin
            if Op = "hello" then
               Validate_Fields (Root, "|protocolVersion|id|op|");
               if Required_Field (Root, "protocolVersion").Kind
                 /= JSON.JSON_Int_Type
                 or else Integer'(Root.Get ("protocolVersion")) /= 1
               then
                  Emit_Error (Id, "unsupported adapter protocol version");
                  return;
               end if;
               Write_Line
                 (Convex_Adapter_Events.Ready
                    (Id,
                     "ada",
                     "native-aws-net-rfc6455-0.1.0",
                     "GNAT 14.2.1"));
            elsif Op = "query" or else Op = "mutation" or else Op = "action"
            then
               Validate_Fields (Root, "|id|op|path|args|");
               declare
                  Path   : constant String := Required_String (Root, "path");
                  Args   : constant JSON.JSON_Value :=
                    Required_Object (Root, "args");
                  Result : constant Convex.Call_Result :=
                    (if Op = "query"
                     then Convex.Query (Client, Path, Args)
                     elsif Op = "mutation"
                     then Convex.Mutation (Client, Path, Args)
                     else Convex.Action (Client, Path, Args));
               begin
                  Write_Line
                    (Convex_Adapter_Events.Call_Result_Line
                       (Id, Result, Max_Output_Bytes));
               end;
            elsif Op = "setAuth" then
               Validate_Fields (Root, "|id|op|token|");
               Convex.Set_Auth (Client, Required_String (Root, "token"));
               Ack (Id);
            elsif Op = "subscribe" then
               Validate_Fields (Root, "|id|op|subscriptionId|path|args|");
               declare
                  Name     : constant String :=
                    Required_Id (Root, "subscriptionId");
                  Path     : constant String := Required_String (Root, "path");
                  Args     : constant JSON.JSON_Value :=
                    Required_Object (Root, "args");
                  Existing : constant Natural := Find_Sub (Name);
                  Slot     : Natural;
                  Success  : Boolean;
                  Message  : US.Unbounded_String;
                  Sub      : Convex.Live.Subscription;
               begin
                  if Existing > 0 then
                     Retire_Subscription (Existing);
                  end if;
                  Slot := Free_Sub;
                  if Slot = 0 then
                     Emit_Error (Id, "adapter subscription limit is 64");
                     return;
                  end if;
                  Convex.Live.Subscribe
                    (Live_Manager, Path, Args, Sub, Success, Message);
                  if not Success then
                     Emit_Error (Id, US.To_String (Message));
                     return;
                  end if;
                  Subscriptions (Slot) :=
                    (Active           => True,
                     Name             => US.To_Unbounded_String (Name),
                     Relay_Generation => Next_Relay_Generation,
                     Value            => Sub);
                  Next_Relay_Generation := Next_Relay_Generation + 1;
                  Ack (Id);
               end;
            elsif Op = "unsubscribe" then
               Validate_Fields (Root, "|id|op|subscriptionId|");
               declare
                  Name : constant String :=
                    Required_Id (Root, "subscriptionId");
                  Slot : constant Natural := Find_Sub (Name);
               begin
                  if Slot > 0 then
                     Retire_Subscription (Slot);
                  end if;
                  Ack (Id);
               end;
            elsif Op = "debugDisconnect" then
               Validate_Fields (Root, "|id|op|");
               declare
                  Success : Boolean;
                  Message : US.Unbounded_String;
               begin
                  Convex.Live.Testing.Debug_Disconnect
                    (Live_Manager, Success, Message);
                  if Success then
                     Ack (Id);
                  else
                     Emit_Error (Id, US.To_String (Message));
                  end if;
               end;
            elsif Op = "close" then
               Validate_Fields (Root, "|id|op|");
               for Sub of Subscriptions loop
                  if Sub.Active then
                     Convex.Live.Unsubscribe (Live_Manager, Sub.Value);
                     declare
                        Retired : Boolean;
                     begin
                        Convex_Adapter_Output.Retire
                          (US.To_String (Sub.Name),
                           Sub.Relay_Generation,
                           Retired);
                        if not Retired then
                           raise Output_Backpressure
                             with "adapter close output retirement timed out";
                        end if;
                     end;
                  end if;
                  Sub.Active := False;
               end loop;
               Convex.Live.Close (Live_Manager);
               Convex.Close (Client);
               Write_Line (Convex_Adapter_Events.Closed (Id));
               declare
                  Drained : Boolean;
               begin
                  Convex_Adapter_Output.Wait_Idle (Drained);
                  if not Drained then
                     raise Output_Backpressure
                       with "adapter close output did not drain";
                  end if;
                  if Use_TCP then
                     --  Order the final closed line before FIN. A full close
                     --  immediately after the writer releases its reservation
                     --  can otherwise race the controller's final read.
                     GNAT.Sockets.Shutdown_Socket
                       (Controller, GNAT.Sockets.Shut_Write);
                  end if;
               end;
               Finished := True;
            else
               Emit_Error (Id, "unknown adapter operation " & Op);
            end if;
         end;
      end;
   exception
      when Output_Backpressure =>
         raise;
      when E : others =>
         Emit_Error
           (US.To_String (Command_Id), Ada.Exceptions.Exception_Message (E));
   end Handle;

   procedure Pump_One_Update is
   begin
      for I in Subscriptions'Range loop
         if Subscriptions (I).Active then
            declare
               Found : Boolean;
               Item  : Convex.Live.Update;
            begin
               Convex.Live.Try_Next
                 (Live_Manager, Subscriptions (I).Value, Found, Item);
               if Found then
                  begin
                     declare
                        Name : constant String :=
                          US.To_String (Subscriptions (I).Name);
                     begin
                        --  A value this adapter cannot encode within its
                        --  output contract becomes a ProtocolError for this
                        --  subscription alone. The subscription stays active
                        --  and its next delivery is published normally.
                        Write_Line
                          (Convex_Adapter_Events.Subscription_Line
                             (Name, Item, Max_Output_Bytes),
                           Name,
                           Subscriptions (I).Relay_Generation);
                     end;
                     Convex.Live.Release (Live_Manager, Item);
                     return;
                  exception
                     when others =>
                        Convex.Live.Release (Live_Manager, Item);
                        raise;
                  end;
               end if;
            end;
         end if;
      end loop;
   end Pump_One_Update;

   procedure Setup_TCP (Listen : String) is
      Separator : constant Natural :=
        Ada.Strings.Fixed.Index (Listen, ":", Going => Ada.Strings.Backward);
      Host      : constant String := Listen (Listen'First .. Separator - 1);
      Port_Text : constant String := Listen (Separator + 1 .. Listen'Last);
      Address   : GNAT.Sockets.Sock_Addr_Type;
   begin
      if Separator <= Listen'First or else Separator = Listen'Last then
         raise Constraint_Error with "ADAPTER_LISTEN must be host:port";
      end if;
      GNAT.Sockets.Create_Socket (Listener);
      GNAT.Sockets.Set_Socket_Option
        (Listener,
         GNAT.Sockets.Socket_Level,
         (Name => GNAT.Sockets.Reuse_Address, Enabled => True));
      Address.Addr := GNAT.Sockets.Inet_Addr (Host);
      Address.Port := GNAT.Sockets.Port_Type'Value (Port_Text);
      GNAT.Sockets.Bind_Socket (Listener, Address);
      GNAT.Sockets.Listen_Socket (Listener, 1);
      GNAT.Sockets.Accept_Socket (Listener, Controller, Address);
      --  A small kernel send buffer makes a stopped controller observable
      --  before application output can hide in multi-megabyte socket buffers.
      GNAT.Sockets.Set_Socket_Option
        (Controller,
         GNAT.Sockets.Socket_Level,
         (Name => GNAT.Sockets.Send_Buffer, Size => 64 * 1024));
      GNAT.Sockets.Set_Socket_Option
        (Controller,
         GNAT.Sockets.Socket_Level,
         (Name => GNAT.Sockets.Linger, Enabled => True, Seconds => 1));
      GNAT.Sockets.Close_Socket (Listener);
   end Setup_TCP;

begin
   if not Ada.Environment_Variables.Exists ("CONVEX_URL") then
      raise Constraint_Error with "CONVEX_URL is required";
   end if;
   Use_TCP :=
     Ada.Environment_Variables.Exists ("ADAPTER_LISTEN")
     and then Ada.Environment_Variables.Value ("ADAPTER_LISTEN")'Length > 0;
   if Use_TCP then
      Setup_TCP (Ada.Environment_Variables.Value ("ADAPTER_LISTEN"));
   end if;
   Convex_Adapter_Output.Start (Use_TCP, Controller);
   Convex.Open (Client, Ada.Environment_Variables.Value ("CONVEX_URL"));
   Convex.Live.Open
     (Live_Manager, Ada.Environment_Variables.Value ("CONVEX_URL"));
   Reader := new Reader_Task;

   while not Finished loop
      declare
         Found              : Boolean;
         Line               : US.Unbounded_String;
         Output_Failed      : Boolean;
         Output_Message     : US.Unbounded_String;
         Output_Events      : Natural;
         Output_Bytes       : Natural;
         Peak_Output_Events : Natural;
         Peak_Output_Bytes  : Natural;
      begin
         Convex_Adapter_Output.Status
           (Output_Failed, Output_Message, Output_Events, Output_Bytes);
         if Output_Failed then
            Convex_Adapter_Output.Evidence
              (Peak_Output_Events, Peak_Output_Bytes);
            raise Output_Backpressure
              with
                US.To_String (Output_Message)
                & " peakEvents="
                & Natural'Image (Peak_Output_Events)
                & " peakBytes="
                & Natural'Image (Peak_Output_Bytes);
         end if;
         Commands.Try_Pop (Found, Line);
         if Found then
            if US.To_String (Line) = "!eof" then
               exit;
            end if;
            Handle (US.To_String (Line));
         else
            Pump_One_Update;
            delay 0.002;
         end if;
      end;
   end loop;

   --  A close command owns the adapter shutdown, so it must also retire the
   --  input task.  Closing the controller socket from this task does not
   --  reliably wake a reader blocked in recv on every runtime and kernel.
   abort Reader.all;

   if not Finished then
      Convex.Live.Close (Live_Manager);
      Convex.Close (Client);
   end if;
   Convex_Adapter_Output.Stop;
   if Use_TCP and then Controller /= GNAT.Sockets.No_Socket then
      GNAT.Sockets.Close_Socket (Controller);
   end if;
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "Ada adapter failed: " & Ada.Exceptions.Exception_Message (E));
      --  Retire the input task here too. A controller that stopped reading is
      --  usually a controller that has also stopped writing, and this task's
      --  master is this procedure: without the abort, a failed adapter waits
      --  for a peer that will never speak again instead of exiting.
      if Reader /= null then
         abort Reader.all;
      end if;
      begin
         Convex.Live.Close (Live_Manager);
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
      Convex_Adapter_Output.Stop;
      if Use_TCP and then Controller /= GNAT.Sockets.No_Socket then
         GNAT.Sockets.Close_Socket (Controller);
      end if;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Convex_Adapter;
