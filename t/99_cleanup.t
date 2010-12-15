#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Cleanup all database objects we may have created
## Shutdown the test database if we created one

use 5.006;
use strict;
use warnings;
use IO::Handle;
*STDOUT->autoflush(1);
*STDERR->autoflush(1);
use Test::More tests => 1;

my $testdir = 'pgsi_test_database';

if (! -d $testdir) {
    pass ("(Cleanup) Test database directory does not exist\n");
    exit;
}

my $pidfile = "$testdir/postmaster.pid";
if (! -e $pidfile) {
    pass ("(Cleanup) Test database PID file does not exist\n");
    exit;
}

open my $fh, '<', $pidfile or die qq{Could not open "$pidfile": $!\n};
<$fh> =~ /(\d+)/ or die qq{No PID found in file "$pidfile"\n};
my $pid = $1;
close $fh or die qq{Could not close "$pidfile": $!\n};

my $count = kill 0 => $pid;
if ($count == 0) {
    unlink $pidfile;
    pass ("(Cleanup) Test database process not found, removed $pidfile\n");
    exit;
}

diag "Shutting down test database\n";

kill 15 => $pid;

pass ("(Cleanup) Test database asked to shutdown with a kill -15\n");
