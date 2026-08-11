! Video-demo watch mode: subscribe to demo:state and print every live update
! until the process is killed. Not part of the verified example or the
! conformance suite; this exists so a human can poke the counter from the
! Convex dashboard and watch Fortran react in real time.
program watch
  use, intrinsic :: iso_fortran_env, only: output_unit
  use convex_fortran
  implicit none

  type(convex_client) :: client
  type(convex_live) :: live
  character(:), allocatable :: url, room, value, error
  logical :: ok, count_ok
  integer :: length, decoded

  call get_environment_variable('CONVEX_URL', length=length)
  if (length == 0) error stop 'CONVEX_URL is required'
  allocate(character(length) :: url)
  call get_environment_variable('CONVEX_URL', url)
  room = argument_or_default('fortran-live-demo')

  call convex_new(url, client, ok, error)
  if (.not. ok) error stop error

  write (output_unit, '(A)') 'Fortran (1957) is watching room "' // room // '"...'
  write (output_unit, '(A)') 'run demo:increment from the Convex dashboard and watch this terminal.'
  flush (output_unit)

  call convex_live_start(client, 'demo:state', '{"room":"' // room // '"}', live, ok, error)
  if (.not. ok) error stop error

  do
    call convex_live_next(live, value, ok, error, timeout_ms=-1)
    if (.not. ok) error stop error
    decoded = convex_count(value, count_ok)
    if (count_ok) then
      write (output_unit, '(A,I0)') 'live count: ', decoded
    else
      write (output_unit, '(A)') 'live value: ' // value
    end if
    flush (output_unit)
  end do

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

end program watch
