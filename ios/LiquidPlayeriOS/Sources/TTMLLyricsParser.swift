import Foundation

enum TTMLLyricsParser {
    static func parse(data: Data) throws -> ParsedLyrics {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate

        guard parser.parse() else {
            throw delegate.error ?? parser.parserError ?? NSError(
                domain: "LiquidPlayeriOS.TTMLParser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse TTML lyrics."]
            )
        }

        return delegate.result()
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    struct SpanContext {
        let begin: Int?
        let end: Int?
        let isBackground: Bool
        let isTranslation: Bool
        let isRoman: Bool
    }

    var lines: [LyricLine] = []
    var songwriters: [String] = []
    var error: Error?

    private var defaultAgent: String?
    private var inSongwriter = false
    private var currentParagraph: ParagraphState?

    func result() -> ParsedLyrics {
        var allLines = lines

        if !songwriters.isEmpty {
            let lastLineEnd = allLines.map(\.endMs).max() ?? 0
            let text = "Written by \(songwriters.joined(separator: ", "))"
            let tokens = text.split(separator: " ").map(String.init)
            let words = tokens.map { token in
                LyricWord(
                    text: token,
                    startMs: lastLineEnd,
                    endMs: lastLineEnd + 1000,
                    isPartOfWord: false,
                    isLetterGroup: false,
                    letters: []
                )
            }

            allLines.append(
                LyricLine(
                    words: words,
                    startMs: lastLineEnd,
                    agent: nil,
                    isBackground: false,
                    oppositeAligned: false,
                    isSongwriter: true,
                    isInterlude: false,
                    interludeEndMs: -1,
                    translation: nil,
                    romanization: nil
                )
            )
        }

        let mainLines = allLines
            .filter { !$0.isBackground && !$0.isSongwriter }
            .sorted { $0.startMs < $1.startMs }

        var interludes: [LyricLine] = []
        if let first = mainLines.first, first.startMs >= 3000 {
            interludes.append(
                LyricLine(
                    words: [],
                    startMs: 0,
                    agent: nil,
                    isBackground: false,
                    oppositeAligned: false,
                    isSongwriter: false,
                    isInterlude: true,
                    interludeEndMs: first.startMs,
                    translation: nil,
                    romanization: nil
                )
            )
        }

        if mainLines.count >= 2 {
            for index in 0..<(mainLines.count - 1) {
                let gapStart = mainLines[index].endMs
                let gapEnd = mainLines[index + 1].startMs
                if gapEnd - gapStart >= 3000 {
                    interludes.append(
                        LyricLine(
                            words: [],
                            startMs: gapStart,
                            agent: nil,
                            isBackground: false,
                            oppositeAligned: false,
                            isSongwriter: false,
                            isInterlude: true,
                            interludeEndMs: gapEnd,
                            translation: nil,
                            romanization: nil
                        )
                    )
                }
            }
        }

        allLines.append(contentsOf: interludes)
        allLines.sort { $0.startMs < $1.startMs }

        return ParsedLyrics(lines: allLines, songwriters: songwriters)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedName(elementName, qName)

        switch name {
        case "songwriter":
            inSongwriter = true
        case "agent":
            let identifier = attributeDict["xml:id"] ?? attributeDict["id"]
            if identifier == "v1" {
                defaultAgent = identifier
            }
        case "p":
            let agent = attributeDict["agent"] ?? attributeDict["ttm:agent"]
            if defaultAgent == nil, let agent {
                defaultAgent = agent
            }
            currentParagraph = ParagraphState(
                beginMs: parseTimeMs(attributeDict["begin"]) ?? 0,
                endMs: parseTimeMs(attributeDict["end"]) ?? 0,
                agent: agent,
                defaultAgent: defaultAgent
            )
        case "span":
            currentParagraph?.pushSpan(attributes: attributeDict)
        case "br":
            currentParagraph?.insertLineBreak()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSongwriter {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                songwriters.append(trimmed)
            }
            return
        }

        currentParagraph?.appendText(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedName(elementName, qName)

        switch name {
        case "songwriter":
            inSongwriter = false
        case "span":
            currentParagraph?.popSpan()
        case "p":
            if var paragraph = currentParagraph {
                paragraph.flushPendingText()
                lines.append(contentsOf: paragraph.makeLines())
            }
            currentParagraph = nil
        default:
            break
        }
    }

    private func normalizedName(_ elementName: String, _ qName: String?) -> String {
        let raw = qName ?? elementName
        return raw.split(separator: ":").last.map(String.init) ?? raw
    }
}

private struct ParagraphState {
    let beginMs: Int
    let endMs: Int
    let agent: String?
    let defaultAgent: String?

