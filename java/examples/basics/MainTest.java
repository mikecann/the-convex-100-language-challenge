package convex.example;

import java.io.PrintWriter;
import java.io.StringWriter;

/** Checks the exact universal stdout transcript emitted by the canonical source. */
public final class MainTest {
  public static void main(String[] args) {
    StringWriter captured = new StringWriter();
    Main.writeTranscript(new PrintWriter(captured, true), 0, 0, true, 1, 1);
    String expected = "current count: 0\n" +
      "live initial count: 0\n" +
      "mutation applied: true\n" +
      "mutation count: 1\n" +
      "live updated count: 1\n" +
      "verified count: 0 -> 1\n";
    if (!expected.equals(captured.toString())) throw new AssertionError("unexpected example transcript:\n" + captured);
    System.out.println("example transcript test passed");
  }
}
