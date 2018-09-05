package Playout::LiquidsoapFile;

use warnings;
use strict;

use Playout::Log();

my $slotA = 'SlotA';
my $slotB = 'SlotB';

sub getDefaultSlot {
    return $slotB;
}

sub isRunning {
    my $event = shift;
    my $show  = shift;
    
        
    # get running id from request
    my $runningRequestIds = getRunningRequestIds();
    Log::debug( 2, "runningRequestIds=" . join( ",", @$runningRequestIds ) );

    # get request by file from active slot
    my $slot = getActiveSlot();
    Log::debug( 2, "activeSlot=$slot" ) if defined $slot;
    Log::debug( 2, "activeSlot=undef" ) unless defined $slot;
    return 0 unless defined $slot;

    my $playoutFile=$event->{playoutFile};
    my $requestId = getRequestId( $slot, $playoutFile );
    Log::debug( 2, "requestId=$requestId" ) if defined $requestId;
    Log::debug( 2, "requestId=undef" ) unless defined $requestId;
    return 0 unless defined $requestId;

    my $found = 0;
    for my $runningRequestId (@$runningRequestIds) {
        if ( $runningRequestId eq $requestId ) {
            $found = 1;
            last;
        }
    }
    if ( $found == 0 ) {
        Log::debug( 1,
            "not running, requestId '$requestId' not in runningRequestIds " . join( ",", @$runningRequestIds ) );
        return 0;
    }
    Log::debug( 1, "isRunning=true, file=$playoutFile, rid=$requestId" );
    return 1;
}

# get request id for file in given slot
sub getRequestId {
    my $slot = shift;
    my $file = shift;
    Log::error("missing slot in getRequestId") unless defined $slot;
    Log::error("missing file in getRequestId") unless defined $file;

    my $queue = getQueue($slot);
    for my $requestId (@$queue) {
        return $requestId if isRequestForFile( $requestId, $file );
    }
    return undef;
}

# get request ids of running request
sub getRunningRequestIds {
    my $lines = Playout::LiquidsoapClient::sendSocket("request.on_air");

    my $results = [];

    # stop unless only white spaces and digits
    return $results if $lines =~ /[^\s\d]/;
    for my $rid ( split( /\s+/, $lines ) ) {
        push @$results, $rid if $rid =~ /^\d+$/;
    }
    return $results;
}

# put file into inactive slot
sub scheduleFile {
    my $file = shift;
    Log::error("missing file in scheduleFile") unless defined $file;

    my $slot = getActiveSlot('');
    $slot = $slotB unless defined $slot;

    $slot = getOtherSlot($slot);
    clearSlot($slot);
    addFileToSlot( $slot, $file );
    return;
}

# get the current playing slot
sub getActiveSlot {
    my $result = Playout::LiquidsoapClient::getString("activeSlot") || 'undef';
    Log::debug( 2, "getActiveSlot()=$result" );
    return $slotA if $result =~ /$slotA/;
    return $slotB if $result =~ /$slotB/;
    return undef;
}

sub deactivateInactiveSlot{
    my $slot = getActiveSlot();
    $slot = getDefaultSlot() unless defined $slot;

    # clear inactive slot
    $slot = getOtherSlot($slot);
    clearSlot($slot);
    return;
}

sub deactivateSlot {
    my $slot = shift;
    Log::error("missing file slot in deactivateSlot") unless defined $slot;
    Log::debug( 2, "deactivateSlot $slot" );
    Playout::LiquidsoapClient::setBool("isActive$slot","false");
    return;
}

# play files in the given slot
sub activateSlot {
    my $slot = shift;
    Log::error("missing file slot in activateSlot") unless defined $slot;
    Log::debug( 2, "activateSlot $slot" );
    Playout::LiquidsoapClient::setString("activeSlot",$slot);
    if ( $slot eq $slotA ) {
        Playout::LiquidsoapClient::setBool("isActiveSlotA","true");
    } else {
        Playout::LiquidsoapClient::setBool("isActiveSlotA","false");
        Playout::LiquidsoapStream::deactivateSlot("StreamA");
        Playout::LiquidsoapStream::deactivateSlot("StreamB");
        Playout::LiquidsoapClient::setBool("isActiveStreamA","false");
    }
    if ( $slot eq $slotB ) {
        Playout::LiquidsoapClient::setBool("isActiveSlotB","true");
    } else {
        Playout::LiquidsoapClient::setBool("isActiveSlotB","false");
        Playout::LiquidsoapStream::deactivateSlot("StreamA");
        Playout::LiquidsoapStream::deactivateSlot("StreamB");
    }
    return;
}

# add a file to a slot
sub addFileToSlot {
    my $slot = shift;
    my $file = shift;
    Log::error("missing slot in addFileToSlot") unless defined $slot;
    Log::error("missing file in addFileToSlot") unless defined $file;

    Log::debug( 1, "addFileToSlot $slot \"$file\"" );
    my $requestId = getRequestId( $slot, $file );
    if ( defined $requestId ) {
        Log::debug( 1, "already scheduled" );
        return;
    }

    my $result = Playout::LiquidsoapClient::sendSocket("$slot.push $file");
    return;
}

# return true if metadata contains file
sub isRequestForFile {
    my $requestId = shift;
    my $file      = shift;
    Log::error("missing requestId in isRequestForFile") unless defined $requestId;
    Log::error("missing file in isRequestForFile") unless defined $file;

    my $lines = Playout::LiquidsoapClient::sendSocket("request.metadata $requestId");

    return 1 if $lines =~ /$file/;
    return 0;
}

# return request ids for the given slot
sub getQueue {
    my $slot   = shift;
    Log::error("missing slot in getQueue") unless defined $slot;

    my $result = Playout::LiquidsoapClient::sendSocket("$slot.queue");
    return [] unless defined $result;
    my @rids = split( / /, $result );
    return \@rids;
}

# clear all requests from slot
sub clearSlot {
    my $slot   = shift;
    Log::error("missing slot in getQueue") unless defined $slot;

    my $result = Playout::LiquidsoapClient::sendSocket("$slot.queue");

    Log::debug( 1, "clearSlot $slot" );

    Playout::LiquidsoapClient::sendSocket("$slot.skip");
    my $queue = getQueue($slot);
    for my $requestId (@$queue) {
        Playout::LiquidsoapClient::sendSocket("$slot.remove $requestId");
    }
    return;
}

# get the opposite slot
sub getOtherSlot {
    my $slot = shift;
    return $slotB if $slot eq $slotA;
    return $slotA;
}

sub getSlotForFile {
    my $file = shift;
    Log::error("missing file in getSlotForFile") unless defined $file;

    for my $slot ( $slotA, $slotB ) {
        if ( defined getRequestId( $slot, $file ) ) {
            Log::debug( 1, "getSlotForFile=$slot for \"$file\"" );
            return $slot;
        }
    }
    Log::debug( 1, "no slot found for \"$file\"" );
    return undef;
}

# do not delete last line
1;
