package Playout;

=head1 NAME

playout - scheduled play out of audio file

=head1 DESCRIPTION

playout is a service to play out audio files at given date and time.
To schedule a single file, put it to a directory /<mediaDir>/yyyy/mm/dd/hh-mm/.

It is useful on scheduling mastered broadcasts with given start time.
It is not intended to use for playlists containing short audio parts.
It is recommended to have ntpd running to make sure your system time is up to date.

After any failure like system crash or power loss playout will continue to play out in-time.
If an audio file is (re-)scheduled to start in the past, the playout will play at in-time position.
If another files is put before or after the current file, files will be cutted so they will not overlap.
Cutting uses mp3splt and is supported for mp3, flac and ogg only.

Playout uses an upstart or systemd service and will automatically restart after crash or reboot.

If there is more than one file in a mediaDir subdirectory, playout triggers the first audio file sorted by name.
To avoid overlapping or silence on sequentially scheduled files, make sure audio files have exactly the scheduled duration.

Playout will not play audio files itself but start a configured player instead. 
Your system should support an alsa mixer or pulse audio to mix output of multiple player instances.

Changes of the configuration will be detected and reread on the fly.
A list of all audio files is stored internally and frequently updated to reduce disk IO. 

To automatically create the media sub directories (containing the schedule date and time in the path) 
you can import a JSON schedule from an URL by running playout_sync.pl. See playout_sync.pl --help for details.

At point of installation na user 'playout' will be created and assigned to groups 'playout', 'audio', 'pulse' and 'pulse-access'
to enable audio access and separate it from other user accounts.

If you dont want to use the service, you can also run 'playout.pl' at command line.
If you use option --daemon logs and pid file will be created.

CONFIGURATION
All configuration is done at /etc/playout/playout.conf

mediaDir           the base directory path of the audio file media
                   to schedule a file, put it to /mediaDir/yyyy/mm/dd/hh-mm/.
                   Make sure the files and directories can be read by the user ('playout' by default).

shortScanInterval  scan mediaDir for changes for yesterday, today and tomorrow every <shortScanInterval> seconds.
                  
fullScanInterval   scan mediaDir for changes every <shortScanInterval> seconds.

timeZone           Leap seconds and winter/summer time changeover are supported for the selected time zone, default is Germany/Berlin.

playCommand        the command to be executed to play (cvlc by default).
                   You can use following keywords in the playCommand:

                   AUDIO_FILE  name of the audio file to be played
                   PID_FILE    pid file of the audio player instance
                   LOG_FILE    global log file
                  
                   Using other commands than starting audio players it could be used for other purposes 
                   like schedule playing videos or sending mails...

initCommand        command to be run initially
                   for example use "killall vlc" to stop all vlc players on starting the service.

bufferDelay        if set to an value greater than 0 audio files will be played <bufferDelay> seconds before the scheduled date. 
                   For example, if you have a total audio buffer and streaming delay of 1.5 seconds, 
                   set bufferDelay to 1.5 to decrease the total delay.

maxAudioLength     the value in seconds after scheduled start when an audio file is assumed to be finished.
                   After this point in time no checks for updates on the files are done anymore.

tempDir            temporary audio files and player pids are written to this directory (use /tmp to do it in memory)

verboseLevel       verbose level [0-3] for log output.
                   If run as a service or with option --daemon logs will be written to /var/log/playout/playout.log
                   otherwise they go to STDOUT. Log files are daily rotated using logrotate.

syncGetScheduleUrl get a JSON document via HTTP GET from the URL containing 

syncSetScheduleUrl send a JSON document to HTTP POST containing current schedule after changes on scanning the mediaDir

syncPlotTargetDir  copy all created RMS plots to the given directory using rsync. Requires package rms to be installed.


=head1 VERSION

Version 0.0.4_0069

=head1 AUTHOR

Milan Chrobok <mc@radiopiloten.de>

=head1 LICENSE AND COPYRIGHT

Copyright 2008-2018 Milan Chrobok.

GPL-3+

=cut

use warnings;
use strict;

