package MediaFiles;

use warnings;
use strict;

use File::Basename ();
use File::Find     ();

use Storable();
use File::Copy qw(move);
use Data::Dumper;

use Playout::Log();
use Playout::Time();
use Playout::Process();

my $mediaDir         = '/media/Playout/';
my $cacheFile        = '/tmp/playout.dat';
my $cache            = {};
my $fullScanInterval = 3600;
my $lastFullScan     = 0;

my $shortScanInterval = 0;
my $lastShortScan     = 0;
my $usePlot           = 0;
my $syncPlotTargetDir = undef;
my $userInfo          = undef;

my $supportedFormats = [ '.ogg', '.mp3', '.wav', '.flac', '.aac', '.aiff', '.m4a', '.m4b', '.mpc', '.oga', '.opus', '.stream' ];

#TODO: move initialization to init()
my $supportedFormatPattern = join( '|', map { quotemeta $_ } @$supportedFormats );

# initialize cache
sub init {
    my $options = shift;

    $supportedFormatPattern = join( '|', map { quotemeta $_ } @$supportedFormats );

    setMediaDir( $options->{mediaDir} )    if defined $options->{mediaDir};
    setCacheFile( $options->{cache_file} ) if defined $options->{cache_file};
    $cache = readCache();

    # check if rms plot is supported
    my ( $result, $exitCode ) = Process::execute( 'which plotRms 2>&1' );
    $usePlot = 1 if $exitCode == 0;
    setSyncPlotTargetDir( $options->{syncPlotTargetDir} ) if defined $options->{syncPlotTargetDir};
}

sub getSupportedFormats {
    return $supportedFormats;
}

sub getCache {
    return $cache;
}

sub setCacheFile {
    $cacheFile = shift;
}

sub getCacheFile {
    return $cacheFile;
}

sub setMediaDir {
    $mediaDir = shift;
}

sub getMediaDir {
    return $mediaDir;
}

sub getNextFullScan {
    return $lastFullScan + $fullScanInterval - time;
}

sub getFullScanInterval {
    return $fullScanInterval;
}

sub setFullScanInterval {
    $fullScanInterval = shift;
}

sub forceFullScan {
    $lastFullScan = 0;
}

sub getNextShortScan {
    return $lastShortScan + $shortScanInterval - time;
}

sub getShortScanInterval {
    return $shortScanInterval;
}

sub setShortScanInterval {
    $shortScanInterval = shift;
}

sub forceShortScan {
    $lastShortScan = 0;
}

sub getSyncPlotTargetDir {
    return $syncPlotTargetDir;
}

sub setSyncPlotTargetDir {
    $syncPlotTargetDir = shift;
}

sub getUserInfo {
    return $userInfo if defined $userInfo;
    $userInfo = `id`;
    return $userInfo;
}

# print list of media files
sub listAudio {
    for my $path ( sort keys %$cache ) {
        next if $path eq 'date';
        next if $path eq 'info';
        Log::info( sprintf( "% 4d secs %s %s", $cache->{$path}->{duration} || 0, $path || '', $cache->{$path}->{playoutFile} || '' ) );
    }
}

sub listInfo {
    Log::info("show info");
    for my $datetime ( sort keys %{ $cache->{info} } ) {
        for my $path ( sort keys %{ $cache->{info}->{$datetime} } ) {
            Log::info( sprintf( "%s %s", $datetime, $path ) );
        }
    }
}

# get minimum future date, given by expires list (epoch) and scanned files (yyyy-mm-dd)
# return undef if there is not enough time to do something
sub getMinimumExpireTime {
    my $expires = shift;
    my $files   = shift;

    Log::debug( 0, "MediaFiles::getMinimumExpireTime(): missing expires list" ) unless defined $expires;
    Log::debug( 0, "MediaFiles::getMinimumExpireTime(): missing files hash" )   unless defined $files;

    my $now      = time();
    my $minStart = $now + 3600;

    # iterate over given expire list
    for my $start (@$expires) {
        next unless defined $start;
        next unless $start > $now;
        $minStart = $start if $start < $minStart;
    }

    # iterate over scanned files
    for my $path ( keys %$files ) {
        next unless defined $path;
        my $datetime = $files->{$path}->{start};
        next unless defined $datetime;
        my $start = Time::datetimeToUnixTime($datetime);
        next unless defined $start;
        next unless $start > $now;
        $minStart = $start if $start < $minStart;
    }

    Log::debug( 1, "file scan will be stopped at " . Time::timeToDatetime($minStart) );
    return $minStart;
}

