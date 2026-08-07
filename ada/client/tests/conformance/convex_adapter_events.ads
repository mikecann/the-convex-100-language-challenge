with Convex;
with Convex.Live;

package Convex_Adapter_Events is
   --  Every NDJSON line the conformance adapter emits is built here, so a
   --  language-local test can assert the exact serialized shape the shared
   --  controller validates against adapter.schema.json. There is deliberately
   --  no second copy of these rules inside the adapter: the test and the real
   --  executable go through the same functions.
   --
   --  The schema treats logs, value, error, id, and subscriptionId as optional
   --  and never permits null in their place. An absent field is therefore
   --  omitted here rather than serialized as an empty array or a null.

   --  adapter.schema.json bounds ids by JSON string length, which counts
   --  Unicode code points rather than the UTF-8 bytes carrying them. The
   --  command line has already been proven well-formed UTF-8 before this is
   --  called, so counting the bytes that are not continuation bytes counts
   --  exactly those code points.
   function Valid_Id (Text : String) return Boolean;

   function Ready
     (Id             : String;
      Language       : String;
      Implementation : String;
      Runtime        : String) return String;

   function Ack (Id : String) return String;

   function Closed (Id : String) return String;

   --  A finished HTTP call. A successful result carries value, and carries
   --  logs only when the deployment actually sent logLines. A failed call
   --  carries the structured error and the same optional logs.
   function Call_Result_Event
     (Id : String; Result : Convex.Call_Result) return String;

   --  A failure the adapter itself detected. Id must already be a validated
   --  command id; pass the empty string when the command's own id could not
   --  be validated, and the event omits the field entirely.
   function Protocol_Error_Event (Id : String; Message : String) return String;

   --  One Live delivery for an already validated subscription id.
   function Subscription_Event
     (Subscription_Id : String; Item : Convex.Live.Update) return String;

   --  A failure the adapter detected while handling one subscription. The
   --  subscription itself survives: the shared controller must still receive
   --  a later valid value on the same subscription id.
   function Subscription_Error_Event
     (Subscription_Id : String; Message : String) return String;

   --  The two events whose size is set by the deployment rather than by this
   --  adapter. A Live value may approach the client's four-megabyte message
   --  ceiling and an HTTP result may approach the two-megabyte response cap,
   --  and re-encoding either one can grow it. Limit is the adapter's output
   --  line ceiling; when the finished event genuinely does not fit, these
   --  return a structured ProtocolError for the same subscription or command
   --  instead, so one unrepresentable value costs that delivery rather than
   --  the process. Neither retains state, so the next delivery is unaffected.
   function Subscription_Line
     (Subscription_Id : String; Item : Convex.Live.Update; Limit : Positive)
      return String;

   function Call_Result_Line
     (Id : String; Result : Convex.Call_Result; Limit : Positive)
      return String;
end Convex_Adapter_Events;
