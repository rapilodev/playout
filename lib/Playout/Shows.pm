package Shows;

use strict;
use warnings;

use Data::Dumper;
use Playout::Time();
use Playout::MediaFiles();

my $startUpDuration = 0;

sub setStartUpDuration {
    $startUpDuration = shift;
    return;
}

sub getStartUpDuration {
    return $startUpDuration;
}

# get last known show that's running or over
# within time range from yesterday till tomorrow
# result contains a pointer to the previous and next show
# if no show is running currently reuslt will contain pointer to next show only
sub getRunning {
    Log::header("Shows::getRunning()");

    my $datetime_utc = Time::getUtcDatetime();

    my $today     = Time::getToday($datetime_utc);
    my $prev_date = Time::getYesterday($datetime_utc);
    my $next_date = Time::getTomorrow($datetime_utc);
    Log::debug( 1, "today " . $today );

    my $dates = [ $prev_date, $today, $next_date ];

    # get audio files from yesterday, today and tomorrow
    my @files = ();
    for my $date (@$dates) {
        my $found_files = MediaFiles::getFilesByDate($date);

        #order by date
        for my $file ( sort keys %$found_files ) {
            push @files, $found_files->{$file};
        }
    }

    if ( @files == 0 ) {
        Log::debug( 1, "no files found!" );
        return {};
    }
    Log::debug( 4, "all files found: " . Dumper( \@files ) );

    # get last file running, do not
    my $now           = Time::getTodaysDateTime($datetime_utc);
    my $current_index = undef;
    my $c             = 0;
    for my $file (@files) {
        if ( ( defined $file->{start} ) && ( $file->{start} le $now ) ) {
            $current_index = $c;
        } else {
            last;
        }
        $c++;
    }
    Log::debug( 4, "current files found: $current_index " . Dumper( \@files ) ) if defined $current_index;
    return $files[$current_index] if defined $current_index;

    #return reference to next show if currently no show is playing
    return { next => $files[0]->{file} };
}

# get previous show from schedule
sub getPrevious {
    my $show = shift;
    return undef unless defined $show;
    return undef unless defined $show->{prev};
    return MediaFiles::get( $show->{prev} );
}

# get next show from schedule
sub getNext {
    my $show = shift;
    return undef unless defined $show;
    return undef unless defined $show->{next};
    return MediaFiles::get( $show->{next} );
}

