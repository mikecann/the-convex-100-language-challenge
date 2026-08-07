with Ada.Strings.Unbounded;
with GNAT.Sockets;

package Convex_Adapter_Output is
   package US renames Ada.Strings.Unbounded;

   Max_Events     : constant := 16;
   Max_Bytes      : constant := 20 * 1024 * 1024;
   Write_Deadline : constant Duration := 3.0;

   --  Fixed per-event bookkeeping charged on top of four times the encoded
   --  line: the queue string, the writer's copy, encoder temporaries, and
   --  runtime overhead.
   Metadata_Bytes : constant := 4 * 1024;

   --  The largest line one event may carry. A Live delivery may legitimately
   --  hold a value close to the client's four-megabyte message ceiling, so a
   --  two-megabyte output cap would refuse schema-valid traffic rather than
   --  bound memory. The ceiling is therefore derived from the byte budget:
   --  it is exactly the longest line whose conservative charge still fits in
   --  Max_Bytes, which leaves roughly a megabyte of headroom above the client
   --  message ceiling for the event envelope and for re-encoding. The adapter
   --  asserts that relationship at compile time, and an event that still does
   --  not fit is reported as a structured error rather than emitted.
   Max_Line_Bytes : constant := (Max_Bytes - Metadata_Bytes) / 4 - 1;

   procedure Start
     (Use_TCP    : Boolean;
      Controller : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Test_Mode  : Boolean := False);

   procedure Try_Emit
     (Line            : String;
      Accepted        : out Boolean;
      Subscription_Id : String := "";
      Generation      : Natural := 0);

   --  Remove every queued line from one retired subscription generation and
   --  wait for a line already owned by the writer to finish or be cancelled.
   --  The writer has its own absolute deadline, so this barrier is bounded.
   procedure Retire
     (Subscription_Id : String; Generation : Natural; Success : out Boolean);

   procedure Wait_Idle (Success : out Boolean);
   procedure Stop;

   procedure Status
     (Failed      : out Boolean;
      Message     : out US.Unbounded_String;
      Event_Count : out Natural;
      Byte_Count  : out Natural);
   procedure Evidence
     (Peak_Event_Count : out Natural; Peak_Byte_Count : out Natural);

   --  Deterministic hooks exercise the same queue and writer task used by the
   --  final adapter. They are inert unless Start enables Test_Mode.
   procedure Test_Pause_Next;
   procedure Test_Wait_Paused (Success : out Boolean);
   procedure Test_Resume;
   procedure Test_Fail_Next;
   function Test_Sent_Count return Natural;
   function Test_Sent_Line (Index : Positive) return String;
end Convex_Adapter_Output;
