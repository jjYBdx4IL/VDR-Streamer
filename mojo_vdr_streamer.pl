# vim:set sw=4 ts=4 et ai smartindent fileformat=unix fileencoding=utf-8 syntax=perl:
# MOJO_MODE=development DEBUG=0 morbo mojo_vdr_streamer.pl daemon --listen 'http://*:3001'
# lsof -p`lsof /home/perl/5.14.0/bin/morbo | sort -n -k2 | tail -n1 | awk '{print $2}'` | grep -v " mem "
package VDR_STREAMER;

BEGIN {
    # EPOLL (4) is buggy, at least on Ubuntu 11.10/amd64 libev with perl 5.14.0 and EV 4.03.
    $ENV{LIBEV_FLAGS}=3;
    die 'public/ missing' unless (-d './public');
}

use strict;
use warnings;
use utf8;
require bytes;
no bytes;

use Mojolicious::Lite;
use EV;
use JSON::Any;
use File::Temp;
use Mojo::IOLoop;
use Mojo::IOWatcher;
use Mojo::Log;
use IPC::Open3;
use Fcntl qw(:DEFAULT);
use Symbol qw(gensym);
use IO::Socket;
use Data::Dumper;
use MIME::Base64;
use File::Slurp;
require 'Index.pm';

app->log->level($ENV{'DEBUG'} ? 'debug' : 'info');
$EV::DIED = sub { EV::unloop; die @_; };

my $j = JSON::Any->new(utf8=>1);
our @recs = ();
our $recs_last_updated;

our $do_precache = 1; # pre-read entire file when streaming starts... lets disks go to sleep on systems with big RAM size
our $precache_pid = undef; # so we are able to abort the pre-caching
our $w_precache = undef;

our $bufsize = 32768;
our $tcp_sndbufsize = undef;

our $default_audio_kbit = 112;
our $default_video_kbit = 640;
our $assumed_mux_overhead_factor = 1.01; # fraction
our $last_ab = $default_audio_kbit;
our $last_vb = $default_video_kbit;

our $remote_player_stream = undef; # only one.

our $playback_ffmpeg_pid = undef;
our $playback_pipe_ffmpeg_stdin = undef;
our $playback_pipe_ffmpeg_stdout = undef;
our $playback_pipe_ffmpeg_stderr = undef;
our $w_ffmpeg_child = undef;
our $w_ffmpeg_stdin = undef;
our $w_ffmpeg_stdout = undef;
our $w_ffmpeg_stderr = undef;
our $ffmpeg_stdout_buf = '';
our $ffmpeg_stdout_buf_stopsize = 2*$bufsize;

our $vdr_src_buf = '';
our $vdr_src_buf_stopsize = 2*$bufsize; # some sort of approx. read-ahead length
our $vdr_src_idx = undef;
our $vdr_src_last_reported_timepos = -1;

our $w_client = undef;
our $w_client_read_monitor = undef;

our %ws_clients = (); # websocket clients we need to keep up to date with current video-stream info
our $current_recording = undef; # which vdr recording are we currently processing?

our %w_evts = ();
sub w_suspend {
    my($w) = @_;
    die unless defined $w;
    return unless ($w->is_active);
    $w_evts{$w} = $w->clear_pending;
    $w->stop;
    1
}
sub w_resume {
    my($w) = @_;
    die unless defined $w;
    return if ($w->is_active);
    $w->start;
    if(exists $w_evts{$w}) {
        # fixes some issues with EPOLL, but not all...:
#        $w->feed_event($w_evts{$w});
        delete $w_evts{$w};
    }
    1
}

