package Playout::LiquidsoapStream;

use warnings;
use strict;

use Playout::Log();

my $slotA      = 'StreamA';
my $slotB      = 'StreamB';
my $invalidUrl = 'http://localhost/invalid';

sub isRunning {
    my $event       = shift;
    my $playoutFile = $event->{file};
    my $url         = $event->{url} || $invalidUrl;
    my $fallback    = $event->{fallbackUrl} || $invalidUrl;

    my $slot = getActiveSlot();
    unless ( defined $slot ) {
        Log::warn("not running, no active stream slot");
        return 0;
    }

    my $file = getPlayoutFileForSlot($slot);
    if ( $file ne $slot ) {
        Log::warn("not running, no playoutFile $playoutFile not set at active $slot");
        return 0;
    }

    my ( $streamUrl, $fallbackUrl ) = getUrlsForSlot($slot);

    unless ( $streamUrl eq $url ) {
        Log::warn("not running, expect=$url, found=$streamUrl");
        return 0;
    }

    unless ( $fallbackUrl eq $fallback ) {
        Log::warn("not running, expect=$fallback, found=$fallbackUrl");
        return 0;
    }

    my $status1 = getStatus( $slot . '1' );
    my $status2 = getStatus( $slot . '2' );
    unless ( ( $status1 =~ /connected/ ) || ( $status2 =~ /connected/ ) ) {
        Log::warn("not running, not connected to neither $url (status=$status1) nor $fallback (status=$status2)");
        return 0;
    }

    Log::debug( 1, "isRunning=true, url=$url (status=$status1), fallback=$fallback (status=$status2)" );
    return 1;

}

sub schedule {
    my $event       = shift;
    my $playoutFile = $event->{file};
    my $url         = $event->{url} || $invalidUrl;
    my $fallback    = $event->{fallbackUrl} || $invalidUrl;

    Log::debug( 1, qq{schedule playoutFile='$playoutFile', url='$url', fallback='$fallback'} );

    #try active slot
    my $slot = getActiveSlot();

    #schedule if no active slot
    unless ( defined $slot ) {
        $slot = $slotA;
        setStreams( $slot, $playoutFile, $url, $fallback );
        return $slot;
    }

    # return if already scheduled
    $slot = getSlotForPlayoutFile($playoutFile);
    if ( defined $slot ) {
        my ( $streamUrl, $fallbackUrl ) = getUrlsForSlot($slot);
        if ( ( $url eq $streamUrl ) && ( $fallback eq $fallbackUrl ) ) {
            return $slot;
        }
    }

    #set urls for inactive slot
    $slot = getInactiveSlot();
    setStreams( $slot, $playoutFile, $url, $fallback );
    return $slot;
}

sub play {
    my $event = shift;

    my $slot = schedule($event);
    activateSlot($slot);
    Log::debug( 1, "play stream $slot done" );
    return;
}

sub stop {
    my $event       = shift;
    my $playoutFile = $event->{file};
    my $url         = $event->{url} || $invalidUrl;
    my $fallback    = $event->{fallbackUrl} || $invalidUrl;

    my $slot = getSlotForPlayoutFile($playoutFile);
    unless ( defined $slot ) {
        Log::debug( 1, "stream $playoutFile already stopped" );
        return;
    }

    deactivateSlot($slot);
    clearStreams($slot);
    return;
}

# activate slot and deactivate others
sub activateSlot {
    my $slot = shift;

    if ( $slot eq $slotA ) {
        Playout::LiquidsoapClient::setBool( "isActiveStreamA", "true" );
        setActiveSlot($slotA);
        deactivateSlot($slotB);
        Playout::LiquidsoapFile::deactivateSlot("SlotA");
        Playout::LiquidsoapFile::deactivateSlot("SlotB");
    }

    elsif ( $slot eq $slotB ) {
        Playout::LiquidsoapClient::setBool( "isActiveStreamB", "true" );
        setActiveSlot($slotB);
        deactivateSlot($slotA);
        Playout::LiquidsoapFile::deactivateSlot("SlotA");
        Playout::LiquidsoapFile::deactivateSlot("SlotB");
    }
    return;
}

# deactivate a single slot
sub deactivateSlot {
    my $slot = shift;
    if ( $slot eq $slotA ) {
        Playout::LiquidsoapClient::setBool( "isActiveStreamA", "false" );
    } elsif ( $slot eq $slotB ) {
        Playout::LiquidsoapClient::setBool( "isActiveStreamB", "false" );
    }
    return;
}

sub getActiveSlot {
    my $result = Playout::LiquidsoapClient::getString("activeStream") || 'undef';
    Log::debug( 2, "getActiveSlot done" );
    return $slotA if $result =~ /$slotA/;
    return $slotB if $result =~ /$slotB/;
    return undef;
}

