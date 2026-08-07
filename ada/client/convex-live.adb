with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Convex_WebSocket;
with GNATCOLL.Random;
with Interfaces;

package body Convex.Live is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_32;
   use type JSON.JSON_Value_Type;
   use type US.Unbounded_String;

   procedure Free_Owner is new
     Ada.Unchecked_Deallocation (Owner_Task, Owner_Access);

   Initial_Timestamp : constant String := "AAAAAAAAAAA=";
   Max_Subscriptions : constant := 64;
   Active_Budget     : constant := 8 * 1024 * 1024;
   Queue_Capacity    : constant := 16;
   Queue_Budget      : constant := 20 * 1024 * 1024;
   Envelope_Charge   : constant := 4 * 1024;
   Max_JSON_Nodes    : constant := 65_536;

   type Sub_State is record
      Active     : Boolean := False;
      Id         : Natural := 0;
      Generation : Natural := 0;
      Path       : US.Unbounded_String;
      Args       : JSON.JSON_Value := JSON.JSON_Null;
      Accounted  : Natural := 0;
      Has_Last   : Boolean := False;
      Last_Value : US.Unbounded_String;
   end record;
   type Sub_Array is
     array (Positive range 1 .. Max_Subscriptions) of Sub_State;

   type Queued_Update is record
      Id         : Natural := 0;
      Generation : Natural := 0;
      Item       : Update;
      Charge     : Natural := 0;
   end record;
   type Update_Array is
     array (Positive range 1 .. Queue_Capacity) of Queued_Update;

   type Pending_Update is record
      Present   : Boolean := False;
      Item      : Update;
      Signature : US.Unbounded_String;
   end record;
   type Pending_Array is
     array (Positive range 1 .. Max_Subscriptions) of Pending_Update;

   procedure Validate_JSON_Bounds (Text : String) is
      Depth     : Natural := 0;
      Nodes     : Natural := 0;
      In_String : Boolean := False;
      Escaped   : Boolean := False;
   begin
      -- Bound the JSON tree as well as the RFC 6455 bytes. Without this, a
      -- compact array can consume far more memory than its four-megabyte frame.
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
               raise Constraint_Error with "Live JSON nesting exceeds 128";
            end if;
         elsif C = '}' or else C = ']' then
            if Depth = 0 then
               raise Constraint_Error
                 with "Live JSON containers are unbalanced";
            end if;
            Depth := Depth - 1;
         elsif C = ',' then
            Nodes := Nodes + 1;
         end if;
         if Nodes > Max_JSON_Nodes then
            raise Constraint_Error
              with "Live JSON exceeds 65536 structural nodes";
         end if;
      end loop;
      if In_String or else Depth /= 0 then
         raise Constraint_Error with "Live JSON is incomplete";
      end if;
   end Validate_JSON_Bounds;

   function Read_Bounded_JSON (Text : String) return JSON.Read_Result is
   begin
      Validate_JSON_Bounds (Text);
      return JSON.Read (Text);
   end Read_Bounded_JSON;

   function Session_Id return String is
      type Byte_Array is array (Positive range 1 .. 16) of Natural;
      Bytes : Byte_Array;
      Hex   : constant String := "0123456789abcdef";

      function Pair (Value : Natural) return String
      is (Hex (Value / 16 + 1) & Hex (Value mod 16 + 1));
   begin
      for I in Bytes'Range loop
         Bytes (I) := Natural (GNATCOLL.Random.Random_Unsigned_32 and 16#FF#);
      end loop;
      Bytes (7) := 16#40# + Bytes (7) mod 16;
      Bytes (9) := 16#80# + Bytes (9) mod 64;
      return
        Pair (Bytes (1))
        & Pair (Bytes (2))
        & Pair (Bytes (3))
        & Pair (Bytes (4))
        & "-"
        & Pair (Bytes (5))
        & Pair (Bytes (6))
        & "-"
        & Pair (Bytes (7))
        & Pair (Bytes (8))
        & "-"
        & Pair (Bytes (9))
        & Pair (Bytes (10))
        & "-"
        & Pair (Bytes (11))
        & Pair (Bytes (12))
        & Pair (Bytes (13))
        & Pair (Bytes (14))
        & Pair (Bytes (15))
        & Pair (Bytes (16));
   end Session_Id;

   function Error_Update
     (Kind : Convex.Error_Kind; Message : String) return Update is
   begin
      return
        (Has_Value => False,
         Value     => JSON.JSON_Null,
         Has_Error => True,
         Error     =>
           (Kind     => Kind,
            Message  => US.To_Unbounded_String (Message),
            Has_Data => False,
            Data     => JSON.JSON_Null,
            Has_Logs => False,
            Logs     => JSON.Empty_Array),
         Has_Logs  => False,
         Logs      => JSON.Empty_Array,
         Token     => 0);
   end Error_Update;

   function Add_Modification (Sub : Sub_State) return JSON.JSON_Value is
      Result : constant JSON.JSON_Value := JSON.Create_Object;
      Args   : JSON.JSON_Array := JSON.Empty_Array;
   begin
      JSON.Append (Args, Sub.Args);
      Result.Set_Field ("type", "Add");
      Result.Set_Field ("queryId", JSON.Create (Long_Long_Integer (Sub.Id)));
      Result.Set_Field ("udfPath", US.To_String (Sub.Path));
      Result.Set_Field ("args", Args);
      return Result;
   end Add_Modification;

   task body Owner_Task is
      URL               : US.Unbounded_String;
      Subs              : Sub_Array;
      Socket            : Convex_WebSocket.Connection;
      Configured        : Boolean := False;
      Stopping          : Boolean := False;
      Next_Id           : Natural := 1;
      Next_Generation   : Natural := 1;
      Query_Set_Version : Interfaces.Unsigned_32 := 0;
      Remote_Query_Set  : Interfaces.Unsigned_32 := 0;
      Remote_Identity   : Interfaces.Unsigned_32 := 0;
      Remote_Timestamp  : US.Unbounded_String :=
        US.To_Unbounded_String (Initial_Timestamp);
      Max_Timestamp     : Interfaces.Unsigned_64 := 0;
      Has_Max_Timestamp : Boolean := False;
      Connection_Count  : Interfaces.Unsigned_32 := 0;
      Connection_Active : Boolean := False;
      Last_Close_Reason : US.Unbounded_String :=
        US.To_Unbounded_String ("InitialConnect");
      Backoff           : Duration := 0.1;
      Reconnect_At      : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Queue             : Update_Array;
      Queue_First       : Positive := 1;
      Queue_Count       : Natural := 0;
      Queue_Bytes       : Natural := 0;
      Inflight_Bytes    : Natural := 0;
      Inflight_Token    : Natural := 0;
      Next_Token        : Natural := 1;
      Active_Bytes      : Natural := 0;

      function Active_Count return Natural is
         Count : Natural := 0;
      begin
         for Sub of Subs loop
            if Sub.Active then
               Count := Count + 1;
            end if;
         end loop;
         return Count;
      end Active_Count;

      function Find_Sub (Id, Generation : Natural) return Natural is
      begin
         for I in Subs'Range loop
            if Subs (I).Active
              and then Subs (I).Id = Id
              and then Subs (I).Generation = Generation
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Sub;

      function Find_Id (Id : Interfaces.Unsigned_32) return Natural is
      begin
         for I in Subs'Range loop
            if Subs (I).Active
              and then Interfaces.Unsigned_32 (Subs (I).Id) = Id
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Id;

      function Subscription_Charge
        (Path : String; Encoded_Args : String) return Natural is
      begin
         return
           Natural'Min
             (Active_Budget, 1_024 + 4 * (Path'Length + Encoded_Args'Length));
      end Subscription_Charge;

      procedure Drop_Oldest is
      begin
         if Queue_Count = 0 then
            return;
         end if;
         Queue_Bytes := Queue_Bytes - Queue (Queue_First).Charge;
         Queue (Queue_First) := (others => <>);
         Queue_First :=
           (if Queue_First = Queue_Capacity then 1 else Queue_First + 1);
         Queue_Count := Queue_Count - 1;
      end Drop_Oldest;

      --  Value_Length lets a caller that already serialized Item.Value (to
      --  compare it against the subscription's last-published signature)
      --  pass that length through, instead of Charge repeating an identical
      --  JSON.Write of a value that can approach the 4 MiB message ceiling.
      --  0 means "not supplied"; JSON.Write never produces an empty string.
      function Charge
        (Item : Update; Value_Length : Natural := 0) return Natural
      is
         Encoded : Natural := Envelope_Charge;
         function Encoded_Length (Value : JSON.JSON_Value) return Natural is
            Text : constant String := JSON.Write (Value);
         begin
            return Text'Length;
         end Encoded_Length;
      begin
         if Item.Has_Value then
            Encoded :=
              Encoded
              + (if Value_Length > 0
                 then Value_Length
                 else Encoded_Length (Item.Value));
         end if;
         if Item.Has_Error then
            Encoded := Encoded + US.Length (Item.Error.Message);
            if Item.Error.Has_Data then
               Encoded := Encoded + Encoded_Length (Item.Error.Data);
            end if;
         end if;
         for I in 1 .. JSON.Length (Item.Logs) loop
            Encoded := Encoded + Encoded_Length (JSON.Get (Item.Logs, I));
         end loop;
         return Natural'Min (Queue_Budget, Encoded * 4);
      end Charge;

      procedure Enqueue
        (Index : Positive; Item : Update; Value_Length : Natural := 0)
      is
         Needed : constant Natural := Charge (Item, Value_Length);
         Last   : Positive;
      begin
         while Queue_Count > 0
           and then (Queue_Count = Queue_Capacity
                     or else Queue_Bytes + Inflight_Bytes + Needed
                             > Queue_Budget)
         loop
            Drop_Oldest;
         end loop;
         if Inflight_Bytes + Needed > Queue_Budget then
            return;
         end if;
         Last := ((Queue_First - 1 + Queue_Count) mod Queue_Capacity) + 1;
         Queue (Last) :=
           (Id         => Subs (Index).Id,
            Generation => Subs (Index).Generation,
            Item       => Item,
            Charge     => Needed);
         Queue_Bytes := Queue_Bytes + Needed;
         Queue_Count := Queue_Count + 1;
      end Enqueue;

      procedure Remove_Queued (Id, Generation : Natural) is
         Kept  : Update_Array;
         Count : Natural := 0;
         Bytes : Natural := 0;
      begin
         if Queue_Count > 0 then
            for Offset in 0 .. Queue_Count - 1 loop
               declare
                  Index : constant Positive :=
                    ((Queue_First - 1 + Offset) mod Queue_Capacity) + 1;
               begin
                  if Queue (Index).Id /= Id
                    or else Queue (Index).Generation /= Generation
                  then
                     Count := Count + 1;
                     Kept (Count) := Queue (Index);
                     Bytes := Bytes + Queue (Index).Charge;
                  end if;
               end;
            end loop;
         end if;
         Queue := Kept;
         Queue_First := 1;
         Queue_Count := Count;
         Queue_Bytes := Bytes;
      end Remove_Queued;

      procedure Broadcast_Error (Kind : Convex.Error_Kind; Message : String) is
         Item : constant Update := Error_Update (Kind, Message);
      begin
         for I in Subs'Range loop
            if Subs (I).Active then
               Enqueue (I, Item);
            end if;
         end loop;
      end Broadcast_Error;

      procedure Schedule_Reconnect is
      begin
         Reconnect_At :=
           Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Backoff);
         Backoff := Duration'Min (15.0, Backoff * 2.0);
      end Schedule_Reconnect;

      procedure Disconnect
        (Reason               : String;
         Report               : Boolean := True;
         Count_Failed_Attempt : Boolean := False) is
      begin
         if Convex_WebSocket.Is_Open (Socket) then
            Convex_WebSocket.Shutdown (Socket);
         end if;
         --  Poll closes the native socket before returning peer, protocol, or
         --  transport failures. Track the logical successful connection so
         --  those reconnects still advance connectionCount exactly once.
         if Connection_Active or else Count_Failed_Attempt then
            if Connection_Count < Interfaces.Unsigned_32'Last then
               Connection_Count := Connection_Count + 1;
            end if;
         end if;
         Connection_Active := False;
         Query_Set_Version := 0;
         Remote_Query_Set := 0;
         Remote_Identity := 0;
         Remote_Timestamp := US.To_Unbounded_String (Initial_Timestamp);
         Last_Close_Reason := US.To_Unbounded_String (Reason);
         if Report then
            Broadcast_Error (Convex.Transport_Error, Reason);
         end if;
         if Active_Count > 0 then
            Schedule_Reconnect;
         end if;
      end Disconnect;

      procedure Send_Modifications
        (Base, New_Version : Interfaces.Unsigned_32;
         Modifications     : JSON.JSON_Array;
         Deadline          : Ada.Real_Time.Time)
      is
         Message : constant JSON.JSON_Value := JSON.Create_Object;
      begin
         Message.Set_Field ("type", "ModifyQuerySet");
         Message.Set_Field
           ("baseVersion", JSON.Create (Long_Long_Integer (Base)));
         Message.Set_Field
           ("newVersion", JSON.Create (Long_Long_Integer (New_Version)));
         Message.Set_Field ("modifications", Modifications);
         --  Send_Text owns one deadline for the complete frame. A slow peer
         --  therefore releases this sole owner to service Remove or Stop
         --  instead of renewing a timeout for every encoded chunk.
         Convex_WebSocket.Send_Text (Socket, JSON.Write (Message), Deadline);
         Query_Set_Version := New_Version;
      end Send_Modifications;

      procedure Send_Modifications
        (Base, New_Version : Interfaces.Unsigned_32;
         Modifications     : JSON.JSON_Array) is
      begin
         Send_Modifications
           (Base,
            New_Version,
            Modifications,
            Ada.Real_Time.Clock
            + Ada.Real_Time.To_Time_Span
                (Convex_WebSocket.Frame_Write_Budget));
      end Send_Modifications;

      procedure Establish is
         Connect_Message : constant JSON.JSON_Value := JSON.Create_Object;
         Adds            : JSON.JSON_Array := JSON.Empty_Array;

         --  Name resolution, connect, TLS, the upgrade write, the 101 read,
         --  and the first Convex Connect frame share one absolute budget. A
         --  peer that makes a little progress at each step therefore cannot
         --  keep this sole owner away from a queued Remove or Stop.
         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock
           + Ada.Real_Time.To_Time_Span (Convex_WebSocket.Connect_Budget);
      begin
         Convex_WebSocket.Open (Socket, US.To_String (URL), Deadline);
         Connection_Active := True;
         Connect_Message.Set_Field ("type", "Connect");
         Connect_Message.Set_Field ("sessionId", Session_Id);
         Connect_Message.Set_Field
           ("connectionCount",
            JSON.Create (Long_Long_Integer (Connection_Count)));
         Connect_Message.Set_Field
           ("lastCloseReason", US.To_String (Last_Close_Reason));
         Connect_Message.Set_Field ("clientTs", Integer (0));
         if Has_Max_Timestamp then
            Connect_Message.Set_Field
              ("maxObservedTimestamp",
               Convex_WebSocket.Encode_Timestamp (Max_Timestamp));
         end if;
         Convex_WebSocket.Send_Text
           (Socket, JSON.Write (Connect_Message), Deadline);
         --  Replay is unchanged: every still-active subscription is re-added
         --  on the new connection. Each replay frame keeps its own ordinary
         --  frame budget so one large Add cannot consume the handshake's.
         for Sub of Subs loop
            if Sub.Active then
               JSON.Append (Adds, Add_Modification (Sub));
            end if;
         end loop;
         if JSON.Length (Adds) > 0 then
            Send_Modifications (0, 1, Adds);
         end if;
         Remote_Query_Set := 0;
         Remote_Identity := 0;
         Remote_Timestamp := US.To_Unbounded_String (Initial_Timestamp);
         --  A validated handshake is evidence the transport is healthy again.
         --  Without this reset a connection that succeeded after several
         --  failures would still hand the next failure the old maximum delay.
         --  Protocol failures on this connection are unaffected: they run
         --  through Handle_Message and Disconnect, which reschedule from the
         --  freshly reset backoff.
         Backoff := 0.1;
      exception
         when E : others =>
            Disconnect
              ("connect: " & Ada.Exceptions.Exception_Message (E),
               Report               => True,
               Count_Failed_Attempt => True);
      end Establish;

      function UInt32_Field
        (Object : JSON.JSON_Value; Name : String) return Interfaces.Unsigned_32
      is
         Result : Interfaces.Unsigned_32;
      begin
         if not Convex_WebSocket.Decode_UInt32 (Object.Get (Name), Result) then
            raise Constraint_Error with Name & " must be an exact uint32";
         end if;
         return Result;
      end UInt32_Field;

      function String_Field
        (Object : JSON.JSON_Value; Name : String) return String
      is
         Value : constant JSON.JSON_Value := Object.Get (Name);
      begin
         if Value.Kind /= JSON.JSON_String_Type then
            raise Constraint_Error with Name & " must be a string";
         end if;
         return Value.Get;
      end String_Field;

      --  Presence is part of the value. A modification without logLines must
      --  not become one with an empty array by the time the adapter serializes
      --  it, so report the field's absence rather than a defaulted array.
      procedure Logs_Field
        (Object  : JSON.JSON_Value;
         Present : out Boolean;
         Logs    : out JSON.JSON_Array) is
      begin
         Present := False;
         Logs := JSON.Empty_Array;
         if not Object.Has_Field ("logLines") then
            return;
         end if;
         declare
            Value : constant JSON.JSON_Value := Object.Get ("logLines");
         begin
            if Value.Kind /= JSON.JSON_Array_Type then
               raise Constraint_Error with "logLines must be an array";
            end if;
            declare
               Values : constant JSON.JSON_Array := Value.Get;
            begin
               for I in 1 .. JSON.Length (Values) loop
                  if JSON.Get (Values, I).Kind /= JSON.JSON_String_Type then
                     raise Constraint_Error
                       with "logLines entries must be strings";
                  end if;
               end loop;
               Present := True;
               Logs := Values;
            end;
         end;
      end Logs_Field;

      procedure Validate_Version
        (Value       : JSON.JSON_Value;
         Q, Identity : out Interfaces.Unsigned_32;
         Timestamp   : out US.Unbounded_String)
      is
         Numeric : Interfaces.Unsigned_64;
         Text    : constant String := String_Field (Value, "ts");
      begin
         if Value.Kind /= JSON.JSON_Object_Type then
            raise Constraint_Error with "state version must be an object";
         end if;
         Q := UInt32_Field (Value, "querySet");
         Identity := UInt32_Field (Value, "identity");
         if not Convex_WebSocket.Decode_Timestamp (Text, Numeric) then
            raise Constraint_Error
              with "state timestamp is not canonical little-endian uint64";
         end if;
         Timestamp := US.To_Unbounded_String (Text);
      end Validate_Version;

      procedure Handle_Transition (Root : JSON.JSON_Value) is
         Start_Q, Start_I, End_Q, End_I : Interfaces.Unsigned_32;
         Start_TS, End_TS               : US.Unbounded_String;
         Numeric_TS                     : Interfaces.Unsigned_64;
         Mods                           : JSON.JSON_Array;
         Pending                        : Pending_Array;
      begin
         Validate_Version
           (Root.Get ("startVersion"), Start_Q, Start_I, Start_TS);
         Validate_Version (Root.Get ("endVersion"), End_Q, End_I, End_TS);
         if Start_Q /= Remote_Query_Set
           or else Start_I /= Remote_Identity
           or else Start_TS /= Remote_Timestamp
         then
            raise Constraint_Error
              with "Transition startVersion does not match local state";
         end if;
         if not Convex_WebSocket.Decode_Timestamp
                  (US.To_String (End_TS), Numeric_TS)
         then
            raise Constraint_Error with "invalid end timestamp";
         end if;
         Mods := Root.Get ("modifications");
         for I in 1 .. JSON.Length (Mods) loop
            declare
               Modification : constant JSON.JSON_Value := JSON.Get (Mods, I);
               Kind         : constant String :=
                 String_Field (Modification, "type");
               Query_Id     : constant Interfaces.Unsigned_32 :=
                 UInt32_Field (Modification, "queryId");
               Index        : constant Natural := Find_Id (Query_Id);
            begin
               if Index = 0 and then Kind /= "QueryRemoved" then
                  raise Constraint_Error
                    with "Transition referenced an unknown query";
               end if;
               if Kind = "QueryUpdated" then
                  declare
                     Value     : constant JSON.JSON_Value :=
                       Modification.Get ("value");
                     Has_Logs  : Boolean;
                     Logs      : JSON.JSON_Array;
                     Signature : constant String := JSON.Write (Value);
                  begin
                     Logs_Field (Modification, Has_Logs, Logs);
                     Pending (Index) :=
                       (Present   => True,
                        Item      =>
                          (Has_Value => True,
                           Value     => Value,
                           Has_Error => False,
                           Error     => <>,
                           Has_Logs  => Has_Logs,
                           Logs      => Logs,
                           Token     => 0),
                        Signature => US.To_Unbounded_String (Signature));
                  end;
               elsif Kind = "QueryFailed" then
                  declare
                     Has_Logs : Boolean;
                     Logs     : JSON.JSON_Array;
                     Has_Data : constant Boolean :=
                       Modification.Has_Field ("errorData");
                     Data     : constant JSON.JSON_Value :=
                       (if Has_Data
                        then Modification.Get ("errorData")
                        else JSON.JSON_Null);
                  begin
                     Logs_Field (Modification, Has_Logs, Logs);
                     Pending (Index) :=
                       (Present   => True,
                        Item      =>
                          (Has_Value => False,
                           Value     => JSON.JSON_Null,
                           Has_Error => True,
                           Error     =>
                             (Kind     => Convex.Function_Error,
                              Message  =>
                                US.To_Unbounded_String
                                  (String_Field
                                     (Modification, "errorMessage")),
                              Has_Data => Has_Data,
                              Data     => Data,
                              Has_Logs => Has_Logs,
                              Logs     => Logs),
                           Has_Logs  => Has_Logs,
                           Logs      => Logs,
                           Token     => 0),
                        Signature => US.Null_Unbounded_String);
                  end;
               elsif Kind = "QueryRemoved" then
                  if Index > 0 then
                     Pending (Index) := (others => <>);
                  end if;
               else
                  raise Constraint_Error
                    with "unknown Transition modification " & Kind;
               end if;
            end;
         end loop;

         -- Nothing is published until every modification validates. This is
         -- the transaction boundary for one server Transition.
         Remote_Query_Set := End_Q;
         Remote_Identity := End_I;
         Remote_Timestamp := End_TS;
         Max_Timestamp :=
           Interfaces.Unsigned_64'Max (Max_Timestamp, Numeric_TS);
         Has_Max_Timestamp := True;
         for Pass in Pending'Range loop
            declare
               Chosen : Natural := 0;
            begin
               for I in Pending'Range loop
                  if Pending (I).Present
                    and then (Chosen = 0
                              or else Subs (I).Id < Subs (Chosen).Id)
                  then
                     Chosen := I;
                  end if;
               end loop;
               exit when Chosen = 0;
               Pending (Chosen).Present := False;
               if Pending (Chosen).Item.Has_Value then
                  if not Subs (Chosen).Has_Last
                    or else Subs (Chosen).Last_Value
                            /= Pending (Chosen).Signature
                  then
                     Subs (Chosen).Has_Last := True;
                     Subs (Chosen).Last_Value := Pending (Chosen).Signature;
                     Enqueue
                       (Chosen,
                        Pending (Chosen).Item,
                        US.Length (Pending (Chosen).Signature));
                  end if;
               else
                  Subs (Chosen).Has_Last := False;
                  Subs (Chosen).Last_Value := US.Null_Unbounded_String;
                  Enqueue (Chosen, Pending (Chosen).Item);
               end if;
            end;
         end loop;
         Backoff := 0.1;
      end Handle_Transition;

      procedure Handle_Message (Text : String) is
         Parsed : constant JSON.Read_Result := Read_Bounded_JSON (Text);
      begin
         if not Parsed.Success
           or else Parsed.Value.Kind /= JSON.JSON_Object_Type
         then
            raise Constraint_Error with "invalid Live JSON message";
         end if;
         declare
            Kind : constant String := String_Field (Parsed.Value, "type");
         begin
            if Kind = "Transition" then
               Handle_Transition (Parsed.Value);
            elsif Kind = "Ping"
              or else Kind = "MutationResponse"
              or else Kind = "ActionResponse"
            then
               Backoff := 0.1;
            elsif Kind = "TransitionChunk" then
               raise Constraint_Error with "TransitionChunk is unsupported";
            else
               raise Constraint_Error with "unknown Live message " & Kind;
            end if;
         end;
      end Handle_Message;

   begin
      accept Configure (Deployment_URL : String) do
         URL := US.To_Unbounded_String (Deployment_URL);
         Configured := True;
      end Configure;

      while Configured and then not Stopping loop
         select
            accept Add
              (Path       : String;
               Args       : JSON.JSON_Value;
               Id         : out Natural;
               Generation : out Natural;
               Success    : out Boolean;
               Message    : out US.Unbounded_String)
            do
               Id := 0;
               Generation := 0;
               Success := False;
               Message := US.Null_Unbounded_String;
               if Path'Length < 3 or else Args.Kind /= JSON.JSON_Object_Type
               then
                  Message :=
                    US.To_Unbounded_String
                      ("Live query requires a path and object arguments");
               elsif Active_Count = Max_Subscriptions then
                  Message :=
                    US.To_Unbounded_String ("Live subscription limit is 64");
               elsif Next_Id = Natural'Last
                 or else Next_Generation = Natural'Last
               then
                  Message :=
                    US.To_Unbounded_String
                      ("Live subscription identifier space is exhausted");
               else
                  declare
                     Owned_Args   : constant JSON.JSON_Value :=
                       JSON.Clone (Args);
                     Encoded_Args : constant String := JSON.Write (Owned_Args);
                  begin
                     if Encoded_Args'Length
                       > Convex_WebSocket.Max_Message_Bytes
                       or else Path'Length
                               > Convex_WebSocket.Max_Message_Bytes
                                 - Encoded_Args'Length
                       or else Path'Length + Encoded_Args'Length
                               > Convex_WebSocket.Max_Message_Bytes - 1_024
                     then
                        Message :=
                          US.To_Unbounded_String
                            ("Live subscription exceeds the 4 MiB message limit");
                     else
                        declare
                           Accounted : constant Natural :=
                             Subscription_Charge (Path, Encoded_Args);
                        begin
                           if Active_Bytes + Accounted > Active_Budget then
                              Message :=
                                US.To_Unbounded_String
                                  ("Live subscription state exceeds 8 MiB");
                           else
                              for I in Subs'Range loop
                                 if not Subs (I).Active then
                                    Id := Next_Id;
                                    Generation := Next_Generation;
                                    Next_Id := Next_Id + 1;
                                    Next_Generation := Next_Generation + 1;
                                    Subs (I) :=
                                      (Active     => True,
                                       Id         => Id,
                                       Generation => Generation,
                                       Path       =>
                                         US.To_Unbounded_String (Path),
                                       Args       => Owned_Args,
                                       Accounted  => Accounted,
                                       Has_Last   => False,
                                       Last_Value => US.Null_Unbounded_String);
                                    Active_Bytes := Active_Bytes + Accounted;
                                    if Convex_WebSocket.Is_Open (Socket) then
                                       declare
                                          Modifications : JSON.JSON_Array :=
                                            JSON.Empty_Array;
                                       begin
                                          JSON.Append
                                            (Modifications,
                                             Add_Modification (Subs (I)));
                                          Send_Modifications
                                            (Query_Set_Version,
                                             Query_Set_Version + 1,
                                             Modifications);
                                       exception
                                          when E : others =>
                                             Disconnect
                                               ("add: "
                                                & Ada
                                                    .Exceptions
                                                    .Exception_Message (E));
                                       end;
                                    else
                                       Reconnect_At := Ada.Real_Time.Clock;
                                    end if;
                                    Success := True;
                                    exit;
                                 end if;
                              end loop;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end Add;
         or
            accept Remove (Id, Generation : Natural) do
               declare
                  Index : constant Natural := Find_Sub (Id, Generation);
               begin
                  if Index > 0 then
                     Remove_Queued (Id, Generation);
                     Active_Bytes := Active_Bytes - Subs (Index).Accounted;
                     -- Retire the generation before doing any network work. If
                     -- the send fails, Disconnect broadcasts only to the still
                     -- active subscriptions, so nothing from this generation
                     -- can cross the unsubscribe acknowledgement barrier.
                     Subs (Index).Active := False;
                     Subs (Index).Accounted := 0;
                     Subs (Index).Has_Last := False;
                     Subs (Index).Last_Value := US.Null_Unbounded_String;
                     if Convex_WebSocket.Is_Open (Socket) then
                        declare
                           Modifications : JSON.JSON_Array := JSON.Empty_Array;
                           Remove_Item   : constant JSON.JSON_Value :=
                             JSON.Create_Object;
                        begin
                           Remove_Item.Set_Field ("type", "Remove");
                           Remove_Item.Set_Field
                             ("queryId", JSON.Create (Long_Long_Integer (Id)));
                           JSON.Append (Modifications, Remove_Item);
                           Send_Modifications
                             (Query_Set_Version,
                              Query_Set_Version + 1,
                              Modifications);
                        exception
                           when E : others =>
                              Disconnect
                                ("remove: "
                                 & Ada.Exceptions.Exception_Message (E));
                        end;
                     end if;
                  end if;
                  --  Route through Disconnect rather than shutting the
                  --  socket down directly. A direct Shutdown left
                  --  Connection_Active, Connection_Count, and
                  --  Last_Close_Reason stale, so the next Establish
                  --  incorrectly reported connectionCount 0 and
                  --  InitialConnect for what is actually a later
                  --  connection. Report => False: losing the last
                  --  subscription is not itself a transport failure, and
                  --  there is nothing left to broadcast it to.
                  if Active_Count = 0 then
                     Disconnect ("no active subscriptions", Report => False);
                  end if;
               end;
            end Remove;
         or
            accept Next
              (Id, Generation : Natural;
               Found          : out Boolean;
               Item           : out Update)
            do
               Found := False;
               Item := (others => <>);
               -- The adapter releases each item after its complete NDJSON line
               -- is written. Never replace that accounting with a second item.
               if Inflight_Bytes = 0 and then Queue_Count > 0 then
                  for Offset in 0 .. Queue_Count - 1 loop
                     declare
                        Index : constant Positive :=
                          ((Queue_First - 1 + Offset) mod Queue_Capacity) + 1;
                     begin
                        if Queue (Index).Id = Id
                          and then Queue (Index).Generation = Generation
                        then
                           -- The adapter is the only dispatcher. Keep this event
                           -- charged as in-flight until its complete NDJSON line is written.
                           Item := Queue (Index).Item;
                           Item.Token := Next_Token;
                           Next_Token := Next_Token + 1;
                           Inflight_Token := Item.Token;
                           Inflight_Bytes := Queue (Index).Charge;
                           declare
                              Kept  : Update_Array;
                              Count : Natural := 0;
                              Bytes : Natural := 0;
                           begin
                              for Other in 0 .. Queue_Count - 1 loop
                                 declare
                                    Other_Index : constant Positive :=
                                      ((Queue_First - 1 + Other)
                                       mod Queue_Capacity)
                                      + 1;
                                 begin
                                    if Other_Index /= Index then
                                       Count := Count + 1;
                                       Kept (Count) := Queue (Other_Index);
                                       Bytes :=
                                         Bytes + Queue (Other_Index).Charge;
                                    end if;
                                 end;
                              end loop;
                              Queue := Kept;
                              Queue_First := 1;
                              Queue_Count := Count;
                              Queue_Bytes := Bytes;
                           end;
                           Found := True;
                           exit;
                        end if;
                     end;
                  end loop;
               end if;
            end Next;
         or
            accept Release_Update (Token : Natural) do
               if Token /= 0 and then Token = Inflight_Token then
                  Inflight_Token := 0;
                  Inflight_Bytes := 0;
               end if;
            end Release_Update;
         or
            accept Disconnect
              (Success : out Boolean; Message : out US.Unbounded_String)
            do
               if Convex_WebSocket.Is_Open (Socket) then
                  Convex_WebSocket.Shutdown (Socket);
                  Queue := [others => <>];
                  Queue_First := 1;
                  Queue_Count := 0;
                  Queue_Bytes := 0;
                  if Connection_Count < Interfaces.Unsigned_32'Last then
                     Connection_Count := Connection_Count + 1;
                  end if;
                  Connection_Active := False;
                  Query_Set_Version := 0;
                  Remote_Query_Set := 0;
                  Remote_Identity := 0;
                  Remote_Timestamp :=
                    US.To_Unbounded_String (Initial_Timestamp);
                  Last_Close_Reason :=
                    US.To_Unbounded_String ("adapter debug disconnect");
                  Reconnect_At :=
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (0.1);
                  Success := True;
                  Message := US.Null_Unbounded_String;
               else
                  Success := False;
                  Message :=
                    US.To_Unbounded_String ("Live WebSocket is not connected");
               end if;
            end Disconnect;
         or
            accept Stop do
               Stopping := True;
               Convex_WebSocket.Shutdown (Socket);
               Connection_Active := False;
               Queue := [others => <>];
               Subs := [others => <>];
               Queue_Count := 0;
               Queue_Bytes := 0;
               Inflight_Bytes := 0;
               Active_Bytes := 0;
            end Stop;
         else
            if Active_Count > 0
              and then not Convex_WebSocket.Is_Open (Socket)
              and then Ada.Real_Time.Clock >= Reconnect_At
            then
               Establish;
            elsif Convex_WebSocket.Is_Open (Socket) then
               declare
                  Item : Convex_WebSocket.Event;
               begin
                  Convex_WebSocket.Poll (Socket, 0.02, Item);
                  case Item.Kind is
                     when Convex_WebSocket.Text_Message     =>
                        begin
                           Handle_Message (US.To_String (Item.Data));
                        exception
                           when E : others =>
                              Broadcast_Error
                                (Convex.Protocol_Error,
                                 Ada.Exceptions.Exception_Message (E));
                              Disconnect
                                ("protocol: "
                                 & Ada.Exceptions.Exception_Message (E),
                                 Report => False);
                        end;

                     when Convex_WebSocket.Control_Traffic  =>
                        Backoff := 0.1;

                     when Convex_WebSocket.Protocol_Failure =>
                        Broadcast_Error
                          (Convex.Protocol_Error, US.To_String (Item.Data));
                        Disconnect
                          ("protocol: " & US.To_String (Item.Data),
                           Report => False);

                     when Convex_WebSocket.Transport_Failure
                        | Convex_WebSocket.Peer_Close       =>
                        Disconnect
                          ((if US.Length (Item.Data) = 0
                            then "peer closed"
                            else US.To_String (Item.Data)));

                     when Convex_WebSocket.No_Event         =>
                        null;
                  end case;
               end;
            else
               delay 0.005;
            end if;
         end select;
      end loop;
   exception
      when E : others =>
         declare
            Failure_Message : constant String :=
              "Live owner task failed: "
              & Ada.Exceptions.Exception_Message (E);
            Stop_Requested  : Boolean := False;
         begin
            --  An unhandled exception here would terminate this task, and
            --  every later Manager entry call would then raise
            --  Tasking_Error instead of a reportable Convex error. Stay
            --  alive and answer every entry with a structured
            --  TransportError until Stop releases it, so a caller always
            --  gets a Convex.Live outcome rather than an unrelated
            --  language-level exception. An exit_statement may not appear
            --  inside an accept_statement, so Stop only records the request
            --  here; the loop below retires on it.
            loop
               select
                  accept Add
                    (Path       : String;
                     Args       : JSON.JSON_Value;
                     Id         : out Natural;
                     Generation : out Natural;
                     Success    : out Boolean;
                     Message    : out US.Unbounded_String)
                  do
                     pragma Unreferenced (Path, Args);
                     Id := 0;
                     Generation := 0;
                     Success := False;
                     Message := US.To_Unbounded_String (Failure_Message);
                  end Add;
               or
                  accept Remove (Id, Generation : Natural) do
                     pragma Unreferenced (Id, Generation);
                     null;
                  end Remove;
               or
                  accept Next
                    (Id, Generation : Natural;
                     Found          : out Boolean;
                     Item           : out Update)
                  do
                     pragma Unreferenced (Id, Generation);
                     Found := True;
                     Item :=
                       Error_Update (Convex.Transport_Error, Failure_Message);
                  end Next;
               or
                  accept Release_Update (Token : Natural) do
                     pragma Unreferenced (Token);
                     null;
                  end Release_Update;
               or
                  accept Disconnect
                    (Success : out Boolean; Message : out US.Unbounded_String)
                  do
                     Success := False;
                     Message := US.To_Unbounded_String (Failure_Message);
                  end Disconnect;
               or
                  accept Stop do
                     Stop_Requested := True;
                  end Stop;
               end select;
               exit when Stop_Requested;
            end loop;
         end;
   end Owner_Task;

   procedure Open (M : in out Manager; Deployment_URL : String) is
   begin
      if M.Opened then
         Close (M);
      end if;
      M.Owner := new Owner_Task;
      M.Owner.Configure (Deployment_URL);
      M.Opened := True;
   end Open;

   procedure Subscribe
     (M       : in out Manager;
      Path    : String;
      Args    : JSON.JSON_Value;
      Result  : out Subscription;
      Success : out Boolean;
      Message : out US.Unbounded_String)
   is
      Id, Generation : Natural;
   begin
      Result := (others => <>);
      if not M.Opened or else M.Owner = null then
         Success := False;
         Message := US.To_Unbounded_String ("Live manager is closed");
         return;
      end if;
      M.Owner.Add (Path, Args, Id, Generation, Success, Message);
      if Success then
         Result := (Id => Id, Generation => Generation, Active => True);
      end if;
   exception
      --  The owner task's own top-level handler keeps it alive to answer
      --  every entry, so Tasking_Error here means the task object itself is
      --  gone (already Stop-ped and freed). Report it the same way a live
      --  owner reports its own terminal failure rather than propagating a
      --  language-level exception to an adapter that expects a Convex one.
      when Tasking_Error =>
         Success := False;
         Message :=
           US.To_Unbounded_String ("Live manager task is no longer available");
   end Subscribe;

   procedure Unsubscribe (M : in out Manager; Sub : in out Subscription) is
   begin
      if M.Opened and then M.Owner /= null and then Sub.Active then
         M.Owner.Remove (Sub.Id, Sub.Generation);
      end if;
      Sub.Active := False;
   exception
      when Tasking_Error =>
         Sub.Active := False;
   end Unsubscribe;

   procedure Try_Next
     (M     : in out Manager;
      Sub   : Subscription;
      Found : out Boolean;
      Item  : out Update) is
   begin
      if not M.Opened or else M.Owner = null or else not Sub.Active then
         Found := False;
         Item := (others => <>);
         return;
      end if;
      M.Owner.Next (Sub.Id, Sub.Generation, Found, Item);
   exception
      when Tasking_Error =>
         Found := True;
         Item :=
           Error_Update
             (Convex.Transport_Error,
              "Live manager task is no longer available");
   end Try_Next;

   procedure Release (M : in out Manager; Item : in out Update) is
   begin
      if M.Opened and then M.Owner /= null and then Item.Token /= 0 then
         M.Owner.Release_Update (Item.Token);
      end if;
      Item.Token := 0;
   exception
      when Tasking_Error =>
         Item.Token := 0;
   end Release;

   procedure Close (M : in out Manager) is
   begin
      if M.Opened and then M.Owner /= null then
         M.Owner.Stop;
         --  Unchecked_Deallocation requires a terminated task. The Stop
         --  rendezvous above only guarantees its accept body ran, not that
         --  the task's own activation has finished unwinding, so wait for
         --  that before freeing the object it names.
         while not M.Owner.all'Terminated loop
            delay 0.001;
         end loop;
         Free_Owner (M.Owner);
      end if;
      M.Opened := False;
   exception
      when Tasking_Error =>
         if M.Owner /= null and then M.Owner.all'Terminated then
            Free_Owner (M.Owner);
         end if;
         M.Opened := False;
   end Close;

   function Is_Active (Sub : Subscription) return Boolean
   is (Sub.Active);
end Convex.Live;
