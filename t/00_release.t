#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Make sure the version number is consistent in all places
## Check all files in MANIFEST for tabs and odd characters

use 5.006;
use strict;
use warnings;
use Data::Dumper;
use Test::More;
use lib 't','.';

if (! $ENV{RELEASE_TESTING}) {
    plan (skip_all =>  'Test skipped unless environment variable RELEASE_TESTING is set');
}

## Grab all files from the MANIFEST to generate a test count
my $file = 'MANIFEST';
my @mfiles;
open my $mfh, '<', $file or die qq{Could not open "$file": $!\n};
while (<$mfh>) {
    next if /^#/;
    push @mfiles => $1 if /(\S.+)/o;
}
close $mfh or warn qq{Could not close "$file": $!\n};

plan tests => 1 + @mfiles;

my %v;
my $vre = qr{(\d+\.\d+\.\d+\_?\d*)};

## Grab version from various files
$file = 'META.yml';
open my $fh, '<', $file or die qq{Could not open "$file": $!\n};
while (<$fh>) {
    push @{$v{$file}} => [$1,$.] if /version\s*:\s*$vre/;
}
close $fh or warn qq{Could not close "$file": $!\n};

$file = 'Makefile.PL';
open $fh, '<', $file or die qq{Could not open "$file": $!\n};
while (<$fh>) {
    push @{$v{$file}} => [$1,$.] if /VERSION = '$vre'/;
}
close $fh or warn qq{Could not close "$file": $!\n};

$file = 'pgsi.pl';
open $fh, '<', $file or die qq{Could not open "$file": $!\n};
while (<$fh>) {
    push @{$v{$file}} => [$1,$.] if (/VERSION = qv\('$vre'/ or /documents version $vre/);
}
close $fh or warn qq{Could not close "$file": $!\n};

$file = 'Changes';
open $fh, '<', $file or die qq{Could not open "$file": $!\n};
while (<$fh>) {
    if (/^$vre/) {
        push @{$v{$file}} => [$1,$.];
        last;
    }
}
close $fh or warn qq{Could not close "$file": $!\n};

my $good = 1;
my $lastver;
for my $filename (keys %v) {
    for my $glob (@{$v{$filename}}) {
        my ($ver,$line) = @$glob;
        if (! defined $lastver) {
            $lastver = $ver;
        }
        elsif ($ver ne $lastver) {
            $good = 0;
        }
    }
}

if ($good) {
    pass ("All version numbers are the same ($lastver)");
}
else {
    fail ('All version numbers were not the same!');
    for my $filename (sort keys %v) {
        for my $glob (@{$v{$filename}}) {
            my ($ver,$line) = @$glob;
            diag "File: $filename. Line: $line. Version: $ver\n";
        }
    }
}

## Make sure all files in the MANIFEST are "clean": no tabs, no unusual characters

for my $mfile (@mfiles) {
    file_is_clean($mfile);
}

sub file_is_clean {

    my $filename = shift or die;

    if (!open $fh, '<', $filename) {
        fail qq{Could not open "$filename": $!\n};
        return;
    }
    $good = 1;
    my $inside_copy = 0;
    while (<$fh>) {
        if (/^COPY .+ FROM stdin/i) {
            $inside_copy = 1;
        }
        if (/^\\./ and $inside_copy) {
            $inside_copy = 0;
        }
        if (/\t/ and $filename ne 'Makefile.PL' and $filename !~ /\.html$/ and ! $inside_copy) {
            diag "Found a tab at line $. of $filename\n";
            $good = 0;
        }
        if (! /^[\S ]*/) {
            diag "Invalid character at line $. of $filename: $_\n";
            $good = 0; die;
        }
    }
    close $fh or warn qq{Could not close "$filename": $!\n};

    if ($good) {
        pass ("The $filename file has no tabs or unusual characters");
    }
    else {
        fail ("The $filename file did not pass inspection!");
    }

}

exit;
