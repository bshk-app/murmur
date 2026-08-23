"""omni-bench host adapter for Murmur.

Lives in this repo, not in omni-bench: the benchmark must not know about the
app. It wraps ``murmur-cli`` rather than reimplementing inference, so what gets
scored is the same code the menu-bar app runs.

**One worker per engine, not one process per sample.** The producer calls
``transcribe`` once per sample and times the call. Spawning a process each time
would charge every measurement for loading the model — around 10 s of the ~30 s
a Voxtral sample takes — so the worker is started once, waits for ``READY`` on
stderr, and then answers one JSON line per path written to its stdin.

**Identity.** ``model`` and ``backend`` are closed objects (``additionalProperties:
false``), so everything that shaped a run has to fit in the fields that exist:
the model repos go in ``base_model_id``, the compute placement in ``backend.id``,
and the pinned mlx-audio-swift revision plus the fast-lane chunk size in
``backend.version``. Without that last part two runs with different chunk sizes
would pool as one configuration.

Usage::

    PYTHONPATH=<repo>/bench omni-bench run \\
      --adapter murmur_bench.adapter:parakeet_ane \\
      --manifest data/asr.fleurs.ru.quick.v1/manifest.json \\
      --measurement-profile audio_transcription.batch_single.v1 \\
      --run-profile '{"delivery":"batch","chunk_ms":null,"warmup_samples":0,
                      "concurrency":1,"family_parameters":{}}' \\
      --out runs/parakeet-ane.jsonl
"""

from __future__ import annotations

import atexit
import json
import re
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from omni_bench.core.adapter import Capabilities, Transcript, TranscriptionError

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CLI = REPO_ROOT / "MurmurKit" / ".build" / "release" / "murmur-cli"

NEMOTRON = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
PARAKEET = "mlx-community/parakeet-tdt-0.6b-v3"
# Same base model with the encoder quantized to int8 (~244 MB). Pure MLX, so it
# needs no CoreML package — which also puts it out of reach of the ANE path's
# cache bug (ai-audio-swift#26).
PARAKEET_INT8 = "beshkenadze/parakeet-tdt-0.6b-v3-mlx-encoder-int8"

# The Nemotron live chunk mirrored from TwoTierEngine.defaultFastChunkMs.
FAST_CHUNK_MS = 160


@dataclass(frozen=True)
class Engine:
    """One comparable configuration: how to invoke it and what it actually ran."""

    args: list[str]
    base_model_id: str
    quantization: str | None
    placement: str
    uses_fast_lane: bool


ENGINES: dict[str, Engine] = {
    "fast": Engine(
        ["--mode", "fast", "--language", "ru"], NEMOTRON, "8bit", "mlx", True
    ),
    "accurate": Engine(["--mode", "accurate"], PARAKEET, None, "mlx", False),
    "hybrid": Engine(
        ["--mode", "hybrid", "--language", "ru"],
        f"{NEMOTRON}+{PARAKEET}", "8bit+bf16", "mlx", True,
    ),
    "parakeet-mlx": Engine(["--parakeet"], PARAKEET, None, "mlx", False),
    "parakeet-int8": Engine(
        ["--parakeet", "--repo", PARAKEET_INT8], PARAKEET_INT8, "int8-encoder", "mlx", False
    ),
    # `backend.id` is a semanticId (`^[a-z0-9][a-z0-9._-]*$`), so the two compute
    # units are joined with a hyphen — a `+` is rejected by the schema. The model
    # side has no such rule, which is why hybrid's base_model_id can keep one.
    "parakeet-ane": Engine(
        ["--parakeet", "--ane"], PARAKEET, None, "mlx-coreml-ane", False
    ),
}


def _dependency_revision() -> str:
    """The pinned mlx-audio-swift commit — the inference code that actually ran."""
    resolved = json.loads((REPO_ROOT / "MurmurKit" / "Package.resolved").read_text())
    for pin in resolved.get("pins", []):
        if "mlx-audio" in pin.get("identity", ""):
            return str(pin["state"]["revision"])[:12]
    raise RuntimeError("mlx-audio-swift is not pinned in MurmurKit/Package.resolved")


