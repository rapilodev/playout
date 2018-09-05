package Upload;

use warnings;
use strict;
use JSON();
use LWP::UserAgent();
use Date::Calc();
use Data::Dumper;
use HTTP::Request();

use Playout::Log();
use Playout::Time();
use Playout::MediaFiles();

my $url = undef;

# get upload URL
sub getUrl {
    return $url;
}

# set upload URL
sub setUrl {
    $url = shift;
}

# upload yesterday to tomorrow
sub shortUpload {
    my $url = getUrl();
    return unless defined $url;

    Log::info("upload current shows to $url");

    my $datetime_utc = Time::getUtcDatetime();
    my $today        = Time::getToday($datetime_utc);
    my $prev_date    = Time::getYesterday($datetime_utc);
    my $next_date    = Time::getTomorrow($datetime_utc);

    my $dates = [ $prev_date, $today, $next_date ];
    upload($dates);
}

# upload all shows
sub fullUpload {
    my $url = getUrl();
    return unless defined $url;

    Log::info("upload all shows to $url");

    my $dates = MediaFiles::getDates();
    upload($dates);
}

# upload events (start, duration, file) for a given list of dates
sub upload {
    my $dates = shift;

    my $events = [];
    for my $date ( sort @$dates ) {
        my $found_files = MediaFiles::getFilesByDate($date);

        #order by date
        for my $file ( sort keys %$found_files ) {
            my $event = $found_files->{$file};

            push @$events,
              {
                start           => $event->{start},
                duration        => $event->{duration},
                file            => $event->{file},
                channels        => $event->{channels},
                "format"        => $event->{"format"},
                format_version  => $event->{format_version},
                format_profile  => $event->{format_profile},
                format_settings => $event->{format_settings},
                stream_size     => $event->{stream_size},
                bitrate         => $event->{bitrate},
                bitrate_mode    => $event->{bitrate_mode},
                sampling_rate   => $event->{sampling_rate},
                writing_library => $event->{writing_library},
                rms_left        => $event->{rms_left},
                rms_right       => $event->{rms_right},
                rms_image       => $event->{rms_image},
                replay_gain     => $event->{replay_gain},
                errors          => $event->{errors}
              };
        }
    }

    my @events = sort { $a->{start} cmp $b->{start} } @$events;
    $events = \@events;

    # start of first event
    my $from = $events->[0]->{start};

    # end of last event
    my $end = $events->[-1];
    my $till = addSeconds( $end->{start}, $end->{duration} );

    # build document
    my $document = {
        from   => $from,
        till   => $till,
        events => $events
    };

    # encode json
    my $json = JSON::to_json($document);

    #my $json = encode_json($document);
    Log::debug( 0, $json );
    print STDERR $json . "\n";

    # send json to upload URL
    my $ua = LWP::UserAgent->new;
    my $request = HTTP::Request->new( POST => $url );
    $request->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $request->content($json);
    my $response = $ua->request($request);

    print $response->decoded_content;

    if ( $response->is_success ) {
        Log::info( $response->decoded_content );
    } else {
        Log::warn( $response->status_line );
    }
}

# add seconds
sub addSeconds {
    my $start    = shift;
    my $duration = shift;

    my @start = ();
    if ( $start =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)[ T](\d\d):(\d\d)\:(\d\d)/ ) {
        my $year   = $1;
        my $month  = $2;
        my $day    = $3;
        my $hour   = $4;
        my $minute = $5;
        my $second = $6;
        @start = ( $year, $month, $day, $hour, $minute, $second );
    }
    return undef unless @start >= 6;
    my @end = Date::Calc::Add_Delta_DHMS(
        $start[0], $start[1], $start[2],    # start date
        $start[3], $start[4], $start[5],    # start time
        0, 0, 0, $duration                  # delta days, hours, minutes, seconds
    );
    return sprintf( "%4d-%02d-%02d %02d:%02d:%02d", @end );
}

# do not delete last line
1;
