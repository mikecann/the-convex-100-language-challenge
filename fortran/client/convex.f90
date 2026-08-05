module convex_fortran
  use, intrinsic :: iso_c_binding, only: c_char, c_null_char, c_ptr, c_null_ptr, c_associated, &
    c_size_t, c_int, c_int64_t, c_funptr, c_funloc, c_f_pointer
  use, intrinsic :: iso_fortran_env, only: real64, int64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  implicit none
  private

  integer, parameter :: max_http_bytes = 2 * 1024 * 1024
  integer, parameter :: max_live_message = 2 * 1024 * 1024
  integer, parameter :: max_subscriptions = 64
  integer, parameter :: max_updates = 16
  integer, parameter :: max_update_bytes = 32 * 1024 * 1024
  character(*), parameter :: initial_timestamp = 'AAAAAAAAAAA='

  type, public :: convex_client
    character(:), allocatable :: url
    character(:), allocatable :: token
  end type convex_client

  type, public :: convex_live
    integer :: query_id = -1
    integer :: generation = 0
  end type convex_live

  type :: subscription_state
    logical :: occupied = .false.
    logical :: active = .false.
    logical :: add_pending = .false.
    logical :: remove_pending = .false.
    logical :: remove_done = .false.
    logical :: rehydrating = .false.
    logical :: has_last_value = .false.
    integer :: query_id = -1
    integer :: generation = 0
    integer(int64) :: add_sequence = 0
    character(:), allocatable :: path
    character(:), allocatable :: args
    character(:), allocatable :: last_value
  end type subscription_state

  type :: live_update
    integer :: query_id = -1
    integer :: generation = 0
    logical :: is_error = .false.
    character(:), allocatable :: value
    character(:), allocatable :: logs
    character(:), allocatable :: error_name
    character(:), allocatable :: error_message
    character(:), allocatable :: error_data
  end type live_update

  type :: transition_modification
    integer :: query_id = -1
    integer :: kind = 0 ! 1 removed, 2 updated, 3 failed
    character(:), allocatable :: value
    character(:), allocatable :: logs
    character(:), allocatable :: error_message
    character(:), allocatable :: error_data
  end type transition_modification

  type :: live_manager
    logical :: initialized = .false.
    logical :: closing = .false.
    logical :: stopped = .false.
    logical :: connected = .false.
    logical :: debug_requested = .false.
    integer :: debug_generation = 0
    integer :: debug_completed = 0
    integer :: next_query_id = 0
    integer(int64) :: next_add_sequence = 0
    integer :: query_set_version = 0
    integer :: remote_query_set = 0
    integer :: remote_identity = 0
    integer :: connection_count = 0
    integer :: update_count = 0
    integer :: update_bytes = 0
    type(c_ptr) :: mutex = c_null_ptr
    type(c_ptr) :: condition = c_null_ptr
    type(c_ptr) :: thread = c_null_ptr
    type(c_ptr) :: socket = c_null_ptr
    character(:), allocatable :: url
    character(:), allocatable :: token
    character(:), allocatable :: remote_timestamp
    character(:), allocatable :: max_observed_timestamp
    character(:), allocatable :: last_close_reason
    type(subscription_state) :: subscriptions(max_subscriptions)
    type(live_update) :: updates(max_updates)
  end type live_manager

  type(live_manager), save :: manager

  public :: convex_new, convex_set_auth, convex_call
  public :: convex_live_start, convex_live_next, convex_live_unsubscribe
  public :: convex_live_debug_disconnect, convex_live_close, convex_live_metadata
  public :: convex_json_member, convex_json_object_allowed, convex_count, json_string
#ifdef FORTRAN_TESTING
  public :: convex_test_live_begin, convex_test_live_apply, convex_test_live_next
  public :: convex_test_live_stats, convex_test_live_end
  public :: convex_test_live_dns_stall_begin
#endif

  interface
    function ft_http_post(url, payload, token, body, body_length, error) bind(c, name="ft_http_post") result(ok)
      import :: c_char, c_ptr, c_size_t, c_int
      character(kind=c_char), intent(in) :: url(*), payload(*), token(*)
      type(c_ptr), intent(out) :: body, error
      integer(c_size_t), intent(out) :: body_length
      integer(c_int) :: ok
    end function ft_http_post

    function ft_ws_open(url, version, error) bind(c, name="ft_ws_open") result(handle)
      import :: c_char, c_ptr
      character(kind=c_char), intent(in) :: url(*), version(*)
      type(c_ptr), intent(out) :: error
      type(c_ptr) :: handle
    end function ft_ws_open

    function ft_ws_send(handle, text, length, error) bind(c, name="ft_ws_send") result(ok)
      import :: c_ptr, c_char, c_size_t, c_int
      type(c_ptr), value :: handle
      character(kind=c_char), intent(in) :: text(*)
      integer(c_size_t), value :: length
      type(c_ptr), intent(out) :: error
      integer(c_int) :: ok
    end function ft_ws_send

    function ft_ws_receive(handle, text, length, timeout_ms, error) bind(c, name="ft_ws_receive") result(status)
      import :: c_ptr, c_size_t, c_int
      type(c_ptr), value :: handle
      type(c_ptr), intent(out) :: text, error
      integer(c_size_t), intent(out) :: length
      integer(c_int), value :: timeout_ms
      integer(c_int) :: status
    end function ft_ws_receive

    subroutine ft_ws_close(handle) bind(c, name="ft_ws_close")
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine ft_ws_close

    function ft_mutex_new() bind(c, name="ft_mutex_new") result(handle)
      import :: c_ptr
      type(c_ptr) :: handle
    end function ft_mutex_new

    subroutine ft_mutex_lock(handle) bind(c, name="ft_mutex_lock")
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine ft_mutex_lock

    subroutine ft_mutex_unlock(handle) bind(c, name="ft_mutex_unlock")
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine ft_mutex_unlock

    subroutine ft_mutex_free(handle) bind(c, name="ft_mutex_free")
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine ft_mutex_free

    function ft_cond_new() bind(c, name="ft_cond_new") result(handle)
      import :: c_ptr
      type(c_ptr) :: handle
    end function ft_cond_new

    function ft_cond_wait(condition, mutex, timeout_ms) bind(c, name="ft_cond_wait") result(status)
      import :: c_ptr, c_int
      type(c_ptr), value :: condition, mutex
      integer(c_int), value :: timeout_ms
      integer(c_int) :: status
    end function ft_cond_wait

    subroutine ft_cond_broadcast(condition) bind(c, name="ft_cond_broadcast")
      import :: c_ptr
      type(c_ptr), value :: condition
    end subroutine ft_cond_broadcast

    subroutine ft_cond_free(condition) bind(c, name="ft_cond_free")
      import :: c_ptr
      type(c_ptr), value :: condition
    end subroutine ft_cond_free

    function ft_thread_start(function, argument) bind(c, name="ft_thread_start") result(handle)
      import :: c_funptr, c_ptr
      type(c_funptr), value :: function
      type(c_ptr), value :: argument
      type(c_ptr) :: handle
    end function ft_thread_start

    subroutine ft_thread_join(handle) bind(c, name="ft_thread_join")
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine ft_thread_join

    function ft_thread_join_bounded(handle, timeout_ms) bind(c, name="ft_thread_join_bounded") result(joined)
      import :: c_ptr, c_int
      type(c_ptr), value :: handle
      integer(c_int), value :: timeout_ms
      integer(c_int) :: joined
    end function ft_thread_join_bounded

    function ft_monotonic_ms() bind(c, name="ft_monotonic_ms") result(value)
      import :: c_int64_t
      integer(c_int64_t) :: value
    end function ft_monotonic_ms

    function ft_string_length(text) bind(c, name="ft_string_length") result(length)
      import :: c_ptr, c_size_t
      type(c_ptr), value :: text
      integer(c_size_t) :: length
    end function ft_string_length

    subroutine ft_free(pointer) bind(c, name="ft_free")
      import :: c_ptr
      type(c_ptr), value :: pointer
    end subroutine ft_free
  end interface

