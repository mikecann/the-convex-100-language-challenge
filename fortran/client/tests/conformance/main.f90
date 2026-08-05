module adapter_state
  use, intrinsic :: iso_c_binding, only: c_ptr, c_null_ptr, c_associated, c_funloc
  use convex_fortran
  use adapter_transport
  implicit none
  private

  integer, parameter :: maximum_events = 16
  integer, parameter :: maximum_event_bytes = 32 * 1024 * 1024
  integer, parameter :: maximum_subscriptions = 64

  type :: queued_event
    character(:), allocatable :: line
    character(:), allocatable :: relay_key
  end type

  type :: adapter_subscription
    logical :: occupied = .false.
    logical :: active = .false.
    integer :: generation = 0
    character(:), allocatable :: id
    type(convex_live) :: live
  end type

  type(c_ptr), save :: output_stream = c_null_ptr
  type(c_ptr), save :: output_mutex = c_null_ptr
  type(c_ptr), save :: output_condition = c_null_ptr
  type(c_ptr), save :: output_thread = c_null_ptr
  logical, save :: output_closing = .false.
  logical, save :: output_failed = .false.
  integer, save :: event_count = 0
  integer, save :: event_bytes = 0
  type(queued_event), save :: events(maximum_events)

  type(c_ptr), save :: subscription_mutex = c_null_ptr
  type(c_ptr), save :: subscription_condition = c_null_ptr
  type(c_ptr), save :: subscription_thread = c_null_ptr
  logical, save :: subscription_closing = .false.
  type(adapter_subscription), save :: subscriptions(maximum_subscriptions)

#ifdef FORTRAN_ADAPTER_TESTING
  type(c_ptr), save :: relay_test_mutex = c_null_ptr
  type(c_ptr), save :: relay_test_condition = c_null_ptr
  type(c_ptr), save :: relay_test_thread = c_null_ptr
  logical, save :: relay_test_pause = .false.
  logical, save :: relay_test_paused = .false.
#endif

  public :: state_start, state_finish, emit_event, emit_subscription
  public :: subscription_start, subscription_activate, subscription_stop
#ifdef FORTRAN_ADAPTER_TESTING
  public :: adapter_test_begin, adapter_test_install, adapter_test_start_relay
  public :: adapter_test_wait_paused, adapter_test_invalidate, adapter_test_release
  public :: adapter_test_join, adapter_test_event_count, adapter_test_finish
#endif

