with Ada.Strings.Unbounded;

package body Convex.Live.Testing is
   procedure Debug_Disconnect
     (M       : in out Manager;
      Success : out Boolean;
      Message : out Ada.Strings.Unbounded.Unbounded_String) is
   begin
      if not M.Opened or else M.Owner = null then
         Success := False;
         Message :=
           Ada.Strings.Unbounded.To_Unbounded_String
             ("Live manager is closed");
         return;
      end if;
      M.Owner.Disconnect (Success, Message);
   end Debug_Disconnect;
end Convex.Live.Testing;
