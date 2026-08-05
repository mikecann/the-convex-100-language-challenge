program basics
  use convex_fortran
  implicit none

  type(convex_client) :: client
  type(convex_live) :: live
  character(:), allocatable :: url, room, value, error, mutation_args, applied, state
  logical :: ok, found
  integer :: count

  call get_environment_variable('CONVEX_URL', length=count)
  if (count == 0) error stop 'CONVEX_URL is required'
  allocate(character(count) :: url)
  call get_environment_variable('CONVEX_URL', url)
  room = argument_or_default('fortran-basic-example')

  ! Configure this client from the verifier-selected deployment.
  call convex_new(url, client, ok, error)
  if (.not. ok) error stop error
  ! The dedicated public test functions need no authentication token.

  ! Query the counter over HTTP before opening the Live query.
  call convex_call(client, 'query', 'demo:state', '{"room":' // quote(room) // '}', value, ok, error)
  if (.not. ok) error stop 'unexpected initial HTTP value'
  ! Decode Convex's JSON number into an ordinary Fortran integer.
  call assert_count(value, 0, 'unexpected initial HTTP value')
  write (*, '(A)') 'current count: 0'

  ! Start `/api/sync` first, so the mutation cannot race past the subscription.
  call convex_live_start(client, 'demo:state', '{"room":' // quote(room) // '}', live, ok, error)
  if (.not. ok) error stop error
  call convex_live_next(live, value, ok, error)
  if (.not. ok) error stop 'unexpected initial Live value'
  call assert_count(value, 0, 'unexpected initial Live value')
  write (*, '(A)') 'live initial count: 0'

  ! The room-specific run ID makes a retry safe: this mutation increments once.
  mutation_args = '{"room":' // quote(room) // ',"language":"Fortran","runId":' // quote(room // '-once') // '}'
  call convex_call(client, 'mutation', 'demo:increment', mutation_args, value, ok, error)
  if (.not. ok) error stop 'unexpected mutation result'
  applied = convex_json_member(value, 'applied', found)
  if (.not. found .or. applied /= 'true') error stop 'unexpected mutation result'
  state = convex_json_member(value, 'state', found)
  if (.not. found) error stop 'unexpected mutation result'
  call assert_count(state, 1, 'unexpected mutation result')
  write (*, '(A)') 'mutation applied: true'
  write (*, '(A)') 'mutation count: 1'

  ! Wait for the server transition that contains the same updated counter.
  call convex_live_next(live, value, ok, error)
  if (.not. ok) error stop 'unexpected updated Live value'
  call assert_count(value, 1, 'unexpected updated Live value')
  write (*, '(A)') 'live updated count: 1'
  ! Unsubscribe first, then stop the sole transport owner and release its socket.
  call convex_live_close(live)
  call convex_live_close()

  ! Stdout is deliberately the universal six-line happy-path transcript.
  write (*, '(A)') 'verified count: 0 -> 1'

contains

  function argument_or_default(default) result(value)
    character(*), intent(in) :: default
    character(:), allocatable :: value
    integer :: length

    if (command_argument_count() == 0) then
      value = default
      return
    end if
    call get_command_argument(1, length=length)
    allocate(character(length) :: value)
    call get_command_argument(1, value)
  end function argument_or_default

  subroutine assert_count(json, expected, message)
    character(*), intent(in) :: json, message
    integer, intent(in) :: expected
    logical :: count_ok
    integer :: decoded

    decoded = convex_count(json, count_ok)
    if (.not. count_ok) error stop message
    if (decoded /= expected) error stop message
  end subroutine assert_count

  function quote(text) result(value)
    character(*), intent(in) :: text
    character(:), allocatable :: value
    integer :: index

    value = '"'
    do index = 1, len_trim(text)
      if (text(index:index) == '"' .or. text(index:index) == '\\') value = value // '\\'
      value = value // text(index:index)
    end do
    value = value // '"'
  end function quote

end program basics
