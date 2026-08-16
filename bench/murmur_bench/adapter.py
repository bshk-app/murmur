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
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

from omni_bench.core.adapter import Capabilities, Transcript, TranscriptionError

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CLI = REPO_ROOT / "MurmurKit" / ".build" / "release" / "murmur-cli"

NEMOTRON = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
VOXTRAL = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
PARAKEET = "mlx-community/parakeet-tdt-0.6b-v3"

# The fast lane's chunk, mirrored from TwoTierEngine.defaultFastChunkMs. It sits
# on a documented latency ladder, so it is not a free knob — but it does shape
# the run, which is why it lands in the backend version string.
FAST_CHUNK_MS = 320


@dataclass(frozen=True)
class Engine:
    """One comparable configuration: how to invoke it and what it actually ran."""

    args: list[str]
    base_model_id: str
    quantization: str | None
    placement: str
    uses_fast_lane: bool


ENGINES: dict[str, Engine] = {
    "fast": Engine(["--mode", "fast"], NEMOTRON, "8bit", "mlx", True),
    "accurate": Engine(["--mode", "accurate"], VOXTRAL, "4bit", "mlx", False),
    "hybrid": Engine(
        ["--mode", "hybrid"], f"{NEMOTRON}+{VOXTRAL}", "8bit+4bit", "mlx", True
    ),
    "parakeet-mlx": Engine(["--parakeet"], PARAKEET, None, "mlx", False),
    "parakeet-ane": Engine(
        ["--parakeet", "--ane"], PARAKEET, None, "mlx+coreml-ane", False
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

    def __init__(self, engine: str, cli: Path = DEFAULT_CLI) -> None:
        if engine not in ENGINES:
            raise ValueError(f"unknown engine {engine!r}; have {sorted(ENGINES)}")
        if not cli.is_file():
            raise FileNotFoundError(
                f"murmur-cli not built at {cli} — "
                "run: swift build -c release --product murmur-cli"
            )
        self.engine = engine
        self._recent_stderr: list[str] = []
        self._ready = threading.Event()
        self._saw_ready = False

        self._proc = subprocess.Popen(
            [str(cli), "--serve", *ENGINES[engine].args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
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
        for line in self._proc.stderr:
            self._recent_stderr.append(line.rstrip("\n"))
            del self._recent_stderr[:-40]
            if line.strip() == "READY":
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
        assert self._proc.stdin is not None and self._proc.stdout is not None
        try:
            self._proc.stdin.write(f"{audio.path}\n")
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
        return Transcript(text=reply["text"])

    def capabilities(self) -> Capabilities:
        # Batch only. The worker consumes a whole file per call; the chunking the
        # --mode lanes do internally is the engine's business, not producer-paced
        # delivery, and calling it streaming would claim streaming-integrity
        # evidence this path cannot produce.
        return Capabilities(supports_timestamps=False, supports_streaming=False, max_concurrency=1)

    def close(self) -> None:
        if self._proc.poll() is not None:
            return
        try:
            if self._proc.stdin:
                self._proc.stdin.close()  # EOF ends the serve loop
            self._proc.wait(timeout=30)
        except Exception:
            self._proc.kill()


def _make(engine: str):
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
    return MurmurTranscriber(engine), model, backend


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


def parakeet_ane():
    return _make("parakeet-ane")
