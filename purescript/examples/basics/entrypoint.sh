#!/bin/sh

# purerl compiles `Main` to the Erlang module `main@ps`, whose `main/0` returns
# the effect rather than performing it, so the entrypoint applies the thunk.
#
# An uncaught BEAM error would print a crash report on stdout, and the
# example's stdout is a strict shared success transcript. Catch failures at the
# runtime boundary and keep diagnostics on stderr instead.
exec erl -noshell -pa /opt/convex \
  -eval 'try ('\''main@ps'\'':main())() of _ -> halt(0) catch Class:Reason -> io:format(standard_error, "Convex example failed: ~p:~p~n", [Class, Reason]), halt(1) end.' \
  -- "$@"
