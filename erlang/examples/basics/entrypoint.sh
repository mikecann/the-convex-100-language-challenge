#!/bin/sh
exec erl -noshell -pa /opt/convex -s main main -s init stop -- "$@"