contains

  subroutine state_start(stream, ok)
    type(c_ptr), intent(in) :: stream
    logical, intent(out) :: ok
    output_stream = stream
    output_mutex = mutex_new()
    output_condition = condition_new()
    subscription_mutex = mutex_new()
    subscription_condition = condition_new()
    ok = c_associated(output_mutex) .and. c_associated(output_condition) .and. &
      c_associated(subscription_mutex) .and. c_associated(subscription_condition)
    if (.not. ok) return
    output_thread = thread_start(c_funloc(output_worker))
    subscription_thread = thread_start(c_funloc(subscription_worker))
    ok = c_associated(output_thread) .and. c_associated(subscription_thread)
  end subroutine

  subroutine emit_event(line)
    character(*), intent(in) :: line
    call enqueue(line, '')
  end subroutine

  subroutine emit_subscription(subscription_id, value, logs, error_name, error_message, error_data, failed)
    character(*), intent(in) :: subscription_id, value, logs, error_name, error_message, error_data
    logical, intent(in) :: failed
    character(:), allocatable :: line
    if (failed) then
      line = '{"type":"subscription","subscriptionId":' // json_quote(subscription_id) // &
        ',"error":{"name":' // json_quote(error_name) // ',"message":' // json_quote(error_message)
      if (len(error_data) > 0) line = line // ',"data":' // error_data
      line = line // '}}'
    else
      line = '{"type":"subscription","subscriptionId":' // json_quote(subscription_id) // &
        ',"value":' // value // ',"logs":' // merge(logs, '[]', len(logs) > 0) // '}'
    end if
    call enqueue(line, subscription_id)
  end subroutine

  subroutine enqueue(line, relay_key)
    character(*), intent(in) :: line, relay_key
    integer :: index, needed
    if (len(line) > 2 * 1024 * 1024) return
    needed = len(line) + 256
    call mutex_lock(output_mutex)
    if (output_closing .or. output_failed) then
      call mutex_unlock(output_mutex)
      return
    end if
    if (len(relay_key) > 0) then
      index = 1
      do while (index <= event_count)
        if (allocated(events(index)%relay_key)) then
          if (events(index)%relay_key == relay_key) then
            call remove_event(index)
            exit
          end if
        end if
        index = index + 1
      end do
    end if
    do while (event_count >= maximum_events .or. event_bytes + needed > maximum_event_bytes)
      if (event_count == 0) exit
      call remove_event(1)
    end do
    if (event_bytes + needed <= maximum_event_bytes) then
      event_count = event_count + 1
      events(event_count)%line = line
      events(event_count)%relay_key = relay_key
      event_bytes = event_bytes + needed
      call condition_broadcast(output_condition)
    end if
    call mutex_unlock(output_mutex)
  end subroutine

  subroutine remove_event(position)
    integer, intent(in) :: position
    integer :: index
    if (position < 1 .or. position > event_count) return
    event_bytes = event_bytes - len(events(position)%line) - 256
    if (allocated(events(position)%line)) deallocate(events(position)%line)
    if (allocated(events(position)%relay_key)) deallocate(events(position)%relay_key)
    do index = position, event_count - 1
      events(index) = events(index + 1)
    end do
    if (allocated(events(event_count)%line)) deallocate(events(event_count)%line)
    if (allocated(events(event_count)%relay_key)) deallocate(events(event_count)%relay_key)
    event_count = event_count - 1
  end subroutine

  function output_worker(argument) bind(c) result(result)
    type(c_ptr), value :: argument
    type(c_ptr) :: result
    character(:), allocatable :: line
    logical :: written
    integer :: ignored
    result = argument
    do
      call mutex_lock(output_mutex)
      do while (event_count == 0 .and. .not. output_closing)
        ignored = condition_wait(output_condition, output_mutex, 100)
      end do
      if (event_count == 0 .and. output_closing) then
        call mutex_unlock(output_mutex)
        exit
      end if
      line = events(1)%line
      call remove_event(1)
      call mutex_unlock(output_mutex)
      written = stream_write_line(output_stream, line)
      if (.not. written) then
        call mutex_lock(output_mutex)
        output_failed = .true.
        output_closing = .true.
        do while (event_count > 0)
          call remove_event(1)
        end do
        call mutex_unlock(output_mutex)
        exit
      end if
    end do
  end function

  subroutine subscription_start(client, subscription_id, path, args, slot, generation, ok, error)
    type(convex_client), intent(in) :: client
    character(*), intent(in) :: subscription_id, path, args
    integer, intent(out) :: slot, generation
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error
    type(convex_live) :: old_live, new_live
    logical :: had_old, removed
    character(:), allocatable :: remove_error
    integer :: index

    slot = 0
    generation = 0
    had_old = .false.
    call mutex_lock(subscription_mutex)
    do index = 1, maximum_subscriptions
      if (subscriptions(index)%occupied .and. subscriptions(index)%id == subscription_id) then
        had_old = .true.
        old_live = subscriptions(index)%live
        subscriptions(index)%active = .false.
        subscriptions(index)%generation = subscriptions(index)%generation + 1
        exit
      end if
    end do
    call mutex_unlock(subscription_mutex)
    if (had_old) then
      call convex_live_unsubscribe(old_live, removed, remove_error)
      if (.not. removed) then
        ok = .false.
        error = remove_error
        return
      end if
    end if

    call convex_live_start(client, path, args, new_live, ok, error)
    if (.not. ok) return
    call mutex_lock(subscription_mutex)
    if (had_old) then
      slot = index
    else
      do index = 1, maximum_subscriptions
        if (.not. subscriptions(index)%occupied) then
          slot = index
          exit
        end if
      end do
    end if
    if (slot == 0) then
      call mutex_unlock(subscription_mutex)
      call convex_live_unsubscribe(new_live, removed, remove_error)
      ok = .false.
      error = 'TransportError: adapter subscription limit reached'
      return
    end if
    subscriptions(slot)%occupied = .true.
    subscriptions(slot)%active = .false.
    subscriptions(slot)%generation = subscriptions(slot)%generation + 1
    subscriptions(slot)%id = subscription_id
    subscriptions(slot)%live = new_live
    generation = subscriptions(slot)%generation
    call mutex_unlock(subscription_mutex)
    ok = .true.
    error = ''
  end subroutine

  subroutine subscription_activate(slot, generation)
    integer, intent(in) :: slot, generation
    call mutex_lock(subscription_mutex)
    if (slot >= 1 .and. slot <= maximum_subscriptions) then
      if (subscriptions(slot)%occupied .and. subscriptions(slot)%generation == generation) then
        subscriptions(slot)%active = .true.
        call condition_broadcast(subscription_condition)
      end if
    end if
    call mutex_unlock(subscription_mutex)
  end subroutine

  subroutine subscription_stop(subscription_id, ok, error)
    character(*), intent(in) :: subscription_id
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error
    type(convex_live) :: live
    logical :: found
    integer :: index
    found = .false.
    call mutex_lock(subscription_mutex)
    do index = 1, maximum_subscriptions
      if (subscriptions(index)%occupied .and. subscriptions(index)%id == subscription_id) then
        live = subscriptions(index)%live
        subscriptions(index)%active = .false.
        subscriptions(index)%generation = subscriptions(index)%generation + 1
        found = .true.
        exit
      end if
    end do
    call mutex_unlock(subscription_mutex)
    if (.not. found) then
      ok = .true.
      error = ''
      return
    end if
    call convex_live_unsubscribe(live, ok, error)
    if (ok) then
      call mutex_lock(subscription_mutex)
      subscriptions(index) = adapter_subscription(generation=subscriptions(index)%generation)
      call mutex_unlock(subscription_mutex)
    end if
  end subroutine

  function subscription_worker(argument) bind(c) result(result)
    type(c_ptr), value :: argument
    type(c_ptr) :: result
    type(convex_live) :: live
    character(:), allocatable :: id, value, error, logs, error_name, error_data, message
    integer :: slot, generation, cursor, scan
    logical :: active, ok
    result = argument
    cursor = 0
    do
      call mutex_lock(subscription_mutex)
      if (subscription_closing) then
        call mutex_unlock(subscription_mutex)
        exit
      end if
      active = .false.
      do scan = 1, maximum_subscriptions
        cursor = mod(cursor, maximum_subscriptions) + 1
        if (subscriptions(cursor)%occupied .and. subscriptions(cursor)%active) then
          live = subscriptions(cursor)%live
          generation = subscriptions(cursor)%generation
          id = subscriptions(cursor)%id
          slot = cursor
          active = .true.
          exit
        end if
      end do
      call mutex_unlock(subscription_mutex)
      if (.not. active) then
        call mutex_lock(subscription_mutex)
        if (.not. subscription_closing) scan = condition_wait(subscription_condition, subscription_mutex, 20)
        call mutex_unlock(subscription_mutex)
        cycle
      end if
      call convex_live_next(live, value, ok, error, logs, error_name, error_data, 20)
      if (.not. ok .and. index(error, 'timed out') > 0) cycle
      if (.not. ok) then
        message = error
        if (index(message, ': ') > 0) message = message(index(message, ': ') + 2:)
        if (len(error_name) == 0) error_name = 'TransportError'
      end if
      call publish_if_current(slot, generation, id, value, logs, error_name, message, error_data, ok)
    end do
  end function

  subroutine publish_if_current(slot, generation, id, value, logs, error_name, message, error_data, ok)
    integer, intent(in) :: slot, generation
    character(*), intent(in) :: id, value, logs, error_name, message, error_data
    logical, intent(in) :: ok
    logical :: active
