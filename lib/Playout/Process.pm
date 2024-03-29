package Process;
use warnings;
use strict;

use Playout::Log();
use Data::Dumper;
use File::Basename();
use File::Path();
use IPC::Open3;
use IO::Select;
use Symbol 'gensym';

# build pid-file path from audio file name.
sub getPidFile {
    my $tempDir  = shift;
    my $filename = shift;

    my $pidFile = $filename;
    $pidFile =~ s/$tempDir\/?playout\_//g;
    $pidFile =~ s/$tempDir//g;

    $pidFile =~ s/[^a-zA-Z0-9\.\-]/\_/g;
    $pidFile =~ s/\_{2,99}/\_/g;

    $pidFile = $tempDir . '/playout_' . $pidFile . '.pid';
    $pidFile =~ s/\/{2,99}/\//g;
    Log::debug( 2, qq{get pid file: "$pidFile"} );
    return $pidFile;
}

# read the pid from the pid file
# on multiple pids use the last one
sub getPid {
    my $pidFile = shift;
    return 0 unless -e $pidFile;
    my $pid = 0;
    open my $file, "<", $pidFile or return Log::error("could not open $pidFile");
    while ( my $line = <$file> ) {
        chomp $line;
        $pid = $line if $line=~/^\d+$/;
    }
    close $file;
    return $pid;
}

sub isRunning {
    my $pid = shift;

    # return if process with pid is running

    if ( $pid <= 0 ) {
        Log::debug( 1, "cannot check process status without pid" );
        return 0;
    }
    Log::debug( 2, "check pid " . $pid );

    my $isRunning = kill 0, $pid;
    Log::debug( 2, "process state: $isRunning" );

    if ( $isRunning > 0 ) {
        Log::debug( 2, "process $pid is running..." );
        return 1;
    }
    Log::info("process $pid is not running...");
    return 0;
}

sub writePidFile {
    my $pidFile = shift;
    my $pid     = shift;

    my $dir   = File::Basename::dirname($pidFile);
    my $error = undef;
    File::Path::make_path( $dir, { error => $error } ) unless -d $dir;
    Log::warn($error) if defined $error;

    Log::info(qq{write pid file "$pidFile"});
    open( my $file, ">", $pidFile ) or return Log::warn(qq{cannot write pid file "$pidFile"});
    print $file "$pid";
    close($file);
    return;
}

# todo: remove pid file
sub stop {
    my $pid = shift;
    Log::debug( 0, "stop $pid" );
    return unless kill( 0, $pid );
    kill( 2, $pid );
    sleep(1);
    Log::debug( 0, "did not stop within a second, kill $pid" );
    return unless kill( 0, $pid );
    kill( 9, $pid );
    return;
}

sub execute {
    my ($result, $op, @cmd) = @_;
    $result //= '';
    my $capture_out = ($op =~ /^</);
    my $capture_err = ($op eq '<+ERR');
    my $pid = open3(undef, my $out, my $err = gensym, @cmd);
    Log::debug( 0, "PID=$pid for @cmd" );
    my $s = IO::Select->new();
    $s->add($out) if $capture_out;
    $s->add($err) if $capture_err;
    while( my @ready = $s->can_read ) {
        for my $fh (@ready) {
            $result .= <$fh> // '';
            $s->remove($fh) if eof($fh);
        }
    }
    close $err or die $!;
    close $out or die $!;
    waitpid $pid, 0;
    my $exitCode = $? >> 8;
    if ($exitCode == 0){
        Log::info qq{"@cmd" returned with exit code $exitCode};
    } else {
        Log::warn qq{"@cmd" returned with exit code $exitCode};
    }
    $_[0] = $result;
    return $exitCode;
}

# do not delete last line
1;
