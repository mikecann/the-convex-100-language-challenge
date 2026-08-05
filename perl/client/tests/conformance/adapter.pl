#!/usr/local/bin/perl

use strict;
use warnings;

use FindBin;
use lib $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../..";
use lib join '/', ( $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../.." ),
  'tests', 'conformance';

use Adapter;

Adapter::main();
