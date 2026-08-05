package convex.adapter;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import convex.ConvexClient;
import java.io.*;
import java.util.*;

/** Test-only NDJSON v1 adapter. Live commands return structured errors until reconnect support is proven. */
public final class Adapter {
  public static void main(String[] args) throws Exception {
    BufferedReader input = new BufferedReader(new InputStreamReader(System.in)); PrintWriter output = new PrintWriter(System.out, true); ConvexClient client = null;
    for (String line; (line=input.readLine()) != null;) {
      JsonNode command; try { command=ConvexClient.JSON.readTree(line); } catch(Exception e) { error(output, "", e); continue; }
      String id=command.path("id").asText(), op=command.path("op").asText();
      try {
        if ("hello".equals(op)) { ObjectNode event=event("ready",id).put("protocolVersion",1).put("language","java").put("implementation","native-java-21").put("runtime",System.getProperty("java.runtime.version")); emit(output,event); continue; }
        if ("close".equals(op)) { if (client != null) client.close(); emit(output,event("closed",id)); return; }
        if (client==null) client=new ConvexClient(requiredEnv("CONVEX_URL"));
        if ("setAuth".equals(op)) { client.setAuth(command.path("token").asText()); emit(output,event("ack",id)); }
        else if (Set.of("query","mutation","action").contains(op)) { ConvexClient.Result result = switch(op) { case "query" -> client.query(command.path("path").asText(), command.path("args")); case "mutation" -> client.mutation(command.path("path").asText(), command.path("args")); default -> client.action(command.path("path").asText(), command.path("args")); }; ObjectNode event=event("result",id); event.set("value",result.value()); if(!result.logs().isEmpty()) event.set("logs",ConvexClient.JSON.valueToTree(result.logs())); emit(output,event); }
        else throw new UnsupportedOperationException("Live adapter operation is not yet proven: " + op);
      } catch(Exception e) { error(output,id,e); }
    }
  }
  private static String requiredEnv(String key) { String value=System.getenv(key); if(value==null||value.isBlank()) throw new IllegalStateException(key+" is required"); return value; }
  private static ObjectNode event(String type,String id) { ObjectNode n=ConvexClient.JSON.createObjectNode().put("type",type); if(!id.isEmpty())n.put("id",id); return n; }
  private static void error(PrintWriter out,String id,Exception e) { ObjectNode n=event("error",id); ObjectNode err=n.putObject("error").put("name",e.getClass().getSimpleName()).put("message",e.getMessage()==null?e.getClass().getSimpleName():e.getMessage()); emit(out,n); }
  private static void emit(PrintWriter out,ObjectNode n) { out.println(n.toString()); }
}
