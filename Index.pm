package VDR::Index;

use strict;
use warnings;

use Carp;
use Data::Dumper;
require bytes;
no bytes;

sub new {
    my $class = shift;

    my $self = {
        fn => shift,
        last_pic_info_picidx => undef,
        last_pic_info => undef,
        num_pics => undef,
    };

    confess 'no index file name given' unless defined $self->{fn};
    confess 'file not found: '.$self->{fn} unless -e $self->{fn};
    
    $self->{num_pics} = (-s $self->{fn}) / 8;

    open $self->{fh}, '<', $self->{fn} or confess $!;
    binmode $self->{fh} or confess "failed to set binmode";
    
    bless $self, $class;
}

sub num_pics { shift->{num_pics} }

sub get_pic_info {
    my $self = shift;
    my $pic_idx = shift;
    seek $self->{fh}, $pic_idx * 8, 0 or confess 'failed to seek to index '.$pic_idx;
    my $buf;
    confess 'failed to read pic info at index '.$pic_idx
        unless (read($self->{fh}, $buf, 8) == 8);
    $self->{last_pic_info} = [unpack("LCCS", $buf)];
    $self->{last_pic_info_picidx} = $pic_idx;
    $self
}

sub picidx { shift->{last_pic_info_picidx} }
sub fileoffset { shift->{last_pic_info}->[0] }
sub frametype { shift->{last_pic_info}->[1] }
sub fileidx { shift->{last_pic_info}->[2] }
sub filename {
    my $self = shift;
    my $fn = $self->{fn};
    my $fn_part = sprintf('%03d.vdr', $self->fileidx);
    if ( $fn =~ /\// ) {
        $fn =~ s/\/[^\/]+$/\/$fn_part/;
    } else {
        $fn = $fn_part;
    }
    $fn
}

sub skip_to_frametype {
    my ( $self, $frametype ) = @_;
    my $pic_idx = $self->{last_pic_info_picidx};
    confess unless defined $pic_idx;
    while ( $self->frametype != $frametype ) {
        $pic_idx++;
        return unless ($pic_idx < $self->num_pics);
        $self->get_pic_info($pic_idx);
    }
    $self
}

1;

