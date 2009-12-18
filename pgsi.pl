#!/usr/bin/perl

## Parse Postgres logs and determine the system impact
##
## Usage: pgsi.pl [options] < pglog_slice.log
##
## See the POD inside this file for full documentation:
## perldoc pgsi.pl
##
## Mark Johnson <mark@endpoint.com>

package PGSI;

use strict;
use warnings;
use Data::Dumper;

use Time::Local qw();
use Getopt::Long;
use IO::Handle;
use 5.008003;

our $VERSION = '1.1.2';

*STDOUT->autoflush(1);
*STDERR->autoflush(1);

my (
    %query,
    %canonical_q,
    $first_line,
    $last_line,
    %seen,
);

my %opt = (
    'top-10'      => '',
    'all'         => '',
    'query-types' => '',
    'pg-version'  => '',
    'offenders'   => 0,
    'verbose'     => 0,
    'format'      => 'html',
);

my $USAGE = qq{Usage: $0 -f filename [options]\n};

GetOptions ( ## no critic
    \%opt,
    (
        'top-10=s',
        'all=s',
        'query-types=s',
        'pg-version=s',
        'offenders=i',
        'help',
        'verbose',
        'file=s',
        'format=s',
    )
) or die $USAGE;

## Prepare formatting vars based on opt{format}
## The default is 'html':
my $fmstartbold = q{<b>};
my $fmendbold = q{</b>};
my $fmstartheader1 = q{<h1>};
my $fmendheader1 = q{</h1>};
my $fmstartheader2 = q{<h2>};
my $fmendheader2 = q{</h2>};
my $fmstartheader3 = q{<h3>};
my $fmendheader3 = q{</h3>};
my $fmsep = q{<hr />};
my $fmstartquery = '<pre>';
my $fmendquery = '</pre>';
if ($opt{format} eq 'mediawiki') {
    $fmstartbold    = q{'''};
    $fmendbold      = q{'''};
    $fmstartheader1 = q{==};
    $fmendheader1   = q{==};
    $fmstartheader2 = q{====};
    $fmendheader2   = q{====};
    $fmstartheader3 = q{=====};
    $fmendheader3   = q{=====};
    $fmsep          = q{----};
    $fmstartquery   = '  ';
    $fmendquery     = '';
}

# Build an or-list for regex extraction of
# the query types of interest.
my $query_types = $opt{'query-types'}
    ? join (
        '|',
        grep { /\w/ && !$seen{$_}++ }
            split (
                /[,\s]+/,
                "\L$opt{'query-types'}"
            )
      )
    : 'select'
;

# Partition the top-10 or all file-patterns
# into their path and file-name components
for my $k ( qw/top-10 all/ ) {
    local ($_) = delete $opt{$k};
    my @v =
        map { defined ($_) ? $_ : '' }
            m{(.*/)?(.*)};
    my @k =
        map {"$k-$_"} qw/path file/;
    @opt{@k} = @v;
}

# Base regex to capture the main pieces of
# each log line entry
my $statement_re =
    qr{
        ^(.+?
            postgres\[
                (\d+)
            \]
        ):
        \s+
        \[
            \d+
            -
            (\d+)
        \]
        \s
        (.*)
    }xms;

# Create the appropriate regex to pull out the actual query depending on the
# format implied by --pg-version. Blesses regex into the appropriate namespace
# to simplify access to routines that deviate between log formats.
my $extract_query_re =
    make_extractor(
        $opt{'pg-version'},
        $query_types
    );

# Regex specifically for the concluding duration
# entry after a query finishes.
my $extract_duration_re =
    qr{
        \A
        log:
        \s
        duration:
        \s
        (
            \d+
            [.]
            \d{3}
        )
    }xms;

my $fh;
if ($opt{file}) {
    open $fh, '<', $opt{file} or die qq{Could not open "$opt{file}": $!\n};
}
else {
    $fh = \*STDIN;
}

