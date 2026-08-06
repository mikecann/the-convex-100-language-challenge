with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings;
with Ada.Strings.Fixed;
with GNAT.SHA1;
with GNATCOLL.Random;
with Interfaces.C;
with AWS.Net.SSL;
with AWS.URL;

package body Convex_WebSocket is
   use Ada.Streams;
   use type AWS.Net.Socket_Access;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Ada.Real_Time.Time;

   Base64_Alphabet     : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
   WebSocket_GUID      : constant String :=
     "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   Max_Handshake_Bytes : constant := 16 * 1024;

   function C_Shutdown
     (FD : Interfaces.C.int; How : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "shutdown";

   function Valid_Close_Code (Payload : String) return Boolean is
      Code : Natural;
   begin
      if Payload'Length < 2 then
         return True;
      end if;
      Code :=
        Character'Pos (Payload (Payload'First))
        * 256
        + Character'Pos (Payload (Payload'First + 1));
      return
        (Code in 1_000 .. 1_014 and then Code not in 1_004 .. 1_006)
        or else Code in 3_000 .. 4_999;
   end Valid_Close_Code;

   function Encode_Base64 (Data : Stream_Element_Array) return String is
      Length  : constant Natural := Natural (Data'Length);
      Result  : String (1 .. ((Length + 2) / 3) * 4);
      Input   : Stream_Element_Offset := Data'First;
      Output  : Positive := Result'First;
      A, B, C : Natural;
   begin
      while Input <= Data'Last loop
         A := Natural (Data (Input));
         B :=
           (if Input + 1 <= Data'Last then Natural (Data (Input + 1)) else 0);
         C :=
           (if Input + 2 <= Data'Last then Natural (Data (Input + 2)) else 0);
         Result (Output) := Base64_Alphabet (A / 4 + 1);
         Result (Output + 1) := Base64_Alphabet ((A mod 4) * 16 + B / 16 + 1);
         Result (Output + 2) :=
           (if Input + 1 <= Data'Last
            then Base64_Alphabet ((B mod 16) * 4 + C / 64 + 1)
            else '=');
         Result (Output + 3) :=
           (if Input + 2 <= Data'Last
            then Base64_Alphabet (C mod 64 + 1)
            else '=');
         Input := Input + 3;
         Output := Output + 4;
      end loop;
      return Result;
   end Encode_Base64;

   function Decode_Base64_Char (C : Character) return Integer is
      Position : constant Natural :=
        Ada.Strings.Fixed.Index (Base64_Alphabet, String'[1 => C]);
   begin
      return (if Position = 0 then -1 else Position - 1);
   end Decode_Base64_Char;

   function Decode_Timestamp
     (Text : String; Value : out Interfaces.Unsigned_64) return Boolean
   is
      Bytes  : array (0 .. 7) of Natural := [others => 0];
      Cursor : Natural := 0;
      I      : Integer := Text'First;
      V      : array (0 .. 3) of Integer;
      Acc    : Interfaces.Unsigned_64 := 0;
      use type Interfaces.Unsigned_64;
   begin
      Value := 0;
      if Text'Length /= 12 or else Text (Text'Last) /= '=' then
         return False;
      end if;
      while I <= Text'Last loop
         for J in 0 .. 3 loop
            V (J) :=
              (if Text (I + J) = '='
               then 0
               else Decode_Base64_Char (Text (I + J)));
            if V (J) < 0 then
               return False;
            end if;
         end loop;
         if Cursor <= 7 then
            Bytes (Cursor) := V (0) * 4 + V (1) / 16;
            Cursor := Cursor + 1;
         end if;
         if Text (I + 2) /= '=' and then Cursor <= 7 then
            Bytes (Cursor) := (V (1) mod 16) * 16 + V (2) / 4;
            Cursor := Cursor + 1;
         end if;
         if Text (I + 3) /= '=' and then Cursor <= 7 then
            Bytes (Cursor) := (V (2) mod 4) * 64 + V (3);
            Cursor := Cursor + 1;
         end if;
         I := I + 4;
      end loop;
      if Cursor /= 8 then
         return False;
      end if;
      for J in reverse Bytes'Range loop
         Acc := Acc * 256 + Interfaces.Unsigned_64 (Bytes (J));
      end loop;
      Value := Acc;
      return Encode_Timestamp (Value) = Text;
   end Decode_Timestamp;

   function Encode_Timestamp (Value : Interfaces.Unsigned_64) return String is
      Bytes : Stream_Element_Array (1 .. 8);
      Work  : Interfaces.Unsigned_64 := Value;
      use type Interfaces.Unsigned_64;
   begin
      for I in Bytes'Range loop
         Bytes (I) := Stream_Element (Work mod 256);
         Work := Work / 256;
      end loop;
      return Encode_Base64 (Bytes);
   end Encode_Timestamp;

   function Valid_UTF8 (Text : String) return Boolean is
      I             : Integer := Text'First;
      B, B2, B3, B4 : Natural;
      function Continuation (Value : Natural) return Boolean
      is (Value in 16#80# .. 16#BF#);
   begin
      while I <= Text'Last loop
         B := Character'Pos (Text (I));
         if B <= 16#7F# then
            I := I + 1;
         elsif B in 16#C2# .. 16#DF# then
            if I + 1 > Text'Last then
               return False;
            end if;
            B2 := Character'Pos (Text (I + 1));
            if not Continuation (B2) then
               return False;
            end if;
            I := I + 2;
         elsif B in 16#E0# .. 16#EF# then
            if I + 2 > Text'Last then
               return False;
            end if;
            B2 := Character'Pos (Text (I + 1));
            B3 := Character'Pos (Text (I + 2));
            if not Continuation (B2)
              or else not Continuation (B3)
              or else (B = 16#E0# and then B2 < 16#A0#)
              or else (B = 16#ED# and then B2 > 16#9F#)
            then
               return False;
            end if;
            I := I + 3;
         elsif B in 16#F0# .. 16#F4# then
            if I + 3 > Text'Last then
               return False;
            end if;
            B2 := Character'Pos (Text (I + 1));
            B3 := Character'Pos (Text (I + 2));
            B4 := Character'Pos (Text (I + 3));
            if not Continuation (B2)
              or else not Continuation (B3)
              or else not Continuation (B4)
              or else (B = 16#F0# and then B2 < 16#90#)
              or else (B = 16#F4# and then B2 > 16#8F#)
            then
               return False;
            end if;
            I := I + 4;
         else
            return False;
         end if;
      end loop;
      return True;
   end Valid_UTF8;

   function Next_Mask
     (Socket : in out Connection) return Interfaces.Unsigned_32
   is
      pragma Unreferenced (Socket);
   begin
      return GNATCOLL.Random.Random_Unsigned_32;
   end Next_Mask;

   procedure Send_Frame
     (Socket : in out Connection; Opcode : Natural; Payload : String)
   is
      Header : Stream_Element_Array (1 .. 14);
      Data   : Stream_Element_Array (1 .. 16 * 1_024);
      Cursor : Stream_Element_Offset := Header'First;
      Mask   : constant Interfaces.Unsigned_32 := Next_Mask (Socket);
      Keys   : constant array (Natural range 0 .. 3) of Stream_Element :=
        [Stream_Element (Interfaces.Shift_Right (Mask, 24) and 16#FF#),
         Stream_Element (Interfaces.Shift_Right (Mask, 16) and 16#FF#),
         Stream_Element (Interfaces.Shift_Right (Mask, 8) and 16#FF#),
         Stream_Element (Mask and 16#FF#)];
      Work   : Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Payload'Length);
      use type Interfaces.Unsigned_64;
   begin
      if not Socket.Opened or else Socket.Net = null then
         raise AWS.Net.Socket_Error with "WebSocket is closed";
      end if;
      AWS.Net.Set_Timeout (Socket.Net.all, 0.5);
      Header (Cursor) := Stream_Element (16#80# + Opcode);
      Cursor := Cursor + 1;
      if Payload'Length <= 125 then
         Header (Cursor) := Stream_Element (16#80# + Payload'Length);
         Cursor := Cursor + 1;
      elsif Payload'Length <= 65_535 then
         Header (Cursor) := 16#FE#;
         Header (Cursor + 1) := Stream_Element (Payload'Length / 256);
         Header (Cursor + 2) := Stream_Element (Payload'Length mod 256);
         Cursor := Cursor + 3;
      else
         Header (Cursor) := 16#FF#;
         Cursor := Cursor + 1;
         for I in reverse 0 .. 7 loop
            Header (Cursor + Stream_Element_Offset (I)) :=
              Stream_Element (Work mod 256);
            Work := Work / 256;
         end loop;
         Cursor := Cursor + 8;
      end if;
      for Key of Keys loop
         Header (Cursor) := Key;
         Cursor := Cursor + 1;
      end loop;
      AWS.Net.Send (Socket.Net.all, Header (Header'First .. Cursor - 1));

      -- Stream large JSON arguments instead of placing a complete masked frame
      -- on the Live owner's task stack.
      declare
         Processed : Natural := 0;
      begin
         while Processed < Payload'Length loop
            declare
               Length : constant Natural :=
                 Natural'Min
                   (Natural (Data'Length), Payload'Length - Processed);
            begin
               for Offset in 0 .. Length - 1 loop
                  Data (Stream_Element_Offset (Offset + 1)) :=
                    Stream_Element
                      (Interfaces.Unsigned_8
                         (Character'Pos
                            (Payload (Payload'First + Processed + Offset)))
                       xor Interfaces.Unsigned_8
                             (Keys ((Processed + Offset) mod 4)));
               end loop;
               AWS.Net.Send
                 (Socket.Net.all,
                  Data (Data'First .. Stream_Element_Offset (Length)));
               Processed := Processed + Length;
            end;
         end loop;
      end;
   end Send_Frame;

   procedure Send_Text (Socket : in out Connection; Message : String) is
   begin
      if Message'Length > Max_Message_Bytes then
         raise Constraint_Error with "WebSocket message exceeds 4 MiB";
      end if;
      if not Valid_UTF8 (Message) then
         raise Constraint_Error with "WebSocket text is not UTF-8";
      end if;
      Send_Frame (Socket, 1, Message);
   end Send_Text;

   procedure Read_Network (Socket : in out Connection; Timeout : Duration) is
      Events : AWS.Net.Event_Set := [others => False];
      Data   : Stream_Element_Array (1 .. 16 * 1024);
      Last   : Stream_Element_Offset;
      Chunk  : String (1 .. Data'Length);
   begin
      if Socket.Net.Pending = 0 then
         Events :=
           AWS.Net.Poll
             (Socket.Net.all,
              [AWS.Net.Input => True, AWS.Net.Output => False],
              Timeout);
         if not Events (AWS.Net.Input) then
            return;
         end if;
      end if;
      AWS.Net.Set_Timeout (Socket.Net.all, 0.05);
      Socket.Net.Receive (Data, Last);
      if Last < Data'First then
         raise AWS.Net.Socket_Error with "peer closed WebSocket";
      end if;
      for I in Data'First .. Last loop
         Chunk (Natural (I)) := Character'Val (Data (I));
      end loop;
      US.Append (Socket.Buffer, Chunk (1 .. Natural (Last)));
      if US.Length (Socket.Buffer) > Max_Message_Bytes + 14 then
         raise Constraint_Error with "WebSocket buffered frame exceeds 4 MiB";
      end if;
   end Read_Network;

   function Buffered_Frame_Ready (Buffer : US.Unbounded_String) return Boolean
   is
      Bytes          : constant String := US.To_String (Buffer);
      First_Byte     : Interfaces.Unsigned_8;
      Second_Byte    : Interfaces.Unsigned_8;
      Opcode         : Natural;
      Payload_Code   : Natural;
      Payload_Length : Interfaces.Unsigned_64;
      Header_Length  : Natural := 2;
      use type Interfaces.Unsigned_64;
   begin
      if Bytes'Length < 2 then
         return False;
      end if;
      First_Byte :=
        Interfaces.Unsigned_8 (Character'Pos (Bytes (Bytes'First)));
      Second_Byte :=
        Interfaces.Unsigned_8 (Character'Pos (Bytes (Bytes'First + 1)));
      Opcode := Natural (First_Byte and 16#0F#);
      if (First_Byte and 16#70#) /= 0
        or else (Second_Byte and 16#80#) /= 0
        or else Opcode in 3 .. 7
        or else Opcode > 10
        or else (Opcode >= 8
                 and then ((First_Byte and 16#80#) = 0
                           or else (Second_Byte and 16#7F#) > 125))
      then
         return True;
      end if;
      Payload_Code := Character'Pos (Bytes (Bytes'First + 1)) mod 128;
      Payload_Length := Interfaces.Unsigned_64 (Payload_Code);
      if Payload_Code = 126 then
         if Bytes'Length < 4 then
            return False;
         end if;
         Payload_Length :=
           Interfaces.Unsigned_64
             (Character'Pos (Bytes (Bytes'First + 2))
              * 256
              + Character'Pos (Bytes (Bytes'First + 3)));
         Header_Length := 4;
         if Payload_Length < 126 then
            return True;
         end if;
      elsif Payload_Code = 127 then
         if Bytes'Length < 10 then
            return False;
         end if;
         if Character'Pos (Bytes (Bytes'First + 2)) >= 128 then
            return True;
         end if;
         Payload_Length := 0;
         for I in 2 .. 9 loop
            Payload_Length :=
              Payload_Length
              * 256
              + Interfaces.Unsigned_64
                  (Character'Pos (Bytes (Bytes'First + I)));
         end loop;
         Header_Length := 10;
         if Payload_Length <= 65_535 then
            return True;
         end if;
      end if;
      if Payload_Length > Interfaces.Unsigned_64 (Max_Message_Bytes)
        or else Payload_Length > Interfaces.Unsigned_64 (Natural'Last)
      then
         -- Let Poll reject the header now. Waiting for the advertised body
         -- would let a peer hold the owner forever with only ten bytes.
         return True;
      end if;
      return Bytes'Length - Header_Length >= Natural (Payload_Length);
   end Buffered_Frame_Ready;

   function Header_Value (Headers, Name : String) return String is
      Lower_Headers : constant String :=
        Ada.Characters.Handling.To_Lower (Headers);
      Needle        : constant String :=
        Ada.Characters.Handling.To_Lower (Name) & ":";
      Start         : Natural := Headers'First;
   begin
      loop
         declare
            Stop : constant Natural :=
              Ada.Strings.Fixed.Index (Headers, ASCII.CR & ASCII.LF, Start);
            Last : constant Natural :=
              (if Stop = 0 then Headers'Last else Stop - 1);
            Line : constant String := Lower_Headers (Start .. Last);
         begin
            if Line'Length >= Needle'Length
              and then Line (Line'First .. Line'First + Needle'Length - 1)
                       = Needle
            then
               declare
                  First : Natural := Start + Needle'Length;
               begin
                  while First <= Last
                    and then Headers (First) in ' ' | ASCII.HT
                  loop
                     First := First + 1;
                  end loop;
                  return Headers (First .. Last);
               end;
            end if;
            exit when Stop = 0;
            Start := Stop + 2;
         end;
      end loop;
      return "";
   end Header_Value;

   function Header_Has_Token (Value, Token : String) return Boolean is
      Lower  : constant String := Ada.Characters.Handling.To_Lower (Value);
      Wanted : constant String := Ada.Characters.Handling.To_Lower (Token);
      First  : Natural := Lower'First;
   begin
      loop
         declare
            Comma : constant Natural :=
              Ada.Strings.Fixed.Index (Lower, ",", First);
            Last  : constant Natural :=
              (if Comma = 0 then Lower'Last else Comma - 1);
            Item  : constant String :=
              Ada.Strings.Fixed.Trim (Lower (First .. Last), Ada.Strings.Both);
         begin
            if Item = Wanted then
               return True;
            end if;
            exit when Comma = 0;
            First := Comma + 1;
         end;
      end loop;
      return False;
   end Header_Has_Token;

   procedure Open (Socket : in out Connection; Deployment_URL : String) is
      Parsed    : constant AWS.URL.Object := AWS.URL.Parse (Deployment_URL);
      Host      : constant String := AWS.URL.Host (Parsed);
      Port      : constant Positive := AWS.URL.Port (Parsed);
      Secure    : constant Boolean := AWS.URL.Security (Parsed);
      Base_Path : constant String := AWS.URL.Pathname_And_Parameters (Parsed);
      Path      : constant String :=
        (if Base_Path = "/"
         then "/api/sync"
         elsif Base_Path (Base_Path'Last) = '/'
         then Base_Path (Base_Path'First .. Base_Path'Last - 1) & "/api/sync"
         else Base_Path & "/api/sync");
      Key_Data  : Stream_Element_Array (1 .. 16);
      Deadline  : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0);
   begin
      Shutdown (Socket);
      if Deployment_URL'Length < 8
        or else (Deployment_URL
                   (Deployment_URL'First .. Deployment_URL'First + 6)
                 /= "http://"
                 and then (Deployment_URL'Length < 9
                           or else Deployment_URL
                                     (Deployment_URL'First
                                      .. Deployment_URL'First + 7)
                                   /= "https://"))
        or else Ada.Strings.Fixed.Index (Deployment_URL, "?") > 0
        or else Ada.Strings.Fixed.Index (Deployment_URL, "#") > 0
        or else Ada.Strings.Fixed.Index (Deployment_URL, "@") > 0
      then
         raise Constraint_Error
           with
             "deployment URL must be absolute http(s) without userinfo, query, or fragment";
      end if;
      for I in Key_Data'Range loop
         Key_Data (I) := Stream_Element (Next_Mask (Socket) and 16#FF#);
      end loop;
      declare
         Key      : constant String := Encode_Base64 (Key_Data);
         Request  : constant String :=
           "GET "
           & Path
           & " HTTP/1.1"
           & ASCII.CR
           & ASCII.LF
           & "Host: "
           & Host
           & AWS.URL.Port_Not_Default (Parsed)
           & ASCII.CR
           & ASCII.LF
           & "Upgrade: websocket"
           & ASCII.CR
           & ASCII.LF
           & "Connection: Upgrade"
           & ASCII.CR
           & ASCII.LF
           & "Sec-WebSocket-Key: "
           & Key
           & ASCII.CR
           & ASCII.LF
           & "Sec-WebSocket-Version: 13"
           & ASCII.CR
           & ASCII.LF
           & "Convex-Client: ada-0.1.0"
           & ASCII.CR
           & ASCII.LF
           & ASCII.CR
           & ASCII.LF;
         Digest   : constant GNAT.SHA1.Binary_Message_Digest :=
           GNAT.SHA1.Digest (Key & WebSocket_GUID);
         Expected : constant String := Encode_Base64 (Digest);
      begin
         Socket.Net := AWS.Net.Socket (Security => Secure);
         AWS.Net.Set_Timeout (Socket.Net.all, 2.0);
         Socket.Net.Connect (Host, Port);
         declare
            Bytes : Stream_Element_Array (1 .. Request'Length);
         begin
            for I in Request'Range loop
               Bytes (Stream_Element_Offset (I - Request'First + 1)) :=
                 Stream_Element (Character'Pos (Request (I)));
            end loop;
            AWS.Net.Send (Socket.Net.all, Bytes);
         end;
         loop
            if Ada.Real_Time.Clock >= Deadline then
               raise AWS.Net.Socket_Error with "WebSocket upgrade timed out";
            end if;
            Read_Network
              (Socket,
               Duration'Max
                 (0.001,
                  Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock)));
            declare
               Raw    : constant String := US.To_String (Socket.Buffer);
               End_At : constant Natural :=
                 Ada.Strings.Fixed.Index
                   (Raw, ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF);
            begin
               if End_At > 0 then
                  if End_At + 4 > Max_Handshake_Bytes then
                     raise AWS.Net.Socket_Error
                       with "WebSocket upgrade response is too large";
                  end if;
                  declare
                     Headers          : constant String :=
                       Raw (Raw'First .. End_At + 1);
                     Status_End       : constant Natural :=
                       Ada.Strings.Fixed.Index (Headers, ASCII.CR & ASCII.LF);
                     Status_Line      : constant String :=
                       Headers (Headers'First .. Status_End - 1);
                     Remaining        : constant String :=
                       (if End_At + 4 <= Raw'Last
                        then Raw (End_At + 4 .. Raw'Last)
                        else "");
                     Lower_Upgrade    : constant String :=
                       Ada.Characters.Handling.To_Lower
                         (Header_Value (Headers, "Upgrade"));
                     Lower_Connection : constant String :=
                       Ada.Characters.Handling.To_Lower
                         (Header_Value (Headers, "Connection"));
                  begin
                     if Status_Line'Length < 12
                       or else Status_Line
                                 (Status_Line'First .. Status_Line'First + 11)
                               /= "HTTP/1.1 101"
                       or else (Status_Line'Length > 12
                                and then Status_Line (Status_Line'First + 12)
                                         /= ' ')
                       or else Lower_Upgrade /= "websocket"
                       or else not Header_Has_Token
                                     (Lower_Connection, "upgrade")
                       or else Header_Value (Headers, "Sec-WebSocket-Accept")
                               /= Expected
                     then
                        raise AWS.Net.Socket_Error
                          with "invalid WebSocket upgrade response";
                     end if;
                     Socket.Buffer := US.To_Unbounded_String (Remaining);
                     Socket.Fragment := US.Null_Unbounded_String;
                     Socket.Fragmented := False;
                     Socket.Opened := True;
                     return;
                  end;
               end if;
               if Raw'Length > Max_Handshake_Bytes then
                  raise AWS.Net.Socket_Error
                    with "WebSocket upgrade response is too large";
               end if;
            end;
         end loop;
      end;
   exception
      when others =>
         Shutdown (Socket);
         raise;
   end Open;

   procedure Poll
     (Socket : in out Connection; Timeout : Duration; Item : out Event)
   is
      Raw            : US.Unbounded_String;
      Fin, Masked    : Boolean;
      Opcode         : Natural;
      Payload_Length : Long_Long_Integer;
      Header_Length  : Natural;
   begin
      Item := (Kind => No_Event, Data => US.Null_Unbounded_String);
      if not Socket.Opened or else Socket.Net = null then
         return;
      end if;
      if not Buffered_Frame_Ready (Socket.Buffer) then
         Read_Network (Socket, Timeout);
      end if;
      Raw := Socket.Buffer;
      if US.Length (Raw) < 2 then
         return;
      end if;
      declare
         Bytes : constant String := US.To_String (Raw);
         B1    : constant Interfaces.Unsigned_8 :=
           Interfaces.Unsigned_8 (Character'Pos (Bytes (Bytes'First)));
         B2    : constant Interfaces.Unsigned_8 :=
           Interfaces.Unsigned_8 (Character'Pos (Bytes (Bytes'First + 1)));
      begin
         Fin := (B1 and 16#80#) /= 0;
         Opcode := Natural (B1 and 16#0F#);
         Masked := (B2 and 16#80#) /= 0;
         if (B1 and 16#70#) /= 0 or else Masked then
            raise Constraint_Error with "invalid server WebSocket frame flags";
         end if;
         if Opcode in 3 .. 7 or else Opcode > 10 then
            raise Constraint_Error with "unknown WebSocket opcode";
         end if;
         Payload_Length := Long_Long_Integer (B2 and 16#7F#);
         Header_Length := 2;
         if Opcode >= 8 and then (not Fin or else Payload_Length > 125) then
            raise Constraint_Error
              with "invalid fragmented WebSocket control frame";
         end if;
         if Payload_Length = 126 then
            if Bytes'Length < 4 then
               return;
            end if;
            Payload_Length :=
              Long_Long_Integer
                (Character'Pos (Bytes (Bytes'First + 2))
                 * 256
                 + Character'Pos (Bytes (Bytes'First + 3)));
            if Payload_Length < 126 then
               raise Constraint_Error with "non-canonical WebSocket length";
            end if;
            Header_Length := 4;
         elsif Payload_Length = 127 then
            if Bytes'Length < 10 then
               return;
            end if;
            Payload_Length := 0;
            if Character'Pos (Bytes (Bytes'First + 2)) >= 128 then
               raise Constraint_Error
                 with "WebSocket length exceeds signed range";
            end if;
            for I in 2 .. 9 loop
               Payload_Length :=
                 Payload_Length
                 * 256
                 + Long_Long_Integer (Character'Pos (Bytes (Bytes'First + I)));
            end loop;
            if Payload_Length <= 65_535 then
               raise Constraint_Error with "non-canonical WebSocket length";
            end if;
            Header_Length := 10;
         end if;
         if Payload_Length > Max_Message_Bytes
           or else Payload_Length > Long_Long_Integer (Natural'Last)
         then
            raise Constraint_Error with "WebSocket frame exceeds 4 MiB";
         end if;
         if Bytes'Length < Header_Length + Natural (Payload_Length) then
            return;
         end if;
         declare
            First    : constant Natural := Bytes'First + Header_Length;
            Last     : constant Natural :=
              First + Natural (Payload_Length) - 1;
            Payload  : constant String :=
              (if Payload_Length = 0 then "" else Bytes (First .. Last));
            Consumed : constant Natural :=
              Header_Length + Natural (Payload_Length);
         begin
            Socket.Buffer :=
              US.To_Unbounded_String
                (if Consumed < Bytes'Length
                 then Bytes (Bytes'First + Consumed .. Bytes'Last)
                 else "");
            case Opcode is
               when 0      =>
                  if not Socket.Fragmented then
                     raise Constraint_Error
                       with "unexpected WebSocket continuation";
                  end if;
                  if Payload'Length
                    > Max_Message_Bytes - US.Length (Socket.Fragment)
                  then
                     raise Constraint_Error
                       with "fragmented message exceeds 4 MiB";
                  end if;
                  US.Append (Socket.Fragment, Payload);
                  if Fin then
                     declare
                        Message : constant String :=
                          US.To_String (Socket.Fragment);
                     begin
                        Socket.Fragmented := False;
                        Socket.Fragment := US.Null_Unbounded_String;
                        if not Valid_UTF8 (Message) then
                           raise Constraint_Error
                             with "invalid UTF-8 WebSocket text";
                        end if;
                        Item :=
                          (Text_Message, US.To_Unbounded_String (Message));
                     end;
                  end if;

               when 1      =>
                  if Socket.Fragmented then
                     raise Constraint_Error
                       with "new data frame during fragmentation";
                  end if;
                  if Fin then
                     if not Valid_UTF8 (Payload) then
                        raise Constraint_Error
                          with "invalid UTF-8 WebSocket text";
                     end if;
                     Item := (Text_Message, US.To_Unbounded_String (Payload));
                  else
                     Socket.Fragmented := True;
                     Socket.Fragment := US.To_Unbounded_String (Payload);
                  end if;

               when 2      =>
                  raise Constraint_Error
                    with "binary WebSocket message is unsupported";

               when 8      =>
                  if Payload'Length = 1
                    or else not Valid_Close_Code (Payload)
                    or else not Valid_UTF8
                                  (if Payload'Length > 2
                                   then
                                     Payload
                                       (Payload'First + 2 .. Payload'Last)
                                   else "")
                  then
                     raise Constraint_Error
                       with "invalid WebSocket close payload";
                  end if;
                  Item :=
                    (Peer_Close,
                     US.To_Unbounded_String
                       (if Payload'Length > 2
                        then Payload (Payload'First + 2 .. Payload'Last)
                        else ""));
                  Shutdown (Socket);

               when 9      =>
                  Send_Frame (Socket, 10, Payload);
                  Item := (Control_Traffic, US.Null_Unbounded_String);

               when 10     =>
                  Item := (Control_Traffic, US.Null_Unbounded_String);

               when others =>
                  raise Constraint_Error with "unknown WebSocket opcode";
            end case;
         end;
      end;
   exception
      when E : Constraint_Error =>
         Item :=
           (Protocol_Failure,
            US.To_Unbounded_String (Ada.Exceptions.Exception_Message (E)));
         Shutdown (Socket);
      when E : others =>
         Item :=
           (Transport_Failure,
            US.To_Unbounded_String (Ada.Exceptions.Exception_Message (E)));
         Shutdown (Socket);
   end Poll;

   procedure Shutdown (Socket : in out Connection) is
      Ignored : Interfaces.C.int;
      pragma Unreferenced (Ignored);
   begin
      if Socket.Net /= null then
         if Socket.Opened then
            begin
               Send_Frame (Socket, 8, "");
            exception
               when others =>
                  null;
            end;
         end if;
         -- AWS's graceful TLS shutdown can wait forever when the peer keeps
         -- speaking. Retire the descriptor first so close, unsubscribe and
         -- debugDisconnect are owner-command barriers with a hard bound.
         Ignored :=
           C_Shutdown
             (Interfaces.C.int (Socket.Net.Get_FD), Interfaces.C.int (2));
         begin
            Socket.Net.Shutdown;
         exception
            when others =>
               null;
         end;
         AWS.Net.Free (Socket.Net);
      end if;
      Socket.Opened := False;
      Socket.Buffer := US.Null_Unbounded_String;
      Socket.Fragment := US.Null_Unbounded_String;
      Socket.Fragmented := False;
   end Shutdown;

   function Is_Open (Socket : Connection) return Boolean
   is (Socket.Opened);
begin
   -- Match the HTTP client setup. AWS's stock client certificate name is a
   -- server-demo default and must not turn into a runtime cert.pem dependency.
   AWS.Net.SSL.Initialize_Default_Config
     (Security_Mode        => AWS.Net.SSL.TLS,
      Client_Certificate   => "",
      Exchange_Certificate => False,
      Check_Certificate    => True,
      Trusted_CA_Filename  => "/etc/ssl/certs/ca-certificates.crt");
end Convex_WebSocket;
