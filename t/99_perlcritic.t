#!perl

## Run Perl::Critic against the source code and the tests
## This is highly customized, so take with a grain of salt
## Requires TEST_CRITIC to be set

use 5.006;
use strict;
use warnings;
use Test::More;
use Data::Dumper;
use IO::Handle;
*STDOUT->autoflush(1);
*STDERR->autoflush(1);

my (@testfiles,%fileslurp,$t);

if (!$ENV{TEST_CRITIC}) {
	plan skip_all => 'Set the environment variable TEST_CRITIC to enable this test';
}
elsif (!eval { require Perl::Critic; 1 }) {
	plan skip_all => 'Could not find Perl::Critic';
}
elsif ($Perl::Critic::VERSION < 0.23) {
	plan skip_all => 'Perl::Critic must be version 0.23 or higher';
}
else {
	$ENV{LANG} = 'C';
	opendir my $dir, 't' or die qq{Could not open directory 't': $!\n};
	@testfiles = map { "t/$_" } grep { /^.+\.(t|pl)$/ } readdir $dir;
	closedir $dir or die qq{Could not closedir "$dir": $!\n};

	my $testmore = 0;
	for my $file (@testfiles) {
		open my $fh, '<', $file or die qq{Could not open "$file": $!\n};
		my $line;
		while (defined($line = <$fh>)) {
			last if $line =~ /__DATA__/; ## perlcritic.t
			for my $func (qw/ok isnt pass fail cmp cmp_ok is_deeply unlike like/) { ## no skip
				next if $line !~ /\b$func\b/;
				next if $line =~ /$func \w/; ## e.g. 'skip these tests'
				next if $line =~ /[\$\%]$func/; ## e.g. $ok %ok
				$fileslurp{$file}{$.}{$func} = $line;
				$testmore++;
			}
		}
		close $fh or die qq{Could not close "$file": $!\n};
	}
	plan tests => 3 + @testfiles + $testmore;
}
ok (@testfiles, 'Found files in test directory');

## Make sure all Test::More function calls are standardized
for my $file (sort keys %fileslurp) {
	for my $linenum (sort {$a <=> $b} keys %{$fileslurp{$file}}) {
		for my $func (sort keys %{$fileslurp{$file}{$linenum}}) {
			$t=qq{Test::More method "$func" is in standard format inside $file at line $linenum};
			## Must be at start of line (optional whitespace and comment), a space, a paren, and something interesting
			like ($fileslurp{$file}{$linenum}{$func}, qr{^\s*#?$func \(['\S]}, $t);
		}
	}
}

## Check some non-test files
my $critic = Perl::Critic->new(-severity => 1);

for my $filename (qw{pgsi.pl}) {

	if ($ENV{TEST_CRITIC_SKIPNONTEST}) {
		pass (qq{Skipping non-test file "$filename"});
		next;
	}

	-e $filename or die qq{Could not find "$filename"!};
	open my $oldstderr, '>&', \*STDERR or die 'Could not dupe STDERR';
	close STDERR or die qq{Could not close STDERR: $!};
	my @vio = $critic->critique($filename);
	open STDERR, '>&', $oldstderr or die 'Could not recreate STDERR'; ## no critic
	close $oldstderr or die qq{Could not close STDERR copy: $!};
	my $vios = 0;
  VIO: for my $v (@vio) {
		my $d = $v->description();
		(my $policy = $v->policy()) =~ s/Perl::Critic::Policy:://;
		my $source = $v->source();

		## Allow our sql and qw blocks to have tabs:
		next if $policy =~ /ProhibitHardTabs/ and ($source =~ /sql = qq/i or $source =~ /qw[\(\/]/);

		$vios++;
		my $f = $v->filename();
		my $l = $v->location();
		my $line = $l->[0];
		diag "\nFile: $f (line $line)\n";
		diag "Vio: $d\n";
		diag "Policy: $policy\n";
		diag "Source: $source\n\n";
	}
	if ($vios) {
		fail (qq{Failed Perl::Critic tests for file "$filename": $vios});
	}
	else {
		pass (qq{File "$filename" passed all Perl::Critic tests});
	}

}

## Specific exclusions for test scripts:
my %ok =
	(yaml => {
			  sub => 'meta_spec_ok',
			  },
	 pod => {
			 sub => 'pod_file_ok pod_coverage_ok',
			 },
	 signature => {
			 sub => 'verify SIGNATURE_OK',
			 },
);
for my $f (keys %ok) {
	for my $ex (keys %{$ok{$f}}) {
		if ($ex eq 'sub') {
			for my $foo (split /\s+/ => $ok{$f}{sub}) {
				push @{$ok{$f}{OK}} => qr{Subroutine "$foo" (?:is neither|not exported)};
			}
		}
		else {
			die "Unknown exception '$ex'\n";
		}
	}
}

## Allow Test::More subroutines
my $tm = join '|' => (qw/skip plan pass fail is ok diag BAIL_OUT/);
my $testmoreok = qr{Subroutine "$tm" is neither};

## Create a new critic for the tests
$critic = Perl::Critic->new(-severity => 1);

my $count = 1;
for my $filename (sort @testfiles) {
	-e $filename or die qq{Could not find "$filename"!};
	my @vio = $critic->critique($filename);
	my $vios = 0;
  VIO: for my $v (@vio) {
		my $d = $v->description();
		(my $policy = $v->policy()) =~ s/Perl::Critic::Policy:://;
		my $source = $v->source();
		my $f = $v->filename();

		## Skip common Test::More subroutines:
		next if $d =~ $testmoreok;

		## Skip other specific items:
		for my $k (sort keys %ok) {
			next unless $f =~ /$k/;
			for (@{$ok{$k}{OK}}) {
				next VIO if $d =~ $_;
			}
		}

		## Skip included file package warning
		next if $policy =~ /RequireExplicitPackage/ and $filename =~ /setup/;

		$vios++;
		my $l = $v->location();
		my $line = $l->[0];
		diag "\nFile: $f (line $line)\n";
		diag "Vio: $d\n";
		diag "Policy: $policy\n";
		diag "Source: $source\n\n";
	}
	if ($vios) {
		fail (qq{Failed Perl::Critic tests for file "$filename": $vios});
	}
	else {
		pass (qq{File "$filename" passed all Perl::Critic tests});
	}
}

pass ('Finished Perl::Critic testing');

