with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Convex_Adapter_Output;

procedure Convex_Adapter_Output_Tests is
   package US renames Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   protected Barrier_Result is
      procedure Finished (Success : Boolean);
      procedure Snapshot (Count : out Natural; All_Succeeded : out Boolean);
   private
      Completed : Natural := 0;
      Good      : Boolean := True;
   end Barrier_Result;

   protected body Barrier_Result is
      procedure Finished (Success : Boolean) is
      begin
         Completed := Completed + 1;
         Good := Good and Success;
      end Finished;

      procedure Snapshot (Count : out Natural; All_Succeeded : out Boolean) is
      begin
         Count := Completed;
         All_Succeeded := Good;
      end Snapshot;
   end Barrier_Result;

   task Barrier is
      entry Run (Name : US.Unbounded_String; Generation : Natural);
   end Barrier;

   task body Barrier is
      Job_Name       : US.Unbounded_String;
      Job_Generation : Natural;
      Success        : Boolean;
   begin
      for Attempt in 1 .. 2 loop
         accept Run (Name : US.Unbounded_String; Generation : Natural) do
            Job_Name := Name;
            Job_Generation := Generation;
         end Run;
         Convex_Adapter_Output.Retire
           (US.To_String (Job_Name), Job_Generation, Success);
         Barrier_Result.Finished (Success);
      end loop;
   end Barrier;

   procedure Wait_For_Barriers (Expected : Natural) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (1.0);
      Count    : Natural := 0;
      Good     : Boolean;
   begin
      while Count < Expected and then Ada.Real_Time.Clock < Deadline loop
         Barrier_Result.Snapshot (Count, Good);
         exit when Count >= Expected;
         delay 0.001;
      end loop;
      Barrier_Result.Snapshot (Count, Good);
      Check (Count = Expected and then Good, "relay barrier did not complete");
   end Wait_For_Barriers;

   procedure Snapshot
     (Failed : out Boolean; Events : out Natural; Bytes : out Natural)
   is
      Message : US.Unbounded_String;
   begin
      Convex_Adapter_Output.Status (Failed, Message, Events, Bytes);
   end Snapshot;

   Accepted : Boolean;
   Paused   : Boolean;
   Drained  : Boolean;
   Failed   : Boolean;
   Events   : Natural;
   Bytes    : Natural;
   Count    : Natural;
   Good     : Boolean;