# scan all dates in mediaDir for changes
# timeout: max running time
sub fullScan {
    my $options = shift;

    Log::debug( 1, qq{full scan "mediaDir", save to "$cacheFile"} );
    my $files = scanDir();
    my $expireTime = getMinimumExpireTime( $options->{expires}, $files );

    my $result = compare(
        {
            cache         => $cache,
            files         => $files,
            expireTime    => $expireTime,
            maxProcessing => $options->{maxProcessing}
        }
    );

    # do not set scan time if not finished
    if ( $result->{expired} ) {
        Log::debug( 1, "stop scan, due to expired" );
        return $result->{changed};
    } else {
        Log::debug( 1, "full scan finished" );
        $lastFullScan  = time();
        $lastShortScan = time();
        return $result->{changed};
    }
}

# scan yesterday, today and tomorrow for file changes
sub shortScan {
    my $options = shift;

    Log::debug( 1, qq{short scan "$mediaDir", save to "$cacheFile"} );
    my $datetime_utc = Time::getUtcDatetime();
    my $now          = Time::getToday($datetime_utc);
    my ( $start_date, $start_time ) = split( / /, $now );
    my $prev_date = Time::getYesterday($datetime_utc);
    my $next_date = Time::getTomorrow($datetime_utc);

    my $updateAudio = 0;
    for my $date ( $prev_date, $start_date, $next_date ) {
        my $files = scanDir( { date => $date } );
        my $expireTime = getMinimumExpireTime( $options->{expires}, $files );

        my $result = compare(
            {
                cache        => $cache,
                files        => $files,
                date         => $date,
                expireTime   => $expireTime,
                maxProessing => $options->{maxProcessing},
            }
        );
        $updateAudio += $result->{changed};
        if ( $result->{expired} ) {
            Log::debug( 1, "stop scan, due to expired" );
            return $updateAudio;
        }
    }
    Log::debug( 2, "short scan finished" );
    $lastShortScan = time();
    return $updateAudio;
}

