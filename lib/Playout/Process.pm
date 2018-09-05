package Process;
use warnings;
use strict;

use Playout::Log();
use Data::Dumper;
use File::Basename();
use File::Path();

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
    open my $file, "<", $pidFile;
    unless ($file) {
        Log::error("could not open $pidFile");
        return;
    }
    while ( (<$file>) ) {
        $pid = $_;
    }
    close $file;
    $pid =~ s/[^\d]//g;
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
    open( my $file, ">", $pidFile );
    unless ($file) {
        Log::warn(qq{cannot write pid file "$pidFile"});
        return;
    }
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
    my $cmd = shift;

    Log::exec($cmd);
    my $result = scalar(`$cmd`) || '';
    my $exitCode = $? >> 8;
    Log::info($result) if ( $result ne '' );
    if ($exitCode) {
        my $message = "exitCode:" . $exitCode;
        $message .= " : " . $@ if ($@);
        Log::error($message);
    }
    return ( $result, $exitCode );
}

# do not delete last line
1;