sub getInactiveSlot {
    my $result = Playout::LiquidsoapClient::getString("activeStream") || 'undef';
    Log::debug( 2, "getInactiveSlot done" );
    return $slotA if $result =~ /$slotB/;
    return $slotB;
}

sub getOtherSlot {
    my $slot = shift;
    return $slotB if $slot eq $slotA;
    return $slotA;
}

sub setActiveSlot {
    my $streamSlot = shift;
    my $result = Playout::LiquidsoapClient::setString( "activeStream", $streamSlot );
    return $result;
}

sub setStreams {
    my $slot        = shift;
    my $playoutFile = shift;
    my $url         = shift;
    my $fallback    = shift;
    setPlayoutFile( $slot, $playoutFile );
    setStream( $slot . '1', $url );
    setStream( $slot . '2', $fallback );
    return;
}

sub setStream {
    my $streamId = shift;
    my $url      = shift;

    Log::error("missing streamId at playstream") unless defined $streamId;
    Log::error("missing url at playstream")      unless defined $url;

    # check if already running
    return unless defined $url;

    my $status = '';
    if ( $url ne getUrl($streamId) ) {
        clearStream($streamId);
        $status = Playout::LiquidsoapClient::sendSocket( "$streamId.url " . $url );
        return unless defined $status;
    }
    $status = getStatus($streamId);
    return unless defined $status;

    Playout::LiquidsoapClient::sendSocket("$streamId.start") unless $status =~ /connected/;

    Log::debug( 2, "setStream $streamId done" );
    return;
}

sub clearStreams {
    my $slot = shift;
    setPlayoutFile( $slot, "none" );
    clearStream( $slot . '1' );
    clearStream( $slot . '2' );
    return;
}

sub clearStream {
    my $streamId = shift;
    Log::error("missing streamId at playstream") unless defined $streamId;

    my $status = Playout::LiquidsoapClient::sendSocket("$streamId.status");
    return unless defined $status;
    unless ( $status =~ /stopped/ ) {
        Playout::LiquidsoapClient::sendSocket("$streamId.stop");

        # wait until stopped with a timeout of one second
        my $start   = time;
        my $timeout = 1;
        sleep(0.05);
        $status = Playout::LiquidsoapClient::sendSocket("$streamId.status");

        while ( ( defined $status ) && ( $status !~ /stopped/ ) ) {
            sleep(0.05);
            $status = Playout::LiquidsoapClient::sendSocket("$streamId.status");
            last if ( time - $start > $timeout );
        }
    }
    return unless defined $status;
    Playout::LiquidsoapClient::sendSocket("$streamId.url $invalidUrl");
    Log::debug( 2, "stopStream $streamId done" );
    return;
}

sub getStatus {
    my $streamId = shift;
    Log::error("missing streamId at getStreamStatus") unless defined $streamId;

    return Playout::LiquidsoapClient::sendSocket("$streamId.status");
}

sub getSlotForPlayoutFile {
    my $playoutFile = shift;
    Log::error("missing playoutFile at getSlotForPlayoutFile") unless defined $playoutFile;

    for my $slot ( $slotA, $slotB ) {
        my $file = Playout::LiquidsoapClient::getString( "PlayoutFile" . $slot ) || '';
        Log::debug( 3, qq{'$playoutFile'=='$file'} );
        return $slot if $file eq $playoutFile;
    }
    return undef;
}

sub setPlayoutFile {
    my $slot        = shift;
    my $playoutFile = shift;
    Log::error("missing slot at setPlayoutFileForSlot")        unless defined $slot;
    Log::error("missing playoutFile at setPlayoutFileForSlot") unless defined $playoutFile;
    return Playout::LiquidsoapClient::setString( "PlayoutFile$slot", $playoutFile );
}

sub getPlayoutFileForSlot {
    my $slot = shift;
    Log::error("missing slot at getPlayoutFileForSlot") unless defined $slot;
    return Playout::LiquidsoapClient::getString("PlayoutFile$slot");
}

sub getUrlsForSlot {
    my $slot = shift;
    Log::error("missing slot at getStreamUrl") unless defined $slot;
    my $streamUrl   = getUrl( $slot . '1' );
    my $fallbackUrl = getUrl( $slot . '2' );
    return ( $streamUrl, $fallbackUrl );
}

sub getUrl {
    my $streamId = shift;
    Log::error("missing streamId at getStreamUrl") unless defined $streamId;
    return Playout::LiquidsoapClient::sendSocket("$streamId.url") || '';
}

# do not delete last line
1;
