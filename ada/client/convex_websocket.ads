with Ada.Streams;
with Ada.Strings.Unbounded;
with AWS.Net;
with Interfaces;

package Convex_WebSocket is
   package US renames Ada.Strings.Unbounded;

   Max_Message_Bytes : constant := 4 * 1024 * 1024;

   type Event_Kind is
     (No_Event,
      Text_Message,
      Control_Traffic,
      Peer_Close,
      Protocol_Failure,
      Transport_Failure);
   type Event is record
      Kind : Event_Kind := No_Event;
      Data : US.Unbounded_String;
   end record;

   type Connection is limited private;

   procedure Open (Socket : in out Connection; Deployment_URL : String);
   procedure Send_Text (Socket : in out Connection; Message : String);
   procedure Poll
     (Socket : in out Connection; Timeout : Duration; Item : out Event);
   procedure Shutdown (Socket : in out Connection);
   function Is_Open (Socket : Connection) return Boolean;

   function Encode_Base64
     (Data : Ada.Streams.Stream_Element_Array) return String;
   function Decode_Timestamp
     (Text : String; Value : out Interfaces.Unsigned_64) return Boolean;
   function Encode_Timestamp (Value : Interfaces.Unsigned_64) return String;
   function Valid_UTF8 (Text : String) return Boolean;

private
   type Connection is limited record
      Net        : AWS.Net.Socket_Access;
      Buffer     : US.Unbounded_String;
      Fragment   : US.Unbounded_String;
      Fragmented : Boolean := False;
      Opened     : Boolean := False;
   end record;
end Convex_WebSocket;
