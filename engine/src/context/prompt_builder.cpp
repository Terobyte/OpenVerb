// ---------------------------------------------------------------------------
// prompt_builder.cpp — System prompt construction and context assembly
//
// MVP1: English-only, 6 one-line styles hard-coded inline.
// MVP4+ i18n: system prompts and generation suffixes localised for
//   en/ru/es/fr/de/ja via in-code locale maps; style descriptions
//   remain English-only (deferred to post-v1.0).
// ---------------------------------------------------------------------------

#include "context/prompt_builder.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------
// xml_escape — replace XML-special characters with predefined entity refs.
//
// Applied to every user-supplied field before embedding it in the XML prompt
// so that values containing '<', '>', or '&' cannot corrupt the tag structure.
// ---------------------------------------------------------------------------

static std::string xml_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (unsigned char c : s) {
        switch (c) {
            case '&':  out += "&amp;";  break;
            case '<':  out += "&lt;";   break;
            case '>':  out += "&gt;";   break;
            case '"':  out += "&quot;"; break;
            case '\'': out += "&apos;"; break;
            default:   out += static_cast<char>(c); break;
        }
    }
    return out;
}

#include <nlohmann/json.hpp>

using json = nlohmann::json;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Maximum bytes kept from selected-text field.
static constexpr std::size_t MAX_CONTEXT_BYTES = 10u * 1024u;  // 10 KB