contains

  subroutine make_c_text(text, value)
    character(*), intent(in) :: text
    character(kind=c_char), allocatable, intent(out) :: value(:)
    integer :: index, length

    length = len(text)
    allocate(value(length + 1))
    do index = 1, length
      value(index) = text(index:index)
    end do
    value(length + 1) = c_null_char
  end subroutine make_c_text

  function from_c(pointer, length) result(value)
    type(c_ptr), intent(in) :: pointer
    integer(c_size_t), intent(in) :: length
    character(:), allocatable :: value
    character(kind=c_char), pointer :: chars(:)
    integer :: index, bounded_length

    bounded_length = int(min(length, int(max_live_message, c_size_t)))
    allocate(character(bounded_length) :: value)
    if (bounded_length == 0) return
    call c_f_pointer(pointer, chars, [bounded_length])
    do index = 1, bounded_length
      value(index:index) = chars(index)
    end do
  end function from_c

  function error_text(pointer) result(value)
    type(c_ptr), intent(in) :: pointer
    character(:), allocatable :: value
    integer(c_size_t) :: length

    if (.not. c_associated(pointer)) then
      value = 'transport failure'
      return
    end if
    length = ft_string_length(pointer)
    value = from_c(pointer, length)
  end function error_text

  function json_quote(text) result(value)
    character(*), intent(in) :: text
    character(:), allocatable :: value
    character(6) :: escaped
    integer :: index, code

    value = '"'
    do index = 1, len(text)
      select case (text(index:index))
      case ('"')
        value = value // '\"'
      case ('\')
        value = value // '\\'
      case (achar(10))
        value = value // '\n'
      case (achar(13))
        value = value // '\r'
      case (achar(9))
        value = value // '\t'
      case default
        code = iachar(text(index:index))
        if (code < 32) then
          write(escaped, '("\\u",Z4.4)') code
          value = value // escaped
        else
          value = value // text(index:index)
        end if
      end select
    end do
    value = value // '"'
  end function json_quote

  function json_string(raw, ok) result(value)
    character(*), intent(in) :: raw
    logical, intent(out) :: ok
    character(:), allocatable :: value
    integer :: index, code, low_code, status
    character(4) :: hex, low_hex

    value = ''
    if (len(raw) < 2) then
      ok = .false.
      return
    end if
    if (raw(1:1) /= '"' .or. raw(len(raw):len(raw)) /= '"') then
      ok = .false.
      return
    end if
    index = 2
    do while (index < len(raw))
      if (raw(index:index) /= '\') then
        value = value // raw(index:index)
        index = index + 1
        cycle
      end if
      index = index + 1
      if (index >= len(raw)) then
        ok = .false.
        return
      end if
      select case (raw(index:index))
      case ('"', '\', '/')
        value = value // raw(index:index)
      case ('b')
        value = value // achar(8)
      case ('f')
        value = value // achar(12)
      case ('n')
        value = value // achar(10)
      case ('r')
        value = value // achar(13)
      case ('t')
        value = value // achar(9)
      case ('u')
        if (index + 4 >= len(raw)) then
          ok = .false.
          return
        end if
        hex = raw(index + 1:index + 4)
        read(hex, '(Z4)', iostat=status) code
        if (status /= 0) then
          ok = .false.
          return
        end if
        index = index + 4
        if (code >= int(Z'D800') .and. code <= int(Z'DBFF')) then
          if (index + 6 >= len(raw)) then
            ok = .false.
            return
          end if
          if (raw(index + 1:index + 2) /= '\u') then
            ok = .false.
            return
          end if
          low_hex = raw(index + 3:index + 6)
          read(low_hex, '(Z4)', iostat=status) low_code
          if (status /= 0 .or. low_code < int(Z'DC00') .or. low_code > int(Z'DFFF')) then
            ok = .false.
            return
          end if
          code = int(Z'10000') + ishft(code - int(Z'D800'), 10) + low_code - int(Z'DC00')
          index = index + 6
        else if (code >= int(Z'DC00') .and. code <= int(Z'DFFF')) then
          ok = .false.
          return
        end if
        call append_utf8(value, code)
      case default
        ok = .false.
        return
      end select
      index = index + 1
    end do
    ok = .true.
  end function json_string

  subroutine append_utf8(value, code)
    character(:), allocatable, intent(inout) :: value
    integer, intent(in) :: code

    if (code <= int(Z'7F')) then
      value = value // achar(code)
    else if (code <= int(Z'7FF')) then
      value = value // achar(int(Z'C0') + ishft(code, -6)) // &
        achar(int(Z'80') + iand(code, int(Z'3F')))
    else if (code <= int(Z'FFFF')) then
      value = value // achar(int(Z'E0') + ishft(code, -12)) // &
        achar(int(Z'80') + iand(ishft(code, -6), int(Z'3F'))) // &
        achar(int(Z'80') + iand(code, int(Z'3F')))
    else
      value = value // achar(int(Z'F0') + ishft(code, -18)) // &
        achar(int(Z'80') + iand(ishft(code, -12), int(Z'3F'))) // &
        achar(int(Z'80') + iand(ishft(code, -6), int(Z'3F'))) // &
        achar(int(Z'80') + iand(code, int(Z'3F')))
    end if
  end subroutine append_utf8

  subroutine convex_new(url, client, ok, error)
    character(*), intent(in) :: url
    type(convex_client), intent(out) :: client
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error

    if (index(url, 'http://') /= 1 .and. index(url, 'https://') /= 1) then
      ok = .false.
      error = 'Convex deployment URL must use http or https'
      return
    end if
    client%url = trim(url)
    do while (len(client%url) > 0)
      if (client%url(len(client%url):) /= '/') exit
      client%url = client%url(:len(client%url) - 1)
    end do
    client%token = ''
    ok = .true.
    error = ''
  end subroutine convex_new

  subroutine convex_set_auth(client, token)
    type(convex_client), intent(inout) :: client
    character(*), intent(in) :: token

    client%token = token
    if (manager%initialized) then
      call ft_mutex_lock(manager%mutex)
      manager%token = token
      call ft_mutex_unlock(manager%mutex)
    end if
  end subroutine convex_set_auth

  subroutine convex_call(client, operation, path, args, value, ok, error, logs, error_data)
    type(convex_client), intent(in) :: client
    character(*), intent(in) :: operation, path, args
    character(:), allocatable, intent(out) :: value, error
    logical, intent(out) :: ok
    character(:), allocatable, intent(out), optional :: logs, error_data
    character(:), allocatable :: endpoint, payload, response, status, message, encoded_message, data
    character(kind=c_char), allocatable :: endpoint_c(:), payload_c(:), token_c(:)
    type(c_ptr) :: body, transport_error
    integer(c_size_t) :: body_length
    integer(c_int) :: transport_ok
    logical :: found, decoded

    value = ''
    error = ''
    if (present(logs)) logs = ''
    if (present(error_data)) error_data = ''
    if (operation /= 'query' .and. operation /= 'mutation' .and. operation /= 'action') then
      ok = .false.; error = 'ProtocolError: unsupported Convex HTTP operation'; return
    end if
    if (len_trim(path) == 0 .or. len_trim(args) == 0) then
      ok = .false.; error = 'ProtocolError: Convex path and object arguments are required'; return
    end if
    if (args(1:1) /= '{') then
      ok = .false.; error = 'ProtocolError: Convex path and object arguments are required'; return
    end if
    endpoint = client%url // '/api/' // trim(operation)
    payload = '{"path":' // json_quote(path) // ',"args":' // trim(args) // ',"format":"json"}'
    call make_c_text(endpoint, endpoint_c)
    call make_c_text(payload, payload_c)
    call make_c_text(client%token, token_c)
    transport_ok = ft_http_post(endpoint_c, payload_c, token_c, body, body_length, transport_error)
    if (transport_ok == 0_c_int) then
      ok = .false.; error = 'TransportError: ' // error_text(transport_error)
      if (c_associated(transport_error)) call ft_free(transport_error)
      return
    end if
    response = from_c(body, body_length)
    call ft_free(body)
    status = convex_json_member(response, 'status', found)
    if (.not. found) then
      ok = .false.; error = 'ProtocolError: HTTP response was not valid Convex JSON'; return
    end if
    if (status == '"success"') then
      value = convex_json_member(response, 'value', found)
      if (.not. found) then
        ok = .false.; error = 'ProtocolError: successful Convex response omitted value'; return
      end if
      if (present(logs)) logs = convex_json_member(response, 'logLines', found)
      ok = .true.
      return
    end if
    if (status == '"error"') then
      encoded_message = convex_json_member(response, 'errorMessage', found)
      if (found) then
        message = json_string(encoded_message, decoded)
        if (.not. decoded) then
          ok = .false.; error = 'ProtocolError: HTTP errorMessage was not a JSON string'; return
        end if
      else
        message = 'Convex function failed'
      end if
      data = convex_json_member(response, 'errorData', found)
      if (present(error_data) .and. found) error_data = data
      if (present(logs)) logs = convex_json_member(response, 'logLines', found)
      error = 'FunctionError: ' // message
      ok = .false.
      return
    end if
    ok = .false.; error = 'ProtocolError: HTTP response had an unknown Convex status'
  end subroutine convex_call

  subroutine initialize_manager(client, ok, error)
    type(convex_client), intent(in) :: client
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error

    if (manager%initialized) then
      if (manager%url /= client%url) then
        ok = .false.; error = 'ProtocolError: one process may own one Live deployment'; return
      end if
      ok = .true.; error = ''; return
    end if
    manager%mutex = ft_mutex_new()
    manager%condition = ft_cond_new()
    if (.not. c_associated(manager%mutex) .or. .not. c_associated(manager%condition)) then
      ok = .false.; error = 'TransportError: could not initialize Live synchronization'; return
    end if
    manager%url = client%url
    manager%token = client%token
    manager%remote_timestamp = initial_timestamp
    manager%max_observed_timestamp = ''
    manager%last_close_reason = 'InitialConnect'
    manager%initialized = .true.
    manager%thread = ft_thread_start(c_funloc(live_worker), c_null_ptr)
    if (.not. c_associated(manager%thread)) then
      manager%initialized = .false.
      ok = .false.; error = 'TransportError: could not start sole Live owner'; return
    end if
    ok = .true.; error = ''
  end subroutine initialize_manager

  subroutine convex_live_start(client, path, args, live, ok, error)
    type(convex_client), intent(in) :: client
    character(*), intent(in) :: path, args
    type(convex_live), intent(out) :: live
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error
    integer :: slot
    integer(c_int) :: waited
    integer(c_int64_t) :: deadline

    live%query_id = -1
    live%generation = 0
    if (len_trim(path) == 0 .or. len_trim(args) == 0) then
      ok = .false.; error = 'ProtocolError: Live path and object arguments are required'; return
    end if
    if (args(1:1) /= '{') then
      ok = .false.; error = 'ProtocolError: Live path and object arguments are required'; return
    end if
    call initialize_manager(client, ok, error)
    if (.not. ok) return
    call ft_mutex_lock(manager%mutex)
    slot = free_subscription_slot()
    if (slot == 0) then
      call ft_mutex_unlock(manager%mutex)
      ok = .false.; error = 'TransportError: Live subscription limit reached'; return
    end if
    manager%next_add_sequence = manager%next_add_sequence + 1
    manager%subscriptions(slot)%occupied = .true.
    manager%subscriptions(slot)%active = .true.
    manager%subscriptions(slot)%add_pending = .true.
    manager%subscriptions(slot)%remove_pending = .false.
    manager%subscriptions(slot)%remove_done = .false.
    manager%subscriptions(slot)%rehydrating = .false.
    manager%subscriptions(slot)%has_last_value = .false.
    manager%subscriptions(slot)%query_id = manager%next_query_id
    manager%subscriptions(slot)%generation = manager%subscriptions(slot)%generation + 1
    manager%subscriptions(slot)%add_sequence = manager%next_add_sequence
    manager%subscriptions(slot)%path = path
    manager%subscriptions(slot)%args = args
    if (allocated(manager%subscriptions(slot)%last_value)) deallocate(manager%subscriptions(slot)%last_value)
    live%query_id = manager%next_query_id
    live%generation = manager%subscriptions(slot)%generation
    manager%next_query_id = manager%next_query_id + 1
    call ft_cond_broadcast(manager%condition)
    deadline = ft_monotonic_ms() + 10000
    do while (manager%subscriptions(slot)%add_pending .and. .not. manager%stopped)
      waited = ft_cond_wait(manager%condition, manager%mutex, 100_c_int)
      if (ft_monotonic_ms() >= deadline) exit
    end do
    if (manager%subscriptions(slot)%add_pending) then
      manager%subscriptions(slot)%active = .false.
      manager%subscriptions(slot)%remove_pending = .true.
      call ft_cond_broadcast(manager%condition)
      call ft_mutex_unlock(manager%mutex)
      ok = .false.; error = 'TransportError: timed out publishing Live Add'; return
    end if
    call ft_mutex_unlock(manager%mutex)
    ok = .true.; error = ''
  end subroutine convex_live_start

  subroutine convex_live_next(live, value, ok, error, logs, error_name, error_data, timeout_ms)
    type(convex_live), intent(in) :: live
    character(:), allocatable, intent(out) :: value, error
    logical, intent(out) :: ok
    character(:), allocatable, intent(out), optional :: logs, error_name, error_data
    integer, intent(in), optional :: timeout_ms
    integer :: index, timeout
    integer(c_int64_t) :: deadline, current_time
    integer(c_int) :: waited
    type(live_update) :: update

    value = ''; error = ''
    if (present(logs)) logs = ''
    if (present(error_name)) error_name = ''
    if (present(error_data)) error_data = ''
    timeout = 10000
    if (present(timeout_ms)) timeout = timeout_ms
    deadline = ft_monotonic_ms() + timeout
    call ft_mutex_lock(manager%mutex)
    do
      index = find_update(live%query_id, live%generation)
      if (index > 0) exit
      if (manager%stopped .or. .not. subscription_active(live%query_id, live%generation)) then
        call ft_mutex_unlock(manager%mutex)
        ok = .false.; error = 'TransportError: Live subscription closed'; return
      end if
      waited = ft_cond_wait(manager%condition, manager%mutex, 100_c_int)
      if (timeout >= 0) then
        current_time = ft_monotonic_ms()
        if (current_time >= deadline) then
          call ft_mutex_unlock(manager%mutex)
          ok = .false.; error = 'TransportError: Live update timed out'; return
        end if
      end if
    end do
    update = manager%updates(index)
    call remove_update(index)
    call ft_mutex_unlock(manager%mutex)
    if (allocated(update%logs) .and. present(logs)) logs = update%logs
    if (update%is_error) then
      if (present(error_name)) error_name = update%error_name
      if (present(error_data) .and. allocated(update%error_data)) error_data = update%error_data
      error = update%error_name // ': ' // update%error_message
      ok = .false.
    else
      value = update%value
      ok = .true.
    end if
  end subroutine convex_live_next

  subroutine convex_live_unsubscribe(live, ok, error)
    type(convex_live), intent(in) :: live
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error
    integer :: slot
    integer(c_int64_t) :: deadline
    integer(c_int) :: waited

    if (.not. manager%initialized) then
      ok = .true.; error = ''; return
    end if
    call ft_mutex_lock(manager%mutex)
    slot = find_subscription(live%query_id, live%generation)
    if (slot == 0) then
      call ft_mutex_unlock(manager%mutex)
      ok = .true.; error = ''; return
    end if
    if (manager%subscriptions(slot)%remove_done) then
      call ft_mutex_unlock(manager%mutex)
      ok = .true.; error = ''; return
    end if
    ! Invalidate the relay generation before a Remove acknowledgement can be
    ! observed by the adapter.
    manager%subscriptions(slot)%active = .false.
    manager%subscriptions(slot)%remove_pending = .true.
    call discard_updates(live%query_id, live%generation)
    call ft_cond_broadcast(manager%condition)
    deadline = ft_monotonic_ms() + 2000
    do while (.not. manager%subscriptions(slot)%remove_done .and. .not. manager%stopped)
      waited = ft_cond_wait(manager%condition, manager%mutex, 50_c_int)
      if (ft_monotonic_ms() >= deadline) exit
    end do
    ok = manager%subscriptions(slot)%remove_done
    if (ok) then
      error = ''
      call clear_subscription(slot)
    else
      error = 'TransportError: timed out publishing Live Remove'
    end if
    call ft_mutex_unlock(manager%mutex)
  end subroutine convex_live_unsubscribe

  subroutine convex_live_debug_disconnect(ok, error)
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error
    integer :: generation
    integer(c_int64_t) :: deadline
    integer(c_int) :: waited

    if (.not. manager%initialized) then
      ok = .false.; error = 'TransportError: Live is not initialized'; return
    end if
    call ft_mutex_lock(manager%mutex)
    if (.not. manager%connected) then
      call ft_mutex_unlock(manager%mutex)
      ok = .false.; error = 'TransportError: Live WebSocket is not connected'; return
    end if
    manager%debug_generation = manager%debug_generation + 1
    generation = manager%debug_generation
    manager%debug_requested = .true.
    call ft_cond_broadcast(manager%condition)
    deadline = ft_monotonic_ms() + 10000
    do while (manager%debug_completed < generation .and. .not. manager%stopped)
      waited = ft_cond_wait(manager%condition, manager%mutex, 50_c_int)
      if (ft_monotonic_ms() >= deadline) exit
    end do
    ok = manager%debug_completed >= generation
    error = ''
    if (.not. ok) error = 'TransportError: debug disconnect acknowledgement timed out'
    call ft_mutex_unlock(manager%mutex)
  end subroutine convex_live_debug_disconnect

  subroutine convex_live_close(live)
    type(convex_live), intent(inout), optional :: live
    logical :: ok
    character(:), allocatable :: ignored
    integer(c_int) :: joined
    type(c_ptr) :: thread

    if (present(live)) then
      call convex_live_unsubscribe(live, ok, ignored)
      live%query_id = -1
      live%generation = 0
      return
    end if
    if (.not. manager%initialized) return
    call ft_mutex_lock(manager%mutex)
    manager%closing = .true.
    call ft_cond_broadcast(manager%condition)
    thread = manager%thread
    call ft_mutex_unlock(manager%mutex)
    joined = 1
    if (c_associated(thread)) joined = ft_thread_join_bounded(thread, 12000_c_int)
    if (joined == 0) then
      ! Leave the static manager storage intact for a worker that outlived the
      ! absolute close deadline. A later close may join it; freeing its mutexes
      ! here would turn a bounded failure into a use-after-free.
      manager%last_close_reason = 'CloseDeadline'
      return
    end if
    call ft_mutex_free(manager%mutex)
    call ft_cond_free(manager%condition)
    call reset_manager()
  end subroutine convex_live_close

  subroutine convex_live_metadata(connection_count, last_close_reason, max_observed_timestamp)
    integer, intent(out) :: connection_count
    character(:), allocatable, intent(out) :: last_close_reason, max_observed_timestamp

    call ft_mutex_lock(manager%mutex)
    connection_count = manager%connection_count
    last_close_reason = manager%last_close_reason
    max_observed_timestamp = manager%max_observed_timestamp
    call ft_mutex_unlock(manager%mutex)
  end subroutine convex_live_metadata

  function live_worker(argument) bind(c) result(result)
    type(c_ptr), value :: argument
    type(c_ptr) :: result
    integer(c_int64_t) :: reconnect_at, current_time
    integer :: backoff, slot, pending_debug
    logical :: active, okay, protocol_error
    character(:), allocatable :: reason, message
    type(c_ptr) :: socket, text, transport_error
    integer(c_size_t) :: length
    integer(c_int) :: received

    result = c_null_ptr
    if (c_associated(argument)) result = c_null_ptr
    reconnect_at = 0
    backoff = 100
    pending_debug = 0
    do
      call ft_mutex_lock(manager%mutex)
      if (manager%closing) then
        socket = manager%socket
        manager%socket = c_null_ptr
        manager%connected = .false.
        call ft_mutex_unlock(manager%mutex)
        if (c_associated(socket)) call ft_ws_close(socket)
        exit
      end if
      if (manager%debug_requested) then
        manager%debug_requested = .false.
        socket = manager%socket
        manager%socket = c_null_ptr
        manager%connected = .false.
        call retire_connection_locked('DebugDisconnect')
        pending_debug = manager%debug_generation
        reconnect_at = ft_monotonic_ms() + 100
        call ft_cond_broadcast(manager%condition)
        call ft_mutex_unlock(manager%mutex)
        if (c_associated(socket)) call ft_ws_close(socket)
        cycle
      end if
      active = active_subscription_count() > 0
      socket = manager%socket
      call complete_disconnected_removes()
      call ft_mutex_unlock(manager%mutex)

      if (.not. c_associated(socket) .and. active) then
        current_time = ft_monotonic_ms()
        if (current_time >= reconnect_at) then
          call connect_owner(okay, reason)
          if (okay) then
            backoff = 100
            if (pending_debug > 0) then
              call ft_mutex_lock(manager%mutex)
              manager%debug_completed = pending_debug
              call ft_cond_broadcast(manager%condition)
              call ft_mutex_unlock(manager%mutex)
              pending_debug = 0
            end if
          else
            call ft_mutex_lock(manager%mutex)
            manager%connection_count = manager%connection_count + 1
            manager%last_close_reason = reason
            call ft_mutex_unlock(manager%mutex)
            reconnect_at = ft_monotonic_ms() + backoff
            backoff = min(backoff * 2, 15000)
          end if
          cycle
        end if
      end if

      if (c_associated(socket)) then
        call pending_command_slot(slot)
        if (slot /= 0) then
          call send_pending_command(slot, okay, reason)
          if (.not. okay) then
            call transport_disconnect(reason)
            reconnect_at = ft_monotonic_ms() + backoff
            backoff = min(backoff * 2, 15000)
          end if
          cycle
        end if
        ! A started frame owns this deadline. One hundred milliseconds keeps a
        ! fragmented message bounded without treating ordinary scheduler jitter
        ! as a corrupt partial payload on emulated linux/amd64 builders.
        received = ft_ws_receive(socket, text, length, 100_c_int, transport_error)
        if (received == 1_c_int) then
          message = from_c(text, length)
          call ft_free(text)
          call process_server_message(message, okay, protocol_error, reason)
          if (okay) then
            backoff = 100
          else
            if (protocol_error) call publish_all_error('ProtocolError', reason, .false.)
            call transport_disconnect(reason)
            reconnect_at = ft_monotonic_ms() + backoff
            backoff = min(backoff * 2, 15000)
          end if
        else if (received < 0_c_int) then
          reason = error_text(transport_error)
          if (c_associated(transport_error)) call ft_free(transport_error)
          call publish_all_error('TransportError', reason, .true.)
          call transport_disconnect(reason)
          reconnect_at = ft_monotonic_ms() + backoff
          backoff = min(backoff * 2, 15000)
        end if
      else
        call ft_mutex_lock(manager%mutex)
        if (.not. manager%closing) received = ft_cond_wait(manager%condition, manager%mutex, 20_c_int)
        call ft_mutex_unlock(manager%mutex)
      end if
    end do
    call ft_mutex_lock(manager%mutex)
    manager%stopped = .true.
    call ft_cond_broadcast(manager%condition)
    call ft_mutex_unlock(manager%mutex)
  end function live_worker

  subroutine connect_owner(ok, reason)
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: reason
    character(:), allocatable :: url, connect, modify
    character(kind=c_char), allocatable :: url_c(:), version_c(:), message_c(:)
    type(c_ptr) :: socket, transport_error
    integer(c_int) :: sent
    integer :: captured_ids(max_subscriptions), captured_generations(max_subscriptions), captured_count, capture_index

    call ft_mutex_lock(manager%mutex)
    if (index(manager%url, 'https://') == 1) then
      url = 'wss://' // manager%url(9:) // '/api/sync'
    else
      url = 'ws://' // manager%url(8:) // '/api/sync'
    end if
    connect = connect_message_locked()
    call ft_mutex_unlock(manager%mutex)
    call make_c_text(url, url_c)
    call make_c_text('fortran-0.1.0', version_c)
    socket = ft_ws_open(url_c, version_c, transport_error)
    if (.not. c_associated(socket)) then
      reason = 'live dial: ' // error_text(transport_error)
      if (c_associated(transport_error)) call ft_free(transport_error)
      ok = .false.; return
    end if
    call make_c_text(connect, message_c)
    sent = ft_ws_send(socket, message_c, int(len(connect), c_size_t), transport_error)
    if (sent == 0_c_int) then
      reason = 'live Connect: ' // error_text(transport_error)
      if (c_associated(transport_error)) call ft_free(transport_error)
      call ft_ws_close(socket)
      ok = .false.; return
    end if
    call ft_mutex_lock(manager%mutex)
    call snapshot_add_message(modify, captured_ids, captured_generations, captured_count)
    call ft_mutex_unlock(manager%mutex)
    if (captured_count > 0) then
      call make_c_text(modify, message_c)
      sent = ft_ws_send(socket, message_c, int(len(modify), c_size_t), transport_error)
      if (sent == 0_c_int) then
        reason = 'live Add snapshot: ' // error_text(transport_error)
        if (c_associated(transport_error)) call ft_free(transport_error)
        call ft_ws_close(socket)
        ok = .false.; return
      end if
    end if
    call ft_mutex_lock(manager%mutex)
    manager%socket = socket
    manager%connected = .true.
    manager%query_set_version = merge(1, 0, captured_count > 0)
    manager%remote_query_set = 0
    manager%remote_identity = 0
    manager%remote_timestamp = initial_timestamp
    do capture_index = 1, captured_count
      call clear_matching_add(captured_ids(capture_index), captured_generations(capture_index))
    end do
    call ft_cond_broadcast(manager%condition)
    call ft_mutex_unlock(manager%mutex)
    ok = .true.; reason = ''
  end subroutine connect_owner

  function connect_message_locked() result(message)
    character(:), allocatable :: message
    character(64) :: count

    write(count, '(I0)') manager%connection_count
    message = '{"type":"Connect","sessionId":' // json_quote(session_id()) // &
      ',"connectionCount":' // trim(count) // ',"lastCloseReason":' // json_quote(manager%last_close_reason)
    if (len(manager%max_observed_timestamp) > 0) then
      message = message // ',"maxObservedTimestamp":' // json_quote(manager%max_observed_timestamp)
    end if
    message = message // ',"clientTs":0}'
  end function connect_message_locked

  function session_id() result(value)
    character(:), allocatable :: value
    character(32) :: clock_hex
    integer(int64) :: clock

    clock = int(ft_monotonic_ms(), int64)
    write(clock_hex, '(Z16.16)') clock
    value = '00000000-0000-4000-8000-' // clock_hex(5:16)
  end function session_id

  subroutine snapshot_add_message(message, ids, generations, count)
    character(:), allocatable, intent(out) :: message
    integer, intent(out) :: ids(max_subscriptions), generations(max_subscriptions), count
    integer :: slot

    count = 0
    message = '{"type":"ModifyQuerySet","baseVersion":0,"newVersion":1,"modifications":['
    do slot = 1, max_subscriptions
      if (.not. manager%subscriptions(slot)%occupied .or. .not. manager%subscriptions(slot)%active .or. &
          manager%subscriptions(slot)%remove_pending) cycle
      if (count > 0) message = message // ','
      count = count + 1
      ids(count) = manager%subscriptions(slot)%query_id
      generations(count) = manager%subscriptions(slot)%generation
      message = message // add_modification(manager%subscriptions(slot))
      manager%subscriptions(slot)%rehydrating = manager%subscriptions(slot)%has_last_value
    end do
    message = message // ']}'
  end subroutine snapshot_add_message

  function add_modification(subscription) result(message)
    type(subscription_state), intent(in) :: subscription
    character(:), allocatable :: message
    character(32) :: id

    write(id, '(I0)') subscription%query_id
    message = '{"type":"Add","queryId":' // trim(id) // ',"udfPath":' // &
      json_quote(subscription%path) // ',"args":[' // subscription%args // ']}'
  end function add_modification

  subroutine pending_command_slot(slot)
    integer, intent(out) :: slot
    integer :: index

    slot = 0
    call ft_mutex_lock(manager%mutex)
    do index = 1, max_subscriptions
      if (.not. manager%subscriptions(index)%occupied) cycle
      if (manager%subscriptions(index)%remove_pending .and. .not. manager%subscriptions(index)%remove_done) then
        slot = -index
        exit
      end if
      if (manager%subscriptions(index)%active .and. manager%subscriptions(index)%add_pending) then
        slot = index
        exit
      end if
    end do
    call ft_mutex_unlock(manager%mutex)
  end subroutine pending_command_slot

  subroutine send_pending_command(signed_slot, ok, reason)
    integer, intent(in) :: signed_slot
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: reason
    integer :: slot, base, new_version, id, generation
    logical :: removing
    character(:), allocatable :: message
    character(32) :: base_text, next_text, id_text
    character(kind=c_char), allocatable :: message_c(:)
    type(c_ptr) :: socket, transport_error
    integer(c_int) :: sent

    removing = signed_slot < 0
    slot = abs(signed_slot)
    call ft_mutex_lock(manager%mutex)
    if (.not. manager%subscriptions(slot)%occupied) then
      call ft_mutex_unlock(manager%mutex)
      ok = .true.; reason = ''; return
    end if
    base = manager%query_set_version
    new_version = base + 1
    id = manager%subscriptions(slot)%query_id
    generation = manager%subscriptions(slot)%generation
    socket = manager%socket
    write(base_text, '(I0)') base
    write(next_text, '(I0)') new_version
    write(id_text, '(I0)') id
    message = '{"type":"ModifyQuerySet","baseVersion":' // trim(base_text) // ',"newVersion":' // &
      trim(next_text) // ',"modifications":['
    if (removing) then
      message = message // '{"type":"Remove","queryId":' // trim(id_text) // '}]}'
    else
      message = message // add_modification(manager%subscriptions(slot)) // ']}'
    end if
    call ft_mutex_unlock(manager%mutex)
    call make_c_text(message, message_c)
    sent = ft_ws_send(socket, message_c, int(len(message), c_size_t), transport_error)
    if (sent == 0_c_int) then
      reason = error_text(transport_error)
      if (c_associated(transport_error)) call ft_free(transport_error)
      ok = .false.; return
    end if
    call ft_mutex_lock(manager%mutex)
    slot = find_subscription(id, generation)
    if (slot > 0) then
      manager%query_set_version = new_version
      if (removing) then
        manager%subscriptions(slot)%remove_done = .true.
        manager%subscriptions(slot)%remove_pending = .false.
      else
        manager%subscriptions(slot)%add_pending = .false.
      end if
      call ft_cond_broadcast(manager%condition)
    end if
    call ft_mutex_unlock(manager%mutex)
    ok = .true.; reason = ''
  end subroutine send_pending_command

  subroutine process_server_message(message, ok, protocol_error, reason)
    character(*), intent(in) :: message
    logical, intent(out) :: ok, protocol_error
    character(:), allocatable, intent(out) :: reason
    character(:), allocatable :: raw_type, type_name
    logical :: found, decoded

    raw_type = convex_json_member(message, 'type', found)
    if (.not. found) then
      ok = .false.; protocol_error = .true.; reason = 'server message omitted type'; return
    end if
    type_name = json_string(raw_type, decoded)
    if (.not. decoded) then
      ok = .false.; protocol_error = .true.; reason = 'server message type was invalid'; return
    end if
    select case (type_name)
    case ('Transition')
      call handle_transition(message, ok, reason)
      protocol_error = .not. ok
    case ('Ping', 'MutationResponse', 'ActionResponse')
      ok = .true.; protocol_error = .false.; reason = ''
    case default
      ok = .false.; protocol_error = .true.; reason = 'unknown server message type ' // type_name
    end select
  end subroutine process_server_message

  subroutine handle_transition(message, ok, reason)
    character(*), intent(in) :: message
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: reason
    character(:), allocatable :: start_object, end_object, modifications, start_ts, end_ts, object
    integer :: start_query, start_identity, end_query, end_identity, position, count, index, slot
    logical :: found, element_ok, start_timestamp_valid, end_timestamp_valid
    type(transition_modification) :: parsed(64)
    type(live_update) :: pending(max_subscriptions)
    logical :: has_pending(max_subscriptions), unchanged, suppress

    start_object = convex_json_member(message, 'startVersion', found)
    if (.not. found) then; ok = .false.; reason = 'Transition omitted startVersion'; return; end if
    end_object = convex_json_member(message, 'endVersion', found)
    if (.not. found) then; ok = .false.; reason = 'Transition omitted endVersion'; return; end if
    modifications = convex_json_member(message, 'modifications', found)
    if (.not. found .or. len(modifications) < 2) then
      ok = .false.; reason = 'Transition omitted modifications'; return
    end if
    if (modifications(1:1) /= '[') then
      ok = .false.; reason = 'Transition omitted modifications'; return
    end if
    call parse_state_version(start_object, start_query, start_identity, start_ts, ok)
    if (.not. ok) then; reason = 'Transition startVersion was invalid'; return; end if
    call parse_state_version(end_object, end_query, end_identity, end_ts, ok)
    if (.not. ok) then; reason = 'Transition endVersion was invalid'; return; end if
    start_timestamp_valid = canonical_timestamp(start_ts)
    end_timestamp_valid = canonical_timestamp(end_ts)
    if (.not. start_timestamp_valid .or. .not. end_timestamp_valid) then
      ok = .false.; reason = 'Transition timestamp was not canonical little-endian uint64'; return
    end if
    count = 0
    position = 2
    do
      call json_array_object(modifications, position, object, element_ok)
      if (.not. element_ok) exit
      count = count + 1
      if (count > size(parsed)) then
        ok = .false.; reason = 'Transition contained too many modifications'; return
      end if
      call parse_modification(object, parsed(count), ok, reason)
      if (.not. ok) return
    end do
    if (position > len_trim(modifications)) then
      ok = .false.; reason = 'Transition modifications were malformed'; return
    end if
    if (modifications(position:position) /= ']') then
      ok = .false.; reason = 'Transition modifications were malformed'; return
    end if

    has_pending = .false.
    call ft_mutex_lock(manager%mutex)
    if (start_query /= manager%remote_query_set .or. start_identity /= manager%remote_identity .or. &
        start_ts /= manager%remote_timestamp) then
      call ft_mutex_unlock(manager%mutex)
      ok = .false.; reason = 'Transition startVersion did not match local state'; return
    end if
    do index = 1, count
      slot = find_subscription_id(parsed(index)%query_id)
      if (slot == 0) cycle
      if (.not. manager%subscriptions(slot)%active .or. manager%subscriptions(slot)%remove_pending .or. &
          parsed(index)%kind == 1) cycle
      call clear_update(pending(slot))
      pending(slot)%query_id = parsed(index)%query_id
      pending(slot)%generation = manager%subscriptions(slot)%generation
      if (allocated(parsed(index)%logs)) pending(slot)%logs = parsed(index)%logs
      if (parsed(index)%kind == 2) then
        unchanged = .false.
        if (manager%subscriptions(slot)%has_last_value .and. allocated(manager%subscriptions(slot)%last_value)) then
          unchanged = manager%subscriptions(slot)%last_value == parsed(index)%value
        end if
        suppress = manager%subscriptions(slot)%rehydrating .and. unchanged
        manager%subscriptions(slot)%last_value = parsed(index)%value
        manager%subscriptions(slot)%has_last_value = .true.
        manager%subscriptions(slot)%rehydrating = .false.
        if (suppress) then
          has_pending(slot) = .false.
        else
          pending(slot)%is_error = .false.
          pending(slot)%value = parsed(index)%value
          has_pending(slot) = .true.
        end if
      else
        manager%subscriptions(slot)%has_last_value = .false.
        manager%subscriptions(slot)%rehydrating = .false.
        if (allocated(manager%subscriptions(slot)%last_value)) deallocate(manager%subscriptions(slot)%last_value)
        pending(slot)%is_error = .true.
        pending(slot)%error_name = 'FunctionError'
        pending(slot)%error_message = parsed(index)%error_message
        if (allocated(parsed(index)%error_data)) pending(slot)%error_data = parsed(index)%error_data
        has_pending(slot) = .true.
      end if
    end do
    manager%remote_query_set = end_query
    manager%remote_identity = end_identity
    manager%remote_timestamp = end_ts
    if (len(manager%max_observed_timestamp) == 0) then
      manager%max_observed_timestamp = end_ts
    else if (timestamp_greater(end_ts, manager%max_observed_timestamp)) then
      manager%max_observed_timestamp = end_ts
    end if
    do slot = 1, max_subscriptions
      if (has_pending(slot)) call enqueue_update_locked(pending(slot))
    end do
    call ft_cond_broadcast(manager%condition)
    call ft_mutex_unlock(manager%mutex)
    ok = .true.; reason = ''
  end subroutine handle_transition

  subroutine parse_state_version(object, query_set, identity, timestamp, ok)
    character(*), intent(in) :: object
    integer, intent(out) :: query_set, identity
    character(:), allocatable, intent(out) :: timestamp
    logical, intent(out) :: ok
    character(:), allocatable :: raw
    logical :: found, decoded

    raw = convex_json_member(object, 'querySet', found)
    if (.not. found) then; ok = .false.; return; end if
    call parse_nonnegative_integer(raw, query_set, ok)
    if (.not. ok) return
    raw = convex_json_member(object, 'identity', found)
    if (.not. found) then; ok = .false.; return; end if
    call parse_nonnegative_integer(raw, identity, ok)
    if (.not. ok) return
    raw = convex_json_member(object, 'ts', found)
    if (.not. found) then; ok = .false.; return; end if
    timestamp = json_string(raw, decoded)
    ok = decoded
  end subroutine parse_state_version

  subroutine parse_modification(object, modification, ok, reason)
    character(*), intent(in) :: object
    type(transition_modification), intent(out) :: modification
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: reason
    character(:), allocatable :: raw, kind
    logical :: found, decoded

    raw = convex_json_member(object, 'type', found)
    if (.not. found) then; ok = .false.; reason = 'Transition modification omitted type'; return; end if
    kind = json_string(raw, decoded)
    if (.not. decoded) then; ok = .false.; reason = 'Transition modification type was invalid'; return; end if
    select case (kind)
    case ('QueryRemoved'); modification%kind = 1
    case ('QueryUpdated'); modification%kind = 2
    case ('QueryFailed'); modification%kind = 3
    case default
      ok = .false.; reason = 'unknown Transition modification ' // kind; return
    end select
    raw = convex_json_member(object, 'queryId', found)
    if (.not. found) then; ok = .false.; reason = 'Transition modification omitted queryId'; return; end if
    call parse_nonnegative_integer(raw, modification%query_id, ok)
    if (.not. ok) then; reason = 'Transition modification queryId was invalid'; return; end if
    modification%logs = convex_json_member(object, 'logLines', found)
    if (modification%kind == 2) then
      modification%value = convex_json_member(object, 'value', found)
      if (.not. found) then; ok = .false.; reason = 'QueryUpdated omitted value'; return; end if
    else if (modification%kind == 3) then
      raw = convex_json_member(object, 'errorMessage', found)
      if (.not. found) then; ok = .false.; reason = 'QueryFailed omitted errorMessage'; return; end if
      modification%error_message = json_string(raw, decoded)
      if (.not. decoded) modification%error_message = raw
      modification%error_data = convex_json_member(object, 'errorData', found)
    end if
    ok = .true.; reason = ''
  end subroutine parse_modification

  subroutine json_array_object(array, position, object, ok)
    character(*), intent(in) :: array
    integer, intent(inout) :: position
    character(:), allocatable, intent(out) :: object
    logical, intent(out) :: ok
    integer :: start, depth
    logical :: quoted, escaped

    do while (position <= len_trim(array))
      if (index(' ,' // achar(9) // achar(10) // achar(13), array(position:position)) == 0) exit
      position = position + 1
    end do
    if (position > len_trim(array)) then
      ok = .false.; object = ''; return
    end if
    if (array(position:position) == ']') then
      ok = .false.; object = ''; return
    end if
    if (array(position:position) /= '{') then
      ok = .false.; object = ''; return
    end if
    start = position
    depth = 0; quoted = .false.; escaped = .false.
    do while (position <= len_trim(array))
      if (quoted) then
        if (.not. escaped .and. array(position:position) == '"') quoted = .false.
        if (.not. escaped .and. array(position:position) == '\') then
          escaped = .true.
        else
          escaped = .false.
        end if
      else
        if (array(position:position) == '"') quoted = .true.
        if (array(position:position) == '{') depth = depth + 1
        if (array(position:position) == '}') then
          depth = depth - 1
          if (depth == 0) then
            object = array(start:position)
            position = position + 1
            ok = .true.
            return
          end if
        end if
      end if
      position = position + 1
    end do
    ok = .false.; object = ''
  end subroutine json_array_object

  subroutine parse_nonnegative_integer(raw, value, ok)
    character(*), intent(in) :: raw
    integer, intent(out) :: value
    logical, intent(out) :: ok
    integer :: status

    if (len_trim(raw) == 0 .or. index(raw, '.') > 0 .or. index(raw, 'e') > 0 .or. index(raw, 'E') > 0) then
      ok = .false.; value = 0; return
    end if
    read(raw, *, iostat=status) value
    ok = status == 0 .and. value >= 0
  end subroutine parse_nonnegative_integer

  logical function canonical_timestamp(timestamp)
    character(*), intent(in) :: timestamp
    integer :: bytes(8)
    logical :: ok

    call decode_timestamp(timestamp, bytes, ok)
    canonical_timestamp = ok
  end function canonical_timestamp

  logical function timestamp_greater(left, right)
    character(*), intent(in) :: left, right
    integer :: left_bytes(8), right_bytes(8), index
    logical :: left_ok, right_ok

    call decode_timestamp(left, left_bytes, left_ok)
    call decode_timestamp(right, right_bytes, right_ok)
    timestamp_greater = .false.
    if (.not. left_ok .or. .not. right_ok) return
    do index = 8, 1, -1
      if (left_bytes(index) > right_bytes(index)) then
        timestamp_greater = .true.; return
      else if (left_bytes(index) < right_bytes(index)) then
        return
      end if
    end do
  end function timestamp_greater

  subroutine decode_timestamp(timestamp, bytes, ok)
    character(*), intent(in) :: timestamp
    integer, intent(out) :: bytes(8)
    logical, intent(out) :: ok
    integer :: values(12), index, at, triple

    bytes = 0
    if (len(timestamp) /= 12) then
      ok = .false.; return
    end if
    if (timestamp(12:12) /= '=') then
      ok = .false.; return
    end if
    do index = 1, 11
      values(index) = base64_value(timestamp(index:index))
      if (values(index) < 0) then; ok = .false.; return; end if
    end do
    if (iand(values(11), 3) /= 0) then; ok = .false.; return; end if
    at = 1
    do index = 1, 5, 4
      triple = ishft(values(index), 18) + ishft(values(index + 1), 12) + &
        ishft(values(index + 2), 6) + values(index + 3)
      bytes(at) = iand(ishft(triple, -16), 255)
      bytes(at + 1) = iand(ishft(triple, -8), 255)
      bytes(at + 2) = iand(triple, 255)
      at = at + 3
    end do
    triple = ishft(values(9), 18) + ishft(values(10), 12) + ishft(values(11), 6)
    bytes(7) = iand(ishft(triple, -16), 255)
    bytes(8) = iand(ishft(triple, -8), 255)
    ok = .true.
  end subroutine decode_timestamp

  integer function base64_value(character_value)
    character, intent(in) :: character_value
    integer :: code

    code = iachar(character_value)
    select case (code)
    case (iachar('A'):iachar('Z')); base64_value = code - iachar('A')
    case (iachar('a'):iachar('z')); base64_value = code - iachar('a') + 26
    case (iachar('0'):iachar('9')); base64_value = code - iachar('0') + 52
    case (iachar('+')); base64_value = 62
    case (iachar('/')); base64_value = 63
    case default; base64_value = -1
    end select
  end function base64_value

  subroutine transport_disconnect(reason)
    character(*), intent(in) :: reason
    type(c_ptr) :: socket

    call ft_mutex_lock(manager%mutex)
    socket = manager%socket
    manager%socket = c_null_ptr
    manager%connected = .false.
    call retire_connection_locked(reason)
    call ft_mutex_unlock(manager%mutex)
    if (c_associated(socket)) call ft_ws_close(socket)
  end subroutine transport_disconnect

  subroutine retire_connection_locked(reason)
    character(*), intent(in) :: reason
    integer :: slot

    manager%connection_count = manager%connection_count + 1
    manager%last_close_reason = reason
    manager%query_set_version = 0
    manager%remote_query_set = 0
    manager%remote_identity = 0
    manager%remote_timestamp = initial_timestamp
    do slot = 1, max_subscriptions
      if (manager%subscriptions(slot)%occupied .and. manager%subscriptions(slot)%active .and. &
          .not. manager%subscriptions(slot)%remove_pending) then
        manager%subscriptions(slot)%add_pending = .true.
        manager%subscriptions(slot)%rehydrating = manager%subscriptions(slot)%has_last_value
      end if
    end do
    call ft_cond_broadcast(manager%condition)
  end subroutine retire_connection_locked

  subroutine publish_all_error(name, message, established_only)
    character(*), intent(in) :: name, message
    logical, intent(in) :: established_only
    integer :: slot
    type(live_update) :: update

    call ft_mutex_lock(manager%mutex)
    do slot = 1, max_subscriptions
      if (.not. manager%subscriptions(slot)%occupied .or. .not. manager%subscriptions(slot)%active .or. &
          manager%subscriptions(slot)%remove_pending) cycle
      if (established_only .and. manager%subscriptions(slot)%add_pending) cycle
      update%query_id = manager%subscriptions(slot)%query_id
      update%generation = manager%subscriptions(slot)%generation
      update%is_error = .true.
      update%error_name = name
      update%error_message = message
      call enqueue_update_locked(update)
      call clear_update(update)
    end do
    call ft_cond_broadcast(manager%condition)
    call ft_mutex_unlock(manager%mutex)
  end subroutine publish_all_error

  subroutine enqueue_update_locked(update)
    type(live_update), intent(in) :: update
    integer :: bytes

    bytes = update_size(update)
    do while (manager%update_count >= max_updates .or. &
      (manager%update_count > 0 .and. manager%update_bytes + bytes > max_update_bytes))
      call remove_update(1)
    end do
    if (bytes > max_update_bytes) return
    manager%update_count = manager%update_count + 1
    manager%updates(manager%update_count) = update
    manager%update_bytes = manager%update_bytes + bytes
  end subroutine enqueue_update_locked

  integer function update_size(update)
    type(live_update), intent(in) :: update

    update_size = 256
    if (allocated(update%value)) update_size = update_size + len(update%value)
    if (allocated(update%logs)) update_size = update_size + len(update%logs)
    if (allocated(update%error_name)) update_size = update_size + len(update%error_name)
    if (allocated(update%error_message)) update_size = update_size + len(update%error_message)
    if (allocated(update%error_data)) update_size = update_size + len(update%error_data)
  end function update_size

  integer function find_update(query_id, generation)
    integer, intent(in) :: query_id, generation
    integer :: index

    find_update = 0
    do index = 1, manager%update_count
      if (manager%updates(index)%query_id == query_id .and. manager%updates(index)%generation == generation) then
        find_update = index
        return
      end if
    end do
  end function find_update

  subroutine remove_update(index)
    integer, intent(in) :: index
    integer :: position

    if (index < 1 .or. index > manager%update_count) return
    manager%update_bytes = manager%update_bytes - update_size(manager%updates(index))
    call clear_update(manager%updates(index))
    do position = index, manager%update_count - 1
      manager%updates(position) = manager%updates(position + 1)
    end do
    call clear_update(manager%updates(manager%update_count))
    manager%update_count = manager%update_count - 1
  end subroutine remove_update

  subroutine discard_updates(query_id, generation)
    integer, intent(in) :: query_id, generation
    integer :: index

    index = 1
    do while (index <= manager%update_count)
      if (manager%updates(index)%query_id == query_id .and. manager%updates(index)%generation == generation) then
        call remove_update(index)
      else
        index = index + 1
      end if
    end do
  end subroutine discard_updates

  subroutine clear_update(update)
    type(live_update), intent(inout) :: update

    update%query_id = -1
    update%generation = 0
    update%is_error = .false.
    if (allocated(update%value)) deallocate(update%value)
    if (allocated(update%logs)) deallocate(update%logs)
    if (allocated(update%error_name)) deallocate(update%error_name)
    if (allocated(update%error_message)) deallocate(update%error_message)
    if (allocated(update%error_data)) deallocate(update%error_data)
  end subroutine clear_update

  integer function free_subscription_slot()
    integer :: slot

    free_subscription_slot = 0
    do slot = 1, max_subscriptions
      if (.not. manager%subscriptions(slot)%occupied) then
        free_subscription_slot = slot
        return
      end if
    end do
  end function free_subscription_slot

  integer function find_subscription(query_id, generation)
    integer, intent(in) :: query_id, generation
    integer :: slot

    find_subscription = 0
    do slot = 1, max_subscriptions
      if (manager%subscriptions(slot)%occupied .and. manager%subscriptions(slot)%query_id == query_id .and. &
          manager%subscriptions(slot)%generation == generation) then
        find_subscription = slot
        return
      end if
    end do
  end function find_subscription

  integer function find_subscription_id(query_id)
    integer, intent(in) :: query_id
    integer :: slot

    find_subscription_id = 0
    do slot = 1, max_subscriptions
      if (manager%subscriptions(slot)%occupied .and. manager%subscriptions(slot)%query_id == query_id) then
        find_subscription_id = slot
        return
      end if
    end do
  end function find_subscription_id

  logical function subscription_active(query_id, generation)
    integer, intent(in) :: query_id, generation
    integer :: slot

    slot = find_subscription(query_id, generation)
    subscription_active = slot > 0
    if (slot > 0) then
      subscription_active = manager%subscriptions(slot)%active .or. .not. manager%subscriptions(slot)%remove_done
    end if
  end function subscription_active

  integer function active_subscription_count()
    integer :: slot

    active_subscription_count = 0
    do slot = 1, max_subscriptions
      if (manager%subscriptions(slot)%occupied .and. manager%subscriptions(slot)%active .and. &
          .not. manager%subscriptions(slot)%remove_pending) active_subscription_count = active_subscription_count + 1
    end do
  end function active_subscription_count

  subroutine clear_matching_add(query_id, generation)
    integer, intent(in) :: query_id, generation
    integer :: slot

    slot = find_subscription(query_id, generation)
    if (slot > 0) manager%subscriptions(slot)%add_pending = .false.
  end subroutine clear_matching_add

  subroutine complete_disconnected_removes()
    integer :: slot

    if (c_associated(manager%socket)) return
    do slot = 1, max_subscriptions
      if (manager%subscriptions(slot)%occupied .and. manager%subscriptions(slot)%remove_pending .and. &
          .not. manager%subscriptions(slot)%remove_done) then
        manager%subscriptions(slot)%remove_done = .true.
        manager%subscriptions(slot)%remove_pending = .false.
      end if
    end do
    call ft_cond_broadcast(manager%condition)
  end subroutine complete_disconnected_removes

  subroutine clear_subscription(slot)
    integer, intent(in) :: slot
    integer :: generation

    generation = manager%subscriptions(slot)%generation
    manager%subscriptions(slot) = subscription_state()
    manager%subscriptions(slot)%generation = generation
  end subroutine clear_subscription

  subroutine reset_manager()
    integer :: slot

    do while (manager%update_count > 0)
      call remove_update(1)
    end do
    do slot = 1, max_subscriptions
      call clear_subscription(slot)
    end do
    manager = live_manager()
  end subroutine reset_manager

  function convex_json_member(document, name, found) result(value)
    character(*), intent(in) :: document, name
    logical, intent(out) :: found
    character(:), allocatable :: value
    logical :: valid

    call parse_json_object(document, name, '', .false., value, found, valid)
    if (.not. valid) then
      found = .false.
      value = ''
    end if
  end function convex_json_member

  logical function convex_json_object_allowed(document, allowed_names)
    character(*), intent(in) :: document, allowed_names
    character(:), allocatable :: ignored
    logical :: found, valid

    call parse_json_object(document, '', allowed_names, .true., ignored, found, valid)
    convex_json_object_allowed = valid
  end function convex_json_object_allowed

  subroutine parse_json_object(document, target, allowed_names, restrict_names, value, found, valid)
    character(*), intent(in) :: document, target, allowed_names
    logical, intent(in) :: restrict_names
    character(:), allocatable, intent(out) :: value
    logical, intent(out) :: found, valid
    character(:), allocatable :: raw_key, key, seen
    integer :: position, value_start, value_finish
    logical :: key_ok, value_ok

    value = ''
    found = .false.
    valid = .false.
    seen = ','
    position = 1
    call skip_json_space(document, position)
    if (.not. json_at(document, position, '{')) return
    position = position + 1
    call skip_json_space(document, position)
    if (json_at(document, position, '}')) then
      position = position + 1
      call skip_json_space(document, position)
      valid = position > len(document)
      return
    end if
    do
      if (.not. json_at(document, position, '"')) return
      value_start = position
      call scan_json_string(document, position, key_ok)
      if (.not. key_ok) return
      raw_key = document(value_start:position - 1)
      key = json_string(raw_key, key_ok)
      if (.not. key_ok) return
      if (index(key, ',') > 0) return
      if (index(seen, ',' // key // ',') > 0) return
      seen = seen // key // ','
      if (restrict_names) then
        if (index(',' // allowed_names // ',', ',' // key // ',') == 0) return
      end if
      call skip_json_space(document, position)
      if (.not. json_at(document, position, ':')) return
      position = position + 1
      call skip_json_space(document, position)
      value_start = position
      call scan_json_value(document, position, value_ok)
      if (.not. value_ok) return
      value_finish = position - 1
      if (key == target) then
        found = .true.
        value = document(value_start:value_finish)
      end if
      call skip_json_space(document, position)
      if (position > len(document)) return
      if (json_at(document, position, '}')) then
        position = position + 1
        exit
      end if
      if (.not. json_at(document, position, ',')) return
      position = position + 1
      call skip_json_space(document, position)
    end do
    call skip_json_space(document, position)
    valid = position > len(document)
  end subroutine parse_json_object

  recursive subroutine scan_json_value(document, position, ok)
    character(*), intent(in) :: document
    integer, intent(inout) :: position
    logical, intent(out) :: ok
    integer :: start

    ok = .false.
    call skip_json_space(document, position)
    if (position > len(document)) return
    select case (document(position:position))
    case ('"')
      call scan_json_string(document, position, ok)
    case ('{')
      position = position + 1
      call skip_json_space(document, position)
      if (json_at(document, position, '}')) then
        position = position + 1
        ok = .true.
        return
      end if
      do
        if (.not. json_at(document, position, '"')) return
        call scan_json_string(document, position, ok)
        if (.not. ok) return
        call skip_json_space(document, position)
        if (.not. json_at(document, position, ':')) then
          ok = .false.
          return
        end if
        position = position + 1
        call scan_json_value(document, position, ok)
        if (.not. ok) return
        call skip_json_space(document, position)
        if (position > len(document)) then
          ok = .false.
          return
        end if
        if (json_at(document, position, '}')) then
          position = position + 1
          ok = .true.
          return
        end if
        if (.not. json_at(document, position, ',')) then
          ok = .false.
          return
        end if
        position = position + 1
        call skip_json_space(document, position)
      end do
    case ('[')
      position = position + 1
      call skip_json_space(document, position)
      if (json_at(document, position, ']')) then
        position = position + 1
        ok = .true.
        return
      end if
      do
        call scan_json_value(document, position, ok)
        if (.not. ok) return
        call skip_json_space(document, position)
        if (position > len(document)) then
          ok = .false.
          return
        end if
        if (json_at(document, position, ']')) then
          position = position + 1
          ok = .true.
          return
        end if
        if (.not. json_at(document, position, ',')) then
          ok = .false.
          return
        end if
        position = position + 1
      end do
    case ('t')
      call scan_json_literal(document, position, 'true', ok)
    case ('f')
      call scan_json_literal(document, position, 'false', ok)
    case ('n')
      call scan_json_literal(document, position, 'null', ok)
    case default
      start = position
      call scan_json_number(document, position, ok)
      if (position == start) ok = .false.
    end select
  end subroutine scan_json_value

  subroutine scan_json_string(document, position, ok)
    character(*), intent(in) :: document
    integer, intent(inout) :: position
    logical, intent(out) :: ok
    integer :: hex_index

    ok = .false.
    if (.not. json_at(document, position, '"')) return
    position = position + 1
    do while (position <= len(document))
      if (iachar(document(position:position)) < 32) return
      if (document(position:position) == '"') then
        position = position + 1
        ok = .true.
        return
      end if
      if (document(position:position) == '\') then
        position = position + 1
        if (position > len(document)) return
        if (index('"\/bfnrtu', document(position:position)) == 0) return
        if (document(position:position) == 'u') then
          if (position + 4 > len(document)) return
          do hex_index = position + 1, position + 4
            if (index('0123456789abcdefABCDEF', document(hex_index:hex_index)) == 0) return
          end do
          position = position + 4
        end if
      end if
      position = position + 1
    end do
  end subroutine scan_json_string

  subroutine scan_json_literal(document, position, literal, ok)
    character(*), intent(in) :: document, literal
    integer, intent(inout) :: position
    logical, intent(out) :: ok
    if (position + len(literal) - 1 > len(document)) then
      ok = .false.
      return
    end if
    ok = document(position:position + len(literal) - 1) == literal
    if (ok) position = position + len(literal)
  end subroutine scan_json_literal

  subroutine scan_json_number(document, position, ok)
    character(*), intent(in) :: document
    integer, intent(inout) :: position
    logical, intent(out) :: ok

    ok = .false.
    if (json_at(document, position, '-')) position = position + 1
    if (position > len(document)) return
    if (json_at(document, position, '0')) then
      position = position + 1
    else if (json_nonzero_digit(document, position)) then
      do while (json_digit(document, position))
        position = position + 1
      end do
    else
      return
    end if
    if (json_at(document, position, '.')) then
      position = position + 1
      if (.not. json_digit(document, position)) return
      do while (json_digit(document, position))
        position = position + 1
      end do
    end if
    if (position <= len(document)) then
      if (json_at(document, position, 'e') .or. json_at(document, position, 'E')) then
        position = position + 1
        if (json_at(document, position, '+') .or. json_at(document, position, '-')) position = position + 1
        if (.not. json_digit(document, position)) return
        do while (json_digit(document, position))
          position = position + 1
        end do
      end if
    end if
    ok = .true.
  end subroutine scan_json_number

  subroutine skip_json_space(document, position)
    character(*), intent(in) :: document
    integer, intent(inout) :: position
    do while (position <= len(document))
      if (index(' ' // achar(9) // achar(10) // achar(13), document(position:position)) == 0) exit
      position = position + 1
    end do
  end subroutine skip_json_space

  logical function json_at(document, position, expected)
    character(*), intent(in) :: document, expected
    integer, intent(in) :: position
    json_at = .false.
    if (position < 1 .or. position > len(document)) return
    json_at = document(position:position) == expected
  end function json_at

  logical function json_digit(document, position)
    character(*), intent(in) :: document
    integer, intent(in) :: position
    json_digit = .false.
    if (position < 1 .or. position > len(document)) return
    json_digit = index('0123456789', document(position:position)) > 0
  end function json_digit

  logical function json_nonzero_digit(document, position)
    character(*), intent(in) :: document
    integer, intent(in) :: position
    json_nonzero_digit = .false.
    if (position < 1 .or. position > len(document)) return
    json_nonzero_digit = index('123456789', document(position:position)) > 0
  end function json_nonzero_digit

  function convex_count(value, ok) result(count)
    character(*), intent(in) :: value
    logical, intent(out) :: ok
    integer :: count
    character(:), allocatable :: raw
    real(real64) :: number
    integer :: status
    logical :: found

    raw = convex_json_member(value, 'count', found)
    if (.not. found .or. len(raw) == 0) then
      ok = .false.; count = 0; return
    end if
    if (raw(1:1) == '"') then
      ok = .false.; count = 0; return
    end if
    read(raw, *, iostat=status) number
    if (status /= 0 .or. .not. ieee_is_finite(number) .or. number > anint(number) .or. number < anint(number) .or. &
        abs(number) > real(huge(count), real64)) then
      ok = .false.; count = 0; return
    end if
    count = int(number)
    ok = .true.
  end function convex_count

#ifdef FORTRAN_TESTING
  ! These hooks compile only into the language-local test executable. They let
  ! deterministic tests drive the real transition transaction without opening
  ! a network connection or weakening the shipped client and adapter binaries.
  subroutine convex_test_live_begin()
    call reset_manager()
    manager%mutex = ft_mutex_new()
    manager%condition = ft_cond_new()
    if (.not. c_associated(manager%mutex) .or. .not. c_associated(manager%condition)) &
      error stop 'could not initialize Live test state'
    manager%initialized = .true.
    manager%remote_timestamp = initial_timestamp
    manager%max_observed_timestamp = ''
    manager%last_close_reason = 'InitialConnect'
    manager%subscriptions(1)%occupied = .true.
    manager%subscriptions(1)%active = .true.
    manager%subscriptions(1)%query_id = 0
    manager%subscriptions(1)%generation = 1
    manager%subscriptions(1)%path = 'demo:state'
    manager%subscriptions(1)%args = '{}'
  end subroutine convex_test_live_begin

  subroutine convex_test_live_dns_stall_begin()
    type(convex_client) :: client
    logical :: ok
    character(:), allocatable :: error

    call reset_manager()
    client%url = 'http://fortran-stall.invalid'
    client%token = ''
    manager%subscriptions(1)%occupied = .true.
    manager%subscriptions(1)%active = .true.
    manager%subscriptions(1)%add_pending = .true.
    manager%subscriptions(1)%query_id = 0
    manager%subscriptions(1)%generation = 1
    manager%subscriptions(1)%path = 'demo:state'
    manager%subscriptions(1)%args = '{}'
    manager%next_query_id = 1
    call initialize_manager(client, ok, error)
    if (.not. ok) error stop error
  end subroutine convex_test_live_dns_stall_begin

  subroutine convex_test_live_apply(message, ok, error)
    character(*), intent(in) :: message
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: error
    call handle_transition(message, ok, error)
  end subroutine convex_test_live_apply

  subroutine convex_test_live_next(value, ok, error, error_name)
    character(:), allocatable, intent(out) :: value, error, error_name
    logical, intent(out) :: ok
    type(convex_live) :: live
    live%query_id = 0
    live%generation = 1
    call convex_live_next(live, value, ok, error, error_name=error_name, timeout_ms=0)
  end subroutine convex_test_live_next

  subroutine convex_test_live_stats(count, bytes, maximum_timestamp)
    integer, intent(out) :: count, bytes
    character(:), allocatable, intent(out) :: maximum_timestamp
    call ft_mutex_lock(manager%mutex)
    count = manager%update_count
    bytes = manager%update_bytes
    maximum_timestamp = manager%max_observed_timestamp
    call ft_mutex_unlock(manager%mutex)
  end subroutine convex_test_live_stats

  subroutine convex_test_live_end()
    call ft_mutex_free(manager%mutex)
    call ft_cond_free(manager%condition)
    call reset_manager()
  end subroutine convex_test_live_end
#endif

end module convex_fortran
