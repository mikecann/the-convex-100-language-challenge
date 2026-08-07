#!/usr/local/bin/tclsh
# TLS transport policy for HTTPS and WSS. Chain verification alone is not
# enough: a certificate that a trusted authority issued for another host must
# also be refused. The identity rules are exercised directly, and then three
# real handshakes against a loopback TLS peer prove the policy end to end.
source [file normalize [file join [file dirname [info script]] .. convex.tcl]]

proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}

# The registered HTTPS transport and the Live socket must ask TclTLS for the
# same verified connection. Capture the exact arguments without a network.
rename ::tls::socket ::tls::socket_real
proc ::tls::socket {args} { set ::tlsSocketArgs $args; return tls-fixture }

proc socket_option {name} {
    set index [lsearch -exact $::tlsSocketArgs $name]
    if {$index < 0} { return "" }
    return [lindex $::tlsSocketArgs [expr {$index + 1}]]
}

set httpsChannel [::convex::tls_socket example.test 443]
assert {$httpsChannel eq "tls-fixture"} "HTTPS socket factory did not delegate to TclTLS"
assert {[socket_option -require] == 1} "HTTPS socket did not require certificate validation"
assert {[socket_option -cafile] eq $::convex::tlsCaFile} "HTTPS socket did not use the runtime CA bundle"
assert {[socket_option -command] eq {::convex::tls_callback}} "HTTPS socket did not install the identity check"
assert {[socket_option -servername] eq "example.test"} "HTTPS socket did not send SNI"
assert {[socket_option -ssl3] == 0 && [socket_option -tls1] == 0 && [socket_option -tls1.1] == 0} \
    "HTTPS socket did not refuse the obsolete TLS versions"
assert {[lrange $::tlsSocketArgs end-1 end] eq {example.test 443}} "HTTPS socket lost its host and port tail"
assert {$::convex::tlsExpectedHost(tls-fixture) eq "example.test"} "HTTPS socket recorded no expected identity"

# SNI is a host name extension, so an address literal must not carry one.
::convex::tls_connect 127.0.0.1 8443
assert {[lsearch -exact $::tlsSocketArgs -servername] < 0} "an address literal was sent as SNI"

# Live connects asynchronously, and its leading options must survive.
::convex::tls_connect example.test 443 -async
assert {[lindex $::tlsSocketArgs 0] eq "-async"} "the Live TLS connect lost its async option"
rename ::tls::socket {}
rename ::tls::socket_real ::tls::socket
unset ::convex::tlsExpectedHost(tls-fixture)

# TclTLS builds differ in how they spell subject alternative names, so every
# documented spelling is read, and a certificate that names nothing this client
# can check must produce an empty identity list rather than an accepted peer.
set sanCertificate {subject {CN=api.example.com, O=Convex} alternate_names {DNS:api.example.com DNS:*.example.com}}
assert {[::convex::certificate_identities $sanCertificate] eq {{dns api.example.com} {dns *.example.com} {dns api.example.com}}} \
    "alternate_names were not read as identities"
set slashCertificate {subject {/CN=api.example.com/O=Convex} subjectAltName {DNS:api.example.com, IP Address:127.0.0.1}}
assert {[::convex::certificate_identities $slashCertificate] eq {{dns api.example.com} {ip 127.0.0.1} {dns api.example.com}}} \
    "a printed subjectAltName was not read as identities"
set extensionCertificate {subject {CN=api.example.com} extensions {basicConstraints CA:FALSE subjectAltName DNS:api.example.com}}
assert {[::convex::certificate_identities $extensionCertificate] eq {{dns api.example.com} {dns api.example.com}}} \
    "an extension block contributed unlabelled text as an identity"
assert {[::convex::certificate_identities {issuer {CN=Convex fixture CA}}] eq {}} \
    "a certificate with no usable name still produced an identity"

foreach {identity host expected} {
    {dns api.example.com}  api.example.com    1
    {dns API.Example.COM}  api.example.com    1
    {dns *.example.com}    api.example.com    1
    {dns *.example.com}    a.b.example.com    0
    {dns *.example.com}    example.com        0
    {dns *.com}            example.com        0
    {dns evil.example.com} api.example.com    0
    {dns example.com}      api.example.com    0
    {ip 127.0.0.1}         127.0.0.1          1
    {ip 127.0.0.2}         127.0.0.1          0
    {dns 127.0.0.1}        127.0.0.1          1
    {dns *.0.0.1}          127.0.0.1          0
    {dns {}}               api.example.com    0
} {
    set actual [::convex::identity_matches $identity $host]
    assert {$actual == $expected} "identity [list $identity] against $host returned $actual"
}
assert {![::convex::verify_hostname {} api.example.com]} "an empty identity list verified a host"

# The verify callback is the only thing standing between an accepted handshake
# and a rejected one, so exercise each of its refusals directly.
set ::convex::tlsExpectedHost(verify-fixture) api.example.com
assert {[::convex::tls_callback verify verify-fixture 0 {subject {CN=api.example.com}} 1 ""] == 1} \
    "a matching certificate was refused"