// System prompts injected into <SystemContext>, keyed by ISO 639-1 locale code.
// Unknown locale codes fall back to "en" in get_system_prompt().
static const std::unordered_map<std::string, std::string> SYSTEM_PROMPTS = {
    {"en",
     "You are an expert text editor processing direct audio input.\n"
     "The user dictated speech. Your task:\n"
     "1. Transcribe what the user said faithfully, preserving all sentences and ideas.\n"
     "   For short utterances: output the single phrase. For long dictations: output\n"
     "   every sentence — do NOT summarize or collapse multiple sentences into one.\n"
     "2. If the same phrase or sentence appears repeated multiple times in the audio,\n"
     "   output it ONCE only — repetition is an audio encoding artifact, not intentional.\n"
     "3. Remove filler words (um, uh, like, you know).\n"
     "4. Fix grammar, adapt tone and style for the active application.\n"
     "5. If the output is ONLY a structural command (delete that, undo, new line,\n"
     "   new paragraph), output ONLY that command word(s) with no other text.\n"
     "   Punctuation (period, comma, question mark, exclamation) is NOT a command —\n"
     "   output it directly as . , ? ! in the tailored text."},
    {"ru",
     "Вы — эксперт по редактированию текста, обрабатывающий прямой аудиоввод.\n"
     "Пользователь продиктовал речь. Ваша задача:\n"
     "1. Точно расшифровать сказанное пользователем, сохраняя все предложения и идеи.\n"
     "   Для коротких фраз: выведите одну фразу. Для длинных диктовок: выведите\n"
     "   каждое предложение — НЕ резюмируйте и НЕ объединяйте несколько предложений в одно.\n"
     "2. Если одна и та же фраза или предложение повторяется несколько раз в аудио,\n"
     "   выведите её ТОЛЬКО ОДИН РАЗ — повторение является артефактом аудиокодирования.\n"
     "3. Удалите слова-паразиты (эм, ээ, типа, ну).\n"
     "4. Исправьте грамматику, адаптируйте тон и стиль для активного приложения.\n"
     "5. Если вывод — ТОЛЬКО структурная команда (удалить, отменить, новая строка,\n"
     "   новый абзац), выведите ТОЛЬКО эту команду без другого текста.\n"
     "   Пунктуация (точка, запятая, вопросительный знак, восклицательный знак) НЕ является командой —\n"
     "   выводите её напрямую как . , ? ! в итоговом тексте."},
    {"es",
     "Eres un editor de texto experto que procesa entrada de audio directa.\n"
     "El usuario ha dictado voz. Tu tarea:\n"
     "1. Transcribir fielmente lo que dijo el usuario, preservando todas las oraciones e ideas.\n"
     "   Para frases cortas: muestra la única frase. Para dictados largos: muestra\n"
     "   cada oración — NO resumas ni colapses múltiples oraciones en una.\n"
     "2. Si la misma frase u oración aparece repetida múltiples veces en el audio,\n"
     "   muéstrala SOLO UNA VEZ — la repetición es un artefacto de codificación de audio.\n"
     "3. Elimina muletillas (eh, este, o sea, sabes).\n"
     "4. Corrige gramática, adapta el tono y estilo para la aplicación activa.\n"
     "5. Si el resultado es SOLO un comando estructural (borrar eso, deshacer, nueva línea,\n"
     "   nuevo párrafo), muestra SOLO esa palabra(s) de comando sin ningún otro texto.\n"
     "   La puntuación (punto, coma, signo de interrogación, exclamación) NO es un comando —\n"
     "   muéstrala directamente como . , ? ! en el texto final."},
    {"fr",
     "Vous êtes un éditeur de texte expert traitant une entrée audio directe.\n"
     "L'utilisateur a dicté de la parole. Votre tâche :\n"
     "1. Transcrire fidèlement ce que l'utilisateur a dit, en préservant toutes les phrases et idées.\n"
     "   Pour les courtes expressions : affichez la seule phrase. Pour les longues dictées : affichez\n"
     "   chaque phrase — NE résumez PAS et NE fusionnez PAS plusieurs phrases en une seule.\n"
     "2. Si la même phrase apparaît plusieurs fois dans l'audio,\n"
     "   affichez-la UNE SEULE FOIS — la répétition est un artefact d'encodage audio.\n"
     "3. Supprimez les mots de remplissage (euh, hum, genre, vous savez).\n"
     "4. Corrigez la grammaire, adaptez le ton et le style pour l'application active.\n"
     "5. Si le résultat est UNIQUEMENT une commande structurelle (supprimer ça, annuler, nouvelle ligne,\n"
     "   nouveau paragraphe), affichez UNIQUEMENT ce(s) mot(s) de commande sans autre texte.\n"
     "   La ponctuation (point, virgule, point d'interrogation, exclamation) n'est PAS une commande —\n"
     "   affichez-la directement comme . , ? ! dans le texte final."},
    {"de",
     "Du bist ein Expertentexteditor, der direkte Audioeingabe verarbeitet.\n"
     "Der Benutzer hat Sprache diktiert. Deine Aufgabe:\n"
     "1. Transkribiere treu, was der Benutzer gesagt hat, und bewahre alle Sätze und Ideen.\n"
     "   Für kurze Äußerungen: gib die einzelne Phrase aus. Für lange Diktate: gib\n"
     "   jeden Satz aus — FASSE NICHT zusammen oder fasse mehrere Sätze zu einem zusammen.\n"
     "2. Wenn dieselbe Phrase oder Satz mehrmals im Audio erscheint,\n"
     "   gib sie NUR EINMAL aus — Wiederholung ist ein Audiocodierungsartefakt.\n"
     "3. Entferne Füllwörter (äh, ähm, also, weißt du).\n"
     "4. Korrigiere Grammatik, passe Ton und Stil an die aktive Anwendung an.\n"
     "5. Wenn die Ausgabe NUR ein Strukturbefehl ist (lösche das, rückgängig, neue Zeile,\n"
     "   neuer Absatz), gib NUR dieses(e) Befehlswort(e) ohne anderen Text aus.\n"
     "   Zeichensetzung (Punkt, Komma, Fragezeichen, Ausrufezeichen) ist KEIN Befehl —\n"
     "   gib sie direkt als . , ? ! im maßgeschneiderten Text aus."},
    {"ja",
     "あなたはダイレクトな音声入力を処理するエキスパートのテキストエディターです。\n"
     "ユーザーが音声を口述しました。あなたのタスク：\n"
     "1. ユーザーの発言を忠実に文字起こしし、すべての文とアイデアを保持してください。\n"
     "   短い発話の場合：単一のフレーズを出力してください。長い口述の場合：\n"
     "   すべての文を出力してください — 複数の文を要約または統合しないでください。\n"
     "2. 同じフレーズや文が音声に複数回繰り返されている場合、\n"
     "   一度だけ出力してください — 繰り返しは音声エンコーディングのアーティファクトです。\n"
     "3. フィラーワード（えー、えーと、みたいな、ね）を削除してください。\n"
     "4. 文法を修正し、アクティブなアプリケーションに合わせてトーンとスタイルを調整してください。\n"
     "5. 出力が構造コマンドのみの場合（それを削除、元に戻す、改行、\n"
     "   新しい段落）、他のテキストなしでそのコマンドワードのみを出力してください。\n"
     "   句読点（ピリオド、カンマ、疑問符、感嘆符）はコマンドではありません —\n"
     "   仕上げテキストに直接 . , ? ! として出力してください。"},
};

