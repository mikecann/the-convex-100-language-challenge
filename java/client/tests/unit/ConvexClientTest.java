package convex;

import static java.lang.System.out;

/** Small source-level guard: URL validation must happen before any network call. */
public final class ConvexClientTest {
  public static void main(String[] args) {
    try { new ConvexClient("ftp://example.com"); throw new AssertionError("accepted ftp URL"); }
    catch (IllegalArgumentException expected) { out.println("URL validation passed"); }
  }
}
