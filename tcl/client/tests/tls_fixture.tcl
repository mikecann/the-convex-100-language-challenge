#!/usr/local/bin/tclsh
# Standalone TLS peer for the Tcl client's transport tests. It runs in its own
# process so the test can drive a blocking handshake without deadlocking against
# the event loop that would otherwise have to accept its own connection.
#
# Usage: tls_fixture.tcl <certificate> <key> <connections>
# It prints "PORT <number>" once it is listening, serves exactly <connections>
# connections, and exits. A rejected client aborts the handshake, so a failed
# read here is the expected outcome for the mismatch and untrusted certificates.
package require tls

lassign $argv certificate key connections
if {$certificate eq "" || $key eq "" || $connections eq ""} {
    error "usage: tls_fixture.tcl certificate key connections"
}
set remaining $connections

proc accept {channel host port} {
    global remaining
    catch {
        fconfigure $channel -blocking 1 -translation binary
        ::tls::handshake $channel
        puts -nonewline $channel "convex-tls-fixture\n"
        flush $channel
    }
    catch {close $channel}
    incr remaining -1
    if {$remaining <= 0} { set ::done served }
}

set server [::tls::socket -server accept -certfile $certificate -keyfile $key -require 0 -myaddr 127.0.0.1 0]
puts "PORT [lindex [fconfigure $server -sockname] end]"
flush stdout
# A parent that dies must not leave this process listening forever.
after 30000 { set ::done timeout }
vwait ::done
catch {close $server}
exit 0
