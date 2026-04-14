# Голосовые команды, триггеры и семантическое управление

## Эволюция: от жесткого синтаксиса к гибкости

### Первое поколение (Apple Dictation, Windows Speech)

Требовалось произносить каждый символ:
```
Пользователь говорит: "Hello comma space world period"
Результат: "Hello, world."
```

**Проблемы:**
- Неестественно
- Медленнее, чем печать
- Высокая когнитивная нагрузка

### Современный подход (AI-диктовка)

LLM расставляет пунктуацию и форматирование самостоятельно:
```
Пользователь говорит: "hello world"
Результат: "Hello, world."  ← AI исправил все
```

**Но** зарезервированные ключевые слова остаются для абсолютного контроля.

## Трехуровневая иерархия команд

### Уровень 1: Структурные команды (жесткие триггеры)

**Выполняются до LLM**, парсятся детектором ключевых слов.

#### Пунктуация и типография

| Команда | Результат | Примечание |
|---------|----------|-----------|
| `period` / `full stop` | `.` | Точка, конец предложения |
| `comma` | `,` | Запятая, пауза в предложении |
| `question mark` | `?` | Вопрос |
| `exclamation` / `exclamation point` | `!` | Восклицание |
| `ellipsis` | `…` | Многоточие |
| `colon` | `:` | Двоеточие |
| `semicolon` | `;` | Точка с запятой |

#### Структурное форматирование

| Команда | Результат | Использование |
|---------|----------|------------|
| `new line` | `\n` | Перенос строки |
| `new paragraph` | `\n\n` | Новый абзац |
| `tab` | `\t` | Отступ (в коде) |
| `indent` | 4 spaces | Выделение кода/цитат |

#### Code-специфичные скобки

```
open parenthesis    → (
close parenthesis   → )
open bracket        → [
close bracket       → ]
open brace          → {
close brace         → }
open angle bracket  → <
close angle bracket → >
```

#### Навигация и деструктивные команды

| Команда | Эффект | Система |
|---------|--------|--------|
| `delete that` | Удалить последнее слово/предложение | UNDO + DELETE |
| `delete last word` | Удалить последнее слово | DELETE backward |
| `delete last sentence` | Удалить последнее предложение | Smart selection + DELETE |
| `undo that` | Отменить последнее действие | Cmd+Z / Ctrl+Z |
| `redo that` | Повторить отмененное действие | Cmd+Shift+Z |

#### Управление регистром

```
capitalize [word]      → Write First Letter Uppercase
all caps [word]        → WRITE ALL CAPS
lowercase [word]       → write all lowercase
caps on / caps lock    → SWITCH MODE FOR ALL NEXT WORDS
caps off               → switch back to normal mode
```

### Уровень 2: Семантические команды (Command Mode)

**Выполняются LLM**, требуют выделенного текста и высокоуровневой инструкции.

#### Базовые трансформации

```
Выделенный текст: "This product is really good and useful."

Команда → Результат:
"Make it shorter"
  → "This product is good."

"Make it more professional"
  → "This product demonstrates excellent utility and value."

"Make it funny"
  → "This product is ridiculously awesome."

"Turn into bullet points"
  → "• Excellent quality
    • High utility
    • Excellent value"

"Summarize this"
  → "Good product."

"Translate to Spanish"
  → "Este producto es realmente bueno y útil."
```

#### Семантическая коррекция

```
Выделенный текст: "Let's meet tomorrow - actually let's do Friday"

Команда → Результат:
"Fix grammar"
  → "Let's meet Friday."  ← система поняла самокоррекцию

"Expand this"
  → "I propose we schedule our meeting for Friday instead of tomorrow, as it would work better for my schedule."

"Simplify"
  → "Friday works better."
```

#### Контекстно-зависимые трансформации

```
Выделенный текст (в коде):
function calculateTotal(items) {
  return items.reduce((sum, item) => sum + item.price, 0);
}

Команда → Результат:
"Add comments"
  → // С JSDoc комментариями

"Add error handling"
  → // С try-catch

"Make it TypeScript"
  → // С типизацией

"Optimize"
  → // Более оптимальная версия
```

#### Стилистические команды

```
"Shorten"       → Удалить лишние слова
"Expand"        → Добавить детали
"Formalize"     → Деловой язык
"Casualize"     → Неформальный язык
"Technical"     → Добавить терминологию
"ELI5"          → Объяснить как для 5-летнего
```

### Уровень 3: Макросы и сниппеты (максимальная производительность)

