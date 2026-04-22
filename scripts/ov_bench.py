#!/usr/bin/env python3
"""
ov_bench.py — autonomous end-to-end benchmark for openverb-engine.

Spawns a fresh engine subprocess on an isolated Unix socket, connects as the Swift
app would, and for each WAV fixture runs a full session: session.start → PCM frames
→ sentinel → result. Measures crash rate, empty-result rate, and transcription success.

Usage:
  ov_bench.py                       # run once, write latest.json
  ov_bench.py --repeat 3            # run each WAV 3 times for back-to-back reliability
  ov_bench.py --wavs short-en-clean # only run matching WAVs
  ov_bench.py --json-only           # machine-readable result on stdout
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import socket
import string
import struct
import subprocess
import sys
import time
import wave
from dataclasses import dataclass, asdict, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENGINE_BIN = REPO / "engine" / "build" / "openverb-engine"
WAV_DIR = REPO / "validation" / "audio"
GT_FILE = WAV_DIR / "ground-truth.txt"
RESULTS_DIR = REPO / "validation" / "results"
HISTORY_FILE = RESULTS_DIR / "ov-bench-history.jsonl"
LATEST_FILE = RESULTS_DIR / "latest.json"

# Default model paths (match engine defaults)
DEFAULT_MODEL = Path.home() / ".openverb" / "models" / "gemma-4-E2B-it-Q4_K_M.gguf"
DEFAULT_MMPROJ = Path.home() / ".openverb" / "models" / "mmproj-BF16.gguf"

# IPC wire constants — mirror engine/src/ipc/protocol.cpp
#
# Wire format on the Unix socket is MIXED:
#   • JSON messages (both directions) are newline-delimited UTF-8 text —
#     no length prefix. Terminator is a single '\n'. Engine's send_json()
#     appends '\n'; recv_json() scans the buffer for '\n'.
#   • Audio frames (client → server, after session.start/ready) are
#     length-prefixed: [4-byte BE length][payload].
#   • End-of-audio sentinel is a length-prefixed frame with length = 0
#     (i.e. four zero bytes on the wire).
#   • Server never sends binary. After the sentinel we read newline JSON
#     messages (progress / partial_result / result / error / warning).
FRAME_HEADER_LEN = 4
MAX_JSON = 1 << 20  # 1 MiB

# Audio frame length (samples) per wire frame.
#
# The engine's VadScanner passes every push_frame call directly to WebRTC VAD,
# which accepts ONLY 10 / 20 / 30 ms frames at 16 kHz (i.e. 160, 320, or 480
# samples). Any other length makes WebRtcVad_Process return -1, which
# is_speech() reads as "not speech", so in_speech_ never becomes true and the
# final flush() drops all buffered audio — the session returns an empty
# transcript. We send exactly 480-sample (30 ms) frames to stay on the VAD's
# happy path.
CHUNK_SAMPLES = 480
# --chunk-samples CLI flag overrides this for Swift-parity testing (2048 = 128 ms).

READY_TIMEOUT_S = 60.0      # model must load + socket accept
RESULT_TIMEOUT_S = 90.0     # transcription from sentinel to result
SESSION_START_TIMEOUT_S = 30.0


@dataclass
class Attempt:
    wav: str
    run: int
    status: str           # "ok", "empty", "error", "timeout", "crash", "connect_fail"
    text: str = ""
    duration_s: float = 0.0
    error_code: str = ""
    error_message: str = ""


@dataclass
class BenchResult:
    started_at: str
    ended_at: str
    engine_binary: str
    engine_mtime: str
    total: int = 0
    ok: int = 0
    empty: int = 0
    error: int = 0
    timeout: int = 0
    crash: int = 0
    connect_fail: int = 0
    score_percent: float = 0.0
    engine_crashed: bool = False
    attempts: list[Attempt] = field(default_factory=list)


def load_ground_truth() -> dict[str, str]:
    gt = {}
    if GT_FILE.exists():
        for line in GT_FILE.read_text().splitlines():
            if "|" in line:
                name, txt = line.split("|", 1)
                gt[name.strip()] = txt.strip()
    return gt


def read_wav_pcm(path: Path) -> bytes:
    """Return raw 16-bit mono 16 kHz PCM bytes. Reject wrong format."""
    with wave.open(str(path), "rb") as w:
        nchannels = w.getnchannels()
        sampwidth = w.getsampwidth()
        framerate = w.getframerate()
        nframes = w.getnframes()
        if (nchannels, sampwidth, framerate) != (1, 2, 16000):
            raise ValueError(
                f"{path.name}: expected 1ch/16-bit/16kHz, got {nchannels}ch/{sampwidth*8}b/{framerate}Hz"
            )
        return w.readframes(nframes)


def make_socket_path() -> str:
    rand = "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
    return f"/tmp/ov-bench-{os.getpid()}-{rand}.sock"


def spawn_engine(socket_path: str, model: Path, mmproj: Path, log_path: Path) -> subprocess.Popen:
    """Launch openverb-engine in --listen mode. Returns Popen handle.

    Redirects engine stdout+stderr to log_path for later inspection if the run
    exits unexpectedly.
    """
    log_f = open(log_path, "wb")
    cmd = [
        str(ENGINE_BIN),
        "--listen",
        "--socket", socket_path,
        "--model", str(model),
        "--mmproj", str(mmproj),
        "--verbose",
    ]
    return subprocess.Popen(
        cmd,
        stdout=log_f,
        stderr=subprocess.STDOUT,
        start_new_session=True,  # isolate from our SIGINT
    )


def wait_for_socket(path: str, proc: subprocess.Popen, timeout_s: float) -> None:
    """Block until socket appears or engine exits. Raises on both failure modes."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(
                f"engine exited prematurely (code={proc.returncode}) before socket appeared"
            )
        if os.path.exists(path):
            # Give the accept loop a beat to start
            time.sleep(0.1)
            return
        time.sleep(0.1)
    raise TimeoutError(f"socket {path} did not appear within {timeout_s}s")


