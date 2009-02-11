#!perl

## Simply test that the main script compiles and gives a version

use 5.006;
use strict;
use warnings;
use DBI;
use Data::Dumper;
use IO::Handle;
*STDOUT->autoflush(1);
*STDERR->autoflush(1);
use Test::More tests => 6;

use vars qw/$COM $info $count $t/;

eval {
	system "perl -c pgsi.pl 2>/dev/null";
};
is ($@, q{}, 'Program compiled cleanly');

## Create a test database as needed
my $testdir = 'pgsi_test_database';
if (! -d $testdir) {
	diag "Creating test database cluster in $testdir\n";
	$COM = "initdb -D $testdir --locale=C -E UTF8 2>&1";
	eval {
		$info = qx{$COM};
	};
	$@ and BAIL_OUT "Failed to initdb: $@\n";
}

## Make custom changes to the postgresql.conf
my $file = "$testdir/postgresql.conf";
open my $fh, '+<', $file or die qq{Could not open "$file": $!\n};
my $found = 0;
while (<$fh>) {
	if (/PGSI TESTING/) {
		$found = 1;
		last;
	}
}
if (! $found) {
	diag "Configuring postgresql.conf\n";
	print $fh <<"EOT"

## PGSI TESTING
port             = 5555
listen_addresses = ''
max_connections  = 5
log_statement    = 'all'
log_duration     = 'on'
log_line_prefix  = '%t %h %d[%p]: [%l-1] ' ## Simulate syslog entries
log_destination  = 'stderr'
redirect_stderr  = 'off'

EOT
}
close $fh or die qq{Could not close "$file": $!\n};


my $pidfile = "$testdir/postmaster.pid";
my $startup = 1;
my $logfile = 'pg.log';
if (-e $pidfile) {
	open my $fh, '<', $pidfile or die qq{Could not open "$pidfile": $!\n};
	<$fh> =~ /(\d+)/ or die qq{No PID found in file "$pidfile"\n};
	my $pid = $1;
	close $fh or die qq{Could not close "$pidfile": $!\n};
	## Make sure it's still around
	$count = kill 0 => $pid;
	if ($count != 1) {
		warn qq{Server seems to have died, removing file "$pidfile"\n};
		unlink $pidfile or die qq{Could not remove file "$pidfile"\n};
	}
}
if (! -e $pidfile) {
	diag "Starting up test database\n";
	$COM = "pg_ctl -D $testdir -l $logfile start";
	eval {
		$info = qx{$COM};
	};
	$@ and BAIL_OUT "Failed to start database: $@\n";
	{
		last if -e $pidfile;
		sleep 0.1;
		redo;
	}
	## Wait for "ready to accept connections"
	open my $fh, '<', $logfile or die qq{Could not open "$logfile": $!\n};
	seek $fh, -100, 2;
	LOOP: {
		  while (<$fh>) {
			  last LOOP if /system is ready/;
		  }
		  sleep 0.1;
		  seek $fh, 0, 1;
		  redo;
	  }
	close $fh or die qq{Could not close "$logfile": $!\n};
}

## Start tracking things sent to the logfile.
## Write a copy, so we only get things since we started up.
my $testlog = 'test.pg.log';
open my $tfh, '>', $testlog or die qq{Could not open "$testlog": $!\n};
open my $lfh, '<', $logfile or die qq{Could not open "$logfile": $!\n};
seek $lfh, 0, 2;

## Send a few commands to the backend, then test basic functionality
my $dbh = DBI->connect('dbi:Pg:port=5555;dbname=postgres', '', '', {AutoCommit=>1, RaiseError=>1});

$dbh->do("SELECT 999");
$dbh->do("SELECT 888");
$dbh->do("SELECT 777");

$dbh->do("SELECT pg_client_encoding()");

update_log_copy();

$info = qx{perl pgsi.pl --file $testlog};

## Got the standard header?
$t=q{pgsi returned the expected header when run};
like ($info, qr{Query_System_Impact}, $t);

## Got the proper count?
$t=q{pgsi returned the expected count};
like ($info, qr{^\Q3<br />}ms, $t);

$t=q{pgsi returned the expected query};
like ($info, qr{^ SELECT \?$}ms, $t);

$t=q{pgsi returned the expected query};
like ($info, qr{^ SELECT pg_client_encoding\(\)}ms, $t);

$t=q{pgsi returned an average duration line};
if ($info =~ qr{^(\d+)\.\d+ ms<br />}ms) {
	pass ($t);
}
else {
	fail ($t);
}

close $tfh or die qq{Could not close "$testlog": $!\n};

exit;

sub update_log_copy {

	my $action = shift || 0;

	seek $lfh, 0, 1;
	while (<$lfh>) {
		print $tfh $_;
	}
	return;

} ## end of update_log_copy
