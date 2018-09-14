#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use Data::Dumper;
use Getopt::Long();
use File::Path ('make_path');
use File::Copy ();
use JSON();
use LWP::UserAgent();

use Playout::Playout();
use Playout::Log();
use Playout::Config();
use Playout::MediaFiles();
use Playout::Time();

my $fileTypes = MediaFiles::getSupportedFormats();

my $configFile = undef;
my $from       = '';
my $till       = '';
my $verbose    = undef;
my $help       = undef;

Getopt::Long::GetOptions(
    "config=s"  => \$configFile,
    "from=s"    => \$from,
    "till=s"    => \$till,
    "verbose=i" => \$verbose,
    "help"      => \$help
);

if ($help) {
    print getUsage();
    exit 0;
}

Playout::init(
    {
        configFile => $configFile,
    }
);

my $syncSourceUrl = Config::get('syncGetScheduleUrl') || '';
Log::error( "cannot find syncGetScheduleUrl at " . Config::getConfigFile() ) if $syncSourceUrl eq '';

my $syncRecordingUrl = Config::get('syncGetRecordingUrl') || '';
Log::warn( "cannot find syncGetRecordingUrl at " . Config::getConfigFile() ) if $syncRecordingUrl eq '';

my $syncImageSourceUrl = Config::get('syncImageSourceUrl') || '';
Log::warn( "cannot find syncImageSourceUrl at " . Config::getConfigFile() ) if $syncImageSourceUrl eq '';

# add params from and till to sync_source_url
if ( $from =~ /(\d\d\d\d\-\d\d\-\d\d)/ ) {
    $syncSourceUrl .= '&from_date=' . $1;
}
if ( $till =~ /(\d\d\d\d\-\d\d\-\d\d)/ ) {
    $syncSourceUrl .= '&till_date=' . $1;
}

my $currentEvents = {};

my $userAgent = LWP::UserAgent->new;
Log::debug( 1, "sync_source_url=" . $syncSourceUrl );
my $events = getEventsFromJson( $userAgent, $syncSourceUrl );
$events = filterEvents($events);
$events = synchronizeStorage( $events, $syncRecordingUrl, $syncImageSourceUrl );

# filter events ascending by start
# filter events descending by upload date
# remove old events from list
sub filterEvents {
    my $events = shift;

    my $current = {};
    my $results = [];

    @$events = sort { ( $a->{start_datetime} cmp $b->{start_datetime} ) or ( $b->{uploaded_at} cmp $a->{uploaded_at} ) } @$events;
    for my $event (@$events) {
        my $id    = $event->{event_id};
        my $start = $event->{start_datetime};
        $current->{$id}->{$start}++;

        my $recordingIndex = $current->{$id}->{$start};
        $event->{recordingIndex} = $recordingIndex;

        # ignore older uploads
        next if $recordingIndex > 1;
        push @$results, $event;
    }

    return $results;
}

# for each event
# - create a directory
# - create a .info file containing event metadata
sub synchronizeStorage {
    my $events             = shift;
    my $syncRecordingUrl   = shift;
    my $syncImageSourceUrl = shift;

    for my $event (@$events) {
        my $dir = Time::datetimeToPath( MediaFiles::getMediaDir(), $event->{start_datetime} );

        # current is one for the first download
        my $start = $event->{start_datetime};
        $currentEvents->{$start}++;
        $event->{current} = $currentEvents->{$start};

        #Log::info( $dir . " $event->{event_id}" . " index:" . $event->{recordingIndex} . " $event->{uploaded_at} " . $event->{key} );

        my $errors = undef;
        File::Path::make_path( $dir, { group => 'playout', 'chmod' => 2775, error => $errors } ) unless ( -e $dir ) && ( -d $dir );

        #`chgrp playout '$dir'`;

        Log::error($errors) if defined $errors;
        Log::error( "could not create '$dir'. Please make sure:"
              . " 1) your default user is assigned to group 'playout' and "
              . " 2) user 'playout' can write to "
              . MediaFiles::getMediaDir() )
          unless -e $dir;

        my $infoFile = $dir . getEventInfoFilename($event);

        #print "$infoFile\n";

        # remove other info files
        for my $file ( glob( $dir . '*.info' ) ) {
            unlink $file unless $file eq $infoFile;
        }

        # update info file on change
        my $content    = getEventInfoContent($event);
        my $oldContent = '';
        $oldContent = loadFile($infoFile) if -e $infoFile;
        if ( $content ne $oldContent ) {
            Log::info("update '$infoFile'");
            saveFile( $infoFile, $content );
        }

        #save event image
        my $imageUrl = $event->{image};
        $imageUrl = $syncImageSourceUrl . $event->{image} if $syncImageSourceUrl ne '';
        saveImage( $userAgent, $imageUrl, $dir );

        #save upload
        saveRecording( $userAgent, $event, $syncRecordingUrl, $dir ) if defined $event->{path};
    }
}