# check cache for changes
# return {changed, expired}
sub compare {
    my $options = shift;

    my $cache = $options->{cache};
    my $files = $options->{files};
    my $maxProcessing = $options->{maxProcessing};

    # set path to optional date
    my $dir  = undef;
    my $date = $options->{date};
    if ( defined $date ) {
        if ( $date =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)/ ) {
            $dir = $mediaDir . '/' . $1 . '/' . $2 . '/' . $3 . '/';
            $dir =~ s/\/+/\//g;
        }
    }

    my $update      = 0;
    my $updateAudio = 0;
    my $expired     = 0;

    # filter files
    my $filesToAnalyse = [];
    my $now            = time;
    for my $path ( keys %$files ) {
        my $file = $files->{$path};
        next unless defined $file;
        next unless defined $file->{start};

        my $extension = undef;
        if ( $path =~ /($supportedFormatPattern)$/i ) {
            $extension = $1;
        } elsif ( $path =~ /(\.info)$/ ) {
            $extension = $1;
        }
        next unless defined $extension;

        next if ( defined $dir ) && ( !isLocatedAt( $path, $dir ) );
        next unless hasChanged( $path, $file->{modified_at}, $cache );

        $file->{start_epoch} = Time::datetimeToUnixTime( $file->{start} );
        next unless defined $file->{start_epoch};

        $file->{extension} = $extension;

        # store absolute relative duration from now to start
        $file->{distance} = abs( $now - $file->{start_epoch} );

        push @$filesToAnalyse, $path;
    }

    @$filesToAnalyse = sort { $files->{$a}->{distance} <=> $files->{$b}->{distance} } @$filesToAnalyse;

    # sort by absolute duration from now to start
    my $expireTime = $options->{expireTime};
    my $analysed=0;
    for my $path (@$filesToAnalyse) {
        my $file        = $files->{$path};
        my $start       = $file->{start};
        my $start_epoch = $file->{start_epoch};

        # check to abort due to expiration (if already running or going to run)
        if ( defined $expireTime ) {
            my $now = time;
            if (

                # start of event is more than 3 minutes in the future
                ( $start_epoch > $now + 3 * 60 )

                # time is to be expired in less than 3 minutes
                && ( $now > $expireTime - 3 * 60 )
              )
            {
                Log::warn( qq{abort scan of $path, expireTime=} . Time::timeToDatetime($expireTime) );
                $expired = 1;
                last;
            }
        }

        # skip if file has beed modified in the last 3 seconds
        if ( $files->{$path}->{modified_at} > $now - 3 ) {
            Log::debug( 0, qq{skip "$path" because updated within last 3 seconds} );
            next;
        }

        $update = 1;
        $updateAudio = 1 if $path =~ /($supportedFormatPattern)$/i;

        my $entry     = {};
        my $extension = $file->{extension};
        if ( $extension =~ /\.info/ ) {
            next unless defined $start;

            # add name of .info file by date to 'info'
            $entry->{file} = $path;
            $entry->{name} = File::Basename::basename($path);
            $entry->{name} =~ s/\.info$//;

            $cache->{info}->{$start}->{$path} = $entry;
            Log::debug( 3, qq{add "$path" to info} );
        } else {
            $analysed++;

            # audio files
            $entry->{start_epoch} = $start_epoch;

            $entry->{file}        = $path;
            $entry->{name}        = $path;
            $entry->{modified_at} = $files->{$path}->{modified_at};
            $entry->{start}       = $start;

            chmod 0664, $path unless -w $path;
            my $error;
            if ( $path =~ /\.stream$/ ) {
                $entry = parseStreamFile( $path, $entry );
                next unless $entry;
            } else {
                $entry = getMetadata( $path, $entry );
                $entry = analyseAudio( $path, $entry );
            }

            $entry->{end_epoch} = $entry->{start_epoch} + int( 0.5 + $entry->{duration} )
              if ( defined $entry->{start_epoch} ) && ( defined $entry->{duration} );

            # store file
            $cache->{$path} = $entry;
            Log::info(qq{add "$path"});
            Log::objectInline( 0, $entry );

            # store media files by date
            my $date = Time::pathToDate( $mediaDir, $path );
            next unless defined $date;
            my $status = Shows::getStatus($entry);
            next unless $status;

            $cache->{date}->{$date}->{$path} = $cache->{$path};
            Log::debug( 3, qq{add "$path" to date} );

            if ( $status->{isRunning} ) {
                Log::debug( 1, qq{ stop scan, due to entry found '$path' is still running} );
                last;
            }

            # if more files to be processed, mark as interrupt but do not finish scan
            if ( $maxProcessing && $analysed >= $maxProcessing ) {
                my $left = @$filesToAnalyse - $analysed;
                Log::debug( 1, qq{ interrupt scan, $left files left} );
                $expired = 1;
                last;
            }
        }
    }

    # remove outdated files
    for my $path ( keys %$cache ) {
        next if $path eq 'date';
        next if $path eq 'info';
        next if ( defined $dir ) && ( !isLocatedAt( $path, $dir ) );
        unless ( defined $files->{$path} ) {
            $update = 1;
            $updateAudio = 1 if $path =~ /($supportedFormatPattern)$/i;
            Log::info(qq{remove "$path" from database});
            delete $cache->{$path};
        }
    }

    # remove outdated entries from date cache
    for my $date ( keys %{ $cache->{date} } ) {
        for my $path ( keys %{ $cache->{date}->{$date} } ) {
            next if ( defined $dir ) && ( !isLocatedAt( $path, $dir ) );
            unless ( defined $files->{$path} ) {
                $update = 1;
                Log::debug( 3, qq{remove audio "$path" from $date} );
                delete $cache->{date}->{$date}->{$path};
            }
        }
        delete $cache->{date}->{$date} if scalar keys %{ $cache->{date}->{$date} } == 0;
    }

    # remove outdated entries from info cache
    for my $date ( keys %{ $cache->{info} } ) {
        for my $path ( keys %{ $cache->{info}->{$date} } ) {
            next if ( defined $dir ) && ( !isLocatedAt( $path, $dir ) );
            unless ( defined $files->{$path} ) {
                $update = 1;
                Log::debug( 3, qq{delete info "$path" from $date} );
                delete $cache->{info}->{$date}->{$path};
            }
        }
        delete $cache->{info}->{$date} if scalar keys %{ $cache->{info}->{$date} } == 0;
    }

    # link next and previous audio files
    my $prev = undef;
    for my $path ( sort keys %$cache ) {
        next if $path eq 'date';
        next if $path eq 'info';
        unless ( defined $prev ) {
            $prev = $path;
            next;
        }

        #set previous file on change
        if ( defined $cache->{$path}->{prev} ) {
            unless ( $cache->{$path}->{prev} eq $prev ) {
                $cache->{$path}->{prev} = $prev;
                Log::debug( 3, qq{update "$prev" as previous of "$path"} );
                $update = 1;
            }
        } else {
            Log::debug( 3, qq{set "$prev" as previous of "$path"} );
            $cache->{$path}->{prev} = $prev;
            $update = 1;
        }

        #set next file on change
        if ( defined $cache->{$prev}->{next} ) {
            unless ( $cache->{$prev}->{next} eq $path ) {
                Log::debug( 3, qq{update "$path" as next of "$prev"} );
                $cache->{$prev}->{next} = $path;
                $update = 1;
            }
        } else {
            Log::debug( 3, qq{set "$path" as next of "$prev"} );
            $cache->{$prev}->{next} = $path;
            $update = 1;
        }
        $prev = $path;
    }

    setCache($cache) if ( $update == 1 );
    return {
        changed => $updateAudio,
        expired => $expired
    };
}

