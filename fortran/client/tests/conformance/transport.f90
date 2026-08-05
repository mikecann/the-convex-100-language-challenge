module adapter_transport
  use, intrinsic :: iso_c_binding
  implicit none
  private

  public :: stream_open, stream_read_line, stream_write_line, stream_close
  public :: mutex_new, mutex_lock, mutex_unlock, mutex_free
  public :: condition_new, condition_wait, condition_broadcast, condition_free
  public :: thread_start, thread_join, thread_join_bounded, monotonic_ms

  interface
    function ft_stream_open(address, error) bind(c, name='ft_stream_open') result(stream)
      import :: c_char, c_ptr
      character(kind=c_char), intent(in) :: address(*)
      type(c_ptr), intent(out) :: error
      type(c_ptr) :: stream
    end function
    function ft_stream_readline(stream, line, length, maximum, error) bind(c, name='ft_stream_readline') result(status)
      import :: c_ptr, c_size_t, c_int
      type(c_ptr), value :: stream
      type(c_ptr), intent(out) :: line, error
      integer(c_size_t), intent(out) :: length
      integer(c_size_t), value :: maximum
      integer(c_int) :: status
    end function
    function ft_stream_write(stream, text, length, timeout_ms, error) bind(c, name='ft_stream_write') result(status)
      import :: c_ptr, c_char, c_size_t, c_int
      type(c_ptr), value :: stream
      character(kind=c_char), intent(in) :: text(*)
      integer(c_size_t), value :: length
      integer(c_int), value :: timeout_ms
      type(c_ptr), intent(out) :: error
      integer(c_int) :: status
    end function
    subroutine ft_stream_close(stream) bind(c, name='ft_stream_close')
      import :: c_ptr
      type(c_ptr), value :: stream
    end subroutine
    function ft_mutex_new() bind(c, name='ft_mutex_new') result(handle)
      import :: c_ptr
      type(c_ptr) :: handle
    end function
    subroutine ft_mutex_lock(handle) bind(c, name='ft_mutex_lock')
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine
    subroutine ft_mutex_unlock(handle) bind(c, name='ft_mutex_unlock')
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine
    subroutine ft_mutex_free(handle) bind(c, name='ft_mutex_free')
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine
    function ft_cond_new() bind(c, name='ft_cond_new') result(handle)
      import :: c_ptr
      type(c_ptr) :: handle
    end function
    function ft_cond_wait(condition, mutex, timeout_ms) bind(c, name='ft_cond_wait') result(status)
      import :: c_ptr, c_int
      type(c_ptr), value :: condition, mutex
      integer(c_int), value :: timeout_ms
      integer(c_int) :: status
    end function
    subroutine ft_cond_broadcast(condition) bind(c, name='ft_cond_broadcast')
      import :: c_ptr
      type(c_ptr), value :: condition
    end subroutine
    subroutine ft_cond_free(condition) bind(c, name='ft_cond_free')
      import :: c_ptr
      type(c_ptr), value :: condition
    end subroutine
    function ft_thread_start(function, argument) bind(c, name='ft_thread_start') result(handle)
      import :: c_funptr, c_ptr
      type(c_funptr), value :: function
      type(c_ptr), value :: argument
      type(c_ptr) :: handle
    end function
    subroutine ft_thread_join(handle) bind(c, name='ft_thread_join')
      import :: c_ptr
      type(c_ptr), value :: handle
    end subroutine
    function ft_thread_join_bounded(handle, timeout_ms) bind(c, name='ft_thread_join_bounded') result(joined)
      import :: c_ptr, c_int
      type(c_ptr), value :: handle
      integer(c_int), value :: timeout_ms
      integer(c_int) :: joined
    end function
    function ft_monotonic_ms() bind(c, name='ft_monotonic_ms') result(value)
      import :: c_int64_t
      integer(c_int64_t) :: value
    end function
    subroutine ft_free(pointer) bind(c, name='ft_free')
      import :: c_ptr
      type(c_ptr), value :: pointer
    end subroutine
  end interface