# get schedule status (isRunning, isOver, isNotStartedYet)
# provides start, end (UTC datetime objects)
# audioDuration, scheduleDuration
# provides additionally: runDuration, timeTillSwitch, timeTillEnd (in seconds)
sub getStatus {
    my $show = shift;

    return unless defined $show;
    return unless defined $show->{start};

    Log::header("Shows::getStatus()");
    Log::debug( 2, 'PREV: "' . ( $show->{prev} || '' ) . '"' );
    Log::debug( 2, 'CURR: "' . ( $show->{file} || '' ) . '"' );
    Log::debug( 2, 'NEXT: "' . ( $show->{next} || '' ) . '"' );

    my $next   = getNext($show);
    my $start  = $show->{start};
    my $result = {};

    #get utc datetime
    my $now = Time::getUtcDatetime();

    $now->add( seconds => $startUpDuration ) if $startUpDuration != 0;
    return unless defined $now;

    my $start_time = Time::getUtcDatetime($start);
    return unless defined $start_time;

    my $audioDuration = $show->{duration};
    unless (defined $audioDuration){
        Log::error("missing duration for $show->{file}");
        return undef;
    }
    my $audio_end_time = Time::getUtcDatetime($start)->add( seconds => $audioDuration );

    my $end = '';
    $end = $next->{start} if defined $next;
    my $end_time = $audio_end_time;
    if ( $end ne '' ) {
        Log::debug( 2, "end: $end" );
        $end_time = Time::getUtcDatetime($end);
        my $gap = $end_time->subtract_datetime($audio_end_time);
        $gap = Time::durationToSeconds($gap);
        $result->{overlap} = -$gap;
        if ( $gap < 0 ) {
            Log::warn(
                qq{audio file "$show->{file}" - overlaps start of next show by } . Time::secondsToTime( -$gap ) );
            $end_time = Time::getUtcDatetime($end);
        }
        if ( $gap > 0 ) {
            Log::warn( qq{audio file "$show->{file}" - gap after show: } . Time::secondsToTime($gap) )
              if $gap < 4 * Time::getHourDef();
            $end_time = Time::getUtcDatetime($end);
        }
    }
    unless (defined $end_time){
        Log::error("missing duration for $show->{file}");
        return undef;
    };

    # calc duration of schedule
    my $scheduleDuration = $end_time->subtract_datetime($start_time);
    $scheduleDuration = Time::durationToSeconds($scheduleDuration);

    Log::debug(
        2, qq{
show UTC now           $now
show UTC start         $start_time
show UTC end           $end_time
show UTC audio end     } . ($audio_end_time) . qq{
show audio duration    } . sprintf( "%.2f minutes, %.2f seconds", $audioDuration / 60, $audioDuration ) . q{
show schedule duration } . sprintf( "%.2f minutes, %.2f seconds", $scheduleDuration / 60, $scheduleDuration ), 'magenta'
    );

    $result->{start}            = $start_time;
    $result->{end}              = $end_time;
    $result->{now}              = $now;
    $result->{audioDuration}    = $audioDuration;
    $result->{scheduleDuration} = $scheduleDuration;

    # running since
    my $runDuration = $now->subtract_datetime($start_time);
    $result->{runDuration}   = Time::durationToSecondsWithMillis($runDuration);
    $result->{timeTillStart} = -$result->{runDuration};

    # when comes next
    my $timeTillSwitch = $end_time->subtract_datetime($now);
    $result->{timeTillSwitch} = Time::durationToSecondsWithMillis($timeTillSwitch);

    my $timeTillEnd = $audio_end_time->subtract_datetime($now);
    $result->{timeTillEnd} = Time::durationToSecondsWithMillis($timeTillEnd);

    my $info = "start:$result->{runDuration} end:$result->{timeTillEnd} switch:$result->{timeTillSwitch}";

    #exit on invalid time range
    if ( $scheduleDuration <= 0 ) {
        Log::warn("WARNING: invalid time range. $info");
        $result->{isError} = 1;
        return $result;
    }

    if ( $now . '' ge $end_time . '' ) {
        Log::debug( 2, "show is over. $info" );
        $result->{isOver} = 1;
        return $result;
    }

    if ( $now . '' gt $audio_end_time . '' ) {
        Log::debug( 2, "show is over. $info" );
        $result->{isOver} = 1;
        return $result;
    }

    #exit with original file if nothing to do
    if ( $now . '' lt $start_time . '' ) {
        Log::debug( 2, "show has not started yet. $info" );
        $result->{isNotStartedYet} = 1;
        return $result;
    }

    $result->{isRunning} = 1;
    Log::debug( 2, "show is running. $info" );

    return $result;
}

sub getNextStart {
    my $now = Time::getUtcDatetime();

    # try current
    my $running = getRunning();
    return undef unless defined $running;
    return undef unless defined $running->{start};
    my $start_time  = Time::getUtcDatetime( $running->{start} );
    my $timeToStart = $start_time->subtract_datetime($now)->seconds;
    return $running->{start_epoch} if $timeToStart > 0;

    # try next
    my $next = getNext($running);
    return undef unless defined $next;
    return undef unless defined $next->{start};
    $start_time  = Time::getUtcDatetime( $next->{start} );
    $timeToStart = $start_time->subtract_datetime($now)->seconds;
    return $next->{start_epoch};
}

sub show {
    my $show = shift;
    return '-' unless defined $show;
    return '-' unless defined $show->{start};
    return sprintf( qq{"%s" "%s" "%s"}, $show->{start}, Time::secondsToTime( $show->{duration} ), $show->{name} );
}

# do not delete last line
1;
