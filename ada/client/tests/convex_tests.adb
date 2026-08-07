with Ada.Streams;
with Ada.Text_IO;
with Convex;
with Convex_WebSocket;
with Convex_URL;
with GNATCOLL.JSON;
with Interfaces;

procedure Convex_Tests is
   package JSON renames GNATCOLL.JSON;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_32;
   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   --  The host and path of a deployment URL are interpolated into a request
   --  line and a Host header. Anything that survives parsing can appear
   --  verbatim in those headers, so rejection has to happen in the parser.
   procedure Check_Rejected_URL (Text, Message : String) is
      Parsed : Convex_URL.Object;
   begin
      Convex_URL.Parse (Text, Parsed);
      Check (False, "deployment URL was accepted: " & Message);
   exception
      when Constraint_Error =>
         null;
   end Check_Rejected_URL;

   procedure Check_Rejected_Token (Token, Message : String) is
      Client : Convex.Client;
   begin
      Convex.Open (Client, "http://127.0.0.1:1");
      begin
         Convex.Set_Auth (Client, Token);
         Convex.Close (Client);
         Check (False, "bearer token was accepted: " & Message);
      exception
         when Constraint_Error =>
            Convex.Close (Client);
      end;
   end Check_Rejected_Token;

   Value : Interfaces.Unsigned_64;
   U32   : Interfaces.Unsigned_32;
begin
   declare
      URL : constant Convex_URL.Object :=
        Convex_URL.Parse ("http://[::1]:8080/api");
   begin
      Check
        (Convex_URL.Host_Header (URL) & Convex_URL.Port_Suffix (URL)
         = "[::1]:8080",
         "custom-port IPv6 Host header");
   end;

   --  A CR or LF that reaches the request builder appends a header line of
   --  the URL author's choosing.
   Check_Rejected_URL
     ("http://example.test" & ASCII.CR & ASCII.LF & "X-Injected: yes/api",
      "CRLF in the authority");
   Check_Rejected_URL
     ("http://example.test/api" & ASCII.CR & ASCII.LF & "X-Injected: yes",
      "CRLF in the path");
   Check_Rejected_URL
     ("http://example.test/api" & ASCII.LF, "bare LF in the path");
   Check_Rejected_URL ("http://exam ple.test/api", "space in the authority");
   Check_Rejected_URL
     ("http://example.test/api" & Character'Val (0), "NUL in the path");
   Check_Rejected_URL
     ("http://example.test" & Character'Val (16#7F#) & "/api",
      "DEL in the authority");
   Check_Rejected_URL
     ("http://exa" & Character'Val (16#C3#) & "mple.test/api",
      "non-ASCII byte in the authority");
   Check_Rejected_URL ("http://example.test:8_080/api", "underscored port");
   Check_Rejected_URL ("http://example.test:+80/api", "signed port");
   Check_Rejected_URL ("http://exa|mple.test/api", "host with a bar");
   Check_Rejected_URL ("http://[::zz]:80/api", "IPv6 literal with non-hex");

   declare
      URL : constant Convex_URL.Object :=
        Convex_URL.Parse ("https://ada-demo.convex.cloud/api");
   begin
      Check
        (Convex_URL.Host (URL) = "ada-demo.convex.cloud"
         and then Convex_URL.Secure (URL)
         and then Convex_URL.Port (URL) = 443,
         "an ordinary deployment URL still parses");
   end;

   --  The bearer token lands directly in an Authorization header value.
   Check_Rejected_Token
     ("good" & ASCII.CR & ASCII.LF & "X-Injected: yes", "CRLF in the token");
   Check_Rejected_Token ("good" & ASCII.LF & "X-Injected: yes", "LF");
   Check_Rejected_Token ("good" & Character'Val (0), "NUL");
   Check_Rejected_Token ("good" & Character'Val (16#7F#), "DEL");
   Check_Rejected_Token ("good" & Character'Val (16#C3#), "non-ASCII byte");
   Check
     (Convex_WebSocket.Encode_Base64
        (Ada.Streams.Stream_Element_Array'
           [1 => 16#66#, 2 => 16#6F#, 3 => 16#6F#])
      = "Zm9v",
      "base64 encoding");
   Check
     (Convex_WebSocket.Decode_Timestamp ("/wAAAAAAAAA=", Value)
      and then Value = 255,
      "little-endian timestamp 255");
   Check
     (Convex_WebSocket.Decode_Timestamp ("AAEAAAAAAAA=", Value)
      and then Value = 256,
      "little-endian timestamp 256");
   Check
     (not Convex_WebSocket.Decode_Timestamp ("AAEAAAAAAAB=", Value),
      "non-canonical timestamp rejection");
   Check
     (Convex_WebSocket.Decode_UInt32 (JSON.Read ("4294967295").Value, U32)
      and then U32 = Interfaces.Unsigned_32'Last,
      "uint32 maximum");
   Check
     (not Convex_WebSocket.Decode_UInt32 (JSON.Read ("4294967296").Value, U32),
      "uint32 overflow rejection");
   Check
     (not Convex_WebSocket.Decode_UInt32 (JSON.Read ("-1").Value, U32),
      "negative uint32 rejection");
   Check
     (not Convex_WebSocket.Decode_UInt32 (JSON.Read ("1.0").Value, U32),
      "integral float uint32 rejection");
   Check
     (not Convex_WebSocket.Decode_UInt32 (JSON.Read ("1.5").Value, U32),
      "fractional uint32 rejection");
   Check
     (not Convex_WebSocket.Decode_UInt32 (JSON.Read ("""1""").Value, U32),
      "quoted uint32 rejection");
   Check
     (Convex_WebSocket.Valid_UTF8
        ("Hello, "
         & Character'Val (16#E9#)
         & Character'Val (16#9B#)
         & Character'Val (16#AA#)),
      "valid UTF-8");
   Check
     (not Convex_WebSocket.Valid_UTF8
            (Character'Val (16#C0#) & Character'Val (16#80#)),
      "overlong UTF-8 rejection");
   Ada.Text_IO.Put_Line ("Ada unit tests passed");
end Convex_Tests;
