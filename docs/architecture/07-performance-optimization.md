# Инженерные оптимизации и фоновые процессы

## Детекция голосовой активности (Voice Activity Detection, VAD)

### Назначение

**До STT-обработки** система должна отделить:
- Значимую речь пользователя
- Фоновый шум (гул вентилятора, стук клавиатуры, уличные звуки)

**Без VAD:**
- Отправка "пустых" аудиофайлов на облачные серверы
- Бесполезная трата API квот
- Перегрузка локального процессора

### Технология: Silero VAD

**Особенности:**
- Микромодель (< 1MB)
- Очень быстрая (работает в реальном времени)
- Высокая точность (95%+)
- Работает на локальном устройстве (приватность)

### Процесс работы

```
Audio Stream (16kHz, 16-bit)
        ↓
[Silero VAD Model]
        ↓
   ┌────┴────┐
   ↓         ↓
 Speech    Silence
   ↓         ↓
Buffer &   Discard
Send to
STT
```

### Математика детекции

```python
def detect_voice_activity(audio_chunk):
  # Вычислить энергию в частотных полосах
  power_spectrum = compute_fft(audio_chunk)

  # Проверить характеристики речи
  checks = {
    'energy': power_in_speech_range > THRESHOLD,
    'pitch': has_fundamental_frequency(),
    'mfcc': mel_frequency_matches_voice(),
    'duration': chunk_duration > MIN_VOICE_DURATION
  }

  # Вероятность, что это речь
  probability = model.predict(features)

  return probability > 0.5  # True = Voice detected
```

### Параметры настройки

```json
{
  "vad": {
    "sensitivity": 0.5,          // 0.0 (строгий) - 1.0 (мягкий)
    "minDuration": 200,          // мс, минимальная длина речи
    "silenceThreshold": 500,     // мс, длина паузы до конца
    "energyThreshold": -40,      // dB, минимальная амплитуда
    "noiseFloor": -60            // dB, порог для фонового шума
  }
}
```

## Динамическая нормализация уровня микрофона

### Проблема

```
Пользователь близко к микрофону: [-10dB] (очень громко)
↓ STT модель обучена на среднем уровне [-20dB]
↓ Результат: ошибки распознавания

Пользователь далеко: [-50dB] (очень тихо)
↓ Спектрограмма не видна
↓ Результат: потеря звука
```

### Решение: Automatic Gain Control (AGC)

```javascript
function normalizeAudio(audioBuffer) {
  // 1. Вычислить RMS (Root Mean Square) энергию
  const rms = computeRMS(audioBuffer);

  // 2. Целевой уровень (оптимум для STT)
  const targetRMS = -20;  // dB

  // 3. Вычислить коэффициент усиления
  const gainFactor = 10 ** ((targetRMS - rms) / 20);

  // 4. Применить с мягким лимитом (не клипировать)
  const normalized = audioBuffer.map(sample => {
    const amplified = sample * gainFactor;
    // Soft limiter (тан-гиперболический)
    return Math.tanh(amplified);
  });

  return normalized;
}
```

### Результат

```
До:  [-10dB] → [-50dB] → [Тихая диктовка]
После: [-10dB] → [-20dB (нормализовано)] → [Четкая диктовка]
```

## Управление памятью и ресурсами

### Проблема

LLM модели занимают огромный объем памяти:
- Whisper Large: 3GB
- Llama 2 70B: 140GB (квантизованная: 40GB)
- GPT-style локальные: 8–16GB

**Без управления**: система зависает после 5–10 диктовок.

### Решение 1: Модели разного размера

```json
{
  "models": {
    "nano": {
      "size": "50MB",
      "speed": "fast",
      "accuracy": 80,
      "vram": "512MB",
      "useCase": "realtime"
    },
    "base": {
      "size": "140MB",
      "speed": "medium",
      "accuracy": 90,
      "vram": "2GB",
      "useCase": "default"
    },
    "large": {
      "size": "3GB",
      "speed": "slow",
      "accuracy": 98,
      "vram": "8GB",
      "useCase": "offline, high-accuracy"
    }
  }
}
```

