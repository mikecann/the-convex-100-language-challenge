package Convex::Subscription;
use strict;
use warnings;
use threads;
use Thread::Queue;
use IO::Select;
use Time::HiRes qw(time);
use Convex::Errors;

# Each subscription owns a bounded newest-16 mailbox. It deliberately drops
# the oldest value so a slow reader eventually catches up with reactive state.
sub new { bless { manager => $_[1], id => $_[2], queue => Thread::Queue->new, closed => 0 }, $_[0] }
sub next_update {
  my ($self, $timeout) = @_; my $item = defined $timeout ? $self->{queue}->dequeue_timed(time + $timeout) : $self->{queue}->dequeue;
  die Convex::Errors::transport_error('timed out waiting for Live update', 'live') unless defined $item;
  die Convex::Errors::closed_error('Live subscription is closed') if $item->{closed}; return $item;
}
sub deliver { my ($self, $update) = @_; return if $self->{closed}; $self->{queue}->dequeue_nb while $self->{queue}->pending >= 16; $self->{queue}->enqueue($update); }
sub finish { my ($self) = @_; return if $self->{closed}++; $self->{queue}->dequeue_nb while $self->{queue}->pending; $self->{queue}->enqueue({ closed => 1 }); }
sub close { my ($self) = @_; return if $self->{closed}; $self->{manager}->request('unsubscribe', { query_id => $self->{id} }); }

package Convex::Live;
use strict;
use warnings;
use Thread::Queue;
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(time sleep);
use URI;
use Convex::WebSocket;
use Convex::Errors;

sub new {
  my ($class, $deployment_url, $client_version) = @_;
  my $uri = URI->new($deployment_url); $uri->scheme($uri->scheme eq 'https' ? 'wss' : 'ws'); $uri->path(($uri->path || '') . '/api/sync'); $uri->query(undef); $uri->fragment(undef);
  my $self = bless { url => $uri->as_string, client_version => $client_version, commands => Thread::Queue->new, next_id => 0, stopped => 0 }, $class;
  $self->{worker} = threads->create(sub { $self->_run }); return $self;
}
sub request {
  my ($self, $type, $data) = @_; die Convex::Errors::closed_error('Convex Live manager is closed') if $self->{stopped}; my $reply = Thread::Queue->new;
  $self->{commands}->enqueue({ type => $type, data => $data || {}, reply => $reply }); my $out = $reply->dequeue; die $out->{error} if $out->{error}; return $out->{value};
}
sub subscribe { $_[0]->request('subscribe', { path => $_[1], args => $_[2] }) }
sub debug_disconnect { $_[0]->request('debug_disconnect') }
sub close { my ($self) = @_; return if $self->{stopped}++; eval { $self->request('close') }; $self->{worker}->join if $self->{worker} && !$self->{worker}->is_joinable; }

