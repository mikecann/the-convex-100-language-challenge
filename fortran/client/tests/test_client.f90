program test_client
  use convex_fortran
  implicit none
  logical :: found, ok
  character(:), allocatable :: value, error, error_name, timestamp, maximum_timestamp
  integer :: count, queued, bytes, sequence

  value = convex_json_member('{"value":{"text":"a, b","nested":[1,{"ok":true}]},"status":"success"}', 'value', found)
  if (.not. found .or. value /= '{"text":"a, b","nested":[1,{"ok":true}]}') error stop 'nested JSON extraction failed'
  value = convex_json_member('{"nested":{"id":"wrong"},"id":"right"}', 'id', found)
  if (.not. found .or. value /= '"right"') error stop 'nested key shadowed a top-level member'
  value = convex_json_member('{"id":"first","id":"second"}', 'id', found)
  if (found) error stop 'duplicate top-level JSON member was accepted'
  value = json_string('"Fortran \u03BB \uD83D\uDE80"', ok)
  if (.not. ok .or. value /= 'Fortran ' // char(206) // char(187) // ' ' // &
      char(240) // char(159) // char(154) // char(128)) error stop 'escaped Unicode was not decoded as UTF-8'
  if (.not. convex_json_string_array('["first","second\\nline"]')) error stop 'valid logLines was rejected'
  if (convex_json_string_array('null')) error stop 'null logLines was accepted'
  if (convex_json_string_array('["first",7]')) error stop 'mixed logLines was accepted'

  count = convex_count('{"count":1.0}', ok)
  if (.not. ok .or. count /= 1) error stop 'integral decimal count was rejected'
  count = convex_count('{"count":1.5}', ok)
  if (ok) error stop 'fractional count was accepted'
  count = convex_count('{"count":"1"}', ok)
  if (ok) error stop 'quoted count was accepted'
  count = convex_count('{"count":NaN}', ok)
  if (ok) error stop 'non-finite count was accepted'
  count = convex_count('{"count":1e999}', ok)
  if (ok) error stop 'overflowing floating-point count was accepted'
  count = convex_count('{"count":2147483648}', ok)
  if (ok) error stop 'overflowing integer count was accepted'

  call convex_test_live_begin()
  call convex_test_live_apply(transition(0, 1, updated('{"count":0}')), ok, error)
  if (.not. ok) error stop error
  call convex_test_live_next(value, ok, error, error_name)
  if (.not. ok .or. value /= '{"count":0}') error stop 'initial QueryUpdated was not delivered'

  call convex_test_live_apply(transition(1, 2, failed()), ok, error)
  if (.not. ok) error stop error
  call convex_test_live_next(value, ok, error, error_name)
  if (ok .or. error_name /= 'FunctionError' .or. index(error, 'fixture failure') == 0) &
    error stop 'QueryFailed was not structured'
  call convex_test_live_apply(transition(2, 3, updated('{"count":1}')), ok, error)
  if (.not. ok) error stop error
  call convex_test_live_next(value, ok, error, error_name)
  if (.not. ok .or. value /= '{"count":1}') error stop 'QueryFailed stranded its subscription'

  ! The first modification must not leak when a later modification makes the
  ! whole transition invalid. A valid transition with the same start version
  ! proves that state and output publication were transactional.
  call convex_test_live_apply(transition(3, 4, updated('{"count":2}') // &
    ',{"type":"Unknown","queryId":0}'), ok, error)
  if (ok) error stop 'malformed transition was accepted'
  call convex_test_live_apply(transition(3, 4, updated('{"count":2}')), ok, error)
  if (.not. ok) error stop 'malformed transition mutated state before rejection'
  call convex_test_live_next(value, ok, error, error_name)
  if (.not. ok .or. value /= '{"count":2}') error stop 'valid recovery after protocol error failed'

  ! Invalid logs reject the whole transition before either its version or
  ! query value can change. The same valid transition must still apply.
  call convex_test_live_apply(transition(4, 5, updated_with_logs('{"count":3}', 'null')), ok, error)
  if (ok .or. index(error, 'logLines') == 0) error stop 'null Live logLines was accepted'
  call convex_test_live_apply(transition(4, 5, updated_with_logs('{"count":3}', '["valid",7]')), ok, error)
  if (ok .or. index(error, 'logLines') == 0) error stop 'mixed Live logLines was accepted'
  call convex_test_live_apply(transition(4, 5, updated('{"count":3}')), ok, error)
  if (.not. ok) error stop 'invalid Live logs mutated transition state'
  call convex_test_live_next(value, ok, error, error_name)
  if (.not. ok .or. value /= '{"count":3}') error stop 'valid recovery after invalid Live logs failed'

  do sequence = 6, 24
    call convex_test_live_apply(transition(sequence - 1, sequence, updated('{"count":' // integer_text(sequence) // '}')), ok, error)
    if (.not. ok) error stop error
  end do
  call convex_test_live_stats(queued, bytes, maximum_timestamp)
  if (queued /= 16 .or. bytes >= 32 * 1024 * 1024) error stop 'Live newest-16 count/byte bound failed'
  timestamp = encode_timestamp(24)
  if (maximum_timestamp /= timestamp) error stop 'maxObservedTimestamp was not monotonic uint64'
  call convex_test_live_next(value, ok, error, error_name)
  if (.not. ok .or. value /= '{"count":9}') error stop 'Live queue did not retain the global newest 16'
  call convex_test_live_end()

  call convex_test_live_begin()
  call convex_test_live_apply('{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},' // &
    '"endVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAB="},"modifications":[]}', ok, error)
  if (ok) error stop 'non-canonical little-endian uint64 timestamp was accepted'
  call convex_test_live_end()

  write (*, '(A)') 'PASS Fortran JSON and transactional Live state tests'

contains

  function transition(start, finish, modifications) result(message)
    integer, intent(in) :: start, finish
    character(*), intent(in) :: modifications
    character(:), allocatable :: message
    message = '{"type":"Transition","startVersion":{"querySet":' // integer_text(merge(0, 1, start == 0)) // &
      ',"identity":0,"ts":' // quote(encode_timestamp(start)) // '},"endVersion":{"querySet":1,"identity":0,"ts":' // &
      quote(encode_timestamp(finish)) // '},"modifications":[' // modifications // ']}'
  end function

  function updated(json) result(modification)
    character(*), intent(in) :: json
    character(:), allocatable :: modification
    modification = '{"type":"QueryUpdated","queryId":0,"value":' // json // ',"logLines":[]}'
  end function

  function updated_with_logs(json, logs) result(modification)
    character(*), intent(in) :: json, logs
    character(:), allocatable :: modification
    modification = '{"type":"QueryUpdated","queryId":0,"value":' // json // ',"logLines":' // logs // '}'
  end function

  function failed() result(modification)
    character(:), allocatable :: modification
    modification = '{"type":"QueryFailed","queryId":0,"errorMessage":"fixture failure","errorData":{"code":7},"logLines":[]}'
  end function

  function integer_text(number) result(text)
    integer, intent(in) :: number
    character(:), allocatable :: text
    character(32) :: buffer
    write(buffer, '(I0)') number
    text = trim(buffer)
  end function

  function encode_timestamp(number) result(encoded)
    integer, intent(in) :: number
    character(:), allocatable :: encoded
    character(*), parameter :: alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    integer :: bytes(8), values(12), index, at, current, carry
    bytes = 0
    current = number
    do index = 1, 8
      bytes(index) = modulo(current, 256)
      current = current / 256
    end do
    at = 1
    do index = 1, 4, 3
      carry = ishft(bytes(index), 16)
      carry = carry + ishft(bytes(index + 1), 8) + bytes(index + 2)
      values(at) = iand(ishft(carry, -18), 63)
      values(at + 1) = iand(ishft(carry, -12), 63)
      values(at + 2) = iand(ishft(carry, -6), 63)
      values(at + 3) = iand(carry, 63)
      at = at + 4
    end do
    carry = ishft(bytes(7), 16) + ishft(bytes(8), 8)
    values(9) = iand(ishft(carry, -18), 63)
    values(10) = iand(ishft(carry, -12), 63)
    values(11) = iand(ishft(carry, -6), 63)
    values(12) = iand(carry, 63)
    encoded = ''
    do index = 1, 11
      encoded = encoded // alphabet(values(index) + 1:values(index) + 1)
    end do
    encoded = encoded // '='
  end function

  function quote(text) result(encoded)
    character(*), intent(in) :: text
    character(:), allocatable :: encoded
    encoded = '"' // text // '"'
  end function

end program test_client
