package Time;

use warnings;
use strict;

use Time::HiRes qw(time);
use DateTime();
use Date::Calc qw(check_date check_time);

use Playout::Log();

#time presets
my $sec  = 1.0;
my $min  = 60.0 * $sec;
my $hour = 60.0 * $min;
my $day  = 24.0 * $hour;
my $timeZone = undef;

sub setTimeZone {
    $timeZone = shift;
    return;
}

sub getTimeZone {
    return $timeZone;
}

sub getHourDef{
    return $hour;
}

# convert a time into a human readable format
sub formatDuration {
    my $time = shift;
    my $s    = '';
    if ( $time < 0 ) {
        $s = ' since ';
        $time *= -1;
    }

    if ( $time > $day ) {
        my $days = int( $time / $day );
        $time -= $days * $day;
        $s .= $days . " day ";
    }
    if ( $time > $hour ) {
        my $hours = int( $time / $hour );
        $time -= $hours * $hour;
        $s .= $hours . " hours ";
    }
    if ( $time > $min ) {
        my $mins = int( $time / $min );
        $time -= $mins * $min;
        $s .= $mins . " min ";
    }
    $s .= sprintf( "%.02f", $time ) . " secs";

    $s .= "\t" if ( length($s) < 5 );
    return $s;
}

sub secondsToTime {
    my $time = shift;
    if ( $time < 0 ) {
        $time *= -1;
    }
    my $days = 0;
    if ( $time > $day ) {
        $days = int( $time / $day );
        $time -= $days * $day;
    }
    my $hours = 0;
    if ( $time >= $hour ) {
        $hours = int( $time / $hour );
        $time -= $hours * $hour;
    }
    my $mins = 0;
    if ( $time >= $min ) {
        $mins = int( $time / $min );
        $time -= $mins * $min;
    }
    return sprintf( "%d days %02d:%02d:%02d", $days, $hours, $mins, $time ) if $days > 0;
    return sprintf( "%02d:%02d:%02d", $hours, $mins, $time ) if $hours > 0;
    return sprintf( "%02d:%02d", $mins, $time );

}

sub datetimeToPath {
    my $mediaDir = shift;
    my $datetime = shift;

    if ( $datetime =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)[ T](\d\d)\:(\d\d)\:(\d\d)/ ) {
        my $path = $mediaDir . '/' . $1 . '/' . $2 . '/' . $3 . '/' . $4 . '-' . $5 . '/';
        $path =~ s/\/+/\//g;
        return $path;
    }
    return undef;
}

# get datetime string for a file at media
sub pathToDatetime {
    my $mediaDir = shift;
    my $path     = shift;

    if ( $path =~ /$mediaDir\/?(\d\d\d\d)\/(\d\d)\/(\d\d)\/(\d\d)\-(\d\d)\// ) {
        my $year   = $1;
        my $month  = $2;
        my $day    = $3;
        my $hour   = $4;
        my $minute = $5;
        my $second = '00';
        unless ( check_date( $year, $month, $day ) ) {
            Log::error("Time::getUtcDatetime($year-$month-$day): invalid date in file $path");
            return undef;
        }
        unless ( check_time( $hour, $minute, $second ) ) {
            Log::error("Time::getUtcDatetime($hour:$minute:$second): invalid time in file $path");
            return undef;
        }
        return sprintf( "%04d-%02d-%02d %02d:%02d:%02d", $year, $month, $day, $hour, $minute, $second );
    }
    return undef;
}

# get date string from file path
sub pathToDate {
    my $mediaDir = shift;
    my $path     = shift;

    if ( $path =~ /$mediaDir\/?(\d\d\d\d)\/(\d\d)\/(\d\d)\/\d\d\-\d\d\// ) {
        my $year  = $1;
        my $month = $2;
        my $day   = $3;

        unless ( check_date( $year, $month, $day ) ) {
            Log::error("Time::pathToDate($year-$month-$day): invalid date in file $path");
            return undef;
        }
        return sprintf( "%04d-%02d-%02d", $year, $month, $day );
    }
    return undef;
}

# format unix time to date time string
sub timeToDatetime {
    my $time = shift;
    ( my $sec, my $min, my $hour, my $day, my $month, my $year ) = localtime($time);
    my $datetime = sprintf( "%4d-%02d-%02d %02d:%02d:%02d", $year + 1900, $month + 1, $day, $hour, $min, $sec );
    return $datetime;
}

