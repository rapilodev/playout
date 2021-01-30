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

use Playout::Playout();
use Playout::MediaFiles();
use Playout::Upload();

use utf8;
use feature "say";
use open ':std', ':encoding(UTF-8)';

# * sync audio files by using playout_sync.pl
# * build schedule for the next week and play it using liquidsoap
#
# config file
# * required by --config <filename>
# * config syntax follows playout_sync.pl,
# * plus streamTarget containing liquidsoap icecast stream config
#
# <config>
#     mediaDir            /mnt/archive/<project>/
#     tempDir             /var/tmp/
#     timeZone            Europe/Berlin
#     syncGetScheduleUrl  https://<domain>/agenda/all-events.cgi?project_id=x&studio_id=y&recordings=1&template=json-p
#     syncGetRecordingUrl https://<domain>/agenda_files/recordings/
#     syncImageSourceUrl  https://<domain>/agenda_files/media/images/
#     streamTarget        host="localhost", port=8000, user="liquidsoap", password="changeme", mount="/<stream>"
#     fallback            /mnt/archive/<project>/fallback.mp3
# optional:
#     syncGetRecordingAccess  user:password
#     syncSetScheduleUrl  https://<domain>/agenda/upload_playout.cgi?project_id=x&studio_id=y
#     syncPlotTargetDir   user@<domain>:<dir>/
#     syncImageSourceUrl  https://<domain>/agenda_files/media/images/
# </config>

my $started;

# one instance only
use Fcntl qw(:flock);
open our $file, '<', $0 or die $!;
flock $file, LOCK_EX|LOCK_NB or die "skip start, script is already running.\n";

$started++;
END{
    system("pkill -f replay.liq") if $started;
}
system("pkill -f replay.liq");

# run script for one week
my $DAYS = 24 * 60 * 60;
alarm 7 * $DAYS;

sub get_script($$) {
    my $icecast  = shift;
    my $fallback = shift;

    my $format = DateTime::Format::Strptime->new(
        pattern   => '%Y-%m-%d %H:%M:%S',
        time_zone => 'local',
        on_error  => 'croak',
    );

    my @shows  = ();
    my $first = 1;
    my $done   = {};

    my $date = DateTime->now ( time_zone => 'local')->subtract(days => 1);
    for (0..7){
        $date->add( days => 1 );
        my $files = MediaFiles::getFilesByDate($date->ymd);

        for my $file (
            sort { $files->{$a}->{start} cmp $files->{$b}->{start} }
            keys %$files
        ){
            my $event = $files->{$file};
            my $start = $format->parse_datetime( $event->{start} );
            my $end   = $start->clone->add( seconds => $event->{duration} );
            push @shows, sprintf("%s ( { %dw%dh%dm%ds-%dw%dh%dm%ds }, single(\"%s\") )\n",
                $first ? '  ' : ', ',
                $start->wday, $start->hour, $start->minute, 0,
                $end->wday,   $end->hour,   $end->minute,   0,
                $event->{file}
            );
            $first=0;
        }
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
                mksafe(single(id="silence", "$fallback"))
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
    print DateTime->now()->datetime . " ---INFO--- execute: " . join( " ", @$command ) . "\n";
    system(@$command);
}

my $config_file = undef;
Getopt::Long::GetOptions( "config=s" => \$config_file );
die "missing --config " unless $config_file;
die "cannot read from $config_file" unless -r $config_file;
my $config = Config::General->new($config_file)->{DefaultConfig}->{config};
die "could not read config from $config_file" unless $config;

my $dirs    = [ $config->{mediaDir} or die "missing mediaDir in config" ];
my $icecast = $config->{streamTarget} or die "missing streamTarget in config";

# get audio files from server
my $from = DateTime->now()->subtract( days=>1 )->ymd;
my $till = DateTime->now()->add( days=>7 )->ymd;
execute([ "playout_sync.pl",
    "--config", "$config_file",
    "--from", $from,
    "--till", $till
]);

# scan files and upload playout entries
Playout::init({ configFile => $config_file});
my $updateAudio = MediaFiles::fullScan({
#    maxProcessing => 1,
    expires       => [ time + 15 * 60, Shows::getNextStart() ]
});
Upload::fullUpload() if $updateAudio > 0;

# save script
my $script_name = 'replay.liq';
open my $fh, '>', $script_name or die "$!";
print $fh get_script( $icecast, $config->{fallback} );
close $fh;

# start script
my $liquidsoap = qx{which liquidsoap};
chomp $liquidsoap;
execute( [ $liquidsoap, $script_name ] );
