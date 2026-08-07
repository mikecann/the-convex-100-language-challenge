with Ada.Strings.Unbounded;
with GNATCOLL.JSON;

package body Convex_Adapter_Events is
   package US renames Ada.Strings.Unbounded;
   package JSON renames GNATCOLL.JSON;

   function Valid_Id (Text : String) return Boolean is
      Count : Natural := 0;
   begin
      for C of Text loop
         if Character'Pos (C) not in 16#80# .. 16#BF# then
            Count := Count + 1;
            if Count > 128 then
               return False;
            end if;
         end if;
      end loop;
      return Count >= 1;
   end Valid_Id;

   --  Every event that carries an id reaches this point only after the
   --  command's id was validated. Fail loudly rather than serialize an id the
   --  shared controller would reject inside an otherwise well-formed event.
   procedure Require_Valid_Id (Id : String) is
   begin
      if not Valid_Id (Id) then
         raise Constraint_Error
           with "adapter event carried an unvalidated identifier";
      end if;
   end Require_Valid_Id;

   function Error_Object (Error : Convex.Error_Info) return JSON.JSON_Value is
      Result : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      Result.Set_Field ("name", Convex.Error_Name (Error.Kind));
      Result.Set_Field ("message", US.To_String (Error.Message));
      --  data is optional and never null. Convex distinguishes an error with
      --  no application payload from one whose payload happens to be null.
      if Error.Has_Data then
         Result.Set_Field ("data", Error.Data);
      end if;
      return Result;
   end Error_Object;

   function Ready
     (Id             : String;
      Language       : String;
      Implementation : String;
      Runtime        : String) return String
   is
      Event : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      Require_Valid_Id (Id);
      Event.Set_Field ("protocolVersion", Integer'(1));
      Event.Set_Field ("id", Id);
      Event.Set_Field ("type", "ready");
      Event.Set_Field ("language", Language);
      Event.Set_Field ("implementation", Implementation);
      Event.Set_Field ("runtime", Runtime);
      return JSON.Write (Event);
   end Ready;

   function Ack (Id : String) return String is
      Event : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      Require_Valid_Id (Id);
      Event.Set_Field ("id", Id);
      Event.Set_Field ("type", "ack");
      return JSON.Write (Event);
   end Ack;

   function Closed (Id : String) return String is
      Event : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      Require_Valid_Id (Id);
      Event.Set_Field ("id", Id);
      Event.Set_Field ("type", "closed");
      return JSON.Write (Event);
   end Closed;

   function Call_Result_Event
     (Id : String; Result : Convex.Call_Result) return String
   is
      Event : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      Require_Valid_Id (Id);
      Event.Set_Field ("id", Id);
      if Result.Success then
         Event.Set_Field ("type", "result");
         Event.Set_Field ("value", Result.Value);
         if Result.Has_Logs then
            Event.Set_Field ("logs", Result.Logs);
         end if;
      else
         Event.Set_Field ("type", "error");
         Event.Set_Field ("error", Error_Object (Result.Error));
         if Result.Error.Has_Logs then
            Event.Set_Field ("logs", Result.Error.Logs);
         end if;
      end if;
      return JSON.Write (Event);
   end Call_Result_Event;

   function Protocol_Error_Event (Id : String; Message : String) return String
   is
      Event : constant JSON.JSON_Value := JSON.Create_Object;
      Error : Convex.Error_Info;
   begin
      Error.Kind := Convex.Protocol_Error;
      Error.Message := US.To_Unbounded_String (Message);
      --  minLength is 1 and maxLength is 128, so a missing or unvalidated
      --  command id must not be echoed back. Omit the field instead.
      if Valid_Id (Id) then
         Event.Set_Field ("id", Id);
      end if;
      Event.Set_Field ("type", "error");
      Event.Set_Field ("error", Error_Object (Error));
      return JSON.Write (Event);
   end Protocol_Error_Event;

   function Subscription_Event
     (Subscription_Id : String; Item : Convex.Live.Update) return String
   is
      Event : constant JSON.JSON_Value := JSON.Create_Object;
   begin
      Require_Valid_Id (Subscription_Id);
      Event.Set_Field ("type", "subscription");
      Event.Set_Field ("subscriptionId", Subscription_Id);
      if Item.Has_Value then
         Event.Set_Field ("value", Item.Value);
         if Item.Has_Logs then
            Event.Set_Field ("logs", Item.Logs);
         end if;
      elsif Item.Has_Error then
         Event.Set_Field ("error", Error_Object (Item.Error));
         if Item.Error.Has_Logs then
            Event.Set_Field ("logs", Item.Error.Logs);
         end if;
      end if;
      return JSON.Write (Event);
   end Subscription_Event;

   function Subscription_Error_Event
     (Subscription_Id : String; Message : String) return String
   is
      Item : Convex.Live.Update;
   begin
      --  Build the ordinary subscription error rather than a second encoder,
      --  so an adapter-detected failure and a QueryFailed reach the shared
      --  controller in exactly the same shape.
      Item.Has_Error := True;
      Item.Error.Kind := Convex.Protocol_Error;
      Item.Error.Message := US.To_Unbounded_String (Message);
      return Subscription_Event (Subscription_Id, Item);
   end Subscription_Error_Event;

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   function Oversize_Message (Encoded, Limit : Natural) return String
   is ("encoded event of "
       & Image (Encoded)
       & " bytes exceeds the "
       & Image (Limit)
       & " byte adapter output limit");

   function Subscription_Line
     (Subscription_Id : String;
      Item            : Convex.Live.Update;
      Limit           : Positive) return String
   is
      Event : constant String := Subscription_Event (Subscription_Id, Item);
   begin
      if Event'Length <= Limit then
         return Event;
      end if;
      return
        Subscription_Error_Event
          (Subscription_Id, Oversize_Message (Event'Length, Limit));
   end Subscription_Line;

   function Call_Result_Line
     (Id : String; Result : Convex.Call_Result; Limit : Positive) return String
   is
      Event : constant String := Call_Result_Event (Id, Result);
   begin
      if Event'Length <= Limit then
         return Event;
      end if;
      return Protocol_Error_Event (Id, Oversize_Message (Event'Length, Limit));
   end Call_Result_Line;
end Convex_Adapter_Events;
