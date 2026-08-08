module ConvexTransportTest {
  use CTypes;

  // These symbols exist only when the C transport is compiled with the
  // explicit CHAPEL_TRANSPORT_TEST define.
  extern proc ct_ws_send_sequence_selftest(): c_int;
  extern proc ct_adapter_close_test_input(): c_int;
  extern proc ct_adapter_stalled_test_output(): c_int;
  extern proc ct_adapter_close_test_saw_closed(): c_int;

  proc webSocketSendSequenceSelfTest(): bool do
    return ct_ws_send_sequence_selftest() == 1;
  proc adapterCloseTestInput(): int do
    return ct_adapter_close_test_input():int;
  proc adapterStalledTestOutput(): int do
    return ct_adapter_stalled_test_output():int;
  proc adapterCloseTestSawClosed(): bool do
    return ct_adapter_close_test_saw_closed() == 1;
}
