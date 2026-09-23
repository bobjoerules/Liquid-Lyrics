import Foundation

struct LyricLetter: Identifiable, Hashable {
    let id = UUID()
    let char: String
    let startMs: Int
    let endMs: Int
}

struct LyricWord: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let startMs: Int
    let endMs: Int
    let isPartOfWord: Bool
    let isLetterGroup: Bool
    let letters: [LyricLetter]

    var duration: Int {
        max(endMs - startMs, 1)
    }
}

struct SpicyWordGroup: Identifiable, Hashable {
    let id: String
    let words: [LyricWord]
    let hasTrailingSpace: Bool

    init(words: [LyricWord], hasTrailingSpace: Bool) {
        self.words = words
        self.hasTrailingSpace = hasTrailingSpace
        self.id = words.first.map { "\($0.id.uuidString)_\($0.startMs)" } ?? UUID().uuidString
    }
}

func groupSpicyWords(_ words: [LyricWord]) -> [SpicyWordGroup] {
    var groups: [SpicyWordGroup] = []
    var current: [LyricWord] = []

    for (index, word) in words.enumerated() {
        current.append(word)
        let isLast = index == words.count - 1
        if !word.isPartOfWord || isLast {
            groups.append(SpicyWordGroup(words: current, hasTrailingSpace: !isLast))
            current = []
        }
    }
    if !current.isEmpty {
        groups.append(SpicyWordGroup(words: current, hasTrailingSpace: false))
    }
    return groups
}

struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let words: [LyricWord]
    let wordGroups: [SpicyWordGroup]
    let startMs: Int
    let lineEndMs: Int?
    let isWordSynced: Bool
    let agent: String?
    let isBackground: Bool
    let oppositeAligned: Bool
    let isSongwriter: Bool
    let isInterlude: Bool
    let interludeEndMs: Int
    let translation: String?
    let romanization: String?
    let rawText: String?

    init(
        words: [LyricWord] = [],
        startMs: Int,
        lineEndMs: Int? = nil,
        isWordSynced: Bool = true,
        agent: String? = nil,
        isBackground: Bool = false,
        oppositeAligned: Bool = false,
        isSongwriter: Bool = false,
        isInterlude: Bool = false,
        interludeEndMs: Int = -1,
        translation: String? = nil,
        romanization: String? = nil,
        rawText: String? = nil
    ) {
        self.words = words
        self.wordGroups = groupSpicyWords(words)
        self.startMs = startMs
        self.lineEndMs = lineEndMs
        self.isWordSynced = isWordSynced
        self.agent = agent
        self.isBackground = isBackground
        self.oppositeAligned = oppositeAligned
        self.isSongwriter = isSongwriter
        self.isInterlude = isInterlude
        self.interludeEndMs = interludeEndMs
        self.translation = translation
        self.romanization = romanization
        self.rawText = rawText
    }

    var endMs: Int {
        if isInterlude, interludeEndMs > 0 {
            return interludeEndMs
        }
        if let lineEndMs = lineEndMs, lineEndMs > 0 {
            return lineEndMs
        }
        return words.last?.endMs ?? startMs
    }

    var duration: Int {
        max(endMs - startMs, 1)
    }

    var displayText: String {
        if isInterlude {
            return "• • •"
        }

        if let rawText = rawText, !rawText.isEmpty {
            return rawText
        }

        if words.isEmpty {
            return isSongwriter ? "Written by" : ""
        }

        var result = ""
        for word in words {
            let clean = word.text.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            if !result.isEmpty && !word.isPartOfWord {
                result += " "
            }
            result += clean
        }
        return result
    }
}

struct SpicyAttributionUser: Hashable {
    let id: String?
    let username: String?
    let avatar: String?
    let url: String?
}

struct SpicyUploadAttribution: Hashable {
    let uploader: SpicyAttributionUser?
    let maker: SpicyAttributionUser?
}

struct ParsedLyrics {
    let lines: [LyricLine]
    let songwriters: [String]
    let source: String?
    let attribution: SpicyUploadAttribution?

    init(lines: [LyricLine], songwriters: [String], source: String? = nil, attribution: SpicyUploadAttribution? = nil) {
        self.lines = lines
        self.songwriters = songwriters
        self.source = source
        self.attribution = attribution
    }
}

struct ImportedTrack: Identifiable, Hashable {
    let baseName: String
    let title: String
    let artist: String
    let audioURL: URL
    let lyricsURL: URL?

    var id: String {
        baseName.lowercased()
    }

    var hasLyrics: Bool {
        lyricsURL != nil
    }
}

struct TrackOverride: Codable {
    var title: String?
    var artist: String?
}

extension String {
    var splitArtistNames: [String] {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ["Unknown Artist"] }
        
        // Special-case common artist names with commas
        if trimmed.caseInsensitiveCompare("Tyler, The Creator") == .orderedSame {
            return ["Tyler, The Creator"]
        }
        
        // Split on common artist separators:
        // 1. Commas or semicolons: "," / ";"
        // 2. Slashes or backslashes with spaces: " / " or " \ "
        // 3. Ampersand with spaces: " & "
        // 4. Feature keywords: feat., feat, ft., ft, featuring, with, x (case-insensitive with whitespace)
        let pattern = #"(?:\s*[,;]\s*|\s+(?:/|\\|&|(?i:feat\.?|ft\.?|featuring|with|x))\s+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [trimmed]
        }
        
        let nsString = trimmed as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: trimmed, range: range)
        
        var results: [String] = []
        var lastEnd = 0
        
        for match in matches {
            let start = match.range.location
            if start > lastEnd {
                let substring = nsString.substring(with: NSRange(location: lastEnd, length: start - lastEnd))
                let clean = substring.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && !results.contains(clean) {
                    results.append(clean)
                }
            }
            lastEnd = match.range.location + match.range.length
        }
        
        if lastEnd < nsString.length {
            let substring = nsString.substring(with: NSRange(location: lastEnd, length: nsString.length - lastEnd))
            let clean = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !results.contains(clean) {
                results.append(clean)
            }
        }
        
        // Re-combine Tyler + The Creator if split by comma
        var combined: [String] = []
        var skipNext = false
        for i in 0..<results.count {
            if skipNext {
                skipNext = false
                continue
            }
            if results[i].localizedCaseInsensitiveCompare("Tyler") == .orderedSame &&
                i + 1 < results.count &&
                results[i + 1].localizedCaseInsensitiveCompare("The Creator") == .orderedSame {
                combined.append("Tyler, The Creator")
                skipNext = true
            } else {
                combined.append(results[i])
            }
        }
        
        return combined.isEmpty ? [trimmed] : combined
    }
}
