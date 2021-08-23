package Play::VlcServer;

use strict;
use warnings;

use LWP::UserAgent();
use URI::Escape();

use Data::Dumper;
use XML::LibXML::Simple qw(XMLin);

use Playout::Log();

use base 'Play';

my $ua      = undef;
my $pidFile = undef;

# hostname,
# port,
# user,
# password
sub new {
    my $class = shift;
    my $args  = shift;

    # execute onInitCommand
    $ua = LWP::UserAgent->new unless defined $ua;
    for my $attr ( 'hostname', 'port', 'user', 'password' ) {
        $args->{$attr} = '' unless defined $args->{$attr};
    }

    my $self = bless {%$args}, $class;
    $self->init($args);
    return $self;
}

# execute onInitCommand
sub init {
    my $self = shift;
    return unless $self->{onInitCommand};
    my @cmd = split /\s/, $self->{onInitCommand};
    Process::execute( my $result, '<', @cmd);

    #start server
    $self->startVlcServer();
    $self->clearPlaylist();
    return;
}

sub exit {
    my $self = shift;
    $self->stopVlcServer();
    return;
}

sub startVlcServer {
    my $self = shift;

    my $pidFile = $self->{serverPidFile};
    my $logFile = $self->{serverLogFile};
    Log::error("missing vlcServer/serverStartCommand") unless defined $self->{serverStartCommand};
    Log::error("missing vlcServer/serverPidFile")      unless defined $self->{serverPidFile};

    Log::info("start vlc server");
    Process::execute( my $result, '<',
        map { s/PID_FILE/$pidFile/gr }
        map { s/LOG_FILE/$logFile/gr }
        map { s/HOSTNAME/$self->{hostname}/gr }
        map { s/PORT/$self->{port}/gr }
        map { s/USER/$self->{user}/gr }
        map { s/PASSWORD/$self->{password}/gr }
        split /\s/, $self->{serverStartCommand});
    return;
}

sub stopVlcServer {
    my $self = shift;

    my $pidFile = $self->{serverPidFile};
    my $pid     = Process::getPid($pidFile);
    if ( $pid > 0 ) {
        Log::warn("stop vlc server with pid $pid");
        Process::stop($pid) if Process::isRunning($pid);
        unlink $pidFile;
    }
    return;
}

sub isServerRunning {
    my $self    = shift;
    my $pidFile = $self->{serverPidFile};
    my $pid     = Process::getPid($pidFile);
    Log::debug( 1, "vlc server is running with pid=$pid" );
    return 0 if $pid == 0;
    return 1 if Process::isRunning($pid);
    return 0;
}

sub prepare {
    my $self  = shift;
    my $event = shift;

    Log::debug( 0, "remove old cut files" );
    AudioCut::removeOldFiles();
    return;
}

sub isRunning {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;

    if ( $self->isServerRunning() ) {
        Log::debug( 2, "vlc server is running..." );
    } else {
        Log::warn("vlc server is not running, restart");
        $self->startVlcServer();
    }

    $event->{playoutFile} = MediaFiles::getPlayoutFile($event);
    unless ( defined $event->{playoutFile} ) {
        Log::warn("cannot check player without playout file for $event->{file}");
        return 0;
    }

    my $result    = $self->action('status.xml');
    my $time      = $result->{time};
    my $currentId = $result->{currentplid};
    my $state     = $result->{state};

    my $playItem = $self->getPlaylistItem($event);
    unless ( defined $playItem ) {
        Log::debug( 2, "state=$state, time=$time, no playlist item available" );
        return 0;
    }

    Log::debug( 2, "state=$state, time=$time, currentId=$currentId, playlistId=$playItem->{id}, current=$playItem->{current}" );

    if ( ( $state eq 'playing' ) && ( $playItem->{current} ) ) {
        Log::debug( 2, "is playing" );
        if ( ( $time > 0 ) && ( $show->{runDuration} > $time + 10 ) ) {
            Log::warn("more than 10 seconds behind, seek to $show->{runDuration}");
            $self->seek( $show->{runDuration} );
            sleep 10;
        }
        return 1;
    }

    return 0;

    #Log::info( Dumper($result) );
}

