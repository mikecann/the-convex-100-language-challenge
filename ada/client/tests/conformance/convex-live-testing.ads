with Ada.Strings.Unbounded;

package Convex.Live.Testing is
   procedure Debug_Disconnect
     (M       : in out Manager;
      Success : out Boolean;
      Message : out Ada.Strings.Unbounded.Unbounded_String);
end Convex.Live.Testing;