my $recur_id = Mojo::IOLoop->recurring(3 => sub {
    app->log->debug(
        $/.'    '.'$w_ffmpeg_stdin->is_active='.(!defined($w_ffmpeg_stdin)?'<undef>':$w_ffmpeg_stdin->is_active).
        $/.'    '.'$w_ffmpeg_stdout->is_active='.(!defined($w_ffmpeg_stdout)?'<undef>':$w_ffmpeg_stdout->is_active).
        $/.'    '.'$w_ffmpeg_stderr->is_active='.(!defined($w_ffmpeg_stderr)?'<undef>':$w_ffmpeg_stderr->is_active).
#        $/.'    '.'$w_vdr_src->is_active='.(!defined($w_vdr_src)?'<undef>':$w_vdr_src->is_active).
        $/.'    '.'$w_client->is_active='.(!defined($w_client)?'<undef>':$w_client->is_active).
        $/.'    '.'$w_client_read_monitor->is_active='.(!defined($w_client_read_monitor)?'<undef>':$w_client_read_monitor->is_active).
        $/.'    '.'$remote_player_stream='.(!defined($remote_player_stream)?'<undef>':$remote_player_stream).
        $/.'    '.'bytes::length($vdr_src_buf)='.(!defined($vdr_src_buf)?'<undef>':bytes::length($vdr_src_buf))
    );
});

sub load_recs {
  @recs = ();
  open my $fh, 'find -L /vdr -name index.vdr |' or die $!;
  binmode($fh, 'utf8') or die $!;
  while (<$fh>) {
      chomp;
      s/\/index\.vdr$//;
      push @recs, $_;
  }
  close $fh;
  @recs = sort @recs;
  $recs_last_updated = time();
}

load_recs();

sub log_ev_evt_flags {
    my ($evt) = @_;
    my @flags = ();
    push @flags, 'EV::READ' if ($evt & EV::READ);
    push @flags, 'EV::WRITE' if ($evt & EV::WRITE);
    app->log->debug('EV EVT FLAGS = '.join(', ',@flags));
}

sub stream_set_default_hooks {
    my ($s,$n) = @_;
    my $id = Mojo::IOLoop->stream($s);
    Mojo::IOLoop->stream($id)->timeout(3600);
    foreach my $e ( qw(read write close error resume) ) {
        $s->on($e => sub {app->log->debug(sprintf('%s event: %s',$n,$e));});
    }
}

sub async_fh {
    my($fh)=@_;
    binmode($fh) or die;
    my $flags = fcntl($fh, F_GETFL, 0);
    fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}

sub ws_dist_msg {
    my ($content) = @_;
    foreach my $s ( values %ws_clients ) {
        $s->send_message($j->encode($content));
    }
}