class JsonStream:
    """Buffers socket bytes into newline-terminated JSON messages.

    The engine never mixes server→client binary with JSON (server only ever
    writes JSON), so a single byte buffer is enough.
    """

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self._buf = bytearray()

    def read_line_json(self, deadline: float) -> dict:
        while True:
            nl = self._buf.find(b"\n")
            if nl != -1:
                line = bytes(self._buf[:nl])
                del self._buf[:nl + 1]
                if not line:
                    continue
                return json.loads(line.decode("utf-8"))
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("recv_json timed out")
            self.sock.settimeout(max(0.05, remaining))
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionResetError("engine closed connection")
            self._buf.extend(chunk)
            if len(self._buf) > MAX_JSON:
                raise RuntimeError("JSON buffer exceeded 1 MiB without newline")


def connect_engine(path: str, timeout_s: float = 5.0) -> socket.socket:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout_s)
    s.connect(path)
    return s


def send_audio_frame(sock: socket.socket, payload: bytes) -> None:
    """Length-prefixed binary audio frame."""
    header = struct.pack(">I", len(payload))
    sock.sendall(header + payload)


def send_sentinel(sock: socket.socket) -> None:
    """End-of-audio sentinel: 4 zero bytes (length-prefix with len=0)."""
    sock.sendall(b"\x00\x00\x00\x00")


def send_json(sock: socket.socket, obj: dict) -> None:
    """Newline-delimited JSON — NOT length-prefixed."""
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n"
    sock.sendall(payload)