# get datetime in UTC from given datetime string
# returns current time if no parameter is passed
# UTC is used for date/time calculations,
# see http://search.cpan.org/dist/DateTime/lib/DateTime.pm#How_Datetime_Math_Works
sub getUtcDatetime {
    my $datetime = shift;

    unless ( defined $datetime ) {
        my $now = DateTime->now( time_zone => $timeZone );
        my $nanoseconds = time;
        $nanoseconds = int( 1000000000 * ( $nanoseconds - int($nanoseconds) ) );
        $now->set_nanosecond($nanoseconds);
        $now->set_time_zone('UTC');
        return $now;
    }

    #print $datetime."\n";
    if ( $datetime =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)[ T](\d\d)\:(\d\d)(\:(\d\d))?/ ) {
        my $year   = $1;
        my $month  = $2;
        my $day    = $3;
        my $hour   = $4;
        my $minute = $5;
        my $second = $7 || '0';

        unless ( check_date( $year, $month, $day ) ) {
            Log::error("Time::getUtcDatetime($datetime): invalid date");
            return undef;
        }
        unless ( check_time( $hour, $minute, $second ) ) {
            Log::error("Time::getUtcDatetime($datetime): invalid time");
            return undef;
        }

        return eval {
            my $dt = DateTime->new(
                year      => $year,
                month     => $month,
                day       => $day,
                hour      => $hour,
                minute    => $minute,
                second    => $second,
                time_zone => $timeZone
            );
            $dt->set_time_zone('UTC');
            return $dt;
        };
    }

    Log::warn("could not parse date :'$datetime'!");
    return undef;
}

#get datetime duration in seconds
sub durationToSeconds {
    my $duration = shift;
    my %values   = $duration->deltas();
    my $value    = $values{seconds};
    $value += $values{minutes} * 60;
    $value += $values{days} * 24 * 60 * 60;
    return $value;
}

sub durationToSecondsWithMillis {
    my $duration = shift;
    my %values   = $duration->deltas();
    my $value    = $values{seconds};
    $value += $values{minutes} * 60;
    $value += $values{days} * 24 * 60 * 60;
    $value += $values{nanoseconds} / 1000000000;
    return $value;
}

# get datetime string from utc
sub getTodaysDateTime {
    my $dt = shift;
    return $dt->clone()->set_time_zone($timeZone)->strftime('%Y-%m-%d %T');
}

# get todays date string from utc
sub getToday {
    my $dt = shift;
    return $dt->clone()->set_time_zone($timeZone)->strftime('%Y-%m-%d');
}

# get tomorrows date string from utc
sub getTomorrow {
    my $dt = shift;
    return $dt->clone()->add( days => 1 )->set_time_zone($timeZone)->strftime('%Y-%m-%d');
}

# get yesterdays date string from utc
sub getYesterday {
    my $dt = shift;
    return $dt->clone()->subtract( days => 1 )->set_time_zone($timeZone)->strftime('%Y-%m-%d');
}

# convert date time string to unix time in seconds
sub datetimeToUnixTime {
    my $datetime = shift;
    unless ( defined $datetime ) {
        Log::error("Time::datetime_to_time(): no valid date time found!");
        return -1;
    }

    if ( $datetime =~ /(\d\d\d\d)\-(\d+)\-(\d+)[T\s](\d+)\:(\d+)(\:(\d+))?/ ) {
        my $year   = $1;
        my $month  = $2;
        my $day    = $3;
        my $hour   = $4;
        my $minute = $5;
        my $second = $7 || '0';

        unless ( check_date( $year, $month, $day ) ) {
            Log::error("Time::datetimeToUnixTime($datetime): invalid date");
            return undef;
        }
        unless ( check_time( $hour, $minute, $second ) ) {
            Log::error("Time::datetimeToUnixTime($datetime): invalid time");
            return undef;
        }

        my $epoch = Time::Local::timelocal( $second, $minute, $hour, $day, $month - 1, $year );
        return $epoch;

    } else {
        Log::error("Time::datetime_to_time($datetime): no valid date time found!");
        return -1;
    }
}

# do not delete the last line
1;
