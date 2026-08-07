#!/usr/local/bin/pike
// The test-only conformance adapter: NDJSON protocol v1 over stdin/stdout, or
// over one accepted controller connection when ADAPTER_LISTEN is set.
//
// This is test infrastructure, not public client code. It calls the real Pike
// client for every operation and never fabricates a value. stdout carries
// protocol events only; diagnostics go to stderr.
#include "events.pike"
#include "output.pike"

constant ADAPTER_LANGUAGE = "pike";
// One controller command is small. This bound stops a controller that never
// sends a newline from growing the input buffer without limit.
constant MAX_COMMAND_BYTES = 4 * 1024 * 1024;

// The compiled Convex client program, and the single client instance every
// operation goes through.
object convex;
object client;
mapping(string:object) relays = ([]);
OutputQueue output;
mapping input_state = ([ "buffer": "", "eof": 0 ]);
int finished;

string locate_client()
{
  // The runtime image installs the client at /opt/convex/client; running from
  // a checkout finds it two directories above this file.
  array(string) candidates = ({
    getenv("CONVEX_CLIENT_PATH"),
    "/opt/convex/client",
    combine_path(dirname(__FILE__), "..", ".."),
  });
  foreach (candidates, string directory) {
    if (!directory || !sizeof(directory))
      continue;
    string candidate = combine_path(directory, "convex.pike");
    if (Stdio.is_file(candidate))
      return candidate;
  }
  error("could not locate the Pike Convex client source\n");
  return 0;
}

string implementation_string()
{
  return "native-pike-" + replace(version(), " ", "-");
}

mapping failure_payload(object failure)
{
  return failure_object(failure->kind, failure->message,
                        failure->carries_data, failure->data);
}

void emit_error(string id, mixed thrown)
{
  object failure = convex->as_convex_error(thrown);
  output->enqueue(error_event(id, failure_payload(failure), failure->logs));
}

object ensure_client()
{
  if (client)
    return client;
  string url = getenv("CONVEX_URL");
  if (!url || !sizeof(url))
    throw(convex->transport_error("CONVEX_URL is required", "adapter"));
  client = convex->Client(url, ([
    "auth_token": getenv("CONVEX_AUTH_TOKEN") || "",
  ]));
  return client;
}

// One relay per live subscription id. The identity check in update() is the
// generation barrier: once this relay is no longer the registered one, the
// controller has already been acknowledged for its removal or replacement, and
// nothing from the old query may reach the wire.
class Relay
{
  string subscription_id;
  object subscription;

  protected void create(string id)
  {
    subscription_id = id;
  }

  void attach(object live_subscription)
  {
    subscription = live_subscription;
    subscription->set_callback(update);
  }

  void update(object live_update)
  {
    if (relays[subscription_id] != this)
      return;
    if (live_update->failure) {
      output->enqueue(subscription_error_event(
        subscription_id, failure_payload(live_update->failure),
        live_update->logs));
      return;
    }
    output->enqueue(subscription_value_event(subscription_id,
                                             live_update->value,
                                             live_update->logs));
  }

  void invalidate()
  {
    if (subscription)
      subscription->close();
    subscription = 0;
  }
}

string require_subscription_id(mapping command)
{
  if (!stringp(command->subscriptionId) || !sizeof(command->subscriptionId))
    throw(convex->protocol_error("subscriptionId is required", "adapter"));
  return command->subscriptionId;
}

mapping command_args(mapping command)
{
  if (zero_type(command->args))
    return ([]);
  if (!mappingp(command->args))
    throw(convex->protocol_error("args must be a JSON object", "adapter"));
  return command->args;
}

void shutdown_adapter(string id)
{
  // Invalidate every relay before anything else can yield, so no in-flight
  // subscription event can be published after the close acknowledgement.
  mapping(string:object) closing = relays;
  relays = ([]);
  foreach (values(closing), object relay)
    catch { relay->invalidate(); };
  if (client)
    catch { client->close(); };
  if (id && sizeof(id))
    output->enqueue(closed_event(id));
  finished = 1;
}

void dispatch(string id, string op, mapping command)
{
  if (op == "hello") {
    if (command->protocolVersion != 1)
      throw(convex->protocol_error("unsupported adapter protocol version",
                                   "adapter"));
    output->enqueue(ready_event(id, ADAPTER_LANGUAGE, implementation_string(),
                                version()));
    return;
  }

  if (op == "query" || op == "mutation" || op == "action") {
    object result = ensure_client()->call(op, command->path,
                                          command_args(command));
    output->enqueue(result_event(id, result->value, result->logs));
    return;
  }

  if (op == "setAuth") {
    ensure_client()->set_auth(stringp(command->token) ? command->token : "");
    output->enqueue(ack_event(id));
    return;
  }

  if (op == "subscribe") {
    string subscription_id = require_subscription_id(command);
    object previous = relays[subscription_id];
    // Retire any relay already using this id before the new one exists, so a
    // replaced subscription cannot publish across its own acknowledgement.
    m_delete(relays, subscription_id);
    if (previous)
      previous->invalidate();

    object handle = ensure_client();
    Relay relay = Relay(subscription_id);
    relays[subscription_id] = relay;
    mixed failed = catch {
      relay->attach(handle->subscribe(command->path, command_args(command)));
    };
    if (failed) {
      m_delete(relays, subscription_id);
      throw(failed);
    }
    output->enqueue(ack_event(id));
    return;
  }

  if (op == "unsubscribe") {
    string subscription_id = require_subscription_id(command);
    object relay = relays[subscription_id];
    m_delete(relays, subscription_id);
    if (relay)
      relay->invalidate();
    output->enqueue(ack_event(id));
    return;
  }

  // Adapter-only, declared in manifest.yaml. It exists so the shared
  // controller can prove five real reconnects.
  if (op == "debugDisconnect") {
    ensure_client()->debug_disconnect_for_adapter();
    output->enqueue(ack_event(id));
    return;
  }

  if (op == "close") {
    shutdown_adapter(id);
    return;
  }

  throw(convex->protocol_error("unknown adapter operation " + op, "adapter"));
}