# frame=  575 fps= 25 q=24.0 Lq=24.0 size=    6535kB time=00:00:23.25 bitrate=2301.9kbits/s
sub start_playback {
    my $rec = $current_recording;
    my $offset = shift || 0; # in bytes
    my $audio_kbit = $last_ab;
    my $video_kbit = $last_vb;
    
    return unless (-r $rec.'/index.vdr');
    
    if($precache_pid) {
        kill 'TERM', $precache_pid;
        $precache_pid = undef;
    }
    
    if(defined $playback_ffmpeg_pid) {
        kill 'TERM', $playback_ffmpeg_pid;
        $playback_ffmpeg_pid = undef;
    }
    
    $vdr_src_buf = '';
    # avoid races by first cleaning up most stuff
    undef $w_ffmpeg_child;
    undef $w_ffmpeg_stdin;
    undef $w_ffmpeg_stdout;
    undef $w_ffmpeg_stderr;
    
    undef $playback_pipe_ffmpeg_stdin;
    undef $playback_pipe_ffmpeg_stdout;
    undef $playback_pipe_ffmpeg_stderr;
    undef $vdr_src_idx;

    $playback_pipe_ffmpeg_stdin = gensym;
    $playback_pipe_ffmpeg_stdout = gensym;
    $playback_pipe_ffmpeg_stderr = gensym;
    
    $ffmpeg_stdout_buf = '';

    app->log->info('$w_vdr_src: opening VDR index file '.$rec.'/index.vdr');
    $vdr_src_idx = VDR::Index->new($rec.'/index.vdr')->async(1);
    my $n_pics = $vdr_src_idx->num_pics;
    app->log->info('$w_vdr_src: number of total frames is '.$n_pics);
    my $exp_content_length = int(($n_pics / $vdr_src_idx->fps) * (($audio_kbit+$video_kbit)*$assumed_mux_overhead_factor)*1024/8);
    app->log->info(sprintf('$w_vdr_src: expected output size at %d+%d kbit is %d bytes',$video_kbit,$audio_kbit,$exp_content_length));
    if($offset > $exp_content_length * 0.99) {
        $offset = int($exp_content_length * 0.99);
    }
    my $offset_frame = int($offset / $exp_content_length * $n_pics);
    app->log->info(sprintf('$w_vdr_src: computed offset frame for offset position %d is %d',$offset,$offset_frame));
    $vdr_src_idx->get_pic_info($offset_frame);
    $vdr_src_idx->skip_to_frametype(1);
    app->log->info('$w_vdr_src: skipped to frame '.$vdr_src_idx->picidx.' based on frame type, new src file pos is '.$vdr_src_idx->fileoffset);
    
    
    if($do_precache) {
        $precache_pid = fork();
        if(!$precache_pid) {
            # let the streamer start first
            sleep 15;
            open STDOUT, '>/dev/null' or die $!;
            exec('cat', glob($rec.'/*.vdr'));
        } else {
            app->log->info('precache child process created and has pid '.$precache_pid);
            $w_precache = EV::child $precache_pid, 0, sub {
                my ($w, $revents) = @_;
                my $status = $w->rstatus;
                app->log->info('precache child process terminated with status '.$status);
                # avoid killing something unrelated:
                $precache_pid = undef;
            };
        }
    }


    $vdr_src_idx->stream_start(sub {
        my($data) = @_;
        app->log->debug('$w_vdr_src stream fired');
        
        $vdr_src_buf .= $$data;
        
        if($vdr_src_last_reported_timepos != $vdr_src_idx->timepos) {
            ws_dist_msg({
                cmd => 'playstatus_update',
                reply => {
                    displaypos    => $vdr_src_idx->displaypos,
                    displaylength => $vdr_src_idx->displaylength,
                },
            });
            $vdr_src_last_reported_timepos = $vdr_src_idx->timepos;
        }
        
        if(bytes::length($vdr_src_buf) >= $vdr_src_buf_stopsize) {
            app->log->debug('$w_vdr_src stream suspended') if $vdr_src_idx->stream_suspend;
        }
        
        if(bytes::length($vdr_src_buf) > 0 && !$w_ffmpeg_stdin->is_active) {
            app->log->debug('$w_ffmpeg_stdin resumed') if w_resume($w_ffmpeg_stdin);
        }
        app->log->debug('$w_vdr_src done');
        
    });

    # http://sites.google.com/site/linuxencoding/x264-ffmpeg-mapping
    $playback_ffmpeg_pid = open3($playback_pipe_ffmpeg_stdin, $playback_pipe_ffmpeg_stdout, $playback_pipe_ffmpeg_stderr,
                    "ffmpeg -y -threads 4 -deinterlace -f mpeg -i - ".
                    "-f mpegts -bt 32k -bufsize 256k ".
#                    "-g 250 -keyint_min 24 -bt 100k -maxrate ${video_kbit}k -bufsize 192k ".
                    "-vcodec libx264 -vpre hq -vb ${video_kbit}k ".
                    "-acodec libmp3lame -ab ${audio_kbit}k -async 1 -sn -dn -");
    async_fh($playback_pipe_ffmpeg_stdin);
    async_fh($playback_pipe_ffmpeg_stdout);
    async_fh($playback_pipe_ffmpeg_stderr);

    $w_ffmpeg_child = EV::child $playback_ffmpeg_pid, 0, sub {
        my ($w, $revents) = @_;
        my $status = $w->rstatus;
        app->log->info('ffmpeg child process terminated with status '.$status);
        # avoid killing something unrelated:
        $playback_ffmpeg_pid = undef;
    };
    $w_ffmpeg_stdin = EV::io $playback_pipe_ffmpeg_stdin, EV::WRITE, sub {
        my ($w, $revents) = @_; # all callbacks receive the watcher and event mask
        app->log->debug('$w_ffmpeg_stdin fired');
        log_ev_evt_flags($revents);
        return unless ($revents & EV::WRITE);

        my $len = bytes::length($vdr_src_buf);
        if($len) {
            app->log->debug(sprintf('writing %d bytes to ffmpeg stdin', $len));
            my $wlen = syswrite($playback_pipe_ffmpeg_stdin,$vdr_src_buf,$len > $bufsize ? $bufsize : $len);
            die $! unless defined $wlen;
            die unless $wlen;
            app->log->debug(sprintf('wrote %d/%d bytes to ffmpeg stdin', $wlen, $len));
            $vdr_src_buf = substr($vdr_src_buf, $wlen);
        }
        
        if (bytes::length($vdr_src_buf)==0) {
            app->log->debug('$w_ffmpeg_stdin suspended') if w_suspend($w_ffmpeg_stdin);
        }
        
        if(bytes::length($vdr_src_buf) < $vdr_src_buf_stopsize) {
            app->log->debug('$w_vdr_src stream resumed') if $vdr_src_idx->stream_resume;
        }
        app->log->debug('$w_ffmpeg_stdin done');
    };
    $w_ffmpeg_stdout = EV::io $playback_pipe_ffmpeg_stdout, EV::READ, sub {
        my ($w, $revents) = @_; # all callbacks receive the watcher and event mask
        app->log->debug('$w_ffmpeg_stdout fired');
        log_ev_evt_flags($revents);
        return unless ($revents & EV::READ);
        
        if(!defined $remote_player_stream) {
            app->log->debug('$w_ffmpeg_stdout suspended because there is no client') if w_suspend($w_ffmpeg_stdout);
            return;
        }
        
        my $buf;
        my $rlen = sysread($playback_pipe_ffmpeg_stdout,$buf,$bufsize);
        die $! unless defined $rlen;
        app->log->debug(sprintf('read %d bytes from ffmpeg stdout', $rlen));
        $ffmpeg_stdout_buf .= $buf;
        
        if(bytes::length($ffmpeg_stdout_buf) >= $ffmpeg_stdout_buf_stopsize) {
            app->log->debug('$w_ffmpeg_stdout suspended') if w_suspend($w_ffmpeg_stdout);
        }
        
        if(bytes::length($ffmpeg_stdout_buf) > 0 && defined($w_client) && !$w_client->is_active) {
            app->log->debug('$w_client resumed') if w_resume($w_client);
        }
        
        app->log->debug('$w_ffmpeg_stdout end');
    };
    $w_ffmpeg_stderr = EV::io $playback_pipe_ffmpeg_stderr, EV::READ, sub {
        my ($w, $revents) = @_; # all callbacks receive the watcher and event mask
        app->log->debug('$w_ffmpeg_stderr fired');
        log_ev_evt_flags($revents);
        return unless ($revents & EV::READ);
        
        my $buf;
        my $rlen = sysread($playback_pipe_ffmpeg_stderr,$buf,$bufsize);
        die $! unless defined $rlen;
        $buf =~ s/[\r\n]+/\n/g;
        app->log->info('ffmpeg stderr: '.$buf);
        ws_dist_msg({
            cmd => 'playstatus_update',
            reply => {position=>$buf},
        });
        app->log->debug('$w_ffmpeg_stderr end');
    };
    app->log->info('ffmpeg child started, pid = '.$playback_ffmpeg_pid);
    $exp_content_length
}

