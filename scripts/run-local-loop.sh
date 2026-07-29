#!/usr/bin/env bash
# Phase 0 smoke test: encoder and decoder on one Mac over loopback.
# No switch, no multicast, no PTP. Ctrl-C stops both.
set -euo pipefail

cd "$(dirname "$0")/.."

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
PORT="${PORT:-50000}"

echo "building..."
swift build -c release

cleanup() {
    echo
    echo "stopping"
    kill "${ENCODER_PID:-}" "${DECODER_PID:-}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "starting encoder on 127.0.0.1:${PORT}"
./.build/release/ipmx-encoder \
    --dest 127.0.0.1 --iface 127.0.0.1 --port "${PORT}" \
    --width "${WIDTH}" --height "${HEIGHT}" --fps "${FPS}" &
ENCODER_PID=$!

# Give the encoder time to emit its first IDR and write the SDP.
sleep 3

if [[ ! -f sdp/stream.sdp ]]; then
    echo "the encoder did not write an SDP — check the Screen Recording permission" >&2
    exit 1
fi

echo "starting decoder"
./.build/release/ipmx-decoder --sdp sdp/stream.sdp --iface 127.0.0.1 &
DECODER_PID=$!

wait