#ifdef FORTRAN_ADAPTER_TESTING
    integer :: ignored
    if (relay_test_pause) then
      call mutex_lock(relay_test_mutex)
      relay_test_paused = .true.
      call condition_broadcast(relay_test_condition)
      do while (relay_test_pause)
        ignored = condition_wait(relay_test_condition, relay_test_mutex, 20)
      end do
      call mutex_unlock(relay_test_mutex)
    end if
#endif
    ! Keep the generation check and output enqueue in one critical section.
    ! Unsubscribe and same-ID replacement cannot publish their ack between
    ! this check and a stale relay enqueue.
    call mutex_lock(subscription_mutex)
    active = subscriptions(slot)%occupied .and. subscriptions(slot)%active .and. &
      subscriptions(slot)%generation == generation
    if (active .and. ok) then
      call emit_subscription(id, value, logs, '', '', '', .false.)
    else if (active) then
      call emit_subscription(id, '', '', error_name, message, error_data, .true.)
    end if
    call mutex_unlock(subscription_mutex)
  end subroutine publish_if_current

#ifdef FORTRAN_ADAPTER_TESTING
  subroutine adapter_test_begin()
    output_mutex = mutex_new()
    output_condition = condition_new()
    subscription_mutex = mutex_new()
    subscription_condition = condition_new()
    relay_test_mutex = mutex_new()
    relay_test_condition = condition_new()
    output_closing = .false.
    output_failed = .false.
    event_count = 0
    event_bytes = 0
    subscriptions = adapter_subscription()
  end subroutine adapter_test_begin

  subroutine adapter_test_install(generation)
    integer, intent(in) :: generation
    call mutex_lock(subscription_mutex)
    subscriptions(1)%occupied = .true.
    subscriptions(1)%active = .true.
    subscriptions(1)%generation = generation
    subscriptions(1)%id = 'relay-fixture'
    call mutex_unlock(subscription_mutex)
  end subroutine adapter_test_install

  subroutine adapter_test_start_relay()
    relay_test_pause = .true.
    relay_test_paused = .false.
    relay_test_thread = thread_start(c_funloc(adapter_test_relay_worker))
  end subroutine adapter_test_start_relay

  function adapter_test_relay_worker(argument) bind(c) result(result)
    type(c_ptr), value :: argument
    type(c_ptr) :: result
    result = argument
    call publish_if_current(1, 1, 'relay-fixture', '{"count":1}', '[]', '', '', '', .true.)
  end function adapter_test_relay_worker

  subroutine adapter_test_wait_paused(ok)
    logical, intent(out) :: ok
    integer :: ignored, attempts
    call mutex_lock(relay_test_mutex)
    do attempts = 1, 100
      if (relay_test_paused) exit
      ignored = condition_wait(relay_test_condition, relay_test_mutex, 20)
    end do
    ok = relay_test_paused
    call mutex_unlock(relay_test_mutex)
  end subroutine adapter_test_wait_paused

  subroutine adapter_test_invalidate(replacement)
    logical, intent(in) :: replacement
    call mutex_lock(subscription_mutex)
    subscriptions(1)%active = replacement
    subscriptions(1)%generation = subscriptions(1)%generation + 1
    call mutex_unlock(subscription_mutex)
  end subroutine adapter_test_invalidate

  subroutine adapter_test_release()
    call mutex_lock(relay_test_mutex)
    relay_test_pause = .false.
    call condition_broadcast(relay_test_condition)
    call mutex_unlock(relay_test_mutex)
  end subroutine adapter_test_release

  subroutine adapter_test_join()
    call thread_join(relay_test_thread)
    relay_test_thread = c_null_ptr
  end subroutine adapter_test_join

  integer function adapter_test_event_count()
    call mutex_lock(output_mutex)
    adapter_test_event_count = event_count
    call mutex_unlock(output_mutex)
  end function adapter_test_event_count

  subroutine adapter_test_finish()
    do while (event_count > 0)
      call remove_event(1)
    end do
    call condition_free(relay_test_condition)
    call mutex_free(relay_test_mutex)
    call condition_free(subscription_condition)
    call mutex_free(subscription_mutex)
    call condition_free(output_condition)
    call mutex_free(output_mutex)
  end subroutine adapter_test_finish
