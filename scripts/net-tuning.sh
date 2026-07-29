#!/usr/bin/env bash
# UDP receive buffers for IPMX media on macOS.
#
# The defaults are sized for ordinary application traffic and will drop packets at the
# head of a keyframe. These settings do NOT survive a reboot; make them permanent with a
# /Library/LaunchDaemons plist once you settle on the values.
#
# Needs sudo. Run it yourself — read it first.
set -euo pipefail

echo "current:"
sysctl kern.ipc.maxsockbuf net.inet.udp.recvspace net.inet.udp.maxdgram

echo
echo "applying:"
# The socket-buffer ceiling. SO_RCVBUF requests above this are silently clamped.
sudo sysctl -w kern.ipc.maxsockbuf=16777216
# Default UDP receive space for sockets that do not ask for more.
sudo sysctl -w net.inet.udp.recvspace=8388608

echo
echo "now:"
sysctl kern.ipc.maxsockbuf net.inet.udp.recvspace net.inet.udp.maxdgram

echo
echo "verify what a socket actually got with: ipmx-decoder --verbose"
