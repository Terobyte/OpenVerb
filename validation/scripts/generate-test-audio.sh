#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/audio"
mkdir -p "$AUDIO_DIR"

say_to_wav() {
    local text="$1"
    local outfile="$AUDIO_DIR/$2"
    local tmpfile
    tmpfile="$(mktemp /tmp/generate-test-audio.XXXXXX.aiff)"
    say -v Samantha -r 175 "$text" -o "$tmpfile"
    afconvert "$tmpfile" "$outfile" -d LEI16@16000 -f WAVE -c 1
    rm -f "$tmpfile"
    echo "Generated: $outfile ($(stat -f%z "$outfile") bytes)"
}

echo "=== Generating synthetic test audio with macOS say ==="
echo ""

say_to_wav "Hello, this is a short test sentence." "short-en-clean.wav"

say_to_wav "The quick brown fox jumps over the lazy dog. She sold sea shells by the sea shore. How much wood would a woodchuck chuck? Peter Piper picked a peck of pickled peppers." "medium-en-clean.wav"

say_to_wav "Artificial intelligence has transformed the way we interact with technology. From voice assistants to recommendation systems, machine learning models are embedded in nearly every digital product we use today. The field continues to evolve rapidly, with new architectures and training techniques emerging on a regular basis. Researchers are pushing the boundaries of what these systems can achieve, from generating creative content to solving complex scientific problems." "long-en-clean.wav"

say_to_wav "Um, I think, uh, you know, this is like a test with filler words." "filler-en.wav"

say_to_wav "The cat sat on the mat. The cat sat on the mat. The cat sat on the mat." "repeat-en.wav"

python3 -c "
import struct, wave
sr = 16000
dur = 3
n = sr * dur
with wave.open('$AUDIO_DIR/silence.wav', 'w') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(struct.pack('<' + 'h' * n, *([0] * n)))
"
echo "Generated: $AUDIO_DIR/silence.wav ($(stat -f%z "$AUDIO_DIR/silence.wav") bytes)"

echo ""
echo "=== Summary ==="
echo ""
echo "Generated automatically:"
echo "  short-en-clean.wav   (~2s, English, clean)"
echo "  medium-en-clean.wav  (~15s, English, clean)"
echo "  long-en-clean.wav    (~60s, English, clean)"
echo "  filler-en.wav        (~5s, English, filler words)"
echo "  repeat-en.wav        (~5s, English, repetition)"
echo "  silence.wav          (~3s, silence)"
echo ""
echo "Requires MANUAL recording:"
echo "  short-ru-clean.wav   (~2s, Russian) — macOS 'say' does not support Russian by default"
echo "  short-en-noisy.wav   (~2s, English, noisy) — requires ambient noise mixing"
echo ""
echo "To record manually, use:"
echo "  ffmpeg -f avfoundation -i ':0' -ar 16000 -ac 1 -sample_fmt s16 -t 2 $AUDIO_DIR/short-ru-clean.wav"
echo "  ffmpeg -f avfoundation -i ':0' -ar 16000 -ac 1 -sample_fmt s16 -t 2 $AUDIO_DIR/short-en-noisy.wav"
echo ""
echo "Alternatively, to mix noise into short-en-clean.wav:"
echo "  ffmpeg -i $AUDIO_DIR/short-en-clean.wav -f lavfi -i 'anoisesrc=d=2:c=pink:r=16000:a=0.1' -filter_complex '[0:a][1:a]amix=inputs=2:duration=first' -ar 16000 -ac 1 -sample_fmt s16 $AUDIO_DIR/short-en-noisy.wav"