#use Data::Dumper;
#use LWP::Simple();
#use DateTime();
#use DateTime::Format::ISO8601();
#use File::Path qw(make_path);
#use Getopt::Long();
#use POSIX();
use Time::HiRes qw(time sleep);

use Playout::Log();
use Playout::Config();
use Playout::MediaFiles();
use Playout::Shows();
use Playout::Time();
use Playout::Process();
use Playout::Upload();
use Playout::Play::Simple();
use Playout::Play::VlcServer();
use Playout::Play::Liquidsoap();

use base 'Exporter';
our @EXPORT_OK = ('run');

# values read from configuration
my $tempDir = undef;    # temporary directory for cutted files and pid files
my $player = undef;

# cache finished shows by filename and modification date to prevent multiple file duration detection

sub getPlayer {
	return $player;
}

sub run() {

	#my $updateAudio=MediaFiles::shortScan();
	#Upload::shortUpload();
	#exit;

	my $interface = Config::get('interface');
	unless ( defined $interface ) {
		Log::error('no interface configured at config');
		exit 1;
	}

	if ( $interface eq 'vlcServer' ) {
		$player = Play::VlcServer->new( Config::get('vlcServer') );
	} elsif ( $interface eq 'liquidsoap' ) {
		$player = Play::Liquidsoap->new( Config::get('liquidsoap') );
	} else {
		$player = Play::Simple->new( Config::get('simple') );
	}

	while (1) {
		Log::header("playout");

		if ( Config::hasChanged() ) {
			Log::debug( 1, "config has changed" );
			updateConfig();
		}

		my $nextFullScan = MediaFiles::getNextFullScan();

		Log::debug( 1, "next full media check in " . sprintf( "%.02f secs", $nextFullScan ) );
		my $nextShortScan = MediaFiles::getNextShortScan();
		Log::debug( 1, "next short check in " . sprintf( "%.02f secs", $nextShortScan ) );

		my $skipShortScan = 0;
		if ( $nextFullScan > 0 ) {
			Log::debug( 1, "next full media check in " . sprintf( "%.02f secs", $nextFullScan ) );
		} else {
			my $updateAudio = MediaFiles::fullScan( { expires => [ time + 15 * 60, Shows::getNextStart() ] } );
			Upload::fullUpload() if $updateAudio > 0;
			MediaFiles::listAudio() if Log::getLevel() > 1;
			$skipShortScan = 1;
		}

		if ( $skipShortScan == 0 ) {
			my $nextShortScan = MediaFiles::getNextShortScan();
			if ( $nextShortScan > 0 ) {
				Log::debug( 1, "next short check in " . sprintf( "%.02f secs", $nextShortScan ) );
			} else {
				my $updateAudio = MediaFiles::shortScan( { expires => [ time + 15 * 60, Shows::getNextStart() ] } );
				Upload::shortUpload()   if $updateAudio > 0;
				MediaFiles::listAudio() if Log::getLevel() > 1;
			}
		}

		my $current = Shows::getRunning();
		$current->{state} = 'current:';
		my $next = Shows::getNext($current);
		$next->{state} = 'next:';
		my $previous = Shows::getPrevious($current);
		$previous->{state} = 'previous:';

		my @events = ( $next, $current, $previous );
		for my $event (@events) {
			Log::debug( 1, sprintf( "\n%-9s %s", uc( $event->{state} ), Shows::show($event) ) );
			my $show = Shows::getStatus($event);
			next unless defined $show;

			Log::objectInline( 1, $show );

			if ( $show->{isError} ) {
				Log::info('isError');
			} elsif ( $show->{isOver} ) {
				$player->stop($event);
			} elsif ( $show->{isRunning} ) {

				# stop show if original audio file is removed
				if ( isFileMissing( $event->{file} ) ) {
					$player->stop($event);
					next;
				}

				if ( $show->{timeTillEnd} > 15 ) {
					unless ( $player->isRunning( $event, $show ) ) {
						$player->play( $event, $show );
					}
				}
			} elsif ( $show->{isNotStartedYet} ) {
				if ( isFileMissing( $event->{file} ) ) {
					Log::warn(qq{missing file "$event->{file}"});
					MediaFiles::forceShortScan();
					next;
				}
				if ( $show->{timeTillStart} < 30 ) {

					#set playout file ($event->file)
					$player->prepare($event);
					$show = Shows::getStatus($event);
					sleep( $show->{timeTillStart} ) if $show->{timeTillStart} > 0;
					$player->play( $event, $show );
					sleep(3);
					next;
				}

			}
		}
		sleep 10;
	}
	return;
}

