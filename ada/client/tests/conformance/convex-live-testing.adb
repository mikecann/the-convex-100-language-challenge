with Ada.Strings.Unbounded;

package body Convex.Live.Testing is
   procedure Abort_Manager (M : in out Manager) is
   begin
      if M.Owner /= null then
         abort M.Owner.all;
      end if;
      M.Opened := False;
   end Abort_Manager;

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