while (my $line = <$fh>) {

    if ($opt{verbose} >= 2) {
        chomp $line;
        warn "Checking line ($line)\n";
    }

    # Lines that don't match the basic format are ignored.
    if ($line !~ $statement_re) {
        chomp $line;
        $opt{verbose} and warn "Line $. did not match: $line\n";
        next;
    }

    my ($st_id, $pid, $st_seq, $st_frag) = ($1, $2, $3, $4);

    $first_line = $last_line = $line
        unless defined $first_line;

    # Allows for blocks of log to be unordered. Assumes
    # earliest found timestamp is start time, and latest
    # end time, regardless of the order in which they're
    # encountered.
    if (defined $line) {
        $first_line = $line
            if $line lt $first_line;
        $last_line = $line
            if $line gt $last_line;
    }

    my $arr;

    # Starting a new statement. Close off
    # possible previous one and begin new
    # one.
    resolve_stmt($pid)
        if $st_seq == 1;

    # Skip any entries that start the log
    # after their first entry.
    next unless $arr = $query{$pid}{fragments};

    # "statement_id" is the earliest timestamp/pid
    # entry found for the statement in question.
    # It should suffice for a human to identify
    # the query within the logfiles.
    $query{$pid}{statement_id} = $st_id
        if $st_seq == 1;

    push (
        @$arr,
        $st_frag
        );

} # End while

defined $first_line or die qq{Could not find any matching lines: incorrect format?\n};

# Go through all entries that haven't been resolved
# (indicated by the presence of elements in the
# fragments array) and add them to the canonical
# list.
while (my ($pid, $hsh) = each %query) {
    next unless exists $hsh->{fragments} and @{ $hsh->{fragments} };
    resolve_stmt($pid);
}

# Determine the server and start/end times
# from the oldest and newest log lines.
my ($host, $start_time, $end_time) =
    log_meta($first_line, $last_line);

# Calculate the ms interval of all log activity.
my $log_int_ms = log_interval($start_time, $end_time);

for my $hsh (values %canonical_q) {

    # Mean runtime.
    my $mean = $hsh->{duration} /= $hsh->{count};

    # Avg time between successive calls.
    $hsh->{interval} = $log_int_ms / $hsh->{count};

    # SI, expressed as a percent. 100 implies the query
    # was, on average, constantly running on a single
    # instance. If interval is invalid (after all,
    # syslog precision is only 1 second), set to -1
    $hsh->{sys_impact} =
        $hsh->{interval} != 0
            ? 100 * $hsh->{duration} / $hsh->{interval}
            : -1
    ;

    # Determine standard deviation. If count <= 1,
    # set to -1 to indicate not applicable.
    if ($hsh->{count} > 1) {
        my $sum = 0;
        for my $duration ( @{$hsh->{durations}} ) {
            $sum += ($duration - $mean)**2;
        }
        $hsh->{deviation} = sqrt($sum / ($hsh->{count} - 1));
    }
    else {
        $hsh->{deviation} = -1;
    }
}

my %out;

# Sort by SI descending and print out reports.
for (
        sort {
            $canonical_q{$b}{sys_impact}
                <=>
            $canonical_q{$a}{sys_impact}
        }
        keys %canonical_q
    )
{

    my $hsh = $canonical_q{$_};

    my $system_impact;
    if ($hsh->{sys_impact} < 0.001) {
        $system_impact = sprintf '%0.6f', $hsh->{sys_impact};
    }
    else {
        $system_impact = sprintf '%0.3f', $hsh->{sys_impact};
    }
    my $duration = sprintf '%0.3f ms', $hsh->{duration};
    my $count = $hsh->{count};
    my $interval;
    if ($hsh->{interval} > 10000) {
        $interval = sprintf '%d seconds', $hsh->{interval}/1000;
    }
    elsif ($hsh->{interval} < 1000) {
        $interval = sprintf '%0.3f ms', $hsh->{interval};
    }
    else {
        $interval = sprintf '%d ms', $hsh->{interval};
    }
    my $deviation = sprintf '%0.3f ms', $hsh->{deviation};
    if ($count == 1) {
        $deviation = 'N/A';
    }

    my $arr =
        $out{ $hsh->{qtype} }
            ||= [];

    # If user provides positive integer
    # in --offenders, add in the actual
    # durations of the best and worst
    # number of queries requested in
    # report. Entry includes full beginning
    # piece of log entry. Offenders was
    # used since initially it only displayed
    # the worst queries, or worst offenders.
    # Best was just added in for balance.
    my $offenders = '';
    if ($opt{offenders}) {
        $offenders = sprintf(
            qq{
<table>
  <tr>
    <td align="center">
      ${fmstartbold}Best$fmendbold
    </td>
    <td align="center">
      ${fmstartbold}Worst$fmendbold
    </td>
  </tr>
  <tr>
    <td align="left"><ol>%s</ol></td>
    <td align="left"><ol>%s</ol></td>
  </tr>
</table>},
            map { join '', map { "<li>$_->[0] -- $_->[1] ms</li>" } @$_ } @$hsh{
                qw( minimum_offenders maximum_offenders )
            }
        );
    }

    my $queries = prettify_query($_) . $offenders;

    my $fmshowborder = $opt{format} eq 'html' ? q{border='1'} : '';

    push (@$arr, <<"EOP");
<table $fmshowborder>
<tr>
<td align="right">
${fmstartbold}System Impact:$fmendbold<br />
Avg. Duration:<br />
Total Count:<br />
Avg. Interval:<br />
Std. Deviation:
</td>
<td>
$fmstartbold$system_impact$fmendbold<br />
$duration<br />
$count<br />
$interval<br />
$deviation
</td>
</tr>
</table>
${fmstartquery}$queries$fmendquery
EOP
}

