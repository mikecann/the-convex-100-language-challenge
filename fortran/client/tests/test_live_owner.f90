program test_live_owner
  use, intrinsic :: iso_c_binding, only: c_int, c_int64_t
  use convex_fortran
  implicit none

  interface
    function ft_live_fixture_start() bind(c, name='ft_live_fixture_start') result(port)
      import :: c_int
      integer(c_int) :: port
    end function ft_live_fixture_start

    subroutine ft_live_fixture_update() bind(c, name='ft_live_fixture_update')
    end subroutine ft_live_fixture_update

    subroutine ft_live_fixture_function_error() bind(c, name='ft_live_fixture_function_error')
    end subroutine ft_live_fixture_function_error

    subroutine ft_live_fixture_protocol_error() bind(c, name='ft_live_fixture_protocol_error')
    end subroutine ft_live_fixture_protocol_error

    subroutine ft_live_fixture_transport_error() bind(c, name='ft_live_fixture_transport_error')
    end subroutine ft_live_fixture_transport_error

    function ft_live_fixture_wait_adds(expected, timeout_ms) bind(c, name='ft_live_fixture_wait_adds') result(ready)
      import :: c_int
      integer(c_int), value :: expected, timeout_ms
      integer(c_int) :: ready
    end function ft_live_fixture_wait_adds

    function ft_live_fixture_wait_removes(expected, timeout_ms) bind(c, name='ft_live_fixture_wait_removes') result(ready)
      import :: c_int
      integer(c_int), value :: expected, timeout_ms
      integer(c_int) :: ready
    end function ft_live_fixture_wait_removes

    subroutine ft_live_fixture_stop() bind(c, name='ft_live_fixture_stop')
    end subroutine ft_live_fixture_stop

    function ft_monotonic_ms() bind(c, name='ft_monotonic_ms') result(value)
      import :: c_int64_t
      integer(c_int64_t) :: value
    end function ft_monotonic_ms
  end interface

  type(convex_client) :: client
  type(convex_live) :: live
  character(32) :: port_text
  character(:), allocatable :: url, value, error, logs, error_name, error_data
  character(:), allocatable :: close_reason, maximum_timestamp
  logical :: ok
  integer(c_int) :: port
  integer(c_int64_t) :: close_started
  integer :: attempt, connection_count

  port = ft_live_fixture_start()
  if (port <= 0) error stop 'real WebSocket fixture did not start'
  write (port_text, '(I0)') port
  url = 'http://127.0.0.1:' // trim(port_text)

  call convex_new(url, client, ok, error)
  if (.not. ok) error stop error
  call convex_live_start(client, 'demo:get', '{}', live, ok, error)
  if (.not. ok) error stop error
  if (ft_live_fixture_wait_adds(1_c_int, 2000_c_int) == 0) error stop 'initial Add was not observed'
  call expect_value(0)

  ! QueryFailed is a subscription event, not a terminal state. The same query
  ! must recover when the fixture sends its next valid transition.
  call ft_live_fixture_function_error()
  call convex_live_next(live, value, ok, error, logs, error_name, error_data, 2000)
  if (ok .or. error_name /= 'FunctionError' .or. index(error_data, 'ROOM_EMPTY') == 0) &
    error stop 'QueryFailed was not structured or recoverable'
  call ft_live_fixture_update()
  call expect_value(1)

  ! A debug acknowledgement is a transport barrier. Every acknowledgement
  ! below means the old socket is retired and the replacement Add was sent.
  do attempt = 1, 5
    call convex_live_debug_disconnect(ok, error)
    if (.not. ok) error stop error
    if (ft_live_fixture_wait_adds(int(attempt + 1, c_int), 2000_c_int) == 0) &
      error stop 'reconnect did not resend the active Add'
    call convex_live_next(live, value, ok, error, timeout_ms=100)
    if (ok .or. index(error, 'timed out') == 0) error stop 'unchanged reconnect hydration leaked'
  end do
  call convex_live_metadata(connection_count, close_reason, maximum_timestamp)
  if (connection_count /= 5 .or. close_reason /= 'DebugDisconnect' .or. len(maximum_timestamp) == 0) &
    error stop 'reconnect metadata was not carried correctly'
  call ft_live_fixture_update()
  call expect_value(2)

  ! Protocol and transport failures are reported, then the owner reconnects
  ! and the still-valid subscription delivers a later update.
  call ft_live_fixture_protocol_error()
  call expect_error('ProtocolError')
  if (ft_live_fixture_wait_adds(7_c_int, 3000_c_int) == 0) error stop 'protocol recovery did not re-Add'
  call convex_live_next(live, value, ok, error, timeout_ms=100)
  if (ok .or. index(error, 'timed out') == 0) error stop 'protocol recovery hydration leaked'
  call ft_live_fixture_update()
  call expect_value(3)

  call ft_live_fixture_transport_error()
  call expect_error('TransportError')
  if (ft_live_fixture_wait_adds(8_c_int, 3000_c_int) == 0) error stop 'transport recovery did not re-Add'
  call convex_live_next(live, value, ok, error, timeout_ms=100)
  if (ok .or. index(error, 'timed out') == 0) error stop 'transport recovery hydration leaked'
  call ft_live_fixture_update()
  call expect_value(4)

  call convex_live_unsubscribe(live, ok, error)
  if (.not. ok) error stop error
  if (ft_live_fixture_wait_removes(1_c_int, 2000_c_int) == 0) error stop 'Remove was not observed before acknowledgement'

  close_started = ft_monotonic_ms()
  call convex_live_close()
  if (ft_monotonic_ms() - close_started > 2000_c_int64_t) error stop 'Live close exceeded its healthy deadline'
  call ft_live_fixture_stop()

  write (*, '(A)') 'PASS real sole-owner Live reconnect and recovery fixture'

contains

  subroutine expect_value(expected)
    integer, intent(in) :: expected
    integer :: actual
    call convex_live_next(live, value, ok, error, logs, error_name, error_data, 2000)
    if (.not. ok) error stop error
    actual = convex_count(value, ok)
    if (.not. ok .or. actual /= expected) error stop 'Live fixture delivered an unexpected value'
  end subroutine expect_value

  subroutine expect_error(expected_name)
    character(*), intent(in) :: expected_name
    call convex_live_next(live, value, ok, error, logs, error_name, error_data, 3000)
    if (ok .or. error_name /= expected_name) error stop 'Live fixture delivered the wrong structured error'
  end subroutine expect_error

end program test_live_owner