#endif

  subroutine state_finish()
    type(convex_live) :: live(maximum_subscriptions)
    logical :: occupied(maximum_subscriptions), ok, joined
    character(:), allocatable :: ignored
    integer :: index
    call mutex_lock(subscription_mutex)
    subscription_closing = .true.
    call condition_broadcast(subscription_condition)
    do index = 1, maximum_subscriptions
      occupied(index) = subscriptions(index)%occupied
      if (occupied(index)) then
        subscriptions(index)%active = .false.
        subscriptions(index)%generation = subscriptions(index)%generation + 1
        live(index) = subscriptions(index)%live
      end if
    end do
    call mutex_unlock(subscription_mutex)
    joined = thread_join_bounded(subscription_thread, 2000)
    if (.not. joined) error stop 'adapter subscription relay close deadline exceeded'
    do index = 1, maximum_subscriptions
      if (occupied(index)) call convex_live_unsubscribe(live(index), ok, ignored)
    end do
    call convex_live_close()
    call condition_free(subscription_condition)
    call mutex_free(subscription_mutex)

    call mutex_lock(output_mutex)
    output_closing = .true.
    call condition_broadcast(output_condition)
    call mutex_unlock(output_mutex)
    joined = thread_join_bounded(output_thread, 12000)
    if (.not. joined) error stop 'adapter output close deadline exceeded'
    call condition_free(output_condition)
    call mutex_free(output_mutex)
  end subroutine

  function json_quote(text) result(value)
    character(*), intent(in) :: text
    character(:), allocatable :: value
    character(6) :: unicode
    integer :: index, code
    value = '"'
    do index = 1, len(text)
      code = iachar(text(index:index))
      select case (code)
      case (34)
        value = value // '\"'
      case (92)
        value = value // '\\'
      case (8)
        value = value // '\b'
      case (9)
        value = value // '\t'
      case (10)
        value = value // '\n'
      case (12)
        value = value // '\f'
      case (13)
        value = value // '\r'
      case (0:7, 11, 14:31)
        write (unicode, '("\\u",Z4.4)') code
        value = value // unicode
      case default
        value = value // text(index:index)
      end select
    end do
    value = value // '"'
  end function

