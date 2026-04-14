# GitHub Findings — STT Ecosystem Research
> Дата исследования: 2026-04-13 · Цель: собрать лучшие open-source решения для OpenVerb

---

## Навигация

1. [STT Движки и Модели](#1-stt-движки-и-модели)
2. [Desktop STT Приложения](#2-desktop-stt-приложения)
3. [Real-time Стриминг](#3-real-time-стриминг)
4. [VAD и Diarization](#4-vad-и-diarization)
5. [Бенчмарки и Лидерборды](#5-бенчмарки-и-лидерборды)
6. [Выводы для OpenVerb](#6-выводы-для-openverb)

---

## 1. STT Движки и Модели

### 🥇 openai/whisper
**⭐ ~75k stars** · Python · MIT
https://github.com/openai/whisper

Эталонная реализация. Обучена на 680k часов аудио (Large-v3 — на 5M часов).
Поддерживает 99 языков. WER на чистом аудио: **2.7%**.

| Размер | Параметры | Относительная скорость |
|--------|-----------|------------------------|
| tiny   | 39M       | ~32x realtime          |
| base   | 74M       | ~16x realtime          |
| small  | 244M      | ~6x realtime           |
| medium | 769M      | ~2x realtime           |
| large-v3 | 1.5B   | ~1x realtime           |

**Для OpenVerb**: эталон точности, но медленная Python-реализация. Используем как baseline для тестов.

---

### 🥇 ggml-org/whisper.cpp
**⭐ ~40k stars** · C/C++ · MIT
https://github.com/ggml-org/whisper.cpp

Порт Whisper на C/C++ через GGML. Нулевые зависимости.
**Core ML** на Apple Neural Engine: **3x+ быстрее** CPU.
Встроенный VAD, real-time stream через SDL2.

**Ключевые возможности:**
- Работает полностью offline, нет Python-оверхеда
- Поддержка: macOS (ANE), CUDA (GPU), OpenCL, Metal
- Bindings: Python, Go, Rust, Node.js, Swift, Java, C#
- Встроенный `stream` example с микрофоном в real-time

**Для OpenVerb**: **основной кандидат** для нативного STT-ядра. Дает sub-200ms latency.

---

### 🥈 SYSTRAN/faster-whisper
**⭐ ~14k stars** · Python · MIT
https://github.com/SYSTRAN/faster-whisper

Reimplementation через CTranslate2. **4x быстрее** оригинала при том же WER.
8-bit квантизация на CPU и GPU.

**Для OpenVerb**: лучший Python-вариант если нужен Python-стек. Batch inference для обработки файлов.

---

### 🥈 m-bain/whisperX
**⭐ ~21k stars** · Python · BSD-4
https://github.com/m-bain/whisperX

Расширение Whisper с **word-level timestamps** и speaker diarization.
70x realtime с large-v2 через батч-инференс.

**Добавляет к Whisper:**
- Выравнивание по словам через wav2vec2
- Speaker diarization через pyannote-audio
- Улучшенные временны́е метки (исправляет неточность оригинала)

**Для OpenVerb**: незаменим для meeting transcription и транскриптов с временными метками.

---

### 🥉 huggingface/distil-whisper
**⭐ ~5k stars** · Python · MIT
https://github.com/huggingface/distil-whisper

Дистиллированный Whisper: **6x быстрее**, на **49% меньше**, WER в пределах 1% от оригинала.
⚠️ **Только английский язык.**

**Для OpenVerb**: быстрый вариант для English-only режима.

---

### 🌟 moonshine-ai/moonshine
**⭐ ~4k stars** · Python/Swift/Kotlin · Apache-2.0
https://github.com/moonshine-ai/moonshine

Разработан с нуля специально для edge-устройств.
**5x быстрее Whisper** на 10-секундных сегментах. Модели от **26MB** (tiny) до нескольких сотен MB.

**Платформы**: Python, iOS, Android, macOS, Linux, Windows, Raspberry Pi, IoT, носимые устройства.
**Языки**: English, Spanish, Mandarin, Japanese, Korean, Vietnamese, Ukrainian, Arabic.

**Для OpenVerb**: **лучший выбор для мобильной версии** и edge-деплоя. Нативные iOS/Android биндинги.

---

### 🌟 k2-fsa/sherpa-onnx
**⭐ ~4k stars** · C++/Multi-language · Apache-2.0
https://github.com/k2-fsa/sherpa-onnx

**Самый универсальный cross-platform runtime.** ONNX Runtime без интернета.
Поддерживает: STT, TTS, speaker diarization, VAD, speech enhancement.

**Платформы**: Android, iOS, HarmonyOS, Raspberry Pi, RISC-V, NPU (RK/Axera/Ascend), x86.
**Языки программирования**: Python, Swift, Kotlin, JavaScript, Go, Rust, C#, C/C++, Dart, Pascal, .NET.
**Модели**: Whisper, Parakeet, Zipformer, Conformer, Paraformer, Moonshine и другие.

**Для OpenVerb**: **стратегический выбор** для cross-platform ядра. Единственный проект с такой матрицей платформ × языков.

---

### 🌟 NVIDIA-NeMo/NeMo — Parakeet & Canary
**⭐ ~14k stars** · Python · Apache-2.0
https://github.com/NVIDIA-NeMo/NeMo

**Parakeet** — NVIDIA's флагманская ASR-модель. FastConformer + TDT decoder.
- `parakeet-tdt-0.6b-v3` — 0.6B параметров, английский
- `parakeet-rnnt-1.1b` — 1.1B, выше точность

**Canary** — многоязычный флагман (25 европейских языков + перевод):
- `Canary Qwen 2.5B` — **WER 5.63%**, #1 на HF Open ASR Leaderboard

**Для OpenVerb**: Parakeet — кандидат на замену Whisper Large для English-only режима (быстрее + точнее на GPU).

---

## 2. Desktop STT Приложения

### Beingpax/VoiceInk
**⭐ ~4.3k stars** · Swift · GPL-3.0
https://github.com/Beingpax/VoiceInk

Нативный macOS диктовщик, открыт исходный код (ранее был закрытым).
100% offline, Apple Silicon только. Whisper on-device.

**Ограничения**: macOS + Apple Silicon. Intel Mac, Windows, Linux — не поддерживаются.
**Цена бинарника**: $39.99 (из исходника — бесплатно через Xcode).

**Для OpenVerb**: изучить UX и архитектуру Swift-интеграции с Whisper.cpp.

---

### OpenWhispr/openwhispr
**⭐ ~активный** · TypeScript/Electron · MIT
https://github.com/OpenWhispr/openwhispr

Cross-platform (macOS, Windows, Linux) диктовщик.
BYOK (Bring Your Own Key) + local Parakeet через sherpa-onnx.

**Функции:**
- Global hotkey (backtick по умолчанию) + автовставка текста в курсор
- Локальный Whisper + Parakeet (25 языков) через sherpa-onnx
- Cloud BYOK: OpenAI, Anthropic, Gemini, Groq, Mistral
- Agent Mode с chat overlay
- Google Calendar интеграция

**Для OpenVerb**: **ближайший open-source конкурент**. Изучить архитектуру автовставки текста.

---

### cjpais/Handy
**⭐ ~1.5k stars** · TypeScript · MIT
https://github.com/cjpais/Handy

Простой cross-platform (macOS, Windows, Linux) оффлайн-диктовщик.
Нажимаешь хоткей → говоришь → текст вставляется в любое поле.
100% локально, данные не покидают устройство.

**Для OpenVerb**: пример минималистичного UX, изучить как реализована вставка текста на Linux/Windows.

---

### jatinkrmalik/vocalinux
**⭐ ~1k stars** · Python · GPL-3.0
https://github.com/jatinkrmalik/vocalinux

Linux-специфичный диктовщик. X11 + Wayland.
Движки: whisper.cpp, OpenAI Whisper, VOSK. GPU via Vulkan.

**Для OpenVerb**: изучить реализацию вставки текста через XDG Remote Desktop Portal (Wayland).

---

### y0sif/whisrs
**⭐ небольшой** · Rust · MIT
https://github.com/y0sif/whisrs

Linux-first диктовщик на Rust. Wayland/X11/Hyprland/Sway.
**Для OpenVerb**: если нужен Rust-компонент для Linux системного слоя.

---

### OlivierMary/MySuperWhisper
**⭐ небольшой** · Python · MIT
https://github.com/OlivierMary/MySuperWhisper

"Superwhisper для Linux" — global hotkey dictation через whisper.cpp.
Работает на Wayland/X11.

---

## 3. Real-time Стриминг

### KoljaB/RealtimeSTT
**⭐ ~3k stars** · Python · MIT
https://github.com/KoljaB/RealtimeSTT

Python-библиотека для real-time STT с низкой latency.
VAD (Silero), wake word активация, instant transcription.
Поддерживает все размеры Whisper. Простой Python API.

```python
from RealtimeSTT import AudioToTextRecorder
recorder = AudioToTextRecorder()
print(recorder.text())
```

**Для OpenVerb**: готовый Python-компонент для быстрого прототипирования real-time транскрипции.

---

### collabora/WhisperLive
**⭐ ~3k stars** · Python · MIT
https://github.com/collabora/WhisperLive

Nearly-live Whisper через WebSocket-сервер.
Browser extensions (Chrome/Firefox), нативный iOS клиент.

**Для OpenVerb**: архитектурный референс для client-server подхода.

---

### shashikg/WhisperS2T
**⭐ ~1k stars** · Python · MIT
https://github.com/shashikg/WhisperS2T

Оптимизированный pipeline для Whisper. Поддерживает multiple inference engines.
Быстрее faster-whisper для batch сценариев.

---

## 4. VAD и Diarization

### snakers4/silero-vad
**⭐ ~5k stars** · Python/ONNX · MIT
https://github.com/snakers4/silero-vad

**Enterprise-grade VAD.** Pre-trained на 100+ языках.
1 chunk (30ms) = ~1ms на одном CPU потоке.
Без телеметрии, без ключей, без регистрации.

**Для OpenVerb**: **обязательный компонент** для точного определения начала/конца речи.

---

### pyannote/pyannote-audio
**⭐ ~8k followers, 140k users** · Python · MIT
https://github.com/pyannote/pyannote-audio

Лучший open-source speaker diarization. neural building blocks:
VAD, speaker change detection, overlapped speech detection, speaker embedding.
**community-1** модель — #1 на всех diarization бенчмарках.

**Для OpenVerb**: для функции "кто говорит" в meeting transcription.

---

## 5. Бенчмарки и Лидерборды

### huggingface/open_asr_leaderboard
https://github.com/huggingface/open_asr_leaderboard

Открытый ASR Leaderboard от HuggingFace. Воспроизводимые бенчмарки.

**Топ-3 по WER (2026):**
| Модель | WER | Языков |
|--------|-----|--------|
| NVIDIA Canary Qwen 2.5B | 5.63% | 25 |
| NVIDIA Canary 1B v2 | 6.67% | 25 |
| Whisper Large-v3 | 7.88% | 99 |

---

### sindresorhus/awesome-whisper
https://github.com/sindresorhus/awesome-whisper

Curated list всех Whisper-based проектов. Хороший реестр для отслеживания экосистемы.

---

## 6. Выводы для OpenVerb

### Рекомендуемый стек

```
┌─────────────────────────────────────────────────────┐
│  УРОВЕНЬ          РЕКОМЕНДАЦИЯ           АЛЬТЕРНАТИВА│
├─────────────────────────────────────────────────────┤
│  STT ядро         whisper.cpp (C++)      sherpa-onnx │
│  STT модель       Whisper large-v3       Moonshine   │
│  VAD              silero-vad             встроенный  │
│  Real-time API    RealtimeSTT (Python)   WhisperLive │
│  Speaker ID       pyannote-audio         —           │
│  Edge/Mobile      moonshine-ai/moonshine sherpa-onnx │
│  Cross-platform   sherpa-onnx runtime    whisper.cpp │
└─────────────────────────────────────────────────────┘
```

### Что изучить из open-source приложений

| Проект | Что взять |
|--------|-----------|
| **OpenWhispr** | Архитектура BYOK + автовставка текста cross-platform |
| **VoiceInk** | Swift/macOS интеграция с Whisper, UX паттерны |
| **Handy** | Минималистичный UX, cross-platform text injection |
| **Vocalinux** | Linux Wayland/X11 вставка через XDG Portal |

### Ниши, не закрытые ни одним проектом

- ✅ Superwhisper: контроль + приватность, но **Mac-only**
- ✅ OpenWhispr: cross-platform, но **Electron** (тяжёлый)
- ✅ VoiceInk: нативный macOS, но **Apple Silicon only**
- ❌ **Нет нативного кроссплатформенного приложения** (не Electron) с:
  - Полным контролем над промптингом
  - Локальной + облачной опцией
  - Linux + Windows + macOS + iOS + Android
  - Open-source без vendor lock-in

**→ Это и есть ниша OpenVerb.**

---

*Исследование проведено: 2026-04-13*
*Следующий шаг: выбрать STT ядро и написать architecture decision record*
