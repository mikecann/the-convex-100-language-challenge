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

   function Read_Client_Text_Length
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
         Length : Natural := Natural (B2 and 16#7F#);
      begin
         Check
           ((B1 and 16#80#) /= 0 and then (B1 and 16#0F#) = 1,
            "slow-reader fixture expected a final client text frame");
         Check
           ((B2 and 16#80#) /= 0,
            "slow-reader fixture expected a masked client frame");
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
                  "slow-reader client frame exceeds the test range");
               Length := 0;
               for I in 5 .. 8 loop
                  Length := Length * 256 + Character'Pos (Extended (I));
               end loop;
            end;
         end if;
         declare
            Mask : String (1 .. 4);
         begin
            Read_Exactly (Socket, Mask);
         end;
         return Length;
      end;
   end Read_Client_Text_Length;

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

   function Hex_Image (Value : Natural) return String is
      Hex_Characters : constant String := "0123456789ABCDEF";
   begin
      if Value < 16 then
         return String'[1 => Hex_Characters (Value + 1)];
      end if;
      return Hex_Image (Value / 16) & Hex_Characters (Value mod 16 + 1);
   end Hex_Image;

   procedure Send_Chunked_HTTP_Response
     (Socket : GNAT.Sockets.Socket_Type; Response_Body : String)
   is
      First_Length : constant Natural :=
        Natural'Min (17, Response_Body'Length);
      First_Last   : constant Natural :=
        Response_Body'First + First_Length - 1;
      Rest_Length  : constant Natural := Response_Body'Length - First_Length;
   begin
      Send_All
        (Socket,
         "HTTP/1.1 200 OK"
         & ASCII.CR
         & ASCII.LF
         & "Content-Type: application/json"
         & ASCII.CR
         & ASCII.LF
         & "Transfer-Encoding: chunked"
         & ASCII.CR
         & ASCII.LF
         & ASCII.CR
         & ASCII.LF
         & Hex_Image (First_Length)
         & ";fixture=yes"
         & ASCII.CR
         & ASCII.LF
         & Response_Body (Response_Body'First .. First_Last)
         & ASCII.CR
         & ASCII.LF
         & (if Rest_Length > 0
            then
              Hex_Image (Rest_Length)
              & ASCII.CR
              & ASCII.LF
              & Response_Body (First_Last + 1 .. Response_Body'Last)
              & ASCII.CR
              & ASCII.LF
            else "")
         & "0"
         & ASCII.CR
         & ASCII.LF
         & "X-Fixture: complete"
         & ASCII.CR
         & ASCII.LF
         & ASCII.CR
         & ASCII.LF);
   end Send_Chunked_HTTP_Response;

   --  A client that rejects a response during header parsing closes before the
   --  fixture has finished writing. That is the behaviour under test, not a
   --  fixture failure.
   procedure Send_Response_Quietly
     (Socket : GNAT.Sockets.Socket_Type; Text : String) is
   begin
      Send_All (Socket, Text);
   exception
      when GNAT.Sockets.Socket_Error =>
         null;
   end Send_Response_Quietly;

   function Sized_Response (Status, Response_Body : String) return String
   is ("HTTP/1.1 "
       & Status
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
         for Step in 1 .. 6 loop
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
                     Send_Chunked_HTTP_Response
                       (Peer, "{""status"":""success"",""value"":7}");

                  when 5 =>
                     Validate_HTTP_Envelope
                       (Request, "query", "messages:badChunk", "");
                     Send_All
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Transfer-Encoding: chunked"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & "not-hex"
                        & ASCII.CR
                        & ASCII.LF
                        & "x"
                        & ASCII.CR
                        & ASCII.LF
                        & "0"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF);

                  when 6 =>
                     Validate_HTTP_Envelope
                       (Request, "query", "messages:count", "");
                     Send_Chunked_HTTP_Response
                       (Peer, "{""status"":""success"",""value"":8}");
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

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:badChunk", Args);
      begin
         Check (not Result.Success, "malformed HTTP chunk became a success");
         Check
           (Result.Error.Kind = Convex.Protocol_Error,
            "malformed HTTP chunk used the wrong error kind");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:count", Args);
      begin
         Check
           (Result.Success, "HTTP did not recover after a malformed chunk");
         Check
           (Result.Value.Kind = JSON.JSON_Int_Type
            and then Long_Long_Integer'(Result.Value.Get) = 8,
            "chunked HTTP recovery returned the wrong value");
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

   task type HTTP_Edge_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end HTTP_Edge_Server;

   task type HTTP_Write_Deadline_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end HTTP_Write_Deadline_Server;

   task body HTTP_Write_Deadline_Server is
      Listen  : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer    : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed  : Boolean := False;
      Error   : US.Unbounded_String;
      Address : GNAT.Sockets.Sock_Addr_Type;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 16 * 1024);
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         --  Keep the advertised window small before accept so a near-maximum
         --  request cannot disappear into kernel buffering. One chunk is
         --  drained just inside the former five-second per-send timeout.
         GNAT.Sockets.Set_Socket_Option
           (Listen,
            GNAT.Sockets.Socket_Level,
            (Name => GNAT.Sockets.Receive_Buffer, Size => 16 * 1024));
         GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
         delay 4.7;
         GNAT.Sockets.Receive_Socket (Peer, Data, Last);
         Check
           (Last >= Data'First,
            "HTTP request writer closed before the delayed drain");
         --  The old implementation renewed another five seconds here. Keep
         --  the peer open past the one operation deadline so the elapsed-time
         --  assertion distinguishes that behavior from an absolute deadline.
         delay 1.2;
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
   end HTTP_Write_Deadline_Server;

   task body HTTP_Edge_Server is
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
               pragma Unreferenced (Request);
            begin
               case Step is
                  when 1 .. 3 =>
                     Send_All
                       (Peer,
                        (case Step is
                           when 1      => "HTTP/1.1 2000 OK",
                           when 2      => "HTTP/1.1 20 OK",
                           when 3      => "HTTP/1.1 2A0 OK",
                           when others => raise Program_Error)
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 0"
                        & ASCII.CR
                        & ASCII.LF
                        & "Connection: close"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF);

                  when 4      =>
                     declare
                        Response_Text : constant String :=
                          "{""status"":""success"",""value"":9}";
                        Part          : constant Natural :=
                          Response_Text'Length / 6;
                        First         : Natural := Response_Text'First;
                     begin
                        Send_All
                          (Peer,
                           "HTTP/1.1 200 OK"
                           & ASCII.CR
                           & ASCII.LF
                           & "Content-Length: "
                           & Image (Response_Text'Length)
                           & ASCII.CR
                           & ASCII.LF
                           & "Connection: close"
                           & ASCII.CR
                           & ASCII.LF
                           & ASCII.CR
                           & ASCII.LF);
                        --  Every partial read arrives well inside five seconds,
                        --  but the full response exceeds one five-second
                        --  operation deadline. An inactivity timeout would
                        --  incorrectly permit this response forever.
                        begin
                           for Piece in 1 .. 6 loop
                              declare
                                 Last : constant Natural :=
                                   (if Piece = 6
                                    then Response_Text'Last
                                    else First + Part - 1);
                              begin
                                 Send_All
                                   (Peer, Response_Text (First .. Last));
                                 First := Last + 1;
                                 if Piece < 6 then
                                    delay 1.1;
                                 end if;
                              end;
                           end loop;
                        exception
                           when GNAT.Sockets.Socket_Error =>
                              null;
                        end;
                     end;
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
   end HTTP_Edge_Server;

   procedure Run_HTTP_Edges is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : HTTP_Edge_Server;
      Client   : Convex.Client;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Success  : Boolean;
      Message  : US.Unbounded_String;
      Started  : Ada.Real_Time.Time;
      Elapsed  : Duration;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Open (Client, URL (Port));
      for Attempt in 1 .. 3 loop
         declare
            Result : constant Convex.Call_Result :=
              Convex.Query (Client, "messages:status", Args);
         begin
            Check
              (not Result.Success
               and then Result.Error.Kind = Convex.Protocol_Error,
               "malformed HTTP status syntax was accepted");
         end;
      end loop;
      Started := Ada.Real_Time.Clock;
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:slow", Args);
      begin
         Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Transport_Error,
            "slow-drip HTTP response did not hit the absolute deadline");
         Check
           (Elapsed >= 4.5 and then Elapsed < 5.8,
            "HTTP response deadline was not one five-second operation budget");
      end;
      Convex.Close (Client);
      Server.Finish (Success, Message);
      Check (Success, "HTTP edge fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Close (Client);
         abort Server;
         raise;
   end Run_HTTP_Edges;

   procedure Run_HTTP_Write_Deadline is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : HTTP_Write_Deadline_Server;
      Client   : Convex.Client;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Success  : Boolean;
      Message  : US.Unbounded_String;
      Started  : Ada.Real_Time.Time;
      Elapsed  : Duration;
   begin
      Args.Set_Field ("payload", String'(1 .. 1_900_000 => 'h'));
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Open (Client, URL (Port));
      Started := Ada.Real_Time.Clock;
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:largeRequest", Args);
      begin
         Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Transport_Error,
            "slow-reading HTTP peer did not stop request transmission");
         Check
           (Elapsed >= 4.5 and then Elapsed < 5.6,
            "HTTP request chunks did not share one five-second deadline");
      end;
      Convex.Close (Client);
      Server.Finish (Success, Message);
      Check
        (Success,
         "HTTP write-deadline fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Close (Client);
         abort Server;
         raise;
   end Run_HTTP_Write_Deadline;

   --  Convex answers some function failures with a non-2xx status such as 560
   --  and a perfectly ordinary error envelope. The status line alone must not
   --  decide the taxonomy, and a non-2xx body still has to be framed, bounded,
   --  read, and parsed like any other.
   task type HTTP_Envelope_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end HTTP_Envelope_Server;

   task body HTTP_Envelope_Server is
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
         for Step in 1 .. 10 loop
            GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
            declare
               Request : constant String := Read_HTTP_Request (Peer);
               pragma Unreferenced (Request);
            begin
               case Step is
                  when 1 =>
                     Send_Response_Quietly
                       (Peer,
                        Sized_Response
                          ("560 Convex Error",
                           "{""status"":""error"","
                           & """errorMessage"":""function threw"","
                           & """errorData"":{""code"":3},"
                           & """logLines"":[""e1""]}"));

                  when 2 =>
                     Send_Response_Quietly
                       (Peer,
                        Sized_Response
                          ("560 Convex Error",
                           "{""status"":""success"",""value"":1}"));

                  when 3 =>
                     Send_Response_Quietly
                       (Peer,
                        Sized_Response
                          ("500 Internal Server Error",
                           "<html>gateway said no</html>"));

                  when 4 =>
                     Send_Response_Quietly
                       (Peer,
                        Sized_Response ("404 Not Found", "{""nope"":1}"));

                  when 5 =>
                     --  A non-2xx body still has to survive chunked framing.
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 560 Convex Error"
                        & ASCII.CR
                        & ASCII.LF
                        & "Transfer-Encoding: chunked"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & "19"
                        & ASCII.CR
                        & ASCII.LF
                        & "{""status"":""error"",""errorM"
                        & ASCII.CR
                        & ASCII.LF
                        & "12"
                        & ASCII.CR
                        & ASCII.LF
                        & "essage"":""chunked""}"
                        & ASCII.CR
                        & ASCII.LF
                        & "0"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF);

                  when 6 =>
                     Send_Response_Quietly
                       (Peer, Sized_Response ("560 Convex Error", ""));

                  when 7 =>
                     --  A 2xx status is not evidence that the body is a
                     --  Convex envelope. An intact response this client
                     --  cannot honour is a protocol failure whatever the
                     --  status line said.
                     Send_Response_Quietly
                       (Peer,
                        Sized_Response ("200 OK", "<html>not convex</html>"));

                  when 8 =>
                     Send_Response_Quietly
                       (Peer, Sized_Response ("200 OK", "[1,2]"));

                  when 9 =>
                     Send_Response_Quietly
                       (Peer, Sized_Response ("200 OK", "{""value"":1}"));

                  when 10 =>
                     Send_Response_Quietly
                       (Peer,
                        Sized_Response
                          ("200 OK",
                           "{""status"":""success"",""value"":42}"));
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
   end HTTP_Envelope_Server;

   procedure Run_HTTP_Envelopes is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : HTTP_Envelope_Server;
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
           Convex.Query (Client, "messages:throws", Args);
      begin
         Check
           (not Result.Success, "HTTP 560 error envelope became a success");
         Check
           (Result.Error.Kind = Convex.Function_Error,
            "HTTP 560 error envelope was not a function error");
         Check
           (US.To_String (Result.Error.Message) = "function threw",
            "HTTP 560 error envelope lost its message");
         Check (Result.Error.Has_Data, "HTTP 560 errorData was lost");
         Check
           (Result.Error.Has_Logs
            and then JSON.Length (Result.Error.Logs) = 1,
            "HTTP 560 logLines were lost");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:mislabeled", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Protocol_Error,
            "a success envelope under HTTP 560 was not a protocol error");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:gateway", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Protocol_Error,
            "a non-JSON non-2xx body was not a protocol error");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:missing", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Protocol_Error,
            "a non-2xx object without status was not a protocol error");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:chunkedError", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Function_Error
            and then US.To_String (Result.Error.Message) = "chunked",
            "a chunked non-2xx error envelope was not read and parsed");
         Check
           (not Result.Error.Has_Logs,
            "an envelope without logLines gained logs");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:emptyError", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Protocol_Error,
            "an empty non-2xx body was not a protocol error");
      end;

      --  The same taxonomy under a 2xx status. A body that never parses, a
      --  body whose root is not an object, and an object without status are
      --  all responses this client understood the transport for and could not
      --  interpret, so all three are protocol errors rather than transport
      --  errors.
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:html", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Protocol_Error,
            "an unparseable 2xx body was not a protocol error");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:array", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Protocol_Error,
            "a non-object 2xx body was not a protocol error");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:statusless", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Protocol_Error,
            "a 2xx object without status was not a protocol error");
      end;

      --  Transport taxonomy and recovery: none of the above may poison the
      --  next ordinary call on the same client.
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:count", Args);
      begin
         Check (Result.Success, "HTTP did not recover after non-2xx bodies");
         Check
           (Result.Value.Kind = JSON.JSON_Int_Type
            and then Long_Long_Integer'(Result.Value.Get) = 42,
            "HTTP recovery returned the wrong value");
         Check
           (not Result.Has_Logs,
            "a success envelope without logLines gained logs");
      end;

      Convex.Close (Client);
      Server.Finish (Success, Message);
      Check
        (Success, "HTTP envelope fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Close (Client);
         abort Server;
         raise;
   end Run_HTTP_Envelopes;

   --  Ambiguous framing is the classic request-smuggling primitive. A client
   --  that guesses which Content-Length to believe is worse than one that
   --  refuses the message, so each of these must be rejected outright and none
   --  of them may leave the client unable to make the next call.
   task type HTTP_Framing_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end HTTP_Framing_Server;

   task body HTTP_Framing_Server is
      Listen   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer     : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed   : Boolean := False;
      Error    : US.Unbounded_String;
      Address  : GNAT.Sockets.Sock_Addr_Type;
      Envelope : constant String := "{""status"":""success"",""value"":5}";
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         for Step in 1 .. 9 loop
            GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
            declare
               Request : constant String := Read_HTTP_Request (Peer);
               pragma Unreferenced (Request);
            begin
               case Step is
                  when 1 =>
                     --  Two different Content-Length values.
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 30"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 5"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & Envelope);

                  when 2 =>
                     --  Two identical Content-Length values are still two
                     --  framing statements. Do not pick one.
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 30"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 30"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & Envelope);

                  when 3 =>
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 30"
                        & ASCII.CR
                        & ASCII.LF
                        & "Transfer-Encoding: chunked"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & Envelope);

                  when 4 =>
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Transfer-Encoding: chunked"
                        & ASCII.CR
                        & ASCII.LF
                        & "Transfer-Encoding: chunked"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & "0"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF);

                  when 5 =>
                     --  A header line with no field name at all.
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 30"
                        & ASCII.CR
                        & ASCII.LF
                        & "ThisLineHasNoColon"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & Envelope);

                  when 6 =>
                     --  Obsolete line folding lets one header carry another
                     --  header's text past a naive parser.
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 30"
                        & ASCII.CR
                        & ASCII.LF
                        & " continued: value"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & Envelope);

                  when 7 =>
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 30, 30"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & Envelope);

                  when 8 =>
                     --  Advertising more than the 2 MiB body cap must be
                     --  refused before a buffer that size is ever reserved.
                     Send_Response_Quietly
                       (Peer,
                        "HTTP/1.1 200 OK"
                        & ASCII.CR
                        & ASCII.LF
                        & "Content-Length: 4194304"
                        & ASCII.CR
                        & ASCII.LF
                        & ASCII.CR
                        & ASCII.LF
                        & Envelope);

                  when 9 =>
                     Send_Response_Quietly
                       (Peer, Sized_Response ("200 OK", Envelope));
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
   end HTTP_Framing_Server;

   procedure Run_HTTP_Framing is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : HTTP_Framing_Server;
      Client   : Convex.Client;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Success  : Boolean;
      Message  : US.Unbounded_String;
      function Framing_Case (Step : Positive) return String
      is (case Step is
            when 1      => "conflicting Content-Length",
            when 2      => "repeated Content-Length",
            when 3      => "Content-Length with Transfer-Encoding",
            when 4      => "repeated Transfer-Encoding",
            when 5      => "a header line without a colon",
            when 6      => "an obsolete folded header line",
            when 7      => "a Content-Length list",
            when others => "an unexpected framing case");
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Open (Client, URL (Port));

      for Step in 1 .. 7 loop
         declare
            Result : constant Convex.Call_Result :=
              Convex.Query (Client, "messages:framing", Args);
         begin
            Check
              (not Result.Success
               and then Result.Error.Kind = Convex.Protocol_Error,
               "HTTP framing accepted " & Framing_Case (Step));
         end;
      end loop;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:oversize", Args);
      begin
         Check
           (not Result.Success
            and then Result.Error.Kind = Convex.Transport_Error,
            "an oversized Content-Length was not a bounded transport failure");
      end;

      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:count", Args);
      begin
         Check
           (Result.Success
            and then Result.Value.Kind = JSON.JSON_Int_Type
            and then Long_Long_Integer'(Result.Value.Get) = 5,
            "HTTP did not recover after rejected framing");
      end;

      Convex.Close (Client);
      Server.Finish (Success, Message);
      Check
        (Success, "HTTP framing fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Close (Client);
         abort Server;
         raise;
   end Run_HTTP_Framing;

   --  TLS failures must arrive as bounded transport errors, not as hangs and
   --  not as protocol or function errors, and the client must stay usable.
   type TLS_Scenario is (TLS_Immediate_EOF, TLS_Garbage, TLS_Silent);

   task type TLS_Failure_Server is
      entry Start
        (Listener : GNAT.Sockets.Socket_Type; Scenario : TLS_Scenario);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end TLS_Failure_Server;

   task body TLS_Failure_Server is
      Listen  : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer    : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Mode    : TLS_Scenario := TLS_Immediate_EOF;
      Passed  : Boolean := False;
      Error   : US.Unbounded_String;
      Address : GNAT.Sockets.Sock_Addr_Type;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 4 * 1024);
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      accept Start
        (Listener : GNAT.Sockets.Socket_Type; Scenario : TLS_Scenario)
      do
         Listen := Listener;
         Mode := Scenario;
      end Start;
      begin
         GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
         case Mode is
            when TLS_Immediate_EOF =>
               --  Retire the connection while the client is still inside the
               --  handshake, which is what a TLS terminator does when it has
               --  no route or no certificate for the requested name.
               GNAT.Sockets.Set_Socket_Option
                 (Peer,
                  GNAT.Sockets.Socket_Level,
                  (Name    => GNAT.Sockets.Linger,
                   Enabled => True,
                   Seconds => 0));

            when TLS_Garbage       =>
               GNAT.Sockets.Receive_Socket (Peer, Data, Last);
               Check
                 (Last >= Data'First,
                  "TLS fixture received no ClientHello");
               Send_Response_Quietly
                 (Peer,
                  "HTTP/1.1 400 Bad Request"
                  & ASCII.CR
                  & ASCII.LF
                  & ASCII.CR
                  & ASCII.LF);

            when TLS_Silent        =>
               --  Accept and then never speak. The absolute request deadline,
               --  not an inactivity timer, has to end this.
               delay 6.5;
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
   end TLS_Failure_Server;

   procedure Run_TLS_Failure (Mode : TLS_Scenario) is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : TLS_Failure_Server;
      Client   : Convex.Client;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Success  : Boolean;
      Message  : US.Unbounded_String;
      Started  : Ada.Real_Time.Time;
      Elapsed  : Duration;
      Result   : Convex.Call_Result;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener, Mode);
      Convex.Open (Client, "https://127.0.0.1:" & Image (Natural (Port)));
      Started := Ada.Real_Time.Clock;
      --  The assertion below is about the deadline, so the test must not
      --  depend on the deadline working in order to terminate at all.
      select
         delay 8.0;
         Check
           (False,
            "a failed TLS handshake never returned for "
            & TLS_Scenario'Image (Mode));
      then abort
         Result := Convex.Query (Client, "messages:count", Args);
      end select;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Check
        (not Result.Success,
         "a failed TLS handshake produced a successful call for "
         & TLS_Scenario'Image (Mode));
      Check
        (Result.Error.Kind = Convex.Transport_Error,
         "a failed TLS handshake was not a transport error for "
         & TLS_Scenario'Image (Mode));
      Check
        (Elapsed < 6.0,
         "a failed TLS handshake exceeded the request deadline for "
         & TLS_Scenario'Image (Mode));
      Convex.Close (Client);
      Server.Finish (Success, Message);
      Check
        (Success,
         "TLS failure fixture failed for "
         & TLS_Scenario'Image (Mode)
         & ": "
         & US.To_String (Message));
   exception
      when others =>
         Convex.Close (Client);
         abort Server;
         raise;
   end Run_TLS_Failure;

   task type Single_Response_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Single_Response_Server;

   task body Single_Response_Server is
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
         GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
         declare
            Request : constant String := Read_HTTP_Request (Peer);
            pragma Unreferenced (Request);
         begin
            Send_Response_Quietly
              (Peer,
               Sized_Response
                 ("200 OK", "{""status"":""success"",""value"":11}"));
         end;
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
   end Single_Response_Server;

   procedure Run_TLS_Recovery is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Single_Response_Server;
      Client   : Convex.Client;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Success  : Boolean;
      Message  : US.Unbounded_String;
   begin
      --  Run immediately after the three TLS failures above. A failed OpenSSL
      --  handshake must leave no process-wide residue that stops the next
      --  ordinary call from completing.
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Open (Client, URL (Port));
      declare
         Result : constant Convex.Call_Result :=
           Convex.Query (Client, "messages:count", Args);
      begin
         Check
           (Result.Success
            and then Result.Value.Kind = JSON.JSON_Int_Type
            and then Long_Long_Integer'(Result.Value.Get) = 11,
            "the client did not recover after failed TLS handshakes");
      end;
      Convex.Close (Client);
      Server.Finish (Success, Message);
      Check
        (Success, "TLS recovery fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Close (Client);
         abort Server;
         raise;
   end Run_TLS_Recovery;

   type Transport_Scenario is
     (Valid_Text,
      Fragmented_UTF8,
      Partial_Header,
      Partial_Payload,
      Masked_Server_Frame,
      Noncanonical_Length,
      Fragmented_Control,
      Invalid_UTF8,
      Reserved_Bit,
      Orphan_Continuation,
      Interleaved_Data,
      Reserved_Close_Code,
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

               when Reserved_Bit        =>
                  --  RSV1 without a negotiated extension.
                  Send_Frame (Peer, 16#C1#, "x");

               when Orphan_Continuation =>
                  --  A continuation with no data frame to continue.
                  Send_Frame (Peer, 16#80#, "x");

               when Interleaved_Data    =>
                  --  A second data frame while a fragmented message is open.
                  Send_Frame (Peer, 16#01#, "a");
                  Send_Frame (Peer, 16#81#, "b");

               when Reserved_Close_Code =>
                  --  1005 is reserved for local use and must never be sent.
                  Send_Frame (Peer, 16#88#, Byte (3) & Byte (237));

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

   --  Convex omits logLines entirely when a query produced no logs. This is
   --  the shape that must not gain an empty array on its way to the adapter.
   function Bare_Updated_Transition
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
       & "}]}");

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
           (Peer, 16#81#, Bare_Updated_Transition (1, 1, Two_TS, Two_TS, 1));
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

   type Reconnect_Failure is
     (Peer_Close_Failure, Protocol_Failure, Transport_Failure);

   task type Failure_Reconnect_Server is
      entry Start
        (Listener : GNAT.Sockets.Socket_Type; Mode : Reconnect_Failure);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Failure_Reconnect_Server;

   task body Failure_Reconnect_Server is
      Listen : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Kind   : Reconnect_Failure := Peer_Close_Failure;
      Passed : Boolean := False;
      Error  : US.Unbounded_String;
   begin
      accept Start
        (Listener : GNAT.Sockets.Socket_Type; Mode : Reconnect_Failure)
      do
         Listen := Listener;
         Kind := Mode;
      end Start;
      begin
         Upgrade (Listen, Peer);
         declare
            Connect : constant JSON.JSON_Value :=
              Read_Object (Read_Client_Text (Peer));
         begin
            Check
              (String_Field (Connect, "type") = "Connect"
               and then Integer_Field (Connect, "connectionCount") = 0,
               "failure reconnect fixture expected initial Connect");
         end;
         Validate_Add (Read_Client_Text (Peer));
         Send_Frame
           (Peer, 16#81#, Updated_Transition (0, 1, Initial_TS, One_TS, 0));
         case Kind is
            when Peer_Close_Failure =>
               Send_Frame (Peer, 16#88#, Byte (3) & Byte (232) & "peer-close");
               Wait_For_Close (Peer);
               Close_Quietly (Peer);

            when Protocol_Failure   =>
               Send_All
                 (Peer,
                  Byte (16#81#)
                  & Byte (16#80#)
                  & Byte (0)
                  & Byte (0)
                  & Byte (0)
                  & Byte (0));
               Wait_For_Close (Peer);
               Close_Quietly (Peer);

            when Transport_Failure  =>
               GNAT.Sockets.Set_Socket_Option
                 (Peer,
                  GNAT.Sockets.Socket_Level,
                  (Name    => GNAT.Sockets.Linger,
                   Enabled => True,
                   Seconds => 0));
               Close_Quietly (Peer);
         end case;

         Upgrade (Listen, Peer);
         declare
            Connect : constant JSON.JSON_Value :=
              Read_Object (Read_Client_Text (Peer));
            Reason  : constant String :=
              String_Field (Connect, "lastCloseReason");
         begin
            Check
              (String_Field (Connect, "type") = "Connect",
               "failure reconnect fixture expected second Connect");
            Check
              (Integer_Field (Connect, "connectionCount") = 1,
               "non-debug failure left connectionCount stale");
            Check
              (String_Field (Connect, "maxObservedTimestamp") = One_TS,
               "failure reconnect lost maxObservedTimestamp");
            case Kind is
               when Peer_Close_Failure =>
                  Check
                    (Reason = "peer-close",
                     "peer-close reconnect lost lastCloseReason");

               when Protocol_Failure   =>
                  Check
                    (Ada.Strings.Fixed.Index (Reason, "protocol: ") = 1,
                     "protocol reconnect lost lastCloseReason");

               when Transport_Failure  =>
                  Check
                    (Reason'Length > 0 and then Reason /= "InitialConnect",
                     "transport reconnect lost lastCloseReason");
            end case;
         end;
         Validate_Add (Read_Client_Text (Peer));
         Send_Frame
           (Peer, 16#81#, Updated_Transition (0, 1, Initial_TS, Two_TS, 1));
         Validate_Remove (Read_Client_Text (Peer));
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
   end Failure_Reconnect_Server;

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
      Check
        (Item.Has_Logs and then JSON.Length (Item.Logs) = 1,
         "QueryUpdated logs were lost");
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
      Check
        (Item.Has_Logs
         and then Item.Error.Has_Logs
         and then JSON.Length (Item.Logs) = 1,
         "QueryFailed logs were lost");
      Convex.Live.Release (Manager, Item);

      Wait_Update (Manager, Sub, Item);
      Check_Integer_Update (Item, 1);
      Check
        (not Item.Has_Logs,
         "an update without logLines gained an empty logs array");
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

   type Slow_Live_Write_Action is (Concurrent_Unsubscribe, Concurrent_Close);
   type Live_Manager_Access is access all Convex.Live.Manager;
   type JSON_Value_Access is access all JSON.JSON_Value;

   task type Slow_Add_Worker is
      entry Start (Manager : Live_Manager_Access; Args : JSON_Value_Access);
      entry Finish
        (Success : out Boolean;
         Message : out US.Unbounded_String);
   end Slow_Add_Worker;

   task body Slow_Add_Worker is
      Live         : Live_Manager_Access;
      Arguments    : JSON_Value_Access;
      Sub          : Convex.Live.Subscription;
      Added        : Boolean := False;
      Detail       : US.Unbounded_String;
   begin
      accept Start (Manager : Live_Manager_Access; Args : JSON_Value_Access) do
         Live := Manager;
         Arguments := Args;
      end Start;
      begin
         Convex.Live.Subscribe
           (Live.all, "messages:large", Arguments.all, Sub, Added, Detail);
      exception
         when E : others =>
            Added := False;
            Detail :=
              US.To_Unbounded_String
                (Ada.Exceptions.Exception_Information (E));
      end;
      accept Finish
        (Success : out Boolean;
         Message : out US.Unbounded_String)
      do
         Success := Added;
         Message := Detail;
      end Finish;
   end Slow_Add_Worker;

   task type Slow_Live_Write_Server is
      entry Start
        (Listener : GNAT.Sockets.Socket_Type; Action : Slow_Live_Write_Action);
      entry Initial_Ready;
      entry Large_Frame_Started;
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Slow_Live_Write_Server;

   task body Slow_Live_Write_Server is
      Listen       : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer         : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Mode         : Slow_Live_Write_Action := Concurrent_Unsubscribe;
      Passed       : Boolean := False;
      Error        : US.Unbounded_String;
      Large_Length : Natural := 0;
   begin
      accept Start
        (Listener : GNAT.Sockets.Socket_Type; Action : Slow_Live_Write_Action)
      do
         Listen := Listener;
         Mode := Action;
      end Start;
      begin
         GNAT.Sockets.Set_Socket_Option
           (Listen,
            GNAT.Sockets.Socket_Level,
            (Name => GNAT.Sockets.Receive_Buffer, Size => 16 * 1024));
         Upgrade (Listen, Peer);
         Check
           (String_Field (Read_Object (Read_Client_Text (Peer)), "type")
            = "Connect",
            "slow Live writer fixture expected Connect first");
         Validate_Add (Read_Client_Text (Peer));
         accept Initial_Ready;

         --  A broken client must not leave the fixture itself stuck in recv.
         --  This timeout is only the outer diagnostic bound. The production
         --  frame deadline remains the stricter 500 ms contract.
         GNAT.Sockets.Set_Socket_Option
           (Peer,
            GNAT.Sockets.Socket_Level,
            (Name    => GNAT.Sockets.Receive_Timeout,
             Timeout => 2.0));

         --  Consume only the near-maximum Add frame's header and mask. The
         --  small receive window then keeps the owner inside frame output
         --  while the controller queues Remove or Stop.
         Large_Length := Read_Client_Text_Length (Peer);
         Check
           (Large_Length > 2_000_000,
            "slow Live writer fixture did not receive a near-maximum Add");
         accept Large_Frame_Started;
         delay 1.1;
         Wait_For_Close (Peer);
         Passed := True;
      exception
         when E : others =>
            Error :=
              US.To_Unbounded_String
                (Slow_Live_Write_Action'Image (Mode)
                 & ": "
                 & Ada.Exceptions.Exception_Information (E));
      end;
      Close_Quietly (Peer);
      Close_Quietly (Listen);
      accept Finish
        (Success : out Boolean; Message : out US.Unbounded_String)
      do
         Success := Passed;
         Message := Error;
      end Finish;
   end Slow_Live_Write_Server;

   procedure Run_Slow_Live_Write (Mode : Slow_Live_Write_Action) is
      Listener    : GNAT.Sockets.Socket_Type;
      Port        : GNAT.Sockets.Port_Type;
      Server      : Slow_Live_Write_Server;
      Worker      : Slow_Add_Worker;
      Manager     : aliased Convex.Live.Manager;
      Small_Sub   : Convex.Live.Subscription;
      Small_Args  : constant JSON.JSON_Value := JSON.Create_Object;
      Large_Args  : aliased JSON.JSON_Value := JSON.Create_Object;
      Success     : Boolean;
      Message     : US.Unbounded_String;
      Started              : Ada.Real_Time.Time;
      Transmission_Started : Ada.Real_Time.Time;
      Action_Time          : Duration;
      Transmission_Time    : Duration;
   begin
      --  This is close to the largest argument that fits beside the first
      --  subscription under Live's conservative 8 MiB ownership budget.
      Large_Args.Set_Field ("payload", String'(1 .. 2_096_000 => 'w'));
      Open_Listener (Listener, Port);
      Server.Start (Listener, Mode);
      Convex.Live.Open (Manager, URL (Port));
      Convex.Live.Subscribe
        (Manager, "messages:small", Small_Args, Small_Sub, Success, Message);
      Check
        (Success,
         "slow Live writer initial subscribe failed: "
         & US.To_String (Message));
      select
         Server.Initial_Ready;
      or
         delay 2.0;
         raise Program_Error
           with "slow Live writer server did not reach its initial barrier";
      end select;

      Worker.Start (Manager'Unchecked_Access, Large_Args'Unchecked_Access);
      --  Put the timeout around the caller. The previous server-side select
      --  was after its blocking header read, so it could never fire when the
      --  client failed before sending the first byte.
      select
         Server.Large_Frame_Started;
      or
         delay 2.0;
         raise Program_Error
           with "slow Live writer client never reached the frame barrier";
      end select;
      Transmission_Started := Ada.Real_Time.Clock;
      Started := Ada.Real_Time.Clock;
      --  The action being measured is also inside an independent deadline.
      --  Measuring only after a synchronous call returns cannot diagnose a
      --  regression that never returns at all.
      select
         delay 0.9;
         raise Program_Error
           with
             "slow Live frame kept the owner from "
             & Slow_Live_Write_Action'Image (Mode)
             & " for 900 ms";
      then abort
         case Mode is
            when Concurrent_Unsubscribe =>
               Convex.Live.Unsubscribe (Manager, Small_Sub);

            when Concurrent_Close       =>
               Convex.Live.Close (Manager);
         end case;
      end select;
      Action_Time := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Check
        (Action_Time < 0.9,
         "slow Live frame kept the owner from "
         & Slow_Live_Write_Action'Image (Mode)
         & " for 900 ms");

      select
         Worker.Finish (Success, Message);
      or
         delay 0.9;
         raise Program_Error
           with "near-maximum Live Add did not retire after its deadline";
      end select;
      Transmission_Time :=
        Ada.Real_Time.To_Duration
          (Ada.Real_Time.Clock - Transmission_Started);
      Check
        (Success,
         "near-maximum Live Add was rejected: " & US.To_String (Message));
      Check
        (Transmission_Time < 0.9,
         "near-maximum Live Add renewed its frame deadline per chunk");
      if Mode = Concurrent_Unsubscribe then
         select
            delay 0.9;
            raise Program_Error
              with "slow Live write cleanup close exceeded 900 ms";
         then abort
            Convex.Live.Close (Manager);
         end select;
      end if;
      select
         Server.Finish (Success, Message);
      or
         delay 2.0;
         raise Program_Error with "slow Live writer server did not finish";
      end select;
      Check
        (Success, "slow Live write fixture failed: " & US.To_String (Message));
   exception
      when others =>
         --  Never call the synchronous Stop entry while handling a failure in
         --  the test that proves Stop is bounded. The test-only abort path
         --  guarantees that diagnostic cleanup cannot hide the first failure.
         Convex.Live.Testing.Abort_Manager (Manager);
         abort Worker;
         abort Server;
         raise;
   end Run_Slow_Live_Write;

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

   --  Four refused upgrades grow the exponential backoff. The fifth
   --  connection is a complete, validated handshake, so the delay after it
   --  fails must come from the reset interval and not from the delay the
   --  earlier failures had accumulated.
   task type Backoff_Reset_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Backoff_Reset_Server;

   task body Backoff_Reset_Server is
      Listen     : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer       : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed     : Boolean := False;
      Error      : US.Unbounded_String;
      Address    : GNAT.Sockets.Sock_Addr_Type;
      Retired_At : Ada.Real_Time.Time;
      Waited     : Duration := 0.0;
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         for Attempt in 1 .. 4 loop
            GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
            declare
               Request : constant String := Read_HTTP_Headers (Peer);
               pragma Unreferenced (Request);
            begin
               Send_Response_Quietly
                 (Peer,
                  "HTTP/1.1 400 Bad Request"
                  & ASCII.CR
                  & ASCII.LF
                  & "Content-Length: 0"
                  & ASCII.CR
                  & ASCII.LF
                  & "Connection: close"
                  & ASCII.CR
                  & ASCII.LF
                  & ASCII.CR
                  & ASCII.LF);
            end;
            Close_Quietly (Peer);
         end loop;

         Upgrade (Listen, Peer);
         Check
           (String_Field (Read_Object (Read_Client_Text (Peer)), "type")
            = "Connect",
            "backoff fixture expected Connect on the validated handshake");
         Validate_Add (Read_Client_Text (Peer));
         Send_Frame
           (Peer, 16#81#, Updated_Transition (0, 1, Initial_TS, One_TS, 0));

         --  Retire the healthy connection abruptly and time the next attempt.
         GNAT.Sockets.Set_Socket_Option
           (Peer,
            GNAT.Sockets.Socket_Level,
            (Name => GNAT.Sockets.Linger, Enabled => True, Seconds => 0));
         Close_Quietly (Peer);
         Retired_At := Ada.Real_Time.Clock;

         Upgrade (Listen, Peer);
         Waited :=
           Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Retired_At);
         Check
           (Waited < 0.9,
            "a reconnect after a validated handshake inherited the backoff "
            & "grown by the earlier failures");
         Check
           (String_Field (Read_Object (Read_Client_Text (Peer)), "type")
            = "Connect",
            "backoff fixture expected Connect after the reset");
         --  Replay is unchanged by the reset: the active query is re-added.
         Validate_Add (Read_Client_Text (Peer));
         Send_Frame
           (Peer, 16#81#, Updated_Transition (0, 1, Initial_TS, Two_TS, 1));

         --  A masked server frame is a protocol violation. Later protocol
         --  error handling must still retire this connection and report.
         Send_All
           (Peer,
            Byte (16#81#)
            & Byte (16#80#)
            & Byte (0)
            & Byte (0)
            & Byte (0)
            & Byte (0));
         Wait_For_Close (Peer);
         Close_Quietly (Peer);

         Upgrade (Listen, Peer);
         Check
           (String_Field (Read_Object (Read_Client_Text (Peer)), "type")
            = "Connect",
            "backoff fixture expected Connect after the protocol failure");
         Validate_Add (Read_Client_Text (Peer));
         Send_Frame
           (Peer,
            16#81#,
            Updated_Transition
              (0,
               1,
               Initial_TS,
               Convex_WebSocket.Encode_Timestamp (3),
               2));
         Validate_Remove (Read_Client_Text (Peer));
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
   end Backoff_Reset_Server;

   --  Drain intervening transport and protocol notices while waiting for the
   --  next real value, recording whether a protocol error was among them.
   procedure Wait_For_Value
     (Manager            : in out Convex.Live.Manager;
      Sub                : Convex.Live.Subscription;
      Expected           : Long_Long_Integer;
      Saw_Protocol_Error : in out Boolean;
      Timeout            : Duration := 8.0)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout);
      Found    : Boolean;
      Item     : Convex.Live.Update;
   begin
      while Ada.Real_Time.Clock < Deadline loop
         Convex.Live.Try_Next (Manager, Sub, Found, Item);
         if Found then
            if Item.Has_Value then
               Check_Integer_Update (Item, Expected);
               Convex.Live.Release (Manager, Item);
               return;
            end if;
            if Item.Has_Error
              and then Item.Error.Kind = Convex.Protocol_Error
            then
               Saw_Protocol_Error := True;
            end if;
            Convex.Live.Release (Manager, Item);
         else
            delay 0.005;
         end if;
      end loop;
      Check (False, "timed out waiting for a Live value");
   end Wait_For_Value;

   procedure Run_Backoff_Reset is
      Listener   : GNAT.Sockets.Socket_Type;
      Port       : GNAT.Sockets.Port_Type;
      Server     : Backoff_Reset_Server;
      Manager    : Convex.Live.Manager;
      Sub        : Convex.Live.Subscription;
      Args       : constant JSON.JSON_Value := JSON.Create_Object;
      Success    : Boolean;
      Message    : US.Unbounded_String;
      Saw_Broken : Boolean := False;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener);
      Convex.Live.Open (Manager, URL (Port));
      Convex.Live.Subscribe
        (Manager, "messages:count", Args, Sub, Success, Message);
      Check
        (Success, "backoff reset subscribe failed: " & US.To_String (Message));

      Wait_For_Value (Manager, Sub, 0, Saw_Broken);
      Wait_For_Value (Manager, Sub, 1, Saw_Broken);
      Saw_Broken := False;
      Wait_For_Value (Manager, Sub, 2, Saw_Broken);
      Check
        (Saw_Broken,
         "a protocol failure after the backoff reset was not reported");

      Convex.Live.Unsubscribe (Manager, Sub);
      Convex.Live.Close (Manager);
      Server.Finish (Success, Message);
      Check
        (Success, "backoff reset fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Live.Testing.Abort_Manager (Manager);
         abort Server;
         raise;
   end Run_Backoff_Reset;

   procedure Run_Failure_Reconnect (Mode : Reconnect_Failure) is
      Listener : GNAT.Sockets.Socket_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Failure_Reconnect_Server;
      Manager  : Convex.Live.Manager;
      Sub      : Convex.Live.Subscription;
      Args     : constant JSON.JSON_Value := JSON.Create_Object;
      Item     : Convex.Live.Update;
      Success  : Boolean;
      Message  : US.Unbounded_String;
   begin
      Open_Listener (Listener, Port);
      Server.Start (Listener, Mode);
      Convex.Live.Open (Manager, URL (Port));
      Convex.Live.Subscribe
        (Manager, "messages:count", Args, Sub, Success, Message);
      Check
        (Success,
         "failure reconnect subscribe failed: " & US.To_String (Message));

      Wait_Update (Manager, Sub, Item);
      Check_Integer_Update (Item, 0);
      Convex.Live.Release (Manager, Item);

      Wait_Update (Manager, Sub, Item, Timeout => 4.0);
      Check
        (Item.Has_Error and then not Item.Has_Value,
         "non-debug failure did not publish a structured error");
      Check
        (Item.Error.Kind
         = (if Mode = Protocol_Failure
            then Convex.Protocol_Error
            else Convex.Transport_Error),
         "non-debug failure published the wrong error kind");
      Convex.Live.Release (Manager, Item);

      Wait_Update (Manager, Sub, Item, Timeout => 4.0);
      Check_Integer_Update (Item, 1);
      Convex.Live.Release (Manager, Item);
      Convex.Live.Unsubscribe (Manager, Sub);
      Convex.Live.Close (Manager);
      Server.Finish (Success, Message);
      Check
        (Success,
         "failure reconnect fixture failed: " & US.To_String (Message));
   exception
      when others =>
         Convex.Live.Close (Manager);
         abort Server;
         raise;
   end Run_Failure_Reconnect;

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
   Run_Transport (Reserved_Bit, Convex_WebSocket.Protocol_Failure);
   Run_Transport (Orphan_Continuation, Convex_WebSocket.Protocol_Failure);
   Run_Transport (Interleaved_Data, Convex_WebSocket.Protocol_Failure);
   Run_Transport (Reserved_Close_Code, Convex_WebSocket.Protocol_Failure);

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
   Ada.Text_IO.Put_Line ("http: strict status and absolute response deadline");
   Run_HTTP_Edges;
   Ada.Text_IO.Put_Line ("http: absolute request transmission deadline");
   Run_HTTP_Write_Deadline;
   Ada.Text_IO.Put_Line ("http: non-2xx Convex error envelopes and recovery");
   Run_HTTP_Envelopes;
   Ada.Text_IO.Put_Line ("http: strict response framing and recovery");
   Run_HTTP_Framing;

   Ada.Text_IO.Put_Line ("tls: bounded handshake failures and recovery");
   for Mode in TLS_Scenario loop
      Run_TLS_Failure (Mode);
   end loop;
   Run_TLS_Recovery;

   Ada.Text_IO.Put_Line ("live: recovery, reconnects, and bounded lifecycle");
   Run_Live_Flow;
   Ada.Text_IO.Put_Line ("live: peer, protocol, and transport reconnects");
   for Mode in Reconnect_Failure loop
      Run_Failure_Reconnect (Mode);
   end loop;
   Ada.Text_IO.Put_Line ("live: backoff reset on a validated handshake");
   Run_Backoff_Reset;
   Ada.Text_IO.Put_Line ("live: five reconnects");
   Run_Reconnects;
   Ada.Text_IO.Put_Line ("live: count and byte backpressure");
   Run_Backpressure;
   Ada.Text_IO.Put_Line ("live: slow-reader frame transmission deadline");
   for Mode in Slow_Live_Write_Action loop
      Run_Slow_Live_Write (Mode);
   end loop;
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
