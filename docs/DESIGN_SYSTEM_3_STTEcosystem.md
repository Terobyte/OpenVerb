# 3. STT Ecosystem & Открытые стандарты

**Версия:** 2026-04 · **Статус:** Рабочий документ

---

## Рекомендуемый стек для OpenVerb

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

---

## Ключевые компоненты

### STT движки

| Проект | Язык | Лицензия | Производительность | Платформы |
|--------|------|----------|-------------------|-----------|
| **whisper.cpp** | C/C++ | MIT | 3x+ на Apple Neural Engine | macOS (ANE), CUDA, OpenCL, Metal |
| **sherpa-onnx** | C++ (multi-lang bindings) | Apache 2.0 | Universal ONNX Runtime | Android, iOS, HarmonyOS, NPU, RISC-V |
| **moonshine** | Python/Swift/Kotlin | Apache 2.0 | 5x faster Whisper на edge | iOS, Android, Raspberry Pi, IoT |
| **Parakeet (NeMo)** | Python | Apache 2.0 | GPU-accelerated | NVIDIA-оптимизировано |

### VAD (Voice Activity Detection)

**silero-vad (обязательный компонент):**
- Enterprise-grade VAD
- Pre-trained на 100+ языках
- 1 chunk (30ms) = ~1ms на CPU
- Без телеметрии, без ключей, без регистрации

```python
import silero_vad

model, get_speech_ts = torch.hub.load(...)
speech_timestamps = get_speech_ts(audio, model)
# Получаем временные метки начала/конца речи
```

### Speaker Diarization

**pyannote-audio (для meeting transcription):**
- Лучший open-source diarization
- Neural building blocks: VAD, speaker change, overlapped speech
- #1 на всех diarization бенчмарках

---

## Открытые приложения для изучения

| Проект | Что взять | Релевантность |
|--------|-----------|---------------|
| **OpenWhispr** | Архитектура BYOK + автовставка текста cross-platform | High |
| **VoiceInk** | Swift/macOS интеграция с Whisper.cpp, UX паттерны | High (macOS) |
| **Handy** | Минималистичный UX, cross-platform text injection | High |
| **Vocalinux** | Linux Wayland/X11 вставка через XDG Portal | Medium (Linux) |

---

## Бенчмарки (2026)

**Top STT моделей по WER (Word Error Rate):**

| Модель | WER | Языков | Размер |
|--------|-----|--------|--------|
| NVIDIA Canary Qwen 2.5B | 5.63% | 25 | 2.5B params |
| NVIDIA Canary 1B v2 | 6.67% | 25 | 1.0B params |
| Whisper Large-v3 | 7.88% | 99 | 1.5B params |

**Whisper sizes:**
| Размер | Параметры | Скорость |
|--------|-----------|----------|
| tiny | 39M | ~32x realtime |
| base | 74M | ~16x realtime |
| small | 244M | ~6x realtime |
| medium | 769M | ~2x realtime |
| large-v3 | 1.5B | ~1x realtime |

---

## Implementation Checklist

### UI Library
- [ ] MinimalWaveformView (RMS visualization, 30-bar ring buffer)
- [ ] RecordingTimerView (MM:SS, monospaced)
- [ ] RecordingStatusIndicator (IDLE/RECORDING/PROCESSING/COMPLETE/ERROR)
- [ ] RecordingLoadingIndicator (progress bar, animated)
- [ ] RecordingUIViewModel (state management, timer logic)
- [ ] RecordingUIKit (assembly, layout)

### Design System
- [ ] Adaptive Glass (blur + opacity dynamically)
- [ ] Claymorphism colors & shadows
- [ ] WCAG 2.2 contrast ratios (APCA algorithm)
- [ ] Dark mode support via system colors
- [ ] Motion accessibility (respectReduceMotion)

### STT Integration
- [ ] whisper.cpp bindings for speech recognition
- [ ] silero-vad for voice activity detection
- [ ] Audio session integration (PCM → RMS amplitude)
- [ ] Real-time streaming (50-100ms updates)

---

**Документ актуален на:** 2026-04-16
