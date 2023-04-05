#!/usr/bin/perl
#-------------------------------------------------------------------------------
my $VERSION     = '0.80';
my $LAST_UPDATE = '2023.04.05';
my $SERVER_NAME = "Tiny RTSP Server Ver$VERSION - $LAST_UPDATE";
################################################################################
# V4L2 RTP Server compress with ffmpeg.
################################################################################
use 5.8.1;
use strict;
use Fcntl;
use Socket;
use threads;
use threads::shared;
use Time::HiRes;
use Digest::MD5;
use MIME::Base64;
################################################################################
my $DEBUG     = 0;
my $PRINT     = 1;
my $BIND      = '*';
my $PORT      = 8554;
my $USE_UDP   = 1;
my $TIMEOUT   = 3;
my $AUTH_ID   = '';
my $AUTH_PASS = '';
my $AUTH_REALM= 'TinyRtspServer';
my $TIMESTAMP = 0;
my $PARSE_VPS = 1;
#-------------------------------------------------------------------------------
# RTSP/RTP
#-------------------------------------------------------------------------------
my $RTP_SSRC	 = 0x12345678;
my $RTP_SSRC_BIN = pack('N', $RTP_SSRC);
my $RTP_SESSION  = "tsession";
my $SPLIT_NAL_U  = 0;
my $RTP_MAX_SIZE = 65000;
#-------------------------------------------------------------------------------
# Codec
#-------------------------------------------------------------------------------
my $INPUT      = '/dev/video0';
my $IN_FORMAT  = 'v4l2';
my $CODEC      = 'H265';
my $WIDTH      = 640;
my $HEIGHT     = 360;
my $FPS        = 30;
my $KEYINT     = undef;
my $BITRATE    = "500k";
my $TIMEBASE   = 1000;
my $FFM_OPTION = '-pix_fmt yuv420p';	# for libde265.js
my $FFM_VCODEC = undef;
my $FFM_VCOPY  = 0;
#-------------------------------------------------------------------------------
# Encoder info
#-------------------------------------------------------------------------------
my @NAL_NAME;
# H265
$NAL_NAME[32] = 'vps';
$NAL_NAME[33] = 'sps';
$NAL_NAME[34] = 'pps';
# H264
$NAL_NAME[6] = 'vps';
$NAL_NAME[7] = 'sps';
$NAL_NAME[8] = 'pps';

my %CO_INFO = (
	H264	=> { id => 'avc1', lib => 'libx264', v4l2fmt => 'h264' },
	H265	=> { id => 'hvc1', lib => 'libx265', v4l2fmt => 'hevc' }
);

