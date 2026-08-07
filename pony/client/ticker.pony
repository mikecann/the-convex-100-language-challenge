use "time"

// Time is injected for the same reason sockets are.
//
// Reconnect backoff, the bounded close deadline, and the partial-frame
// deadline are all real behaviour that has to be proved, and none of it can be
// proved by a test that sleeps. A test supplies a ticker it fires by hand, so
// "the deadline elapsed" becomes an assertion rather than a stopwatch.

interface tag TickReceiver
  be tick(tick_id: U64)

interface tag Ticker
  """
  Delivers one `tick` to `receiver` after roughly `delay_ms`.

  Cancellation matters for more than tidiness. A Pony program exits when it
  runs out of work, and a pending timer is work, so a deadline that outlives
  the operation it guarded would keep a finished program alive until it fired.
  Every receiver still ignores a tick it no longer recognises, so cancellation
  is an optimisation for shutdown rather than a correctness requirement.
  """
  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64)
  be cancel(receiver: TickReceiver, tick_id: U64)

actor RealTicker
  let _timers: Timers = Timers
  let _pending: Array[(TickReceiver, U64, Timer tag)] =
    Array[(TickReceiver, U64, Timer tag)]

  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64) =>
    let ticker: RealTicker tag = this
    let notify =
      object iso is TimerNotify
        let _ticker: RealTicker tag = ticker
        let _receiver: TickReceiver = receiver
        let _tick_id: U64 = tick_id

        fun ref apply(timer: Timer, count: U64): Bool =>
          _ticker.fired(_receiver, _tick_id)
          _receiver.tick(_tick_id)
          // One shot: returning false removes the timer.
          false
      end
    let timer = Timer(consume notify, delay_ms * 1_000_000)
    // A tag alias is kept so the timer can be cancelled after the `Timers`
    // actor has taken ownership of it.
    let handle: Timer tag = timer
    _timers(consume timer)
    _pending.push((receiver, tick_id, handle))

  be fired(receiver: TickReceiver, tick_id: U64) =>
    _forget(receiver, tick_id)

  be cancel(receiver: TickReceiver, tick_id: U64) =>
    var index: USize = 0
    while index < _pending.size() do
      try
        let entry = _pending(index)?
        // Receivers are compared by identity, so two components sharing one
        // ticker cannot cancel each other's deadlines by reusing a number.
        if (entry._1 is receiver) and (entry._2 == tick_id) then
          _timers.cancel(entry._3)
          _pending.remove(index, 1)
          return
        end
      end
      index = index + 1
    end

  be dispose() =>
    for entry in _pending.values() do
      _timers.cancel(entry._3)
    end
    _pending.clear()

  fun ref _forget(receiver: TickReceiver, tick_id: U64) =>
    var index: USize = 0
    while index < _pending.size() do
      try
        let entry = _pending(index)?
        if (entry._1 is receiver) and (entry._2 == tick_id) then
          _pending.remove(index, 1)
          return
        end
      end
      index = index + 1
    end