**Автоматический выбор:** система выбирает модель на основе доступной памяти и требований точности.

### Решение 2: Выгрузка моделей из памяти

```python
class ModelManager:
  def __init__(self):
    self.active_model = None
    self.model_cache = {}
    self.last_used_time = {}

  def unload_idle_models(self):
    """Выгрузить модели, которые не использовались > 5 минут"""
    current_time = time.time()

    for model_name, last_time in self.last_used_time.items():
      if current_time - last_time > 300:  # 5 minutes
        del self.model_cache[model_name]
        print(f"Unloaded {model_name} - freed 2GB RAM")

  def load_model(self, model_name):
    if model_name in self.model_cache:
      return self.model_cache[model_name]

    # Выгрузить другие модели если памяти мало
    if get_available_vram() < 3000:  # MB
      self.unload_idle_models()

    model = load_from_disk(model_name)
    self.model_cache[model_name] = model
    self.last_used_time[model_name] = time.time()

    return model
```

**Конфигурация:**

```json
{
  "memoryManagement": {
    "voiceModelActiveDuration": 300000,  // мс = 5 минут
    "autoUnloadThreshold": 3000,         // МБ доступной VRAM
    "maxCachedModels": 2                 // максимум 2 модели в памяти
  }
}
```

## Фильтрация слов-паразитов

### Проблема

Люди произносят сложные слова, которые не добавляют смысл:
```
Пользователь говорит: "Um, the, uh, project requires, like, three modules, you know?"
Должно быть: "The project requires three modules."
```

### Решение: семантическая фильтрация

```python
def remove_filler_words(transcription):
  filler_patterns = {
    'en': ['um', 'uh', 'like', 'you know', 'basically', 'literally', 'actually'],
    'ru': ['э', 'ммм', 'ну', 'типа', 'вот', 'как бы', 'на самом деле'],
    'ja': ['あの', 'えっと', 'その', 'まあ']
  }

  # NLP анализ: оставить только значимые токены
  tokens = nlp.tokenize(transcription)

  meaningful_tokens = [
    token for token in tokens
    if not is_filler(token, detected_language)
  ]

  return ' '.join(meaningful_tokens)

# До: "Um, the, uh, project requires, like, three modules, you know?"
# LLM (семантика + фильтрация):
# После: "The project requires three modules."
```

### Конфиденция фильтрации

```json
{
  "fillerWordRemoval": {
    "enabled": true,
    "languages": ["en", "ru"],
    "threshold": 0.95,  // Точность фильтрации
    "preserveEmphasis": true  // Сохранить "actually" если выделено
  }
}
```

## Мультиязычность и код-свитчинг

### Автоматическое определение языка

```python
def detect_language_and_process(audio):
  # Вычислить языковые признаки
  language_scores = {}

  for lang in ['en', 'ru', 'es', 'fr', 'de', 'ja']:
    model = load_language_model(lang)
    confidence = model.predict_confidence(audio)
    language_scores[lang] = confidence

  detected_lang = max(language_scores, key=language_scores.get)
  confidence = language_scores[detected_lang]

  if confidence < 0.7:
    # Низкая уверенность — вероятно, смешанный язык
    return detect_code_switching(audio)

  return detected_lang

# Результат: "ru" с confidence 0.92
```

### Код-свитчинг (смешанный язык)

```
Пользователь говорит (на русском):
"The API endpoint находится в config.json"

Языки:
- "The API endpoint" (английский)
- "находится в" (русский)
- "config.json" (английский)

LLM понимает и правильно обрабатывает оба языка
Результат: "The API endpoint находится в config.json"
```

### Локализация STT-моделей

```json
{
  "languages": {
    "en": {
      "model": "whisper_english",
      "vocabulary": 30000,
      "trainingData": "LibriSpeech"
    },
    "ru": {
      "model": "whisper_russian",
      "vocabulary": 50000,
      "trainingData": "Russian Speech Corpus + Yandex"
    },
    "ja": {
      "model": "whisper_japanese",
      "vocabulary": 10000,
      "trainingData": "JSUT Corpus"
    }
  }
}
```