begin
   Convex_Adapter_Output.Start (Use_TCP => False, Test_Mode => True);

   --  Unsubscribe cannot acknowledge while an old generation is paused after
   --  dequeue. Once resumed, retirement cancels it before the ack is queued.
   Convex_Adapter_Output.Test_Pause_Next;
   Convex_Adapter_Output.Try_Emit
     ("stale-unsubscribe", Accepted, "same-id", 1);
   Check (Accepted, "unsubscribe stale line was not accepted");
   Convex_Adapter_Output.Test_Wait_Paused (Paused);
   Check (Paused, "unsubscribe line did not pause after dequeue");
   Barrier.Run (US.To_Unbounded_String ("same-id"), 1);
   delay 0.05;
   Barrier_Result.Snapshot (Count, Good);
   Check (Count = 0, "unsubscribe barrier acknowledged a dequeued stale line");
   Convex_Adapter_Output.Test_Resume;
   Wait_For_Barriers (1);
   Convex_Adapter_Output.Try_Emit ("unsubscribe-ack", Accepted);
   Check (Accepted, "unsubscribe ack was not accepted");
   Convex_Adapter_Output.Wait_Idle (Drained);
   Check (Drained, "unsubscribe output did not drain");
   Check
     (Convex_Adapter_Output.Test_Sent_Count = 1
      and then Convex_Adapter_Output.Test_Sent_Line (1) = "unsubscribe-ack",
      "stale unsubscribe line crossed its acknowledgement barrier");

   --  Replacing the same subscription ID has the identical barrier. The new
   --  generation may publish only after the old generation is retired.
   Convex_Adapter_Output.Test_Pause_Next;
   Convex_Adapter_Output.Try_Emit
     ("stale-replacement", Accepted, "same-id", 2);
   Check (Accepted, "replacement stale line was not accepted");
   Convex_Adapter_Output.Test_Wait_Paused (Paused);
   Check (Paused, "replacement line did not pause after dequeue");
   Barrier.Run (US.To_Unbounded_String ("same-id"), 2);
   delay 0.05;
   Barrier_Result.Snapshot (Count, Good);
   Check (Count = 1, "replacement barrier acknowledged a dequeued stale line");
   Convex_Adapter_Output.Test_Resume;
   Wait_For_Barriers (2);
   Convex_Adapter_Output.Try_Emit ("replacement-ack", Accepted);
   Check (Accepted, "replacement ack was not accepted");
   Convex_Adapter_Output.Try_Emit
     ("new-generation-value", Accepted, "same-id", 3);
   Check (Accepted, "new generation line was not accepted");
   Convex_Adapter_Output.Wait_Idle (Drained);
   Check (Drained, "replacement output did not drain");
   Check
     (Convex_Adapter_Output.Test_Sent_Count = 3
      and then Convex_Adapter_Output.Test_Sent_Line (2) = "replacement-ack"
      and then Convex_Adapter_Output.Test_Sent_Line (3)
               = "new-generation-value",
      "same-ID replacement crossed its stale generation barrier");

   --  Five valid sub-2-MiB lines drive conservative reservations above 17 MiB
   --  without crossing the 20 MiB output budget.
   declare
      Large_Line : constant String (1 .. 900_000) := [others => 'x'];
   begin
      Convex_Adapter_Output.Test_Pause_Next;
      for I in 1 .. 5 loop
         Convex_Adapter_Output.Try_Emit (Large_Line, Accepted, "large", 4);
         Check (Accepted, "large line within byte budget was rejected");
         if I = 1 then
            Convex_Adapter_Output.Test_Wait_Paused (Paused);
            Check (Paused, "large line did not pause after dequeue");
         end if;
      end loop;
      Snapshot (Failed, Events, Bytes);
      Check
        (not Failed
         and then Events = 5
         and then Bytes >= 17 * 1024 * 1024
         and then Bytes <= Convex_Adapter_Output.Max_Bytes,
         "conservative byte reservations were not bounded near the budget");
      Convex_Adapter_Output.Try_Emit (Large_Line, Accepted, "large", 4);
      Check (not Accepted, "byte budget accepted an over-budget line");
      Convex_Adapter_Output.Test_Resume;
      Convex_Adapter_Output.Wait_Idle (Drained);
      Check (Drained, "large-line reservations did not release after send");
   end;

   Convex_Adapter_Output.Test_Pause_Next;
   for I in 1 .. Convex_Adapter_Output.Max_Events loop
      Convex_Adapter_Output.Try_Emit ("count-budget", Accepted, "count", 5);
      Check (Accepted, "event within count budget was rejected");
      if I = 1 then
         Convex_Adapter_Output.Test_Wait_Paused (Paused);
         Check (Paused, "count-budget line did not pause after dequeue");
      end if;
   end loop;
   Convex_Adapter_Output.Try_Emit ("count-overflow", Accepted, "count", 5);
   Check (not Accepted, "event count budget accepted a seventeenth event");
   Convex_Adapter_Output.Test_Resume;
   Convex_Adapter_Output.Wait_Idle (Drained);
   Check (Drained, "count reservations did not release after send");

   Convex_Adapter_Output.Test_Fail_Next;
   Convex_Adapter_Output.Try_Emit ("fail", Accepted);
   Check (Accepted, "injected failure line was not accepted");
   declare
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (1.0);
   begin
      loop
         Snapshot (Failed, Events, Bytes);
         exit when Failed or else Ada.Real_Time.Clock >= Deadline;
         delay 0.001;
      end loop;
   end;
   Check
     (Failed and then Events = 0 and then Bytes = 0,
      "failed output did not release count and byte reservations");
   Convex_Adapter_Output.Stop;
   Ada.Text_IO.Put_Line ("Ada adapter output tests passed");
end Convex_Adapter_Output_Tests;
