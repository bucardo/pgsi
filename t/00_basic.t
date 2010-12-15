#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Simply test that the main script compiles

use 5.006;
use strict;
use warnings;
use Test::More tests => 1;
use IO::Handle;
*STDOUT->autoflush(1);
*STDERR->autoflush(1);

eval {
    system "perl -c pgsi.pl 2>/dev/null";
};
is ($@, q{}, 'Program compiled cleanly');
