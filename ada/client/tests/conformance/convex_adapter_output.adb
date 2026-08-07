with Ada.Exceptions;
with Ada.Real_Time;
with Interfaces.C;
with System;

package body Convex_Adapter_Output is
   use type Ada.Real_Time.Time;
   use type GNAT.Sockets.Socket_Type;
   use type Interfaces.C.int;
   use type Interfaces.C.long;

   Queue_Capacity : constant := Max_Events;

   type Output_Item is record
      Line       : US.Unbounded_String;
      Sub_Id     : US.Unbounded_String;
      Generation : Natural := 0;
      Charge     : Natural := 0;
   end record;

   type Output_Array is
     array (Positive range 1 .. Queue_Capacity) of Output_Item;
   type Captured_Array is
     array (Positive range 1 .. Queue_Capacity) of US.Unbounded_String;

   protected Output_State is
      procedure Configure
        (Use_TCP    : Boolean;
         Controller : GNAT.Sockets.Socket_Type;
         Test_Mode  : Boolean);
      procedure Enqueue (Item : Output_Item; Accepted : out Boolean);
      entry Take
        (Item       : out Output_Item;
         Finish     : out Boolean;
         TCP        : out Boolean;
         Controller : out GNAT.Sockets.Socket_Type;
         Testing    : out Boolean;
         Pause      : out Boolean);
      procedure Should_Send (Item : Output_Item; Send : out Boolean);
      procedure Complete (Item : Output_Item; Sent : Boolean);
      procedure Fail (Message : String);
      procedure Begin_Retire (Sub_Id : String; Generation : Natural);
      procedure Retirement_Done
        (Sub_Id : String; Generation : Natural; Done : out Boolean);
      procedure End_Retire;
      procedure Snapshot
        (Failed      : out Boolean;
         Message     : out US.Unbounded_String;
         Event_Count : out Natural;
         Byte_Count  : out Natural);
      procedure Peak_Snapshot
        (Event_Count : out Natural; Byte_Count : out Natural);
      procedure Request_Stop;
      procedure Pause_Next;
      procedure Resume;
      procedure Paused_State (Value : out Boolean);
      procedure Fail_Next;
      procedure Captured_Count (Count : out Natural);
      procedure Captured_Line
        (Index : Positive; Line : out US.Unbounded_String);
   private
      Queue               : Output_Array;
      First               : Positive := 1;
      Count               : Natural := 0;
      Bytes               : Natural := 0;
      Inflight            : Output_Item;
      Has_Inflight        : Boolean := False;
      Started             : Boolean := False;
      Stopping            : Boolean := False;
      Failed_State        : Boolean := False;
      Failure             : US.Unbounded_String;
      TCP_Mode            : Boolean := False;
      Socket              : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Testing_Mode        : Boolean := False;
      Retiring            : Boolean := False;
      Retiring_Sub        : US.Unbounded_String;
      Retiring_Generation : Natural := 0;
      Pause_Requested     : Boolean := False;
      Is_Paused           : Boolean := False;
      Fail_Requested      : Boolean := False;
      Captured            : Captured_Array;
      Captured_Items      : Natural := 0;
      Peak_Events         : Natural := 0;
      Peak_Bytes          : Natural := 0;
   end Output_State;

   protected body Output_State is
      procedure Configure
        (Use_TCP    : Boolean;
         Controller : GNAT.Sockets.Socket_Type;
         Test_Mode  : Boolean) is
      begin
         if Started then
            raise Program_Error with "adapter output owner started twice";
         end if;
         Started := True;
         TCP_Mode := Use_TCP;
         Socket := Controller;
         Testing_Mode := Test_Mode;
      end Configure;

      procedure Enqueue (Item : Output_Item; Accepted : out Boolean) is
         Last : Positive;
      begin
         Accepted :=
           Started
           and then not Stopping
           and then not Failed_State
           and then US.Length (Item.Line) > 0
           and then Item.Charge <= Max_Bytes
           and then Count + Boolean'Pos (Has_Inflight) < Queue_Capacity
           and then Bytes <= Max_Bytes - Item.Charge;
         if Accepted then
            Last := ((First - 1 + Count) mod Queue_Capacity) + 1;
            Queue (Last) := Item;
            Count := Count + 1;
            Bytes := Bytes + Item.Charge;
            Peak_Events :=
              Natural'Max (Peak_Events, Count + Boolean'Pos (Has_Inflight));
            Peak_Bytes := Natural'Max (Peak_Bytes, Bytes);
         end if;
      end Enqueue;

      entry Take
        (Item       : out Output_Item;
         Finish     : out Boolean;
         TCP        : out Boolean;
         Controller : out GNAT.Sockets.Socket_Type;
         Testing    : out Boolean;
         Pause      : out Boolean)
        when Count > 0 or else Stopping
      is
      begin
         Finish := Count = 0 and then Stopping;
         Item := (others => <>);
         TCP := TCP_Mode;
         Controller := Socket;
         Testing := Testing_Mode;
         Pause := False;
         if not Finish then
            Item := Queue (First);
            Queue (First) := (others => <>);
            First := (if First = Queue_Capacity then 1 else First + 1);
            Count := Count - 1;
            Inflight := Item;
            Has_Inflight := True;
            if Pause_Requested and then Testing_Mode then
               Pause_Requested := False;
               Is_Paused := True;
               Pause := True;
            end if;
         end if;
      end Take;

      procedure Should_Send (Item : Output_Item; Send : out Boolean) is
      begin
         Send :=
           not Failed_State
           and then not (Retiring
                         and then Item.Generation = Retiring_Generation
                         and then US.To_String (Item.Sub_Id)
                                  = US.To_String (Retiring_Sub));
         if Fail_Requested and then Testing_Mode then
            Fail_Requested := False;
            Send := False;
            Failed_State := True;
            Failure := US.To_Unbounded_String ("injected output failure");
            for I in Queue'Range loop
               Queue (I) := (others => <>);
            end loop;
            Count := 0;
            First := 1;
            Bytes := (if Has_Inflight then Inflight.Charge else 0);
         end if;
      end Should_Send;

      procedure Complete (Item : Output_Item; Sent : Boolean) is
      begin
         if Testing_Mode and then Sent and then Captured_Items < Queue_Capacity
         then
            Captured_Items := Captured_Items + 1;
            Captured (Captured_Items) := Item.Line;
         end if;
         if Has_Inflight then
            Bytes := Bytes - Inflight.Charge;
            Inflight := (others => <>);
            Has_Inflight := False;
         end if;
      end Complete;

      procedure Fail (Message : String) is
      begin
         Failed_State := True;
         Failure := US.To_Unbounded_String (Message);
         for I in Queue'Range loop
            Queue (I) := (others => <>);
         end loop;
         Count := 0;
         First := 1;
         --  The in-flight reservation is released by Complete after Fail.
         Bytes := (if Has_Inflight then Inflight.Charge else 0);
      end Fail;

      procedure Begin_Retire (Sub_Id : String; Generation : Natural) is
         Kept       : Output_Array;
         Kept_Count : Natural := 0;
         Kept_Bytes : Natural := (if Has_Inflight then Inflight.Charge else 0);
      begin
         if Retiring then
            raise Program_Error with "nested adapter output retirement";
         end if;
         Retiring := True;
         Retiring_Sub := US.To_Unbounded_String (Sub_Id);
         Retiring_Generation := Generation;
         if Count > 0 then
            for Offset in 0 .. Count - 1 loop
               declare
                  Index : constant Positive :=
                    ((First - 1 + Offset) mod Queue_Capacity) + 1;
               begin
                  if Queue (Index).Generation /= Generation
                    or else US.To_String (Queue (Index).Sub_Id) /= Sub_Id
                  then
                     Kept_Count := Kept_Count + 1;
                     Kept (Kept_Count) := Queue (Index);
                     Kept_Bytes := Kept_Bytes + Queue (Index).Charge;
                  end if;
               end;
            end loop;
         end if;
         Queue := Kept;
         First := 1;
         Count := Kept_Count;
         Bytes := Kept_Bytes;
      end Begin_Retire;

      procedure Retirement_Done
        (Sub_Id : String; Generation : Natural; Done : out Boolean) is
      begin
         Done :=
           not Has_Inflight
           or else Inflight.Generation /= Generation
           or else US.To_String (Inflight.Sub_Id) /= Sub_Id;
      end Retirement_Done;

      procedure End_Retire is
      begin
         Retiring := False;
         Retiring_Sub := US.Null_Unbounded_String;
         Retiring_Generation := 0;
      end End_Retire;

      procedure Snapshot
        (Failed      : out Boolean;
         Message     : out US.Unbounded_String;
         Event_Count : out Natural;
         Byte_Count  : out Natural) is
      begin
         Failed := Failed_State;
         Message := Failure;
         Event_Count := Count + Boolean'Pos (Has_Inflight);
         Byte_Count := Bytes;
      end Snapshot;

      procedure Peak_Snapshot
        (Event_Count : out Natural; Byte_Count : out Natural) is
      begin
         Event_Count := Peak_Events;
         Byte_Count := Peak_Bytes;
      end Peak_Snapshot;

      procedure Request_Stop is
      begin
         Stopping := True;
         for I in Queue'Range loop
            Queue (I) := (others => <>);
         end loop;
         Count := 0;
         First := 1;
         Bytes := (if Has_Inflight then Inflight.Charge else 0);
         Is_Paused := False;
      end Request_Stop;

      procedure Pause_Next is
      begin
         if Testing_Mode then
            Pause_Requested := True;
         end if;
      end Pause_Next;

      procedure Resume is
      begin
         Is_Paused := False;
      end Resume;

      procedure Paused_State (Value : out Boolean) is
      begin
         Value := Is_Paused;
      end Paused_State;

      procedure Fail_Next is
      begin
         if Testing_Mode then
            Fail_Requested := True;
         end if;
      end Fail_Next;

      procedure Captured_Count (Count : out Natural) is
      begin
         Count := Captured_Items;
      end Captured_Count;

      procedure Captured_Line
        (Index : Positive; Line : out US.Unbounded_String) is
      begin
         if Index <= Captured_Items then
            Line := Captured (Index);
         else
            Line := US.Null_Unbounded_String;
         end if;
      end Captured_Line;
   end Output_State;

   type Poll_FD is record
      FD      : Interfaces.C.int;
      Events  : Interfaces.C.short;
      Revents : Interfaces.C.short;
   end record
   with Convention => C;

   function C_Poll
     (Descriptor : access Poll_FD;
      Count      : Interfaces.C.unsigned_long;
      Timeout_MS : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "poll";
   function C_Write
     (FD     : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t) return Interfaces.C.long
   with Import, Convention => C, External_Name => "write";
   function C_Send
     (FD     : Interfaces.C.int;
      Buffer : System.Address;
      Length : Interfaces.C.size_t;
      Flags  : Interfaces.C.int) return Interfaces.C.long
   with Import, Convention => C, External_Name => "send";
   function C_Fcntl
     (FD      : Interfaces.C.int;
      Command : Interfaces.C.int;
      Value   : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "fcntl";

   F_Get_Flags       : constant Interfaces.C.int := 3;
   F_Set_Flags       : constant Interfaces.C.int := 4;
   O_Nonblock        : constant Interfaces.C.int := 2_048;
   Poll_Output       : constant Interfaces.C.short := 4;
   Message_Dont_Wait : constant Interfaces.C.int := 64;
   Message_No_Signal : constant Interfaces.C.int := 16_384;

   procedure Set_Nonblocking (FD : Interfaces.C.int) is
      Flags : Interfaces.C.int;
   begin
      Flags := C_Fcntl (FD, F_Get_Flags, 0);
      if Flags < 0 or else C_Fcntl (FD, F_Set_Flags, Flags + O_Nonblock) < 0
      then
         raise Program_Error with "could not make adapter output nonblocking";
      end if;
   end Set_Nonblocking;

   --  Poll-and-write one bounded slice against the shared Deadline, without
   --  ever copying it. Data is addressed directly (Data'Address plus a
   --  cursor); no local buffer here scales with a caller-supplied line, so
   --  this never grows the task's stack usage with the size of a delivery.
   function Write_Slice
     (FD       : Interfaces.C.int;
      Data     : String;
      TCP      : Boolean;
      Deadline : Ada.Real_Time.Time) return Boolean
   is
      Cursor : Natural := 0;
   begin
      while Cursor < Data'Length loop
         if Ada.Real_Time.Clock >= Deadline then
            return False;
         end if;
         declare
            Remaining  : constant Duration :=
              Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
            Wait_MS    : constant Interfaces.C.int :=
              Interfaces.C.int'Max (1, Interfaces.C.int (Remaining * 1_000.0));
            Descriptor : aliased Poll_FD :=
              (FD => FD, Events => Poll_Output, Revents => 0);
            Ready      : constant Interfaces.C.int :=
              C_Poll (Descriptor'Access, 1, Wait_MS);
         begin
            if Ready = 0 then
               return False;
            elsif Ready > 0 then
               declare
                  Written : constant Interfaces.C.long :=
                    (if TCP
                     then
                       C_Send
                         (FD,
                          Data (Data'First + Cursor)'Address,
                          Interfaces.C.size_t (Data'Length - Cursor),
                          Message_Dont_Wait + Message_No_Signal)
                     else
                       C_Write
                         (FD,
                          Data (Data'First + Cursor)'Address,
                          Interfaces.C.size_t (Data'Length - Cursor)));
               begin
                  if Written > 0 then
                     Cursor := Cursor + Natural (Written);
                  end if;
               end;
            end if;
         end;
      end loop;
      return True;
   end Write_Slice;

   --  Line's own bytes are written first, directly out of the caller's
   --  String; the ASCII.LF terminator is a second, one-byte slice. Splitting
   --  it this way is deliberate: the previous `Line & ASCII.LF` local
   --  concatenation held a full copy of the line on this task's stack, and
   --  for a delivery near the client's four-megabyte message ceiling that is
   --  exactly the failure mode Convex.Live.Owner_Task's own Storage_Size
   --  comment warns about. Neither slice here scales with Line's length.
   function Write_Bounded
     (FD : Interfaces.C.int; Line : String; TCP : Boolean) return Boolean
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Write_Deadline);
      Newline  : aliased constant String := [1 => ASCII.LF];
   begin
      return
        Write_Slice (FD, Line, TCP, Deadline)
        and then Write_Slice (FD, Newline, TCP, Deadline);
   end Write_Bounded;

   --  Write_Slice addresses Line directly instead of copying it onto this
   --  stack (see its own comment), so nothing here scales with a delivery
   --  that may be several megabytes wide. A small explicit size is still
   --  given rather than inheriting the runtime default, so this is a
   --  deliberate bound rather than whatever happens to be enough today: the
   --  locals actually placed on this stack are a handful of small records
   --  and scalars per poll/write iteration, not the line itself.
   task Writer
     with Storage_Size => 256 * 1024;

   task body Writer is
      Item       : Output_Item;
      Finish     : Boolean;
      TCP        : Boolean;
      Controller : GNAT.Sockets.Socket_Type;
      Testing    : Boolean;
      Pause      : Boolean;
      Send       : Boolean;
      Sent       : Boolean;
      Paused     : Boolean;
   begin
      loop
         Output_State.Take (Item, Finish, TCP, Controller, Testing, Pause);
         exit when Finish;
         if Pause then
            loop
               Output_State.Paused_State (Paused);
               exit when not Paused;
               delay 0.001;
            end loop;
         end if;
         Output_State.Should_Send (Item, Send);
         Sent := False;
         if Send then
            if Testing then
               Sent := True;
            else
               Sent :=
                 Write_Bounded
                   ((if TCP
                     then Interfaces.C.int (GNAT.Sockets.To_C (Controller))
                     else Interfaces.C.int'(1)),
                    US.To_String (Item.Line),
                    TCP);
               if not Sent then
                  Output_State.Fail
                    ("adapter output write timed out or failed");
               end if;
            end if;
         end if;
         Output_State.Complete (Item, Sent);
      end loop;
   exception
      when E : others =>
         Output_State.Fail
           ("adapter output owner failed: "
            & Ada.Exceptions.Exception_Message (E));
         Output_State.Complete (Item, False);
   end Writer;

   procedure Start
     (Use_TCP    : Boolean;
      Controller : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Test_Mode  : Boolean := False)
   is
      FD : constant Interfaces.C.int :=
        (if Use_TCP
         then Interfaces.C.int (GNAT.Sockets.To_C (Controller))
         else Interfaces.C.int'(1));
   begin
      if not Test_Mode then
         if Use_TCP and then Controller = GNAT.Sockets.No_Socket then
            raise Constraint_Error with "adapter output TCP socket is missing";
         end if;
         --  MSG_DONTWAIT scopes nonblocking behavior to each TCP send. Do not
         --  set O_NONBLOCK on the shared socket because the command reader owns
         --  blocking receives on the same descriptor.
         if not Use_TCP then
            Set_Nonblocking (FD);
         end if;
      end if;
      Output_State.Configure (Use_TCP, Controller, Test_Mode);
   end Start;

   procedure Try_Emit
     (Line            : String;
      Accepted        : out Boolean;
      Subscription_Id : String := "";
      Generation      : Natural := 0)
   is
      Charge : Natural;
   begin
      --  Four times the encoded line plus fixed metadata is deliberately
      --  conservative. It covers the queue string, writer copy, JSON encoder
      --  temporaries, and runtime bookkeeping while staying under 128 MiB.
      --  Max_Line_Bytes is the exact point where that charge reaches the
      --  budget, so one ceiling-sized line still fits an empty queue and
      --  nothing longer can be charged at all.
      if Line'Length > Max_Line_Bytes then
         Accepted := False;
         return;
      end if;
      Charge := Metadata_Bytes + 4 * (Line'Length + 1);
      Output_State.Enqueue
        ((Line       => US.To_Unbounded_String (Line),
          Sub_Id     => US.To_Unbounded_String (Subscription_Id),
          Generation => Generation,
          Charge     => Charge),
         Accepted);
   end Try_Emit;

   procedure Retire
     (Subscription_Id : String; Generation : Natural; Success : out Boolean)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock
        + Ada.Real_Time.To_Time_Span (Write_Deadline + 0.5);
      Done     : Boolean := False;
   begin
      Output_State.Begin_Retire (Subscription_Id, Generation);
      while not Done and then Ada.Real_Time.Clock < Deadline loop
         Output_State.Retirement_Done (Subscription_Id, Generation, Done);
         exit when Done;
         delay 0.001;
      end loop;
      Output_State.End_Retire;
      Success := Done;
   end Retire;

   procedure Wait_Idle (Success : out Boolean) is
      Deadline    : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock
        + Ada.Real_Time.To_Time_Span (Write_Deadline + 0.5);
      Failed      : Boolean;
      Message     : US.Unbounded_String;
      Event_Count : Natural;
      Byte_Count  : Natural;
   begin
      loop
         Output_State.Snapshot (Failed, Message, Event_Count, Byte_Count);
         exit when
           Event_Count = 0
           or else Failed
           or else Ada.Real_Time.Clock >= Deadline;
         delay 0.001;
      end loop;
      Success := not Failed and then Event_Count = 0;
   end Wait_Idle;

   procedure Stop is
   begin
      Output_State.Request_Stop;
   end Stop;

   procedure Status
     (Failed      : out Boolean;
      Message     : out US.Unbounded_String;
      Event_Count : out Natural;
      Byte_Count  : out Natural) is
   begin
      Output_State.Snapshot (Failed, Message, Event_Count, Byte_Count);
   end Status;

   procedure Evidence
     (Peak_Event_Count : out Natural; Peak_Byte_Count : out Natural) is
   begin
      Output_State.Peak_Snapshot (Peak_Event_Count, Peak_Byte_Count);
   end Evidence;

   procedure Test_Pause_Next is
   begin
      Output_State.Pause_Next;
   end Test_Pause_Next;

   procedure Test_Wait_Paused (Success : out Boolean) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (1.0);
      Paused   : Boolean := False;
   begin
      while not Paused and then Ada.Real_Time.Clock < Deadline loop
         Output_State.Paused_State (Paused);
         exit when Paused;
         delay 0.001;
      end loop;
      Success := Paused;
   end Test_Wait_Paused;

   procedure Test_Resume is
   begin
      Output_State.Resume;
   end Test_Resume;

   procedure Test_Fail_Next is
   begin
      Output_State.Fail_Next;
   end Test_Fail_Next;

   function Test_Sent_Count return Natural is
      Count : Natural;
   begin
      Output_State.Captured_Count (Count);
      return Count;
   end Test_Sent_Count;

   function Test_Sent_Line (Index : Positive) return String is
      Line : US.Unbounded_String;
   begin
      Output_State.Captured_Line (Index, Line);
      return US.To_String (Line);
   end Test_Sent_Line;
end Convex_Adapter_Output;
