package Config;

use strict;
use warnings;
use Config::General();
use Data::Dumper;
use Playout::Time();
use Playout::Log();

my $configFile = '/etc/playout/playout.conf';
my $lastReadConfig = 0;    # unix time configuration was read
my $config         = {};

sub setConfigFile {
    $configFile = shift;
    return;
}

sub getConfigFile {
    return $configFile;
}

sub get {
    my $key = shift;
    return $config->{$key};
}

sub hasChanged {
    my $modifiedAt = getFileModificationDate($configFile);
    return 0 unless defined $modifiedAt;
    return 0 if $modifiedAt eq $lastReadConfig;
    return 1;
}

sub setChanged {
    my $modifiedAt = getFileModificationDate($configFile);
    $lastReadConfig = $modifiedAt;
    return;
}

# update configuration from config file
sub update {
    return $config unless hasChanged();
    setChanged();

    $config = parse($configFile);

    $config->{verboseLevel}      = 1     unless defined $config->{verboseLevel};
    $config->{bufferDelay}       = 0     unless defined $config->{bufferDelay};
    $config->{shortScanInterval} = 60    unless defined $config->{shortScanInterval};
    $config->{fullScanInterval}  = 360   unless defined $config->{fullScanInterval};
    $config->{maxAudioLength}    = 10000 unless defined $config->{maxAudioLength};

    $config->{tempDir}  = '/var/tmp/'             unless defined $config->{tempDir};
    $config->{mediaDir} = '/media/audio/playout/' unless defined $config->{mediaDir};
    $config->{pidFile}  = '/var/run/playout/playout.pid' unless defined $config->{pidFile};
    $config->{timeZone} = 'Europe/Berlin' unless defined $config->{timeZone};

    return $config;
}

sub show {
    my $content = '';
    Log::objectInline($config);
    #for my $key ( sort keys %$config ) {
    #    $content .= sprintf( "%-20s = %s\n", $key, $config->{$key} );
    #}
    return $content;
}

# read a configuration file
sub parse {
    my $filename = shift;

    Log::error(qq{config file "$filename" does not exist}) unless -e $filename ;
    Log::error(qq{cannot read config "$filename"})         unless -r $filename ;

    my $configuration = Config::General->new($filename);
    return $configuration->{DefaultConfig}->{config};
}

# check the configuration and exit on errors
sub check {
    my $error   = 0;
    my $tempDir = $config->{tempDir};

    unless ( defined $tempDir ) {
        Log::error("tempDir not found at configuration!");
        $error++;
    }
    unless ( -e $tempDir ) {
        Log::error(qq{tempDir "$tempDir" does not exist!});
        $error++;
    }
    unless ( -d $tempDir ) {
        Log::error(qq{tempDir "$tempDir" has to be a directory!});
        $error++;
    }

    return $error;
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