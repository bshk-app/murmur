#!/usr/bin/env python3
"""Feed a wav to `murmur-cli --serve-stream` at 1x real time.

Exists to measure energy, not quality. In a paced run wall time equals audio
time, so mean power above idle in watts *is* joules per second of audio — no
RTF term needed. That only holds if the audio really arrives at 1x, which is
what the pacing here guarantees.

The clip is replayed as successive utterances (C… F, C… F) until the requested
duration, which both matches how dictation is actually used and gives the power
sampler a long enough stretch to average.

Standard library only: the quiet machine has no numpy or soundfile.

    stream-feed.py <murmur-cli> <clip.wav> <seconds> [engine args…]
"""

import array
import json
import re
import subprocess
import sys
import threading
import time
import wave

CHUNK_MS = 480  # what MicCapture delivers in the app


def read_wav_16k_mono(path):
    with wave.open(path, "rb") as w:
        if w.getnchannels() != 1 or w.getframerate() != 16000 or w.getsampwidth() != 2:
            raise SystemExit(
                f"{path}: need 16 kHz mono int16, got {w.getnchannels()}ch "
                f"{w.getframerate()}Hz {w.getsampwidth() * 8}-bit"
            )
        ints = array.array("h")
        ints.frombytes(w.readframes(w.getnframes()))
    return array.array("f", (s / 32768.0 for s in ints))


def main():
    cli, clip, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
    engine_args = sys.argv[4:]

    samples = read_wav_16k_mono(clip)
    step = int(16000 * CHUNK_MS / 1000)
    clip_seconds = len(samples) / 16000.0

    proc = subprocess.Popen(
        [cli, "--serve-stream", *engine_args],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
    )
    ready = threading.Event()

    def drain():
        # Download progress is redrawn with \r and never terminated, so READY can
        # arrive glued to the end of a progress line. Split on both.
        for raw in proc.stderr:
            for line in re.split(r"[\r\n]", raw.decode("utf-8", "replace")):
                if line.strip() == "READY":
                    ready.set()
        ready.set()

    threading.Thread(target=drain, daemon=True).start()
    if not ready.wait(1800):
        proc.kill()
        raise SystemExit("worker never reported READY")
    print("READY", flush=True)

    t0 = time.monotonic()
    audio_fed = 0.0
    utterances = 0
    while time.monotonic() - t0 < seconds:
        u0 = time.monotonic()
        for i in range(0, len(samples), step):
            payload = samples[i : i + step].tobytes()
            proc.stdin.write(b"C %d\n" % len(payload))
            proc.stdin.write(payload)
            proc.stdin.flush()
            proc.stdout.readline()                      # one reply per request
            # Pace to this chunk's real-time boundary. Falling behind means the
            # engine cannot keep up, and the measurement would silently become a
            # throughput test instead of a realtime one — so report it.
            deadline = u0 + (i + step) / 16000.0
            now = time.monotonic()
            if now < deadline:
                time.sleep(deadline - now)
        proc.stdin.write(b"F\n")
        proc.stdin.flush()
        json.loads(proc.stdout.readline())
        audio_fed += clip_seconds
        utterances += 1
        behind = (time.monotonic() - u0) - clip_seconds
        if behind > 0.25:
            print(f"WARNING utterance {utterances} ran {behind:.2f}s behind real time",
                  file=sys.stderr, flush=True)

    wall = time.monotonic() - t0
    proc.stdin.close()
    proc.wait(timeout=30)
    print(f"audio_seconds {audio_fed:.1f}")
    print(f"wall_seconds  {wall:.1f}")
    print(f"utterances    {utterances}")
    print(f"realtime_ratio {wall / audio_fed:.3f}   (>1.05 means it fell behind)")


if __name__ == "__main__":
    main()
