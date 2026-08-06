with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with AWS.Client;
with AWS.Net.SSL;
with AWS.Response;
with AWS.URL;

package body Convex is
   use type JSON.JSON_Value_Type;
   use type Ada.Streams.Stream_Element_Offset;

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
      Headers : AWS.Client.Header_List;
      Payload : out US.Unbounded_String)
   is
      Connection : AWS.Client.HTTP_Connection;
      Response   : AWS.Response.Data;
      Buffer     : Ada.Streams.Stream_Element_Array (1 .. 16 * 1024);
      Last       : Ada.Streams.Stream_Element_Offset;
   begin
      Payload := US.Null_Unbounded_String;
      AWS.Client.Create
        (Connection,
         Host        => URL,
         Retry       => 0,
         Persistent  => False,
         Timeouts    => AWS.Client.Timeouts (Each => 5.0),
         Server_Push => True,
         User_Agent  => "convex-ada/0.1.0");
      AWS.Client.Post
        (Connection,
         Response,
         Data,
         Content_Type => "application/json",
         Headers      => Headers);
      loop
         AWS.Client.Read_Some (Connection, Buffer, Last);
         exit when Last < Buffer'First;
         declare
            Length : constant Natural := Natural (Last - Buffer'First + 1);
         begin
            if US.Length (Payload) + Length > Max_Response_Bytes then
               raise Response_Too_Large with "response exceeds 2 MiB";
            end if;
            for I in Buffer'First .. Last loop
               US.Append (Payload, Character'Val (Buffer (I)));
            end loop;
         end;
      end loop;
      AWS.Client.Close (Connection);
   exception
      when others =>
         AWS.Client.Close (Connection);
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
      Headers  : AWS.Client.Header_List;
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
      Headers.Add ("Accept", "application/json");
      Headers.Add ("Convex-Client", "ada-0.1.0");
      if US.Length (C.Auth) > 0 then
         Headers.Add ("Authorization", "Bearer " & US.To_String (C.Auth));
      end if;

      declare
         Payload : US.Unbounded_String;
      begin
         Post_Bounded
           (US.To_String (C.URL) & "/api/" & Operation,
            JSON.Write (Envelope),
            Headers,
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
         Parsed : constant AWS.URL.Object :=
           AWS.URL.Parse (US.To_String (C.URL));
      begin
         if AWS.URL.Host (Parsed)'Length = 0 then
            raise Constraint_Error with "deployment URL must include a host";
         end if;
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