end module adapter_state

#ifndef FORTRAN_ADAPTER_MODULE_ONLY
program adapter
  use, intrinsic :: iso_c_binding, only: c_ptr, c_null_ptr, c_associated
  use convex_fortran
  use adapter_transport
  use adapter_state
  implicit none

  type(c_ptr) :: stream
  type(convex_client) :: client
  character(:), allocatable :: listen, line, stream_error, id, operation, path, args, token
  character(:), allocatable :: subscription_id, value, error, logs, error_data, url, raw
#ifdef FORTRAN_ADAPTER_TESTING
  character(:), allocatable :: large_value
#endif
  logical :: found, decoded, ok, client_ready, state_ready, id_found, operation_found, shape_ok
  integer :: status, length, slot, generation

  client_ready = .false.
  call get_environment_variable('ADAPTER_LISTEN', length=length)
  if (length > 0) then
    allocate(character(length) :: listen)
    call get_environment_variable('ADAPTER_LISTEN', listen)
  else
    listen = ''
  end if
  stream = stream_open(listen, stream_error)
  if (.not. c_associated(stream)) error stop stream_error
  call state_start(stream, state_ready)
  if (.not. state_ready) error stop 'could not initialize bounded adapter workers'

  do
    call stream_read_line(stream, line, status, stream_error)
    if (status == 0) exit
    if (status == -2) then
      call emit_error('', 'ProtocolError', 'adapter command exceeds 2 MiB')
      cycle
    end if
    if (status == -3) then
      call emit_error('', 'ProtocolError', 'adapter command is not valid UTF-8')
      cycle
    end if
    if (status < 0) exit
    if (len(line) == 0) cycle
    if (line(1:1) /= '{' .or. line(len(line):len(line)) /= '}') then
      call emit_error('', 'ProtocolError', 'malformed JSON command')
      cycle
    end if
    id = string_member(line, 'id', id_found)
    operation = string_member(line, 'op', operation_found)
    if (.not. id_found .or. len(id) == 0 .or. len(id) > 128) id = ''
    if (.not. operation_found .or. len(operation) == 0) then
      call emit_error(id, 'ProtocolError', 'command requires a string op')
      cycle
    end if

    select case (operation)
    case ('hello')
      shape_ok = convex_json_object_allowed(line, 'protocolVersion,id,op')
    case ('query', 'mutation', 'action')
      shape_ok = convex_json_object_allowed(line, 'id,op,path,args')
    case ('subscribe', 'unsubscribe')
      shape_ok = convex_json_object_allowed(line, 'id,op,subscriptionId,path,args')
    case ('setAuth')
      shape_ok = convex_json_object_allowed(line, 'id,op,token')
    case ('close', 'debugDisconnect')
      shape_ok = convex_json_object_allowed(line, 'id,op')
