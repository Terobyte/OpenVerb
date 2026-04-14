#!/usr/bin/env python3
"""
WER (Word Error Rate) calculator using Levenshtein distance.
  WER = (S + D + I) / N
  S = substitutions, D = deletions, I = insertions, N = reference word count

Usage:
  python3 wer.py <reference> <hypothesis>     -> prints WER as decimal
"""
import sys
import re


def normalize(text: str) -> list:
    """Lowercase, strip punctuation, split into words."""
    text = text.lower()
    text = re.sub(r"[^\w\s']", " ", text)
    return text.split()


def wer(ref_text: str, hyp_text: str) -> float:
    ref = normalize(ref_text)
    hyp = normalize(hyp_text)
    if not ref:
        return 0.0 if not hyp else 1.0
    n, m = len(ref), len(hyp)
    # Rolling-array Levenshtein — O(m) space
    d = list(range(m + 1))
    for i in range(1, n + 1):
        prev = d[:]
        d[0] = i
        for j in range(1, m + 1):
            if ref[i - 1] == hyp[j - 1]:
                d[j] = prev[j - 1]
            else:
                d[j] = 1 + min(prev[j - 1], prev[j], d[j - 1])
    return d[m] / n


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <reference> <hypothesis>", file=sys.stderr)
        sys.exit(1)
    score = wer(sys.argv[1], sys.argv[2])
    print(f"{score:.4f}")
