with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with AWS.Net;
with GNATCOLL.JSON;
with Interfaces;

package Convex_WebSocket is
   package US renames Ada.Strings.Unbounded;

   Max_Message_Bytes : constant := 4 * 1024 * 1024;

   --  One connection attempt covers name resolution, the TCP connect, the TLS
   --  handshake, the upgrade request write, and the 101 response. Callers pass
   --  a single absolute deadline for all of it, and normally extend the same
   --  deadline over the first Convex Connect frame, so a peer that makes slow
   --  progress at every step still cannot hold the sole Live owner past it.
   Connect_Budget : constant Duration := 2.0;

   --  One complete outgoing frame, header and masked payload, shares one
   --  deadline. Renewing per chunk would let a slow reader stall the owner.
   Frame_Write_Budget : constant Duration := 0.5;

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

   procedure Open
     (Socket         : in out Connection;
      Deployment_URL : String;
      Deadline       : Ada.Real_Time.Time);
   procedure Open (Socket : in out Connection; Deployment_URL : String);

   procedure Send_Text
     (Socket   : in out Connection;
      Message  : String;
      Deadline : Ada.Real_Time.Time);
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
   function Decode_UInt32
     (Value : GNATCOLL.JSON.JSON_Value; Result : out Interfaces.Unsigned_32)
      return Boolean;
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