**Пользовательские шаблоны**, замещают длинные блоки текста на короткие триггеры.

#### Простые сниппеты

```
Пользователь создает макрос:
  Триггер: "send calendar link"
  Результат: "Please schedule a time that works best for you: https://calendly.com/john/30min"

Использование:
  Пользователь говорит в Slack: "Hey send calendar link"
  AI: "Hey" (диктовка) + "send calendar link" (макрос раскрывается)
  Результат: "Hey please schedule a time that works best for you: https://calendly.com/john/30min"
```

#### Контекстные сниппеты

```
Макрос может содержать переменные:

Триггер: "insert error template"
Результат: """
Error: {{ERROR_NAME}}
Location: {{FILE_NAME}}:{{LINE_NUMBER}}
Stack: {{STACK_TRACE}}
"""

При использовании система подставляет текущий контекст:
- {{FILE_NAME}} → "auth.ts"
- {{LINE_NUMBER}} → 45
- {{STACK_TRACE}} → буфер обмена
```

#### Командные словари (Shared Dictionaries)

**Для команд (Enterprise):**

```json
{
  "customDictionary": {
    "ACME": "ACME Corporation",  // Бренд
    "GPT4": "GPT-4",              // Технология
    "OKR": "Objective Key Result", // Метрика
    "xRGB": "Extended RGB"         // Стандарт
  }
}
```

**Результат**: когда LLM видит "ACME" в контексте, правильно интерпретирует как бренд, а не аббревиатуру.

#### Непрерывное обучение от исправлений

```
Система фиксирует все ручные исправления пользователя:

1. Система диктует: "algoritm" (ошибка)
2. Пользователь исправляет на: "algorithm"
3. LLM запоминает контекст и улучшает веса:
   - При похожем контексте вероятность "algoritm" снижается
   - Вероятность "algorithm" повышается
4. При следующей диктовке улучшение заметно
```

## Детекция команд: точность распознавания

### Проблема: ложные срабатывания

**Сценарий 1:**
```
Пользователь говорит в историческом контексте: "The Roman period ended"
Система неправильно парсит: "period" как команда, вставляет точку
Результат: "The Roman . ended"  ❌ НЕПРАВИЛЬНО
```

**Решение**: микропаузы + акустический анализ

```python
def is_command_keyword(word, context):
  # Проверка 1: микропауза перед/после слова?
  pause_before = audio.get_pause_duration_before(word) > 200  # мс
  pause_after = audio.get_pause_duration_after(word) > 200

  # Проверка 2: интонация (pitch change)?
  is_lifted_intonation = audio.pitch(word) > average_pitch + 50  # Hz

  # Проверка 3: контекст (грамматически возможна команда)?
  grammatical_fit = context.is_command_position(word)

  return pause_before or (pause_after and is_lifted_intonation) or grammatical_fit
```

### Тестирование точности

| Сценарий | Точность |
|----------|----------|
| Четкая команда с паузой | 98% |
| Команда в конце предложения | 85% |
| Команда в контексте (период=period) | 92% |
| Быстрая речь, нет пауз | 70% |

## Интеграция команд в поток диктовки

```
┌──────────────────────────────────┐
│ Audio Stream                     │
└──────────────────────────────────┘
        ↓
┌──────────────────────────────────┐
│ Real-time Command Detection      │
│ (Structural keywords only)       │
└──────────────────────────────────┘
        ↓
┌──────────────────────────────────┐
│ Streaming STT + LLM              │
│ (Full semantic processing)       │
│                                  │
│ + Detected keywords stripped     │
│   (не отправлять в LLM)         │
└──────────────────────────────────┘
        ↓
┌──────────────────────────────────┐
│ Final Text                       │
│ + Applied Formatting             │
└──────────────────────────────────┘
```

## Приоритет команд

При наличии нескольких возможных интерпретаций:

```
1. Структурные команды (пунктуация, новая строка)
2. Деструктивные команды (delete, undo) — требуют подтверждения
3. Макросы/Сниппеты — точное совпадение
4. Command Mode — только если есть выделенный текст
5. Обычная диктовка — fallback
```

## Безопасность: подтверждение деструктивных операций

```
Пользователь говорит: "delete that"
↓
Система показывает диалог:
┌─────────────────────────────────┐
│ Are you sure?                   │
│                                 │
│ This will delete:               │
│ "Some important text here"      │
│                                 │
│ [Cancel]  [Delete]              │
└─────────────────────────────────┘

Пользователь может отменить голосом:
- "cancel"
- "no"
- "nevermind"
```