sub disableRecordingsInDirectory {
    my $dir = shift;

    return unless -e $dir && -d $dir;

    #TODO: replace by readdir
    for my $fileType (@$fileTypes) {
        for my $file ( glob( $dir . "/*" . $fileType ) ) {
            Log::info("disable existing recording '$file'");
            File::Copy::move( $file, $file . '.off' );
        }
    }
}

sub saveRecording {
    my $userAgent        = shift;
    my $event            = shift;
    my $syncRecordingUrl = shift;
    my $dir              = shift;

    my $filename   = $event->{path};
    my $url        = $syncRecordingUrl . $filename;
    my $targetPath = $dir . '/' . $filename;

    # check for other entries that are newer
    my $uploadedAt = Time::datetimeToUnixTime( $event->{uploaded_at} );
    if ( $uploadedAt == -1 ) {
        Log::warn("skip download '$targetPath' again, could not converted uploaded_at to epoch");
        return;
    }

    #TODO: replace by readdir
    for my $fileType (@$fileTypes) {
        for my $file ( glob( $dir . '/*' . $fileType ) ) {
            my $date = MediaFiles::getFileModificationDate($file);
            Log::info( sprintf( qq{found %s, date="%s", uploadDate="%s"}, $file, $event->{uploaded_at}, Time::timeToDatetime($date) ) );
            if ( ( $date != -1 ) && ( $date > $uploadedAt ) ) {
                Log::warn("skip download '$targetPath', $file is in the same directory, but newer");
                return;
            }
        }
    }
    if ( -e $targetPath ) {
        chmod 0664, $targetPath if -f $targetPath;
        Log::info("skip download '$targetPath' again, it already exists");
        return;
    }

    if ( -e $targetPath . '.off' ) {
        Log::warn("skip download '$targetPath' again, it has been disabled");
        return;
    }

    my $temporaryPath = $targetPath . '.temp';
    Log::info("download '$url' to temporary target '$temporaryPath'");

    #my $response = $userAgent->get( $url, ':content_file' => $temporaryPath );
    my $response = $userAgent->mirror( $url, $temporaryPath );
    Log::info( $response->status_line );

    if ( ( $response->is_success ) || ( $response->{_rc} == 304 ) ) {
        disableRecordingsInDirectory($dir);
        File::Copy::move( $temporaryPath, $targetPath );
    } else {
        Log::error("could not save '$url' to '$temporaryPath'");
    }

    chmod 0664, $targetPath if -f $targetPath;
}

# create event filename optionally from series_name, title and event_id
sub getEventInfoFilename {
    my $event = shift;

    my $filename = $event->{full_title} . ' - ' . $event->{event_id} . '.info';
    $filename = escapeFilename($filename);
    return $filename;
}

# create event info from program, series_name, title and event_id
sub getEventInfoContent {
    my $event = shift;

    my $attributes = [];
    for my $attr ( 'event_id', 'location', 'path', 'uploaded_at', 'uploaded_by', 'size' ) {
        push @$attributes, $attr . ': ' . $event->{$attr} if defined $event->{$attr};
    }
    $attributes = join( "\n", @$attributes ) . "\n";

    my $areas = [];
    for my $area ( $event->{full_title}, $event->{excerpt}, $event->{content}, $attributes ) {
        $area .= "\n" unless $area =~ /\n$/;
        push @$areas, $area;
    }

    my $content = join( "--------------------\n", @$areas );
    return $content;
}