our %preview_jobs = ();
sub loadpreviewimages {
    my($ws,$ival,$cnt,$imgwidth,$cbname,$offset_picidx,$nodata_cb)=@_;
    my $sendlimit = $cnt;
    $cnt += 2; # mplayer seems to need some more frames in input... ???
    my $job = {};
    if ( exists $preview_jobs{$ws} ) {
        $job = $preview_jobs{$ws};
    }
    if($job->{pid}) {
        kill 'TERM', $job->{pid};
        undef $job->{w};
    }
    if(!defined $current_recording) {
        return;
    }

    my $tmpdir = File::Temp->newdir;

    $job->{ws} = $ws;
    $job->{pid} = fork();
    if(!$job->{pid}) {
        my $idx = VDR::Index->new($current_recording.'/index.vdr');
        my @pic_idxs = ();
        my @pic_displaypos = ();
        my $frameidx = $offset_picidx;
        #open my $fh, '|-', "ffmpeg -vframes ".quotemeta($cnt)." -f mpeg -i - -s ".quotemeta($imgsize)." -f image2 $tmpdir/\%06d.jpg" or die $!;
        #open my $fh, '|-', "ffmpeg -f mpeg -i - -s ".quotemeta($imgsize)." -f image2 $tmpdir/\%06d.jpg" or die $!;
        #open my $fh, '|-', "mplayer -nosound -vf scale=".quotemeta($imgwidth).":-3 -vo jpeg:outdir=".quotemeta($tmpdir)." -" or die $!;
        open my $fh, '>:raw', "$tmpdir/data" or die $!;
        binmode($fh) or die;
        for ( my $i = 0; $i < $cnt; $i++ ) {
            if($i > 0) {
                $frameidx += int($ival * $idx->fps);
            }
#            app->log->debug('image preview $frameidx '.$frameidx);
#            print STDERR 'image preview $frameidx '.$frameidx.$/;
            $idx->get_pic_info($frameidx);
            $idx->skip_to_frametype(1);
            push @pic_idxs, $idx->picidx;
            push @pic_displaypos, $idx->displaypos;
            my $frame = $idx->get_full_frame();
#             if($i==0) {
#                 for(my $j=0; $j<100; $j++) {
#                     print $fh $frame or die;
#                 }
#             }
            print $fh $frame or die;
        }
        close $fh or die $!;
        system("mplayer -nosound $tmpdir/data -vf scale=".quotemeta($imgwidth).":-3 -vo jpeg:outdir=".quotemeta($tmpdir));
        #system("ffmpeg -f mpeg -i $tmpdir/data -s 160x120 -f image2 $tmpdir/\%06d.jpg");
        unlink "$tmpdir/data" or die;
        my $sent = 0;
        foreach my $jpg ( sort glob($tmpdir.'/*.jpg') ) {
            if($sent >= $sendlimit) {
                unlink $jpg or die;
                next;
            }
            if(! @pic_idxs) {
                warn "no pic idx, dropping preview image";
                unlink $jpg or die;
                next;
            }
            rename $jpg, sprintf('%s/%s_%09d.jpg',$tmpdir,shift @pic_displaypos,shift @pic_idxs) or die;
            $sent++;
        }
        exit 0;
    }
    $job->{w} = EV::child $job->{pid}, 0, sub {
        my ($w, $revents) = @_;
        my $status = $w->rstatus;
        app->log->info('image preview child process terminated with status '.$status);
        
        
        # http://aktuell.de.selfhtml.org/artikel/grafik/inline-images/
        
        my $data_sent = 0;
        foreach my $jpg ( sort glob($tmpdir.'/*.jpg') ) {
            app->log->debug('sending base64 encoded preview image '.$jpg);
            my ( $displaypos, $picidx ) = ( $jpg =~ /\/([^\/]+)_(\d+)\.jpg/i );
            $picidx =~ s/^0+//;
            $job->{ws}->send_message($j->encode({
                cmd => $cbname,
                reply => {
                    data => encode_base64(read_file($jpg)),
                    picidx => $picidx,
                    displaypos => $displaypos,
                },
            }));
            $data_sent++;
        }
        
        if(!$data_sent && defined($nodata_cb)) {
            $job->{ws}->send_message($j->encode({
                cmd => $nodata_cb,
            }));
        }
        
        # avoid killing something unrelated:
        $job->{pid} = undef;
        undef $job->{w};
        undef $job->{ws};
        delete $preview_jobs{$ws};
    };
    
    $preview_jobs{$ws} = $job;
}

