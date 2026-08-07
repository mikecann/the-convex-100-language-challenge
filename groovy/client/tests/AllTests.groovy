package convex.tests

/** Runs every deterministic language-local suite from the Docker test target. */
final class AllTests {
  static void main(String[] args) {
    ClientTests.run()
    LiveClientTests.run()
    AdapterTests.run()
    println 'Groovy client, Live, adapter, and adversarial tests passed'
  }
}
