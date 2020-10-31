#!/usr/bin/perl

use warnings;
use strict;

use Config::General();
use Cwd();
use Data::Dumper;
use DateTime();
use DateTime::Format::Strptime ( );
use File::Find();
use Getopt::Long();
use JSON();
use HTTP::Request();
use LWP::UserAgent();
use FindBin;
chdir $FindBin::Bin;

use utf8;
use feature "say";
use open ':std', ':encoding(UTF-8)';

# * get schedule and files using calcms
# * build playout schedule file fo the next week 
#
# config file 
# * required by --config <filename>
# * config syntax follows playout_sync.pl,
# * plus streamTarget containing liquidsoap icecast stream config
#
# <config>
#     mediaDir            /mnt/archive/<stream>/
#     timeZone            Europe/Berlin
#     syncGetScheduleUrl  https://<domain>/agenda/events.cgi?recordings=1&template=json-p
#     syncGetRecordingUrl https://<domain>/agenda_files/recordings/
#     syncImageSourceUrl  https://<domain>/agenda_files/media/images/
#     streamTarget        host="localhost", port=8000, user="liquidsoap", password="changeme", mount="/<stream>"
# </config>


# one instance only
use Fcntl qw(:flock);
open our $file, '<', $0 or die $!;
flock $file, LOCK_EX|LOCK_NB or die "skip start, script is already running\n.";

# stop after 7 days to reload
my $DAYS = 24 * 60 * 60;
alarm 7 * $DAYS;

sub get_date_time {
    my $time = time;
    ( my $sec, my $min, my $hour, my $day, my $month, my $year ) = localtime($time);
    return sprintf(
        "%4d-%02d-%02d %02d:%02d:%02d.%03d",
        $year + 1900,
        $month + 1, $day, $hour, $min, $sec, ( $time - int($time) ) * 1000
    );
}

sub get_events {
    my $url = shift;

    print get_date_time() . " ---INFO--- fetch events from $url\n";
    my $ua       = LWP::UserAgent->new();
    my $response = $ua->get($url);
    my $doc;
    if ( $response->is_success ) {
        $doc = $response->decoded_content;
    } else {
        die $response->status_line;
    }
    return JSON::decode_json($doc)->{events};
}

sub filter_events {
    my $events = shift;

    my $format = DateTime::Format::Strptime->new(
        pattern   => '%Y-%m-%d %H:%M:%S',
        time_zone => 'local',
        on_error  => 'croak',
    );

    my $entries = [];
    for my $event (@$events) {
        my $end      = $format->parse_datetime( $event->{end} );
        my $start    = $format->parse_datetime( $event->{start} );
        my $duration = $start - $end;
        my $entry    = {
            start_date    => $event->{start_date},
            start_time    => $event->{start_time},
            start_weekday => $start->day_of_week,
            end_date      => $event->{end_date},
            end_time      => $event->{end_time},
            end_weekday   => $end->day_of_week,
            start         => $event->{start},
            end           => $event->{end},
            series_name   => $event->{series_name},
            episode       => $event->{episode},
            duration      => $duration->in_units("minutes"),
            full_title    => $event->{full_title}
        };
        push @$entries, $entry;
    }
    return $entries;
}

sub get_files {
    my $dirs  = shift;
    my $files = [];

    File::Find::find(
        sub {
            my $file = $File::Find::name;
            if ( !-f $file ) {
                return;
            } elsif ( $file =~ /\.(mp3|flac|wav|ogg)$/ ) {
                push @$files, $file;
                return;
            }
        },
        @$dirs
    );
    return $files;
}

sub find_file($$$) {
    my $entry = shift;
    my $dirs  = shift;
    my $files = shift;

    if ( $entry->{start} =~ /(\d\d\d\d)\-(\d\d)\-(\d\d) (\d\d)\:(\d\d)/ ) {
        my $prefix = $1 . '/' . $2 . '/' . $3 . '/' . $4 . '-' . $5 . '/';
        for my $dir (@$dirs) {
            my $prefix = $dir . '/' . $prefix;
            $prefix =~ s!/+!/!g;
            for my $file ( sort @$files ) {
                return $file if index( $file, $prefix ) != -1;
            }
        }
    }

    warn get_date_time() . " --WARNING- no file found for $entry->{full_title}\n";
    return undef;
}

sub get_script($$$$) {
    my $entries = shift;
    my $dirs    = shift;
    my $files   = shift;
    my $icecast = shift;

    my @shows  = ();
    my $active = 0;
    for my $entry (@$entries) {
        my $title = $entry->{series_name} . " " . $entry->{episode};
        $title =~ s/\"//g;
        my $file = find_file( $entry, $dirs, $files );
        my ( $sh, $sm ) = split( /\:/, $entry->{start_time}, 2 );
        my ( $eh, $em ) = split( /\:/, $entry->{end_time},   2 );
        push @shows, sprintf "%s%s ( { %dw%dh%dm%ds-%dw%dh%dm%ds }, %s )\n",
          $active && $file ? ', ' : '  ',
          $file            ? ' '  : '#',
          $entry->{start_weekday}, $sh, $sm, 0,
          $entry->{end_weekday},   $eh, $em, 0,
          $file ? qq{single("$file")} : qq{say("$title")};
        $active++ if $file;
    }

    my $shows = join '', @shows;
    return qq{
        radio = switch(
            [
$shows
            ]
        );
        radio = mksafe (radio);

        radio= fallback(
            id="fallback",
            track_sensitive=false,
            [
                fail(),
                strip_blank(id="silence", max_blank=60., threshold=-50., radio ) ,
                mksafe(single(id="silence", "fallback.mp3"))
            ]
        )

        output.icecast(
            %mp3(bitrate=192),
            $icecast,
            radio
        );
    };
}

sub execute($) {
    my $command = shift;
    print get_date_time() . " ---INFO--- execute: " . join( " ", @$command ) . "\n";
    system(@$command);
}

my $config_file = undef;
Getopt::Long::GetOptions( "config=s" => \$config_file );
die "missing --config " unless $config_file;
die "cannot read from $config_file" unless -r $config_file;
my $config = Config::General->new($config_file)->{DefaultConfig}->{config};
die "could not read config from $config_file" unless $config;

# date now or from command line yyyy-mm-dd
my $date = DateTime->now( time_zone => 'local' )->subtract( days => 1 );
$date = DateTime::Format::Strptime->new(
    pattern   => '%Y-%m-%d',
    time_zone => 'local',
    on_error  => 'croak',
)->parse_datetime( $ARGV[0] )
  if scalar(@ARGV) > 0;
my $from_date = $date->ymd();
my $till_date = $date->add( weeks => 1 )->ymd();

my $url     = $config->{syncGetScheduleUrl} . qq{&from_date=$from_date&till_date=$till_date};
my $dirs    = [ $config->{mediaDir} or die "missing mediaDir in config" ];
my $icecast = $config->{streamTarget} or die "missing streamTarget in config";

# get audio files from server
execute( [ "playout_sync.pl", "--config", "$config_file" ] );

# get events from server
my $events = get_events($url);
my $slots  = filter_events($events);
#
my $files  = get_files($dirs);
my $script = get_script( $slots, $dirs, $files, $icecast );

# save script
my $script_name = 'replay.liq';
open my $fh, '>', $script_name;
print $fh $script;
close $fh;

# start script
execute( [ "liquidsoap", $script_name ] );
