package Playout::Play;

use warnings;
use strict;

require Exporter;
my @ISA    = qw(Exporter);
my @EXPORT = qw(playShow prepareShow runShow);

sub new {
    my ( $class, $args ) = @_;
    return bless {%$args}, $class;
}

sub init {

}

sub exit {

}

sub isRunning {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;
}

sub prepare {
}

sub play {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;
}

sub stop {
}

return 1;
