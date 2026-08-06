with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Characters.Handling;
with Convex_URL;
with AWS.Net;
with AWS.Net.SSL;

package body Convex is
   use type JSON.JSON_Value_Type;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type AWS.Net.Socket_Access;

   Max_Response_Bytes : constant := 2 * 1024 * 1024;
   Max_JSON_Nodes     : constant := 65_536;
   Response_Too_Large : exception;

   procedure Validate_JSON_Bounds (Text : String) is
      Depth     : Natural := 0;
      Nodes     : Natural := 0;
      In_String : Boolean := False;
      Escaped   : Boolean := False;
   begin
      -- A byte cap alone does not bound parser memory for input such as a
      -- two-megabyte array of single-character values.
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
               raise Constraint_Error with "response JSON nesting exceeds 128";
            end if;
         elsif C = '}' or else C = ']' then
            if Depth = 0 then
               raise Constraint_Error
                 with "response JSON containers are unbalanced";
            end if;
            Depth := Depth - 1;
         elsif C = ',' then
            Nodes := Nodes + 1;
         end if;
         if Nodes > Max_JSON_Nodes then
            raise Constraint_Error
              with "response JSON exceeds 65536 structural nodes";
         end if;
      end loop;
      if In_String or else Depth /= 0 then
         raise Constraint_Error with "response JSON is incomplete";
      end if;
   end Validate_JSON_Bounds;

   function Read_Bounded_JSON (Text : String) return JSON.Read_Result is
   begin
      Validate_JSON_Bounds (Text);
      return JSON.Read (Text);
   end Read_Bounded_JSON;

   procedure Post_Bounded
     (URL     : String;
      Data    : String;
      Auth    : String;
      Payload : out US.Unbounded_String)
   is
      Parsed            : Convex_URL.Object;
      Port              : Positive;
      Secure            : Boolean;
      Path              : US.Unbounded_String;
      Socket            : AWS.Net.Socket_Access := null;
      Raw               : US.Unbounded_String;
      Body_Start        : Natural := 0;
      Body_Length       : Natural := 0;
      Has_Length        : Boolean := False;
      Chunked           : Boolean := False;
      Header_Done       : Boolean := False;
      Peer_Closed       : Boolean := False;
      Request_Deadline  : Ada.Real_Time.Time;
      Response_Deadline : Ada.Real_Time.Time;

      function Chunk_Size (Line : String) return Natural is
         Extension : constant Natural := Ada.Strings.Fixed.Index (Line, ";");
         Last      : constant Natural :=
           (if Extension = 0 then Line'Last else Extension - 1);
         Result    : Natural := 0;
         Digit     : Natural;
      begin
         if Last < Line'First then
            raise Constraint_Error with "empty HTTP chunk size";
         end if;
         for I in Line'First .. Last loop
            Digit :=
              (case Line (I) is
                 when '0' .. '9' =>
                   Character'Pos (Line (I)) - Character'Pos ('0'),
                 when 'a' .. 'f' =>
                   Character'Pos (Line (I)) - Character'Pos ('a') + 10,
                 when 'A' .. 'F' =>
                   Character'Pos (Line (I)) - Character'Pos ('A') + 10,
                 when others     =>
                   raise Constraint_Error with "invalid HTTP chunk size");
            if Result > (Max_Response_Bytes - Digit) / 16 then
               raise Response_Too_Large with "HTTP chunk exceeds 2 MiB";
            end if;
            Result := Result * 16 + Digit;
         end loop;
         return Result;
      end Chunk_Size;

      function Chunks_Complete (Text : String) return Boolean is
         Cursor : Natural := Body_Start;
         Total  : Natural := 0;
      begin
         loop
            if Cursor > Text'Last then
               return False;
            end if;
            declare
               Line_End : constant Natural :=
                 Ada.Strings.Fixed.Index (Text, ASCII.CR & ASCII.LF, Cursor);
            begin
               if Line_End = 0 then
                  return False;
               elsif Line_End - Cursor > 8 * 1_024 then
                  raise Constraint_Error with "HTTP chunk line exceeds 8 KiB";
               end if;
               declare
                  Size : constant Natural :=
                    Chunk_Size (Text (Cursor .. Line_End - 1));
               begin
                  Cursor := Line_End + 2;
                  if Size = 0 then
                     if Cursor + 1 > Text'Last then
                        return False;
                     elsif Text (Cursor .. Cursor + 1) = ASCII.CR & ASCII.LF
                     then
                        return True;
                     else
                        return
                          Ada.Strings.Fixed.Index
                            (Text,
                             ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF,
                             Cursor)
                          > 0;
                     end if;
                  end if;
                  if Total > Max_Response_Bytes - Size then
                     raise Response_Too_Large
                       with "chunked HTTP body exceeds 2 MiB";
                  end if;
                  Total := Total + Size;
                  if Cursor > Text'Last or else Size > Text'Last - Cursor + 1
                  then
                     return False;
                  end if;
                  Cursor := Cursor + Size;
                  if Cursor + 1 > Text'Last then
                     return False;
                  elsif Text (Cursor .. Cursor + 1) /= ASCII.CR & ASCII.LF then
                     raise Constraint_Error
                       with "HTTP chunk omitted its terminator";
                  end if;
                  Cursor := Cursor + 2;
               end;
            end;
         end loop;
      end Chunks_Complete;

      function Decode_Chunks (Text : String) return US.Unbounded_String is
         Cursor : Natural := Body_Start;
         Result : US.Unbounded_String;
      begin
         loop
            declare
               Line_End : constant Natural :=
                 Ada.Strings.Fixed.Index (Text, ASCII.CR & ASCII.LF, Cursor);
               Size     : constant Natural :=
                 Chunk_Size (Text (Cursor .. Line_End - 1));
            begin
               Cursor := Line_End + 2;
               exit when Size = 0;
               US.Append (Result, Text (Cursor .. Cursor + Size - 1));
               Cursor := Cursor + Size + 2;
            end;
         end loop;
         return Result;
      end Decode_Chunks;

      procedure Send_Text (Text : String; Deadline : Ada.Real_Time.Time) is
         Buffer : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      begin
         if Ada.Real_Time.Clock >= Deadline then
            raise AWS.Net.Socket_Error with "HTTP request timed out";
         end if;
         for I in Text'Range loop
            Buffer (Ada.Streams.Stream_Element_Offset (I - Text'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Text (I)));
         end loop;
         --  AWS.Net.Send owns the TLS-aware poll/write loop and creates one
         --  absolute deadline when this call begins. Supplying the complete
         --  request is deliberate: calling it once per 16 KiB chunk would
         --  restart that deadline and let a slow peer hold the client forever.
         AWS.Net.Set_Timeout
           (Socket.all,
            Duration'Max
              (0.001,
               Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock)));
         AWS.Net.Send (Socket.all, Buffer);
      end Send_Text;

      function Header_Value (Headers, Name : String) return String is
         Lower_Headers : constant String :=
           Ada.Characters.Handling.To_Lower (Headers);
         Needle        : constant String :=
           Ada.Characters.Handling.To_Lower (Name) & ":";
         First         : Natural := Headers'First;
      begin
         loop
            declare
               Stop : constant Natural :=
                 Ada.Strings.Fixed.Index (Headers, ASCII.CR & ASCII.LF, First);
               Last : constant Natural :=
                 (if Stop = 0 then Headers'Last else Stop - 1);
               Line : constant String := Lower_Headers (First .. Last);
            begin
               if Line'Length >= Needle'Length
                 and then Line (Line'First .. Line'First + Needle'Length - 1)
                          = Needle
               then
                  declare
                     Value_First : Natural := First + Needle'Length;
                  begin
                     while Value_First <= Last
                       and then Headers (Value_First) in ' ' | ASCII.HT
                     loop
                        Value_First := Value_First + 1;
                     end loop;
                     return Headers (Value_First .. Last);
                  end;
               end if;
               exit when Stop = 0;
               First := Stop + 2;
            end;
         end loop;
         return "";
      end Header_Value;

      procedure Close_Socket is
      begin
         if Socket /= null then
            begin
               Socket.all.Shutdown;
            exception
               when others =>
                  null;
            end;
            AWS.Net.Free (Socket);
         end if;
      end Close_Socket;
   begin
      Convex_URL.Parse (URL, Parsed);
      Port := Convex_URL.Port (Parsed);
      Secure := Convex_URL.Secure (Parsed);
      Path := US.To_Unbounded_String (Convex_URL.Path (Parsed));
      Payload := US.Null_Unbounded_String;
      Socket := AWS.Net.Socket (Security => Secure);
      Request_Deadline :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (5.0);
      AWS.Net.Set_Timeout
        (Socket.all,
         Ada.Real_Time.To_Duration (Request_Deadline - Ada.Real_Time.Clock));
      Socket.all.Connect (Convex_URL.Host (Parsed), Port);
      Send_Text
        ("POST "
         & US.To_String (Path)
         & " HTTP/1.1"
         & ASCII.CR
         & ASCII.LF
         & "Host: "
         & Convex_URL.Host_Header (Parsed)
         & Convex_URL.Port_Suffix (Parsed)
         & ASCII.CR
         & ASCII.LF
         & "Accept: application/json"
         & ASCII.CR
         & ASCII.LF
         & "Content-Type: application/json"
         & ASCII.CR
         & ASCII.LF
         & "Content-Length: "
         & Natural'Image (Data'Length)
         & ASCII.CR
         & ASCII.LF
         & "Connection: close"
         & ASCII.CR
         & ASCII.LF
         & "Convex-Client: ada-0.1.0"
         & ASCII.CR
         & ASCII.LF
         & (if Auth'Length > 0
            then "Authorization: Bearer " & Auth & ASCII.CR & ASCII.LF
            else "")
         & ASCII.CR
         & ASCII.LF
         & Data,
         Request_Deadline);
      --  Partial reads must not extend the operation forever. Every poll below
      --  consumes the same absolute five-second response budget.
      Response_Deadline :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (5.0);
      loop
         declare
            Events : AWS.Net.Event_Set := [others => False];
            Buffer : Ada.Streams.Stream_Element_Array (1 .. 16 * 1024);
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
            if Ada.Real_Time.Clock >= Response_Deadline then
               raise AWS.Net.Socket_Error with "HTTP response timed out";
            end if;
            Events :=
              AWS.Net.Poll
                (Socket.all,
                 [AWS.Net.Input => True, AWS.Net.Output => False],
                 Ada.Real_Time.To_Duration
                   (Response_Deadline - Ada.Real_Time.Clock));
            if not Events (AWS.Net.Input) then
               raise AWS.Net.Socket_Error with "HTTP response timed out";
            end if;
            begin
               Socket.all.Receive (Buffer, Last);
            exception
               when AWS.Net.Socket_Error =>
                  Peer_Closed := True;
                  Last := Buffer'First - 1;
            end;
            if not Peer_Closed then
               declare
                  Length : constant Natural :=
                    Natural (Last - Buffer'First + 1);
               begin
                  if US.Length (Raw) + Length > Max_Response_Bytes + 64 * 1024
                  then
                     raise Response_Too_Large
                       with "response exceeds bounded headers and 2 MiB body";
                  end if;
                  for I in Buffer'First .. Last loop
                     US.Append (Raw, Character'Val (Buffer (I)));
                  end loop;
               end;
            end if;
         end;
         declare
            Text   : constant String := US.To_String (Raw);
            End_At : constant Natural :=
              Ada.Strings.Fixed.Index
                (Text, ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF);
         begin
            if End_At > 0 and then not Header_Done then
               if End_At > 64 * 1024 then
                  raise Response_Too_Large
                    with "HTTP response headers exceed 64 KiB";
               end if;
               declare
                  Headers       : constant String :=
                    Text (Text'First .. End_At + 1);
                  Status_End    : constant Natural :=
                    Ada.Strings.Fixed.Index (Headers, ASCII.CR & ASCII.LF);
                  Status_Line   : constant String :=
                    Headers (Headers'First .. Status_End - 1);
                  Length_Text   : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Header_Value (Headers, "Content-Length"),
                       Ada.Strings.Both);
                  Transfer_Text : constant String :=
                    Ada.Characters.Handling.To_Lower
                      (Ada.Strings.Fixed.Trim
                         (Header_Value (Headers, "Transfer-Encoding"),
                          Ada.Strings.Both));
               begin
                  if Status_Line'Length < 12
                    or else Status_Line
                              (Status_Line'First .. Status_Line'First + 8)
                            /= "HTTP/1.1 "
                    or else Status_Line (Status_Line'First + 9)
                            not in '0' .. '9'
                    or else Status_Line (Status_Line'First + 10)
                            not in '0' .. '9'
                    or else Status_Line (Status_Line'First + 11)
                            not in '0' .. '9'
                    or else (Status_Line'Length > 12
                             and then Status_Line (Status_Line'First + 12)
                                      /= ' ')
                  then
                     raise Constraint_Error
                       with "invalid HTTP response status";
                  elsif Status_Line (Status_Line'First + 9) /= '2' then
                     raise AWS.Net.Socket_Error
                       with "HTTP response status was not successful";
                  end if;
                  if Length_Text'Length > 0 and then Transfer_Text'Length > 0
                  then
                     raise Constraint_Error
                       with "HTTP response mixed length and transfer encoding";
                  elsif Transfer_Text'Length > 0 then
                     if Transfer_Text /= "chunked" then
                        raise Constraint_Error
                          with "unsupported HTTP transfer encoding";
                     end if;
                     Chunked := True;
                  elsif Length_Text'Length > 0 then
                     Body_Length := Natural'Value (Length_Text);
                     if Body_Length > Max_Response_Bytes then
                        raise Response_Too_Large
                          with "HTTP response body exceeds 2 MiB";
                     end if;
                     Has_Length := True;
                  end if;
                  Body_Start := End_At + 4;
                  Header_Done := True;
               end;
            end if;
            exit when
              Header_Done
              and then (if Chunked
                        then Chunks_Complete (Text)
                        elsif Has_Length
                        then Text'Length - Body_Start + 1 >= Body_Length
                        else Peer_Closed);
            if Peer_Closed then
               if not Header_Done then
                  raise AWS.Net.Socket_Error
                    with "HTTP response omitted headers";
               elsif Chunked then
                  raise AWS.Net.Socket_Error
                    with "chunked HTTP response ended early";
               elsif Has_Length then
                  raise AWS.Net.Socket_Error
                    with "HTTP response ended before Content-Length";
               else
                  exit;
               end if;
            end if;
         end;
      end loop;
      declare
         Text : constant String := US.To_String (Raw);
      begin
         if not Header_Done then
            raise AWS.Net.Socket_Error with "HTTP response omitted headers";
         end if;
         if Has_Length and then Text'Length - Body_Start + 1 < Body_Length then
            raise AWS.Net.Socket_Error
              with "HTTP response ended before Content-Length";
         end if;
         if Chunked then
            Payload := Decode_Chunks (Text);
         elsif Has_Length and then Body_Length = 0 then
            Payload := US.Null_Unbounded_String;
         elsif Has_Length then
            Payload :=
              US.To_Unbounded_String
                (Text (Body_Start .. Body_Start + Body_Length - 1));
         elsif Body_Start <= Text'Last then
            Payload := US.To_Unbounded_String (Text (Body_Start .. Text'Last));
         end if;
      end;
      Close_Socket;
   exception
      when others =>
         Close_Socket;
         raise;
   end Post_Bounded;

   function Failure
     (Kind     : Error_Kind;
      Message  : String;
      Has_Data : Boolean := False;
      Data     : JSON.JSON_Value := JSON.JSON_Null;
      Logs     : JSON.JSON_Array := JSON.Empty_Array) return Call_Result is
   begin
      return
        (Success => False,
         Error   =>
           (Kind     => Kind,
            Message  => US.To_Unbounded_String (Message),
            Has_Data => Has_Data,
            Data     => Data,
            Logs     => Logs));
   end Failure;

   function Required_String
     (Value : JSON.JSON_Value; Field : String) return String
   is
      Item : constant JSON.JSON_Value := Value.Get (Field);
   begin
      if Item.Kind /= JSON.JSON_String_Type then
         raise Constraint_Error with "field " & Field & " must be a string";
      end if;
      return Item.Get;
   end Required_String;

   function Optional_Logs (Value : JSON.JSON_Value) return JSON.JSON_Array is
   begin
      if Value.Has_Field ("logLines") then
         declare
            Item : constant JSON.JSON_Value := Value.Get ("logLines");
         begin
            if Item.Kind /= JSON.JSON_Array_Type then
               raise Constraint_Error with "logLines must be an array";
            end if;
            declare
               Logs : constant JSON.JSON_Array := Item.Get;
            begin
               for I in 1 .. JSON.Length (Logs) loop
                  if JSON.Get (Logs, I).Kind /= JSON.JSON_String_Type then
                     raise Constraint_Error
                       with "logLines entries must be strings";
                  end if;
               end loop;
               return Logs;
            end;
         end;
      end if;
      return JSON.Empty_Array;
   end Optional_Logs;

   function Call
     (C         : in out Client;
      Operation : String;
      Path      : String;
      Args      : JSON.JSON_Value) return Call_Result
   is
      Envelope : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      if not C.Opened then
         return Failure (Closed_Error, "Convex client is closed");
      end if;
      if Path'Length < 3 or else Args.Kind /= JSON.JSON_Object_Type then
         return
           Failure
             (Protocol_Error,
              "function path and object arguments are required");
      end if;

      Envelope.Set_Field ("path", Path);
      Envelope.Set_Field ("args", Args);
      Envelope.Set_Field ("format", "json");

      declare
         Payload : US.Unbounded_String;
      begin
         Post_Bounded
           (US.To_String (C.URL) & "/api/" & Operation,
            JSON.Write (Envelope),
            (if US.Length (C.Auth) > 0 then US.To_String (C.Auth) else ""),
            Payload);
         declare
            Payload_Text : constant String := US.To_String (Payload);
            Parsed       : constant JSON.Read_Result :=
              Read_Bounded_JSON (Payload_Text);
         begin
            if not Parsed.Success then
               return
                 Failure
                   (Transport_Error,
                    "non-Convex response: "
                    & JSON.Format_Parsing_Error (Parsed.Error));
            end if;
            if Parsed.Value.Kind /= JSON.JSON_Object_Type
              or else not Parsed.Value.Has_Field ("status")
            then
               return Failure (Protocol_Error, "response omitted status");
            end if;

            declare
               Status : constant String :=
                 Required_String (Parsed.Value, "status");
               Logs   : constant JSON.JSON_Array :=
                 Optional_Logs (Parsed.Value);
            begin
               if Status = "success" then
                  if not Parsed.Value.Has_Field ("value") then
                     return
                       Failure
                         (Protocol_Error,
                          "successful response omitted value",
                          Logs => Logs);
                  end if;
                  return
                    (Success => True,
                     Value   => Parsed.Value.Get ("value"),
                     Logs    => Logs);
               elsif Status = "error" then
                  declare
                     Message  : constant String :=
                       (if Parsed.Value.Has_Field ("errorMessage")
                        then Required_String (Parsed.Value, "errorMessage")
                        else "Convex function failed");
                     Has_Data : constant Boolean :=
                       Parsed.Value.Has_Field ("errorData");
                     Data     : constant JSON.JSON_Value :=
                       (if Has_Data
                        then Parsed.Value.Get ("errorData")
                        else JSON.JSON_Null);
                  begin
                     return
                       Failure (Function_Error, Message, Has_Data, Data, Logs);
                  end;
               else
                  return
                    Failure
                      (Protocol_Error,
                       "unknown response status",
                       Logs => Logs);
               end if;
            end;
         end;
      end;
   exception
      when E : Response_Too_Large =>
         return
           Failure
             (Transport_Error,
              Operation & ": " & Ada.Exceptions.Exception_Message (E));
      when E : Constraint_Error =>
         return
           Failure
             (Protocol_Error,
              Operation
              & ": invalid response: "
              & Ada.Exceptions.Exception_Message (E));
      when E : others =>
         return
           Failure
             (Transport_Error,
              Operation & ": " & Ada.Exceptions.Exception_Message (E));
   end Call;

   procedure Open (C : in out Client; Deployment_URL : String) is
      Last : Natural := Deployment_URL'Last;
   begin
      if Deployment_URL'Length < 8
        or else (Deployment_URL
                   (Deployment_URL'First .. Deployment_URL'First + 6)
                 /= "http://"
                 and then (Deployment_URL'Length < 9
                           or else Deployment_URL
                                     (Deployment_URL'First
                                      .. Deployment_URL'First + 7)
                                   /= "https://"))
      then
         raise Constraint_Error with "deployment URL must be absolute http(s)";
      end if;
      if Ada.Strings.Fixed.Index (Deployment_URL, "?") > 0
        or else Ada.Strings.Fixed.Index (Deployment_URL, "#") > 0
        or else Ada.Strings.Fixed.Index (Deployment_URL, "@") > 0
      then
         raise Constraint_Error
           with "deployment URL must not contain userinfo, query, or fragment";
      end if;
      while Last >= Deployment_URL'First and then Deployment_URL (Last) = '/'
      loop
         Last := Last - 1;
      end loop;
      C.URL :=
        US.To_Unbounded_String (Deployment_URL (Deployment_URL'First .. Last));
      declare
         Parsed : Convex_URL.Object;
      begin
         Convex_URL.Parse (US.To_String (C.URL), Parsed);
      end;
      C.Auth := US.Null_Unbounded_String;
      C.Opened := True;
   end Open;

   procedure Set_Auth (C : in out Client; Token : String) is
   begin
      if not C.Opened then
         raise Constraint_Error with "Convex client is closed";
      end if;
      C.Auth := US.To_Unbounded_String (Token);
   end Set_Auth;

   procedure Close (C : in out Client) is
   begin
      C.Auth := US.Null_Unbounded_String;
      C.Opened := False;
   end Close;

   function Query
     (C : in out Client; Path : String; Args : JSON.JSON_Value)
      return Call_Result
   is (Call (C, "query", Path, Args));

   function Mutation
     (C : in out Client; Path : String; Args : JSON.JSON_Value)
      return Call_Result
   is (Call (C, "mutation", Path, Args));

   function Action
     (C : in out Client; Path : String; Args : JSON.JSON_Value)
      return Call_Result
   is (Call (C, "action", Path, Args));

   function Error_Name (Kind : Error_Kind) return String
   is (case Kind is
         when Function_Error  => "FunctionError",
         when Protocol_Error  => "ProtocolError",
         when Transport_Error => "TransportError",
         when Closed_Error    => "ClosedError");
begin
   -- AWS defaults its client certificate to cert.pem. Convex uses ordinary
   -- server-authenticated TLS, so clear that client credential while retaining
   -- CA and hostname verification before the first secure socket is created.
   AWS.Net.SSL.Initialize_Default_Config
     (Security_Mode        => AWS.Net.SSL.TLS,
      Client_Certificate   => "",
      Exchange_Certificate => False,
      Check_Certificate    => True,
      Trusted_CA_Filename  => "/etc/ssl/certs/ca-certificates.crt");
end Convex;
