#!/usr/bin/env bash
set -euo pipefail

echo "==> [1/4] Ensuring alsa-utils is installed..."
if ! command -v arecord >/dev/null 2>&1 || ! command -v aplay >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y alsa-utils
fi

echo "==> [2/4] Stopping and removing PulseAudio to prevent virtio-snd full-duplex stalls..."
systemctl --user stop pulseaudio.socket pulseaudio.service 2>/dev/null || true
systemctl --user mask pulseaudio.socket pulseaudio.service 2>/dev/null || true
if dpkg -l | grep -qE '^ii\s+(pulseaudio|pulseaudio-utils)\s'; then
    sudo apt-get remove -y pulseaudio pulseaudio-utils
fi

echo "==> [3/4] Installing ~/.asoundrc and calibrating Mic Boost (+2.61 dB)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/asoundrc" "$HOME/.asoundrc"

# Trigger softvol control creation and set calibrated gain (38% = +2.61 dB)
arecord -f S16_LE -r 16000 -c 1 -d 1 -t raw -q /dev/null
amixer -c 0 sset 'Mic Boost' 38% >/dev/null
sudo alsactl store

echo "==> [4/4] Verifying full-duplex simultaneous capture + playback..."
python3 - <<'EOF'
import subprocess, time, struct, math

rec = subprocess.Popen(
    ["arecord", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw", "-q", "-"],
    stdout=subprocess.PIPE,
)
time.sleep(0.5)
d1 = rec.stdout.read(16000)

play = subprocess.Popen(
    ["aplay", "-q", "-t", "raw", "-f", "S16_LE", "-r", "24000", "-c", "1", "--buffer-time=100000", "-"],
    stdin=subprocess.PIPE,
)
play.stdin.write(b"\x00\x00" * 24000)
play.stdin.flush()

d2 = rec.stdout.read(32000)
play.stdin.close()
play.wait()

d3 = rec.stdout.read(16000)
rec.terminate()

assert len(d1) == 16000 and len(d2) == 32000 and len(d3) == 16000, "Capture stalled!"
print(f"SUCCESS: Full-duplex verified (before={len(d1)}B, during={len(d2)}B, after={len(d3)}B)")
EOF