while (my ($qtype,$arr) = each %out) {

    my $type_top_ten = $opt{'top-10-file'}
        ? "$opt{'top-10-path'}$host-$qtype-$opt{'top-10-file'}"
        : '/dev/null'
    ;

    my ($all_fh, $type_all);

    if ($opt{'all-file'}) {
        $type_all = "$opt{'all-path'}$host-$qtype-$opt{'all-file'}";
        open ($all_fh, '>', $type_all)
            or die "Can't open '$type_all' to write: $!";
    }
    else {
        $all_fh = \*STDOUT;
    }

    open (my $top_ten_fh, '>', $type_top_ten)
        or die "Can't open '$type_top_ten' to write: $!";

    # Start off reports with appropriate Wiki naming
    # convention. Can automate the posting of reports
    # with code that strips first line and uses it
    # for Wiki page.

    my $a1 = '';
    my $a2 = '';
    if ($opt{format} eq 'html') {
        my $safename = "${host}_$qtype";
        $a1 = qq{<a name="$safename">};
        $a2 = qq{</a>};
        print $all_fh qq{${fmstartheader2}${a1}Query System Impact: $host : $qtype${a2}${fmendheader2}\n};
    }
    else {
        print $all_fh qq{Query_System_Impact:$host:$qtype\n};
    }

    # Top 10 lists are put into templates, assuming
    # they will be pulled in to a collection with
    # other top 10s, typically for the same host.
    print $top_ten_fh <<"EOP";
Template:${host}_SI_Top_10:$qtype
EOP

    for my $fh ($all_fh, $top_ten_fh) {
        print $fh "${fmstartheader3}Log activity from $start_time to $end_time${fmendheader3}\n";
    }

    print $all_fh join ("$fmsep\n", @$arr);
    print $top_ten_fh join ("$fmsep", grep { defined $_ } @$arr[0..9]);

    close ($top_ten_fh) or warn "Error closing '$type_top_ten': $!";
    if ($type_all) {
        close ($all_fh) or warn "Error closing '$type_all': $!";
    }
}

close $fh or warn qq{Could not close "$opt{file}": $!\n};
exit;