// Generation suffixes keyed by locale.  Returned as the second element of
// build_prompt()'s pair so callers and tests can verify without depending
// on the inference layer.
static const std::unordered_map<std::string, std::string> GENERATION_SUFFIXES = {
    {"en", "Output ONLY the final text:"},
    {"ru", "Выведи ТОЛЬКО итоговый текст:"},
    {"es", "Genera SOLO el texto final:"},
    {"fr", "Produis UNIQUEMENT le texte final:"},
    {"de", "Gib NUR den endgültigen Text aus:"},
    {"ja", "最終テキストのみを出力してください:"},
};

static std::string get_system_prompt(const std::string& locale) {
    auto it = SYSTEM_PROMPTS.find(locale);
    if (it != SYSTEM_PROMPTS.end())
        return it->second;
    return SYSTEM_PROMPTS.at("en");
}

static std::string get_generation_suffix(const std::string& locale) {
    auto it = GENERATION_SUFFIXES.find(locale);
    if (it != GENERATION_SUFFIXES.end())
        return it->second;
    return GENERATION_SUFFIXES.at("en");
}

// ---------------------------------------------------------------------------
// STYLE_MAP — bundle ID → concise style hint (Stage 1: exact O(1) lookup)
// ---------------------------------------------------------------------------
// MVP4+ i18n: style descriptions remain English-only (deferred to post-v1.0);
//   only system prompts and generation suffixes are localised.

static const std::unordered_map<std::string, std::string> STYLE_MAP = {
    {"com.tinyspeck.slackmacgap", "Casual, concise, emoji OK"},
    {"com.apple.mail",            "Formal, complete sentences"},
    {"com.microsoft.VSCode",      "Code-aware, syntax-correct, comments"},
    {"com.apple.Terminal",        "Commands, no prose"},
    {"com.apple.Notes",           "Raw dictation, preserve everything"},
};

// ---------------------------------------------------------------------------
// FRAGMENT_STYLES — (fragment, style) pairs for Stage 2 fuzzy name matching.
//
// Ordered: first hit wins.  Fragments correspond to the well-known apps above
// so that display names like "Slack" or "Terminal" resolve to the right style.
// ---------------------------------------------------------------------------

static const std::vector<std::pair<std::string, std::string>> FRAGMENT_STYLES = {
    {"slack",    "Casual, concise, emoji OK"},
    {"mail",     "Formal, complete sentences"},
    {"vscode",   "Code-aware, syntax-correct, comments"},
    {"terminal", "Commands, no prose"},
    {"notes",    "Raw dictation, preserve everything"},
};

// ---------------------------------------------------------------------------
// resolve_style
// ---------------------------------------------------------------------------

std::string resolve_style(const std::string& app_name) {
    // Stage 1: exact bundle ID match — O(1)
    auto it = STYLE_MAP.find(app_name);
    if (it != STYLE_MAP.end())
        return it->second;

    // Stage 2: iterate FRAGMENT_STYLES and test if lowercase(app_name)
    // contains a known fragment; first match wins.
    std::string lower = app_name;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    for (const auto& [fragment, style] : FRAGMENT_STYLES) {
        if (lower.find(fragment) != std::string::npos)
            return style;
    }

    // Fallback: neutral prose cleanup
    return "Neutral, clean grammar";
}

