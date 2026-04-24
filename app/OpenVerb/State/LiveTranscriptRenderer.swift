import Foundation

// ---------------------------------------------------------------------------
// LiveTranscriptRenderer
//
// Pure formatting layer for the recorder HUD. It turns raw partial text and
// polished text into display tokens with semantic statuses. SwiftUI owns only
// layout and animation; this file owns word matching and replacement markup.
// ---------------------------------------------------------------------------

struct LiveTranscriptToken: Identifiable, Equatable {
    enum Status: Equatable {
        case confirmed
        case pending
        case wrong
        case correction
        case polished
    }

    let id: Int
    var display: String
    var normalized: String
    var status: Status
}

enum LiveTranscriptRenderer {

    static func tokens(from text: String, status: LiveTranscriptToken.Status) -> [LiveTranscriptToken] {
        splitWords(text).enumerated().map { index, word in
            LiveTranscriptToken(
                id: index,
                display: word.display,
                normalized: word.normalized,
                status: status
            )
        }
    }

    static func revisionTokens(raw: String, polished: String) -> [LiveTranscriptToken] {
        let rawWords = splitWords(raw)
        let polishedWords = splitWords(polished)
        guard !rawWords.isEmpty else {
            return indexedTokens(polishedWords, status: .correction)
        }
        guard !polishedWords.isEmpty else {
            return indexedTokens(rawWords, status: .wrong)
        }

        let matches = lcsMatches(rawWords.map(\.normalized), polishedWords.map(\.normalized))
        var output: [LiveTranscriptToken] = []
        var rawIndex = 0
        var polishedIndex = 0

        func append(_ word: Word, status: LiveTranscriptToken.Status) {
            output.append(
                LiveTranscriptToken(
                    id: output.count,
                    display: word.display,
                    normalized: word.normalized,
                    status: status
                )
            )
        }

        func emitReplacement(rawEnd: Int, polishedEnd: Int) {
            for word in rawWords[rawIndex..<rawEnd] {
                append(word, status: .wrong)
            }
            for word in polishedWords[polishedIndex..<polishedEnd] {
                append(word, status: .correction)
            }
        }

        for match in matches {
            emitReplacement(rawEnd: match.raw, polishedEnd: match.polished)
            append(polishedWords[match.polished], status: .confirmed)
            rawIndex = match.raw + 1
            polishedIndex = match.polished + 1
        }
        emitReplacement(rawEnd: rawWords.count, polishedEnd: polishedWords.count)
        return output
    }

    private static func indexedTokens(_ words: [Word], status: LiveTranscriptToken.Status) -> [LiveTranscriptToken] {
        words.enumerated().map { index, word in
            LiveTranscriptToken(
                id: index,
                display: word.display,
                normalized: word.normalized,
                status: status
            )
        }
    }
}

private struct Word {
    var display: String
    var normalized: String
}

private struct LCSMatch {
    var raw: Int
    var polished: Int
}

private func splitWords(_ text: String) -> [Word] {
    text.split(whereSeparator: { $0.isWhitespace }).map { slice in
        let display = String(slice)
        return Word(display: display, normalized: normalizedWord(display))
    }
}

private func normalizedWord(_ word: String) -> String {
    let scalars = word.unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
    }
    return String(String.UnicodeScalarView(scalars)).lowercased()
}

private func lcsMatches(_ raw: [String], _ polished: [String]) -> [LCSMatch] {
    guard !raw.isEmpty, !polished.isEmpty else { return [] }

    var table = Array(
        repeating: Array(repeating: 0, count: polished.count + 1),
        count: raw.count + 1
    )

    for i in stride(from: raw.count - 1, through: 0, by: -1) {
        for j in stride(from: polished.count - 1, through: 0, by: -1) {
            if !raw[i].isEmpty, raw[i] == polished[j] {
                table[i][j] = table[i + 1][j + 1] + 1
            } else {
                table[i][j] = max(table[i + 1][j], table[i][j + 1])
            }
        }
    }

    var matches: [LCSMatch] = []
    var i = 0
    var j = 0
    while i < raw.count, j < polished.count {
        if !raw[i].isEmpty, raw[i] == polished[j] {
            matches.append(LCSMatch(raw: i, polished: j))
            i += 1
            j += 1
        } else if table[i + 1][j] >= table[i][j + 1] {
            i += 1
        } else {
            j += 1
        }
    }
    return matches
}