## Потоковая обработка vs Батч-обработка

### Потоковая (Real-time, Streaming)

```
Audio chunks: [chunk1] → STT → Interim1
              [chunk2] → STT → Interim2
              [chunk3] → STT → Final1
              [chunk4] → STT → Interim3
              [chunk5] → STT → Final2
```

**Плюсы:**
- Минимальная задержка
- Мгновенная визуальная обратная связь

**Минусы:**
- Выше требования к ресурсам
- Нестабильные промежуточные результаты

### Батч-обработка (One-shot)

```
Запись: [===== audio chunk =====]
        (Записать полностью)
        ↓
STT: (Обработать целиком)
        ↓
Final Result (Один результат)
```

**Плюсы:**
- Ниже требования к ресурсам
- Выше точность (контекст всей фразы)

**Минусы:**
- Задержка после остановки записи (500–1000мс)
- Нет промежуточной обратной связи

### Адаптивный выбор

```python
def choose_processing_mode():
  device_vram = get_available_vram()  # МБ
  processor = detect_processor()       # CPU, GPU

  if device_vram > 8000 and processor == 'GPU':
    return 'streaming'  # Хороший железо → поток

  elif device_vram > 2000:
    return 'streaming'  # Старое железо → тоже поток

  else:
    return 'batch'  # Очень слабое → батч
```

## Сетевая оптимизация для облачных моделей

### Сжатие аудио перед отправкой

```python
def compress_audio_for_transmission(audio_buffer):
  # Исходный размер: 16kHz * 16-bit * 10 сек = 320 KB
  # После сжатия: ~32 KB (10x меньше)

  # Использовать формат Opus (лучший для речи)
  compressed = encode_opus(audio_buffer, bitrate='12kbps')

  return compressed  # 32 KB вместо 320 KB
```

### Кэширование результатов на устройстве

```python
class ResponseCache:
  def __init__(self):
    self.cache = {}

  def get_cached(self, audio_fingerprint):
    """Вернуть результат если аналогичное было"""
    if audio_fingerprint in self.cache:
      return self.cache[audio_fingerprint]
    return None

  def cache_response(self, fingerprint, result):
    """Сохранить результат локально"""
    self.cache[fingerprint] = result

# Пример:
# Пользователь часто говорит "send calendar link"
# Первый раз → отправить в облако → кэш
# Второй раз → вернуть из кэша мгновенно
```

### Параллельная обработка

```
┌─ Stream 1: STT (локально)
│ └─ Промежуточные результаты мгновенно
│
├─ Stream 2: LLM (облачная, параллельно)
│ └─ Обрабатывает первые промежуточные результаты
│
└─ Stream 3: UI Rendering
  └─ Отображает результаты обоих потоков

Результат: LLM готов почти когда заканчивается STT!
```

## Метрики и мониторинг

### Критические метрики

```json
{
  "metrics": {
    "latency": {
      "mic_to_interim": "< 200ms",
      "mic_to_final": "< 1000ms",
      "final_to_injection": "< 500ms",
      "total_end_to_end": "< 2000ms"
    },
    "accuracy": {
      "wer": "< 5%",              // Word Error Rate
      "cer": "< 2%",              // Character Error Rate
      "contextual_match": "> 95%"  // Правильная адаптация
    },
    "resource": {
      "memory_peak": "< 4GB",
      "cpu_usage": "< 50%",
      "gpu_vram": "< 2GB"
    }
  }
}
```

### Логирование и анализ

```python
def log_performance_metrics(session):
  metrics = {
    'timestamp': datetime.now(),
    'audio_duration': session.duration_ms,
    'latency_interim': session.time_to_interim,
    'latency_final': session.time_to_final,
    'wer': compute_wer(session.transcription, session.reference),
    'memory_used': get_process_memory(),
    'context_applied': session.context_type
  }

  # Отправить в систему аналитики
  analytics.log(metrics)

  # Если аномалия — вызвать оптимизацию
  if metrics['latency_final'] > 2000:
    optimizer.suggest_improvements()
```
