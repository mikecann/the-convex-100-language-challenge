#!/bin/sh

# purerl compiles `Adapter` to the Erlang module `adapter@ps`. `main/0` returns
# the effect, so the entrypoint applies it and then stops the node, which keeps
# a clean close a zero exit status for the shared controller.
#
# `-noinput`, not `-noshell`: under `-noshell` OTP starts a reader that pulls
# standard input into an io server's mailbox as fast as the peer can write it,
# with no bound and no back pressure. The adapter owns a port on the descriptor
# instead (see `Convex.Sys`), and `-noinput` is what stops OTP competing for
# the same bytes. Diagnostics on standard error are unaffected.
exec erl -noinput -pa /opt/convex \
  -eval 'try ('\''adapter@ps'\'':main())() of _ -> halt(0) catch Class:Reason -> io:format(standard_error, "Convex adapter failed: ~p:~p~n", [Class, Reason]), halt(1) end.'
