#!/usr/local/bin/perl
use strict;
use warnings;
use FindBin;
use lib $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../..";
use IO::Socket::INET;
use JSON::PP qw(encode_json decode_json);
use threads;
use threads::shared;
use Thread::Queue;
use Convex;

sub write_event { my ($io, $lock, $event) = @_; lock($$lock); print {$io} encode_json($event) . "\n"; }
sub error_event {
  my ($error) = @_; my $kind = ref($error) || 'TransportError'; my %out = (name => $kind =~ /([^:]+)$/ ? $1 : $kind, message => "$error");
  $out{data} = $error->{data} if ref($error) && exists $error->{data}; return \%out;
}
sub run_adapter {
  my ($input, $output) = @_; my $lock :shared; my ($client, %subscriptions, %threads);
  my $done = 0;
  while (my $line = <$input>) {
    my $command = eval { decode_json($line) }; if ($@) { write_event($output, \$lock, { type => 'error', error => { name => 'ProtocolError', message => "decode command: $@" } }); next; }
    my $id = $command->{id};
    eval {
      if ($command->{op} eq 'hello') { die 'unsupported adapter protocol version' unless $command->{protocolVersion} == 1; write_event($output, \$lock, { protocolVersion => 1, id => $id, type => 'ready', language => 'perl', implementation => "native-perl-$]", runtime => "perl-$]" }); }
      elsif ($command->{op} =~ /^(query|mutation|action)$/) { $client ||= Convex->new($ENV{CONVEX_URL}, bearer_token => $ENV{CONVEX_AUTH_TOKEN}); my $r = $client->$1($command->{path}, $command->{args} || {}); write_event($output, \$lock, { id => $id, type => 'result', value => $r->{value}, logs => $r->{logs} }); }
      elsif ($command->{op} eq 'setAuth') { $client ||= Convex->new($ENV{CONVEX_URL}); $client->set_auth($command->{token}); write_event($output, \$lock, { id => $id, type => 'ack' }); }
      elsif ($command->{op} eq 'subscribe') { $client ||= Convex->new($ENV{CONVEX_URL}); my $sid = $command->{subscriptionId}; $subscriptions{$sid}->close if $subscriptions{$sid}; $subscriptions{$sid} = $client->subscribe($command->{path}, $command->{args} || {}); write_event($output, \$lock, { id => $id, type => 'ack' }); my $sub = $subscriptions{$sid}; $threads{$sid} = threads->create(sub { while (1) { my $u = eval { $sub->next_update }; last if $@ && ref($@) =~ /ClosedError/; if ($@ || $u->{error}) { write_event($output, \$lock, { type => 'subscription', subscriptionId => $sid, error => error_event($@ || $u->{error}) }); } else { write_event($output, \$lock, { type => 'subscription', subscriptionId => $sid, value => $u->{value}, logs => $u->{logs} || [] }); } } }); }
      elsif ($command->{op} eq 'unsubscribe') { my $sid = $command->{subscriptionId}; $subscriptions{$sid}->close if delete $subscriptions{$sid}; $threads{$sid}->join if delete $threads{$sid}; write_event($output, \$lock, { id => $id, type => 'ack' }); }
      elsif ($command->{op} eq 'debugDisconnect') { $client->debug_disconnect_for_adapter; write_event($output, \$lock, { id => $id, type => 'ack' }); }
      elsif ($command->{op} eq 'close') { $_->close for values %subscriptions; $_->join for values %threads; $client->close if $client; write_event($output, \$lock, { id => $id, type => 'closed' }); $done = 1; }
      else { die 'unknown adapter operation'; }
      1;
    } or write_event($output, \$lock, { id => $id, type => 'error', error => error_event($@) });
    last if $done;
  }
}
if ($ENV{ADAPTER_LISTEN}) { my ($host, $port) = split /:/, $ENV{ADAPTER_LISTEN}, 2; my $server = IO::Socket::INET->new(LocalAddr => $host, LocalPort => $port, Listen => 1, ReuseAddr => 1) or die "listen: $!"; my $socket = $server->accept; run_adapter($socket, $socket); } else { run_adapter(*STDIN, *STDOUT); }