sub _run {
  my ($self) = @_; my (%subs, %results); my ($socket, $query_version, $remote, $connections, $reason, $max_ts, $backoff, $retry_at) = (undef, 0, _zero(), 0, 'InitialConnect', undef, 0.1, 0);
  my $closed = 0;
  while (!$closed) {
    # The worker alone changes socket or query-set state. Callers only enqueue commands.
    while (my $command = $self->{commands}->dequeue_nb) {
      my ($type, $data, $reply) = @{$command}{qw(type data reply)};
      eval {
        if ($type eq 'subscribe') {
          my $id = $self->{next_id}++; my $sub = Convex::Subscription->new($self, $id); $subs{$id} = { %$data, subscription => $sub };
          $reply->enqueue({ value => $sub });
          _modify($socket, \$query_version, [_add($id, $subs{$id})]) if $socket; $retry_at = time unless $socket;
        } elsif ($type eq 'unsubscribe') {
          my $state = delete $subs{$data->{query_id}}; delete $results{$data->{query_id}};
          if ($state) { $state->{subscription}->finish; _modify($socket, \$query_version, [{ type => 'Remove', queryId => $data->{query_id} }]) if $socket; }
          $reply->enqueue({ value => undef });
        } elsif ($type eq 'debug_disconnect') {
          die Convex::Errors::transport_error('Live WebSocket is not connected', 'live') unless $socket;
          $socket->close_now; $socket = undef; ++$connections; $reason = 'DebugDisconnect'; $retry_at = time; $reply->enqueue({ value => undef });
        } elsif ($type eq 'close') {
          $closed = 1; $socket->close_now if $socket; $reply->enqueue({ value => undef });
        } else { die Convex::Errors::protocol_error("unknown Live command $type"); }
        1;
      } or do { $reply->enqueue({ error => $@ }); };
    }
    last if $closed;
    if (!$socket && %subs && time >= $retry_at) {
      eval {
        $socket = Convex::WebSocket->connect($self->{url}, $self->{client_version}); $query_version = 0; $remote = _zero(); %results = ();
        my $connect = { type => 'Connect', sessionId => _uuid(), connectionCount => $connections, lastCloseReason => $reason, clientTs => 0 }; $connect->{maxObservedTimestamp} = $max_ts if defined $max_ts;
        $socket->write_json($connect); _modify($socket, \$query_version, [ map { _add($_, $subs{$_}) } sort { $a <=> $b } keys %subs ]) if %subs;
        $backoff = 0.1; 1;
      } or do { $reason = "$@"; ++$connections; $retry_at = time + $backoff; $backoff = $backoff * 2 > 15 ? 15 : $backoff * 2; $socket = undef; };
    }
    if ($socket) {
      my $ready = IO::Select->new($socket->io)->can_read(0.05);
      if (@$ready || $socket->pending) {
        eval {
          my $raw = $socket->read_message; die Convex::Errors::transport_error('server closed', 'live') unless defined $raw;
          my $message = decode_json($raw); $backoff = 0.1;
          if (($message->{type} || '') eq 'Transition') {
            die Convex::Errors::protocol_error('Transition version mismatch') unless encode_json($message->{startVersion}) eq encode_json($remote);
            my %changed;
            for my $m (@{$message->{modifications} || []}) {
              my $id = $m->{queryId};
              if ($m->{type} eq 'QueryUpdated') { $changed{$id} = { value => $m->{value}, logs => $m->{logLines} || [] }; $results{$id} = $changed{$id}; }
              elsif ($m->{type} eq 'QueryFailed') { $changed{$id} = { error => Convex::Errors::function_error($m->{errorMessage} || 'query failed', $m->{errorData}, $m->{logLines} || []) }; $results{$id} = $changed{$id}; }
              elsif ($m->{type} eq 'QueryRemoved') { delete $results{$id}; }
              else { die Convex::Errors::protocol_error('unknown Transition modification'); }
            }
            $remote = $message->{endVersion}; $max_ts = $remote->{ts};
            # Commit the complete transition, then relay only still-current subscriptions.
            for my $id (sort { $a <=> $b } keys %changed) {
              $subs{$id}{subscription}->deliver($changed{$id}) if $subs{$id};
            }
          } elsif (($message->{type} || '') =~ /^(Ping|MutationResponse|ActionResponse)$/) { }
          else { die Convex::Errors::protocol_error('unknown Live message'); }
          1;
        } or do { my $error = $@; $_->{subscription}->deliver({ error => $error }) for values %subs; $socket->close_now; $socket = undef; ++$connections; $reason = "$error"; $retry_at = time + $backoff; $backoff = $backoff * 2 > 15 ? 15 : $backoff * 2; };
      }
    } else { sleep 0.02; }
  }
  $_->{subscription}->finish for values %subs;
}
sub _modify { my ($socket, $version, $mods) = @_; return unless @$mods; $socket->write_json({ type => 'ModifyQuerySet', baseVersion => $$version, newVersion => $$version + 1, modifications => $mods }); ++$$version; }
sub _add { my ($id, $state) = @_; return { type => 'Add', queryId => 0 + $id, udfPath => $state->{path}, args => [ $state->{args} ] }; }
sub _zero { { querySet => 0, identity => 0, ts => 'AAAAAAAAAAA=' } }
sub _uuid { sprintf('%08x-%04x-%04x-%04x-%012x', rand(2**32), rand(2**16), rand(2**16), rand(2**16), rand(2**48)); }
1;