assert {[::convex::tls_callback verify verify-fixture 1 {subject {CN=Convex fixture CA}} 1 ""] == 1} \
    "an issuer above the leaf was checked as if it named the host"
assert {[::convex::tls_callback verify verify-fixture 0 {subject {CN=other.example.com}} 1 ""] == 0} \
    "a trusted certificate for another host was accepted"
assert {[::convex::tls_callback verify verify-fixture 0 {subject {CN=api.example.com}} 0 "self signed certificate"] == 0} \
    "an untrusted chain was accepted"
assert {[::convex::tls_callback verify unrecorded-fixture 0 {subject {CN=api.example.com}} 1 ""] == 0} \
    "a channel with no recorded identity was accepted"
assert {[::convex::tls_callback verify verify-fixture 0 not-a-certificate-dict 1 ""] == 0} \
    "an unexpected TclTLS callback shape was accepted"
assert {[::convex::tls_callback info verify-fixture "handshake started"] == 1} \
    "a non-verify callback event was treated as a refusal"
unset ::convex::tlsExpectedHost(verify-fixture)

# Real handshakes. The fixture certificates are generated inside the Docker test
# stage, so this test never carries key material in the repository.
if {![info exists ::env(CONVEX_TLS_FIXTURE_DIR)] || $::env(CONVEX_TLS_FIXTURE_DIR) eq ""} {
    error "CONVEX_TLS_FIXTURE_DIR is required: the TLS fixture certificates are built in Docker"
}
set fixtureDir $::env(CONVEX_TLS_FIXTURE_DIR)
set fixtureScript [file normalize [file join [file dirname [info script]] tls_fixture.tcl]]
set tclshCommand [auto_execok tclsh]

proc start_tls_peer {certificate key connections} {
    global tclshCommand fixtureScript
    set pipe [open [list | $tclshCommand $fixtureScript $certificate $key $connections] r]
    fconfigure $pipe -blocking 1 -buffering line -translation auto
    if {[gets $pipe line] < 0 || ![regexp {^PORT ([0-9]+)$} $line -> port]} {
        catch {close $pipe}
        error "TLS fixture did not report a port: $line"
    }
    return [list $pipe $port]
}

# The client verifies against the fixture authority for these three cases, which
# also proves the CA bundle it uses is the configured one.
set savedCaFile $::convex::tlsCaFile
set ::convex::tlsCaFile [file join $fixtureDir ca.crt]

lassign [start_tls_peer [file join $fixtureDir server.crt] [file join $fixtureDir server.key] 1] trustedPipe trustedPort
set ::convex::tlsLastRejection ""
set trusted [::convex::tls_connect 127.0.0.1 $trustedPort]
fconfigure $trusted -blocking 1 -translation auto
::tls::handshake $trusted
assert {[gets $trusted] eq "convex-tls-fixture"} "the verified TLS peer did not deliver its greeting"
assert {$::convex::tlsLastRejection eq ""} "a valid certificate was refused: $::convex::tlsLastRejection"
catch {close $trusted}
catch {close $trustedPipe}

# Signed by the same authority, issued for a different host. The chain is fine,
# so only the identity check can stop this one.
lassign [start_tls_peer [file join $fixtureDir mismatch.crt] [file join $fixtureDir mismatch.key] 1] mismatchPipe mismatchPort
set ::convex::tlsLastRejection ""
set mismatch [::convex::tls_connect 127.0.0.1 $mismatchPort]
fconfigure $mismatch -blocking 1 -translation auto
set mismatchGreeting ""
if {![catch {::tls::handshake $mismatch}]} { catch {set mismatchGreeting [gets $mismatch]} }
assert {$mismatchGreeting ne "convex-tls-fixture"} "a certificate issued for another host completed a session"
assert {[string match {*do not match 127.0.0.1*} $::convex::tlsLastRejection]} \
    "the mismatched certificate was not refused by the identity check: $::convex::tlsLastRejection"
catch {close $mismatch}
catch {close $mismatchPipe}

# Correct host name, but signed by nobody the client trusts.
lassign [start_tls_peer [file join $fixtureDir untrusted.crt] [file join $fixtureDir untrusted.key] 1] untrustedPipe untrustedPort
set ::convex::tlsLastRejection ""
set untrusted [::convex::tls_connect 127.0.0.1 $untrustedPort]
fconfigure $untrusted -blocking 1 -translation auto
set untrustedGreeting ""
if {![catch {::tls::handshake $untrusted}]} { catch {set untrustedGreeting [gets $untrusted]} }
assert {$untrustedGreeting ne "convex-tls-fixture"} "an untrusted certificate completed a session"
assert {[string match {*chain rejected*} $::convex::tlsLastRejection]} \
    "the untrusted certificate was not refused by chain verification: $::convex::tlsLastRejection"
catch {close $untrusted}
catch {close $untrustedPipe}

set ::convex::tlsCaFile $savedCaFile
puts "Tcl TLS chain and hostname verification tests passed"
