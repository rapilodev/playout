package Play::Simple;

use warnings;
use strict;
use Playout::MediaFiles();
use Playout::Process();
use Playout::AudioCut();

use base 'Play';

# tempDir
# playCommand
# onInitCommand
# onExitCommand

sub new {
    my ( $class, $args ) = @_;

    # execute onInitCommand
    init($args);

    return bless {%$args}, $class;
}

# execute onInitCommand
sub init {
    my $self = shift;
    return unless $self->{onInitCommand};
    my @cmd = split /\s/, $self->{onInitCommand};
    Process::execute my $result, '<', @cmd;
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

    my $pidFile = Process::getPidFile( $self->{tempDir}, $event->{playoutFile} );
    my $pid = Process::getPid($pidFile);
    if ( Process::isRunning($pid) ) {
        Log::debug( 2, "player process is running..." );
        return 1;
    } else {
        Log::debug( 2, "player process is not running" );
    }
    return 0;
}

# open file to warm up drive some seconds before start
sub prepare {
    my $self  = shift;
    my $event = shift;

    my $audioFile = $event->{file};

    Log::debug( 0, "remove old cut files" );
    AudioCut::removeOldFiles();

    unless ( defined $event->{url} ) {

        # read audio file
        Log::debug( 0, "prepare '" . $audioFile . "'" );
        if ( -e $audioFile ) {
            open my $file, '<', $audioFile or return Log::warn "cannot read $audioFile";
            if ($file) {
                my $line = '';
                read( $file, $line, 1000 * 1000 );
                close $file;
            }
        }
        Log::debug( 0, "after load file" );
    }

    Log::debug( 0, "deactivate silence detection" );
    my $cmd         = $self->{playCommand};
    my $logFile     = Log::getLogFile();
    my $playoutFile = '/usr/share/playout/peak.wav';
    my $pidFile     = Process::getPidFile( $self->{tempDir}, $playoutFile );

    my $exitCode = Process::execute(my $result, '<',
        map { s/PID_FILE/$pidFile/gr }
        map { s/LOG_FILE/$logFile/gr }
        map { s/AUDIO_FILE/$playoutFile/gr }
        split /\s/, $cmd);
    Log::debug( 0, substr( $result, 0, 80 ) . '...' );
    Log::debug( 0, "after prepare" );
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

    unless ( defined $event->{playoutFile} ) {
        Log::error("Simple::playShow: no playout file for $event->{file}");
        return undef;
    }
    my $playoutFile = $event->{playoutFile};

    my $pidFile = Process::getPidFile( $self->{tempDir}, $playoutFile );

    #build play command
    my $cmd     = $self->{playCommand};
    my $logFile = Log::getLogFile();

    my $exitCode = Process::execute my $result, '<',
        map { s/PID_FILE/$pidFile/gr }
        map { s/LOG_FILE/$logFile/gr }
        map { s/AUDIO_FILE/$playoutFile/gr }
        split /\s/, $cmd;
    return;
}

# stop player process
sub stop {
    my $self  = shift;
    my $event = shift;
    $event->{playoutFile} = MediaFiles::getPlayoutFile($event);

    my $pidFile = Process::getPidFile( $self->{tempDir}, $event->{playoutFile} );
    my $pid = Process::getPid($pidFile);
    if ( $pid > 0 ) {
        Log::warn("stop $event->{name} and remove pid $pid");
        Process::stop($pid) if Process::isRunning($pid);
        unlink $pidFile;
    }
    return;
}

# set playoutFile and cut
sub cut {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;

    # set next event as end of show
    my $next = Shows::getNext($event);
    $event->{end} = $next->{start} if defined $next;

    # set playout file to original file
    if ( defined $event->{url} ) {

        # for streams append start date to identify pid file
        $event->{playoutFile} = $event->{url} . '#' . ($event->{start} =~ s{[\D]}{\-}gr);
    } else {
        $event->{playoutFile} = $event->{file};

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

