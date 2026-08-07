with Ada.Strings.Unbounded;
with GNATCOLL.JSON;

package Convex is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;

   type Error_Kind is
     (Function_Error, Protocol_Error, Transport_Error, Closed_Error);

   --  Convex omits logLines entirely when a call produced no logs. Has_Logs
   --  records that difference so the conformance adapter can omit the optional
   --  field instead of serializing an empty array the schema never asked for.
   type Error_Info is record
      Kind     : Error_Kind := Protocol_Error;
      Message  : US.Unbounded_String;
      Has_Data : Boolean := False;
      Data     : JSON.JSON_Value := JSON.JSON_Null;
      Has_Logs : Boolean := False;
      Logs     : JSON.JSON_Array := JSON.Empty_Array;
   end record;

   type Call_Result (Success : Boolean := False) is record
      case Success is
         when True =>
            Value    : JSON.JSON_Value;
            Has_Logs : Boolean := False;
            Logs     : JSON.JSON_Array;

         when False =>
            Error : Error_Info;
      end case;
   end record;

   type Client is limited private;

   procedure Open (C : in out Client; Deployment_URL : String);
   procedure Set_Auth (C : in out Client; Token : String);
   procedure Close (C : in out Client);

   function Query
     (C : in out Client; Path : String; Args : JSON.JSON_Value)
      return Call_Result;
   function Mutation
     (C : in out Client; Path : String; Args : JSON.JSON_Value)
      return Call_Result;
   function Action
     (C : in out Client; Path : String; Args : JSON.JSON_Value)
      return Call_Result;

   function Error_Name (Kind : Error_Kind) return String;

private
   type Client is limited record
      URL    : US.Unbounded_String;
      Auth   : US.Unbounded_String;
      Opened : Boolean := False;
   end record;
end Convex;
