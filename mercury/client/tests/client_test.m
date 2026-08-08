%-----------------------------------------------------------------------------%
% Language-local unit tests for convex.m's pure, network-free logic:
% deployment URL validation and normalisation. The HTTP and Live protocol
% logic that actually needs a socket is exercised by the canonical example
% and the shared conformance suite instead of being mocked here, per
% AGENTS.md's ban on awarding a capability from a mocked test.
%-----------------------------------------------------------------------------%
:- module client_test.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module convex.

:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module pair.
:- import_module string.

main(!IO) :-
    check_accepts_https(N01, P01),
    check_accepts_http(N02, P02),
    check_trims_trailing_slash(N03, P03),
    check_rejects_missing_scheme(N04, P04),
    check_rejects_empty_host(N05, P05),
    check_rejects_empty_url(N06, P06),
    check_set_and_clear_auth(N07, P07),
    Results = [N01 - P01, N02 - P02, N03 - P03, N04 - P04, N05 - P05,
        N06 - P06, N07 - P07],
    report(Results, 0, Failures, !IO),
    ( Failures = 0 ->
        io.write_string("client_test: all checks passed\n", !IO)
    ;
        io.format("client_test: %d check(s) failed\n", [i(Failures)], !IO),
        io.set_exit_status(1, !IO)
    ).

:- pred report(list(pair(string, bool))::in, int::in, int::out,
    io::di, io::uo) is det.

report([], Failures, Failures, !IO).
report([Name - Passed | Rest], Failures0, Failures, !IO) :-
    ( Passed = yes ->
        io.format("  ok   %s\n", [s(Name)], !IO),
        Failures1 = Failures0
    ;
        io.format("  FAIL %s\n", [s(Name)], !IO),
        Failures1 = Failures0 + 1
    ),
    report(Rest, Failures1, Failures, !IO).

:- pred check_accepts_https(string::out, bool::out) is det.

check_accepts_https(Name, Passed) :-
    Name = "an https:// deployment URL is accepted",
    ( new_client("https://usable-reindeer-44.convex.cloud", Url, _) ->
        ( Url = "https://usable-reindeer-44.convex.cloud" -> Passed = yes ; Passed = no )
    ;
        Passed = no
    ).

:- pred check_accepts_http(string::out, bool::out) is det.

check_accepts_http(Name, Passed) :-
    Name = "an http:// deployment URL (self-hosted backend) is accepted",
    ( new_client("http://backend:3210", _, _) -> Passed = yes ; Passed = no ).

:- pred check_trims_trailing_slash(string::out, bool::out) is det.

check_trims_trailing_slash(Name, Passed) :-
    Name = "a trailing slash is trimmed from the deployment URL",
    ( new_client("https://example.convex.cloud/", Url, _) ->
        ( Url = "https://example.convex.cloud" -> Passed = yes ; Passed = no )
    ;
        Passed = no
    ).

:- pred check_rejects_missing_scheme(string::out, bool::out) is det.

check_rejects_missing_scheme(Name, Passed) :-
    Name = "a deployment URL without http(s):// is rejected",
    ( new_client("example.convex.cloud", _, _) -> Passed = no ; Passed = yes ).

:- pred check_rejects_empty_host(string::out, bool::out) is det.

check_rejects_empty_host(Name, Passed) :-
    Name = "a scheme with no host is rejected",
    ( new_client("https://", _, _) -> Passed = no ; Passed = yes ).

:- pred check_rejects_empty_url(string::out, bool::out) is det.

check_rejects_empty_url(Name, Passed) :-
    Name = "an empty deployment URL is rejected",
    ( new_client("", _, _) -> Passed = no ; Passed = yes ).

:- pred check_set_and_clear_auth(string::out, bool::out) is det.

check_set_and_clear_auth(Name, Passed) :-
    Name = "set_auth followed by clear_auth returns to the unauthenticated client",
    ( new_client("https://example.convex.cloud", _, Client0) ->
        set_auth("a-token", Client0, Client1),
        clear_auth(Client1, Client2),
        ( Client2 = Client0 -> Passed = yes ; Passed = no )
    ;
        Passed = no
    ).