any '/' => sub {
    my $self = shift;
    my $ws_tx = $self->tx;
    if(! exists $ws_clients{$ws_tx}) {
        $ws_clients{$ws_tx}=$ws_tx;
        $ws_tx->on(finish => sub {
            delete $ws_clients{$ws_tx};
            app->log->info('DISCONNECTED!!!');
        });
    }
    $self->on(message => sub {
        my ($s,$msg) = @_;
        $self->app->log->info('msg in: '.$msg);
        my $msg_in = $j->decode($msg);
        my $msg_out = undef;
        if($msg_in->{cmd} eq 'load') {
            $msg_out = $j->encode({
                cmd => 'load',
                reply => {recs=>\@recs,recs_last_updated=>$recs_last_updated},
            });
        }
        if($msg_in->{cmd} eq 'reload') {
            load_recs();
            $msg_out = $j->encode({
                cmd => 'load',
                reply => {recs=>\@recs,recs_last_updated=>$recs_last_updated},
            });
        }
        if($msg_in->{cmd} eq 'play') {
            $current_recording = $msg_in->{recording};
            start_playback();
            $msg_out = $j->encode({
                cmd => 'playstatus_start',
                reply => {title=>$msg_in->{recording}},
            });
        }
        if($msg_in->{cmd} eq 'wind') {
            if ( defined $vdr_src_idx && defined $msg_in->{seconds} ) {
                my $dest_pic_idx = $vdr_src_idx->picidx + $vdr_src_idx->fps * $msg_in->{seconds};
                if ( $dest_pic_idx >= $vdr_src_idx->num_pics - $vdr_src_idx->fps * 12 ) {
                    $dest_pic_idx = $vdr_src_idx->num_pics - $vdr_src_idx->fps * 12 - 1;
                }
                if ( $dest_pic_idx < 0 ) {
                    $dest_pic_idx = 0;
                }
                $vdr_src_idx->get_pic_info($dest_pic_idx);
                $vdr_src_idx->skip_to_frametype(1);
            }
        }
        if($msg_in->{cmd} eq 'seekpic') {
            if ( defined $vdr_src_idx && defined $msg_in->{picidx} ) {
                my $dest_pic_idx = $msg_in->{picidx};
                if ( $dest_pic_idx >= $vdr_src_idx->num_pics - $vdr_src_idx->fps * 12 ) {
                    $dest_pic_idx = $vdr_src_idx->num_pics - $vdr_src_idx->fps * 12 - 1;
                }
                if ( $dest_pic_idx < 0 ) {
                    $dest_pic_idx = 0;
                }
                $vdr_src_idx->get_pic_info($dest_pic_idx);
                $vdr_src_idx->skip_to_frametype(1);
            }
        }
        if($msg_in->{cmd} eq 'loadpreviewimages') {
            if(defined $vdr_src_idx) {
                loadpreviewimages($s,$msg_in->{interval},$msg_in->{count},$msg_in->{imgwidth},'previewimage',$vdr_src_idx->picidx);
            }
        }
        if($msg_in->{cmd} eq 'loadsinglepreviewimage') {
            if(defined $vdr_src_idx && defined($msg_in->{picidx})) {
                loadpreviewimages($s,0.1,1,$msg_in->{imgwidth},'singlepreviewimage',$msg_in->{picidx},'singlepreviewimagefail');
            }
        }
        if($msg_in->{cmd} eq 'ping') {
            $msg_out = $j->encode({
                cmd => 'ping',
            });
        }
        if(defined $msg_out) {
            app->log->info('msg out: '.$msg_out);
            $s->send_message($msg_out);
        }
    }) if $self->tx->is_websocket;
} => 'websocket';

