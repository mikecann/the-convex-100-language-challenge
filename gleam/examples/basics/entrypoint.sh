#!/bin/sh

# `erl -s` sends an uncaught Gleam assertion's crash report to stdout. The
# example's stdout is a strict shared success transcript, so catch failures at
# the runtime boundary and keep diagnostics on stderr instead.
exec erl -noshell -pa /opt/convex \
  -eval 'try main:main() of _ -> halt(0) catch Class:Reason -> io:format(standard_error, "Convex example failed: ~p:~p~n", [Class, Reason]), halt(1) end.' \
  -- "$@"
