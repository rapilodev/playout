package Play::Liquidsoap;

use warnings;
use strict;

use Time::HiRes qw(time sleep);
use Data::Dumper;

use Playout::Log();
use Playout::MediaFiles();
use Playout::Process();
use Playout::AudioCut();
use Playout::LiquidsoapClient();
use Playout::LiquidsoapStream();
use Playout::LiquidsoapFile();

use base 'Play';

# tempDir
# playCommand
# onInitCommand
# onExitCommand

sub new {
    my ( $class, $args ) = @_;

    # execute onInitCommand
    init($args);
    Playout::LiquidsoapClient::init($args);

    return bless {%$args}, $class;
}

# execute onInitCommand
sub init {
    my $self = shift;
    return unless $self->{onInitCommand};
    my @cmd = split /\s/, $self->{onInitCommand};
    my $exitCode = Process::execute my $result, '<', @cmd;
    return;
}

# will be called at stop of playout
sub exit {
    my $self = shift;
    return unless $self->{onExitCommand};
    my @cmd = split /\s/, $self->{onExitCommand};
    my $exitCode = Process::execute my $result, '<', @cmd;
    print $result;
    return;
}

# check if player process runs
sub isRunning {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;

    $event->{playoutFile} = MediaFiles::getPlayoutFile($event);
    unless ( defined $event->{playoutFile} ) {
        Log::warn("cannot check player without playout file for $event->{file}");
        return 0;
    }
    my $playoutFile = $event->{playoutFile};
    Log::debug( 0, "playoutFile=$playoutFile" );

    if ( defined $event->{url} ) {
        return Playout::LiquidsoapStream::isRunning($event);
    } else {
        return Playout::LiquidsoapFile::isRunning( $event, $show );
    }
    return 1;
}

# open file to warm up drive some seconds before start
sub prepare {
    my $self  = shift;
    my $event = shift;

    Log::debug( 0, "remove old cut files" );
    AudioCut::removeOldFiles();

    if ( defined $event->{url} ) {
        my $url = $event->{url};
        Log::info("prepare '$url'");
        Playout::LiquidsoapFile::deactivateInactiveSlot();
        Playout::LiquidsoapStream::schedule($event);

    } else {
        Log::info( "prepare '" . $event->{file} . "'" );
        Playout::LiquidsoapFile::scheduleFile( $event->{file} );
    }
    return;

}

# play audio with given pid file
sub play {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;

    $self->cut( $event, $show );

    # update playout file (on change)
    $event->{playoutFile} = MediaFiles::getPlayoutFile($event);
    MediaFiles::setPlayoutFile( $event->{file}, $event->{playoutFile} );
    Log::info("play $event->{playoutFile}");

    unless ( defined $event->{playoutFile} ) {
        Log::error("Liquidsoap::playShow: no playout file for $event->{file}");
        return undef;
    }
    my $playoutFile = $event->{playoutFile};

    if ( defined $event->{url} ) {
        Playout::LiquidsoapStream::play($event);
    } else {
        my $slot = Playout::LiquidsoapFile::getSlotForFile($playoutFile);
        unless ( defined $slot ) {
            Playout::LiquidsoapFile::scheduleFile($playoutFile);
            $slot = Playout::LiquidsoapFile::getSlotForFile($playoutFile);
        }
        unless ( defined $slot ) {
            Log::error("could not get schedule for '$playoutFile'");
            return;
        }
        Playout::LiquidsoapFile::activateSlot($slot);
    }
    Log::debug( 1, "play done" );
    return;
}

# stop player
sub stop {
    my $self  = shift;
    my $event = shift;
    $event->{playoutFile} = MediaFiles::getPlayoutFile($event);

    my $playoutFile = $event->{playoutFile};
    if ( defined $event->{url} ) {
        Playout::LiquidsoapStream::stop($event);
    } else {
        my $slot = Playout::LiquidsoapFile::getSlotForFile($playoutFile);
        Playout::LiquidsoapFile::clearSlot($slot) if defined $slot;
    }
    Log::debug( 0, "end of stop" );
    return;
}

# set playoutFile and cut
sub cut {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;

    # set playout file to original file
    $event->{playoutFile} = $event->{file};

    # set next event as end of show
    my $next = Shows::getNext($event);
    $event->{end} = $next->{start} if defined $next;

    if ( defined $event->{url} ) {

        # for streams
        $event->{playoutFile} = $event->{url};
    } else {

        # for audio files
        my $fileCheck = AudioCut::checkFile( $event->{file}, $show );
        if ( defined $fileCheck->{cutPoints} ) {

            # set playout file to cut file
            $event->{playoutFile} = AudioCut::cut( $fileCheck->{file}, $fileCheck->{cutPoints} );
        }
    }

    # store playout file
    MediaFiles::setPlayoutFile( $event->{file}, $event->{playoutFile} );
    return;
}

# do not delete last line
1;
