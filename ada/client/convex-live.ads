with Ada.Strings.Unbounded;
with GNATCOLL.JSON;

package Convex.Live is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;

   --  Has_Logs distinguishes "the server sent no logLines field" from "the
   --  server sent an empty logLines array". The conformance adapter must omit
   --  the optional field in the first case rather than serialize [].
   type Update is record
      Has_Value : Boolean := False;
      Value     : JSON.JSON_Value := JSON.JSON_Null;
      Has_Error : Boolean := False;
      Error     : Convex.Error_Info;
      Has_Logs  : Boolean := False;
      Logs      : JSON.JSON_Array := JSON.Empty_Array;
      Token     : Natural := 0;
   end record;

   type Manager is limited private;
   type Subscription is private;

   procedure Open (M : in out Manager; Deployment_URL : String);
   procedure Subscribe
     (M       : in out Manager;
      Path    : String;
      Args    : JSON.JSON_Value;
      Result  : out Subscription;
      Success : out Boolean;
      Message : out US.Unbounded_String);
   procedure Unsubscribe (M : in out Manager; Sub : in out Subscription);

   procedure Try_Next
     (M     : in out Manager;
      Sub   : Subscription;
      Found : out Boolean;
      Item  : out Update);
   procedure Release (M : in out Manager; Item : in out Update);

   procedure Close (M : in out Manager);

   function Is_Active (Sub : Subscription) return Boolean;

private
   --  This task holds a complete Live message, its decoded tree, and the
   --  encoded signature it compares against the previous value, so a single
   --  delivery at the four-megabyte message ceiling occupies several
   --  megabytes at once. Say so rather than inheriting whatever default the
   --  runtime happens to use, because the failure mode of a default that is
   --  too small is Storage_Error on exactly the largest valid values.
   task type Owner_Task with Storage_Size => 16 * 1024 * 1024 is
      entry Configure (Deployment_URL : String);
      entry Add
        (Path       : String;
         Args       : JSON.JSON_Value;
         Id         : out Natural;
         Generation : out Natural;
         Success    : out Boolean;
         Message    : out US.Unbounded_String);
      entry Remove (Id, Generation : Natural);
      entry Next
        (Id, Generation : Natural; Found : out Boolean; Item : out Update);
      entry Release_Update (Token : Natural);
      entry Disconnect
        (Success : out Boolean; Message : out US.Unbounded_String);
      entry Stop;
   end Owner_Task;
   type Owner_Access is access Owner_Task;

   type Manager is limited record
      Owner  : Owner_Access;
      Opened : Boolean := False;
   end record;

   type Subscription is record
      Id         : Natural := 0;
      Generation : Natural := 0;
      Active     : Boolean := False;
   end record;
end Convex.Live;
