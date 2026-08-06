with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;

procedure Convex_Adapter_Stopped_Reader is
   use type Ada.Streams.Stream_Element_Offset;

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
              with "adapter controller closed while sending commands";
         end if;
         Sent := Natural (Last);
      end loop;
   end Send_All;

   Host    : constant String :=
     Ada.Environment_Variables.Value ("ADAPTER_HOST");
   Port    : constant GNAT.Sockets.Port_Type :=
     GNAT.Sockets.Port_Type'Value
       (Ada.Environment_Variables.Value ("ADAPTER_PORT"));
   Socket  : GNAT.Sockets.Socket_Type;
   Address : GNAT.Sockets.Sock_Addr_Type;
begin
   GNAT.Sockets.Create_Socket (Socket);
   --  Lock the advertised TCP receive window before connect, then never read.
   --  This prevents Linux autotuning from hiding megabytes of adapter output.
   GNAT.Sockets.Set_Socket_Option
     (Socket,
      GNAT.Sockets.Socket_Level,
      (Name => GNAT.Sockets.Receive_Buffer, Size => 16 * 1024));
   Address.Addr :=
     GNAT.Sockets.Addresses (GNAT.Sockets.Get_Host_By_Name (Host), 1);
   Address.Port := Port;
   GNAT.Sockets.Connect_Socket (Socket, Address);
   Send_All
     (Socket,
      "{""protocolVersion"":1,""id"":""hello"",""op"":""hello""}"
      & ASCII.LF
      & "{""id"":""sub"",""op"":""subscribe"","
      & """subscriptionId"":""pressure"",""path"":""fixture:large"","
      & """args"":{}}"
      & ASCII.LF);
   Ada.Text_IO.Put_Line ("stopped reader active");
   Ada.Text_IO.Flush;
   delay 8.0;
   GNAT.Sockets.Close_Socket (Socket);
end Convex_Adapter_Stopped_Reader;
