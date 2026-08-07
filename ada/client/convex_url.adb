with Ada.Strings.Fixed;

package body Convex_URL is
   procedure Parse (Text : String; Result : out Object) is
      Scheme_End      : Natural;
      Authority_First : Natural;
      Authority_Last  : Natural;
      Path_First      : Natural;
      Host_First      : Natural;
      Host_Last       : Natural;
      Port_First      : Natural := 0;
      Closing_Bracket : Natural := 0;
      Secure_Scheme   : Boolean;
   begin
      Result.Is_IPv6 := False;
      --  The host and path below are interpolated straight into a request line
      --  and a Host header. A carriage return, line feed, NUL, or space here
      --  would let a deployment URL append request headers of its own, so
      --  reject them before any of this text reaches a header builder.
      for C of Text loop
         if C <= ' ' or else C >= Character'Val (16#7F#) then
            raise Constraint_Error
              with
                "deployment URL must not contain spaces, controls, "
                & "or non-ASCII bytes";
         end if;
      end loop;
      if Text'Length >= 8
        and then Text (Text'First .. Text'First + 7) = "https://"
      then
         Scheme_End := Text'First + 8;
         Secure_Scheme := True;
      elsif Text'Length >= 7
        and then Text (Text'First .. Text'First + 6) = "http://"
      then
         Scheme_End := Text'First + 7;
         Secure_Scheme := False;
      else
         raise Constraint_Error with "deployment URL must be absolute http(s)";
      end if;
      if Ada.Strings.Fixed.Index (Text, "?") > 0
        or else Ada.Strings.Fixed.Index (Text, "#") > 0
        or else Ada.Strings.Fixed.Index (Text, "@") > 0
      then
         raise Constraint_Error
           with "deployment URL must not contain userinfo, query, or fragment";
      end if;

      Authority_First := Scheme_End;
      Path_First := Ada.Strings.Fixed.Index (Text, "/", Scheme_End);
      if Path_First = 0 then
         Authority_Last := Text'Last;
         Path_First := Text'Last + 1;
      else
         Authority_Last := Path_First - 1;
      end if;
      if Authority_First > Authority_Last then
         raise Constraint_Error with "deployment URL must include a host";
      end if;

      if Text (Authority_First) = '[' then
         Result.Is_IPv6 := True;
         Host_First := Authority_First + 1;
         Closing_Bracket := Ada.Strings.Fixed.Index (Text, "]", Host_First);
         if Closing_Bracket = 0 then
            raise Constraint_Error with "invalid IPv6 host";
         end if;
         Host_Last := Closing_Bracket - 1;
         if Host_Last < Host_First then
            raise Constraint_Error with "invalid IPv6 host";
         end if;
         if Closing_Bracket < Authority_Last then
            if Text (Closing_Bracket + 1) /= ':' then
               raise Constraint_Error with "invalid host and port";
            end if;
            Port_First := Closing_Bracket + 2;
         end if;
      else
         Host_First := Authority_First;
         Host_Last := Authority_Last;
         for I in reverse Authority_First .. Authority_Last loop
            if Text (I) = ':' then
               Host_Last := I - 1;
               Port_First := I + 1;
               exit;
            end if;
         end loop;
      end if;
      if Host_First > Host_Last then
         raise Constraint_Error with "deployment URL must include a host";
      end if;
      --  Restrict the authority to characters a registered name or an IPv6
      --  literal may actually contain. This rejects ':' smuggled into a name,
      --  stray brackets, and anything else that would change how the Host
      --  header is later framed.
      for I in Host_First .. Host_Last loop
         if Result.Is_IPv6 then
            if Text (I) not in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | ':' | '.'
            then
               raise Constraint_Error with "invalid IPv6 host";
            end if;
         elsif Text (I)
               not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_'
         then
            raise Constraint_Error
              with "deployment URL host is not a registered name";
         end if;
      end loop;
      Result.Host_Name :=
        US.To_Unbounded_String (Text (Host_First .. Host_Last));
      Result.Path_Name :=
        US.To_Unbounded_String
          (if Path_First > Text'Last
           then "/"
           else Text (Path_First .. Text'Last));
      Result.Is_Secure := Secure_Scheme;
      Result.Port_No := (if Secure_Scheme then 443 else 80);
      if Port_First > 0 then
         if Port_First > Authority_Last then
            raise Constraint_Error with "host port is empty";
         end if;
         --  Positive'Value would silently accept "8_080" and a signed form.
         --  A port is a bare digit string or the authority is not what the
         --  caller thinks it is.
         if Authority_Last - Port_First + 1 > 5 then
            raise Constraint_Error with "host port is out of range";
         end if;
         for I in Port_First .. Authority_Last loop
            if Text (I) not in '0' .. '9' then
               raise Constraint_Error with "host port must be decimal digits";
            end if;
         end loop;
         Result.Port_No :=
           Positive'Value (Text (Port_First .. Authority_Last));
      end if;
   end Parse;

   function Parse (Text : String) return Object is
      Result : Object;
   begin
      Parse (Text, Result);
      return Result;
   end Parse;

   function Host (Value : Object) return String
   is (US.To_String (Value.Host_Name));

   function Host_Header (Value : Object) return String is
   begin
      return
        (if Value.Is_IPv6
         then "[" & US.To_String (Value.Host_Name) & "]"
         else US.To_String (Value.Host_Name));
   end Host_Header;

   function Port (Value : Object) return Positive
   is (Value.Port_No);

   function Secure (Value : Object) return Boolean
   is (Value.Is_Secure);

   function Path (Value : Object) return String
   is (US.To_String (Value.Path_Name));

   function Port_Suffix (Value : Object) return String is
      Port_Text : constant String :=
        Ada.Strings.Fixed.Trim
          (Positive'Image (Value.Port_No), Ada.Strings.Both);
   begin
      if (Value.Is_Secure and then Value.Port_No = 443)
        or else (not Value.Is_Secure and then Value.Port_No = 80)
      then
         return "";
      else
         return ":" & Port_Text;
      end if;
   end Port_Suffix;
end Convex_URL;
