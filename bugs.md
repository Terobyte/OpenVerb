# OpenVerb Bug Tracker

Sorted by severity: crashes and data loss first, cosmetic and test gaps last.
`[tested]` = failing red test exists. Green = bug fixed.

---

## Medium — real bugs with narrower trigger conditions

**Bug 102** [tested] — Surrogate-pair split: UTF-16 cursor offset can bisect an emoji grapheme cluster
`AccessibilityReader.swift:139–148` — `NSString.substring(to: cursorPos)` at a UTF-16 offset inside a surrogate pair produces a lone surrogate → corrupt UTF-8 passed as context to the engine.

---

## Deferred

_(none)_