def run_one_session(socket_path: str, pcm: bytes, run_index: int, wav_name: str,
                     chunk_samples: int = CHUNK_SAMPLES) -> Attempt:
    started = time.monotonic()
    attempt = Attempt(wav=wav_name, run=run_index, status="error")
    try:
        sock = connect_engine(socket_path)
    except OSError as e:
        attempt.status = "connect_fail"
        attempt.error_message = f"connect: {e}"
        attempt.duration_s = time.monotonic() - started
        return attempt

    stream = JsonStream(sock)
    debug = os.environ.get("OV_BENCH_DEBUG") == "1"
    def dbg(msg):
        if debug:
            print(f"  [dbg] {msg}", flush=True)
    try:
        dbg("→ session.start")
        send_json(sock, {"type": "session.start", "context": {}})
        ready_deadline = time.monotonic() + SESSION_START_TIMEOUT_S
        while True:
            msg = stream.read_line_json(ready_deadline)
            dbg(f"← {msg}")
            if msg.get("type") == "session.ready":
                break
            if msg.get("type") == "error":
                attempt.status = "error"
                attempt.error_code = msg.get("code", "")
                attempt.error_message = msg.get("message", "")
                attempt.duration_s = time.monotonic() - started
                return attempt

        # Stream PCM in chunk_samples (int16) = chunk_samples*2 bytes
        chunk_bytes = chunk_samples * 2
        frames_sent = 0
        bytes_sent = 0
        for i in range(0, len(pcm), chunk_bytes):
            chunk = pcm[i:i + chunk_bytes]
            send_audio_frame(sock, chunk)
            frames_sent += 1
            bytes_sent += len(chunk)
        dbg(f"→ {frames_sent} audio frames, {bytes_sent} PCM bytes")
        send_sentinel(sock)
        dbg("→ sentinel")

        result_deadline = time.monotonic() + RESULT_TIMEOUT_S
        while True:
            msg = stream.read_line_json(result_deadline)
            dbg(f"← {msg}")
            t = msg.get("type", "")
            if t == "result":
                text = (msg.get("text") or "").strip()
                attempt.text = text
                attempt.status = "ok" if text else "empty"
                break
            if t == "error":
                attempt.status = "error"
                attempt.error_code = msg.get("code", "")
                attempt.error_message = msg.get("message", "")
                break
            # progress / partial_result / warning — keep draining
    except TimeoutError as e:
        attempt.status = "timeout"
        attempt.error_message = str(e)
    except ConnectionResetError as e:
        attempt.status = "crash"
        attempt.error_message = f"engine disconnected: {e}"
    except Exception as e:
        attempt.status = "error"
        attempt.error_message = f"{type(e).__name__}: {e}"
    finally:
        try:
            # Be polite: send session.shutdown so engine can keep its event loop healthy
            if attempt.status in ("ok", "empty"):
                send_json(sock, {"type": "session.shutdown"})
        except Exception:
            pass
        try:
            sock.close()
        except Exception:
            pass

    attempt.duration_s = time.monotonic() - started
    return attempt


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repeat", type=int, default=1, help="runs per WAV (back-to-back reliability)")
    ap.add_argument("--wavs", default="", help="comma-separated substring filter")
    ap.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    ap.add_argument("--mmproj", type=Path, default=DEFAULT_MMPROJ)
    ap.add_argument("--json-only", action="store_true")
    ap.add_argument("--quick", action="store_true", help="only short WAVs for fast iteration")
    ap.add_argument("--chunk-samples", type=int, default=CHUNK_SAMPLES,
                    help="samples per audio frame sent to engine (480=30ms VAD-friendly, 2048=Swift-parity 128ms)")
    return ap.parse_args()


def pick_wavs(filter_str: str, quick: bool) -> list[Path]:
    all_wavs = sorted(WAV_DIR.glob("*.wav"))
    # Skip long ones by default in quick mode; they don't change pass/fail semantics
    if quick:
        all_wavs = [p for p in all_wavs if "two-min" not in p.name and "long" not in p.name]
    if not filter_str:
        return all_wavs
    subs = [s.strip() for s in filter_str.split(",") if s.strip()]
    return [p for p in all_wavs if any(s in p.name for s in subs)]


