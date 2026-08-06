with Ada.Streams;
with Ada.Text_IO;
with Convex_WebSocket;
with Interfaces;

procedure Convex_Tests is
   use type Interfaces.Unsigned_64;
   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   Value : Interfaces.Unsigned_64;
begin
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
