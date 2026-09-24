import Foundation

// MARK: - Spicy Lyrics API Decodable Models

struct SpicyLyricsEnvelope: Codable {
    let Body: SpicyLyricsBody?
    let Status: Int
    let type: String?

    enum CodingKeys: String, CodingKey {
        case Body
        case Status
        case type = "Type"
    }
}

struct SpicyLyricsBody: Codable {
    let id: String?
    let source: String?
    let SongWriters: [String]?
    let type: String? // "Syllable", "Line", "Static"
    let StartTime: Double?
    let EndTime: Double?
    let Content: [SpicyContentLine]?
    let UploadAttribution: SpicyUploadAttributionDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case SongWriters
        case type = "Type"
        case StartTime
        case EndTime
        case Content
        case UploadAttribution
    }
}

struct SpicyUploadAttributionDTO: Codable {
    let Uploader: SpicyAttributionUserDTO?
    let Maker: SpicyAttributionUserDTO?
}

struct SpicyAttributionUserDTO: Codable {
    let id: String?
    let username: String?
    let avatar: String?
    let hasProfileBanner: Bool?
    let url: String?
}

struct SpicyContentLine: Codable {
    let type: String?
    let OppositeAligned: Bool?
    let agent: String?
    let Lead: SpicyVocalGroup?
    let Background: [SpicyVocalGroup]?
    
    // For Line-level lyrics
    let StartTime: Double?
    let EndTime: Double?
    let Text: String?
    let TransliteratedText: String?
    let TranslatedText: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case OppositeAligned
        case agent
        case Lead
        case Background
        case StartTime
        case EndTime
        case Text
        case TransliteratedText
        case TranslatedText
    }
}

struct SpicyVocalGroup: Codable {
    let StartTime: Double?
    let EndTime: Double?
    let OppositeAligned: Bool?
    let TransliteratedText: String?
    let TranslatedText: String?
    let Syllables: [SpicySyllable]?
}

struct SpicySyllable: Codable {
    let Text: String
    let StartTime: Double
    let EndTime: Double
    let IsPartOfWord: Bool?
    let TransliteratedText: String?
}

// MARK: - Service Implementation

