#!/usr/bin/env bash
# Phase 0 smoke test: encoder and decoder on one Mac over loopback.
# No switch, no multicast, no PTP. Ctrl-C stops both.
#
#   ./scripts/run-local-loop.sh            # H.264
#   ./scripts/run-local-loop.sh h265       # H.265
set -euo pipefail

cd "$(dirname "$0")/.."

CODEC="${1:-${CODEC:-h264}}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-60}"
PORT="${PORT:-50000}"
SDP="sdp/${CODEC}.sdp"

echo "building..."
swift build -c release

cleanup() {
    echo
    echo "stopping"
    kill "${ENCODER_PID:-}" "${DECODER_PID:-}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "starting ${CODEC} encoder on 127.0.0.1:${PORT}"
./.build/release/ipmx-encoder \
    --codec "${CODEC}" \
    --dest 127.0.0.1 --iface 127.0.0.1 --port "${PORT}" \
    --width "${WIDTH}" --height "${HEIGHT}" --fps "${FPS}" \
    --sdp "${SDP}" &
ENCODER_PID=$!

# Give the encoder time to emit its first random access point and write the SDP.
sleep 3

if [[ ! -f "${SDP}" ]]; then
    echo "the encoder did not write an SDP — check the Screen Recording permission" >&2
    exit 1
fi

echo "starting decoder"
./.build/release/ipmx-decoder --sdp "${SDP}" --iface 127.0.0.1 &
DECODER_PID=$!

echo
echo "note: ScreenCaptureKit only delivers frames when the screen changes, so the counters"
echo "      stall on a completely idle desktop. Move the mouse to keep frames flowing."
echo

wait