    private(set) var leadLines: [[LyricWord]] = [[]]
    private(set) var backgroundGroups: [[LyricWord]] = []
    private(set) var currentTranslation = ""
    private(set) var currentRomanization = ""
    private var stack: [ParserDelegate.SpanContext]
    private var previousEndedMidWord = false
    private var currentBackgroundGroup: [LyricWord]?
    private var inBackgroundSpan = false
    private var backgroundPreviousEndedMidWord = false
    private var pendingText = ""

    init(beginMs: Int, endMs: Int, agent: String?, defaultAgent: String?) {
        self.beginMs = beginMs
        self.endMs = endMs
        self.agent = agent
        self.defaultAgent = defaultAgent
        self.stack = [ParserDelegate.SpanContext(begin: beginMs, end: endMs, isBackground: false, isTranslation: false, isRoman: false)]
    }

    mutating func pushSpan(attributes: [String: String]) {
        flushPendingText()
        let inherited = stack.last ?? ParserDelegate.SpanContext(begin: beginMs, end: endMs, isBackground: false, isTranslation: false, isRoman: false)
        let begin = parseTimeMs(attributes["begin"]) ?? inherited.begin
        let end = parseTimeMs(attributes["end"]) ?? inherited.end
        let role = attributes["role"] ?? attributes["ttm:role"]
        let isBackground = role == "x-bg" || inherited.isBackground
        let isTranslation = role == "x-translation" || inherited.isTranslation
        let isRoman = role == "x-roman" || inherited.isRoman

        if isBackground && currentBackgroundGroup == nil {
            currentBackgroundGroup = []
            backgroundPreviousEndedMidWord = false
        }

        inBackgroundSpan = isBackground
        stack.append(ParserDelegate.SpanContext(begin: begin, end: end, isBackground: isBackground, isTranslation: isTranslation, isRoman: isRoman))
    }

    mutating func popSpan() {
        guard !stack.isEmpty else {
            return
        }

        flushPendingText()
        let popped = stack.removeLast()
        let nextIsBackground = stack.last?.isBackground ?? false
        if popped.isBackground && !nextIsBackground {
            if let currentBackgroundGroup, !currentBackgroundGroup.isEmpty {
                backgroundGroups.append(currentBackgroundGroup)
            }
            self.currentBackgroundGroup = nil
            inBackgroundSpan = false
        } else {
            inBackgroundSpan = nextIsBackground
        }
    }

    mutating func insertLineBreak() {
        flushPendingText()

        if inBackgroundSpan {
            if let currentBackgroundGroup, !currentBackgroundGroup.isEmpty {
                backgroundGroups.append(currentBackgroundGroup)
                self.currentBackgroundGroup = []
            }
            backgroundPreviousEndedMidWord = false
            return
        }

        if let currentLine = leadLines.last, !currentLine.isEmpty {
            leadLines.append([])
        }
        previousEndedMidWord = false
    }

    mutating func appendText(_ rawText: String) {
        pendingText += rawText
    }

    mutating func flushPendingText() {
        let rawText = pendingText
        pendingText = ""

        let context = stack.last ?? ParserDelegate.SpanContext(begin: beginMs, end: endMs, isBackground: false, isTranslation: false, isRoman: false)
        let isBackgroundToken = context.isBackground || inBackgroundSpan

        if context.isTranslation {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !currentTranslation.isEmpty {
                    currentTranslation += " "
                }
                currentTranslation += trimmed
            }
            return
        }