sub getMetadata {
    my $path = shift;
    my $result = shift || {};

    my $info = {};

    my $mediaInfo = "/usr/bin/mediainfo";

    unless ( -e $mediaInfo ) {
        Log::warn("cannot find $mediaInfo");
        return {};
    }

    open my $cmd, '-|', "$mediaInfo -f '$path' 2>&1";
    unless ($cmd) {
        Log::warn "could not execute $mediaInfo";
        return {};
    }
    while (<$cmd>) {
        my $line   = $_;
        my @fields = split( /\s+\:\s+/, $line, 2 );
        my $key    = $fields[0];
        my $value  = $fields[1];
        next unless @fields == 2;
        $key =~ s/^\s+//g;
        $key =~ s/\s+$//g;
        $value =~ s/^\s+//g;
        $value =~ s/\s+$//g;

        if (   ( $key eq 'Format' )
            || ( $key eq 'Format version' )
            || ( $key eq 'Format settings' )
            || ( $key eq 'Format profile' )
            || ( $key eq 'Writing library' ) )
        {
            $info->{$key} = $value;
        }

        if ( ( $key eq 'Bit rate mode' ) && ( $value =~ /^[A-Z]+$/ ) ) {
            $info->{$key} = $value;
        }

        if (   ( $key eq 'Bit rate' )
            || ( $key eq 'Duration' )
            || ( $key eq 'Channel(s)' )
            || ( $key eq 'Sampling rate' )
            || ( $key eq 'Stream size' ) )
        {
            $info->{$key} = $value if $value =~ /^\d+$/;
        }
    }
    close $cmd;

    $info->{"Duration"} = int( $info->{"Duration"} / 1000 ) if defined $info->{"Duration"};
    $info->{"Bit rate"} /= 1000 if defined $info->{"Bit rate"};

    for my $key ( keys %$info ) {
        my $newKey = lc $key;
        $newKey =~ s/\s+/_/g;
        $newKey =~ s/[^a-z\_]//g;
        $newKey =~ s/bit_rate/bitrate/g;
        $result->{$newKey} = $info->{$key};
    }
    return $result;
}

