module ConvexTransport {
  use CTypes;

  require "convex_transport.h", "convex_transport.c";
  require "-lcurl", "-ljson-c", "-lcrypto";

  extern type chapel_ws;
  extern proc ct_free(value: c_ptr(void));
  extern proc ct_getenv_copy(name: c_ptrConst(c_char)): c_ptr(c_char);
  extern proc ct_monotonic_ms(): int(64);
  extern proc ct_random_uuid(output: c_ptr(c_char));
  extern proc ct_json_quote(value: c_ptrConst(c_char)): c_ptr(c_char);
  extern proc ct_deployment_url(value: c_ptrConst(c_char),
                                websocket: c_int): c_ptr(c_char);
  extern proc ct_json_is_object(json: c_ptrConst(c_char)): c_int;
  extern proc ct_json_get_raw(json: c_ptrConst(c_char),
                              field: c_ptrConst(c_char),
                              ref output: c_ptr(c_char)): c_int;
  extern proc ct_json_get_string(json: c_ptrConst(c_char),
                                 field: c_ptrConst(c_char),
                                 ref output: c_ptr(c_char)): c_int;
  extern proc ct_json_get_uint32(json: c_ptrConst(c_char),
                                 field: c_ptrConst(c_char),
                                 ref output: uint(32)): c_int;
  extern proc ct_json_array_length(json: c_ptrConst(c_char),
                                   field: c_ptrConst(c_char)): c_int;
  extern proc ct_json_array_raw(json: c_ptrConst(c_char),
                                field: c_ptrConst(c_char), entryIndex: c_int,
                                ref output: c_ptr(c_char)): c_int;
  extern proc ct_json_get_string_array(json: c_ptrConst(c_char),
                                       field: c_ptrConst(c_char),
                                       ref output: c_ptr(c_char)): c_int;
  extern proc ct_validate_adapter_command(
    json: c_ptrConst(c_char),
    ref safeId: c_ptr(c_char),
    ref errorMessage: c_ptr(c_char)
  ): c_int;
  extern proc ct_valid_http_field_value(value: c_ptrConst(c_char),
                                         length: c_size_t): c_int;
  extern proc ct_valid_text_boundary(value: c_ptrConst(c_char),
                                      length: c_size_t): c_int;
  extern proc ct_json_equal(left: c_ptrConst(c_char),
                            right: c_ptrConst(c_char)): c_int;
  extern proc ct_json_integral_field(json: c_ptrConst(c_char),
                                     field: c_ptrConst(c_char),
                                     ref output: int(64)): c_int;
  extern proc ct_timestamp_compare(left: c_ptrConst(c_char),
                                   right: c_ptrConst(c_char),
                                   ref comparison: c_int): c_int;
  extern proc ct_http_post(url: c_ptrConst(c_char), urlLength: c_size_t,
                           clientVersion: c_ptrConst(c_char),
                           clientVersionLength: c_size_t,
                           token: c_ptrConst(c_char), tokenLength: c_size_t,
                           body: c_ptrConst(c_char), bodyLength: c_size_t,
                           deadline: int(64), ref response: c_ptr(c_char),
                           ref responseLength: c_size_t,
                           ref errorMessage: c_ptr(c_char)): c_int;
  extern proc ct_ws_connect(url: c_ptrConst(c_char), urlLength: c_size_t,
                            clientVersion: c_ptrConst(c_char),
                            clientVersionLength: c_size_t,
                            deadline: int(64),
                            ref errorMessage: c_ptr(c_char)): c_ptr(chapel_ws);
  extern proc ct_ws_send(socket: c_ptr(chapel_ws),
                         message: c_ptrConst(c_char), length: c_size_t,
                         deadline: int(64),
                         ref errorMessage: c_ptr(c_char)): c_int;
  extern proc ct_ws_receive(socket: c_ptr(chapel_ws), deadline: int(64),
                            ref message: c_ptr(c_char),
                            ref messageLength: c_size_t,
                            ref errorMessage: c_ptr(c_char)): c_int;
  extern proc ct_ws_interrupt(socket: c_ptr(chapel_ws));
  extern proc ct_ws_close(socket: c_ptr(chapel_ws), deadline: int(64));
  extern proc ct_adapter_accept(address: c_ptrConst(c_char),
                                addressLength: c_size_t,
                                ref errorMessage: c_ptr(c_char)): c_int;
  extern proc ct_read_line(fd: c_int, limit: c_size_t,
                           ref line: c_ptr(c_char),
                           ref lineLength: c_size_t,
                           ref errorMessage: c_ptr(c_char)): c_int;
  extern proc ct_write_line(fd: c_int, line: c_ptrConst(c_char),
                            length: c_size_t, deadline: int(64),
                            ref errorMessage: c_ptr(c_char)): c_int;
  extern proc ct_interrupt_fd(fd: c_int);
  extern proc ct_close_fd(fd: c_int);
  extern proc ct_exit_process(status: c_int);