        if context.isRoman {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !currentRomanization.isEmpty {
                    currentRomanization += " "
                }
                currentRomanization += trimmed
            }
            return
        }

        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let startsWithSpace = rawText.first?.isWhitespace == true
        let endsWithSpace = rawText.last?.isWhitespace == true
        var trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isBackgroundToken {
            trimmed = trimmed.replacingOccurrences(of: #"^\("#, with: "", options: .regularExpression)
            trimmed = trimmed.replacingOccurrences(of: #"\)$"#, with: "", options: .regularExpression)
        }

        if trimmed.isEmpty {
            return
        }

        let spaceTokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        var wordsToAdd: [(String, Bool)] = []
        for (tokenIndex, token) in spaceTokens.enumerated() {
            let subTokens = splitKeepingTrailingHyphen(token)
            for (subIndex, subToken) in subTokens.enumerated() {
                let isLastSub = subIndex == subTokens.count - 1
                let isLastToken = tokenIndex == spaceTokens.count - 1

                let isPartOfWord: Bool
                if !isLastSub {
                    // Ends with hyphen or split mid-token: continues into next syllable
                    isPartOfWord = true
                } else if !isLastToken {
                    // Followed by whitespace within the same span: completes word
                    isPartOfWord = false
                } else {
                    // Last token in the span: continues if the span does NOT end with whitespace
                    isPartOfWord = !endsWithSpace
                }
                wordsToAdd.append((subToken, isPartOfWord))
            }
        }

        let start = context.begin ?? beginMs
        let end = context.end ?? (start + 1000)
        let duration = max(end - start, 0)
        let chunkDuration = wordsToAdd.isEmpty ? duration : duration / wordsToAdd.count

        for (index, entry) in wordsToAdd.enumerated() {
            let wordStart = start + (index * chunkDuration)
            let wordEnd = index == wordsToAdd.count - 1 ? end : start + ((index + 1) * chunkDuration)
            let wordDuration = wordEnd - wordStart
            let token = entry.0
            let isLetterGroup = wordDuration >= 1000 && token.count > 1

            let letters: [LyricLetter]
            if isLetterGroup {
                let count = max(token.count, 1)
                let letterDuration = Double(wordDuration) / Double(count)
                letters = token.enumerated().map { offset, character in
                    LyricLetter(
                        char: String(character),
                        startMs: wordStart + Int(Double(offset) * letterDuration),
                        endMs: offset == count - 1 ? wordEnd : wordStart + Int(Double(offset + 1) * letterDuration)
                    )
                }
            } else {
                letters = []
            }

            let word = LyricWord(
                text: token,
                startMs: wordStart,
                endMs: wordEnd,
                isPartOfWord: entry.1,
                isLetterGroup: isLetterGroup,
                letters: letters
            )

            if isBackgroundToken {
                currentBackgroundGroup?.append(word)
            } else {
                if leadLines.isEmpty {
                    leadLines = [[]]
                }
                leadLines[leadLines.count - 1].append(word)
            }
        }

        if isBackgroundToken {
            backgroundPreviousEndedMidWord = !endsWithSpace
        } else {
            previousEndedMidWord = !endsWithSpace
        }
    }

    func makeLines() -> [LyricLine] {
        let oppositeAligned = agent != nil && defaultAgent != nil && agent != defaultAgent
        var result: [LyricLine] = []

        for words in leadLines where !words.isEmpty {
            let hasWordTimings = words.count > 1 && Set(words.map(\.startMs)).count > 1
            result.append(
                LyricLine(
                    words: words,
                    startMs: words.first?.startMs ?? beginMs,
                    lineEndMs: endMs,
                    isWordSynced: hasWordTimings,
                    agent: agent,
                    isBackground: false,
                    oppositeAligned: oppositeAligned,
                    isSongwriter: false,
                    isInterlude: false,
                    interludeEndMs: -1,
                    translation: currentTranslation.isEmpty ? nil : currentTranslation,
                    romanization: currentRomanization.isEmpty ? nil : currentRomanization
                )
            )
        }

        for group in backgroundGroups {
            let groupStart = group.first?.startMs ?? beginMs
            let groupEnd = group.last?.endMs ?? endMs
            let hasWordTimings = group.count > 1 ? Set(group.map(\.startMs)).count > 1 : true
            result.append(
                LyricLine(
                    words: group,
                    startMs: groupStart,
                    lineEndMs: groupEnd,
                    isWordSynced: hasWordTimings,
                    agent: agent,
                    isBackground: true,
                    oppositeAligned: oppositeAligned,
                    isSongwriter: false,
                    isInterlude: false,
                    interludeEndMs: -1,
                    translation: nil,
                    romanization: nil
                )
            )
        }

        return result
    }

    private func splitKeepingTrailingHyphen(_ token: String) -> [String] {
        var result: [String] = []
        var current = ""
        for char in token {
            current.append(char)
            if char == "-" || char == "–" || char == "—" || char == "/" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}

private func parseTimeMs(_ time: String?) -> Int? {
    guard let time else {
        return nil
    }

    var trimmed = time.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    
    // Check if it's an offset-time ending in "ms"
    if trimmed.hasSuffix("ms") {
        let valueString = trimmed.dropLast(2)
        if let msValue = Double(valueString) {
            return Int(msValue.rounded())
        }
        return nil
    }
    
    // Check other suffix endings like "s", "m", "h"
    var scale: Double = 1000.0 // default is seconds if it's just a number
    if trimmed.hasSuffix("s") {
        trimmed = String(trimmed.dropLast())
        scale = 1000.0
    } else if trimmed.hasSuffix("m") {
        trimmed = String(trimmed.dropLast())
        scale = 60.0 * 1000.0
    } else if trimmed.hasSuffix("h") {
        trimmed = String(trimmed.dropLast())
        scale = 3600.0 * 1000.0
    }

    let parts = trimmed.split(separator: ":").map(String.init)
    
    if parts.count == 1 {
        // Just seconds/fraction or a raw number
        if let val = Double(parts[0]) {
            return Int((val * scale).rounded())
        }
        return nil
    }
    
    if parts.count == 2 {
        // mm:ss.ms
        let minutes = Int(parts[0]) ?? 0
        let secondsParts = parts[1].split(separator: ".", maxSplits: 1).map(String.init)
        let seconds = Int(secondsParts[0]) ?? 0
        let milliseconds = secondsParts.count > 1 ? paddedMilliseconds(secondsParts[1]) : 0
        return ((minutes * 60) + seconds) * 1000 + milliseconds
    }

    if parts.count == 3 {
        // hh:mm:ss.ms
        let hours = Int(parts[0]) ?? 0
        let minutes = Int(parts[1]) ?? 0
        let secondsParts = parts[2].split(separator: ".", maxSplits: 1).map(String.init)
        let seconds = Int(secondsParts[0]) ?? 0
        let milliseconds = secondsParts.count > 1 ? paddedMilliseconds(secondsParts[1]) : 0
        return ((hours * 3600) + (minutes * 60) + seconds) * 1000 + milliseconds
    }

    return nil
}

private func paddedMilliseconds(_ raw: String) -> Int {
    let prefix = String(raw.prefix(3))
    let padded = prefix.padding(toLength: 3, withPad: "0", startingAt: 0)
    return Int(padded) ?? 0
}

// MARK: - TTML Exporter
enum TTMLExporter {
    static func export(
        lines: [LyricLine],
        songwriters: [String] = [],
        title: String? = nil,
        artist: String? = nil
    ) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\">\n"
        xml += "  <head>\n"
        xml += "    <metadata>\n"
        if let title = title, !title.isEmpty {
            xml += "      <ttm:title>\(xmlEscape(title))</ttm:title>\n"
        }
        if let artist = artist, !artist.isEmpty {
            xml += "      <ttm:agent type=\"person\">\(xmlEscape(artist))</ttm:agent>\n"
        }
        for songwriter in songwriters {
            xml += "      <songwriter>\(xmlEscape(songwriter))</songwriter>\n"
        }
        xml += "    </metadata>\n"
        xml += "  </head>\n"
        xml += "  <body>\n"
        xml += "    <div>\n"

        let regularLines = lines.filter { !$0.isSongwriter && !$0.isInterlude }
        for line in regularLines {
            let start = formatTime(ms: line.startMs)
            let end = formatTime(ms: line.endMs)
            let agentAttr = line.agent.map { " agent=\"\(xmlEscape($0))\"" } ?? ""
            let backgroundAttr = line.isBackground ? " ttm:role=\"background\"" : ""

            xml += "      <p begin=\"\(start)\" end=\"\(end)\"\(agentAttr)\(backgroundAttr)>\n"

            if line.isWordSynced && !line.words.isEmpty {
                for (wIndex, word) in line.words.enumerated() {
                    let wStart = formatTime(ms: word.startMs)
                    let wEnd = formatTime(ms: word.endMs)
                    let isLast = wIndex == line.words.count - 1
                    let trailing = (!isLast && !word.isPartOfWord && !word.text.hasSuffix("-")) ? " " : ""
                    xml += "        <span begin=\"\(wStart)\" end=\"\(wEnd)\">\(xmlEscape(word.text))\(trailing)</span>\n"
                }
            } else {
                xml += "        <span>\(xmlEscape(line.displayText))</span>\n"
            }

            if let trans = line.translation, !trans.isEmpty {
                xml += "        <span ttm:role=\"translation\">\(xmlEscape(trans))</span>\n"
            }
            if let rom = line.romanization, !rom.isEmpty {
                xml += "        <span ttm:role=\"romanization\">\(xmlEscape(rom))</span>\n"
            }

            xml += "      </p>\n"
        }

        xml += "    </div>\n"
        xml += "  </body>\n"
        xml += "</tt>\n"
        return xml
    }

    static func export(
        parsed: ParsedLyrics,
        title: String? = nil,
        artist: String? = nil
    ) -> String {
        return export(
            lines: parsed.lines,
            songwriters: parsed.songwriters,
            title: title,
            artist: artist
        )
    }

    private static func formatTime(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let milliseconds = max(0, ms) % 1000
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    private static func xmlEscape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

