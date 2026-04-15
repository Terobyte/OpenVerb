# Recording UI Library — Минималистичный Premium Design

## Обзор

Библиотека для красивого, минималистичного UI записи микрофона в OpenVerb. Включает:
- **Визуализация волны** (реал-тайм амплитуда)
- **Таймер** (MM:SS формат)
- **Статус индикатор** (Готово/Запись/Обработка)
- **Индикатор загрузки** (при обработке)

Все компоненты — модульные, переиспользуемые, с плавными анимациями.

---

## Архитектура компонентов

### 1. RecordingUIKit (Main Container)
**Назначение:** Главный контейнер, объединяющий все элементы UI.

**Ответственность:**
- Layout всех компонентов
- Background/shadow/corner radius
- Координирование состояния между элементами

**Вход:** `@ObservedObject viewModel: RecordingUIViewModel`

**Структура вывода:**
```
┌─ Padding(20) ─────────────────────────┐
│ ┌─ MinimalWaveformView ──────────────┐ │
│ │ Высота: 60pt                        │ │
│ │ Визуализирует amplitudes[]          │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ ┌─ HStack(spacing: 12) ──────────────┐ │
│ │ [StatusIndicator] [Timer] [Spacer] │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ ┌─ LoadingIndicator (if isProcessing)─┐ │
│ │ Transition: opacity                 │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

---

### 2. MinimalWaveformView
**Назначение:** Визуализация амплитуды звука в реал-тайме.

**Дизайн принципы:**
- Минимализм: максимум 30 полос
- Гладкие анимации: `duration: 0.08s`
- Градиент сверху вниз (основной цвет → 70% opacity)
- Rounded corners (radius: 1.5pt) для мягкости

**Вход:**
```swift
let amplitudes: [CGFloat]  // 0.0...1.0, max 30 items
```

**Поведение:**
- Каждая полоса анимируется независимо
- При добавлении новой амплитуды, старые сдвигаются влево
- Ring buffer: если > 30 полос, первая удаляется

**Анимация:**
```
.animation(.easeInOut(duration: 0.08), value: amplitudes)
```

---

### 3. RecordingTimerView
**Назначение:** Показать прошедшее время в формате MM:SS.

**Дизайн:**
- Monospaced шрифт для стабильности
- Иконка `clock.fill` (12pt, semibold, secondary цвет)
- Текст: 14pt, semibold, monospaced

**Формат времени:**
```
elapsedSeconds: 0 → "00:00"
elapsedSeconds: 65 → "01:05"
elapsedSeconds: 125 → "02:05"
```

**Логика:**
```swift
minutes = elapsedSeconds / 60
seconds = elapsedSeconds % 60
format = String(format: "%02d:%02d", minutes, seconds)
```

---

### 4. RecordingStatusIndicator
**Назначение:** Показать текущий статус записи с визуальным фидбэком.

**Статусы:**

| Status | Текст | Цвет | Анимация |
|--------|-------|------|----------|
| `.idle` | "Готово" | Gray | Статик |
| `.recording` | "Запись" | Red | Пульс 0.8s |
| `.processing` | "Обработка" | Orange | Пульс 0.8s |
| `.complete` | "Готово" | Green | Статик |
| `.error` | "Ошибка" | Red | Статик |

**Визуальная часть:**
- Круглая точка (8×8pt)
- Для recording/processing: пульсирующая (opacity: 1.0 → 0.3)
- Текст: 12pt, medium

**Пульс анимация:**
```swift
.easeInOut(duration: 0.8).repeatForever()
```

---

### 5. RecordingLoadingIndicator
**Назначение:** Показать, что идет обработка (inferencing).

**Компоненты:**
1. **Progress bar** — линейный, анимирующийся слева направо
   - Фон: gray 0.2 opacity
   - Прогресс: gradient (accent → 60% opacity)
   - Height: 4pt
   - Corner radius: 2pt

2. **Текст** — "Обработка..."
   - 12pt, regular, secondary цвет

**Анимация:**
- Width растет: 0 → geometry.width
- Duration: 1.5s
- Repeat forever

```swift
.animation(.easeInOut(duration: 1.5).repeatForever(), value: isAnimating)
```

---

### 6. RecordingUIViewModel
**Назначение:** State management для всех компонентов.

**@Published свойства:**
```swift
@Published var amplitudes: [CGFloat] = []
@Published var elapsedSeconds: Int = 0
@Published var status: RecordingStatusIndicator.Status = .idle
@Published var isProcessing: Bool = false
```

**Методы управления:**

```swift
// Начать запись
func startRecording()
  - status = .recording
  - elapsedSeconds = 0
  - amplitudes.removeAll()
  - запустить таймер

// Остановить запись (перейти в обработку)
func stopRecording()
  - status = .processing
  - isProcessing = true
  - остановить таймер

// Завершить обработку
func finishProcessing()
  - isProcessing = false
  - status = .complete