sub parseIds {
    my $result = shift;
    my $node   = shift;

    #print Dumper($node);
    if ( ref($node) eq 'ARRAY' ) {
        for my $child (@$node) {
            parseIds( $result, $child );
        }
    } elsif ( ref($node) eq 'HASH' ) {
        for my $key ( keys %$node ) {
            my $child = $node->{$key};
            if ( ref($child) eq 'ARRAY' ) {
                parseIds( $result, $child );
            }
        }
        if ( ( defined $node->{uri} ) && ( defined $node->{id} ) ) {
            my $uri = $node->{uri};
            $uri =~ s/^file\:\/\///;
            $node->{uri}     = URI::Escape::uri_unescape();
            $node->{current} = 0 unless defined $node->{current};
            $result->{$uri}  = $node;
        }
    }
    return;
}

sub getPlaylistItem {
    my $self  = shift;
    my $event = shift;

    unless ( defined $event->{playoutFile} ) {
        $event->{playoutFile} = MediaFiles::getPlayoutFile($event);
        unless ( defined $event->{playoutFile} ) {
            Log::warn("cannot check player without playout file for $event->{file}");
            return 0;
        }
    }
    my $result = $self->action('playlist.xml');

    my $ids = {};
    parseIds( $ids, $result );

    #print Dumper($ids);
    my @files = keys %$ids;
    if ( scalar(@files) == 1 ) {
        $ids->{ $files[0] }->{current} = 1;
    }
    return undef unless defined $ids->{ $event->{playoutFile} };
    return $ids->{ $event->{playoutFile} };
}

sub play {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;

    # update playout file (on change)
    $event->{playoutFile} = MediaFiles::getPlayoutFile($event);
    MediaFiles::setPlayoutFile( $event->{file}, $event->{playoutFile} );

    unless ( defined $event->{playoutFile} ) {
        Log::error("Simple::playShow: no playout file for $event->{file}");
        return undef;
    }
    my $playoutFile = $event->{playoutFile};

    #print Dumper($event);
    #print Dumper($show);
    my $result = $self->action( 'status.xml', { command => 'in_play', 'input' => 'file://' . $playoutFile } );
    if ( $show->{runDuration} > 10 ) {
        $result = $self->seek( $show->{runDuration} );
        sleep(10);
    }
    return $result;

}

sub stop {
    my $self  = shift;
    my $event = shift;
    $event->{playoutFile} = MediaFiles::getPlayoutFile($event);
    return;
}

sub status {
    my $self   = shift;
    my $result = $self->action('status.xml');
    return $result;
}

sub clearPlaylist {
    my $self = shift;
    my $result = $self->action( 'status.xml', { 'command' => 'pl_empty' } );
    return $result;

}

sub seek {
    my $self    = shift;
    my $seconds = shift;
    return if $seconds < 0;
    my $result = $self->action( 'status.xml', { 'command' => 'seek', 'val' => $seconds } );
    return $result;
}

sub playlist {
    my $self   = shift;
    my $result = $self->action('playlist.xml');
    return;
}

sub action {
    my $self       = shift;
    my $controller = shift;
    my $options    = shift;

    my $url = "http://" . $self->{hostname} . ":" . $self->{port} . "/requests/" . $controller;

    my $params = [];
    for my $key ( keys %$options ) {
        push @$params, $key . '=' . URI::Escape::uri_escape( $options->{$key} );
    }
    $url .= '?' . join( '&', @$params ) if scalar($params) > 0;

    my $doc = $self->query($url);
    return $doc;
}

sub query {
    my $self = shift;
    my $url  = shift;

    Log::debug( 1, "vlc server request: '$url', user:'$self->{user}', password:'$self->{password}'" );
    my $request = HTTP::Request->new( GET => $url );
    $request->authorization_basic( $self->{user}, $self->{password} );

    my $response = $ua->request($request);
    my $doc      = undef;
    if ( $response->is_success ) {
        my $content = $response->content;
        my $doc = XML::LibXML::Simple::XMLin( $content, ForceArray => 1, KeyAttr => [] );
        return $doc;
    } else {
        Log::warn( $response->{_rc} . " on $url" );
        return undef;
    }
}

1;
