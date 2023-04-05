# tiny-rtsp-server

This is an RTSP server using **ffmpeg** command.
Only supports **video stream** by video devices.

## Feature

- Easy to use.
- Low latency (*about 200-300ms* with [MPC-HC](https://github.com/clsid2/mpc-hc)).
- Works with Perl, **no external module required**.
- **No hardware codecs required** (Can use hardware codecs).

## Support

- Multiclient (use perl's ithreads).
- RTP/TCP and RTP/UDP unicast.
- Digest authentication.
- H264(libx264), H265(libx265).

## Not support

- Audio stream.
- IPv6.
- RTSP streaming from push stream by external software.
- RTSP streaming from video file.
- RTP/UDP multicast.
- RTSP path (ignore path).
- Basic authentication.
- Multiple video streams.
	- If you wish to distribute multiple videos, launch this software multiple.

# Install

Install to /usr/bin as root:
```
wget -O  /usr/bin/tiny-rtsp-server.pl https://raw.githubusercontent.com/nabe-abk/tiny-rtsp-server/main/tiny-rtsp-server.pl
chmod +x /usr/bin/tiny-rtsp-server.pl
```

Install to ~/bin or any directory:
```
cd ~/bin
wget https://raw.githubusercontent.com/nabe-abk/tiny-rtsp-server/main/tiny-rtsp-server.pl
chmod +x tiny-rtsp-server.pl
```

# Usage

```
Usage: tiny-rtsp-server.pl [options]

General options:
  -q            Quiet (sileint mode)
  -d            Debug mode
  -dd           Debug mode (verbose)
  -h            View this help

Server options:
  -b  ip        Bind IP address (default:*)
  -p  port      RTSP listen port number (default:8554)
  -t  sec       Timeout for RTSP connection (default:3)
  -ai id        Digest authentication id
  -ap pass      Digest authentication password
  -u            Use UDP/RTP (default)
  -u0           Not use UDP/RTP
  -sn           Split RTP packets by NAL units

Codec options:
  -264          Encode with H.264/libx264
  -265          Encode with H.265/libx265 (default)
  -s  WxH       Video frame size (default:640x360)
  -vb bitrate   Video bitrate (default:500k)
  -r  rate      Frame rate, fps (default:30)
  -g  int       Keyframe interval (default:=fps)
  -i  device    Input device (default:/dev/video0)
  -f  format    Input device format (default:v4l2)
  -ts           Embed timestamp in video stream
  -fo opt       FFmpeg extra options (default:"-pix_fmt yuv420p")
  -vc codec     Force set ffmpeg video codec.
  -cc           Use camera's built-in codec. Ignore options: -vb -ts
```

## Command line examples

Run default:
```
tiny-rtsp-server.pl
```

Port is 8554, RTSP authentication, H.264 encode:
```
tiny-rtsp-server.pl -p 8554 -264 -ai myid -ap pass
```

Bitrate 0.1Mbps, 15fps, video width 800px, video height 450px, with timestamp:
```
tiny-rtsp-server.pl -vb 0.1m -r 15 -s 800x450 -ts
```

Camera's built-in encoder (include Raspberry Pi's camera):
```
tiny-rtsp-server.pl -cc -264
```

Raspberry Pi, h264 with bcm2835 hardware encoder:
```
tiny-rtsp-server.pl -vc h264_v4l2m2m -264
```

*[*] On the Raspberry Pi, it is lower latency to consider the camera's built-in codec than to use h264_v4l2m2.*

# Memo

```
v4l2-ctl --list-devices
v4l2-ctl --list-formats -d /dev/video0
v4l2-ctl --list-formats-ext -d /dev/video0
```