sub resolve_stmt {

    my $pid = shift;

    $query{$pid} ||= {};
    my $prev = $query{$pid}{fragments};


    # First time to see this pid. Initialize
    # fragments array, and no previous
    # statement to resolve.
    unless (ref ($prev) eq 'ARRAY') {
        $query{$pid}{fragments} = [];
        return;
    }

    # Now have collected a full query and need to
    # canonize and store.
    my $full_statement = lc (join (' ', @$prev));

    # Get rid of SQL comments!
    $full_statement =~ s/\s*--.*$//mg;
    $full_statement =~ s{/[*].*?[*]/}{}msg;

    # Tidy up spaces
    $full_statement =~ s/#011/ /g;
    $full_statement =~ s/^\s+|\s+$//g;
    $full_statement =~ s/\s+/ /g;

    # If closing a query, store until we get
    # subsequent duration statement
    if (my @match_args = $full_statement =~ $extract_query_re) {

        my ($main_query, $query_type) =
            $extract_query_re->query_info(@match_args);

        # Clean out arguments
        # Quoted string
        $main_query =~ s/'(?:''|\\+'?|[^'\\]+)*'/?/g;

        # Numeric no quote, and bind params
        $main_query =~ s/(?<=[^\w.])[\$-]?(?:\d*[.])?\d+\b/?/g;

        # Collapsing IN () lists, so queries deviating
        # only by 'IN (?,?)' and 'IN (?,?,?)' are logged
        # as "the same"
        $main_query =~
            s{
                # Starts IN ...
                \s in \s?
                # Outermost paren for IN list
                [(]
                    (?:
                        # Could be list of rows
                        [(] [?,\s\$]* [)]
                            |
                        # or the standard stuff of a scalar list
                        [?,\s\$]+
                    )+
                # Until we close the full IN list
                [)]
            }
            { in (?+)}xmsg;

        # Store in temporary statement hashkey,
        # along with UPPER type
        $query{$pid}{statement} = $main_query;
        $query{$pid}{qtype} = "\U$query_type";
    }
    elsif (
            exists $query{$pid}{statement}
            &&
            $full_statement =~ $extract_duration_re
        )
    {
        my $duration = $1 || 0;
        my $stored = $query{$pid};

        # Add canonical query to count hash
        my $hsh =
            $canonical_q{ delete $stored->{statement} }
                ||= {
                        count => 0,
                        duration => 0,
                        deviation => 0,
                        qtype => delete $stored->{qtype},
                        minimum_offenders => [ [ $stored->{statement_id} => $duration ] ],
                        minimum_threshold => $duration,
                        maximum_offenders => [ [ $stored->{statement_id} => $duration ] ],
                        maximum_threshold => $duration,
                        durations => [],
                    };

        ++$hsh->{count};
        $hsh->{duration} += $duration;
        push @{$hsh->{durations}}, $duration;

        # If we're tracking offenders (best/worst queries)
        # add them in if the newest one measures as one of the
        # best or worst.
        if ($opt{offenders}) {
            if ($duration > $hsh->{maximum_threshold}) {
                my $array = $hsh->{maximum_offenders};
                @$array = (
                    sort { $b->[1] <=> $a->[1] }
                    @$array,
                    [ $stored->{statement_id}, $duration ],
                );
                splice (@$array, $opt{offenders}) if @$array > $opt{offenders};
                $hsh->{maximum_threshold} = $array->[-1]->[1];
            }

            if ($duration < $hsh->{minimum_threshold}) {
                my $array = $hsh->{minimum_offenders};
                @$array = (
                    sort { $a->[1] <=> $b->[1] }
                    @$array,
                    [ $stored->{statement_id}, $duration ],
                );
                splice (@$array, $opt{offenders}) if @$array > $opt{offenders};
                $hsh->{maximum_threshold} = $array->[-1]->[1];
            }
        }
    }

    @$prev = ();
    return 1;
}

# Expects first arg as log entry of earliest time
# and second arg as log entry of latest time
sub log_interval {
    my ($first_line, $second_line) = @_;

    my $first_timelocal = get_timelocal_from_line($first_line);
    my $second_timelocal = get_timelocal_from_line($second_line);
    my $interval_in_sec = $second_timelocal - $first_timelocal;
    
    # Full log-slice interval in ms
    return $interval_in_sec * 1000;
}

sub get_timelocal_from_line {
    my ($line) = @_;
    
    my @datetime = get_date_from_line($line);
    
    # timelocal uses 0..11 for months instead of 1..12
    --$datetime[1];
    
    my $int_in_sec =
        Time::Local::timelocal(reverse(@datetime));
        
    return $int_in_sec;
}

sub get_date_from_line {
    my ($line) = @_;
    
    my ($year, $mon, $day, $hour, $min, $sec) = 
        $line =~ m{
        (\d{4})
        -
        (\d{1,2})
        -
        (\d{1,2})
        [T ]
        0?
        (\d{1,2})
        :
        0?
        (\d{1,2})
        :
        0?
        (\d{1,2})
    }x;
    
    return ($year, $mon, $day, $hour, $min, $sec);
}

sub prettify_query {
    local ($_) = shift;

    # Perform some basic transformations
    # to try to make the query more readable.
    # It's not perfect, but much better than
    # all one line, all lower case.
    # Also prefixes a single space to each
    # line for wiki blockquote format.

    # uc sql keywords
    s{
        \b(
            select     |
            exists     |
            distinct   |
            from       |
            where      |
            (?:
                group  |
                order
            ) \s by    |
            and        |
            or         |
            not        |
            in         |
            between    |
            as         |
            on         |
            using      |
            left       |
            right      |
            full       |
            join       |
            limit      |
            offset     |
            count      |
            coalesce   |
            max        |
            min        |
            sum        |
            all        |
            desc       |
            asc        |
            union      |
            intersect  |
            except     |
            is         |
            null       |
            true       |
            false      |
            case       |
            when       |
            then       |
            else       |
            end        |
            i? like    |
            having     |
            insert     |
            (?:in)? to |
            update     |
            delete     |
            set        |
            values     |
            copy       |
            create     |
            drop       |
            add        |
            alter      |
            table      |
            trigger    |
            rule       |
            references |
            foreign
            \s key     |
            (?:
                en |
                dis
            ) able     |
            listen     |
            notify     |
            index
        )\b
    }
    {\U$1}xmsg;

    # line break after certain
    # sql keywords
    s{
        (?<!DELETE)
        \s
        (
            SELECT    |
            FROM      |
            (?:
                (?: LEFT | RIGHT | FULL )
                (?: \s OUTER )?
                \s
            )?
            JOIN      |
            WHERE     |
            (?:
                GROUP |
                ORDER
            )\s BY    |
            LIMIT     |
            OFFSET    |
            UNION     |
            INTERSECT |
            EXCEPT    |
            SET       |
            VALUES    |
            ADD       |
            DROP      |
            REFERENCES
        )
    }
    {\n $1}xmsg;

    if (/^SELECT code::text/) {
        my $count = 0;
        ++$count while m{[(]\s*[?]\s*,\s*[?]\s*[)]}g;
        ## print "Has $count freakin' args in the IN list\n";
    }
    return ' ' . $_;
}

sub log_meta {
    my @lines = @_;

    my ($host, $start, $end);

    # Pull out start and end times,
    # and host. Assumes start as first
    # arg and end as second.

    for (@lines) {
        if ($opt{verbose} >= 1) {
            chomp $_;
            warn "Checking meta line ($_)\n";
        }
        m{
            \A
            ( .{19} )
            (?:[+-]\d+:\d+|\s[A-Z]+)
            \s
            ( \S+ )
        }xms or next;

        $end = $1; ## no critic
        $host ||= $2; ## no critic
        $start ||= $end;
    }

    defined $start or die qq{Unable to find the starting time\n};

    defined $end or die qq{Unable to find the ending time\n};

    return ("\u\L$host", $start, $end);
}

sub make_extractor {
    (my $pg_version = shift) =~ s/\W+/_/g;
    $pg_version ||= '8_2';
    my $class = "PG_$pg_version";
    no strict 'refs'; ## no critic
    return bless (&$class(shift), $class);
}

sub PG_8_1 {
    my $query_types = shift;

    # Regex for log format prior to DETAIL
    # entries in 8.2. Not certain how many versions
    # prior to 8.1 for which this will work.

    return qr{
        \A
        log:
        \s
        statement:
        \s
        (?:
            execute
            \s
            <[^>]*>
            \s
            (\[)
            prepare:
            \s
        )?
        (
            ($query_types)
            .*?
        )
        (\])?
        \Z
    }xms;
}

sub PG_8_2 {
    my $query_types = shift;

    # Regex for log format after DETAIL
    # entries in 8.2. Works for v's 8.2 and 8.3.

    return qr{
        \A
        log:
        \s
        (
            statement |
            execute
        )
        [^:]* :
        \s
        (
            ($query_types)
            .*
        )
    }xms;
}

sub PG_8_1::query_info {

    my $self = shift;
    my ($open_sq, $main_query, $query_type, $close_sq) = @_;

    # Query may either be direct statement or the EXECUTE
    # of a PREPAREd statement. If EXECUTE variety, the log
    # partitions the query off in sq. brackets, so we tail
    # strip possible space between the query end and the
    # right sq. bracket that used to end the string. Else,
    # the query itself might end in right sq. bracket, so
    # we put it back on if found.
    if ($open_sq) {
        $main_query =~ s/\s+$//;
    }
    else {
        $main_query .= $close_sq || '';
    }

    return ($main_query, $query_type);
}

sub PG_8_2::query_info {

    my $self = shift;
    my ($stm_or_exec, $main_query, $query_type) = @_;

    # EXECUTEd queries end with a DETAIL segment showing
    # the bound parameters, which is great, except in
    # our case, where we are interested in flattening
    # out arguments.
    $main_query =~ s/ detail:.*?$//
        if $stm_or_exec eq 'execute';

    return ($main_query, $query_type);
}

__END__

=head1 NAME

pgsi.pl - Produce system impact reports for a PostgreSQL database.

=head1 VERSION

This documentation refers to version 1.1.1

=head1 USAGE


pgsi.pl [options] < pglog_slice.log 

 or...

pgsi.pl --file pglog_slice.log [options]

=over 3

=item Options

 --file
 --query-types
 --top-10
 --all
 --pg-version
 --offenders

=back

=head1 DESCRIPTION

System Impact (SI) is a measure of the overall load a given query imposes on a
server. It is expressed as a percentage of a query's average duration over its
average interval between successive calls. E.g., SI=80 indicates that a given
query is active 80% of the time during the entire log interval. SI=200
indicates the query is running twice at all times on average. Thus, the lower
the SI, the better.

The goal of SI is to identify those queries most likely to cause performance
degradation on the database during heaviest traffic periods. Focusing
exclusively on the least efficient queries can hide relatively fast-running
queries that saturate the system more because they are called far more
frequently. By contrast, focusing only on the most-frequently called queries
will tend to emphasize small, highly optimized queries at the expense of
slightly less popular queries that spend much more of their time between
successive calls in an active state. These are often smaller queries that have
failed to be optimized and punish a system severely under heavy load.

One thing SI does not do is distinguish between high-value queries represented
by extended active states or long durations due to blocking locks. Either
condition is worthy of attention, but determining which is to blame will
require independent investigation.

Queries are canonized with placeholders representing literals or arguments.
Further, IN lists are canonized so that variation from query to query only
in the number of elements in the IN list will not be treated as distinct
queries.

Some examples of the "same" query:

=over 3

=item *

 SELECT col FROM table WHERE code = 'One';
 SELECT col FROM table WHERE code = 'Sixty-Three';

=item *

 SELECT foo FROM bar WHERE fuzz = $1 AND color IN ('R','G','B');
 Select FOO
 from bar
 WhErE fuzz = '56'
     AND color IN ('R', $1);

=back

Differences in capitalization and whitespace are irrelevant.

=head2 Log Data

Pass in log data on stdin:

    pgsi.pl < some_log_slice.log
    cat some_log_slice.log | pgsi.pl

Or use the --file option:

    pgsi.pl --file=some_log_slice.log

Log data must comply with a specific format and must be from contiguous
activity. The code makes the assumption that the overall interval of activity
is the time elapsed between the first and last log entries. If there are
several blocks of logs to analyze, they must be run separately.

Required format is the following in syslog:

YYYY-MM-DDTHH24:MI:SS(-TZ:00)? server postgres[I<pid>]:

This also requires that log_statement is set to 'all' and 
that log_duration be set to 'on' in postgresql.conf.
If you are not using syslog, you can simulate the format with the following:

log_line_prefix  = '%t %h postgres[%p]: [%l-1] ' ## Simulate syslog for pgsi.

=head2 Options

=over 4

=item --query-types

Query impact is segregated by types. I.e., all the SELECTs together, all
UPDATEs together, etc. Typically it is assumed that SELECT is the most
interesting (and is by itself the default), but any query type may be analyzed.
Multiples are provided as space- or comma-separated lists.

    pgsi.pl --query-types="select, update, copy, create"

The code will produce a unique report for each type when used with the --all
and/or --top-10 file-pattern options (see below).

=item --top-10, --all

Supplies a file I<pattern> and optional directory path into which the reports
should be written per --query-type. The pattern is prefixed with the
--query-type and host for this report and placed into the requested directory
(or cwd if no path is present).

--all will list every canonized query encountered, which is likely to
contain a large number of queries of no interest (those with negligible
impact).

--top-10 limits the report to only the 10 entries with the greatest SI.

    pgsi.pl \
        --query-types=select,update \
        --all=si_reports/monday_10am_1pm.all.txt \
        --top-10=si_reports/monday_10am_1pm.t10.txt

This will produce the following reports in si_reports/ for a database running
on server db1:

    SELECT-db1-monday_10am_1pm.all.txt
    UPDATE-db1-monday_10am_1pm.all.txt
    SELECT-db1-monday_10am_1pm.t10.txt
    UPDATE-db1-monday_10am_1pm.t10.txt

If --top-10 is not supplied, then no top 10 report is generated. If --all is
not supplied, then the report(s) print to stdout.

=item --pg-version

Currently, this might better be described as either "before DETAIL" or "after
DETAIL". The code was written against PG 8.1 originally, but when 8.2 came out
the addition of DETAIL log entries forced a different parser. That unfortunate
timing led to the assumption that log construction would change with each
release. Going forward, --pg-version will be (other than 8.1) the first version
in which this log format was encountered.

--pg-version is only either 8.1 or 8.2 (8.2 is default). It's unknown how far
back in versions the 8.1 format holds, but 8.2 holds for itself and 8.3. So,
unless you're working against logs generated by a PG version less than 8.2, you
do not need to include this option (but it might save you some trouble if a new
format comes at a later version and the default bumps up to the most recent
while you stay on your older version).

    pgsi.pl --pg-version=8.1

=item --offenders

Number of best and worst queries to included with the report, in terms of
overall duration of execution. Enough log information is listed along with the
duration such that tracking down the original query (not the canonized
version) is straightforward. The offenders list can be very useful for a query
that is causing trouble in a handful of permutations, but most of the time is
behaving well.

The list in conjunction with standard deviation gives an overall indication of
performance volatility.

--offenders=5 produces additional output in the report that looks something
like the following example:

 Best
   1. 2009-01-12T10:11:49-07:00 db1 postgres[4692] -- 4.833 ms
   2. 2009-01-12T10:31:19-07:00 db1 postgres[1937] -- 4.849 ms
   3. 2009-01-12T09:16:20-07:00 db1 postgres[20294] -- 4.864 ms
   4. 2009-01-12T10:16:54-07:00 db1 postgres[20955] -- 4.867 ms
   5. 2009-01-12T10:32:16-07:00 db1 postgres[5010] -- 4.871 ms

 Worst
   1. 2009-01-12T10:00:07-07:00 db1 postgres[2804] -- 2175.650 ms
   2. 2009-01-12T09:30:07-07:00 db1 postgres[2804] -- 2090.914 ms
   3. 2009-01-12T10:00:18-07:00 db1 postgres[2804] -- 2046.608 ms
   4. 2009-01-12T09:30:10-07:00 db1 postgres[2804] -- 1954.604 ms
   5. 2009-01-12T11:20:11-07:00 db1 postgres[2804] -- 1788.576 ms

=back

=head1 BUGS

=over

=item *

If queries contain exceptionally long IN lists, the regex that attempts to
flatten them can run into a perl recursion limit. In that event, the query will
keep the placeholders of the IN list, making it unique compared to the same
query with a different cardinality of list params in the same IN. This
deficiency should only surface on IN lists with composite parameters [e.g., IN
((?,?,...,?),(?,?,...,?),...,(?,?,...,?))]. For scalar IN lists, there should
be no such limit.

=back

=head1 AUTHOR

Original code:
    Mark Johnson (mark@endpoint.com), End Point Corp.

Contributions:
    Ethan Rowe (ethan@endpoint.com), End Point Corp.

=head1 LICENSE AND COPYRIGHT

Copyright 2008-2009 Mark Johnson (mark@endpoint.com)

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself. See the LICENSE file.

=cut
