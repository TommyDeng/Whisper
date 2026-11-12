#!/usr/bin/env python3
"""Generate short loopable PCM WAV tones for call ringing (no third-party deps)."""

from __future__ import annotations

import math
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "sounds"
SAMPLE_RATE = 22050
AMPLITUDE = 0.32  # keep modest so a ringtone is not painfully loud


def _sample(t: float, freqs: tuple[float, ...]) -> int:
    if not freqs:
        return 0
    value = sum(math.sin(2 * math.pi * freq * t) for freq in freqs) / len(freqs)
    # Short fade in/out on each burst is applied by the caller via envelope.
    return int(max(-1.0, min(1.0, value)) * AMPLITUDE * 32767)


def write_loop(path: Path, freqs: tuple[float, ...], on_sec: float, off_sec: float) -> None:
    n_on = int(SAMPLE_RATE * on_sec)
    n_off = int(SAMPLE_RATE * off_sec)
    fade = min(int(SAMPLE_RATE * 0.01), n_on // 4)
    frames = bytearray()
    for i in range(n_on):
        env = 1.0
        if fade and i < fade:
            env = i / fade
        elif fade and i >= n_on - fade:
            env = (n_on - i) / fade
        t = i / SAMPLE_RATE
        sample = int(_sample(t, freqs) * env)
        frames += sample.to_bytes(2, "little", signed=True)
    frames += b"\x00\x00" * n_off
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "w") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(bytes(frames))
    print(f"wrote {path.relative_to(ROOT)} ({len(frames) // 2} samples)")


def write_chime(path: Path) -> None:
    """A short two-note notification, not looped (~0.45 s)."""
    # Slightly quieter than a ringtone.
    amplitude = 0.26
    notes: list[tuple[tuple[float, ...], float]] = [
        ((880.0,), 0.12),
        ((), 0.04),
        ((1174.7, 1760.0), 0.18),
        ((), 0.08),
    ]
    frames = bytearray()
    for freqs, dur in notes:
        n = int(SAMPLE_RATE * dur)
        fade = min(int(SAMPLE_RATE * 0.008), max(1, n // 4)) if freqs else 0
        for i in range(n):
            env = 1.0
            if fade and i < fade:
                env = i / fade
            elif fade and i >= n - fade:
                env = (n - i) / fade
            t = i / SAMPLE_RATE
            if freqs:
                value = sum(math.sin(2 * math.pi * freq * t) for freq in freqs) / len(freqs)
                sample = int(max(-1.0, min(1.0, value)) * amplitude * env * 32767)
            else:
                sample = 0
            frames += sample.to_bytes(2, "little", signed=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "w") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(bytes(frames))
    print(f"wrote {path.relative_to(ROOT)} ({len(frames) // 2} samples)")


def main() -> None:
    # Incoming: classic dual-tone ring, 2 s on / 2 s off.
    write_loop(OUT / "incoming_ring.wav", (440.0, 480.0), 2.0, 2.0)
    # Ringback / waiting: single 425 Hz, 1 s on / 3 s off, distinct from incoming.
    write_loop(OUT / "ringback.wav", (425.0,), 1.0, 3.0)
    write_chime(OUT / "message_chime.wav")


if __name__ == "__main__":
    main()