// ---------------------------------------------------------------------------
// build_prompt
// ---------------------------------------------------------------------------

std::pair<std::string, std::string> build_prompt(const PromptContext& ctx) {
    const std::string style = resolve_style(ctx.app_name);

    std::string xml;
    xml.reserve(2048);

    const std::string locale = ctx.locale.empty() ? "en" : ctx.locale;

    // <SystemContext> — expert role + five instructions
    xml += "<SystemContext>\n";
    xml += get_system_prompt(locale);
    xml += "\n</SystemContext>\n";

    // <ApplicationContext> — always present; empty fields produce blank values.
    // app_name and window_title are escaped: bundle IDs are safe in practice
    // but window titles can contain arbitrary user text.
    xml += "<ApplicationContext>\n";
    xml += "App: ";    xml += xml_escape(ctx.app_name);    xml += "\n";
    xml += "Window: "; xml += xml_escape(ctx.window_title); xml += "\n";
    xml += "Style: ";  xml += style;                        xml += "\n";
    xml += "</ApplicationContext>\n";

    // <SelectedText> — omit tag entirely when selected_text is empty.
    // Escape for the same reason as clipboard.
    if (!ctx.selected_text.empty()) {
        xml += "<SelectedText>\n";
        xml += xml_escape(ctx.selected_text);
        xml += "\n</SelectedText>\n";
    }

    // The generation suffix is returned here so callers and tests can verify it
    // without depending on the inference layer.
    return {xml, get_generation_suffix(locale)};
}

// ---------------------------------------------------------------------------
// truncate_utf8 — truncate to at most max_bytes, respecting UTF-8 boundaries.
//
// UTF-8 continuation bytes are 0x80–0xBF (top two bits == 10).  After slicing
// at max_bytes we walk backward over any dangling continuation bytes so we
// never leave a partial multi-byte sequence (e.g. a 3-byte Cyrillic glyph or
// a 4-byte emoji) in the result.
// ---------------------------------------------------------------------------
static std::string truncate_utf8(const std::string& s, std::size_t max_bytes) {
    if (s.size() <= max_bytes) return s;
    std::size_t pos = max_bytes;
    // Walk back over continuation bytes (10xxxxxx) to the nearest start byte.
    while (pos > 0 && (static_cast<unsigned char>(s[pos]) & 0xC0) == 0x80)
        --pos;
    return s.substr(0, pos);
}

// ---------------------------------------------------------------------------
// parse_context_json
// ---------------------------------------------------------------------------

PromptContext parse_context_json(const std::string& json_str) {
    // Contract (header line 70): return a default-empty PromptContext when the
    // string is empty.  An empty string is not valid JSON, so we must guard
    // before calling json::parse() — otherwise nlohmann throws parse_error even
    // for the normal no-`--context` path where config defaults to "".
    if (json_str.empty())
        return PromptContext{};

    // Throws nlohmann::json::parse_error on malformed JSON — propagate as-is.
    const json j = json::parse(json_str);

    PromptContext ctx;

    if (j.contains("app") && j.at("app").is_string())
        ctx.app_name = j.at("app").get<std::string>();

    if (j.contains("window") && j.at("window").is_string())
        ctx.window_title = j.at("window").get<std::string>();

    if (j.contains("selected") && j.at("selected").is_string()) {
        ctx.selected_text = j.at("selected").get<std::string>();
        if (ctx.selected_text.size() > MAX_CONTEXT_BYTES)
            ctx.selected_text = truncate_utf8(ctx.selected_text, MAX_CONTEXT_BYTES);
    }

    if (j.contains("locale") && j.at("locale").is_string())
        ctx.locale = j.at("locale").get<std::string>();

    // Unknown keys are silently ignored (no schema check, no error).
    return ctx;
}