sub isFileMissing {
	my $audioFile = shift || '';

	# skip if file is empty
	if ( $audioFile eq '' ) {
		Log::warn("skip\tfile is empty");
		return 1;
	}

	# stop show if file has been removed
	unless ( -e $audioFile ) {
		Log::warn(qq{skip\taudio file has been moved or removed: "$audioFile"});
		MediaFiles::forceShortScan();
		return 1;
	}
	return 0;
}

# read configuration, run housekeeping and kill existing players
sub init {
	my $options = shift;

	Log::info("start playout");

	my $configFile = $options->{configFile};
	$configFile = Config::getConfigFile() unless defined $configFile;
	Config::setConfigFile($configFile);

	unless ( -e $configFile ) {
		Log::error(qq{cannot find config file "$configFile"});
		exit 1;
	}

	unless ( -r $configFile ) {
		Log::error(qq{cannot read config file "$configFile". Please check file permissions.});
		exit 1;
	}
	Log::info(qq{read config from "$configFile"});

	my ( $config, $error ) = updateConfig($options);
	exit if ( $error > 0 );

	AudioCut::removeOldFiles();
	MediaFiles::init($config);
	return;

}

sub updateConfig {
	my $options = shift;

	return unless Config::hasChanged();

	my $config = Config::update();

	if ( defined $options->{daemon} ) {

		# set log file from config if customized
		Log::setLogFile( $config->{logFile} ) if defined $config->{logFile};
		Log::openLog();
	}
	Log::setLevel( $config->{verboseLevel} );

	Log::info( Config::show() );
	my $error = Config::check();

	# return on errors
	return $error unless $error == 0;

	# deploy config values
	$tempDir = $config->{tempDir};
	AudioCut::setOutputDirectory($tempDir);
	MediaFiles::setMediaDir( $config->{mediaDir} );
	MediaFiles::setCacheFile( $config->{mediaDir} . '/playout.dat' );
	Time::setTimeZone( $config->{timeZone} );
	AudioCut::setStartUpDuration( $config->{bufferDelay} );
	Shows::setStartUpDuration( $config->{bufferDelay} );
	MediaFiles::setShortScanInterval( $config->{shortScanInterval} );
	MediaFiles::setFullScanInterval( $config->{fullScanInterval} );
	MediaFiles::setSyncPlotTargetDir( $config->{syncPlotTargetDir} );
	MediaFiles::setGainCommand( $config->{gainCommand} );
	Log::debug( 2, "setUrl:$config->{syncSetScheduleUrl}" ) if defined $config->{syncSetScheduleUrl};
	Upload::setUrl( $config->{syncSetScheduleUrl} );

	#Download::setUrl($config->{syncGetScheduleUrl});

	# add checks
	$error += MediaFiles::checkMediaDir();
	return $config, $error;
}

# print current configuration
sub printConfig {
	Log::info(
		qq{
mediaDir            } . MediaFiles::getMediaDir() . qq{
shortScanInterval  } . MediaFiles::getShortScanInterval() . qq{
fullScanInterval   } . MediaFiles::getFullScanInterval() . qq{
bufferDelay         } . Shows::getStartUpDuration() . qq{
maxAudioLength     } . Config::get('maxAudioLength') . qq{
timeZone            } . Time::getTimeZone() . qq{
tempDir             } . Config::get('tempDir') . qq{
verboseLevel          } . Log::getLevel() . qq{
initCommand        '} . Config::get('initCommand') . qq{'
playCommand        '} . Config::get('playCommand') . qq{'
}
	);
	return;
}

# get last modification date of file
sub getFileModificationDate {
	my $file = shift;
	my @stat = stat($file);
	return undef if scalar(@stat) == 0;
	return $stat[9];
}

# do not delete last line
1;
