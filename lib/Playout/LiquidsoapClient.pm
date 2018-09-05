package Playout::LiquidsoapClient;

use warnings;
use strict;

use IO::Socket::UNIX qw(SOCK_STREAM);
use IO::Socket::INET qw(SOCK_STREAM);
use Playout::Log();

my $hostname   = 'localhost';
my $port       = 1234;
my $socketPath = undef;

my $fileSocket   = undef;
my $telnetSocket = undef;

sub init {
    my $options = shift;

    $hostname   = $options->{hostname}   if defined $options->{hostname};
    $port       = $options->{port}       if defined $options->{port};
    $socketPath = $options->{socketPath} if defined $options->{socketPath};

    $SIG{TERM} = sub {
        Log::debug( 3, "connection lost to liquidsoap (terminated), close socket" );
        closeSocket();
    };

    $SIG{PIPE} = sub {
        Log::debug( 3, "connection lost to liquidsoap (broken pipe), close socket" );
        closeSocket();
    };
    return;
}

sub getBool {
    my $name = shift;
    return sendSocket(qq{var.get $name});
}

sub setBool {
    my $name  = shift;
    my $value = shift;
    return sendSocket(qq{var.set $name=$value});
}

sub getString {
    my $name   = shift;
    my $result = sendSocket(qq{var.get $name});
    $result =~ s/^"// if defined $result;
    $result =~ s/"$// if defined $result;
    return $result;
}

sub setString {
    my $name  = shift;
    my $value = shift;
    return sendSocket(qq{var.set $name="$value"});
}

sub sendSocket {
    my $command = shift;
    if ( defined $socketPath ) {
        my $result = sendFileSocket($command);
        return undef unless defined $result;
        if ( $result =~ /Connection timed out/ ) {
            closeFileSocket();
            Log::debug( 1, "retry ..." );
            $result = sendFileSocket($command);
        }
        return $result;
    }
    if ( ( defined $hostname ) && ( defined $port ) ) {
        my $result = sendTelnetSocket($command);
        return undef unless defined $result;
        if ( $result =~ /Connection timed out/ ) {
            closeTelnetSocket();
            Log::debug( 1, "retry ..." );
            $result = sendTelnetSocket($command);
        }
        return $result;
    }
    Log::warn("neither liquidsoap unix socket is configured nor telnet host and port");
    return;
}

sub closeSocket {
    closeFileSocket();
    closeTelnetSocket();
    return;
}

sub sendFileSocket {
    my $command = shift;
    Log::debug( 2, qq{send to socket "$command" via "$socketPath"} );

    unless ( defined $fileSocket ) {
        $fileSocket = IO::Socket::UNIX->new(
            Type    => SOCK_STREAM,
            Peer    => $socketPath,
            Timeout => 1,
        );
        Log::debug( 3, "opened $fileSocket" ) if defined $fileSocket;
    }

    unless ( defined $fileSocket ) {
        my $message = "liquidsoap is not available! Cannot connect to socket $socketPath to send $command";
        Log::error($message);
        return undef;
    }

    print $fileSocket $command . "\n";

    my $lines = '';
    while (<$fileSocket>) {
        my $line = $_;
        chomp $line;
        next if $line eq $command;
        unless ( $line =~ /^END/ ) {

            #Log::debug( 4, "line:" . $line );
            $lines .= $line . "\n";
            next;
        }
        last;
    }

    $lines =~ s/\s+$//;
    Log::debug( 3, "result:" . $lines );

    #closeFileSocket();

    return $lines;
}

sub closeFileSocket {
    return unless defined $fileSocket;
    Log::debug( 3, "close file socket" );
    print $fileSocket "exit\n" if defined $fileSocket;
    <$fileSocket>              if defined $fileSocket;
    close $fileSocket          if defined $fileSocket;
    $fileSocket = undef;
    return;
}

sub closeTelnetSocket {
    return unless defined $telnetSocket;
    Log::debug( 3, "close telnet socket" );
    print $telnetSocket "exit\n" if defined $telnetSocket;
    <$telnetSocket>              if defined $telnetSocket;
    close $telnetSocket          if defined $telnetSocket;
    $telnetSocket = undef;
    return;
}

sub sendTelnetSocket {
    my $command = shift;
    Log::debug( 2, qq{send command "$command" to $hostname:$port}, 'green' );

    unless ( defined $telnetSocket ) {
        Log::debug( 3, "open telnet socket to $hostname:$port" );
        $telnetSocket = IO::Socket::INET->new(
            PeerAddr => $hostname,
            PeerPort => $port,
            Proto    => "tcp",
            Type     => SOCK_STREAM,
            Timeout  => 1,
        );
        Log::debug( 3, "opened $telnetSocket" ) if defined $telnetSocket;
    }

    unless ( defined $telnetSocket ) {
        my $message = "liquidsoap is not available! Cannot connect to telnet $hostname:$port to send $command";
        Log::error($message);
        return undef;
    }

    # send command
    print $telnetSocket $command . "\n";

    # get response
    my $lines = '';
    return $lines unless defined $telnetSocket;
    while (<$telnetSocket>) {
        my $line = $_;
        chomp $line;
        next if $line eq $command;
        unless ( $line =~ /^END/ ) {
            Log::debug( 4, "line:" . $line );
            $lines .= $line . "\n";
            next;
        }
        last;
    }

    $lines =~ s/\s+$//;
    Log::debug( 2, "result:" . $lines, "red" );

    #closeTelnetSocket();

    return $lines;

}

# do not delete last line
1;
