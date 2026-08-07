import ballerina/lang.runtime;
import ballerina/time;

// A bounded, drop-oldest delivery queue for one Live subscription.
//
// The Live owner strand is the only writer; the adapter's relay strand (or a
// test) is the only reader. Both cross a strand boundary, so this state lives
// behind a `lock` rather than as a plain field, matching AGENTS.md's
// requirement to "bound it and test its overflow behaviour" for any
// client-owned update queue.
public const int MAILBOX_CAPACITY = 16;

public isolated class Mailbox {
    private Update[] updates = [];
    private boolean closed = false;

    // Appends an update, dropping the oldest queued one first if already at
    // capacity. A slow consumer therefore always sees the newest state rather
    // than growing without bound.
    isolated function push(Update update) {
        lock {
            if self.closed {
                return;
            }
            if self.updates.length() >= MAILBOX_CAPACITY {
                Update droppedForCapacity = self.updates.shift();
            }
            self.updates.push(update.cloneReadOnly());
        }
    }

    isolated function close() {
        lock {
            self.closed = true;
        }
    }

    // Blocks (by short polling) until an update is queued, the mailbox is
    // closed with nothing left to deliver, or `timeoutSeconds` elapses.
    public isolated function recvTimeout(decimal timeoutSeconds) returns Update|ClosedError|TransportError {
        decimal deadline = time:monotonicNow() + timeoutSeconds;
        while true {
            lock {
                if self.updates.length() > 0 {
                    Update next = self.updates.shift();
                    return next.cloneReadOnly();
                }
                if self.closed {
                    return error ClosedError("convex client is closed", logs = []);
                }
            }
            if time:monotonicNow() >= deadline {
                return error TransportError("mailbox did not deliver an update within " + timeoutSeconds.toString() + " seconds", logs = []);
            }
            runtime:sleep(0.005);
        }
    }
}
