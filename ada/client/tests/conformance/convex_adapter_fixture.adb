with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Convex_WebSocket;
with GNAT.SHA1;
with GNAT.Sockets;
with GNATCOLL.JSON;
with Interfaces;

procedure Convex_Adapter_Fixture is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_8;

   WebSocket_GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   Initial_TS     : constant String := "AAAAAAAAAAA=";

   --  The stopped-reader evidence needs deliveries close to the client's
   --  four-megabyte message ceiling, and the ordinary relay tests need
   --  something smaller. One fixture serves both: the caller names the size
   --  and the fixture refuses anything the client would reject as an
   --  oversized frame, so a mistake here fails loudly instead of silently
   --  testing a smaller value than it claims.
   Large_Value_Bytes : constant Natural :=
     (if Ada.Environment_Variables.Exists ("FIXTURE_VALUE_BYTES")
      then
        Natural'Value (Ada.Environment_Variables.Value ("FIXTURE_VALUE_BYTES"))
      else 900_000);

   function Byte (Value : Natural) return Character
   is (Character'Val (Value));

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Send_All (Socket : GNAT.Sockets.Socket_Type; Text : String) is
      Data   : Ada.Streams.Stream_Element_Array (1 .. 16 * 1024);
      Last   : Ada.Streams.Stream_Element_Offset;
      Cursor : Natural := 0;
   begin
      while Cursor < Text'Length loop
         declare
            Count : constant Natural :=
              Natural'Min (Data'Length, Text'Length - Cursor);
            Sent  : Natural := 0;
         begin
            for Offset in 0 .. Count - 1 loop
               Data (Ada.Streams.Stream_Element_Offset (Offset + 1)) :=
                 Ada.Streams.Stream_Element
                   (Character'Pos (Text (Text'First + Cursor + Offset)));
            end loop;
            while Sent < Count loop
               GNAT.Sockets.Send_Socket
                 (Socket,
                  Data
                    (Ada.Streams.Stream_Element_Offset (Sent + 1)
                     .. Ada.Streams.Stream_Element_Offset (Count)),
                  Last);
               Check
                 (Last >= Ada.Streams.Stream_Element_Offset (Sent + 1),
                  "fixture peer closed while sending");
               Sent := Natural (Last);
            end loop;
            Cursor := Cursor + Count;
         end;
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
         Check
           (Last >= Ada.Streams.Stream_Element_Offset (Read + 1),
            "fixture peer closed while receiving");
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
         Check (Last >= Data'First, "fixture peer closed during upgrade");
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
         end;
      end loop;
   end Read_HTTP_Headers;

   function Header_Value (Headers, Name : String) return String is
      Needle : constant String := Name & ": ";
      First  : constant Natural := Ada.Strings.Fixed.Index (Headers, Needle);
      Last   : Natural;
   begin
      Check (First > 0, "fixture upgrade header is missing");
      Last :=
        Ada.Strings.Fixed.Index
          (Headers, ASCII.CR & ASCII.LF, First + Needle'Length);
      Check (Last > 0, "fixture upgrade header is incomplete");
      return Headers (First + Needle'Length .. Last - 1);
   end Header_Value;

   procedure Upgrade
     (Listener : GNAT.Sockets.Socket_Type; Peer : out GNAT.Sockets.Socket_Type)
   is
      Address : GNAT.Sockets.Sock_Addr_Type;
   begin
      GNAT.Sockets.Accept_Socket (Listener, Peer, Address);
      declare
         Request : constant String := Read_HTTP_Headers (Peer);
         Key     : constant String :=
           Header_Value (Request, "Sec-WebSocket-Key");
         Digest  : constant GNAT.SHA1.Binary_Message_Digest :=
           GNAT.SHA1.Digest (Key & WebSocket_GUID);
      begin
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
            & Convex_WebSocket.Encode_Base64 (Digest)
            & ASCII.CR
            & ASCII.LF
            & ASCII.CR
            & ASCII.LF);
      end;
   end Upgrade;

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
            "fixture expected client text");
         Check ((B2 and 16#80#) /= 0, "client text was not masked");
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
         end if;
         declare
            Mask    : String (1 .. 4);
            Payload : String (1 .. Length);
         begin
            Read_Exactly (Socket, Mask);
            Read_Exactly (Socket, Payload);
            for I in Payload'Range loop
               Payload (I) :=
                 Character'Val
                   (Interfaces.Unsigned_8 (Character'Pos (Payload (I)))
                    xor Interfaces.Unsigned_8
                          (Character'Pos (Mask ((I - 1) mod 4 + 1))));
            end loop;
            return Payload;
         end;
      end;
   end Read_Client_Text;

   procedure Send_Frame (Socket : GNAT.Sockets.Socket_Type; Payload : String)
   is
   begin
      Send_All
        (Socket,
         Byte (16#81#)
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
   end Send_Frame;

   function Version (Query_Set : Natural; Timestamp : String) return String
   is ("{""querySet"":"
       & Natural'Image (Query_Set)
       & ",""identity"":0,""ts"":"""
       & Timestamp
       & """}");

   function Large_Transition (Index : Positive; Fill : Character) return String
   is
      Chunk     : constant String (1 .. 4_096) := [others => Fill];
      Remaining : Natural := Large_Value_Bytes;
      Start_TS  : constant String :=
        (if Index = 1
         then Initial_TS
         else
           Convex_WebSocket.Encode_Timestamp
             (Interfaces.Unsigned_64 (Index - 1)));
      End_TS    : constant String :=
        Convex_WebSocket.Encode_Timestamp (Interfaces.Unsigned_64 (Index));
      Result    : US.Unbounded_String :=
        US.To_Unbounded_String
          ("{""type"":""Transition"",""startVersion"":"
           & Version ((if Index = 1 then 0 else 1), Start_TS)
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

   Listener : GNAT.Sockets.Socket_Type;
   Peer     : GNAT.Sockets.Socket_Type;
   Address  : GNAT.Sockets.Sock_Addr_Type;
   Port     : constant GNAT.Sockets.Port_Type :=
     GNAT.Sockets.Port_Type'Value
       ((if Ada.Environment_Variables.Exists ("FIXTURE_PORT")
         then Ada.Environment_Variables.Value ("FIXTURE_PORT")
         else "19090"));
begin
   GNAT.Sockets.Create_Socket (Listener);
   GNAT.Sockets.Set_Socket_Option
     (Listener,
      GNAT.Sockets.Socket_Level,
      (Name => GNAT.Sockets.Reuse_Address, Enabled => True));
   Address.Addr := GNAT.Sockets.Any_Inet_Addr;
   Address.Port := Port;
   GNAT.Sockets.Bind_Socket (Listener, Address);
   GNAT.Sockets.Listen_Socket (Listener, 1);
   Ada.Text_IO.Put_Line ("adapter fixture ready");
   Ada.Text_IO.Flush;
   Upgrade (Listener, Peer);
   declare
      Connect : constant JSON.Read_Result :=
        JSON.Read (Read_Client_Text (Peer));
      Add     : constant JSON.Read_Result :=
        JSON.Read (Read_Client_Text (Peer));
   begin
      Check
        (Connect.Success and then Add.Success, "fixture client JSON failed");
      Check
        (String'(Connect.Value.Get ("type")) = "Connect",
         "fixture expected Connect");
      Check
        (String'(Add.Value.Get ("type")) = "ModifyQuerySet",
         "fixture expected Add");
   end;
   for Index in 1 .. 5 loop
      declare
         Message : constant String :=
           Large_Transition
             (Index, Character'Val (Character'Pos ('A') + Index - 1));
      begin
         Check
           (Message'Length <= Convex_WebSocket.Max_Message_Bytes,
            "fixture transition exceeds the client message ceiling");
         Send_Frame (Peer, Message);
      end;
   end loop;
   Wait_For_Close (Peer);
   GNAT.Sockets.Close_Socket (Peer);
   GNAT.Sockets.Close_Socket (Listener);
end Convex_Adapter_Fixture;
