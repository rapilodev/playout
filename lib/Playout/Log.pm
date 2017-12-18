package Log;

use warnings;
use strict;
use Term::ANSIColor;
use Time::HiRes qw(time);

# debug level [0..]
our $debug = 0;

our $logFile = '/var/log/playout/playout.log';

sub setLogFile {
    $logFile = shift;
}

sub getLogFile {
    return $logFile;
}

# output debug if level greater than current debug level
sub debug($$;$) {
    my $level   = $_[0];
    my $message = $_[1];
    my $color   = $_[2];

    my $color2=$color||'';
    #print STDERR "debug '$level','$message','$color2'\n";

    return if $debug == 0;
    return unless $debug > $level;

    print color $color if defined $color;

    my $date = getDateTime();
    for my $line ( split /\n/, $message ) {
        print "$date --DEBUG-- $level\t$line\n";
    }

    print color 'reset' if defined $color;
}

# same as debug but print plain line without date and level.
sub debugPlain($$) {
    my $level = $_[0];
    return if $debug == 0;
    print $_[1] if ( $debug > $level );
}

# print info
sub info($) {
    return if $debug == 0;
    my $date = getDateTime();
    for my $line ( split /\n/, $_[0] ) {
        print "$date --INFO--- " . $line . "\n";
    }
}

# print method header (for debug level > 1)
sub header($) {
    return unless ( $debug > 1 );
    my $date = getDateTime();
    print color 'blue';
    print "$date --enter-- " . $_[0] . "\n";
    print color 'reset';
}

# print error
sub error($) {
    my $date = getDateTime();
    print color 'red';
    print "$date --ERROR-- " . $_[0] . "\n";
    print color 'reset';
}

# print execution command
sub exec($) {
    return if $debug == 0;
    my $date = getDateTime();
    print "$date --EXEC--- " . $_[0] . "\n";
}

# print warning
sub warn($) {
    my $date = getDateTime();
    print "$date --WARN--- " . $_[0] . "\n";
}

# dump object
sub object {
    my $level=shift;
    my $entry = shift;
    my $depth = shift || 0;

    return if $debug == 0;
    return unless $debug > $level;

    my $date = getDateTime();

    my $line = '';
    if ( ref($entry) eq 'SCALAR' ) {
        $line .= "$date --OBJECT- $level   $entry\n";
    }
    if ( ref($entry) eq 'HASH' ) {
        for my $key ( keys %$entry ) {
            $line .= sprintf( "$date --entry-- $level  %-18s = %s\n", $key, $entry->{$key} );
        }
    }
    if ( ref($entry) eq 'ARRAY' ) {
        my $i = 0;
        for my $value (@$entry) {
            $line .= "$date --OBJECT- $level   [$i] : \n";
            $line .= object( $level, $value, $depth + 1 );
            $i++;
        }
    }
    print $line if $depth == 0;
    return $line;
}

sub objectInline {
    my $level=shift;
    my $entry = shift;
    my $depth = shift || 0;

    return if $debug == 0;
    return unless $debug > $level;

    my $date  = getDateTime();

    my $line = '';
    if ( ref($entry) eq 'SCALAR' ) {
        $line .= $entry;
    }
    if ( ref($entry) eq 'HASH' ) {
        $line .= "{" . join( ", ", map { sprintf( "%s=%s", $_, $entry->{$_} ) } ( keys %$entry ) ) . '}';
    }
    if ( ref($entry) eq 'ARRAY' ) {
        my $i = 0;
        for my $value (@$entry) {
            $line .= "," if $i > 0;
            $line .= "[$i] : \n";
            $line .= objectInline( $level, $value, $depth + 1 );
            $i++;
        }
    }
    print "$date --OBJECT- $level     " . $line . "\n" if $depth == 0;
    return $line;
}

sub getDateTime {
    my $time = time;
    ( my $sec, my $min, my $hour, my $day, my $month, my $year ) = localtime($time);
    return sprintf(
        "%4d-%02d-%02d %02d:%02d:%02d.%03d",
        $year + 1900,
        $month + 1, $day, $hour, $min, $sec, ( $time - int($time) ) * 1000
    );
}

sub setLevel {
    $Log::debug = shift || 0;
}

sub getLevel {
    return $Log::debug;
}

sub openLog {
    my $oldDebug = $debug;
    $debug = 1;
    if ( -e $logFile ) {
        info("reopen log '$logFile'\n");
        open( STDOUT, ">>" . $logFile ) or die "cannot open log file '$logFile'";
        info("reopened log '$logFile'\n");
    } else {
        info("open logfile '$logFile'\n");
        open( STDOUT, ">" . $logFile ) or die "cannot open log file '$logFile'";
        info("opened logfile '$logFile'\n");
    }
    $debug = $oldDebug;
    open STDERR, '>&STDOUT' or die "Can't dup STDOUT: $!";
}

# do not delete last line
1;