void process_line(string line)
{
  mixed decoded;
  mixed failed = catch {
    decoded = Standards.JSON.decode(utf8_to_string(line));
  };
  if (failed || !mappingp(decoded)) {
    output->enqueue(error_event(
      0, failure_object("ProtocolError",
                        "adapter command must be one JSON object", 0, 0)));
    return;
  }
  mapping command = decoded;
  string id = stringp(command->id) ? command->id : 0;
  string op = stringp(command->op) ? command->op : "";
  mixed problem = catch { dispatch(id, op, command); };
  if (problem)
    emit_error(id, problem);
}

// A direct, single-shot nonblocking read of the input stream, called once
// per loop iteration instead of registering read/close callbacks with the
// event backend. Some descriptors this adapter is asked to read (/dev/null,
// exercised by the end-of-input conformance test below) are always "ready"
// and cannot be registered with an epoll-based backend, so a close callback
// on them would never fire and the adapter would hang forever waiting for
// an event that cannot arrive. read(n, 1) sidesteps the backend entirely: it
// returns a non-empty string for data, an empty string for a genuine EOF,
// and the integer 0 when nothing is available yet. Any read error is folded
// into EOF, matching this adapter's existing "end of input is the same
// lifecycle as an explicit close" contract.
void poll_input(object input)
{
  mixed failed = catch {
    mixed chunk = input->read(65536, 1);
    if (stringp(chunk)) {
      if (sizeof(chunk))
        input_state->buffer += chunk;
      else
        input_state->eof = 1;
    }
  };
  if (failed)
    input_state->eof = 1;
}

int drain_input()
{
  int processed;
  while (!finished) {
    int newline = search(input_state->buffer, "\n");
    if (newline < 0) {
      if (sizeof(input_state->buffer) > MAX_COMMAND_BYTES) {
        output->enqueue(error_event(
          0, failure_object("ProtocolError",
                            "adapter command exceeded its byte budget", 0, 0)));
        finished = 1;
      }
      break;
    }
    string line = input_state->buffer[..newline - 1];
    input_state->buffer = input_state->buffer[newline + 1..];
    if (sizeof(line) && line[-1] == '\r')
      line = line[..sizeof(line) - 2];
    processed = 1;
    if (sizeof(line))
      process_line(line);
  }
  return processed;
}

int run_loop(object input, object out)
{
  output = OutputQueue(out);
  input->set_nonblocking();
  if (out != input)
    out->set_nonblocking();

  while (!finished && !output->failed) {
    poll_input(input);
    int progressed = drain_input();
    if (finished)
      break;
    // Let the Live owner run its reconnect timers and frame deadlines between
    // commands. Failures here are already published to the subscriptions.
    if (client)
      catch { client->poll(); };
    output->flush();
    if (progressed)
      continue;
    if (input_state->eof && search(input_state->buffer, "\n") < 0) {
      // End of input is the same lifecycle as an explicit close, minus the
      // acknowledgement there is no longer anyone to read.
      shutdown_adapter(0);
      break;
    }
    Pike.DefaultBackend(0.02);
  }

  int flushed = output->drain();
  if (output->failed) {
    werror("pike adapter output failed: %s\n", output->failure_message);
    return 1;
  }
  if (!flushed) {
    werror("pike adapter could not flush its output before the deadline\n");
    return 1;
  }
  return 0;
}

int run_tcp(string address)
{
  int separator = -1;
  for (int index = sizeof(address) - 1; index >= 0; index--)
    if (address[index] == ':') {
      separator = index;
      break;
    }
  if (separator < 1) {
    werror("ADAPTER_LISTEN must be host:port\n");
    return 2;
  }
  string host = address[..separator - 1];
  int port_number = (int)address[separator + 1..];
  Stdio.Port listener = Stdio.Port();
  if (!listener->bind(port_number, 0, host)) {
    werror("pike adapter could not bind %s\n", address);
    return 2;
  }
  // Exactly one controller, as the shared harness expects.
  object peer = listener->accept();
  listener->close();
  if (!peer) {
    werror("pike adapter accepted no controller connection\n");
    return 2;
  }
  return run_loop(peer, peer);
}

int main(int argc, array(string) argv)
{
  mixed failed = catch { convex = compile_file(locate_client())(); };
  if (failed) {
    werror("pike adapter could not load its Convex client: %s\n",
           describe_error(failed));
    return 2;
  }

  string listen_address = getenv("ADAPTER_LISTEN");
  if (listen_address && sizeof(listen_address))
    return run_tcp(listen_address);
  return run_loop(Stdio.File("stdin"), Stdio.File("stdout"));
}