actor SpicyLyricsService {
    static let shared = SpicyLyricsService()
    
    private var cache: [String: ParsedLyrics] = [:]
    private var inFlightTasks: [String: Task<ParsedLyrics, Error>] = [:]

    func getCachedLyrics(for trackId: String) -> ParsedLyrics? {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        return cache[cleanId]
    }

    func isLyricsCached(for trackId: String) -> Bool {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        return cache[cleanId] != nil
    }

    func prefetchLyrics(for trackId: String) async {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }
        if cache[cleanId] != nil { return }
        _ = try? await fetchLyrics(for: cleanId)
    }

    func prefetchLyrics(for trackIds: [String]) async {
        for id in trackIds.prefix(5) {
            await prefetchLyrics(for: id)
        }
    }

    func fetchLyrics(for trackId: String) async throws -> ParsedLyrics {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw NSError(domain: "LiquidPlayer.SpicyLyrics", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid track ID."])
        }

        if let cached = cache[cleanId] {
            return cached
        }

        // Deduplicate in-flight requests for the same track
        if let existingTask = inFlightTasks[cleanId] {
            return try await existingTask.value
        }

        let task = Task<ParsedLyrics, Error> {
            guard let url = URL(string: "https://api.spicylyrics.org/v1/lyrics/\(cleanId)") else {
                throw NSError(domain: "LiquidPlayer.SpicyLyrics", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL."])
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(APIConfig.spicyLyricsApiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "LiquidPlayer.SpicyLyrics", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network error"])
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    throw NSError(domain: "LiquidPlayer.SpicyLyrics", code: 404, userInfo: [NSLocalizedDescriptionKey: "Lyrics not found for this track."])
                }
                if httpResponse.statusCode == 503 {
                    throw NSError(domain: "LiquidPlayer.SpicyLyrics", code: 503, userInfo: [NSLocalizedDescriptionKey: "Upstream lyrics service temporarily unavailable."])
                }
                throw NSError(domain: "LiquidPlayer.SpicyLyrics", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
            }

            let envelope = try JSONDecoder().decode(SpicyLyricsEnvelope.self, from: data)
            guard let body = envelope.Body else {
                throw NSError(domain: "LiquidPlayer.SpicyLyrics", code: -2, userInfo: [NSLocalizedDescriptionKey: "Empty lyrics response"])
            }

            let parsed = self.parseLyricsBody(body)
            return parsed
        }

        inFlightTasks[cleanId] = task

        do {
            let result = try await task.value
            inFlightTasks.removeValue(forKey: cleanId)
            cache[cleanId] = result
            return result
        } catch {
            inFlightTasks.removeValue(forKey: cleanId)
            throw error
        }
    }

    private func parseLyricsBody(_ body: SpicyLyricsBody) -> ParsedLyrics {
        let songwriters = body.SongWriters ?? []
        var lines: [LyricLine] = []

        let syncType = body.type ?? "Syllable"

        if let contentLines = body.Content {
            for contentLine in contentLines {
                if syncType == "Line" || contentLine.Lead == nil {
                    // Line-level: show line directly without fake word timings
                    let text = contentLine.Text ?? ""
                    let startMs = Int((contentLine.StartTime ?? 0.0) * 1000.0)
                    let endMs = Int((contentLine.EndTime ?? (Double(startMs) / 1000.0 + 3.0)) * 1000.0)
                    let opposite = contentLine.OppositeAligned ?? (contentLine.agent != nil && contentLine.agent != "1" && contentLine.agent != "v1")

                    lines.append(
                        LyricLine(
                            words: [],
                            startMs: startMs,
                            lineEndMs: endMs,
                            isWordSynced: false,
                            agent: contentLine.agent,
                            isBackground: false,
                            oppositeAligned: opposite,
                            isSongwriter: false,
                            isInterlude: false,
                            interludeEndMs: -1,
                            translation: contentLine.TranslatedText,
                            romanization: contentLine.TransliteratedText,
                            rawText: text
                        )
                    )
                } else if let lead = contentLine.Lead {
                    // Syllable-level precision
                    let opposite = contentLine.OppositeAligned ?? contentLine.Lead?.OppositeAligned ?? (contentLine.agent != nil && contentLine.agent != "1" && contentLine.agent != "v1")
                    let startMs = Int((lead.StartTime ?? 0.0) * 1000.0)
                    
                    var words: [LyricWord] = []
                    if let syllables = lead.Syllables {
                        for (sylIndex, syl) in syllables.enumerated() {
                            let sylStart = Int(syl.StartTime * 1000.0)
                            let sylEnd = Int(syl.EndTime * 1000.0)
                            let rawToken = syl.Text
                            let trimmedToken = rawToken.trimmingCharacters(in: .whitespaces)
                            guard !trimmedToken.isEmpty else { continue }

                            let hasLeadingSpace = rawToken.hasPrefix(" ")
                            let isPart = (syl.IsPartOfWord ?? false) && !hasLeadingSpace
                            let duration = max(sylEnd - sylStart, 1)

                            let isLetterGroup = duration >= 1000 && trimmedToken.count > 1
                            let letters: [LyricLetter]
                            if isLetterGroup {
                                let count = max(trimmedToken.count, 1)
                                let letterDur = Double(duration) / Double(count)
                                letters = trimmedToken.enumerated().map { off, char in
                                    LyricLetter(
                                        char: String(char),
                                        startMs: sylStart + Int(Double(off) * letterDur),
                                        endMs: off == count - 1 ? sylEnd : sylStart + Int(Double(off + 1) * letterDur)
                                    )
                                }
                            } else {
                                letters = []
                            }

                            words.append(
                                LyricWord(
                                    text: trimmedToken,
                                    startMs: sylStart,
                                    endMs: sylEnd,
                                    isPartOfWord: isPart,
                                    isLetterGroup: isLetterGroup,
                                    letters: letters
                                )
                            )
                        }
                    }

                    lines.append(
                        LyricLine(
                            words: words,
                            startMs: startMs,
                            agent: nil,
                            isBackground: false,
                            oppositeAligned: opposite,
                            isSongwriter: false,
                            isInterlude: false,
                            interludeEndMs: -1,
                            translation: lead.TranslatedText,
                            romanization: lead.TransliteratedText
                        )
                    )

                    // Background vocals if present
                    if let bgList = contentLine.Background {
                        for bg in bgList {
                            let bgStart = Int((bg.StartTime ?? Double(startMs) / 1000.0) * 1000.0)
                            var bgWords: [LyricWord] = []
                            if let bgSyllables = bg.Syllables {
                                for (sylIndex, syl) in bgSyllables.enumerated() {
                                    let sStart = Int(syl.StartTime * 1000.0)
                                    let sEnd = Int(syl.EndTime * 1000.0)
                                    let rawToken = syl.Text
                                    let trimmedToken = rawToken.trimmingCharacters(in: .whitespaces)
                                    guard !trimmedToken.isEmpty else { continue }
                                    let hasLeadingSpace = rawToken.hasPrefix(" ")
                                    let isPart = (syl.IsPartOfWord ?? false) && !hasLeadingSpace
                                    bgWords.append(
                                        LyricWord(
                                            text: trimmedToken,
                                            startMs: sStart,
                                            endMs: sEnd,
                                            isPartOfWord: isPart,
                                            isLetterGroup: false,
                                            letters: []
                                        )
                                    )
                                }
                            }
                            if !bgWords.isEmpty {
                                let actualStart = bgWords.first?.startMs ?? bgStart
                                let actualEnd = bg.EndTime.map { Int($0 * 1000.0) } ?? bgWords.last?.endMs ?? actualStart
                                let hasWordTimings = bgWords.count > 1 ? Set(bgWords.map(\.startMs)).count > 1 : true
                                lines.append(
                                    LyricLine(
                                        words: bgWords,
                                        startMs: actualStart,
                                        lineEndMs: actualEnd,
                                        isWordSynced: hasWordTimings,
                                        agent: nil,
                                        isBackground: true,
                                        oppositeAligned: opposite,
                                        isSongwriter: false,
                                        isInterlude: false,
                                        interludeEndMs: -1,
                                        translation: bg.TranslatedText,
                                        romanization: bg.TransliteratedText
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }


        // Interlude dot lines (matching AMLL-TTML-TOOL dotLine algorithm)
        let mainLines = lines
            .filter { !$0.isBackground && !$0.isSongwriter }
            .sorted { $0.startMs < $1.startMs }

        var dotLines: [LyricLine] = []
        if let first = mainLines.first, first.startMs >= 3000 {
            let total = first.startMs
            let base = Double(total) / 3.0
            let firstEnd = max(0, Int(base - 550.0 / 3.0))
            let secondEnd = max(firstEnd, Int(base * 2.0 - (550.0 * 2.0) / 3.0))
            let thirdEnd = max(secondEnd, first.startMs - 550)

            let dotWords = [
                LyricWord(text: "•", startMs: 0, endMs: firstEnd, isPartOfWord: false, isLetterGroup: false, letters: []),
                LyricWord(text: "•", startMs: firstEnd, endMs: secondEnd, isPartOfWord: false, isLetterGroup: false, letters: []),
                LyricWord(text: "•", startMs: secondEnd, endMs: thirdEnd, isPartOfWord: false, isLetterGroup: false, letters: [])
            ]

            dotLines.append(
                LyricLine(
                    words: dotWords,
                    startMs: 0,
                    agent: first.agent,
                    isBackground: false,
                    oppositeAligned: first.oppositeAligned,
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
                let nextLine = mainLines[index + 1]
                let gapEnd = nextLine.startMs
                if gapEnd - gapStart >= 3000 {
                    let total = gapEnd - gapStart
                    let base = Double(total) / 3.0
                    let firstEnd = max(gapStart, gapStart + Int(base - 550.0 / 3.0))
                    let secondEnd = max(firstEnd, gapStart + Int(base * 2.0 - (550.0 * 2.0) / 3.0))
                    let thirdEnd = max(secondEnd, gapEnd - 550)

                    let dotWords = [
                        LyricWord(text: "•", startMs: gapStart, endMs: firstEnd, isPartOfWord: false, isLetterGroup: false, letters: []),
                        LyricWord(text: "•", startMs: firstEnd, endMs: secondEnd, isPartOfWord: false, isLetterGroup: false, letters: []),
                        LyricWord(text: "•", startMs: secondEnd, endMs: thirdEnd, isPartOfWord: false, isLetterGroup: false, letters: [])
                    ]

                    dotLines.append(
                        LyricLine(
                            words: dotWords,
                            startMs: gapStart,
                            agent: nextLine.agent,
                            isBackground: false,
                            oppositeAligned: nextLine.oppositeAligned,
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

        let sortedAll = (lines + dotLines).sorted {
            if $0.startMs == $1.startMs {
                if $0.isInterlude != $1.isInterlude {
                    return $0.isInterlude && !$1.isInterlude
                }
                if $0.isBackground != $1.isBackground {
                    return !$0.isBackground && $1.isBackground
                }
            }
            return $0.startMs < $1.startMs
        }

        var attribution: SpicyUploadAttribution? = nil
        if let uploadAttr = body.UploadAttribution {
            let uploader = uploadAttr.Uploader.map {
                SpicyAttributionUser(id: $0.id, username: $0.username, avatar: $0.avatar, url: $0.url)
            }
            let maker = uploadAttr.Maker.map {
                SpicyAttributionUser(id: $0.id, username: $0.username, avatar: $0.avatar, url: $0.url)
            }
            attribution = SpicyUploadAttribution(uploader: uploader, maker: maker)
        }

        return ParsedLyrics(
            lines: sortedAll,
            songwriters: songwriters,
            source: body.source,
            attribution: attribution
        )
    }
}
