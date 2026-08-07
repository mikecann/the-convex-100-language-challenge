with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Convex;
with Convex.Live;
with Convex_Adapter_Events;
with Convex_Adapter_Output;
with Convex_WebSocket;
with GNATCOLL.JSON;

procedure Convex_Adapter_Event_Tests is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;

   --  These assertions are on the exact NDJSON text the shared controller
   --  validates. Checking a decoded object instead would not catch a field
   --  that is present but should have been omitted, which is precisely the
   --  mismatch adapter.schema.json rejects.
   procedure Check_Line (Actual, Expected, Message : String) is
   begin
      if Actual /= Expected then
         raise Program_Error
           with Message & ": expected " & Expected & " but got " & Actual;
      end if;
   end Check_Line;

   function One_Log return JSON.JSON_Array is
      Logs : JSON.JSON_Array := JSON.Empty_Array;
   begin
      JSON.Append (Logs, JSON.Create (String'("log line")));
      return Logs;
   end One_Log;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   --  U+00E9 as UTF-8. One code point, two bytes: a byte-length check would
   --  disagree with the shared schema's character-length bound.
   Two_Byte_Scalar : constant String :=
     Character'Val (16#C3#) & Character'Val (16#A9#);

   Output_Limit : constant := Convex_Adapter_Output.Max_Line_Bytes;

   --  A subscription delivery carrying one unescaped string value serializes
   --  as this fixed 59-byte envelope around the value's characters, which is
   --  what makes the assertions below exact rather than approximate.
   Value_Envelope : constant := 59;
   Delivery_Head  : constant String :=
     "{""type"":""subscription"",""subscriptionId"":""sub-4"",""value"":""";

   type String_Access is access String;

   --  Multi-megabyte payloads live on the heap. A local object this size
   --  would be an environment-task stack allocation, which is a test harness
   --  failure mode rather than anything the adapter does.
   function Filled (Length : Natural) return String_Access is
      Result : constant String_Access := new String (1 .. Length);
   begin
      for I in Result.all'Range loop
         Result.all (I) := 'x';
      end loop;
      return Result;
   end Filled;

   function Delivery (Value : String) return Convex.Live.Update is
      Item : Convex.Live.Update;
   begin
      Item.Has_Value := True;
      Item.Value := JSON.Create (Value);
      return Item;
   end Delivery;

   --  Take the finished line as a parameter so a near-ceiling event is passed
   --  by reference instead of copied into a local constant.
   procedure Check_Delivery
     (Line : String; Expected_Length : Natural; Message : String) is
   begin
      Check (Line'Length = Expected_Length, Message & ": wrong length");
      Check
        (Line'Length >= Delivery_Head'Length
         and then Line (Line'First .. Line'First + Delivery_Head'Length - 1)
                  = Delivery_Head,
         Message & ": wrong shape");
   end Check_Delivery;

begin
   Check (not Convex_Adapter_Events.Valid_Id (""), "empty id must be invalid");
   Check
     (Convex_Adapter_Events.Valid_Id (String'(1 .. 128 => 'x')),
      "a 128 character id must be valid");
   Check
     (not Convex_Adapter_Events.Valid_Id (String'(1 .. 129 => 'x')),
      "a 129 character id must be invalid");
   declare
      Long_Scalars : String (1 .. 256);
   begin
      for I in 1 .. 128 loop
         Long_Scalars (2 * I - 1) := Two_Byte_Scalar (Two_Byte_Scalar'First);
         Long_Scalars (2 * I) := Two_Byte_Scalar (Two_Byte_Scalar'Last);
      end loop;
      Check
        (Convex_Adapter_Events.Valid_Id (Long_Scalars),
         "128 two-byte scalars must be valid despite being 256 bytes");
      Check
        (not Convex_Adapter_Events.Valid_Id (Long_Scalars & Two_Byte_Scalar),
         "129 two-byte scalars must be invalid");
   end;

   Check_Line
     (Convex_Adapter_Events.Ready
        ("hello", "ada", "native-aws-net-rfc6455-0.1.0", "GNAT 14.2.1"),
      "{""protocolVersion"":1,""id"":""hello"",""type"":""ready"","
      & """language"":""ada"","
      & """implementation"":""native-aws-net-rfc6455-0.1.0"","
      & """runtime"":""GNAT 14.2.1""}",
      "ready event shape");

   Check_Line
     (Convex_Adapter_Events.Ack ("a1"),
      "{""id"":""a1"",""type"":""ack""}",
      "ack event shape");

   Check_Line
     (Convex_Adapter_Events.Closed ("c1"),
      "{""id"":""c1"",""type"":""closed""}",
      "closed event shape");

   --  A deployment that sent no logLines must not gain an empty logs array on
   --  the way out. This is the regression the presence flag exists to prevent.
   Check_Line
     (Convex_Adapter_Events.Call_Result_Event
        ("q1",
         (Success  => True,
          Value    => JSON.Create (Long_Long_Integer (7)),
          Has_Logs => False,
          Logs     => JSON.Empty_Array)),
      "{""id"":""q1"",""type"":""result"",""value"":7}",
      "successful result omits absent logs");

   --  An explicitly empty logLines array is a different observation and is
   --  serialized as one.
   Check_Line
     (Convex_Adapter_Events.Call_Result_Event
        ("q2",
         (Success  => True,
          Value    => JSON.JSON_Null,
          Has_Logs => True,
          Logs     => JSON.Empty_Array)),
      "{""id"":""q2"",""type"":""result"",""value"":null,""logs"":[]}",
      "successful result keeps an empty logs array");

   Check_Line
     (Convex_Adapter_Events.Call_Result_Event
        ("q3",
         (Success  => True,
          Value    => JSON.Create (True),
          Has_Logs => True,
          Logs     => One_Log)),
      "{""id"":""q3"",""type"":""result"",""value"":true,"
      & """logs"":[""log line""]}",
      "successful result carries present logs");

   Check_Line
     (Convex_Adapter_Events.Call_Result_Event
        ("m1",
         (Success => False,
          Error   =>
            (Kind     => Convex.Function_Error,
             Message  => US.To_Unbounded_String ("function failed"),
             Has_Data => True,
             Data     => JSON.Create (Long_Long_Integer (9)),
             Has_Logs => True,
             Logs     => One_Log))),
      "{""id"":""m1"",""type"":""error"",""error"":"
      & "{""name"":""FunctionError"",""message"":""function failed"","
      & """data"":9},""logs"":[""log line""]}",
      "structured HTTP error shape");

   Check_Line
     (Convex_Adapter_Events.Call_Result_Event
        ("m2",
         (Success => False,
          Error   =>
            (Kind     => Convex.Transport_Error,
             Message  => US.To_Unbounded_String ("peer closed"),
             Has_Data => False,
             Data     => JSON.JSON_Null,
             Has_Logs => False,
             Logs     => JSON.Empty_Array))),
      "{""id"":""m2"",""type"":""error"",""error"":"
      & "{""name"":""TransportError"",""message"":""peer closed""}}",
      "transport error omits absent data and logs");

   --  An unvalidated command id must never reach the controller, so the error
   --  event omits the field rather than sending an empty string.
   Check_Line
     (Convex_Adapter_Events.Protocol_Error_Event ("", "invalid command"),
      "{""type"":""error"",""error"":"
      & "{""name"":""ProtocolError"",""message"":""invalid command""}}",
      "protocol error without a validated id");

   Check_Line
     (Convex_Adapter_Events.Protocol_Error_Event ("p1", "unknown operation"),
      "{""id"":""p1"",""type"":""error"",""error"":"
      & "{""name"":""ProtocolError"",""message"":""unknown operation""}}",
      "protocol error with a validated id");

   Check_Line
     (Convex_Adapter_Events.Subscription_Event
        ("sub-1",
         (Has_Value => True,
          Value     => JSON.Create (Long_Long_Integer (1)),
          Has_Error => False,
          Error     => <>,
          Has_Logs  => False,
          Logs      => JSON.Empty_Array,
          Token     => 3)),
      "{""type"":""subscription"",""subscriptionId"":""sub-1"",""value"":1}",
      "subscription value omits absent logs");

   Check_Line
     (Convex_Adapter_Events.Subscription_Event
        ("sub-1",
         (Has_Value => True,
          Value     => JSON.Create (Long_Long_Integer (2)),
          Has_Error => False,
          Error     => <>,
          Has_Logs  => True,
          Logs      => One_Log,
          Token     => 4)),
      "{""type"":""subscription"",""subscriptionId"":""sub-1"",""value"":2,"
      & """logs"":[""log line""]}",
      "subscription value carries present logs");

   Check_Line
     (Convex_Adapter_Events.Subscription_Event
        ("sub-2",
         (Has_Value => False,
          Value     => JSON.JSON_Null,
          Has_Error => True,
          Error     =>
            (Kind     => Convex.Function_Error,
             Message  => US.To_Unbounded_String ("query failed"),
             Has_Data => False,
             Data     => JSON.JSON_Null,
             Has_Logs => True,
             Logs     => One_Log),
          Has_Logs  => True,
          Logs      => One_Log,
          Token     => 5)),
      "{""type"":""subscription"",""subscriptionId"":""sub-2"",""error"":"
      & "{""name"":""FunctionError"",""message"":""query failed""},"
      & """logs"":[""log line""]}",
      "subscription error shape");

   Check_Line
     (Convex_Adapter_Events.Subscription_Event
        ("sub-3",
         (Has_Value => False,
          Value     => JSON.JSON_Null,
          Has_Error => True,
          Error     =>
            (Kind     => Convex.Protocol_Error,
             Message  => US.To_Unbounded_String ("bad transition"),
             Has_Data => False,
             Data     => JSON.JSON_Null,
             Has_Logs => False,
             Logs     => JSON.Empty_Array),
          Has_Logs  => False,
          Logs      => JSON.Empty_Array,
          Token     => 6)),
      "{""type"":""subscription"",""subscriptionId"":""sub-3"",""error"":"
      & "{""name"":""ProtocolError"",""message"":""bad transition""}}",
      "subscription protocol error omits absent logs");

   --  An adapter-detected subscription failure uses the same encoder as a
   --  QueryFailed, so the shared controller sees one subscription error shape.
   Check_Line
     (Convex_Adapter_Events.Subscription_Error_Event ("sub-4", "no room"),
      "{""type"":""subscription"",""subscriptionId"":""sub-4"",""error"":"
      & "{""name"":""ProtocolError"",""message"":""no room""}}",
      "adapter-detected subscription error shape");

   --  The output ceiling has to cover a schema-valid Live value at the
   --  client's message ceiling. Before this was reconciled, a value between
   --  two and four megabytes raised out of the adapter's main loop and killed
   --  the process instead of reaching the controller at all.
   Check
     (Output_Limit >= Convex_WebSocket.Max_Message_Bytes,
      "the adapter output ceiling is below the Live message ceiling");

   declare
      Ceiling_Value : constant String_Access :=
        Filled (Convex_WebSocket.Max_Message_Bytes - 1_000);
      Item          : constant Convex.Live.Update :=
        Delivery (Ceiling_Value.all);
   begin
      Check_Delivery
        (Convex_Adapter_Events.Subscription_Line ("sub-4", Item, Output_Limit),
         Ceiling_Value.all'Length + Value_Envelope,
         "a Live value at the message ceiling was not delivered verbatim");
   end;

   --  Only an event that genuinely cannot be encoded within the contract is
   --  replaced, and the replacement names both sizes so the controller's log
   --  says what was dropped.
   declare
      Over_Value : constant String_Access :=
        Filled (Output_Limit - Value_Envelope + 1);
      Item       : constant Convex.Live.Update := Delivery (Over_Value.all);
   begin
      Check_Line
        (Convex_Adapter_Events.Subscription_Line ("sub-4", Item, Output_Limit),
         "{""type"":""subscription"",""subscriptionId"":""sub-4"",""error"":"
         & "{""name"":""ProtocolError"",""message"":""encoded event of "
         & Image (Output_Limit + 1)
         & " bytes exceeds the "
         & Image (Output_Limit)
         & " byte adapter output limit""}}",
         "an unencodable Live value did not become a subscription error");
   end;

   --  The same substitution for a finished HTTP call, keyed to the command id
   --  rather than a subscription.
   Check_Line
     (Convex_Adapter_Events.Call_Result_Line
        ("q4",
         (Success  => True,
          Value    => JSON.Create (String'(1 .. 100 => 'x')),
          Has_Logs => False,
          Logs     => JSON.Empty_Array),
         100),
      "{""id"":""q4"",""type"":""error"",""error"":"
      & "{""name"":""ProtocolError"",""message"":""encoded event of "
      & "138 bytes exceeds the 100 byte adapter output limit""}}",
      "an unencodable call result did not become a protocol error");

   --  Substitution retains nothing: the next delivery on the same
   --  subscription and the next result for the same command are unchanged.
   Check_Line
     (Convex_Adapter_Events.Subscription_Line
        ("sub-4", Delivery ("ok"), Output_Limit),
      "{""type"":""subscription"",""subscriptionId"":""sub-4"","
      & """value"":""ok""}",
      "a subscription did not recover after an unencodable value");

   Check_Line
     (Convex_Adapter_Events.Call_Result_Line
        ("q4",
         (Success  => True,
          Value    => JSON.Create (Long_Long_Integer (7)),
          Has_Logs => False,
          Logs     => JSON.Empty_Array),
         Output_Limit),
      "{""id"":""q4"",""type"":""result"",""value"":7}",
      "a call did not recover after an unencodable result");

   --  Reading the ceiling from the output owner elaborates its writer task,
   --  which waits for work forever unless it is told to stop. This test never
   --  starts that owner; releasing it is what lets this program exit.
   Convex_Adapter_Output.Stop;

   Ada.Text_IO.Put_Line ("Ada adapter event shape tests passed");
end Convex_Adapter_Event_Tests;
