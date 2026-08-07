with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Convex;
with GNAT.Sockets;
with GNATCOLL.JSON;

--  Hostname verification, proved separately from chain verification.
--
--  The peer for these tests is convex_tls_fixture, which mints one ephemeral
--  CA and two leaves for it at test time: one named localhost and one named
--  wrong.invalid. The Docker test stage installs that CA as the only trusted
--  anchor while these tests run. Because both leaves share an issuer, the
--  only difference between the two connections below is the name in the
--  certificate, so accepting the first and refusing the second is evidence
--  about the name check specifically.
procedure Convex_TLS_Tests is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;

   use type Ada.Streams.Stream_Element_Offset;
   use type Convex.Error_Kind;
   use type GNAT.Sockets.Socket_Type;
   use type JSON.JSON_Value_Type;

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

   function Required_Port (Name : String) return Natural is
   begin
      if not Ada.Environment_Variables.Exists (Name) then
         raise Constraint_Error with Name & " is required";
      end if;
      return Natural'Value (Ada.Environment_Variables.Value (Name));
   end Required_Port;

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
         exit when Last < Ada.Streams.Stream_Element_Offset (Sent + 1);
         Sent := Natural (Last);
      end loop;
   end Send_All;

   --  A plaintext peer for the recovery assertion. A failed TLS handshake
   --  must leave no process-wide OpenSSL residue behind it.
   task type Plain_Server is
      entry Start (Listener : GNAT.Sockets.Socket_Type);
      entry Finish (Success : out Boolean; Message : out US.Unbounded_String);
   end Plain_Server;

   task body Plain_Server is
      Listen  : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Peer    : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Passed  : Boolean := False;
      Error   : US.Unbounded_String;
      Address : GNAT.Sockets.Sock_Addr_Type;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 4 * 1024);
      Last    : Ada.Streams.Stream_Element_Offset;
      Text    : US.Unbounded_String;
   begin
      accept Start (Listener : GNAT.Sockets.Socket_Type) do
         Listen := Listener;
      end Start;
      begin
         GNAT.Sockets.Accept_Socket (Listen, Peer, Address);
         loop
            GNAT.Sockets.Receive_Socket (Peer, Data, Last);
            exit when Last < Data'First;
            for I in Data'First .. Last loop
               US.Append (Text, Character'Val (Data (I)));
            end loop;
            exit when
              Ada.Strings.Fixed.Index
                (US.To_String (Text),
                 ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF)
              > 0;
         end loop;
         declare
            Envelope : constant String :=
              "{""status"":""success"",""value"":12}";
         begin
            Send_All
              (Peer,
               "HTTP/1.1 200 OK"
               & ASCII.CR
               & ASCII.LF
               & "Content-Type: application/json"
               & ASCII.CR
               & ASCII.LF
               & "Content-Length: "
               & Image (Envelope'Length)
               & ASCII.CR
               & ASCII.LF
               & "Connection: close"
               & ASCII.CR
               & ASCII.LF
               & ASCII.CR
               & ASCII.LF
               & Envelope);
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
   end Plain_Server;

   --  Every call below is wrapped so that a broken deadline fails loudly
   --  instead of hanging the build.
   procedure Bounded_Query
     (Deployment_URL : String;
      Path           : String;
      Result         : out Convex.Call_Result;
      Label          : String)
   is
      Client : Convex.Client;
      Args   : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      Result := (Success => False, Error => <>);
      Convex.Open (Client, Deployment_URL);
      select
         delay 20.0;
         Check (False, Label & " never returned");
      then abort
         Result := Convex.Query (Client, Path, Args);
      end select;
      Convex.Close (Client);
   exception
      when others =>
         Convex.Close (Client);
         raise;
   end Bounded_Query;

   Matching_Port   : constant Natural := Required_Port ("CONVEX_TLS_PORT");
   Mismatched_Port : constant Natural :=
     Required_Port ("CONVEX_TLS_WRONG_HOST_PORT");
begin
   --  The trusted anchor is the ephemeral CA and nothing else, so a leaf it
   --  signed for the name actually dialled must complete an ordinary call.
   declare
      Result : Convex.Call_Result;
   begin
      Bounded_Query
        ("https://localhost:" & Image (Matching_Port),
         "messages:count",
         Result,
         "the trusted TLS call");
      if not Result.Success then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "tls: " & US.To_String (Result.Error.Message));
      end if;
      Check
        (Result.Success,
         "a certificate matching the dialled host was refused");
      Check
        (Result.Value.Kind = JSON.JSON_Int_Type
         and then Long_Long_Integer'(Result.Value.Get) = 11,
         "the trusted TLS call returned the wrong value");
   end;

   --  Same CA, same fixture, same code path. Only the certificate's name
   --  differs, and that alone has to end the call as a transport failure.
   declare
      Result : Convex.Call_Result;
   begin
      Bounded_Query
        ("https://localhost:" & Image (Mismatched_Port),
         "messages:count",
         Result,
         "the mismatched TLS call");
      Check
        (not Result.Success,
         "a certificate for wrong.invalid was accepted for localhost");
      Check
        (Result.Error.Kind = Convex.Transport_Error,
         "a hostname mismatch was not reported as a transport error");
      Check
        (US.Length (Result.Error.Message) > 0,
         "a hostname mismatch was reported without a reason");
      Ada.Text_IO.Put_Line
        ("tls: hostname mismatch rejected: "
         & US.To_String (Result.Error.Message));
   end;

   --  Recovery: the refused handshake must not stop the next ordinary call.
   declare
      Listener : GNAT.Sockets.Socket_Type;
      Address  : GNAT.Sockets.Sock_Addr_Type;
      Port     : GNAT.Sockets.Port_Type;
      Server   : Plain_Server;
      Result   : Convex.Call_Result;
      Success  : Boolean;
      Message  : US.Unbounded_String;
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
      Server.Start (Listener);
      begin
         Bounded_Query
           ("http://127.0.0.1:" & Image (Natural (Port)),
            "messages:count",
            Result,
            "the recovery call");
         Check
           (Result.Success
            and then Result.Value.Kind = JSON.JSON_Int_Type
            and then Long_Long_Integer'(Result.Value.Get) = 12,
            "the client did not recover after a refused certificate");
         Server.Finish (Success, Message);
         Check
           (Success, "TLS recovery fixture failed: " & US.To_String (Message));
      exception
         when others =>
            --  Releasing the fixture task matters more than the diagnostic:
            --  an unaborted server waiting for its rendezvous would turn a
            --  failed assertion into a hung test run.
            abort Server;
            raise;
      end;
   end;

   Ada.Text_IO.Put_Line ("Ada TLS hostname tests passed");
end Convex_TLS_Tests;