  proc monotonicMillis(): int(64) do return ct_monotonic_ms();

  private proc takeCString(ref value: c_ptr(c_char)): string {
    if value == nil then return "";
    var result = "";
    try { result = string.createCopyingBuffer(value); } catch { }
    ct_free(value: c_ptr(void));
    value = nil;
    return result;
  }

  private proc takeExactString(ref value: c_ptr(c_char),
                               length: c_size_t): string {
    if value == nil then return "";
    var result = "";
    try { result = string.createCopyingBuffer(value, length:int); } catch { }
    ct_free(value: c_ptr(void));
    value = nil;
    return result;
  }

  proc environment(name: string): string {
    var value = ct_getenv_copy(name.c_str());
    return takeCString(value);
  }

  proc randomUUID(): string {
    var uuidBytes: c_array(c_char, 37);
    ct_random_uuid(uuidBytes);
    try {
      return string.createCopyingBuffer(c_ptrTo(uuidBytes[0]), 36);
    } catch {
      return "00000000-0000-4000-8000-000000000000";
    }
  }

  proc jsonQuote(value: string): string {
    if !validTextBoundary(value) then return "null";
    var encoded = ct_json_quote(value.c_str());
    return takeCString(encoded);
  }

  proc deploymentURL(value: string, websocket = false): (bool, string) {
    if !validTextBoundary(value) then return (false, "");
    var normalized = ct_deployment_url(value.c_str(), websocket:c_int);
    if normalized == nil then return (false, "");
    return (true, takeCString(normalized));
  }

  proc jsonIsObject(value: string): bool {
    if !validTextBoundary(value) then return false;
    return ct_json_is_object(value.c_str()) == 1;
  }

  proc jsonRaw(value: string, field: string): (bool, string) {
    if !validTextBoundary(value) || !validTextBoundary(field) then
      return (false, "");
    var output: c_ptr(c_char) = nil;
    const status = ct_json_get_raw(value.c_str(), field.c_str(), output);
    return (status == 1, takeCString(output));
  }

  proc jsonString(value: string, field: string): (bool, string) {
    if !validTextBoundary(value) || !validTextBoundary(field) then
      return (false, "");
    var output: c_ptr(c_char) = nil;
    const status = ct_json_get_string(value.c_str(), field.c_str(), output);
    return (status == 1, takeCString(output));
  }

  proc jsonUInt32(value: string, field: string): (bool, uint(32)) {
    if !validTextBoundary(value) || !validTextBoundary(field) then
      return (false, 0:uint(32));
    var output: uint(32) = 0;
    const status = ct_json_get_uint32(value.c_str(), field.c_str(), output);
    return (status == 1, output);
  }

  proc jsonArrayLength(value: string, field: string): int {
    if !validTextBoundary(value) || !validTextBoundary(field) then return -1;
    return ct_json_array_length(value.c_str(), field.c_str()): int;
  }

  proc jsonArrayRaw(value: string, field: string,
                    entryIndex: int): (bool, string) {
    if !validTextBoundary(value) || !validTextBoundary(field) then
      return (false, "");
    var output: c_ptr(c_char) = nil;
    const status = ct_json_array_raw(value.c_str(), field.c_str(),
                                     entryIndex:c_int, output);
    return (status == 1, takeCString(output));
  }

  proc jsonStringArray(value: string, field: string): (int, string) {
    if !validTextBoundary(value) || !validTextBoundary(field) then
      return (-1, "");
    var output: c_ptr(c_char) = nil;
    const status = ct_json_get_string_array(value.c_str(), field.c_str(),
                                             output);
    return (status:int, takeCString(output));
  }

  record adapterValidation {
    var ok = false;
    var safeId = "";
    var errorMessage = "";
  }

  proc validateAdapterCommand(value: string): adapterValidation {
    if !validTextBoundary(value) then return new adapterValidation(
      errorMessage="adapter command is not exact UTF-8 text"
    );
    var safeId: c_ptr(c_char) = nil;
    var errorMessage: c_ptr(c_char) = nil;
    const status = ct_validate_adapter_command(value.c_str(), safeId,
                                                errorMessage);
    return new adapterValidation(status == 1, takeCString(safeId),
                                 takeCString(errorMessage));
  }

  proc validHttpFieldValue(value: string): bool {
    return ct_valid_http_field_value(
      value.c_str(), value.numBytes:c_size_t
    ) == 1;
  }

  proc validTextBoundary(value: string): bool {
    return ct_valid_text_boundary(value.c_str(), value.numBytes:c_size_t) == 1;
  }