# parse duration, stream url and fallback url from a .stream file,
# first valid items are used any following are ignored

# #EXTINF:504,Bob Marley - Buffalo Soldier
# http://stream
# http://fallback
#
# or
#
# 3600
# http://stream
# http://fallback

sub parseStreamFile {
    my $filename = shift;
    my $result = shift || {};

    Log::debug( 1, "parse playlist $filename" );
    my $file;
    unless (open ($file, '<', $filename)){
        Log::warn qq{could not read "$filename"};
        return undef;
    };
    
    while (<$file>) {
        my $line = $_;
        unless ( defined $result->{duration} ) {
            if ( $line =~ /#EXTINF:(\d+)/ ) {
                $result->{duration} = $1;
            } elsif ( $line =~ /^\s*(\d+)\s*$/ ) {
                $result->{duration} = $1;
            }
        }
        if ( $line =~ /^\s*http\:/ ) {
            my $url = $line;
            $url =~ s/\s+$//g;
            $url =~ s/^\s+//g;
            $result->{url}         = $url unless defined $result->{url};
            $result->{fallbackUrl} = $url unless defined $result->{fallbackUrl};
        }
    }
    close $file;
    Log::debug( 1, qq{found duration=$result->{duration}, url="$result->{url}", fallback="$result->{fallbackUrl}"} );
    return $result;
}

