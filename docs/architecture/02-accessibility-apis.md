# Системная интеграция через Accessibility APIs

## Концепция: реверс-инжиниринг для AI

Историческая справка: Accessibility APIs разрабатывались для **программ экранного доступа** (screen readers):
- NVDA, JAWS, VoiceOver
- Помощь пользователям с нарушениями зрения

**Современное использование**: AI-диктовочные приложения "перехватили" эту архитектуру для собственных нужд, читая дерево доступности (Accessibility Tree).

## macOS: Carbon Accessibility API (AXAPI)

### Процесс перехвата контекста

#### Этап 1: Проверка прав доступа

```swift
AXIsProcessTrustedWithOptions([
  kAXTrustedCheckOptionPromptIfNeeded: true
])
```

**Что происходит:**
- Система проверяет разрешение в Settings → Security & Privacy → Accessibility
- Без разрешения песочница macOS заблокирует все попытки чтения
- Впервые вызов может вызвать диалог запроса разрешения у пользователя

#### Этап 2: Создание системного объекта доступности

```swift
let systemWide = AXUIElementCreateSystemWide()
```

**Результат:**
- Точка входа для навигации по всему дереву UI системы
- Универсальный доступ ко всем элементам всех окон

#### Этап 3: Определение фокусированного элемента

```swift
AXUIElementCopyAttributeValue(
  systemWide,
  kAXFocusedUIElementAttribute as CFString,
  &focusedElement
)
```

**Возвращает:**
- Ссылку на конкретный элемент пользовательского интерфейса в фокусе
- Например: текстовое поле сообщения в Slack или строка кода в VS Code

#### Этап 4: Извлечение текста

**Получение всего текста:**
```swift
AXUIElementCopyAttributeValue(
  focusedElement,
  kAXValueAttribute as CFString,
  &textValue
)
```

**Получение выделенного текста:**
```swift
AXUIElementCopyAttributeValue(
  focusedElement,
  kAXSelectedTextAttribute as CFString,
  &selectedText
)
```

### Определение позиции курсора (для плавающего UI)

```swift
AXUIElementCopyAttributeValue(
  focusedElement,
  kAXSelectedTextRangeAttribute as CFString,
  &textRange
)

AXUIElementCopyParameterizedAttributeValue(
  focusedElement,
  kAXBoundsForRangeParameterizedAttribute as CFString,
  [textRange] as CFArray,
  &bounds // CGRect с X, Y координатами
)
```

**Результат**: точные пиксельные координаты для позиционирования плавающего окна.

## Windows: UI Automation и MSAA

### Современный подход: UI Automation

```csharp
// Получение корневого элемента активного окна
var element = AutomationElement.FromHandle(
  GetForegroundWindow()
);

// Извлечение текста
var textPattern = element.GetCurrentPattern(ValuePattern.Pattern);
string text = textPattern.Current.Value;
```

**Преимущества:**
- Более современный API чем MSAA
- Поддерживается в Windows 7+
- Лучше работает с современными приложениями

### Fallback для устаревших приложений: MSAA

```csharp
// Для приложений, не поддерживающих UI Automation
IntPtr hwnd = FindWindowEx(...);

// Прямой запрос текста через системное сообщение
SendMessage(hwnd, WM_GETTEXT, bufferSize, buffer);
```

**Когда используется:**
- Старые приложения Win32
- Kiosks и спецаппараты
- Терминальные интерфейсы

## Проблема: несовместимость с Electron-приложениями

### Проблема

**Electron приложения** (Slack, VS Code, Discord) часто некорректно обрабатывают запросы Accessibility API:
- Иерархия элементов может быть неправильной
- Координаты возвращаются неточные
- Некоторые свойства недоступны

### Решение: эвристическая аппроксимация

```swift
// 1. Получить базовую позицию родительского элемента
let elementPosition = element.position // (x, y)

// 2. Запросить номер текущей строки
let lineNumber = AXUIElementCopyAttributeValue(
  element,
  kAXInsertionPointLineNumberAttribute
) as Int

// 3. Вычислить приблизительную Y-координату
let approximateY = elementPosition.y + (lineNumber * 14) // 14 — стандартная высота шрифта

// 4. Позиционировать индикатор записи
floatingUI.position = CGPoint(x: elementPosition.x, y: approximateY)
```

**Точность**: ±10–20 пикселей, достаточно для визуального фидбека.

## Безопасность и пески

### Требования безопасности macOS

- Приложение должно быть в пути Applications или иметь валидную подпись
- Песочница удаляет разрешение Accessibility по умолчанию
- Только явное разрешение пользователя включает доступ

### Windows UAC и права

- UIAutomation требует same-privilege access
- Приложение, запущенное от админа, может читать обычные приложения
- Обычное приложение не может читать привилегированные процессы

## Наблюдаемые ограничения

| Проблема | Причина | Решение |
|----------|---------|---------|
| Задержка 50–100мс | Асинхронный IPC между процессами | Кэширование, батчинг запросов |
| Неполные координаты | Electron, WebGL-рендеринг | Эвристическая аппроксимация |
| Отсутствие уведомлений | API не предоставляет событий изменения | Polling с интервалом 50мс |
| Конфликты с RDP | Удаленный рабочий стол блокирует доступ | Требуется локальная сессия |

## Интеграция в архитектуру диктовки

```
[Microphone Audio]
        ↓
[Speech-to-Text (Whisper)]
        ↓
┌─────────────────────────────────┐
│ Accessibility API (Extraction)  │
│ ├─ Application Context          │
│ ├─ Selected Text                │
│ └─ Cursor Position              │
└─────────────────────────────────┘
        ↓
[Semantic Tailoring + LLM]
        ↓
[Text Injection (Keystrokes/Clipboard)]
```

Все три параллельных потока (аудио, контекст, позиция) сходятся в LLM для создания финального результата.