  proc jsonEqual(left: string, right: string): bool {
    if !validTextBoundary(left) || !validTextBoundary(right) then return false;
    return ct_json_equal(left.c_str(), right.c_str()) == 1;
  }

  proc jsonIntegralField(value: string, field: string): (bool, int(64)) {
    if !validTextBoundary(value) || !validTextBoundary(field) then
      return (false, 0:int(64));
    var output: int(64) = 0;
    const status = ct_json_integral_field(value.c_str(), field.c_str(),
                                          output);
    return (status == 1, output);
  }

  proc timestampCompare(left: string, right: string): (bool, int) {
    if !validTextBoundary(left) || !validTextBoundary(right) then
      return (false, 0);
    var comparison: c_int = 0;
    const status = ct_timestamp_compare(left.c_str(), right.c_str(),
                                        comparison);
    return (status == 1, comparison:int);
  }

  record httpTransportResult {
    var ok = false;
    var body = "";
    var errorMessage = "";
  }

  proc httpPost(url: string, clientVersion: string, token: string,
                body: string, deadline: int(64)): httpTransportResult {
    if !validHttpFieldValue(clientVersion) || !validHttpFieldValue(token) then
      return new httpTransportResult(
        errorMessage="invalid HTTP header field value"
      );
    var response: c_ptr(c_char) = nil;
    var responseLength: c_size_t = 0;
    var errorMessage: c_ptr(c_char) = nil;
    const status = ct_http_post(url.c_str(), url.numBytes:c_size_t,
                                clientVersion.c_str(),
                                clientVersion.numBytes:c_size_t,
                                token.c_str(), token.numBytes:c_size_t,
                                body.c_str(), body.numBytes:c_size_t, deadline,
                                response, responseLength, errorMessage);
    return new httpTransportResult(status == 1,
                                   takeExactString(response, responseLength),
                                   takeCString(errorMessage));
  }

  record receiveResult {
    var status = 0;
    var message = "";
    var errorMessage = "";
  }

  class WebSocket {
    var handle: c_ptr(chapel_ws) = nil;

    proc connect(url: string, clientVersion: string,
                     deadline: int(64)): string {
      if !validHttpFieldValue(clientVersion) then
        return "invalid HTTP header field value";
      var errorMessage: c_ptr(c_char) = nil;
      handle = ct_ws_connect(url.c_str(), url.numBytes:c_size_t,
                             clientVersion.c_str(),
                             clientVersion.numBytes:c_size_t, deadline,
                             errorMessage);
      return takeCString(errorMessage);
    }

    proc send(message: string, deadline: int(64)): string {
      var errorMessage: c_ptr(c_char) = nil;
      const status = ct_ws_send(handle, message.c_str(),
                                message.numBytes:c_size_t, deadline,
                                errorMessage);
      const detail = takeCString(errorMessage);
      if status == 1 then return "";
      return detail;
    }

    proc receive(deadline: int(64)): receiveResult {
      var message: c_ptr(c_char) = nil;
      var messageLength: c_size_t = 0;
      var errorMessage: c_ptr(c_char) = nil;
      const status = ct_ws_receive(handle, deadline, message, messageLength,
                                   errorMessage);
      return new receiveResult(status:int,
                               takeExactString(message, messageLength),
                               takeCString(errorMessage));
    }

    proc interrupt() { ct_ws_interrupt(handle); }

    proc close(deadline: int(64)) {
      if handle != nil then ct_ws_close(handle, deadline);
      handle = nil;
    }
  }

  proc adapterAccept(address: string): (int, string) {
    if !validTextBoundary(address) then return (-1, "invalid listen address");
    var errorMessage: c_ptr(c_char) = nil;
    const fd = ct_adapter_accept(address.c_str(), address.numBytes:c_size_t,
                                 errorMessage);
    return (fd:int, takeCString(errorMessage));
  }

  proc readLine(fd: int, limit: int): (int, string, string) {
    var line: c_ptr(c_char) = nil;
    var lineLength: c_size_t = 0;
    var errorMessage: c_ptr(c_char) = nil;
    const status = ct_read_line(fd:c_int, limit:c_size_t, line, lineLength,
                                errorMessage);
    return (status:int, takeExactString(line, lineLength),
            takeCString(errorMessage));
  }

  proc writeLine(fd: int, line: string, deadline: int(64)): string {
    var errorMessage: c_ptr(c_char) = nil;
    const status = ct_write_line(fd:c_int, line.c_str(),
                                 line.numBytes:c_size_t, deadline,
                                 errorMessage);
    const detail = takeCString(errorMessage);
    if status == 1 then return "";
    return detail;
  }

  proc closeFd(fd: int) { ct_close_fd(fd:c_int); }
  proc interruptFd(fd: int) { ct_interrupt_fd(fd:c_int); }
  proc exitProcess(status: int) { ct_exit_process(status:c_int); }
}
