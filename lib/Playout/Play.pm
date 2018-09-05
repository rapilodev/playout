package Playout::Play;

use warnings;
use strict;

use base 'Exporter';
my @EXPORT_OK = ( 'playShow', 'prepareShow', 'runShow' );

sub new {
    my ( $class, $args ) = @_;
    return bless {%$args}, $class;
}

sub init {
    return;

}

sub exit {
    return;

}

sub isRunning {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;
    return;
}

sub prepare {
    return;
}

sub play {
    my $self  = shift;
    my $event = shift;
    my $show  = shift;
    return;
}

sub stop {
    return;
}

# do not delete last line
1;
