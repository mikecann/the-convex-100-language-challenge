module HTTPTest

// Language-local unit coverage for Convex.HTTP's pure endpoint parser. Run
// by the `test` Docker stage; not part of the public client or the
// conformance adapter. `parseEndpoint` is the only function this module
// exports that takes no transport, so it is the only one a network-free
// unit test can reach; the request/response framing above it (chunked and
// Content-Length bodies, status and header parsing) is exercised instead by
// `./run verify` and `./run verify-hosted` against a real deployment, per
// this project's layered test plan.

import StdEnv
import StdMaybe
import Convex.HTTP

Start :: *World -> *World
Start w
	| not checkHttpsWithPortAndPath = abort "parseEndpoint: https with an explicit port and a trailing-slash path failed"
	| not checkHttpLocalNoPath = abort "parseEndpoint: http host:port with no path failed"
	| not checkDefaultPorts = abort "parseEndpoint: default port inference (443 for https, 80 for http) failed"
	| not checkRootPathTrimsToEmpty = abort "parseEndpoint: a bare trailing slash should trim to an empty base path"
	| not checkInvalidSchemeRejected = abort "parseEndpoint: a non-http(s) scheme should be rejected"
	| not checkMissingSchemeRejected = abort "parseEndpoint: a URL with no \"://\" should be rejected"
	| not checkEmptyHostRejected = abort "parseEndpoint: an empty host should be rejected"
	| not checkNonNumericPortFallsBackToDefault = abort "parseEndpoint: a non-numeric port should fall back to the scheme default rather than error"
	= w

checkHttpsWithPortAndPath :: Bool
checkHttpsWithPortAndPath = case parseEndpoint "https://example.convex.cloud:8443/base/" of
	Just e = e.epTls && e.epHost == "example.convex.cloud" && e.epPort == 8443 && e.epBasePath == "/base"
	Nothing = False

checkHttpLocalNoPath :: Bool
checkHttpLocalNoPath = case parseEndpoint "http://127.0.0.1:3210" of
	Just e = not e.epTls && e.epHost == "127.0.0.1" && e.epPort == 3210 && e.epBasePath == ""
	Nothing = False

checkDefaultPorts :: Bool
checkDefaultPorts = case (parseEndpoint "https://foo.convex.cloud", parseEndpoint "http://foo.convex.cloud") of
	(Just https, Just http) = https.epPort == 443 && http.epPort == 80
	_ = False

checkRootPathTrimsToEmpty :: Bool
checkRootPathTrimsToEmpty = case parseEndpoint "https://example.convex.cloud/" of
	Just e = e.epBasePath == ""
	Nothing = False

checkInvalidSchemeRejected :: Bool
checkInvalidSchemeRejected = case parseEndpoint "ftp://example.com" of
	Nothing = True
	Just _ = False

checkMissingSchemeRejected :: Bool
checkMissingSchemeRejected = case parseEndpoint "example.com/no/scheme" of
	Nothing = True
	Just _ = False

checkEmptyHostRejected :: Bool
checkEmptyHostRejected = case parseEndpoint "https://:443/" of
	Nothing = True
	Just _ = False

// A malformed port should not silently propagate a nonsensical value or
// crash the parser; falling back to the scheme's own default port keeps
// this in line with `Convex.HTTP.hostPortToEndpoint`'s documented use of
// `fromMaybe` here.
checkNonNumericPortFallsBackToDefault :: Bool
checkNonNumericPortFallsBackToDefault = case parseEndpoint "https://example.convex.cloud:abc/" of
	Just e = e.epPort == 443
	Nothing = False