contains

  subroutine make_c_text(text, value)
    character(*), intent(in) :: text
    character(kind=c_char), allocatable, intent(out) :: value(:)
    integer :: index
    allocate(value(len_trim(text) + 1))
    do index = 1, len_trim(text)
      value(index) = text(index:index)
    end do
    value(size(value)) = c_null_char
  end subroutine

  function pointer_text(pointer, length) result(value)
    type(c_ptr), intent(in) :: pointer
    integer(c_size_t), intent(in) :: length
    character(:), allocatable :: value
    character(kind=c_char), pointer :: bytes(:)
    integer :: index, bounded
    bounded = int(min(length, int(2 * 1024 * 1024, c_size_t)))
    allocate(character(bounded) :: value)
    if (bounded > 0) then
      call c_f_pointer(pointer, bytes, [bounded])
      do index = 1, bounded
        value(index:index) = bytes(index)
      end do
    end if
  end function

  function error_text(pointer) result(value)
    type(c_ptr), intent(in) :: pointer
    character(:), allocatable :: value
    character(kind=c_char), pointer :: bytes(:)
    integer :: length, index
    if (.not. c_associated(pointer)) then
      value = ''
      return
    end if
    call c_f_pointer(pointer, bytes, [4096])
    length = 0
    do while (length < 4096)
      if (bytes(length + 1) == c_null_char) exit
      length = length + 1
    end do
    allocate(character(length) :: value)
    do index = 1, length
      value(index:index) = bytes(index)
    end do
  end function

  function stream_open(address, error) result(stream)
    character(*), intent(in) :: address
    character(:), allocatable, intent(out) :: error
    type(c_ptr) :: stream, pointer
    character(kind=c_char), allocatable :: encoded(:)
    call make_c_text(address, encoded)
    stream = ft_stream_open(encoded, pointer)
    error = error_text(pointer)
    if (c_associated(pointer)) call ft_free(pointer)
  end function

  subroutine stream_read_line(stream, line, status, error)
    type(c_ptr), intent(in) :: stream
    character(:), allocatable, intent(out) :: line, error
    integer, intent(out) :: status
    type(c_ptr) :: pointer, failure
    integer(c_size_t) :: length
    status = int(ft_stream_readline(stream, pointer, length, int(2 * 1024 * 1024, c_size_t), failure))
    error = error_text(failure)
    if (c_associated(failure)) call ft_free(failure)
    if (status == 1) then
      line = pointer_text(pointer, length)
      if (c_associated(pointer)) call ft_free(pointer)
    else
      line = ''
    end if
  end subroutine

  logical function stream_write_line(stream, line)
    type(c_ptr), intent(in) :: stream
    character(*), intent(in) :: line
    character(kind=c_char), allocatable :: encoded(:)
    type(c_ptr) :: failure
    call make_c_text(line // new_line('a'), encoded)
    stream_write_line = ft_stream_write(stream, encoded, int(len(line) + 1, c_size_t), 500_c_int, failure) /= 0
    if (c_associated(failure)) call ft_free(failure)
  end function

  subroutine stream_close(stream)
    type(c_ptr), intent(inout) :: stream
    if (c_associated(stream)) call ft_stream_close(stream)
    stream = c_null_ptr
  end subroutine

  function mutex_new() result(handle)
    type(c_ptr) :: handle
    handle = ft_mutex_new()
  end function
  subroutine mutex_lock(handle)
    type(c_ptr), intent(in) :: handle
    call ft_mutex_lock(handle)
  end subroutine
  subroutine mutex_unlock(handle)
    type(c_ptr), intent(in) :: handle
    call ft_mutex_unlock(handle)
  end subroutine
  subroutine mutex_free(handle)
    type(c_ptr), intent(inout) :: handle
    if (c_associated(handle)) call ft_mutex_free(handle)
    handle = c_null_ptr
  end subroutine
  function condition_new() result(handle)
    type(c_ptr) :: handle
    handle = ft_cond_new()
  end function
  integer function condition_wait(condition, mutex, milliseconds)
    type(c_ptr), intent(in) :: condition, mutex
    integer, intent(in) :: milliseconds
    condition_wait = int(ft_cond_wait(condition, mutex, int(milliseconds, c_int)))
  end function
  subroutine condition_broadcast(condition)
    type(c_ptr), intent(in) :: condition
    call ft_cond_broadcast(condition)
  end subroutine
  subroutine condition_free(condition)
    type(c_ptr), intent(inout) :: condition
    if (c_associated(condition)) call ft_cond_free(condition)
    condition = c_null_ptr
  end subroutine
  function thread_start(function) result(handle)
    type(c_funptr), intent(in) :: function
    type(c_ptr) :: handle
    handle = ft_thread_start(function, c_null_ptr)
  end function
  subroutine thread_join(handle)
    type(c_ptr), intent(inout) :: handle
    if (c_associated(handle)) call ft_thread_join(handle)
    handle = c_null_ptr
  end subroutine
  logical function thread_join_bounded(handle, milliseconds)
    type(c_ptr), intent(inout) :: handle
    integer, intent(in) :: milliseconds
    if (.not. c_associated(handle)) then
      thread_join_bounded = .true.
      return
    end if
    thread_join_bounded = ft_thread_join_bounded(handle, int(milliseconds, c_int)) /= 0
    if (thread_join_bounded) handle = c_null_ptr
  end function
  integer(c_int64_t) function monotonic_ms()
    monotonic_ms = ft_monotonic_ms()
  end function

end module adapter_transport