#ifdef FORTRAN_ADAPTER_TESTING
    case ('testResult', 'testFunctionError', 'testSubscription', 'testSubscriptionError', 'testLargeEvent')
      shape_ok = convex_json_object_allowed(line, 'id,op')
#endif
    case default
      shape_ok = convex_json_object_allowed(line, 'id,op')
    end select
    if (.not. id_found .or. len(id) == 0 .or. .not. shape_ok) then
      call emit_error('', 'ProtocolError', 'command shape does not match adapter protocol v1')
      cycle
    end if

    select case (operation)
    case ('hello')
      raw = convex_json_member(line, 'protocolVersion', found)
      if (.not. found .or. raw /= '1') then
        call emit_error(id, 'ProtocolError', 'unsupported adapter protocol version')
      else
        call emit_event('{"protocolVersion":1,"id":' // quote(id) // &
          ',"type":"ready","language":"fortran","implementation":"native-fortran2018-libcurl-http-openssl-rfc6455","runtime":"GNU Fortran 14.2"}')
      end if
    case ('query', 'mutation', 'action')
      if (.not. ensure_client(client, client_ready, error)) then
        call emit_error(id, 'ProtocolError', error)
        cycle
      end if
      path = string_member(line, 'path', found)
      args = convex_json_member(line, 'args', decoded)
      if (.not. found .or. .not. decoded .or. len(path) < 3 .or. len(args) < 2) then
        call emit_error(id, 'ProtocolError', 'command requires path and object args')
        cycle
      end if
      if (args(1:1) /= '{') then
        call emit_error(id, 'ProtocolError', 'command requires path and object args')
        cycle
      end if
      call convex_call(client, operation, path, args, value, ok, error, logs, error_data)
      if (ok) then
        if (len(logs) == 0) logs = '[]'
        call emit_event('{"id":' // quote(id) // ',"type":"result","value":' // value // ',"logs":' // logs // '}')
      else
        call emit_call_error(id, error, error_data)
      end if
    case ('setAuth')
      if (.not. ensure_client(client, client_ready, error)) then
        call emit_error(id, 'ProtocolError', error)
        cycle
      end if
      token = string_member(line, 'token', found)
      if (.not. found) then
        call emit_error(id, 'ProtocolError', 'setAuth requires a string token')
      else
        call convex_set_auth(client, token)
        call emit_event('{"id":' // quote(id) // ',"type":"ack"}')
      end if
    case ('subscribe')
      if (.not. ensure_client(client, client_ready, error)) then
        call emit_error(id, 'ProtocolError', error)
        cycle
      end if
      subscription_id = string_member(line, 'subscriptionId', found)
      path = string_member(line, 'path', decoded)
      args = convex_json_member(line, 'args', ok)
      if (.not. found .or. .not. decoded .or. .not. ok .or. len(subscription_id) == 0 .or. &
          len(subscription_id) > 128 .or. len(path) < 3 .or. &
          len(args) < 2) then
        call emit_error(id, 'ProtocolError', 'subscribe requires subscriptionId, path, and object args')
        cycle
      end if
      if (args(1:1) /= '{') then
        call emit_error(id, 'ProtocolError', 'subscribe requires subscriptionId, path, and object args')
        cycle
      end if
      call subscription_start(client, subscription_id, path, args, slot, generation, ok, error)
      if (ok) then
        call emit_event('{"id":' // quote(id) // ',"type":"ack"}')
        call subscription_activate(slot, generation)
      else
        call emit_call_error(id, error, '')
      end if
    case ('unsubscribe')
      subscription_id = string_member(line, 'subscriptionId', found)
      if (.not. found .or. len(subscription_id) == 0 .or. len(subscription_id) > 128) then
        call emit_error(id, 'ProtocolError', 'unsubscribe requires subscriptionId')
        cycle
      end if
      call subscription_stop(subscription_id, ok, error)
      if (ok) then
        call emit_event('{"id":' // quote(id) // ',"type":"ack"}')
      else
        call emit_call_error(id, error, '')
      end if
    case ('debugDisconnect')
      call convex_live_debug_disconnect(ok, error)
      if (ok) then
        call emit_event('{"id":' // quote(id) // ',"type":"ack"}')
      else
        call emit_call_error(id, error, '')
      end if
    case ('close')
      call emit_event('{"id":' // quote(id) // ',"type":"closed"}')
      exit
#ifdef FORTRAN_ADAPTER_TESTING
    case ('testResult')
      call emit_event('{"id":' // quote(id) // ',"type":"result","value":{"count":1},"logs":["fixture"]}')
    case ('testFunctionError')
      call emit_call_error(id, 'FunctionError: fixture failure', '{"code":"FIXTURE"}')
    case ('testSubscription')
      call emit_subscription('fixture-subscription', '{"count":2}', '[]', '', '', '', .false.)
    case ('testSubscriptionError')
      call emit_subscription('fixture-error', '', '', 'TransportError', 'fixture transport failure', '', .true.)
    case ('testLargeEvent')
      allocate(character(1900000) :: large_value)
      large_value = repeat('x', len(large_value))
      call emit_event('{"id":' // quote(id) // ',"type":"result","value":"' // large_value // '","logs":[]}')
      deallocate(large_value)
#endif
    case default
      call emit_error(id, 'ProtocolError', 'unknown adapter operation')
    end select
  end do

  call state_finish()
  call stream_close(stream)

contains

  logical function ensure_client(target, ready, message)
    type(convex_client), intent(inout) :: target
    logical, intent(inout) :: ready
    character(:), allocatable, intent(out) :: message
    integer :: count
    if (ready) then
      ensure_client = .true.
      message = ''
      return
    end if
    call get_environment_variable('CONVEX_URL', length=count)
    if (count == 0) then
      ensure_client = .false.
      message = 'CONVEX_URL is required'
      return
    end if
    if (allocated(url)) deallocate(url)
    allocate(character(count) :: url)
    call get_environment_variable('CONVEX_URL', url)
    call convex_new(url, target, ensure_client, message)
    ready = ensure_client
  end function

  function string_member(document, name, present) result(text)
    character(*), intent(in) :: document, name
    logical, intent(out) :: present
    character(:), allocatable :: text, encoded
    logical :: valid
    encoded = convex_json_member(document, name, present)
    if (.not. present) then
      text = ''
      return
    end if
    text = json_string(encoded, valid)
    present = valid
    if (.not. valid) text = ''
  end function

  subroutine emit_error(event_id, name, message)
    character(*), intent(in) :: event_id, name, message
    character(:), allocatable :: event
    event = '{"type":"error"'
    if (len(event_id) > 0) event = event // ',"id":' // quote(event_id)
    event = event // ',"error":{"name":' // quote(name) // ',"message":' // quote(message) // '}}'
    call emit_event(event)
  end subroutine

  subroutine emit_call_error(event_id, failure, data)
    character(*), intent(in) :: event_id, failure, data
    character(:), allocatable :: name, message, event
    integer :: separator
    separator = index(failure, ': ')
    if (separator > 0) then
      name = failure(:separator - 1)
      message = failure(separator + 2:)
    else
      name = 'TransportError'
      message = failure
    end if
    event = '{"type":"error","id":' // quote(event_id) // ',"error":{"name":' // quote(name) // &
      ',"message":' // quote(message)
    if (len(data) > 0) event = event // ',"data":' // data
    call emit_event(event // '}}')
  end subroutine

  function quote(text) result(encoded)
    character(*), intent(in) :: text
    character(:), allocatable :: encoded
    character(6) :: unicode
    integer :: position, code
    encoded = '"'
    do position = 1, len(text)
      code = iachar(text(position:position))
      select case (code)
      case (34)
        encoded = encoded // '\"'
      case (92)
        encoded = encoded // '\\'
      case (8)
        encoded = encoded // '\b'
      case (9)
        encoded = encoded // '\t'
      case (10)
        encoded = encoded // '\n'
      case (12)
        encoded = encoded // '\f'
      case (13)
        encoded = encoded // '\r'
      case (0:7, 11, 14:31)
        write (unicode, '("\\u",Z4.4)') code
        encoded = encoded // unicode
      case default
        encoded = encoded // text(position:position)
      end select
    end do
    encoded = encoded // '"'
  end function

end program adapter
#endif
