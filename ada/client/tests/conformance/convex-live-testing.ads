with Ada.Strings.Unbounded;

package Convex.Live.Testing is
   procedure Debug_Disconnect
     (M       : in out Manager;
      Success : out Boolean;
      Message : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Abort_Manager (M : in out Manager);
   --  Test-failure cleanup must not call the same synchronous Stop entry whose
   --  boundedness a fixture is currently checking. Abort_Manager is compiled
   --  only into the conformance/test surface and makes that failure path
   --  independently nonblocking.
end Convex.Live.Testing;
