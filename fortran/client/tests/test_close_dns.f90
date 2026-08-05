program test_close_dns
  use, intrinsic :: iso_c_binding, only: c_int, c_int64_t
  use convex_fortran
  implicit none

  interface
    function ft_test_resolver_started() bind(c, name='ft_test_resolver_started') result(started)
      import :: c_int
      integer(c_int) :: started
    end function ft_test_resolver_started

    function ft_test_thread_count() bind(c, name='ft_test_thread_count') result(count)
      import :: c_int
      integer(c_int) :: count
    end function ft_test_thread_count

    subroutine ft_test_sleep_ms(milliseconds) bind(c, name='ft_test_sleep_ms')
      import :: c_int
      integer(c_int), value :: milliseconds
    end subroutine ft_test_sleep_ms

    function ft_monotonic_ms() bind(c, name='ft_monotonic_ms') result(value)
      import :: c_int64_t
      integer(c_int64_t) :: value
    end function ft_monotonic_ms
  end interface

  integer :: attempt, baseline_threads
  integer(c_int64_t) :: started, elapsed

  baseline_threads = ft_test_thread_count()
  if (baseline_threads < 1) error stop 'could not inspect resolver thread ownership'
  call convex_test_live_dns_stall_begin()
  do attempt = 1, 100
    if (ft_test_resolver_started() /= 0) exit
    call ft_test_sleep_ms(10_c_int)
  end do
  if (ft_test_resolver_started() == 0) error stop 'Live owner did not enter the stalled resolver'

  started = ft_monotonic_ms()
  call convex_live_close()
  elapsed = ft_monotonic_ms() - started
  if (elapsed < 9000_c_int64_t .or. elapsed > 11800_c_int64_t) &
    error stop 'full-client close did not honor the bounded DNS deadline'
  if (ft_test_thread_count() /= baseline_threads) &
    error stop 'DNS timeout left detached resolver work behind'

  write (*, '(A)') 'PASS full-client close bounds a hostile DNS resolver'
end program test_close_dns
