package AudioCut;
use warnings;
use strict;

use Data::Dumper;

use Playout::Time();
use Playout::Log();
use Playout::Process();

my $outputDirectory = '';
my $startUpDuration = 0;

# add startUpDuration to current time to start earlier.
sub setStartUpDuration {
    $startUpDuration = shift;
    return;
}

sub setOutputDirectory {
    $outputDirectory = shift;
    return;
}

# return filename
# return undef on error
# return cutPoints if show is running
# return showIsOver if show is over

sub checkFile {
    my $file = shift;
    my $show = shift;

    my $start            = $show->{start};
    my $end              = $show->{end};
    my $scheduleDuration = $show->{scheduleDuration};
    my $audioDuration    = $show->{audioDuration};
    my $now              = $show->{now};

    Log::debug(
        1, qq{
check file           $file
check start          $start
check end            $end
check audioDuration  $audioDuration
check startup        $startUpDuration
check output dir     $outputDirectory
}
    );

    if ( $file eq '' ) {
        Log::warn("AudioCut: missing filename");
        return undef;
    }

    if ( $start eq '' ) {
        Log::warn("AudioCut: missing start");
        return undef;
    }

    my $result = { file => $file };

    if ( $outputDirectory ne '' ) {
        unless ( -e $outputDirectory ) {
            Log::warn("output directory '$outputDirectory' does not exist");
            $result->{error} = 1;
            return $result;
        }
        unless ( -w $outputDirectory ) {
            Log::warn("cannot write into directory '$outputDirectory'");
            $result->{error} = 1;
            return $result;
        }
    }

    my $cutPoints = getCutPoints( $start, $end, $now, $audioDuration, $scheduleDuration );

    # is start is to be cut off, set the cut points
    if ( $cutPoints->{start} > 0 ) {
        $result->{cutPoints} = $cutPoints;
        return $result;
    }

    # audio duration tolerance in seconds
    my $tolerance = 3;

    # set cut points if audio duration is more than tolerance seconds above scheduled length, it will be cutted
    if ( ( $cutPoints->{end} > 0 ) && ( $cutPoints->{end} < ( $audioDuration - $tolerance ) ) ) {
        $result->{cutPoints} = $cutPoints;
        return $result;
    }

    Log::info("no need for cut");
    return $result;
}

sub getCutPoints {
    my $start_time       = shift;
    my $end_time         = shift;
    my $now              = shift;
    my $audioDuration    = shift;    # from audio
    my $scheduleDuration = shift;    # scheduled

    #init cut points
    my $endCut = $audioDuration;

    #cut end if audio is longer than show duration
    if ( $audioDuration > $scheduleDuration ) {
        $endCut = $scheduleDuration;
    }

    my $startCut = 0;

    #cut start only, if currently running
    if ( ( $now . '' gt $start_time . '' ) && ( $now . '' lt $end_time . '' ) ) {

        #cut start
        my $running_time = $now->subtract_datetime($start_time);
        $startCut = Time::durationToSeconds($running_time);
    }

    my $cutPoints = {
        start => int($startCut),
        end   => int($endCut)
    };

    Log::debug(
        1, qq{
cut start:    $cutPoints->{start}
cut end:      $cutPoints->{end}
}
    );

    return $cutPoints;
}

# split mp3/ogg/flac file from start to end using mp3splt
# see http://mp3splt.sourceforge.net/mp3splt_page/home.php
# return file name
sub cut {
    my $filename  = shift;
    my $cutPoints = shift;

    my $outFile = getCutFilename( $filename, $outputDirectory, $cutPoints );
    return mp3splt( $filename, $outFile, $cutPoints );
}

sub removeOldFiles {
    my $now = time();
    my $DAY = 24 * 60 * 60;

    opendir( my $dh, $outputDirectory ) || Log::warn("cannot open $outputDirectory");
    return unless defined $dh;

    while ( my $file = readdir $dh ) {
        next unless $file =~ /playout\_/;
        $file = $outputDirectory . '/' . $file;
        my @stat = stat($file);
        next if scalar(@stat) == 0;
        my $modifiedAt = $stat[9];
        my $age        = ( $now - $modifiedAt ) / $DAY;
        next if ( $age < 1 );
        Log::debug( 1, sprintf( "remove old file '%s' with age of %d days", $file, $age ) );
        unlink $file || Log::warn("cannot remove $file");
    }
    closedir($dh);
    return;
}

#calc filename for cutted file from output dir and original filename
# return dir, filename and extension
sub getCutFilename {
    my $filename  = shift;
    my $dir       = shift;
    my $cutPoints = shift;

    #remove directory from filename
    if ( $filename =~ /\/([^\/]+)$/ ) {
        $filename = $1;
    }

    if ( $dir ne '' ) {

        #remove multiple trailing slashes from output directory
        $dir =~ s/\/+$//g;
        $dir .= '/';
    }

    #remove file extension from filename
    my $extension = '.' . ( split( /\./, $filename ) )[-1];
    $filename =~ s/$extension//g;

    return {
        dir       => $dir,
        file      => 'playout_' . $filename . '-cut-' . $cutPoints->{start} . '-' . $cutPoints->{end},
        extension => $extension
    };
}

# cut file into outFile (dir,file,ext) for given cutPoints (start,end)
# return full path of output
sub mp3splt {
    my $inFile    = shift;
    my $outFile   = shift;
    my $cutPoints = shift;

    my $startCut = secondsToMp3splt( $cutPoints->{start} );
    my $endCut   = secondsToMp3splt( $cutPoints->{end} );

    # separate option by directory and file
    my $options = '';
    $options = "-d $outFile->{dir}" if $outFile->{dir} ne '';

    #mp3splt will extend file by extension automatically...
    my $cmd = qq{mp3splt '$inFile' "$startCut" "$endCut" -o '$outFile->{file}' $options -Q};
    Log::debug( 1, $cmd );
    my ( $result, $exitCode ) = Process::execute($cmd);

    #return full path
    my $path = $outFile->{dir} . $outFile->{file} . $outFile->{extension};

    #escape ' in filename
    $path =~ s/\'/\'\\\'\'/g;
    Log::debug( 1, "cutted file='$path'" );
    return $path;
}

#get audio file duration using mp3info
#see http://ibiblio.org/mp3info/
sub getFileDuration {
    my $filename = shift;
    $filename =~ s/\'/\'\\\'\'/g;

    my $cmd = qq{mp3info -p '%S' '$filename'};
    Log::debug( 1, $cmd );
    my ( $result, $exitCode ) = Process::execute($cmd);
    $result =~ s/\s+//g;
    return -1 unless $result =~ /^\d+$/;
    return $result;
}

#convert seconds to mp3splt parameter time format "min.sec"
sub secondsToMp3splt {
    my $time = shift;
    my $min  = int( $time / 60 );
    $time -= $min * 60;
    my $sec = $time;
    return "$min.$sec";
}

# do not delete last line
1;