#-------------------------------------------------------------------------------
# command line options
#-------------------------------------------------------------------------------
{
	my $HELP;
	my @ary;
	my $err='';
	while(@ARGV) {
		my $x = shift(@ARGV);
		#---------------------------------------------------------------
		# General
		#---------------------------------------------------------------
		if ($x eq '-q')  { $PRINT = 0; next; }
		if ($x eq '-d')  { $PRINT = $DEBUG = 1; next; }
		if ($x eq '-dd') { $PRINT = $DEBUG = 2; next; }
		if ($x eq '-h')  { $HELP  = 1; next; }

		#---------------------------------------------------------------
		# RTSP server
		#---------------------------------------------------------------
		if ($x eq '-b')  { $BIND = shift(@ARGV); next; }
		if ($x eq '-p')  {
			$PORT = shift(@ARGV);
			if ($PORT !~ /^\d+$/) { $err .= "Invalid port: $PORT\n"; }
			next;
		}
		if ($x eq '-t') {
			$TIMEOUT = shift(@ARGV);
			if ($TIMEOUT <= 0 || $TIMEOUT !~ /^\d+$/) { $err .= "Invalid timeout: $TIMEOUT\n"; }
			next;
		}
		if ($x eq '-ai') { $AUTH_ID     = shift(@ARGV); next; }
		if ($x eq '-ap') { $AUTH_PASS   = shift(@ARGV); next; }
		if ($x eq '-u')  { $USE_UDP     = 1; next; }
		if ($x eq '-u0') { $USE_UDP     = 0; next; }
		if ($x eq '-sn') { $SPLIT_NAL_U = 0; next; }

		#---------------------------------------------------------------
		# Codec
		#---------------------------------------------------------------
		if ($x eq '-264'){ $CODEC = 'H264'; next; }
		if ($x eq '-265'){ $CODEC = 'H265'; next; }
		if ($x eq '-i')  { $INPUT     = shift(@ARGV) =~ s/\s//rg; next; }
		if ($x eq '-f')  { $IN_FORMAT = shift(@ARGV) =~ s/\s//rg; next; }

		if ($x eq '-s') {
			my $size = shift(@ARGV);
			if ($size !~ /^(\d+)x(\d+)$/) { $err .= "Invalid size: $size\n"; }
			$WIDTH  = $1;
			$HEIGHT = $2;
			next;
		}
		if ($x eq '-vb') {
			$BITRATE = shift(@ARGV);
			if ($BITRATE !~ /^\d+(?:\.\d+)?(?:[KkMm]|)$/) { $err .= "Invalid bitrate: $BITRATE\n"; }
			next;
		}
		if ($x eq '-r') {
			$FPS = shift(@ARGV);
			if ($FPS !~ /^\d+$/) { $err .= "Invalid fps: $FPS\n"; }
			next;
		}
		if ($x eq '-g') {
			$KEYINT = shift(@ARGV);
			if ($KEYINT !~ /^\d+$/) { $err .= "Invalid keyframe interval: $KEYINT\n"; }
			next;
		}
		if ($x eq '-ts') { $TIMESTAMP  = 1; next; }
		if ($x eq '-fo') { $FFM_OPTION = shift(@ARGV); next; }
		if ($x eq '-vc') { $FFM_VCODEC = shift(@ARGV) =~ s/\s//rg; next; }
		if ($x eq '-cc') { $FFM_VCOPY  = 1; next; }

		push(@ary, $x);
	}

	if ($HELP) {
		print <<HELP;
Usage: $0 [options]

General options:
  -q		Quiet (sileint mode)
  -d		Debug mode
  -dd		Debug mode (verbose)
  -h		View this help

Server options:
  -b  ip	Bind IP address (default:*)
  -p  port	RTSP listen port number (default:8554)
  -t  sec	Timeout for RTSP connection (default:3)
  -ai id	Digest authentication id
  -ap pass	Digest authentication password
  -u		Use UDP/RTP (default)
  -u0		Not use UDP/RTP
  -sn		Split RTP packets by NAL units

Codec options:
  -264		Encode with H.264/libx264
  -265		Encode with H.265/libx265 (default)
  -s  WxH	Video frame size (default:640x360)
  -vb bitrate	Video bitrate (default:500k)
  -r  rate	Frame rate, fps (default:30)
  -g  int	Keyframe interval (default:=fps)
  -i  device	Input device (default:/dev/video0)
  -f  format	Input device format (default:v4l2)
  -ts		Embed timestamp in video stream
  -fo opt	FFmpeg extra options (default:"-pix_fmt yuv420p")
  -vc codec	Force set ffmpeg video codec.
  -cc		Use camera's built-in codec. Ignore options: -vb -ts
HELP
		exit;
	}

	if (@ary) {
		$err .= "Unknown options: " . join(' ',@ary) . "\n";
	}
	if ($err) {
		$PRINT && print STDERR $err;
		exit(1);
	}
}
{
	my $y = substr($LAST_UPDATE,0,4);
	$PRINT && print "$SERVER_NAME (C)$y nabe\@abk\n\n";
}

#-------------------------------------------------------------------------------
# Bind rtsp port
#-------------------------------------------------------------------------------
my $srv;
my ($usock, $UPORT);
my ($urtcp, $URPORT);
{
	if ($BIND =~ /^unix:(.*)/) {
		#-----------------------------------------------------
		# UNIX domain socket
		#-----------------------------------------------------
		my $name = $1;
		socket($srv, PF_UNIX, SOCK_STREAM, 0)	|| die "socket failed: $!";
		unlink($name);
		bind($srv, sockaddr_un($name))		|| die "bind '$BIND' failed: $!";
		chmod(0777, $name);
		$SIG{INT} = sub {
			unlink($name);
			exit;
		};
	} else {
		#-----------------------------------------------------
		# TCP/IP socket
		#-----------------------------------------------------
		my $ip = $BIND eq '*' ? INADDR_ANY : inet_aton($BIND);
		socket($srv, PF_INET, SOCK_STREAM, getprotobyname('tcp'))	|| die "socket failed: $!";
		setsockopt($srv, SOL_SOCKET, SO_REUSEADDR, pack("l", 1))	|| die "setsockopt failed: $!";
		bind($srv, sockaddr_in($PORT, $ip))				|| die "bind '$BIND:$PORT' failed: $!";

		if ($USE_UDP) {
		  foreach(0..10) {
			socket($usock, PF_INET, SOCK_DGRAM, getprotobyname('udp'))	|| die "UDP socket failed: $!";
			bind($usock, pack_sockaddr_in(0, $ip))				|| die "UDP bind failed: $!";
			$UPORT = (unpack_sockaddr_in(getsockname($usock)))[0];

			socket($urtcp, PF_INET, SOCK_DGRAM, getprotobyname('udp'))	|| die "UDP socket failed: $!";
			my $r = bind($urtcp, pack_sockaddr_in($UPORT+1, $ip));
			if (!$r) {
				if ($_==10) { die "UDP bind failed: $!"; }
				close($usock);
				close($urtcp);
				next;
			}
			$URPORT = (unpack_sockaddr_in(getsockname($urtcp)))[0];
			last;
		  }
		}
	}
	listen($srv, SOMAXCONN) || die "listen failed: $!";

	$PRINT && print "RTSP Listen: $BIND:$PORT" . ($USE_UDP ? "  UDP/RTP $BIND:$UPORT  UDP/RTCP $BIND:$URPORT" : '') . "\n";
}

#-------------------------------------------------------------------------------
# open ffmpeg and video device
#-------------------------------------------------------------------------------
my $ffmpeg;
{
	my $cinfo= $CO_INFO{$CODEC};
	my $clib = $FFM_VCODEC || $cinfo->{lib};

	#-----------------------------------------------------
	# check ffmpeg
	#-----------------------------------------------------
	open(my $fh, "ffmpeg -v quiet -codecs|");
	my @ary = <$fh>;
	close($fh);

	if (!@ary) {
		print STDERR "\"ffmpeg\" command not found! Please install ffmpeg.\n";
		exit(2);
	}
	my $found;
	foreach(@ary) {
		if ($_ !~ /encoders: *(.*)/) { next; }
		if (grep { $_ eq $clib } split(/\s+/, $1)) {
			$found=1;
			last;
		}
	}
	if (!$found) {
		print STDERR "\"ffmpeg\" is not support \"$clib\" ($CODEC)\n";
		exit(3);
	}

	#-----------------------------------------------------
	# open pipe
	#-----------------------------------------------------
	my @cmd;
	if ($FFM_VCOPY) {
		# copy from camera's bultin codec
		@cmd = (
			'ffmpeg', '-v', $PRINT ? 'error' : 'quiet',
			'-f', $IN_FORMAT, '-s', "${WIDTH}x${HEIGHT}", '-r', $FPS, '-pix_fmt', $cinfo->{v4l2fmt}, '-i', $INPUT,
			'-vcodec', 'copy', split(/ +/, $FFM_OPTION),
			'-f', 'rawvideo', 'pipe:1'
		);
	} else {
		# Normal
		my $timestamp = $TIMESTAMP ? "-vf \"settb=AVTB,"
			. "setpts='trunc(PTS/1K)*1K+st(1,trunc(RTCTIME/1K))-1K*trunc(ld(1)/1K)',"
			. "drawtext='fontsize=36:x=8:y=8:text=%{localtime\\:%X}.%{eif\\:1M*t-1K*trunc(t*1K)\\:d\\:3}'\"" : '';
		@cmd = (
			'ffmpeg', '-v', $PRINT ? 'error' : 'quiet',
			'-f', $IN_FORMAT, '-s', "${WIDTH}x${HEIGHT}", '-r', $FPS, '-i', $INPUT,
			$timestamp, '-c', $clib, '-g', $KEYINT ? $KEYINT : $FPS, '-vb', $BITRATE,
			'-fflags', 'nobuffer', '-tune', 'zerolatency', split(/ +/, $FFM_OPTION),
			'-f', 'rawvideo', 'pipe:1'
		);
	}

	$ffmpeg = &safe_pipe_open(@cmd);
	binmode($ffmpeg);

	#-----------------------------------------------------
	# set non blocking I/O
	#-----------------------------------------------------
	my $flags;
	fcntl($ffmpeg, F_GETFL, $flags);
	$flags |= O_NONBLOCK;
	fcntl($ffmpeg, F_SETFL, $flags);
}

#-------------------------------------------------------------------------------
# main loop
#-------------------------------------------------------------------------------
my $srv_fno    = fileno($srv);
my $ffmpeg_fno = fileno($ffmpeg);
my $vec;
vec($vec, $srv_fno,    1) = 1;
vec($vec, $ffmpeg_fno, 1) = 1;

my $urtcp_fno;
if ($USE_UDP) {
	$urtcp_fno = fileno($urtcp);
	vec($vec, $urtcp_fno, 1) = 1;
}

my %clients :shared;
my %closed  :shared;
my %start;
my %socks;
my $rtp_seq = 0;

my %vinfo;

$SIG{PIPE} = 'IGNORE';

while(1) {
	my $r  = select(my $in=$vec, undef, undef, undef);
	if ($r == -1) {
		die "select error: $!";
	}

	foreach(keys(%closed)) {
		close($socks{$_});

		delete $socks{$_};
		delete $closed{$_};
		delete $clients{$_};
	}

	if (vec($in, $srv_fno, 1)) {
		my $addr = accept(my $sock, $srv);
		if (!$addr) { next; }

		my ($cl, $ip) = &addr2cl($addr);

		my $thr = threads->create(\&client, $sock, $cl, $ip);
		if (!defined $thr) { die "threads->create fail!"; }

		$thr->detach();

		my $tid = $thr->tid();
		$socks{$tid} = $sock;
	}

	if (vec($in, $ffmpeg_fno, 1)) {
		my $data;
		my $r = sysread($ffmpeg, $data, 0x1000000);
		if (!$r) {
			print STDERR "ffmpeg is die!\n";
			exit(10);
		}
		while(16383<$r) {
			$r = sysread($ffmpeg, $data, 0x1000000, length($data));
		}

		&send_rtsp_packet($data);

		if ($PARSE_VPS) {
			my $p=0;
			while (0 <= ($p = index($data, "\0\0\0\1", $p))) {	# parse VPS/PPS/SPS
				$p+=4;
				my $x = ord(substr($data, $p, 1));
				my $t;
				   if ($CODEC eq 'H265') { $t = ($x & 0x7e)>>1; }
				elsif ($CODEC eq 'H264') { $t =  $x & 0x1f;     }

				my $n = $NAL_NAME[$t];
				if (!$n) { next; }

				my $x = index($data, "\0\0\1", $p);
				if (substr($data,$x,1) eq "\0") { $x--; }

				if ($x<0) {
					$vinfo{$n} = substr($data, $p);
					$p = length($data);
				} else {
					$vinfo{$n} = substr($data, $p, $x-$p);
					$p = $x;
				}
				(1<$DEBUG) && &log('', "Found $n: " . unpack('H*', $vinfo{$n}));
			}
		}
	}

	if ($USE_UDP && vec($in, $urtcp_fno, 1)) {	# RTCP: RFC3550, section 6
		&rtcp_recive();
	}
}
exit;

#-------------------------------------------------------------------------------
# send rtsp
#-------------------------------------------------------------------------------
sub send_rtsp_packet {
	my $data = shift;
	if ($data eq '') { return; }

	my $tm      = &get_rtp_timestamp();
	my $split_u = $RTP_MAX_SIZE<length($data) || $SPLIT_NAL_U;

	while(length($data)) {
		my $unit;
		my $x = $split_u ? index($data, "\0\0\0\1", 4) : -100;
		if ($x<0) {
			$unit = $data;
			$data = '';
		} else {
			$unit = substr($data, 0, $x);
			$data = substr($data, $x);
		}

		if (%clients) {
			&do_send_rtsp_packet($tm, $unit, $RTP_MAX_SIZE);
		}
	}
}

sub do_send_rtsp_packet {
	my $tm   = shift;
	my $data = shift;
	my $max  = (shift) -15 -8;	# -15: RTP Header and Frag size, -8:RTSP Header

	my $len = length($data);
	my $p   = 0;
	if (substr($data,0,4) eq "\0\0\0\1") { $p=4; $len -=4; }
	my $nal_type = (ord(substr($data, $p, 1)) & 0x7e) >>1;
	my $nal_b1   = substr($data, $p+1, 1);

	my $frags = int(($len-1)/$max);

	foreach(0..$frags) {
		my $size = $max<$len ? $max : $len;

		my $frag_header = '';

		if ($frags) {				# rewrite nal header
			$frag_header
				= "\x62"		# Fragmentation Units
				. $nal_b1
				. chr(($_==0 ? 0x80 : 0) | ($_==$frags ? 0x40 : 0) | $nal_type);

			if ($_==0) { # first packet
				$p        += 2;
				$size     -= 2;
			}
		}

		my $rtp_header
			= "\x80\x60"		# type=96 (fix)
			. pack('n', ++$rtp_seq)	# Sequence number
			. pack('N', $tm)	# timestamp
			. $RTP_SSRC_BIN		# ssrc
		;

		my $rtp_packet = $rtp_header . $frag_header . substr($data, $p, $size);
		my $rtp_size   = length($rtp_packet);
		my $rtsp_packet;
		$len -= $size;
		$p   += $size;

		my $tcp_c=0;
		my $udp_c=0;
		foreach(keys(%clients)) {
			my $addr = $clients{$_};
			if ($addr eq '1') {		# TCP/RTSP
				$rtsp_packet ||= "\$\0" . pack('n', $rtp_size) . $rtp_packet;

				send($socks{$_}, $rtsp_packet, 0);
				$tcp_c++;
				next;
			}
			# UDP/RTP
			send($usock, $rtp_packet, 0, $addr);
			$udp_c++;
		}
		(1<$DEBUG) && &log("[$tm] ", "[Send] RTSP($tcp_c)/RTP($udp_c) seq=$rtp_seq size=$rtp_size Nal=$nal_type frag=$frags");
	}
}

sub get_rtp_timestamp {
	my ($utc, $usec) = Time::HiRes::gettimeofday();
	my $tm = ($utc*$TIMEBASE + int($usec*$TIMEBASE/1000000)) & 0xffffffff;
	return wantarray ? ($tm, $utc, $usec) : $tm;
}

#-------------------------------------------------------------------------------
# rtcp
#-------------------------------------------------------------------------------
sub rtcp_recive {
	my $data;
	my $addr = recv($urtcp, $data, 0x10000, 0);
	my $cl   = &addr2cl($addr);

	my $h0 = ord(substr($data,0,1));
	my $h1 = ord(substr($data,1,1));
	if (($h0 & 0xf0) != 0x80) { next; }	# Do not support

	my $size = unpack('n', substr($data,2,2))*4;

	$DEBUG && &log($cl, "[RTCP:Recive] PT=$h1 size=$size");

	# make Sender report
	my ($tm, $utc, $usec) = &get_rtp_timestamp();
	my $usec_fixp = int($usec * (1<<32)/1000000);

	my $packet
		= "\x80\xC8"			# 0xC0=200 sender report
		. pack('n', 6)			# size/4 (real packet size-4)
		. $RTP_SSRC_BIN			# ssrc
		. pack('N', $utc + 2208988800)	# NTP timestamp MSW
		. pack('N', $usec_fixp)		# NTP timestamp LSW
		. pack('N', $tm)		# RTP timestamp
		. "\0\0\0\0"			# sender's packet count
		. "\0\0\0\0"			# sender's packet octet
	;

	send($urtcp, $packet, 0, $addr);

	$DEBUG && &log($cl, "[RTCP:Send] PT=200 size=24");
}

################################################################################
# Server main
################################################################################
sub client {
	my $sock = shift;
	my $cl   = shift;
	my $cl_ip= shift;

	binmode($sock);
	setsockopt($sock, Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1);
	fcntl($sock, F_GETFL, my $flags);
	fcntl($sock, F_SETFL, $flags | O_NONBLOCK);

	&log($cl, 'New RTSP connection');
	&client_main($sock, $cl, $cl_ip);
	&log($cl, 'Close RTSP connection');

	my $tid = threads::tid();
	$closed{$tid} = 1;
	return;
}

#-------------------------------------------------------------------------------
# RTSP Server
#-------------------------------------------------------------------------------
sub client_main {
	my $sock = shift;
	my $cl   = shift;
	my $cl_ip= shift;

	my $nonce = $AUTH_ID ne '' && &generate_nonce();
	my $play;
	my $udp_port;

	while(1) {
		my ($req, $h, $err) = &recieve_rtsp_request($sock, $cl, $play ? 0 : $TIMEOUT);
		if ($err)  { return; }
		if (!$req) { next; }

		my $res  = &make_rtsp_response_base($h);
		my $body ='';

		if ($req =~ /^TEARDOWN /i) {
			&send_rtsp_response($sock, $cl, $res, $body);
			return;
		}

		if ($nonce && $req =~ m!(DESCRIBE|SETUP|PLAY)\s+([^\s]+)?!i) {
			my $method = $1;
			my $uri    = $2;

			my $auth   = $h->{authorization};
			my $auth_ok;

			while($auth) {
				if ($auth !~ /^digest (.*)/i) { last; };
				my @ary = split(/\s*,\s*/, $1);
				my %opt;
				foreach(@ary) {
					if ($_ =~ /^([^=]+)="([^\"]+)"$/) {
						my $k = $1;
						$k =~ tr/A-Z/a-z/;
						$opt{$k} = $2;
					}
				}
				$opt{method} = $method;
				$opt{uri} =~ s|/+$||;
				$uri      =~ s|/+$||;

				if ($opt{realm} ne $AUTH_REALM) { last; }
				if ($opt{nonce} ne $nonce)      { last; }
				if ($opt{uri}   ne $uri)        { last; }

				$auth_ok = &auth_digest(\%opt);
				last;
			}
			if (!$auth_ok) {
				$res->[0] = 'RTSP/1.0 401 Unauthorized';
				push(@$res, "WWW-Authenticate: Digest realm=\"$AUTH_REALM\", nonce=\"$nonce\"");

				&send_rtsp_response($sock, $cl, $res, $body);
				next;
			}
		}

		if ($req =~ m|^OPTIONS |) {
			push(@$res, 'Public: OPTIONS,DESCRIBE,TEARDOWN,SETUP,PLAY');

		} elsif ($req =~ m|^DESCRIBE rtsp://([^\s]+)|i) {
			push(@$res, 'Content-Type: application/sdp');
			push(@$res, "Content-Base: rtsp://$1");
			my $fmtp='';
			if ($CODEC eq 'H264') {
				$fmtp .= 'profile-level-id=' . ($vinfo{sps} ? unpack('H*', substr($vinfo{sps},1,3)) : '64001E');

				if ($vinfo{sps} || $vinfo{pps}) {
					my $sps = encode_base64($vinfo{sps}, '');
					my $pps = encode_base64($vinfo{pps}, '');
					$fmtp .= ";sprop-parameter-sets=$sps,$pps";
				}
			} else {
				foreach(keys(%vinfo)) {
					$fmtp .= "sprop-$_=" . encode_base64($vinfo{$_}, '') . ';';
				}
				chop($fmtp);
			}
			$body = <<BODY =~ s/\n/\r\n/rg;
v=0
a=control:*
a=range:npt=0-
m=video 0 RTP/AVP 96
a=rtpmap:96 $CODEC/$TIMEBASE
a=framesize:96 $WIDTH-$HEIGHT
a=framerate:$FPS
a=fmtp:96 $fmtp
BODY
		} elsif ($req =~ m|^SETUP |i) {
			if ($h->{transport} =~ m|^(RTP/AVP(?:/UDP))?;.*(client_port=(\d+)-\d+)|i) {
				if ($USE_UDP) {
					$udp_port  = $3;
					my @addr   = unpack_sockaddr_in(getsockname($sock));
					my $srv_ip = inet_ntoa($addr[1]);

					my $ss = sprintf("%08X", $RTP_SSRC);
					push(@$res, "Transport: RTP/AVP;unicast;source=$srv_ip;$2;server_port=$UPORT-$URPORT");
				} else {
					$res->[0] = 'RTSP/1.0 445 Method Not Valid In This State';
				}
			} else {
				push(@$res, 'Transport: RTP/AVP/TCP;unicast;interleaved=0-1');
			}
			push(@$res, "Session: $RTP_SESSION");

		} elsif ($req =~ m|^PLAY |i) {
			push(@$res, 'Range: npt=0.000-');
			&send_rtsp_response($sock, $cl, $res, $body);
			if ($play) { next; }

			$play=1;
			my $tid = threads::tid();

			if ($udp_port) {
				$clients{$tid} = pack_sockaddr_in($udp_port, inet_aton($cl_ip));
			} else {
				$clients{$tid} = 1;
			}
			next;

		} else {
			$res->[0] = 'RTSP/1.0 400 Bad Request';
		}

		&send_rtsp_response($sock, $cl, $res, $body);
	}
}

#-------------------------------------------------------------------------------
# RTSP subroutine
#-------------------------------------------------------------------------------
sub recieve_rtsp_request {
	my $sock = shift;
	my $cl   = shift;
	my $timeout = shift;

	my $vec;
	vec($vec, fileno($sock), 1)=1;
	my $limit = time + $timeout;

	my @lines;
	my $data='';
	while (index($data, "\r\n\r\n")<0) {
		select(my $in=$vec, undef, undef, $timeout ? 1 : undef);

		my $bytes = sysread($sock, $data, 0x100000, length($data));
		if ($data eq "\r\n") { last; }

		if ($timeout) {
			if ($bytes)      { next; }
			if (time<$limit) { next; }
			&log($cl, "Connection timeout!");
			return (undef, undef, 1);
		}
		# not set timeout
		if (!$bytes) {
			return (undef, undef, -1);	# close connection
		}
	}
	substr($data, index($data, "\r\n\r\n")) = '';	# VLC bug?
	while(substr($data,0,2) eq "\$\1") {		# VLC bug?
		my $s = unpack('n', substr($data,2,2));
		$data = substr($data, $s+4);
	}
	my ($req, @lines) = split(/\r\n/, $data);

	$DEBUG && &log($cl,"[Recive] $req");

	my %h;
	foreach(@lines) {
		$DEBUG && &log($cl,"[Recive] $_");
		if ($_ =~ /^([\w\-]+):\s+(.*)/) {
			my $name = $1;
			$name =~ tr/A-Z/a-z/;
			$h{$name} = $2;
		}
	}
	$DEBUG && &log($cl,"[Recive] ");

	if ($req eq '' || $h{cseq} eq '') {
		&send_rtsp_response($sock, $cl, &make_rtsp_response_base(\%h, 'RTSP/1.0 400 Bad Request'));
		$req = undef;
	}
	return ($req, \%h);
}

sub make_rtsp_response_base {
	my $h    = shift;
	my @res  = (shift || 'RTSP/1.0 200 OK');
	if ($h->{cseq} ne '') { push(@res, "CSeq: $h->{cseq}");		}
	if ($h->{session})    { push(@res, "Session: $h->{session}");	}
	push(@res, "User-Agent: $SERVER_NAME");
	return \@res;
}

sub send_rtsp_response {
	my $sock = shift;
	my $cl   = shift;
	my $res  = shift;
	my $body = shift;
	if ($body ne '') {
		push(@$res, 'Content-length: ' . length($body));
	}

	push(@$res, '');
	if ($DEBUG) { foreach(@$res,split(/\r\n/, $body)) { &log($cl, "[Send] $_"); } }

	my $data .= join("\r\n", @$res) . "\r\n" . $body;
	syswrite($sock, $data, length($data));
}

sub auth_digest {
	my $h = shift;
	my $uid   = &encode_uricom($AUTH_ID);
	my $upass = &encode_uricom($AUTH_PASS);

	my $ha1 = Digest::MD5::md5_hex("$uid:$h->{realm}:$upass");
	my $ha2 = Digest::MD5::md5_hex("$h->{method}:$h->{uri}");
	my $res = Digest::MD5::md5_hex("$ha1:$h->{nonce}:$ha2");

	return $h->{response} eq $res;
}

################################################################################
# Subroutine
################################################################################
sub safe_pipe_open {	# https://perldoc.perl.org/perlipc#Safe-Pipe-Opens

	my @cmd = grep { $_ ne '' } @_;
	&log('Open: ' . join(' ', @cmd));

	my $pid = open(my $fh, "-|");		# fork
	if (!defined $pid) {
		die "cannot open pipe: $!";
	}
	if ($pid) {	# parent
		return $fh;
	}

	# child
	close(STDERR);
	exec { $cmd[0] } @cmd;
	die "exit $cmd[0]";
}

sub addr2cl {
	my $addr = shift;
	my ($port, $ip_bin) = unpack_sockaddr_in($addr);
	my $ip = inet_ntoa($ip_bin);
	my $cl = "[$ip:$port] ";
	return wantarray ? ($cl, $ip) : $cl;
}

sub generate_nonce {
	my $len  = shift || 24;
	my $base = 'zcHKPvGgsXMdmV3wSi5TrNt1kqCuAyU8RfoZYx0ln426JWahj_pELB7IDO9b-eQF';
	my $str  = '';
	foreach(1..$len) {
		$str .= substr($base, int(rand(64)), 1);
	}
	return $str;
}

sub decode_uri {
	my $x = shift;
	$x =~ tr/+/ /;
	$x =~ s/%([0-9a-fA-F][0-9a-fA-F])/chr(hex($1))/eg;
	return $x;
}

sub encode_uricom {
	my $x = shift;
	$x =~ s/([^\w!\(\)\*\-\.\~:])/'%' . unpack('H2',$1)/eg;
	return $x;
}

sub log {
	my ($s,$m,$h,$d,$m,$y) = localtime(time());  
	my $tm = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $y+1900, $m+1, $d, $h, $m, $s);
	print join('', "$tm ", @_, "\n");
}

