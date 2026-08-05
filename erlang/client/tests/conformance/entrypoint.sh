#!/bin/sh
exec erl -noshell -pa /opt/convex -s adapter main -s init stop
