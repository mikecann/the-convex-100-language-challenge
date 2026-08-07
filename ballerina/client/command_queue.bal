import ballerina/lang.runtime;
import ballerina/time;

// The single command channel between caller strands (whatever calls
// `Client.subscribe`, `Subscription.close`, `Client.close`, or the adapter's
// `debugDisconnect`) and the one Live owner strand that exclusively reads and
// writes the WebSocket. AGENTS.md requires that exclusivity directly: every
// state change is a command pushed here, never a direct call into the
// owner's own connection state.
//
// Ballerina's isolation checker only allows a value to cross a `lock`
// boundary when it is either `readonly` or a bare reference to an `isolated
// object` - never a plain (non-readonly) record that merely happens to hold
// an isolated-object field, because the record's own field slot is itself an
// unprotected, aliasable location. `Mailbox` and `Reply` objects therefore
// travel as bare fields of small `isolated class` command types rather than
// as fields inside plain records.

public const string CMD_REMOVE = "remove";
public const string CMD_DEBUG_DISCONNECT = "debugDisconnect";
public const string CMD_CLOSE = "close";

public type SimpleKind CMD_REMOVE|CMD_DEBUG_DISCONNECT|CMD_CLOSE;

# A one-shot result slot for `Add`. Split into three independently-isolated
# fields (never one composite record) for the same reason `Command` is a
# class rather than a record: `Mailbox` cannot be made `readonly`.
public isolated class SubscribeReply {
    private boolean done = false;
    private int assignedId = 0;
    private Mailbox? assignedMailbox = ();
    private ConvexError? failure = ();

    isolated function succeed(int id, Mailbox mailbox) {
        lock {
            self.done = true;
            self.assignedId = id;
            self.assignedMailbox = mailbox;
        }
    }

    isolated function reject(ConvexError err) {
        lock {
            self.done = true;
            self.failure = err;
        }
    }

    public isolated function awaitOutcome(decimal timeoutSeconds) returns SubscribeOutcome|ConvexError {
        decimal deadline = time:monotonicNow() + timeoutSeconds;
        while true {
            boolean isDone = false;
            ConvexError? failureOut = ();
            int idOut = 0;
            Mailbox? mailboxOut = ();
            lock {
                isDone = self.done;
                failureOut = self.failure;
                idOut = self.assignedId;
                mailboxOut = self.assignedMailbox;
            }
            if isDone {
                if failureOut is ConvexError {
                    return failureOut;
                }
                if mailboxOut is Mailbox {
                    return {id: idOut, mailbox: mailboxOut};
                }
                return error TransportError("subscribe completed without a mailbox", logs = []);
            }
            if time:monotonicNow() >= deadline {
                return error TransportError("live owner did not respond within " + timeoutSeconds.toString() + " seconds", logs = []);
            }
            runtime:sleep(0.002);
        }
    }
}

# The outcome of a successful `Add`: the assigned query ID and the mailbox
# the owner will publish updates to. Only ever constructed *outside* a lock,
# from values already extracted one at a time - see `SubscribeReply.awaitOutcome`.
public type SubscribeOutcome record {|
    int id;
    Mailbox mailbox;
|};

# A one-shot result slot for `Remove`, `debugDisconnect`, and `Close`, which
# only ever need to report success or a `ConvexError`.
public isolated class UnitReply {
    private boolean done = false;
    private ConvexError? failure = ();

    isolated function succeed() {
        lock {
            self.done = true;
        }
    }

    isolated function reject(ConvexError err) {
        lock {
            self.done = true;
            self.failure = err;
        }
    }

    public isolated function awaitOutcome(decimal timeoutSeconds) returns ConvexError? {
        decimal deadline = time:monotonicNow() + timeoutSeconds;
        while true {
            boolean isDone = false;
            ConvexError? failureOut = ();
            lock {
                isDone = self.done;
                failureOut = self.failure;
            }
            if isDone {
                return failureOut;
            }
            if time:monotonicNow() >= deadline {
                return error TransportError("live owner did not respond within " + timeoutSeconds.toString() + " seconds", logs = []);
            }
            runtime:sleep(0.002);
        }
    }
}

public isolated class AddCommand {
    final string path;
    final json & readonly args;
    final SubscribeReply reply;

    isolated function init(string path, json & readonly args, SubscribeReply reply) {
        self.path = path;
        self.args = args;
        self.reply = reply;
    }
}

public isolated class SimpleCommand {
    final SimpleKind kind;
    final int removeId;
    final UnitReply reply;

    isolated function init(SimpleKind kind, int removeId, UnitReply reply) {
        self.kind = kind;
        self.removeId = removeId;
        self.reply = reply;
    }
}

public type Command AddCommand|SimpleCommand;

public isolated class CommandQueue {
    private Command[] queue = [];

    isolated function push(Command command) {
        lock {
            self.queue.push(command);
        }
    }

    // Non-blocking: the owner loop calls this once per tick rather than
    // sleeping on it, so it can also service the socket in the same tick.
    isolated function tryPop() returns Command? {
        lock {
            if self.queue.length() == 0 {
                return ();
            }
            return self.queue.shift();
        }
    }
}
