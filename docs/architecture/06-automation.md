# Скриптовая маршрутизация и системная автоматизация

## Парадигма: микрофон как командный интерфейс

**Традиционно**: микрофон → текст в активное окно

**Современно**: микрофон → умная маршрутизация → множество целей:
- Текст в окно
- Веб-поиск
- Системные команды
- Скрипты и макросы
- Удаленные API
- Локальная обработка

## Архитектура Macrowhisper

### Концепция

Macrowhisper — это фоновый сервис (daemon), который:
1. Мониторит скрытые папки приложения Superwhisper
2. Перехватывает готовые результаты диктовки (в `meta.json`)
3. Применяет правила маршрутизации
4. Распределяет текст по различным обработчикам

### Процесс работы

```
┌────────────────────────────┐
│ Superwhisper               │
│ ├─ Диктовка               │
│ ├─ Семантический тейлоринг│
│ └─ Генерация результата    │
│    ↓                       │
│ Запись в meta.json:        │
│ {                          │
│   "result": "...",         │
│   "context": {...}         │
│ }                          │
└────────────────────────────┘
        ↓ (file created)
┌────────────────────────────┐
│ Macrowhisper Daemon        │
│ ├─ Мониторит файл         │
│ ├─ Читает результат        │
│ ├─ Применяет regex rules   │
│ └─ Маршрутизирует         │
└────────────────────────────┘
        ↓
   ┌────┴────┬─────────┬──────────┐
   ↓         ↓         ↓          ↓
  Paste    Shell    Browser   Shortcut
  (Cmd+V)  Script   (Google)  (Automator)
```

## Маршрутизация: правила и триггеры

### Конфигурационный формат JSON

```json
{
  "rules": [
    {
      "name": "Google Search",
      "trigger": "^ask google (.+)$",
      "action": "url",
      "url": "https://www.google.com/search?q={{capture1}}",
      "encoding": "urlencoded"
    },
    {
      "name": "Slack Message",
      "trigger": "^send (.*)",
      "action": "paste",
      "delay": 100
    },
    {
      "name": "Run Script",
      "trigger": "^execute (.+)",
      "action": "shell",
      "command": "bash ~/scripts/{{capture1}}.sh"
    },
    {
      "name": "Trigger Shortcut",
      "trigger": "^shortcut (.+)",
      "action": "shortcut",
      "shortcut": "{{capture1}}"
    }
  ]
}
```

## Типы действий (Actions)

### 1. URL Action (Веб-маршрутизация)

#### Веб-поиск

```json
{
  "name": "Google Search",
  "trigger": "^search (.+)$|^ask google (.+)$",
  "action": "url",
  "url": "https://www.google.com/search?q={{$1}}"
}
```

**Пример:**
```
Пользователь говорит: "search how to use Git rebase"
↓
Regex захватывает: "how to use Git rebase"
↓
URL строится: https://www.google.com/search?q=how+to+use+Git+rebase
↓
Браузер открывается автоматически
```

#### Кастомные ссылки с параметрами

```json
{
  "name": "Create GitHub Issue",
  "trigger": "^create issue (.+)$",
  "action": "url",
  "url": "https://github.com/myrepo/issues/new?title={{$1}}&labels=bug"
}
```

#### URL Encoding

```python
# Пользователь говорит: "search hello world!"
swResult = "hello world!"

# Правило:
"url": "https://api.example.com/search?q={{swResult}}"

# Encoding типы:
urlencoded:  "hello%20world%21"
utf8:        "hello world!"
base64:      "aGVsbG8gd29ybGQh"
```

### 2. Shell Action (Системные команды)

#### Bash/Zsh скрипты

```json
{
  "name": "Create Project",
  "trigger": "^new project (.+)$",
  "action": "shell",
  "shell": "bash",
  "command": "mkdir -p ~/Projects/{{$1}} && cd ~/Projects/{{$1}} && git init"
}
```

**Пример:**
```
Пользователь говорит: "new project my-app"
↓
Команда: mkdir -p ~/Projects/my-app && cd ~/Projects/my-app && git init
↓
Проект создан автоматически
```

#### Передача контекста в скрипт

```json
{
  "name": "Process With Context",
  "trigger": "^process (.+)$",
  "action": "shell",
  "command": "process_script.sh",
  "env": {
    "SW_RESULT": "{{swResult}}",
    "SW_APP": "{{applicationContext.processName}}",
    "SW_CLIPBOARD": "{{clipboardContext.text}}"
  }
}
```

**Bash скрипт:**
```bash
#!/bin/bash
# Получить переменные окружения от Macrowhisper
TEXT="$SW_RESULT"
APP="$SW_APP"
CLIPBOARD="$SW_CLIPBOARD"

# Обработать
echo "Processing in $APP: $TEXT"
echo "Clipboard contained: $CLIPBOARD"
```

### 3. AppleScript/PowerShell Action

#### macOS: AppleScript

```json
{
  "name": "Send iMessage",
  "trigger": "^message (.+)$",
  "action": "applescript",
  "script": "send_message.applescript"
}
```

**send_message.applescript:**
```applescript
on run argv
  set messageText to item 1 of argv

  tell application "Messages"
    set targetBuddy to "John Doe"
    send messageText to buddy targetBuddy
  end tell
end run
```

#### Windows: PowerShell

```json
{
  "name": "Send Email",
  "trigger": "^email (.+)$",
  "action": "powershell",
  "script": "send_email.ps1"
}
```

