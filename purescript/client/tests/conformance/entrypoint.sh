#!/bin/sh

# purerl compiles `Adapter` to the Erlang module `adapter@ps`. `main/0` returns
# the effect, so the entrypoint applies it and then stops the node, which keeps
# a clean close a zero exit status for the shared controller.
exec erl -noshell -pa /opt/convex \
  -eval 'try ('\''adapter@ps'\'':main())() of _ -> halt(0) catch Class:Reason -> io:format(standard_error, "Convex adapter failed: ~p:~p~n", [Class, Reason]), halt(1) end.'