class MurmurTranscriber:
    """Batch transcriber backed by one long-lived ``murmur-cli --serve`` worker."""

    def __init__(self, engine: str, cli: Path = DEFAULT_CLI, stream: bool = False) -> None:
        if engine not in ENGINES:
            raise ValueError(f"unknown engine {engine!r}; have {sorted(ENGINES)}")
        if not cli.is_file():
            raise FileNotFoundError(
                f"murmur-cli not built at {cli} — "
                "run: swift build -c release --product murmur-cli"
            )
        self.engine = engine
        self.stream = stream
        self._recent_stderr: list[str] = []
        self._ready = threading.Event()
        self._saw_ready = False

        # Binary pipes both ways: the streaming seam frames raw float32 PCM on
        # stdin, and replies are JSON lines that decode the same either way.
        self._proc = subprocess.Popen(
            [str(cli), "--serve-stream" if stream else "--serve", *ENGINES[engine].args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        atexit.register(self.close)

        # stderr carries the worker's progress AND everything the model layer
        # prints (the worker points fd 1 at stderr so its stdout stays parseable).
        # It has to be drained or the pipe fills and the worker blocks mid-run.
        threading.Thread(target=self._drain_stderr, daemon=True).start()

        # The event also fires when the worker dies, so READY has to be checked
        # separately: a worker that crashed while loading would otherwise sail
        # past here and turn one startup failure into 64 per-sample errors.
        if not self._ready.wait(timeout=900) or not self._saw_ready:
            self.close()
            raise RuntimeError(
                f"{engine}: worker never reported READY "
                f"(exit {self._proc.poll()}).\n" + self._stderr_tail()
            )

    def _drain_stderr(self) -> None:
        assert self._proc.stderr is not None
        for raw in self._proc.stderr:
            # Download progress is redrawn with \r and never terminated, so a
            # newline-delimited read hands back the whole progress bar with READY
            # stuck on the end ("…/755215305 filesREADY"). Split on both, or the
            # marker is only ever recognised when nothing had to be downloaded —
            # which is exactly backwards, since a download is when it takes long.
            text = raw.decode("utf-8", errors="replace")
            for line in re.split(r"[\r\n]", text):
                line = line.strip()
                if not line:
                    continue
                self._recent_stderr.append(line)
                del self._recent_stderr[:-40]
                if line == "READY":
                    self._saw_ready = True
                    self._ready.set()
        self._ready.set()  # the worker died; unblock the waiter to report it

    def _stderr_tail(self) -> str:
        return "\n".join(f"  {line}" for line in self._recent_stderr[-15:])

    def transcribe(self, audio, *, language: str, task: dict) -> Transcript:
        """Transcribe one prepared sample.

        ``language`` is accepted and not forwarded: none of these engines takes a
        language on this path — Parakeet v3 and Voxtral detect it, and Nemotron's
        language argument is not plumbed through the offline entry point. The
        FLEURS Russian Tasks are monolingual, so this changes nothing there; it
        would matter for a mixed-language Task.
        """
        if self._proc.poll() is not None:
            raise TranscriptionError(
                f"{self.engine}: worker exited with {self._proc.returncode}\n"
                + self._stderr_tail()
            )
        return Transcript(text=self._exchange(f"{audio.path}\n".encode())["text"])

    def transcribe_stream(self, stream, *, language: str, task: dict, emit) -> Transcript:
        """Consume producer-paced chunks, emit partials, return the final text.

        Every chunk is answered, including one that produced no new text — the
        producer is blocked on the reply, and going quiet would stall the paced
        feed and be scored as failing to drain the stream. Only non-empty
        partials are emitted, since the producer ignores empty ones anyway and
        the first non-empty one is what it timestamps.
        """
        for chunk in stream:
            payload = np.asarray(chunk.samples, dtype=np.float32).tobytes()
            reply = self._exchange(b"C %d\n" % len(payload) + payload)
            partial = reply.get("partial") or ""
            if partial.strip():
                emit(partial)
        return Transcript(text=self._exchange(b"F\n")["text"])

    def _exchange(self, request: bytes) -> dict:
        """One request, one reply. Any failure is this sample's, not the run's."""
        if self._proc.poll() is not None:
            raise TranscriptionError(
                f"{self.engine}: worker exited with {self._proc.returncode}\n"
                + self._stderr_tail()
            )
        assert self._proc.stdin is not None and self._proc.stdout is not None
        try:
            self._proc.stdin.write(request)
            self._proc.stdin.flush()
            line = self._proc.stdout.readline()
        except (BrokenPipeError, ValueError) as exc:
            raise TranscriptionError(f"{self.engine}: worker pipe closed: {exc}") from exc

        if not line:
            raise TranscriptionError(
                f"{self.engine}: worker closed stdout mid-run\n" + self._stderr_tail()
            )
        try:
            reply = json.loads(line)
        except json.JSONDecodeError as exc:
            raise TranscriptionError(f"{self.engine}: unparseable reply {line!r}") from exc
        if "error" in reply:
            raise TranscriptionError(f"{self.engine}: {reply['error']}")
        return reply

    def capabilities(self) -> Capabilities:
        # A worker is started for exactly one seam, so it declares exactly one.
        # Advertising both would let a run profile pick the seam at runtime, and
        # a delivery selector is not streaming-integrity evidence.
        return Capabilities(
            supports_timestamps=False,
            supports_streaming=self.stream,
            max_concurrency=1,
        )

    def close(self) -> None:
        if self._proc.poll() is not None:
            return
        try:
            if self._proc.stdin:
                self._proc.stdin.close()  # EOF ends the serve loop
            self._proc.wait(timeout=30)
        except Exception:
            self._proc.kill()


def _make(engine: str, stream: bool = False):
    spec = ENGINES[engine]
    version = _dependency_revision()
    if spec.uses_fast_lane:
        version = f"{version}+chunk{FAST_CHUNK_MS}ms"
    model = {
        "base_model_id": spec.base_model_id,
        "artifact_sha256": None,
        "quantization": spec.quantization,
    }
    backend = {"id": spec.placement, "version": version}
    return MurmurTranscriber(engine, stream=stream), model, backend


# One factory per comparable configuration. The engine name is then visible in
# the --adapter argument, so an operator reading the command can see which one
# produced an artifact without opening it.
def fast():
    return _make("fast")


def accurate():
    return _make("accurate")


def hybrid():
    return _make("hybrid")


def parakeet_mlx():
    return _make("parakeet-mlx")


def parakeet_int8():
    return _make("parakeet-int8")


# Streaming counterparts. Separate factories rather than one adapter that serves
# both seams: the worker is launched for one of them, and which seam produced a
# number has to be visible in the command that produced it — batch WER and
# streaming WER are not interchangeable.
def fast_stream():
    return _make("fast", stream=True)


def accurate_stream():
    return _make("accurate", stream=True)


def hybrid_stream():
    return _make("hybrid", stream=True)


def parakeet_mlx_stream():
    return _make("parakeet-mlx", stream=True)


def parakeet_int8_stream():
    return _make("parakeet-int8", stream=True)


def parakeet_ane_stream():
    return _make("parakeet-ane", stream=True)


def parakeet_ane():
    return _make("parakeet-ane")
