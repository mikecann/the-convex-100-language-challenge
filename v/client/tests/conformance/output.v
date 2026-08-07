module conformance

import net
import sync
import time

// One writer owns the terminal output stream. Every event is encoded and
// charged before it is queued, and the charge is held while a write is in
// flight, so a controller that stops reading cannot hide memory in a blocked
// write. An event count alone is not a memory bound when one subscription
// value may approach the Live message limit.
pub const max_output_items = 16
pub const max_output_bytes = 6 * 1024 * 1024
pub const output_publish_budget = 2 * time.second
pub const output_drain_budget = 5 * time.second
pub const output_write_budget = 1 * time.second

const output_poll_slice = 2 * time.millisecond

struct OutputItem {
	text      string
	size      int
	droppable bool
}

// OutputTarget is the terminal stream. Both adapter modes carry the identical
// NDJSON protocol; only this object differs between them.
interface OutputTarget {
mut:
	emit(text string) !
	finish()
}

struct StdoutTarget {}

fn (mut target StdoutTarget) emit(text string) ! {
	print(text)
	flush_stdout()
}

fn (mut target StdoutTarget) finish() {
	flush_stdout()
}

struct TcpTarget {
mut:
	conn &net.TcpConn = unsafe { nil }
}

fn (mut target TcpTarget) emit(text string) ! {
	// TcpConn.write_string loops until the whole line is sent. Its timeout is
	// relative, so narrow it for every event and verify the reported byte count
	// before the sink releases the in-flight reservation.
	target.conn.set_write_timeout(output_write_budget)
	target.conn.set_write_deadline(time.now().add(output_write_budget))
	written := target.conn.write_string(text)!
	if written != text.len {
		return error('terminal writer accepted ${written} of ${text.len} bytes')
	}
}

// finish deliberately does not linger. The bounded writer has already drained
// before this point, and a controller that has gone away must not hold the
// adapter open past its own exit.
fn (mut target TcpTarget) finish() {
	target.conn.close() or {}
}

// Mutex-guarded and passed around as `&OutputSink`, so `@[heap]` is required:
// V cannot otherwise prove a pointer parameter it did not itself allocate is
// heap-safe to copy into another struct's field.
@[heap]
pub struct OutputSink {
mut:
	mutex     &sync.Mutex  = unsafe { nil }
	target    OutputTarget = OutputTarget(&StdoutTarget{})
	queue     []OutputItem
	queued    int
	in_flight int
	stopping  bool
	drained   bool
	failed    string
}

pub fn new_output_sink(target OutputTarget) &OutputSink {
	return &OutputSink{
		mutex:  sync.new_mutex()
		target: target
	}
}

fn (mut sink OutputSink) reserved() (int, int) {
	sink.mutex.@lock()
	defer {
		sink.mutex.unlock()
	}
	count := sink.queue.len + if sink.in_flight > 0 { 1 } else { 0 }
	return count, sink.queued + sink.in_flight
}

fn (mut sink OutputSink) drop_one_droppable() bool {
	for index, item in sink.queue {
		if item.droppable {
			sink.queued -= item.size
			sink.queue.delete(index)
			return true
		}
	}
	return false
}

// publish charges an already-encoded event against the sink's reservation. A
// subscription delivery is droppable, because losing one stale value is better
// than exceeding the adapter's memory envelope; a command response is not,
// because the controller is waiting for it.
pub fn (mut sink OutputSink) publish(text string, droppable bool) ! {
	item := OutputItem{
		text:      text
		size:      text.len + 128
		droppable: droppable
	}
	deadline := time.sys_mono_now() + u64(output_publish_budget)
	for {
		sink.mutex.@lock()
		if sink.failed.len > 0 {
			failure := sink.failed
			sink.mutex.unlock()
			return error('adapter output failed: ${failure}')
		}
		if sink.stopping {
			sink.mutex.unlock()
			return error('adapter output is closed')
		}
		count := sink.queue.len + if sink.in_flight > 0 { 1 } else { 0 }
		bytes := sink.queued + sink.in_flight
		if count < max_output_items && bytes + item.size <= max_output_bytes {
			sink.queue << item
			sink.queued += item.size
			sink.mutex.unlock()
			return
		}
		if sink.drop_one_droppable() {
			sink.mutex.unlock()
			continue
		}
		sink.mutex.unlock()
		if time.sys_mono_now() >= deadline {
			sink.mutex.@lock()
			sink.failed = 'terminal writer did not drain within its budget'
			sink.mutex.unlock()
			return error('adapter output is congested')
		}
		time.sleep(output_poll_slice)
	}
}

// writer_loop is the only code that touches the terminal stream, which is what
// keeps NDJSON lines whole and ordered even when several producers publish.
pub fn (mut sink OutputSink) writer_loop() {
	for {
		sink.mutex.@lock()
		if sink.queue.len == 0 {
			stopping := sink.stopping
			sink.mutex.unlock()
			if stopping {
				break
			}
			time.sleep(output_poll_slice)
			continue
		}
		item := sink.queue[0]
		sink.queue.delete(0)
		sink.queued -= item.size
		// The charge moves to in-flight rather than being released, so a write
		// blocked in the kernel still counts against the reservation.
		sink.in_flight = item.size
		sink.mutex.unlock()

		mut failure := ''
		sink.target.emit(item.text) or { failure = err.msg() }

		sink.mutex.@lock()
		sink.in_flight = 0
		if failure.len > 0 {
			sink.failed = failure
			sink.stopping = true
			sink.queued = 0
			sink.queue = []OutputItem{}
			sink.mutex.unlock()
			eprintln('adapter output failed: ${failure}')
			break
		}
		sink.mutex.unlock()
	}
	sink.mutex.@lock()
	sink.drained = true
	sink.mutex.unlock()
}

// close stops accepting events, waits a bounded time for the queue to drain,
// and then retires the stream whether or not the peer kept reading.
pub fn (mut sink OutputSink) close(finish_target bool) {
	sink.mutex.@lock()
	sink.stopping = true
	sink.mutex.unlock()
	deadline := time.sys_mono_now() + u64(output_drain_budget)
	for time.sys_mono_now() < deadline {
		sink.mutex.@lock()
		drained := sink.drained
		sink.mutex.unlock()
		if drained {
			break
		}
		time.sleep(output_poll_slice)
	}
	if finish_target {
		sink.target.finish()
	}
}

fn stdout_target() OutputTarget {
	return OutputTarget(&StdoutTarget{})
}

fn tcp_target(conn &net.TcpConn) OutputTarget {
	return OutputTarget(&TcpTarget{
		conn: conn
	})
}

fn diagnostic(message string) {
	// Diagnostics never share the protocol stream.
	eprintln(message)
	flush_stderr()
}
