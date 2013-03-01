use ExtUtils::MakeMaker;
use strict;
use warnings;
use 5.008003;

my $VERSION = '1.7.2';

WriteMakefile(
    NAME          => 'pgsi',
    VERSION_FROM  => 'pgsi.pl',
    PREREQ_PM     => {
                     'Test::More'          => '0.61',
                     'Test::Harness'       => '2.03',
                     'IO::Handle'          => '1.24',
                  },
    EXE_FILES     => ['pgsi.pl'],
    ABSTRACT      => 'Postgres system impact report',
    AUTHOR        => 'Mark Johnson <mark@endpoint.com>',
    LICENSE       => 'BSD',
    NO_META       => 1,
    NEEDS_LINKING => 0,
    NORECURS      => 1,
    PM            => { },
    clean         => { FILES => '*~ tmp/* test.pg.log pgsi.html' },
);

package MY;

sub manifypods {
    my $after = qq{\t\$(NOECHO) pod2html pgsi.pl > pgsi.html\n};
    $after .= qq{\t\$(NOECHO) \$(RM_F) pod*.tmp pm_to_blib\n};
    $after .= qq{\t\$(NOECHO) \$(PERL) -pi -e "s/<link.*?>//" pgsi.html\n};
    $after .= qq{\t\$(NOECHO) \$(ECHO) Created pgsi.html\n};
    return shift->SUPER::manifypods(@_) . $after;
}

