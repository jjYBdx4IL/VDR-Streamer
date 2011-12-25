package VDR::Index;

BEGIN {
    # EPOLL (4) is buggy, at least on Ubuntu 11.10/amd64 libev with perl 5.14.0 and EV 4.03.
    $ENV{LIBEV_FLAGS}=3;
}

use strict;
use warnings;

use Carp;
use Data::Dumper;
use Fcntl qw(:DEFAULT);
use EV;
require bytes;
no bytes;

sub new {
    my $class = shift;

    my $self = {
        fn => shift,
        last_pic_info_picidx => undef,
        last_pic_info => undef,
        num_pics => undef,
        fh => undef,
        # stream reader stuff
        stream_fh => undef,
        stream_fh_idx => -1,
        async => 0,
        framebuf => '',
        framebuf_picidx => -1,
        w => undef,
    };

    confess 'no index file name given' unless defined $self->{fn};
    confess 'file not found: '.$self->{fn} unless -e $self->{fn};
    
    $self->{num_pics} = (-s $self->{fn}) / 8;

    sysopen($self->{fh}, $self->{fn}, O_RDONLY) or confess $!;
    
    bless $self, $class;
}

sub _seconds_to_display_str {
    my ( $self, $seconds ) = @_;
    my $hours = int($seconds / 3600);
    $seconds -= $hours * 3600;
    my $minutes = int($seconds / 60);
    $seconds -= $minutes *60;
    sprintf('%02d:%02d:%02d',$hours,$minutes,$seconds)
}

sub displaypos {
    my($self)=@_;
    $self->_seconds_to_display_str($self->timepos)
}

sub displaylength {
    my($self)=@_;
    $self->_seconds_to_display_str($self->length)
}

sub num_pics { shift->{num_pics} }

sub get_pic_info {
    my $self = shift;
    my $pic_idx = shift;
    confess unless defined $pic_idx;
    return $self if ( defined $self->picidx && $self->picidx == $pic_idx );
    if(!defined sysseek($self->{fh}, $pic_idx * 8, 0)) {
        confess 'failed to seek to index '.$pic_idx;
    }
    my $buf = '';
    my $rlen = sysread($self->{fh}, $buf, 2*8);
    confess unless defined $rlen;
    if ( $rlen == 2*8 ) {
        # we were able to read the next frame's offset, too:
        $self->{last_pic_info} = [unpack('LCCSL', $buf)];
    }
    elsif ( $rlen == 8 ) {
        $self->{last_pic_info} = [unpack('LCCS', $buf)];
    } else {
        confess 'failed to read pic info at index '.$pic_idx;
    }
    $self->{last_pic_info_picidx} = $pic_idx;
    if ( $rlen == 8 ) {
        push @{$self->{last_pic_info}}, (-s $self->filename);
    }
    # compute frame size from next frame's offset
    $self->{last_pic_info}->[4] = $self->{last_pic_info}->[4] - $self->{last_pic_info}->[0];
    # is there a next frame?
    $self->{last_pic_info}->[5] = ($rlen == 2*8) ? 1 : 0;
    $self
}

sub fps { 25 }
sub picidx { shift->{last_pic_info_picidx} }
sub fileoffset { shift->{last_pic_info}->[0] }
sub frametype { shift->{last_pic_info}->[1] }
sub fileidx { shift->{last_pic_info}->[2] }
sub framesize { shift->{last_pic_info}->[4] }
sub moreframes { shift->{last_pic_info}->[5] }
sub timepos { # seconds
    my($self)=@_;
    int($self->picidx / $self->fps)
}
sub length { # seconds
    my($self)=@_;
    int($self->num_pics / $self->fps)
}
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

# stream reader stuff
# (units == frames)

sub async {
    my($self,$arg) = @_;
    $self->{async} = $arg;
    $self
}

sub _get {
    my($self,$picidx) = @_;
    if(!defined $picidx) {
        $picidx = $self->picidx;
    }
    if ( $picidx != $self->{framebuf_picidx} ) {
        $self->{framebuf} = '';
    }
    $self->get_pic_info($picidx);
    if($self->{stream_fh_idx} != $self->fileidx) {
        sysopen($self->{stream_fh}, $self->filename, O_RDONLY | ($self->{async} ? O_NONBLOCK : 0))
            or confess "error opening ".$self->filename." ($!)";
        if(!defined sysseek($self->{stream_fh}, $self->fileoffset, 0)) {
            confess;
        }
    }
    my $exp_rlen = $self->framesize - bytes::length($self->{framebuf});
    return 1 unless $exp_rlen;
    my $exp_offset = $self->fileoffset + bytes::length($self->{framebuf});
    if ( $exp_offset != sysseek($self->{stream_fh},0,1) ) {
        if(!defined sysseek($self->{stream_fh}, $exp_offset, 0)) {
            confess;
        }
    }
    my $rlen = sysread($self->{stream_fh}, $self->{framebuf}, $exp_rlen, bytes::length($self->{framebuf}));
    confess unless $rlen;
    return if ( $rlen != $exp_rlen );
    return 1;
}

sub get_full_frame {
    my($self,$picidx) = @_;
    while (!$self->_get($picidx)) {}
    return $self->{framebuf};
}

sub stream_start {
    my($self,$cb) = @_;

    # get current frame so we have an initialized file handle
    $self->_get();
    $self->{w} = EV::io $self->{stream_fh}, EV::READ, sub {
        my ($w, $revents) = @_; # all callbacks receive the watcher and event mask
        return unless ($revents & EV::READ);
        
        my $buf = $self->_get();
        if(defined $buf) {
            $cb->(\$self->{framebuf});
            
            if($self->moreframes) {
                $self->get_pic_info($self->picidx+1);
            } else {
                $self->{w} = undef;
            }
        }
    };
}

sub stream_suspend {
     my($self) = @_;
     confess unless defined $self->{w};
     if($self->{w}->is_active) {
         $self->{w}->stop;
         return 1;
     }
     return 0;
}

sub stream_resume {
     my($self) = @_;
     confess unless defined $self->{w};
     if(!$self->{w}->is_active) {
         $self->{w}->start;
         return 1;
     }
     return 0;
}

1;

