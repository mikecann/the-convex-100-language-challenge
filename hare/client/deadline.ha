// A small absolute-deadline helper shared by the TLS, HTTP, and WebSocket
// layers. Every network operation in this client is bounded by one absolute
// deadline covering the whole operation (a name lookup plus a handshake, or
// a whole frame read) rather than a per-syscall timeout that a trickling
// peer could keep resetting forever.
use time;

export type deadline = struct {
	at: time::instant,
};

export fn deadline_in(ms: u64) deadline = deadline {
	at = time::add(time::now(time::clock::MONOTONIC), (ms: i64) * time::MILLISECOND),
};

// Nanoseconds remaining, clamped to zero once the deadline has passed.
export fn remaining_ns(d: *deadline) i64 = {
	const r = time::diff(time::now(time::clock::MONOTONIC), d.at);
	return if (r < 0) 0 else r;
};

export fn expired(d: *deadline) bool = remaining_ns(d) == 0;
