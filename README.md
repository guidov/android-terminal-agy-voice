# Antigravity CLI (`agy`) Voice Mode on Android Linux Terminal

This repository documents how to install the **Antigravity CLI (`agy`)** inside the Android **Terminal** app and how to fix `/voice` (`/voice live` and `/voice ptt`) so that full-duplex microphone input and speaker playback work reliably.

---

## 1. Android App & Environment

- **Android App:** **Terminal** (`com.android.virtualization.terminal` — Android's built-in Linux development environment powered by the Android Virtualization Framework / `crosvm`).
- **Guest OS:** Debian GNU/Linux 13 (Trixie, `arm64`).
- **Audio Hardware:** `card 0: SoundCard [VirtIO SoundCard], device 0: virtio-snd [VirtIO PCM 0]` (`1` playback stream, `1` capture stream passed through from the Android host).
- **Host Permission Required:** Ensure the Android **Terminal** app is granted **Microphone** permission in Android Settings (`Settings -> Apps -> Terminal -> Permissions -> Microphone -> Allow`).

---

## 2. How to Install Antigravity CLI (`agy`)

Inside the Android **Terminal** app:

1. **Run the installer (or place the `agy` binary in `~/.local/bin`):**
   ```bash
   mkdir -p ~/.local/bin
   # Add ~/.local/bin to PATH in ~/.bashrc and ~/.profile if not already present:
   export PATH="$HOME/.local/bin:$PATH"
   ```
   When installed via the Antigravity CLI installer, `agy` is placed at:
   - Binary: `~/.local/bin/agy`
   - App Data & Logs: `~/.gemini/antigravity-cli/log/`

2. **Start `agy` and authenticate:**
   ```bash
   agy
   ```
   Once inside the TUI, log in with `/login` (or follow the startup OAuth prompt).

---

## 3. The Problem: Why `/voice live` Could Not Hear the Microphone

When running `/voice live` in `agy` inside the Android Terminal VM, three separate issues prevented voice mode from working out of the box:

### Issue A: Missing ALSA Capture/Playback Utilities (`alsa-utils`)
- When `PULSE_SERVER` is not explicitly set in the environment, `agy` searches `PATH` for `pw-record` or `arecord` for microphone capture (`16000 Hz, S16_LE, mono`) and `pw-cat`, `paplay`, or `aplay` for speaker playback (`24000 Hz, S16_LE, mono`).
- By default, `alsa-utils` (`arecord` and `aplay`) was not installed, causing `/voice` to fail immediately when starting recording.

### Issue B: PulseAudio Full-Duplex Deadlock on `virtio-snd`
- Debian in the Android Terminal VM came with `pulseaudio` (`17.0`) and `pulseaudio-utils` (`/usr/bin/paplay`) preinstalled, and routed default ALSA traffic through PulseAudio (`/usr/share/alsa/pulse-alsa.conf`).
- Because `/usr/bin/paplay` was present in `PATH`, `agy` selected `paplay` for speaker output and `arecord` (via the PulseAudio ALSA plugin) for microphone capture.
- **What happened during `/voice live`:**
  1. `arecord` started capturing microphone audio (`SPEECH_STARTED` triggered normally with `mic_rms: 202.4` – `661.1`).
  2. The moment `paplay` opened a simultaneous playback stream on the `virtio-snd` device, PulseAudio hit a `POLLOUT`/`POLLIN` wakeup bug on the VirtIO sound driver:
     ```text
     ALSA woke us up to write/read new data to/from the device, but there was actually nothing to write/read.
     Most likely this is a bug in the ALSA driver '(null)'.
     We were woken up with POLLOUT/POLLIN set -- however a subsequent snd_pcm_avail() returned 0 or another value < min_avail.
     ```
  3. Immediately upon playback starting, PulseAudio's capture stream stalled permanently (`0 bytes` delivered to `arecord`), causing `agy` to stop hearing the microphone and time out after 10 seconds with `voice_talker_stall` (`quiet_ms: 10000`).

### Issue C: Raw Microphone Gain Calibration
- Raw `virtio-snd` microphone audio from the Android host has a quiet signal level (normal speech peaks around `3043 / 32768` or `-20.6 dBFS`, `RMS ~ 389–808`, while ambient room silence is `RMS ~ 28`).
- Over-boosting the microphone raises ambient silence above `agy`'s speech threshold (preventing `SPEECH_ENDED` from firing), whereas a slight software gain boost (`+2.6 dB`) keeps ambient silence low (`RMS ~ 28`) while improving speech clarity.

---

## 4. How It Was Solved

Testing direct ALSA (`plughw:0,0`) without PulseAudio proved that the underlying `virtio-snd` kernel driver supports simultaneous full-duplex capture (`16000 Hz`) and playback (`24000 Hz` resampled to `48000 Hz`) with zero dropped bytes or stalls.

### Step-by-Step Fix

1. **Install `alsa-utils`:**
   ```bash
   sudo apt-get update && sudo apt-get install -y alsa-utils
   ```

2. **Disable and remove PulseAudio so `agy` uses `arecord` and `aplay` directly:**
   ```bash
   systemctl --user stop pulseaudio.socket pulseaudio.service || true
   systemctl --user mask pulseaudio.socket pulseaudio.service || true
   sudo apt-get remove -y pulseaudio pulseaudio-utils
   ```
   Removing `pulseaudio-utils` removes `/usr/bin/paplay`, causing `agy` to natively select `/usr/bin/aplay` for playback and `/usr/bin/arecord` for capture.

3. **Configure `~/.asoundrc` for Direct Full-Duplex ALSA (`plughw:0,0`) + `Mic Boost`:**
   Copy [`asoundrc`](./asoundrc) to `~/.asoundrc`:
   ```bash
   cp asoundrc ~/.asoundrc
   ```

4. **Initialize and calibrate the `Mic Boost` softvol control (`38%` / `+2.61 dB`):**
   ```bash
   arecord -f S16_LE -r 16000 -c 1 -d 1 -t raw -q /dev/null
   amixer -c 0 sset 'Mic Boost' 38%
   sudo alsactl store
   ```

---

## 5. Quick Automated Setup

Run the included setup and verification script:

```bash
chmod +x setup-voice.sh
./setup-voice.sh
```