**send_email.ps1:**
```powershell
param($Message)

$EmailParams = @{
  To = "recipient@example.com"
  From = "sender@example.com"
  Subject = "From Voice"
  Body = $Message
  SmtpServer = "smtp.gmail.com"
}

Send-MailMessage @EmailParams
```

### 4. Shortcut Action (Automation)

#### macOS Shortcuts

```json
{
  "name": "Create Reminder",
  "trigger": "^remind me (.+)$",
  "action": "shortcut",
  "shortcut": "Create Reminder",
  "inputs": {
    "text": "{{$1}}",
    "time": "tomorrow 9am"
  }
}
```

#### Alfred Workflows

```json
{
  "name": "Search Spotlight",
  "trigger": "^find (.+)$",
  "action": "alfred",
  "workflow": "Spotlight Search",
  "query": "{{$1}}"
}
```

## Асинхронные рабочие процессы

### Пример 1: Многошаговая автоматизация

```
[Voice Input] → [Extract task] → [Create in app 1] → [Notify in app 2]
                                         ↓
                                   [Wait for status]
                                         ↓
                                   [Async task]
```

**Конфигурация:**
```json
{
  "name": "Full Task Workflow",
  "trigger": "^create task (.+)$",
  "action": "workflow",
  "steps": [
    {
      "type": "shell",
      "command": "create_task_api.sh",
      "async": true
    },
    {
      "type": "notify",
      "message": "Task created: {{$1}}"
    }
  ]
}
```

### Пример 2: Apple Watch → Mac → База данных

```
┌──────────────────────┐
│ Apple Watch          │
│ Voice Note → iCloud  │
└──────────────────────┘
           ↓ (Sync)
┌──────────────────────┐
│ Mac (Macrowhisper)   │
│ Detect file change   │
└──────────────────────┘
           ↓
┌──────────────────────┐
│ Superwhisper         │
│ Transcribe audio     │
└──────────────────────┘
           ↓
┌──────────────────────┐
│ Keyboard Maestro     │
│ (Automation)         │
└──────────────────────┘
           ↓
┌──────────────────────┐
│ Bear (Notes app)     │
│ Store transcription  │
└──────────────────────┘
```

**Весь процесс автоматический, без кликов!**

## Расширенные функции маршрутизации

### Условное выполнение

```json
{
  "name": "Smart Route",
  "trigger": "^do something$",
  "conditions": {
    "app": "Slack",  // Только в Slack
    "time": "9-17"   // Только в рабочие часы
  },
  "action": "shell",
  "command": "handle_work_task.sh"
}
```

### Вложенные правила

```json
{
  "name": "Cascading Rules",
  "trigger": "^process (.+)$",
  "action": "workflow",
  "steps": [
    {
      "trigger": "^error",
      "action": "shell",
      "command": "handle_error.sh"
    },
    {
      "trigger": "^success",
      "action": "notify",
      "message": "Completed!"
    }
  ]
}
```

### Повторы и Retry Logic

```json
{
  "name": "Reliable API Call",
  "action": "url",
  "url": "https://api.example.com/data",
  "retry": {
    "maxAttempts": 3,
    "delayMs": 1000,
    "backoff": "exponential"
  }
}
```

## Примеры реальных сценариев

### Сценарий 1: Анализ ошибок сервера

```
Разработчик видит ошибку в логах сервера
↓ копирует stack trace
↓ говорит в мессенджер: "analyze this error"
↓
Macrowhisper перехватывает "analyze"
↓
Правило:
  - Достает stack trace из буфера
  - Отправляет в Claude API
  - Получает анализ
  - Вставляет результат в мессенджер

Все за 2-3 секунды, без переключения окон!
```

### Сценарий 2: Автоматическое создание тикета

```
Пользователь говорит: "create ticket slow database query"
↓
Macrowhisper:
  1. Извлекает: "slow database query"
  2. Получает контекст (app = Terminal)
  3. Команда маршрутизации:
     - Вызывает GitHub API
     - Создает issue с заголовком "slow database query"
     - Добавляет ярлык "performance"
     - Вставляет URL в терминал
```

### Сценарий 3: Контекстное выполнение

```
Если пользователь в Slack говорит:
  "schedule meeting next Tuesday"
↓
Макрос создает Slack-friendly формат
↓
Если в Calendar говорит то же:
  Макрос вызывает Calendar API
↓
Если в Terminal:
  Макрос создает напоминание через shell
```

## Безопасность маршрутизации

### Санитизация входных данных

```python
def sanitize_command_input(user_input, rule_type):
  if rule_type == "shell":
    # Запретить опасные символы
    dangerous = ['|', '&&', ';', '`', '$()']
    for char in dangerous:
      if char in user_input:
        raise SecurityError(f"Dangerous character: {char}")

  if rule_type == "url":
    # URL encode, но не переполнение
    if len(user_input) > 500:
      raise SecurityError("Input too long")

  return user_input
```

### Разрешения (Permissions)

```json
{
  "rules": [
    {
      "name": "Safe: Google Search",
      "permissions": ["internet"],
      "action": "url"
    },
    {
      "name": "Risky: Delete Files",
      "permissions": ["filesystem_write", "confirmation_required"],
      "action": "shell"
    }
  ]
}
```

При первом использовании рискованного правила система запрашивает подтверждение.
