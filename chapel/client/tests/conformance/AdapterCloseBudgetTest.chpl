module ChapelConvexAdapterCloseBudgetTest {
  use Convex;
  use ConvexTransport;
  use ConvexTransportTest;
  use ChapelConvexAdapter;

  proc main() {
    const readFd = adapterCloseTestInput();
    const writeFd = adapterStalledTestOutput();
    assert(readFd >= 0 && writeFd >= 0,
           "could not create adapter close-budget fixtures");
    const started = monotonicMillis();
    const failure = runAdapter(readFd, writeFd);
    const elapsed = monotonicMillis() - started;
    closeFd(readFd);
    closeFd(writeFd);
    assert(!adapterCloseTestSawClosed(),
           "failed adapter teardown claimed successful closure");
    assert(failure.kind == FailureKind.Transport,
           "stalled output writer did not report a structured failure");
    assert(closeBudgetOwnerDidStop(),
           "adapter Client owner outlived the close budget");
    assert(closeBudgetWriterDidStop(),
           "adapter output writer outlived the close budget");
    assert(elapsed < 3400,
           "runAdapter exceeded one three-second close budget");
  }
}