any '/playback' => sub {
    my $self = shift;
    # nothing selected for playback yet?
    if(!$current_recording) {
        return;
    }

    $last_ab = $self->req->param('ab') || $last_ab;
    $last_vb = $self->req->param('vb') || $last_vb;

    $self->render_later;
    $remote_player_stream = Mojo::IOLoop->stream($self->tx->connection);
    if(defined $tcp_sndbufsize) {
        app->log->error('failed to set sendbuf size')
            unless defined setsockopt($remote_player_stream->handle,SOL_SOCKET, SO_SNDBUF, $tcp_sndbufsize);
    }
    app->log->debug('client stream id = '.Mojo::IOLoop->stream($remote_player_stream));
    $remote_player_stream->timeout(3600);
    app->log->info($self->req->to_string);
    my $range = $self->req->content->headers->range;
    my $res = defined $range ? '206' : '200';
    $range //= 0;
    $range = ($range =~ /(\d+)/)[0];
    my $content_length = start_playback($range);
    $remote_player_stream->on(close => sub {
        app->log->info('$remote_player_stream closed');
        app->log->debug('$w_ffmpeg_stdout suspended') if w_suspend($w_ffmpeg_stdout);
        undef $w_client;
        undef $w_client_read_monitor;
        Mojo::IOLoop->drop(Mojo::IOLoop->stream($remote_player_stream));
        undef $remote_player_stream;
    });
    $remote_player_stream->write(
        "HTTP/1.1 $res OK\n"
        ."Content-Type: video/mpeg\n"
        ."Accept-Ranges: bytes\n"
        .'Content-Length: '.int($content_length-$range)."\n"
        .($res eq '206' ? 'Content-Range: bytes '.int($range).'-'.int($content_length-1).'/'.int($content_length) : '')
        ."Connection: close\n"
        ."\n"
    );
    $w_client = EV::io $remote_player_stream->handle, EV::WRITE, sub {
        my ($w, $revents) = @_; # all callbacks receive the watcher and event mask
        app->log->debug('$w_client fired');
        log_ev_evt_flags($revents);
        return unless ($revents & EV::WRITE);
        
        my $len = bytes::length($ffmpeg_stdout_buf);
        if($len) {
            app->log->debug(sprintf('writing %d bytes to client', $len));
            my $wlen = syswrite($remote_player_stream->handle,$ffmpeg_stdout_buf,$len > $bufsize ? $bufsize : $len);
            if(!defined $wlen) {
                app->log->info($!);
                return;
            }
            die unless $wlen;
            app->log->debug(sprintf('wrote %d/%d bytes to client', $wlen, $len));
            $ffmpeg_stdout_buf = substr($ffmpeg_stdout_buf, $wlen);
        }
        
        if (bytes::length($ffmpeg_stdout_buf)==0) {
            app->log->debug('$w_client suspended') if w_suspend($w_client);
        }
        
        if(bytes::length($ffmpeg_stdout_buf) < $ffmpeg_stdout_buf_stopsize) {
            app->log->debug('$w_ffmpeg_stdout resumed') if w_resume($w_ffmpeg_stdout);
        }
    };
    $w_client_read_monitor = EV::io $remote_player_stream->handle, EV::READ, sub {
        my ($w, $revents) = @_; # all callbacks receive the watcher and event mask
        app->log->debug('$w_client_read_monitor fired');
        log_ev_evt_flags($revents);
        return unless ($revents & EV::READ);
    
        my $buf;
        read($remote_player_stream->handle, $buf, 1024);
        app->log->debug('CLIENT SENT: '.$buf);
    };
};

# unfinished, one-stop playback...?
get '/2play/*' => sub {
    my $self = shift;
    app->log->info($self->req->to_string);
    app->log->debug('recname='.Dumper($self->req));
    app->log->debug('recname='.Dumper($self->req->url->path->parts));
    my @parts = @{$self->req->url->path->parts};
    shift @parts;
    my $recname = '/' . join ('/', @parts);
    app->log->debug('$recname='.$recname);
};

app->start;

__DATA__

@@ websocket.html.ep
<!DOCTYPE html>
<html>
  <head>
    <title>VDR Streamer</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <link rel="stylesheet" type="text/css" href="/style.css" media="all" />
    % my $url = url_for->to_abs->scheme('ws');
    %= javascript begin
    var ws_url = '<%= $url %>';
    % end
    %= javascript '/js/jquery.js'
    %= javascript '/JSON.js'
    %= javascript '/vdr_streamer.js'
  </head>
  <body>
    <pre>playback command: (s)mplayer <%= url_for('/playback')->to_abs %></pre>
    <div id="reloadbutton" class="icontextbutton">
        <img src="/icons/refresh.png" alt="refresh">
        <span>refresh</span>
    </div>
    <div id="recs" style="clear:both;"></div>
  </body>
</html>