sub isLocatedAt {
    my $path = shift;
    my $dir  = shift;

    return 0 unless defined $path;
    return 0 unless defined $dir;
    Log::debug( 2, qq{'$path' '$dir' '} . substr( $path, 0, length($dir) ) . "'" );
    return 1 if substr( $path, 0, length($dir) ) eq $dir;
    return 0;
}

sub getPlayoutFile {
    my $event = shift;
    return undef unless defined $event->{file};
    my $path = $event->{file};
    return undef unless defined $cache->{$path};
    my $entry = $cache->{$path};
    return $entry->{playoutFile} if defined $entry->{playoutFile};
    return $entry->{file}        if defined $entry->{file};
    return undef;
}

sub setPlayoutFile {
    my $path        = shift;
    my $playoutFile = shift;

    return undef unless defined $cache->{$path};

    my $entry  = $cache->{$path};
    my $update = 0;
    if ( defined $entry->{playoutFile} ) {
        if ( $entry->{playoutFile} ne $playoutFile ) {
            Log::debug( 1, qq{update playout file "$playoutFile"} );
            $entry->{playoutFile} = $playoutFile;
            $update = 1;
        }
    } else {
        Log::debug( 1, qq{add playout file "$playoutFile"} );
        $entry->{playoutFile} = $playoutFile;
        $update = 1;
    }

    if ( $update == 1 ) {
        my $date = Time::pathToDate( $mediaDir, $path );
        if ( defined $date ) {
            $cache->{date}->{$date}->{$path}->{playoutFile} = $playoutFile;
            Log::debug( 1, qq{add playout file date for "$path"} );
        }
        setCache($cache);
    }
}

sub getDates {
    my @dates = keys %{ $cache->{date} };
    return \@dates;
}

sub getFilesByDate {
    my $date = shift;
    return $cache->{date}->{$date};
}

sub get {
    my $path = shift;
    return unless defined $path;
    return $cache->{$path} if defined $cache->{$path};
    return undef;
}

# detect duration, rms_left and rms_right
sub analyseAudio {
    my $path  = shift;
    my $entry = shift;

    Log::info("analyse '$path'");

    my $error = undef;

    # get duration and rms, plot rms only if rms is installed
    ( $entry, $error ) = getDataFromPlotRms( $path, $entry );
    return $entry unless $error;

    # fallback to soxi if plotRms is not installed
    ( $entry, $error ) = getDurationFromSoxi( $path, $entry );
    Log::info("finish analyse '$path'");

    return $entry;
}


sub getDataFromPlotRms {

    my $path  = shift;
    my $entry = shift;

    my $error = undef;

    if ( $usePlot == 0 ) {
        my $error = "package rms not installed\n";
        Log::debug( 1, $error ) if defined $error;
        return ( $entry, $error );
    }

    my $targetDir = File::Basename::dirname($path);
    unless ( -w $targetDir ) {
        $error = "cannot write to directory '$targetDir'";
        Log::error($error);
        Log::error( getUserInfo() );
        return ( $entry, $error );
    }

    # make image filename compatible to url
    my $targetFile = File::Basename::basename($path);
    $targetFile =~ s/\#/Nr\./g;
    $targetFile =~ s/[\?\&]+/_/g;
    $targetFile =~ s/\_+/\_/g;

    my $result = '';
    for my $suffix ( 'png', 'svg' ) {
        my $imageFile = "$targetDir/$targetFile.$suffix";

        ( $result, my $exitCode ) = Process::execute( "plotRms -i '$path' -o '$imageFile'" . ' 2>&1' );

        # this will not be handled as reason for fallback to other detection method
        if ( $exitCode != 0 ) {
            my $error = qq{could not analyse and plot "$path" by 'plotRms', exitCode=$exitCode};
            Log::warn($error);
            Log::debug( 1, $result );
        }

        if ( -e $imageFile ) {
            chmod 0664, $imageFile;
            # both svg and png files will be uploaded, but only svg will be added to database as rms_image 
            $entry->{rms_image} = getPathRelativeToMediaDir($imageFile);
            syncPlotFileTarget( $entry->{rms_image} );
        }
    }

    for my $line ( split( /\n/, $result ) ) {
        if ( $line =~ /duration\=([\-\d\.]+)$/ ) {
            $entry->{duration} = $1;
        } elsif ( $line =~ /rmsLeft\=([\-\d\.]+)$/ ) {
            $entry->{rms_left} = $1;
        } elsif ( $line =~ /rmsRight\=([\-\d\.]+)$/ ) {
            $entry->{rms_right} = $1;
        }
    }

    unless ( defined $entry->{duration} ) {
        $error = "could not detect duration using rmsPlot\n";
        Log::warn($error);
    }

    return ( $entry, $error );
}

# get metadata using soxi
sub getDurationFromSoxi {
    my $path  = shift;
    my $entry = shift;

    my $error = "could not get duration from soxi";
    Log::info(qq{get audio duration for "$path" from soxi});
    if ( $path =~ /\.(mp3|flac)$/i ) {
        my ( $result, $exitCode ) = Process::execute( qq{soxi -D '$path'} . ' 2>&1' );

        if ( $result =~ /([\d\.]+)/ ) {
            $entry->{duration} = $1;
            $error = undef;
        }
    }
    Log::debug( 1, $error ) if defined $error;
    return ( $entry, $error );
}

# copy rms_image to target if configured by "syncPlotTargetDir"
sub syncPlotFileTarget {
    my $sourceFile = shift;

    my $mediaDir = getMediaDir();
    return unless defined $mediaDir;

    my $syncPlotTargetDir = getSyncPlotTargetDir();
    unless ( defined $syncPlotTargetDir ) {
        Log::warn("syncPlotTargetDir is disabled");
        return;
    }

    unless ( defined $sourceFile ) {
        Log::warn("no rms_image given to be synced");
        return;
    }

    # use file name relative to mediaDir
    chdir($mediaDir);
    unless ( -e $sourceFile ) {
        Log::warn(qq{cannot find "$sourceFile" relative to mediaDir "$mediaDir"});
        return;
    }

    my ( $result, $exitCode ) = Process::execute( "rsync -avR '" . $sourceFile . "' '" . $syncPlotTargetDir . "'" . ' 2>&1' );
    Log::warn(qq{could not copy "$mediaDir/$sourceFile" to "$syncPlotTargetDir": "$result"}) if ( $exitCode != 0 );
}

sub hasChanged {
    my $filePath       = shift;
    my $fileModifiedAt = shift;
    my $cache          = shift;
    return 1 unless defined $cache->{$filePath};
    return 1 unless defined $cache->{$filePath}->{modified_at};
    return 1 unless $fileModifiedAt == $cache->{$filePath}->{modified_at};
    return 0;
}

# scan files with start and modification date recursively starting at directory
# if no date is given a full scan is performed
my $limitDate = '';

sub scanDir {
    my $options = shift;

    my $date = $options->{date};

    my $dir = $mediaDir . '/';
    if ( defined $date ) {

        # add optional date to path
        if ( $date =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)/ ) {
            $dir .= $1 . '/' . $2 . '/' . $3 . '/';
        }
    }
    $dir =~ s/\/+/\//g;
    $mediaDir =~ s/\/+$//g;
    Log::debug( 2, qq{scan dir "$dir"} );
    our $files = {};
    return $files unless -e $dir;

    # store files up to 7 days in past
    $limitDate = Time::getUtcDatetime()->add( days => -7 )->ymd();

    sub wanted {
        my $date = Time::pathToDate( $mediaDir, $File::Find::name );
        return unless defined $date;
        return unless $date gt $limitDate;
        Log::debug( 3, "$date after limit of $limitDate" );
        my $mtime = ( stat($_) )[9];
        $files->{$File::Find::name} = {
            modified_at => $mtime,
            start       => Time::pathToDatetime( $mediaDir, $File::Find::name ),
        };
    }
    File::Find::find( { wanted=>\&wanted, follow_fast=>1 }, $dir );

    # on multiple audio files at same time ignore all but the first one
    my $previousFile  = undef;
    my $previousStart = undef;
    for my $path ( sort keys %$files ) {
        next unless $path =~ /($supportedFormatPattern)$/i;
        my $start = $files->{$path}->{start};
        if ( defined $previousFile ) {
            if ( $start eq $previousStart ) {
                if ( lc($path) lt lc($previousFile) ) {
                    Log::error(qq{audio file "$previousFile" - ignore, multiple files at same time});
                    delete $files->{$previousFile};
                } else {
                    Log::error(qq{audio file "$path" - ignore, multiple files at same time});
                    delete $files->{$path};
                }
            }
        }
        $previousFile  = $path;
        $previousStart = $start;
    }

    return $files;
}

# load metadata
sub readCache {
    my $cacheFile = getCacheFile();
    Log::info(qq{read file cache from "$cacheFile"});
    return {} unless -e $cacheFile;
    my $cache = Storable::lock_retrieve($cacheFile);
    return $cache;
}

# write metadata
sub setCache {
    my $cache = shift;

    my $cacheFile = getCacheFile();
    if ( ( -e $cacheFile ) && ( !-w $cacheFile ) ) {
        Log::error("cannot write $cacheFile");
        Log::error( getUserInfo() );
    }
    Log::info(qq{store file cache at "$cacheFile"});
    Storable::lock_store( $cache, $cacheFile );
}

sub getPathRelativeToMediaDir {
    my $path = shift;

    return undef unless defined $path;

    my $mediaDir = getMediaDir();
    return undef unless defined $mediaDir;

    # remove mediaDir from path
    $mediaDir = quotemeta($mediaDir);
    $path =~ s/$mediaDir//;

    # remove double slashes
    $path =~ s/\/+/\//g;

    # remove starting slashes
    $path =~ s/^\///g;

    return $path;
}

sub checkMediaDir {
    my $errors = 0;
    unless ( defined $mediaDir ) {
        Log::error(qq{mediaDir not found at configuration!});
        $errors++;
    }
    unless ( -e $mediaDir ) {
        Log::error(qq{mediaDir "$mediaDir" does not exist!});
        $errors++;
    }
    unless ( -d $mediaDir ) {
        Log::error(qq{mediaDir "$mediaDir" has to be a directory!});
        $errors++;
    }
    return $errors;
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