#remove unsafe characters from filename
sub escapeFilename {
    my $filename = shift;
    $filename =~ s/[^a-zA-Z0-9 \.\_\-\#]//g;
    $filename =~ s/\s+/ /g;
    return $filename;
}

#get all events from json
sub getEventsFromJson {
    my $userAgent     = shift;
    my $syncSourceUrl = shift;
    Log->info("read events from '$syncSourceUrl'");

    my $content  = '';
    my $response = $userAgent->get($syncSourceUrl);

    if ( $response->is_success ) {
        $content = $response->decoded_content;
    } else {
        die $response->status_line;
    }

    my $events = JSON::decode_json($content);
    my @events = ();
    @events = @{ $events->{events} } if defined $events->{events};
    Log::error("no event found") if @events == 0;

    return $events->{events};
}

sub loadFile {
    my $filename = shift;
    my $content  = '';
    open my $file, "<:utf8", $filename || warn("cant read file '$filename'");
    while (<$file>) {
        $content .= $_;
    }
    return $content;
}

#save utf-8 file
sub saveFile {
    my $filename = shift;
    my $content  = shift;

    chmod 0664, $filename if ( -f $filename ) && ( !-w $filename );

    my $result = open my $file, ">:utf8", $filename;
    unless ($result) {
        warn("cannot write file '$filename'");
        return;
    }
    print $file $content;
    close $file;

    chmod 0664, $filename if -f $filename;
}

#save image in raw mode
sub saveImage {
    my $userAgent = shift;
    my $url       = shift;
    my $dir       = shift;

    return unless defined $url;

    my $imageName = ( split( /\//, $url ) )[-1];
    my $path      = $dir . "/" . $imageName;
    my $response  = $userAgent->mirror( $url, $path );
    chmod 0664, $path if -f $path;
    Log::info( "imageUrl='$url', file='$path', result='" . $response->status_line . "'" ) unless $response->{_rc} == 304;
}

sub getUsage {
    return qq|
usage: $0 --from yyyy-mm-dd --till yyyy-mm-dd --verbose [level]

playout_sync.pl imports events from an external data source. 
playout_sync.pl will create all the neccessary directories (containing date and time in the path).
After directories got created, you only need to put audio files into directories to play them.

Events are read from an JSON source <syncGetScheduleUrl> configured at /etc/playout/playout.conf
One can filter the date range by using parameters --from and --till which append '&from_date=yyyy-mm-dd' and '&till_date=yyyy-mm-dd' to the URL.

media archive directory should have group playout, permissions 775 and have the group setgid bit set.
The user should be added to group playout.

chgrp playout /mnt/archive/playout
chmod g+s /mnt/archive/playout

The URL response document should consist of an "events"-list of single playout events.
Directories will be created from event attribute "start_datetime" attribute [yyyy-mm-ddThh:mm:ss].
Attributes "series_name", "title", "event_id" are used to build a text info filename.
Each info file contains the attributes "excerpt", "content", "location".
If an "image" URL attribute is given, the image will be downloaded and put into the directory.

Example source JSON document:
{
    "events":[
        {
            "start_datetime":"2014-03-14T20:00:00"
            "series_name":"series A", "title":"A", "event_id":"1",
            "excerpt":"short text A", "content":"long text A", "location":"at home",
            "image":"http://localhost/imageA.png"
        },{
            "start_datetime":"2014-03-14T21:00:00"
            "series_name":"series B", "title":"B", "event_id":"2",
            "excerpt":"short text B", "content":"long text B", "location":"at work",
            "image":"http://localhost/imageB.png"
        }
    ]
}

This example will create 2 directories 2014/03/14/20-00 and 2014/03/14/21-00 at the mediaDir.
A text file .info and the downloaded image will be put into each directory.
if you put audio files at a directory, playout will play them at scheduled time.

If the source contains links to remote audio files there will be downloaded relative to <syncGetRecordingUrl>.
Events require fields <uploaded_at> with timestamp and <path> with an relative path.  

|;
}
