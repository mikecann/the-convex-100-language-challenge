program test_relay_barrier
  use adapter_state
  implicit none

  call prove_barrier(.false., 'unsubscribe')
  call prove_barrier(.true., 'same-ID replacement')
  write (*, '(A)') 'PASS deterministic relay generation acknowledgement barriers'

contains

  subroutine prove_barrier(replacement, name)
    logical, intent(in) :: replacement
    character(*), intent(in) :: name
    logical :: paused

    call adapter_test_begin()
    call adapter_test_install(1)
    call adapter_test_start_relay()
    call adapter_test_wait_paused(paused)
    if (.not. paused) error stop 'relay did not pause after dequeue'

    ! This is the acknowledgement boundary used by unsubscribe and replacement:
    ! invalidate the old generation before allowing the dequeued relay to run.
    call adapter_test_invalidate(replacement)
    call adapter_test_release()
    call adapter_test_join()
    if (adapter_test_event_count() /= 0) error stop name // ' allowed a stale relay across its acknowledgement'
    call adapter_test_finish()
  end subroutine prove_barrier

end program test_relay_barrier
