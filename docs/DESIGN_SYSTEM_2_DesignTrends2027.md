# 2. Design Trends 2027 — Техническая реализация

**Версия:** 2026-04 · **Статус:** Рабочий документ

---

## Техническая реализация дизайн-систем

### Glassmorphism → Adaptive Glass

**Проблемы классического Glassmorphism:**
- Чрезмерная полупрозрачность снижает контрастность текста
- Трудночитаемость на сложных фонах
- Сенсорная перегрузка для пользователей с нарушениями зрения
- Неэффективен при солнечном освещении

**Adaptive Glass — техническая архитектура:**

Программная система на базе локальных алгоритмов ИИ, которая динамически изменяет:
- Уровень размытия (blur)
- Прозрачность (opacity)
- Цветовую насыщенность (saturation)

В зависимости от анализируемого контента фона и данных сенсоров освещенности.

**Реализация на Swift/SwiftUI:**

```swift
struct AdaptiveGlassView: View {
    @State private var blurAmount: CGFloat = 8
    @State private var opacity: Double = 0.7

    var body: some View {
        ZStack {
            // Background content

            // Adaptive glass layer
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .blur(radius: blurAmount)
                .opacity(opacity)
                .onReceive(brightnessPublisher) { brightness in
                    // Динамическая коэффициент плотности:
                    // - Светлый фон: коэффициент 1.2x (более непрозрачно)
                    // - Темный фон: коэффициент 0.8x (более прозрачно)
                    opacity = brightness > 0.5 ? 0.84 : 0.56
                    blurAmount = brightness > 0.5 ? 10 : 6
                }
        }
    }
}
```

**Синхронизация с доступностью:**
- Автоматически синхронизируется с системными настройками
- `@Environment(\.accessibilityReduceMotion)` — отключить шейдеры
- `@Environment(\.accessibilityHighContrast)` — монолитные панели вместо стекла

---

## Морфизмы 2027 — Техническая матрица

| Парадигма | SwiftUI реализация | Когда использовать |
|-----------|-------------------|-------------------|
| **Glassmorphism (Адаптивный)** | `.ultraThinMaterial`, `blur()`, gradient borders | AR/VR UI, уведомления, overlay меню |
| **Neumorphism** | soft shadows + complementary background, subtle gradients | утилитарные интерфейсы, IOT |
| **Claymorphism** | 3D-like inner glow, double shadows, rounded forms | образовательные приложения, fun UI |
| **Neo-brutalism** | `Color.black` sharp shadows, `offset()`, монотипные borders | утилиты, портфолио, нишевые apps |
| **Skeuomorphism (Возрождение)** | complex gradients, texture overlays, physical mimicry | профессиональное ПО, премиум-гаджеты |

**Claymorphism (рекомендуется для OpenVerb):**

```swift
struct ClayButton: View {
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 4) // outer
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.3), lineWidth: 1)  // inner light edge
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: -2, inset: true)
        )
    }
}
```

---

## Доступность: WCAG 2.2 & ADA

### Требования (дедлайны)

- **24 апреля 2026:** государственные учреждения, муниципалитеты, вузы
- **26 апреля 2027:** организации с <50k населения юрисдикции

**Последствия несоблюдения:**
- Коллективные судебные иски
- Штрафы и репутационный ущерб

### POUR модель

Любой контент должен быть:
1. **Perceivable** (Воспринимаемым) — видимость, контрастность, альтернативные форматы
2. **Operable** (Работоспособным) — горячие клавиши, focus order, без trap
3. **Understandable** (Понятным) — язык, labels, инструкции
4. **Robust** (Надежным) — доступность технологиям ассистива

### APCA (Advanced Perceptual Contrast Algorithm)

Переход от устаревших алгоритмов к APCA (часть WCAG 3.0):
- Точнее отражает биологию человеческого восприятия
- Учитывает дисплеи высокой плотности пикселей
- Позволяет создавать нюансированные, легитимные интерфейсы

**SwiftUI реализация:**

```swift
// Контрастность текста
struct AccessibleText: View {
    var text: String

    var body: some View {
        Text(text)
            .foregroundColor(.primary)  // автоматический контраст в light/dark mode
            .accessibility(label: Text(text))  // для screen readers
    }
}

// Фокус-индикатор
@FocusState private var focused: Bool

Button("Нажми") {
    // action
}
.focused($focused)
.accessibility(focused: $focused)
.border(focused ? Color.blue : Color.clear, width: 2)
```

### Обязательные практики 2027

**Независимость от цвета:**
- Информация не должна передаваться исключительно цветом
- Используй labels, шаблоны, текстуры

**Keyboard navigation:**
- Все интерактивные элементы доступны через Tab
- Правильный focus order (логический, не визуальный)

**Screen readers:**
- Все кнопки, поля должны иметь `accessibility(label:)` или `accessibility(identifier:)`
- Используй `AccessibilityElement` для grouping

**Motion:**
- `@Environment(\.accessibilityReduceMotion)` — отключать анимации если нужно
- Не полагайся на animation для важной информации

---

**Документ актуален на:** 2026-04-16
