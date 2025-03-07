#!/usr/bin/perl

use warnings;
use strict;
use utf8;

use Getopt::Long();

use Playout::Playout    ();
use Playout::Log        ();
use Playout::Config     ();
use Playout::Process    ();
use Playout::MediaFiles ();

$| = 1;

my ($configFile, $daemon, $help);

Getopt::Long::GetOptions(
    'c|config=s' => \$configFile,
    'd|daemon'   => \$daemon,
    'h|help'     => \$help
);

if ($help) {
    print getUsage();
    exit 0;
}

Playout::init({
    configFile => $configFile,
    daemon     => $daemon
});

my $pidFile = Config::get('pidFile');

if ($daemon) {
    Process::writePidFile($pidFile, $$);
    $SIG{HUP} = \&Log::openLog;
}

$SIG{INT} = sub {
    my $player = Playout::getPlayer();
    $player->exit() if $player;
    unlink $pidFile if -e $pidFile;
    exit;
};

Playout::run();

sub getUsage {
    return q{
playout.pl OPTION+

OPTION:

  --config  config file, default is /etc/playout/playout.conf
  --daemon  write log and pid file, reopen log on HUP
  --help    this page.
  
see man playout for details.    
};
}
