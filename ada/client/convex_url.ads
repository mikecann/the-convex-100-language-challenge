with Ada.Strings.Unbounded;

package Convex_URL is
   package US renames Ada.Strings.Unbounded;

   type Object is private;

   procedure Parse (Text : String; Result : out Object);
   function Parse (Text : String) return Object;
   function Host (Value : Object) return String;
   function Host_Header (Value : Object) return String;
   function Port (Value : Object) return Positive;
   function Secure (Value : Object) return Boolean;
   function Path (Value : Object) return String;
   function Port_Suffix (Value : Object) return String;

private
   type Object is record
      Host_Name : US.Unbounded_String;
      Path_Name : US.Unbounded_String;
      Port_No   : Positive := 80;
      Is_Secure : Boolean := False;
      Is_IPv6   : Boolean := False;
   end record;
end Convex_URL;
