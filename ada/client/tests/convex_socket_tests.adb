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
with GNAT.SHA1;
with GNAT.Sockets;
with GNATCOLL.JSON;
with Interfaces;

procedure Convex_Socket_Tests is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Convex.Error_Kind;
   use type Convex_WebSocket.Event_Kind;
   use type GNAT.Sockets.Socket_Type;
   use type GNATCOLL.JSON.JSON_Value_Type;
   use type Interfaces.Unsigned_8;

   WebSocket_GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   Initial_TS     : constant String := "AAAAAAAAAAA=";
   One_TS         : constant String := "AQAAAAAAAAA=";
   Two_TS         : constant String := "AgAAAAAAAAA=";

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

   function Byte (Value : Natural) return Character
   is (Character'Val (Value));

   procedure Close_Quietly (Socket : in out GNAT.Sockets.Socket_Type) is
   begin
      if Socket /= GNAT.Sockets.No_Socket then
         begin
            GNAT.Sockets.Close_Socket (Socket);
         exception
            when others =>
               null;
         end;
         Socket := GNAT.Sockets.No_Socket;
      end if;
   end Close_Quietly;

   procedure Send_All (Socket : GNAT.Sockets.Socket_Type; Text : String) is
      Data : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      Last : Ada.Streams.Stream_Element_Offset;
      Sent : Natural := 0;
   begin
      for I in Text'Range loop
         Data (Ada.Streams.Stream_Element_Offset (I - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (I)));
      end loop;
      while Sent < Text'Length loop
         GNAT.Sockets.Send_Socket
           (Socket,
            Data (Ada.Streams.Stream_Element_Offset (Sent + 1) .. Data'Last),
            Last);
         if Last < Ada.Streams.Stream_Element_Offset (Sent + 1) then
            raise GNAT.Sockets.Socket_Error
              with "fixture peer closed while sending";
         end if;
         Sent := Natural (Last);
      end loop;
   end Send_All;

   procedure Read_Exactly
     (Socket : GNAT.Sockets.Socket_Type; Text : out String)
   is
      Data : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      Last : Ada.Streams.Stream_Element_Offset;
      Read : Natural := 0;
   begin
      while Read < Text'Length loop
         GNAT.Sockets.Receive_Socket
           (Socket,
            Data (Ada.Streams.Stream_Element_Offset (Read + 1) .. Data'Last),
            Last);
         if Last < Ada.Streams.Stream_Element_Offset (Read + 1) then
            raise GNAT.Sockets.Socket_Error
              with "fixture peer closed while receiving";
         end if;
         Read := Natural (Last);
      end loop;
      for I in Text'Range loop
         Text (I) :=
           Character'Val
             (Data (Ada.Streams.Stream_Element_Offset (I - Text'First + 1)));
      end loop;
   end Read_Exactly;

   function Read_HTTP_Headers (Socket : GNAT.Sockets.Socket_Type) return String
   is
      Data : Ada.Streams.Stream_Element_Array (1 .. 1_024);
      Last : Ada.Streams.Stream_Element_Offset;
      Text : US.Unbounded_String;
   begin
      loop
         GNAT.Sockets.Receive_Socket (Socket, Data, Last);
         if Last < Data'First then
            raise GNAT.Sockets.Socket_Error with "peer closed during upgrade";
         end if;
         for I in Data'First .. Last loop
            US.Append (Text, Character'Val (Data (I)));
         end loop;
         declare
            Value : constant String := US.To_String (Text);
         begin
            if Ada.Strings.Fixed.Index
                 (Value, ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF)
              > 0
            then
               return Value;
            end if;
            if Value'Length > 16 * 1_024 then
               raise Constraint_Error
                 with "fixture upgrade request is too large";
            end if;
         end;
      end loop;
   end Read_HTTP_Headers;

   function Header_Value (Headers, Name : String) return String is
      Needle : constant String := Name & ": ";
      First  : constant Natural := Ada.Strings.Fixed.Index (Headers, Needle);
      Last   : Natural;
   begin
      if First = 0 then
         return "";
      end if;
      Last :=
        Ada.Strings.Fixed.Index
          (Headers, ASCII.CR & ASCII.LF, First + Needle'Length);
      if Last = 0 then
         return "";
      end if;
      return Headers (First + Needle'Length .. Last - 1);
   end Header_Value;

   procedure Upgrade
     (Listener : GNAT.Sockets.Socket_Type; Peer : out GNAT.Sockets.Socket_Type)
   is
      Address : GNAT.Sockets.Sock_Addr_Type;
   begin
      GNAT.Sockets.Accept_Socket (Listener, Peer, Address);
      declare
         Request      : constant String := Read_HTTP_Headers (Peer);
         Key          : constant String :=
           Header_Value (Request, "Sec-WebSocket-Key");
         Digest       : constant GNAT.SHA1.Binary_Message_Digest :=
           GNAT.SHA1.Digest (Key & WebSocket_GUID);
         Accept_Value : constant String :=
           Convex_WebSocket.Encode_Base64 (Digest);
      begin
         Check
           (Ada.Strings.Fixed.Index (Request, "GET /api/sync HTTP/1.1") = 1,
            "fixture expected the /api/sync upgrade path");
         Check (Key'Length > 0, "fixture did not receive a WebSocket key");
         Send_All
           (Peer,
            "HTTP/1.1 101 Switching Protocols"
            & ASCII.CR
            & ASCII.LF
            & "Upgrade: websocket"
            & ASCII.CR
            & ASCII.LF
            & "Connection: Upgrade"
            & ASCII.CR
            & ASCII.LF
            & "Sec-WebSocket-Accept: "
            & Accept_Value
            & ASCII.CR
            & ASCII.LF
            & ASCII.CR
            & ASCII.LF);
      end;
   end Upgrade;

   procedure Send_Frame
     (Socket : GNAT.Sockets.Socket_Type; First : Natural; Payload : String) is
   begin
      if Payload'Length <= 125 then
         Send_All (Socket, Byte (First) & Byte (Payload'Length) & Payload);
      elsif Payload'Length <= 65_535 then
         Send_All
           (Socket,
            Byte (First)
            & Byte (126)
            & Byte (Payload'Length / 256)
            & Byte (Payload'Length mod 256)
            & Payload);
      else
         Send_All
           (Socket,
            Byte (First)
            & Byte (127)
            & Byte (0)
            & Byte (0)
            & Byte (0)
            & Byte (0)
            & Byte ((Payload'Length / 16#1000000#) mod 256)
            & Byte ((Payload'Length / 16#10000#) mod 256)
            & Byte ((Payload'Length / 256) mod 256)
            & Byte (Payload'Length mod 256));
         Send_All (Socket, Payload);
      end if;
   end Send_Frame;

   function Read_Client_Text (Socket : GNAT.Sockets.Socket_Type) return String
   is
      Header : String (1 .. 2);
   begin
      Read_Exactly (Socket, Header);
      declare
         B1     : constant Interfaces.Unsigned_8 :=
           Interfaces.Unsigned_8 (Character'Pos (Header (1)));
         B2     : constant Interfaces.Unsigned_8 :=
           Interfaces.Unsigned_8 (Character'Pos (Header (2)));
         Length : Natural := Natural (B2 and 16#7F#);
      begin
         Check
           ((B1 and 16#80#) /= 0 and then (B1 and 16#0F#) = 1,
            "client fixture expected a final text frame");
         Check ((B2 and 16#80#) /= 0, "client WebSocket frame was not masked");
         if Length = 126 then
            declare
               Extended : String (1 .. 2);
            begin
               Read_Exactly (Socket, Extended);
               Length :=
                 Character'Pos (Extended (1))
                 * 256
                 + Character'Pos (Extended (2));
            end;
         elsif Length = 127 then
            declare
               Extended : String (1 .. 8);
            begin
               Read_Exactly (Socket, Extended);
               Check
                 (Extended (1 .. 4) = String'(1 .. 4 => Byte (0)),
                  "fixture received an unexpectedly large client frame");
               Length := 0;
               for I in 5 .. 8 loop
                  Length := Length * 256 + Character'Pos (Extended (I));
               end loop;
            end;
         end if;
         declare
            Mask    : String (1 .. 4);
            Payload : String (1 .. Length);
         begin
            Read_Exactly (Socket, Mask);
            if Length > 0 then
               Read_Exactly (Socket, Payload);
               for I in Payload'Range loop
                  Payload (I) :=
                    Character'Val
                      (Interfaces.Unsigned_8 (Character'Pos (Payload (I)))
                       xor Interfaces.Unsigned_8
                             (Character'Pos (Mask ((I - 1) mod 4 + 1))));
               end loop;
            end if;
            return Payload;
         end;
      end;
   end Read_Client_Text;

   function Read_Client_Opcode
     (Socket : GNAT.Sockets.Socket_Type) return Natural
   is
      Header : String (1 .. 2);
   begin
      Read_Exactly (Socket, Header);
      declare
         B1     : constant Interfaces.Unsigned_8 :=
           Interfaces.Unsigned_8 (Character'Pos (Header (1)));
         B2     : constant Interfaces.Unsigned_8 :=
           Interfaces.Unsigned_8 (Character'Pos (Header (2)));
         Length : constant Natural := Natural (B2 and 16#7F#);
         Mask   : String (1 .. 4);
      begin
         Check ((B1 and 16#80#) /= 0, "client control frame was fragmented");
         Check ((B2 and 16#80#) /= 0, "client control frame was not masked");
         Check (Length <= 125, "client control frame was too large");
         Read_Exactly (Socket, Mask);
         if Length > 0 then
            declare
               Payload : String (1 .. Length);
            begin
               Read_Exactly (Socket, Payload);
            end;
         end if;
         return Natural (B1 and 16#0F#);
      end;
   end Read_Client_Opcode;

   procedure Wait_For_Close (Socket : GNAT.Sockets.Socket_Type) is
      Data : Ada.Streams.Stream_Element_Array (1 .. 256);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         GNAT.Sockets.Receive_Socket (Socket, Data, Last);
         exit when Last < Data'First;
      end loop;
   exception
      when GNAT.Sockets.Socket_Error =>
         null;
   end Wait_For_Close;

   procedure Open_Listener
     (Listener : out GNAT.Sockets.Socket_Type;
      Port     : out GNAT.Sockets.Port_Type)
   is
      Address : GNAT.Sockets.Sock_Addr_Type;
   begin
      GNAT.Sockets.Create_Socket (Listener);
      GNAT.Sockets.Set_Socket_Option
        (Listener,
         GNAT.Sockets.Socket_Level,
         (Name => GNAT.Sockets.Reuse_Address, Enabled => True));
      Address.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Address.Port := 0;
      GNAT.Sockets.Bind_Socket (Listener, Address);
      GNAT.Sockets.Listen_Socket (Listener, 1);
      Port := GNAT.Sockets.Get_Socket_Name (Listener).Port;
   end Open_Listener;

   function URL (Port : GNAT.Sockets.Port_Type) return String
   is ("http://127.0.0.1:" & Image (Natural (Port)));

   function String_Field
     (Object : JSON.JSON_Value; Name : String) return String;

   function Read_HTTP_Request (Socket : GNAT.Sockets.Socket_Type) return String
   is
      Prefix      : constant String := Read_HTTP_Headers (Socket);
      End_At      : constant Natural :=
        Ada.Strings.Fixed.Index
          (Prefix, ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF);
      Body_Length : constant Natural :=
        Natural'Value (Header_Value (Prefix, "Content-Length"));
      Needed      : constant Natural := End_At + 3 + Body_Length;
      Text        : US.Unbounded_String := US.To_Unbounded_String (Prefix);
      Data        : Ada.Streams.Stream_Element_Array (1 .. 1_024);
      Last        : Ada.Streams.Stream_Element_Offset;
   begin
      while US.Length (Text) < Needed loop
         GNAT.Sockets.Receive_Socket (Socket, Data, Last);
         if Last < Data'First then
            raise GNAT.Sockets.Socket_Error
              with "peer closed during HTTP body";
         end if;
         for I in Data'First .. Last loop
            US.Append (Text, Character'Val (Data (I)));
         end loop;
      end loop;
      return US.Slice (Text, 1, Needed);
   end Read_HTTP_Request;

   function HTTP_Body (Request : String) return String is
      End_At : constant Natural :=
        Ada.Strings.Fixed.Index
          (Request, ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF);
   begin
      return Request (End_At + 4 .. Request'Last);
   end HTTP_Body;

   procedure Send_HTTP_Response
     (Socket : GNAT.Sockets.Socket_Type; Response_Body : String) is
   begin
      Send_All
        (Socket,
         "HTTP/1.1 200 OK"
         & ASCII.CR
         & ASCII.LF
         & "Content-Type: application/json"
         & ASCII.CR
         & ASCII.LF
         & "Content-Length: "
         & Image (Response_Body'Length)
         & ASCII.CR
         & ASCII.LF
         & "Connection: close"
         & ASCII.CR
         & ASCII.LF
         & ASCII.CR
         & ASCII.LF
         & Response_Body);
   end Send_HTTP_Response;

   procedure Validate_HTTP_Envelope
     (Request, Operation, Path, Expected_Auth : String)
   is
      Root        : constant JSON.JSON_Value :=
        JSON.Read (HTTP_Body (Request)).Value;
      Auth_Needle : constant String :=
        ASCII.CR
        & ASCII.LF
        & "Authorization: Bearer "
        & Expected_Auth
        & ASCII.CR
        & ASCII.LF;
   begin
      Check
        (Ada.Strings.Fixed.Index
           (Request, "POST /api/" & Operation & " HTTP/1.1")
         = 1,
         "HTTP fixture received the wrong endpoint");
      Check
        (Root.Kind = JSON.JSON_Object_Type,
         "HTTP fixture received a non-object envelope");
      Check
        (String_Field (Root, "path") = Path,
         "HTTP fixture received the wrong function path");
      Check
        (String_Field (Root, "format") = "json",
         "HTTP fixture did not receive the json format marker");
      Check
        (Root.Get ("args").Kind = JSON.JSON_Object_Type,
         "HTTP fixture did not receive object arguments");
      if Expected_Auth'Length = 0 then
         Check
           (Ada.Strings.Fixed.Index
              (Request, ASCII.CR & ASCII.LF & "Authorization:")
            = 0,
            "HTTP fixture received stale authorization");
      else
         Check
           (Ada.Strings.Fixed.Index (Request, Auth_Needle) > 0,
            "HTTP fixture received the wrong bearer token");
      end if;
   end Validate_HTTP_Envelope;

   task type HTTP_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end HTTP_Server;

   task body HTTP_Server is
      Listen  : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer    : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed  : Boolean := False;
      Error   : US.Unbounded_String;
      Address : GNAT.Sockets.Sock_Addr_Type;
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         for Step in 1 .. 4 loop
            GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
            declare
               Request : constant String := Read_HTTP_Request (Peer);
            begin
               case Step is
                  when 1 =>
                     Validate_HTTP_Envelope
                       (Request, "query", "messages:empty", "");
                     Send_HTTP_Response
                       (Peer,
                        "{""status"":""success"",""value"":null,"
                        & """logLines"":[""query log""]}");

                  when 2 =>
                     Validate_HTTP_Envelope
                       (Request,
                        "mutation",
                        "messages:increment",
                        "token-one");
                     Send_HTTP_Response
                       (Peer,
                        "{""status"":""success"",""value"":true,"
                        & """logLines"":[""mutation log""]}");

                  when 3 =>
                     Validate_HTTP_Envelope
                       (Request, "action", "messages:fail", "token-two");
                     Send_HTTP_Response
                       (Peer,
                        "{""status"":""error"",""errorMessage"":""action failed"","
                        & """errorData"":{""code"":9},"
                        & """logLines"":[""action log""]}");

                  when 4 =>
                     Validate_HTTP_Envelope
                       (Request, "query", "messages:count", "");
                     Send_HTTP_Response
                       (Peer, "{""status"":""success"",""value"":7}");
               end case;
            end;
            Close_Quietly (Peer);
         end loop;
         Passed := True;
      exception
         when E : others =>
            Error :=
              US.To_Unbounded_String
                (Ada.Exceptions.Exception_Information (E));
      end;
      Close_Quietly (Peer);
      Close_Quietly (Listen);
      accept Finish
        (Success : out Boolean; Message : out US.Unbounded_String)
      do
         Success := Passed;
         Message := Error;
      end Finish;
   end HTTP_Server;

   procedure Run_HTTP is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : HTTP_Server;
      Client   : Convex.Client;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Success  : Boolean;
      Message  : US.Unbounded_String;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Open (Client, URL (Port));
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:empty", Args);
      begin
         Check (Result.Success, "HTTP query failed");
         Check
           (Result.Value.Kind = JSON.JSON_Null_Type,
            "HTTP query did not preserve null success");
         Check (JSON.Length (Result.Logs) = 1, "HTTP query logs were lost");
      end;

      Convex.Set_Auth (Client, "token-one");
      declare
         Result : constant Convex.Call_Result :=
           Convex.Mutation (Client, "messages:increment", Args);
      begin
         Check (Result.Success, "HTTP mutation failed");
         Check
           (Result.Value.Kind = JSON.JSON_Boolean_Type
            and then Result.Value.Get,
            "HTTP mutation returned the wrong value");
         Check (JSON.Length (Result.Logs) = 1, "HTTP mutation logs were lost");
      end;

      Convex.Set_Auth (Client, "token-two");
      declare
         Result : constant Convex.Call_Result :=
           Convex.Action (Client, "messages:fail", Args);
      begin
         Check (not Result.Success, "HTTP action error became a success");
         Check
           (Result.Error.Kind = Convex.Function_Error,
            "HTTP action error used the wrong kind");
         Check
           (US.To_String (Result.Error.Message) = "action failed",
            "HTTP action error message was lost");
         Check (Result.Error.Has_Data, "HTTP action errorData was lost");
         Check
           (JSON.Length (Result.Error.Logs) = 1,
            "HTTP action error logs were lost");
      end;

      Convex.Set_Auth (Client, "");
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:count", Args);
      begin
         Check (Result.Success, "HTTP query after auth clear failed");
         Check
           (Result.Value.Kind = JSON.JSON_Int_Type,
            "HTTP query after auth clear returned the wrong type");
         Check
           (Long_Long_Integer'(Result.Value.Get) = 7,
            "HTTP query after auth clear returned the wrong value");
      end;

      Convex.Close (Client);
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:count", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Closed_Error,
            "closed HTTP client did not reject a call locally");
      end;
      Server.Finish (Success, Message);
      Check (Success, "HTTP fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Close (Client);
         abort Server;
         raise;
   end Run_HTTP;

   type Transport_Scenario is
     (Valid_Text,
      Fragmented_UTF8,
      Partial_Header,
      Partial_Payload,
      Masked_Server_Frame,
      Noncanonical_Length,
      Fragmented_Control,
      Invalid_UTF8,
      Stalled_Upgrade,
      Idle_Shutdown,
      Half_Frame_Shutdown,
      Continuous_Shutdown);

   task type Transport_Server is
      entry Start
        (Listener : GNAT.Sockets.Socket_Type; Scenario : Transport_Scenario);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Transport_Server;

   task body Transport_Server is
      Listen : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Mode   : Transport_Scenario := Valid_Text;
      Passed : Boolean := False;
      Error  : US.Unbounded_String;
   begin
      accept Start
        (Listener : GNAT.Sockets.Socket_Type; Scenario : Transport_Scenario)
      do
         Listen := Listener;
         Mode := Scenario;
      end Start;
      begin
         if Mode = Stalled_Upgrade then
            declare
               Address : GNAT.Sockets.Sock_Addr_Type;
               Request : US.Unbounded_String;
            begin
               GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
               Request := US.To_Unbounded_String (Read_HTTP_Headers (Peer));
               Check
                 (US.Length (Request) > 0,
                  "stalled upgrade fixture received no request");
               delay 3.0;
            end;
         else
            Upgrade (Listen, Peer);
            case Mode is
               when Valid_Text          =>
                  Send_Frame (Peer, 16#81#, "recovered");

               when Fragmented_UTF8     =>
                  Send_Frame
                    (Peer, 16#01#, "snow " & Byte (16#E2#) & Byte (16#98#));
                  Send_Frame (Peer, 16#89#, "p");
                  Send_Frame (Peer, 16#80#, String'(1 => Byte (16#83#)));

               when Partial_Header      =>
                  Send_All (Peer, String'(1 => Byte (16#81#)));
                  delay 0.15;
                  Send_All (Peer, Byte (5) & "hello");

               when Partial_Payload     =>
                  Send_All (Peer, Byte (16#81#) & Byte (5) & "he");
                  delay 0.15;
                  Send_All (Peer, "llo");

               when Masked_Server_Frame =>
                  Send_All
                    (Peer,
                     Byte (16#81#)
                     & Byte (16#80#)
                     & Byte (0)
                     & Byte (0)
                     & Byte (0)
                     & Byte (0));

               when Noncanonical_Length =>
                  Send_All
                    (Peer,
                     Byte (16#81#) & Byte (126) & Byte (0) & Byte (1) & "x");

               when Fragmented_Control  =>
                  Send_All (Peer, Byte (16#09#) & Byte (0));

               when Invalid_UTF8        =>
                  Send_Frame (Peer, 16#81#, Byte (16#C0#) & Byte (16#80#));

               when Stalled_Upgrade     =>
                  null;

               when Idle_Shutdown       =>
                  delay 0.9;

               when Half_Frame_Shutdown =>
                  Send_All (Peer, String'(1 => Byte (16#81#)));
                  delay 0.9;

               when Continuous_Shutdown =>
                  begin
                     for I in 1 .. 2_000 loop
                        Send_Frame (Peer, 16#89#, "x");
                        delay 0.001;
                     end loop;
                  exception
                     when GNAT.Sockets.Socket_Error =>
                        null;
                  end;
            end case;
            if Mode
               not in Idle_Shutdown | Half_Frame_Shutdown | Continuous_Shutdown
            then
               delay 0.2;
            end if;
         end if;
         Passed := True;
      exception
         when E : others =>
            Error :=
              US.To_Unbounded_String
                (Ada.Exceptions.Exception_Information (E));
      end;
      Close_Quietly (Peer);
      Close_Quietly (Listen);
      accept Finish
        (Success : out Boolean; Message : out US.Unbounded_String)
      do
         Success := Passed;
         Message := Error;
      end Finish;
   end Transport_Server;

   procedure Finish_Server (Server : in out Transport_Server) is
      Success : Boolean;
      Message : US.Unbounded_String;
   begin
      Server.Finish (Success, Message);
      Check (Success, "socket fixture failed: " & US.To_String (Message));
   end Finish_Server;

   procedure Run_Transport
     (Mode          : Transport_Scenario;
      Expected_Kind : Convex_WebSocket.Event_Kind;
      Expected_Data : String := "")
   is
      Listener    : GNAT.Sockets.Socket_Type;
      Port        : GNAT.Sockets.Port_Type;
      Server      : Transport_Server;
      Socket      : Convex_WebSocket.Connection;
      Item        : Convex_WebSocket.Event;
      Saw_Control : Boolean := False;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener, Mode);
      Convex_WebSocket.Open (Socket, URL (Port));

      if Mode in Partial_Header | Partial_Payload then
         Convex_WebSocket.Poll (Socket, 0.03, Item);
         Check
           (Item.Kind = Convex_WebSocket.No_Event,
            "partial frame should survive a bounded poll timeout");
      end if;

      for Attempt in 1 .. 8 loop
         Convex_WebSocket.Poll (Socket, 0.3, Item);
         if Item.Kind = Convex_WebSocket.Control_Traffic then
            Saw_Control := True;
         elsif Item.Kind /= Convex_WebSocket.No_Event then
            exit;
         end if;
      end loop;
      if Mode = Fragmented_UTF8 then
         Check
           (Saw_Control,
            "fragmented message did not surface interleaved ping traffic");
      end if;
      Check
        (Item.Kind = Expected_Kind,
         "unexpected transport event for "
         & Transport_Scenario'Image (Mode)
         & ": "
         & Convex_WebSocket.Event_Kind'Image (Item.Kind));
      if Expected_Data'Length > 0 then
         Check
           (US.To_String (Item.Data) = Expected_Data,
            "unexpected transport payload for "
            & Transport_Scenario'Image (Mode));
      end if;
      if Expected_Kind = Convex_WebSocket.Protocol_Failure then
         Check
           (not Convex_WebSocket.Is_Open (Socket),
            "protocol failure must retire the connection");
      end if;
      Convex_WebSocket.Shutdown (Socket);
      Finish_Server (Server);
   end Run_Transport;

   procedure Run_Bounded_Shutdown (Mode : Transport_Scenario) is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Transport_Server;
      Socket   : Convex_WebSocket.Connection;
      Item     : Convex_WebSocket.Event;
      Started  : Ada.Real_Time.Time;
      Elapsed  : Duration;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener, Mode);
      Convex_WebSocket.Open (Socket, URL (Port));
      if Mode = Half_Frame_Shutdown then
         Convex_WebSocket.Poll (Socket, 0.08, Item);
         Check
           (Item.Kind = Convex_WebSocket.No_Event,
            "half-frame setup unexpectedly produced an event");
      end if;
      Started := Ada.Real_Time.Clock;
      Convex_WebSocket.Shutdown (Socket);
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Check
        (Elapsed < 0.4,
         "shutdown exceeded 400 ms against "
         & Transport_Scenario'Image (Mode));
      Finish_Server (Server);
   end Run_Bounded_Shutdown;

   procedure Run_Stalled_Upgrade is
      Listener  : GNAT.Sockets.Socket_Type;
      Port      : GNAT.Sockets.Port_Type;
      Server    : Transport_Server;
      Socket    : Convex_WebSocket.Connection;
      Started   : Ada.Real_Time.Time;
      Elapsed   : Duration;
      Timed_Out : Boolean := False;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener, Stalled_Upgrade);
      Started := Ada.Real_Time.Clock;
      begin
         Convex_WebSocket.Open (Socket, URL (Port));
      exception
         when others =>
            Timed_Out := True;
      end;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Check (Timed_Out, "stalled WebSocket upgrade unexpectedly succeeded");
      Check (Elapsed < 2.5, "stalled WebSocket upgrade exceeded 2.5 seconds");
      Convex_WebSocket.Shutdown (Socket);
      Finish_Server (Server);
   end Run_Stalled_Upgrade;

   function Version (Query_Set : Natural; Timestamp : String) return String
   is ("{""querySet"":"
       & Image (Query_Set)
       & ",""identity"":0,""ts"":"""
       & Timestamp
       & """}");

   function Updated_Transition
     (Start_Query, End_Query : Natural;
      Start_TS, End_TS       : String;
      Value                  : Natural) return String
   is ("{""type"":""Transition"",""startVersion"":"
       & Version (Start_Query, Start_TS)
       & ",""endVersion"":"
       & Version (End_Query, End_TS)
       & ",""modifications"":[{""type"":""QueryUpdated"",""queryId"":1,"
       & """value"":"
       & Image (Value)
       & ",""logLines"":[""fixture""]}]}");

   function Failed_Transition return String
   is ("{""type"":""Transition"",""startVersion"":"
       & Version (1, One_TS)
       & ",""endVersion"":"
       & Version (1, Two_TS)
       & ",""modifications"":[{""type"":""QueryFailed"",""queryId"":1,"
       & """errorMessage"":""fixture failed"",""errorData"":{""code"":7},"
       & """logLines"":[""boom""]}]}");

   function Large_Transition
     (Start_TS, End_TS : String; Fill : Character) return String
   is
      Large_Value_Bytes : constant := 900_000;
      Chunk             : constant String (1 .. 4_096) := [others => Fill];
      Remaining         : Natural := Large_Value_Bytes;
      Result            : US.Unbounded_String :=
        US.To_Unbounded_String
          ("{""type"":""Transition"",""startVersion"":"
           & Version (1, Start_TS)
           & ",""endVersion"":"
           & Version (1, End_TS)
           & ",""modifications"":[{""type"":""QueryUpdated"",""queryId"":1,"
           & """value"":""");
   begin
      while Remaining > 0 loop
         declare
            Count : constant Natural := Natural'Min (Remaining, Chunk'Length);
         begin
            US.Append (Result, Chunk (1 .. Count));
            Remaining := Remaining - Count;
         end;
      end loop;
      US.Append (Result, """,""logLines"":[]}]}");
      return US.To_String (Result);
   end Large_Transition;

   function Read_Object (Text : String) return JSON.JSON_Value is
      Result : constant JSON.Read_Result := JSON.Read (Text);
   begin
      Check
        (Result.Success and then Result.Value.Kind = JSON.JSON_Object_Type,
         "fixture received invalid client JSON: " & Text);
      return Result.Value;
   end Read_Object;

   function Integer_Field
     (Object : JSON.JSON_Value; Name : String) return Integer
   is
      Value : constant JSON.JSON_Value := Object.Get (Name);
   begin
      Check
        (Value.Kind = JSON.JSON_Int_Type, "expected integer field " & Name);
      return Value.Get;
   end Integer_Field;

   function String_Field
     (Object : JSON.JSON_Value; Name : String) return String
   is
      Value : constant JSON.JSON_Value := Object.Get (Name);
   begin
      Check
        (Value.Kind = JSON.JSON_String_Type, "expected string field " & Name);
      return Value.Get;
   end String_Field;

   procedure Validate_Add (Text : String) is
      Root : constant JSON.JSON_Value := Read_Object (Text);
      Mods : constant JSON.JSON_Array := Root.Get ("modifications");
      Item : JSON.JSON_Value;
   begin
      Check
        (String_Field (Root, "type") = "ModifyQuerySet",
         "fixture expected ModifyQuerySet");
      Check (JSON.Length (Mods) = 1, "fixture expected one query-set change");
      Item := JSON.Get (Mods, 1);
      Check (String_Field (Item, "type") = "Add", "fixture expected Add");
      Check
        (Integer_Field (Item, "queryId") = 1, "fixture expected query id 1");
      Check
        (String_Field (Item, "udfPath") = "messages:count",
         "fixture received the wrong query path");
   end Validate_Add;

   procedure Validate_Remove (Text : String) is
      Root : constant JSON.JSON_Value := Read_Object (Text);
      Mods : constant JSON.JSON_Array := Root.Get ("modifications");
      Item : constant JSON.JSON_Value := JSON.Get (Mods, 1);
   begin
      Check
        (String_Field (Root, "type") = "ModifyQuerySet",
         "fixture expected ModifyQuerySet remove");
      Check (JSON.Length (Mods) = 1, "fixture expected one remove");
      Check
        (String_Field (Item, "type") = "Remove", "fixture expected Remove");
      Check
        (Integer_Field (Item, "queryId") = 1, "fixture removed wrong query");
   end Validate_Remove;

   task type Live_Flow_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Live_Flow_Server;

   task body Live_Flow_Server is
      Listen : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed : Boolean := False;
      Error  : US.Unbounded_String;
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         Upgrade (Listen, Peer);
         Check
           (String_Field (Read_Object (Read_Client_Text (Peer)), "type")
            = "Connect",
            "Live fixture expected Connect first");
         Validate_Add (Read_Client_Text (Peer));
         Send_Frame
           (Peer, 16#81#, Updated_Transition (0, 1, Initial_TS, One_TS, 0));
         delay 0.05;
         Send_Frame (Peer, 16#81#, Failed_Transition);
         delay 0.05;
         Send_Frame
           (Peer, 16#81#, Updated_Transition (1, 1, Two_TS, Two_TS, 1));
         Validate_Remove (Read_Client_Text (Peer));
         Passed := True;
      exception
         when E : others =>
            Error :=
              US.To_Unbounded_String
                (Ada.Exceptions.Exception_Information (E));
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "live fixture failed: " & US.To_String (Error));
      end;
      Close_Quietly (Peer);
      Close_Quietly (Listen);
      accept Finish
        (Success : out Boolean; Message : out US.Unbounded_String)
      do
         Success := Passed;
         Message := Error;
      end Finish;
   end Live_Flow_Server;

   protected Reconnect_Status is
      procedure Connected;
      procedure Failed (Message : String);
      function Count return Natural;
      function Is_Valid return Boolean;
      function Error return US.Unbounded_String;
   private
      Connections : Natural := 0;
      Valid       : Boolean := True;
      Failure     : US.Unbounded_String;
   end Reconnect_Status;

   protected body Reconnect_Status is
      procedure Connected is
      begin
         Connections := Connections + 1;
      end Connected;

      procedure Failed (Message : String) is
      begin
         Valid := False;
         Failure := US.To_Unbounded_String (Message);
      end Failed;

      function Count return Natural
      is (Connections);
      function Is_Valid return Boolean
      is (Valid);
      function Error return US.Unbounded_String
      is (Failure);
   end Reconnect_Status;

   task type Reconnect_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Reconnect_Server;

   task body Reconnect_Server is
      Listen : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed : Boolean := False;
      Error  : US.Unbounded_String;
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         for Attempt in 1 .. 6 loop
            Upgrade (Listen, Peer);
            declare
               Connect : constant JSON.JSON_Value :=
                 Read_Object (Read_Client_Text (Peer));
            begin
               Check
                 (String_Field (Connect, "type") = "Connect",
                  "reconnect fixture expected Connect");
               Check
                 (Integer_Field (Connect, "connectionCount") = Attempt - 1,
                  "connectionCount did not advance on reconnect");
               Check
                 (String_Field (Connect, "lastCloseReason")
                  = (if Attempt = 1
                     then "InitialConnect"
                     else "adapter debug disconnect"),
                  "lastCloseReason did not describe the retired connection");
               if Attempt = 1 then
                  Check
                    (not Connect.Has_Field ("maxObservedTimestamp"),
                     "first Connect unexpectedly carried a timestamp");
               else
                  Check
                    (String_Field (Connect, "maxObservedTimestamp") = One_TS,
                     "reconnect did not carry the maximum observed timestamp");
               end if;
            end;
            Validate_Add (Read_Client_Text (Peer));
            Send_Frame
              (Peer,
               16#81#,
               Updated_Transition
                 (0,
                  1,
                  Initial_TS,
                  (if Attempt = 6 then Two_TS else One_TS),
                  (if Attempt = 6 then 1 else 0)));
            Reconnect_Status.Connected;
            Wait_For_Close (Peer);
            Close_Quietly (Peer);
         end loop;
         Passed := Reconnect_Status.Is_Valid;
      exception
         when E : others =>
            Error :=
              US.To_Unbounded_String
                (Ada.Exceptions.Exception_Information (E));
            Reconnect_Status.Failed (US.To_String (Error));
      end;
      Close_Quietly (Peer);
      Close_Quietly (Listen);
      accept Finish
        (Success : out Boolean; Message : out US.Unbounded_String)
      do
         Success := Passed;
         Message :=
           (if US.Length (Error) > 0 then Error else Reconnect_Status.Error);
      end Finish;
   end Reconnect_Server;

   task type Backpressure_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Count_Ready;
      entry Continue;
      entry First_Ready;
      entry Continue_Bytes;
      entry Bytes_Ready;
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Backpressure_Server;

   task body Backpressure_Server is
      Listen : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed : Boolean := False;
      Error  : US.Unbounded_String;
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         Upgrade (Listen, Peer);
         Check
           (String_Field (Read_Object (Read_Client_Text (Peer)), "type")
            = "Connect",
            "backpressure fixture expected Connect first");
         Validate_Add (Read_Client_Text (Peer));

         for Value in 1 .. 20 loop
            Send_Frame
              (Peer,
               16#81#,
               Updated_Transition
                 ((if Value = 1 then 0 else 1),
                  1,
                  (if Value = 1
                   then Initial_TS
                   else
                     Convex_WebSocket.Encode_Timestamp
                       (Interfaces.Unsigned_64 (Value - 1))),
                  Convex_WebSocket.Encode_Timestamp
                    (Interfaces.Unsigned_64 (Value)),
                  Value));
         end loop;
         Send_Frame (Peer, 16#89#, "count barrier");
         Check
           (Read_Client_Opcode (Peer) = 10,
            "backpressure fixture did not receive count-barrier Pong");
         accept Count_Ready;
         accept Continue;

         declare
            Message : constant String :=
              Large_Transition
                (Convex_WebSocket.Encode_Timestamp (20),
                 Convex_WebSocket.Encode_Timestamp (21),
                 'A');
         begin
            Send_Frame (Peer, 16#81#, Message);
         end;
         Send_Frame (Peer, 16#89#, "first byte barrier");
         Check
           (Read_Client_Opcode (Peer) = 10,
            "backpressure fixture did not receive first-byte Pong");
         accept First_Ready;
         accept Continue_Bytes;

         for Index in 1 .. 5 loop
            declare
               Message : constant String :=
                 Large_Transition
                   (Convex_WebSocket.Encode_Timestamp
                      (Interfaces.Unsigned_64 (20 + Index)),
                    Convex_WebSocket.Encode_Timestamp
                      (Interfaces.Unsigned_64 (21 + Index)),
                    Character'Val (Character'Pos ('A') + Index));
            begin
               Send_Frame (Peer, 16#81#, Message);
            end;
         end loop;
         Send_Frame (Peer, 16#89#, "byte barrier");
         Check
           (Read_Client_Opcode (Peer) = 10,
            "backpressure fixture did not receive byte-barrier Pong");
         accept Bytes_Ready;
         Wait_For_Close (Peer);
         Passed := True;
      exception
         when E : others =>
            Error :=
              US.To_Unbounded_String
                (Ada.Exceptions.Exception_Information (E));
      end;
      Close_Quietly (Peer);
      Close_Quietly (Listen);
      accept Finish
        (Success : out Boolean; Message : out US.Unbounded_String)
      do
         Success := Passed;
         Message := Error;
      end Finish;
   end Backpressure_Server;

   procedure Wait_Update
     (Manager : in out Convex.Live.Manager;
      Sub     : Convex.Live.Subscription;
      Item    : out Convex.Live.Update;
      Timeout : Duration := 2.0)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout);
      Found    : Boolean := False;
   begin
      while Ada.Real_Time.Clock < Deadline loop
         Convex.Live.Try_Next (Manager, Sub, Found, Item);
         exit when Found;
         delay 0.005;
      end loop;
      Check (Found, "timed out waiting for a Live update");
   end Wait_Update;

   procedure Check_Integer_Update
     (Item : Convex.Live.Update; Expected : Long_Long_Integer)
   is
      Actual : Long_Long_Integer;
   begin
      Check
        (Item.Has_Value and then not Item.Has_Error,
         "expected a successful Live value");
      Check
        (Item.Value.Kind = JSON.JSON_Int_Type,
         "expected an integer Live value");
      Actual := Item.Value.Get;
      Check (Actual = Expected, "unexpected Live value");
   end Check_Integer_Update;

   procedure Run_Live_Flow is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Live_Flow_Server;
      Manager  : Convex.Live.Manager;
      Sub      : Convex.Live.Subscription;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Item     : Convex.Live.Update;
      Success  : Boolean;
      Message  : US.Unbounded_String;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Live.Open (Manager, URL (Port));
      Convex.Live.Subscribe
        (Manager, "messages:count", Args, Sub, Success, Message);
      Check (Success, "Live subscribe failed: " & US.To_String (Message));

      Wait_Update (Manager, Sub, Item);
      Check_Integer_Update (Item, 0);
      Check (JSON.Length (Item.Logs) = 1, "QueryUpdated logs were lost");
      Convex.Live.Release (Manager, Item);

      Wait_Update (Manager, Sub, Item);
      Check
        (Item.Has_Error and then not Item.Has_Value,
         "QueryFailed was not published as an error");
      Check
        (Item.Error.Kind = Convex.Function_Error,
         "QueryFailed used the wrong structured error kind");
      Check
        (US.To_String (Item.Error.Message) = "fixture failed",
         "QueryFailed message was lost");
      Check (Item.Error.Has_Data, "QueryFailed errorData was lost");
      Check (JSON.Length (Item.Logs) = 1, "QueryFailed logs were lost");
      Convex.Live.Release (Manager, Item);

      Wait_Update (Manager, Sub, Item);
      Check_Integer_Update (Item, 1);
      Convex.Live.Release (Manager, Item);

      Convex.Live.Unsubscribe (Manager, Sub);
      Convex.Live.Close (Manager);
      Server.Finish (Success, Message);
      Check (Success, "Live flow fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Live.Close (Manager);
         abort Server;
         raise;
   end Run_Live_Flow;

   procedure Run_Backpressure is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Backpressure_Server;
      Manager  : Convex.Live.Manager;
      Sub      : Convex.Live.Subscription;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Item     : Convex.Live.Update;
      Success  : Boolean;
      Message  : US.Unbounded_String;
      Found    : Boolean;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Live.Open (Manager, URL (Port));
      Convex.Live.Subscribe
        (Manager, "messages:count", Args, Sub, Success, Message);
      Check
        (Success, "backpressure subscribe failed: " & US.To_String (Message));

      -- The fixture waits for a Pong sent after all 20 transitions. At that
      -- point the owner has parsed every earlier frame, so inspecting the
      -- queue does not depend on a scheduling delay.
      Server.Count_Ready;
      for Expected in 5 .. 20 loop
         Wait_Update (Manager, Sub, Item);
         Check_Integer_Update (Item, Long_Long_Integer (Expected));
         Convex.Live.Release (Manager, Item);
      end loop;
      Convex.Live.Try_Next (Manager, Sub, Found, Item);
      Check
        (not Found, "event-count backpressure retained more than 16 updates");

      Server.Continue;
      Server.First_Ready;
      Wait_Update (Manager, Sub, Item, Timeout => 4.0);
      Check
        (Item.Has_Value and then Item.Value.Kind = JSON.JSON_String_Type,
         "byte backpressure did not dequeue the first large value");
      declare
         Text : constant String := Item.Value.Get;
      begin
         Check
           (Text'Length = 900_000
            and then Text (Text'First) = 'A'
            and then Text (Text'Last) = 'A',
            "byte backpressure dequeued the wrong first large value");
      end;

      -- Keep A charged in-flight while B through F arrive. With the 20 MiB
      -- budget, B must be evicted even though only four queued values remain.
      Server.Continue_Bytes;
      Server.Bytes_Ready;
      Convex.Live.Release (Manager, Item);
      for Expected in Character range 'C' .. 'F' loop
         Wait_Update (Manager, Sub, Item, Timeout => 4.0);
         Check
           (Item.Has_Value and then Item.Value.Kind = JSON.JSON_String_Type,
            "byte backpressure did not retain a large value");
         declare
            Text : constant String := Item.Value.Get;
         begin
            Check
              (Text'Length = 900_000,
               "byte backpressure changed the large value length");
            Check
              (Text (Text'First) = Expected
               and then Text (Text'Last) = Expected,
               "byte backpressure did not retain the newest five values");
         end;
         Convex.Live.Release (Manager, Item);
      end loop;
      Convex.Live.Try_Next (Manager, Sub, Found, Item);
      Check
        (not Found,
         "byte backpressure failed to include the in-flight update charge");

      Convex.Live.Unsubscribe (Manager, Sub);
      Convex.Live.Close (Manager);
      Server.Finish (Success, Message);
      Check
        (Success, "backpressure fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Live.Close (Manager);
         abort Server;
         raise;
   end Run_Backpressure;

   task type Live_Shutdown_Server is
      entry Start
        (Listener : GNAT.Sockets.Socket_Type; Scenario : Transport_Scenario);
      entry Ready;
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Live_Shutdown_Server;

   task body Live_Shutdown_Server is
      Listen : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Mode   : Transport_Scenario := Idle_Shutdown;
      Passed : Boolean := False;
      Error  : US.Unbounded_String;
   begin
      accept Start
        (Listener : GNAT.Sockets.Socket_Type; Scenario : Transport_Scenario)
      do
         Listen := Listener;
         Mode := Scenario;
      end Start;
      begin
         Upgrade (Listen, Peer);
         Check
           (String_Field (Read_Object (Read_Client_Text (Peer)), "type")
            = "Connect",
            "shutdown fixture expected Connect first");
         Validate_Add (Read_Client_Text (Peer));
         if Mode = Half_Frame_Shutdown then
            Send_All (Peer, String'(1 => Byte (16#81#)));
         end if;
         accept Ready;
         case Mode is
            when Idle_Shutdown | Half_Frame_Shutdown =>
               Wait_For_Close (Peer);

            when Continuous_Shutdown                 =>
               begin
                  for I in 1 .. 2_000 loop
                     Send_Frame (Peer, 16#89#, "x");
                     delay 0.001;
                  end loop;
               exception
                  when GNAT.Sockets.Socket_Error =>
                     null;
               end;

            when others                              =>
               raise Program_Error with "invalid Live shutdown fixture mode";
         end case;
         Passed := True;
      exception
         when E : others =>
            Error :=
              US.To_Unbounded_String
                (Ada.Exceptions.Exception_Information (E));
      end;
      Close_Quietly (Peer);
      Close_Quietly (Listen);
      accept Finish
        (Success : out Boolean; Message : out US.Unbounded_String)
      do
         Success := Passed;
         Message := Error;
      end Finish;
   end Live_Shutdown_Server;

   procedure Run_Live_Bounded_Lifecycle
     (Mode : Transport_Scenario; Remove_First : Boolean)
   is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Live_Shutdown_Server;
      Manager  : Convex.Live.Manager;
      Sub      : Convex.Live.Subscription;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Success  : Boolean;
      Message  : US.Unbounded_String;
      Started  : Ada.Real_Time.Time;
      Elapsed  : Duration;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener, Mode);
      Convex.Live.Open (Manager, URL (Port));
      Convex.Live.Subscribe
        (Manager, "messages:count", Args, Sub, Success, Message);
      Check (Success, "lifecycle subscribe failed: " & US.To_String (Message));
      Server.Ready;
      delay 0.05;

      if Remove_First then
         Started := Ada.Real_Time.Clock;
         Convex.Live.Unsubscribe (Manager, Sub);
         Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
         Check
           (Elapsed < 0.4,
            "Live unsubscribe exceeded 400 ms against "
            & Transport_Scenario'Image (Mode));
      end if;

      Started := Ada.Real_Time.Clock;
      Convex.Live.Close (Manager);
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Check
        (Elapsed < 0.4,
         "Live close exceeded 400 ms against "
         & Transport_Scenario'Image (Mode));
      Server.Finish (Success, Message);
      Check
        (Success, "Live lifecycle fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Live.Close (Manager);
         abort Server;
         raise;
   end Run_Live_Bounded_Lifecycle;

   procedure Wait_Connections (Expected : Natural) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (3.0);
   begin
      while Reconnect_Status.Count < Expected
        and then Reconnect_Status.Is_Valid
        and then Ada.Real_Time.Clock < Deadline
      loop
         delay 0.005;
      end loop;
      Check
        (Reconnect_Status.Is_Valid,
         "reconnect fixture failed: " & US.To_String (Reconnect_Status.Error));
      Check
        (Reconnect_Status.Count >= Expected,
         "timed out waiting for reconnect " & Image (Expected));
   end Wait_Connections;

   procedure Run_Reconnects is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Reconnect_Server;
      Manager  : Convex.Live.Manager;
      Sub      : Convex.Live.Subscription;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Item     : Convex.Live.Update;
      Success  : Boolean;
      Message  : US.Unbounded_String;
      Found    : Boolean;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Live.Open (Manager, URL (Port));
      Convex.Live.Subscribe
        (Manager, "messages:count", Args, Sub, Success, Message);
      Check (Success, "reconnect subscribe failed: " & US.To_String (Message));
      Wait_Connections (1);
      Wait_Update (Manager, Sub, Item);
      Check_Integer_Update (Item, 0);
      Convex.Live.Release (Manager, Item);

      for Expected in 2 .. 6 loop
         Convex.Live.Testing.Debug_Disconnect (Manager, Success, Message);
         Check (Success, "debugDisconnect failed: " & US.To_String (Message));
         Wait_Connections (Expected);
         if Expected < 6 then
            delay 0.05;
            Convex.Live.Try_Next (Manager, Sub, Found, Item);
            Check
              (not Found, "unchanged reconnect hydration was not suppressed");
         end if;
      end loop;

      Wait_Update (Manager, Sub, Item);
      Check_Integer_Update (Item, 1);
      Convex.Live.Release (Manager, Item);
      Convex.Live.Unsubscribe (Manager, Sub);
      Convex.Live.Close (Manager);
      Server.Finish (Success, Message);
      Check (Success, "reconnect fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Live.Close (Manager);
         abort Server;
         raise;
   end Run_Reconnects;

begin
   Ada.Text_IO.Put_Line
     ("socket: fragmentation, malformed frames, and recovery");
   Run_Transport
     (Fragmented_UTF8,
      Convex_WebSocket.Text_Message,
      "snow " & Byte (16#E2#) & Byte (16#98#) & Byte (16#83#));
   Run_Transport (Partial_Header, Convex_WebSocket.Text_Message, "hello");
   Run_Transport (Partial_Payload, Convex_WebSocket.Text_Message, "hello");
   Run_Transport (Masked_Server_Frame, Convex_WebSocket.Protocol_Failure);
   Run_Transport (Noncanonical_Length, Convex_WebSocket.Protocol_Failure);
   Run_Transport (Fragmented_Control, Convex_WebSocket.Protocol_Failure);
   Run_Transport (Invalid_UTF8, Convex_WebSocket.Protocol_Failure);

   -- A fresh valid socket after malformed traffic proves parser failure does
   -- not poison later connections.
   Run_Transport (Valid_Text, Convex_WebSocket.Text_Message, "recovered");

   Ada.Text_IO.Put_Line ("socket: bounded shutdown and upgrade timeout");
   Run_Bounded_Shutdown (Idle_Shutdown);
   Run_Bounded_Shutdown (Half_Frame_Shutdown);
   Run_Bounded_Shutdown (Continuous_Shutdown);
   Run_Stalled_Upgrade;

   Ada.Text_IO.Put_Line ("http: envelopes, auth lifecycle, logs, and errors");
   Run_HTTP;

   Ada.Text_IO.Put_Line ("live: recovery, reconnects, and bounded lifecycle");
   Run_Live_Flow;
   Ada.Text_IO.Put_Line ("live: five reconnects");
   Run_Reconnects;
   Ada.Text_IO.Put_Line ("live: count and byte backpressure");
   Run_Backpressure;
   Ada.Text_IO.Put_Line ("live: unsubscribe and close deadlines");
   for Mode in Idle_Shutdown .. Continuous_Shutdown loop
      Run_Live_Bounded_Lifecycle (Mode, Remove_First => True);
      Run_Live_Bounded_Lifecycle (Mode, Remove_First => False);
   end loop;

   Ada.Text_IO.Put_Line ("Ada real-socket tests passed");
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "Ada real-socket tests failed: "
         & Ada.Exceptions.Exception_Information (E));
      raise;
end Convex_Socket_Tests;