def main() -> int:
    args = parse_args()
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    if not ENGINE_BIN.exists():
        print(f"ERROR: engine binary missing at {ENGINE_BIN}", file=sys.stderr)
        print("Run: cd engine && cmake --build build", file=sys.stderr)
        return 2
    if not args.model.exists():
        print(f"ERROR: model missing at {args.model}", file=sys.stderr)
        return 2
    if not args.mmproj.exists():
        print(f"ERROR: mmproj missing at {args.mmproj}", file=sys.stderr)
        return 2

    wavs = pick_wavs(args.wavs, args.quick)
    if not wavs:
        print("ERROR: no WAV files selected", file=sys.stderr)
        return 2

    ground_truth = load_ground_truth()

    sock_path = make_socket_path()
    engine_log = RESULTS_DIR / f"engine-{int(time.time())}.log"
    if not args.json_only:
        print(f"socket:      {sock_path}")
        print(f"engine log:  {engine_log}")
        print(f"wavs:        {len(wavs)} × {args.repeat} = {len(wavs) * args.repeat} attempts")

    proc = spawn_engine(sock_path, args.model, args.mmproj, engine_log)
    result = BenchResult(
        started_at=time.strftime("%Y-%m-%dT%H:%M:%S"),
        ended_at="",
        engine_binary=str(ENGINE_BIN),
        engine_mtime=time.strftime("%Y-%m-%dT%H:%M:%S",
                                   time.localtime(ENGINE_BIN.stat().st_mtime)),
    )

    try:
        wait_for_socket(sock_path, proc, READY_TIMEOUT_S)

        for wav in wavs:
            try:
                pcm = read_wav_pcm(wav)
            except Exception as e:
                print(f"skip {wav.name}: {e}", file=sys.stderr)
                continue
            for r in range(args.repeat):
                if proc.poll() is not None:
                    result.engine_crashed = True
                    a = Attempt(wav=wav.name, run=r, status="crash",
                                error_message=f"engine exited code={proc.returncode}")
                    result.attempts.append(a)
                    break
                a = run_one_session(sock_path, pcm, r, wav.name, args.chunk_samples)
                result.attempts.append(a)
                if not args.json_only:
                    tag = a.status.upper().ljust(8)
                    preview = (a.text[:60] + "…") if len(a.text) > 60 else a.text
                    print(f"  [{tag}] {wav.name} run={r} {a.duration_s:5.1f}s  {preview}")
                if a.status == "crash":
                    result.engine_crashed = True
                    break
            if result.engine_crashed:
                break
    finally:
        # Stop engine
        try:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
        except Exception:
            pass
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        result.ended_at = time.strftime("%Y-%m-%dT%H:%M:%S")

    # Tally
    for a in result.attempts:
        result.total += 1
        setattr(result, a.status, getattr(result, a.status, 0) + 1)
    # For silence.wav, empty result is actually correct — count it as ok.
    for a in result.attempts:
        if a.wav == "silence.wav" and a.status == "empty":
            result.ok += 1
            result.empty -= 1
            a.status = "ok"  # reclassify for downstream reports
    result.score_percent = round(100.0 * result.ok / max(1, result.total), 2)

    out = {
        "summary": {k: v for k, v in asdict(result).items() if k != "attempts"},
        "attempts": [asdict(a) for a in result.attempts],
        "ground_truth": ground_truth,
    }

    # Persist
    LATEST_FILE.write_text(json.dumps(out, indent=2, ensure_ascii=False))
    with open(HISTORY_FILE, "a") as f:
        f.write(json.dumps(out["summary"], ensure_ascii=False) + "\n")

    if args.json_only:
        print(json.dumps(out, ensure_ascii=False))
    else:
        s = out["summary"]
        print()
        print(f"=== benchmark summary ===")
        print(f"  score:        {s['score_percent']}%   ({s['ok']}/{s['total']})")
        print(f"  empty:        {s['empty']}")
        print(f"  error:        {s['error']}")
        print(f"  timeout:      {s['timeout']}")
        print(f"  crash:        {s['crash']}")
        print(f"  connect_fail: {s['connect_fail']}")
        print(f"  engine_crashed: {s['engine_crashed']}")
        print(f"  latest:       {LATEST_FILE}")
        print(f"  engine log:   {engine_log}")

    return 0 if result.score_percent >= 100.0 and not result.engine_crashed else 1


if __name__ == "__main__":
    sys.exit(main())