// Сбросить состояние
func reset()
  - status = .idle
  - elapsedSeconds = 0
  - amplitudes.removeAll()
  - isProcessing = false

// Обновить амплитуду (из AudioSession)
func updateAmplitude(_ amplitude: CGFloat)
  - Добавить в amplitudes[]
  - Если > 30: removeFirst()

// Ошибка
func setError()
  - status = .error
  - остановить таймер
```

**Таймер логика:**
- `Timer.publish(every: 1.0)` — каждую секунду
- Увеличивает `elapsedSeconds += 1`
- Используется `AnyCancellable` для cleanup

---

## Принципы дизайна

### Минимализм
- Только необходимые элементы
- Чистые линии (border radius: 2-12pt)
- Использование негативного пространства (padding: 20pt)

### Анимация
- Все анимации < 300ms (UX standard)
- `easeInOut` для естественного движения
- Пульсирующие элементы для привлечения внимания (recording status)
- Плавные переходы между состояниями

### Цвета
- Системные цвета (`.controlAccentColor`, `.controlBackgroundColor`)
- Автоматическая поддержка light/dark mode
- Градиенты для depth

### Типография
- Monospaced для таймера (стабильность ширины)
- System fonts (San Francisco)
- Sizes: 12pt (labels), 14pt (main), 20pt (emphasis)

---

## Интеграция с AudioSession

**Поток данных:**

```
AudioSession (captures audio)
    ↓
PCM Data (Int16 chunks)
    ↓
computeRMS() → CGFloat amplitude [0.0...1.0]
    ↓
viewModel.updateAmplitude(amplitude)
    ↓
@Published amplitudes[] изменяется
    ↓
MinimalWaveformView переанимируется
```

**Требование:** AudioSession должна вызывать:
```swift
recordingUIViewModel.updateAmplitude(rmsValue)
```

Желательно на каждые 50-100ms для smooth animation.

---

## Жизненный цикл состояния

```
┌─────────────────────────────────────┐
│          IDLE                       │
│  (статус: "Готово", таймер: 00:00) │
└────────────┬────────────────────────┘
             │ startRecording()
             ↓
┌─────────────────────────────────────┐
│       RECORDING                     │
│  (статус: "Запись" пульс,           │
│   таймер: 00:01, 00:02, ...)        │
└────────────┬────────────────────────┘
             │ stopRecording()
             ↓
┌─────────────────────────────────────┐
│       PROCESSING                    │
│  (статус: "Обработка" пульс,        │
│   loading bar анимируется)          │
└────────────┬────────────────────────┘
             │ finishProcessing()
             ↓
┌─────────────────────────────────────┐
│       COMPLETE                      │
│  (статус: "Готово", зеленый)        │
└────────────┬────────────────────────┘
             │ reset()
             ↓
          [IDLE]
```

---

## Usage Example

```swift
// В главном контроллере:
@StateObject var recordingUI = RecordingUIViewModel()

var body: some View {
    VStack {
        RecordingUIKit(viewModel: recordingUI)
            .frame(maxWidth: 400)
            .padding()
    }
    .onAppear {
        // Пример: начать запись
        recordingUI.startRecording()
    }
}

// Из AudioSession:
func audioTapCallback(buffer: AVAudioPCMBuffer) {
    let rms = computeRMS(buffer)
    recordingUI.updateAmplitude(rms)  // ← вызывать часто
}

// По окончании записи:
recordingUI.stopRecording()  // → PROCESSING

// После обработки (когда сервер ответил):
recordingUI.finishProcessing()  // → COMPLETE
```

---

## Размеры и макет

```
Основной контейнер: 340×120pt (including shadow padding)
─────────────────────────────────────

Padding: 20pt (all sides)

Волна: 60pt height, max-width

Таймер + Статус: 14pt height

Загрузка: 40pt height (когда видна)

Gap между элементами: 16pt

Rounded corners: 12pt (контейнер)
```

---

## Тестирование (Preview)

Должны быть preview'ы для каждого состояния:
1. IDLE (initial)
2. RECORDING (с волной, идет запись)
3. PROCESSING (с loading bar)
4. COMPLETE (статус зеленый)
5. ERROR (статус красный)

---

## Производительность

- **Amplitude update frequency:** 50-100ms (20-10 updates/sec)
- **Animation frames:** 60 fps (system manages)
- **Memory:** Ring buffer max 30 items (~240 bytes)
- **CPU:** Minimal (native SwiftUI animations)

---

## Фазы реализации

1. **MinimalWaveformView** — Core visualization
2. **RecordingTimerView** — Timer logic
3. **RecordingStatusIndicator** — Status rendering
4. **RecordingLoadingIndicator** — Loading state
5. **RecordingUIViewModel** — State management
6. **RecordingUIKit** — Container assembly
7. **Integration** — Hook into AudioSession

---

## Заметки

- Используется `@MainActor` для thread-safety
- `AnyCancellable` для cleanup таймера
- System colors для автоматической темы
- Gradients для visual polish
- Все значения жестко кодированы (можно параметризировать позже)
