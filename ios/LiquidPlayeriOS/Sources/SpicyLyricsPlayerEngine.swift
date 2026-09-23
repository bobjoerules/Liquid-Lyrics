import SwiftUI

// MARK: - Natural Cubic Spline (matching AMLL-TTML-TOOL math.ts)

final class CubicSpline {
    private let a: [Double]
    private var b: [Double] = []
    private var c: [Double] = []
    private var d: [Double] = []
    private let xs: [Double]

    init(points: [(Double, Double)]) {
        self.xs = points.map { $0.0 }
        self.a = points.map { $0.1 }
        let n = points.count - 1
        guard n > 0 else { return }

        var h = [Double](repeating: 0, count: n)
        for i in 0..<n {
            h[i] = xs[i + 1] - xs[i]
        }

        var alpha = [Double](repeating: 0, count: n)
        for i in 1..<n {
            alpha[i] = (3.0 / h[i]) * (a[i + 1] - a[i]) - (3.0 / h[i - 1]) * (a[i] - a[i - 1])
        }

        var l = [Double](repeating: 0, count: n + 1)
        var mu = [Double](repeating: 0, count: n + 1)
        var z = [Double](repeating: 0, count: n + 1)
        l[0] = 1.0
        for i in 1..<n {
            l[i] = 2.0 * (xs[i + 1] - xs[i - 1]) - h[i - 1] * mu[i - 1]
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }
        l[n] = 1.0
        c = [Double](repeating: 0, count: n + 1)
        b = [Double](repeating: 0, count: n)
        d = [Double](repeating: 0, count: n)

        for j in stride(from: n - 1, through: 0, by: -1) {
            c[j] = z[j] - mu[j] * c[j + 1]
            b[j] = (a[j + 1] - a[j]) / h[j] - (h[j] * (c[j + 1] + 2.0 * c[j])) / 3.0
            d[j] = (c[j + 1] - c[j]) / (3.0 * h[j])
        }
    }

    func at(_ x: Double) -> Double {
        guard xs.count > 1 else { return a.first ?? 0 }
        if x <= xs[0] { return a[0] }
        if x >= xs[xs.count - 1] { return a[a.count - 1] }

        var i = xs.count - 2
        for j in 0..<xs.count - 1 {
            if x < xs[j + 1] {
                i = j
                break
            }
        }
        let dx = x - xs[i]
        return a[i] + b[i] * dx + c[i] * dx * dx + d[i] * dx * dx * dx
    }
}

// MARK: - Spline Curves from Spicy Lyrics (AMLL-TTML-TOOL)

enum SpicySplines {
    static let scaleSpline = CubicSpline(points: [
        (0.0, 0.95),
        (0.7, 1.0505),
        (1.0, 1.0)
    ])

    static let letterScaleSpline = CubicSpline(points: [
        (0.0, 0.95),
        (0.7, 1.175),
        (1.0, 1.0)
    ])

    static let ySpline = CubicSpline(points: [
        (0.0, 0.01),
        (0.9, -1.0 / 60.0),
        (1.0, 0.0)
    ])

    static let letterYSpline = CubicSpline(points: [
        (0.0, 0.01),
        (0.9, -1.0 / 56.0),
        (1.0, 0.0)
    ])

    static let glowSpline = CubicSpline(points: [
        (0.0, 0.0),
        (0.15, 1.0),
        (0.6, 1.0),
        (1.0, 0.0)
    ])

    static let dotScaleSpline = CubicSpline(points: [
        (0.0, 0.75),
        (0.35, 1.12),
        (0.7, 1.0),
        (1.0, 1.0)
    ])

    static let dotYSpline = CubicSpline(points: [
        (0.0, 0.0),
        (0.35, -1.0 / 48.0),
        (0.7, 0.0),
        (1.0, 0.0)
    ])

    static let dotGlowSpline = CubicSpline(points: [
        (0.0, 0.0),
        (0.35, 1.0),
        (0.7, 0.25),
        (1.0, 0.25)
    ])

    static let dotOpacitySpline = CubicSpline(points: [
        (0.0, 0.35),
        (0.35, 1.0),
        (0.6, 1.0),
        (1.0, 1.0)
    ])
}

// MARK: - Word & Syllable Token Grouping

// MARK: - Syllable Token View (Progressive Gradient Fill & Bounce Pop)

struct SpicySyllableTokenView: View {
    let word: LyricWord
    let currentTimeMs: Int
    let isBackground: Bool
    let isLineActive: Bool
    let isLinePast: Bool

    var body: some View {
        if word.isLetterGroup && !word.letters.isEmpty {
            letterGroupView
        } else {
            singleSyllableView
        }
    }

    private var cleanText: String {
        word.text.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private var singleSyllableView: some View {
        if !isLineActive {
            let isWordSung = isLinePast || currentTimeMs >= word.endMs
            Text(cleanText)
                .foregroundStyle(isWordSung ? (isBackground ? .white.opacity(0.90) : .white) : .white.opacity(isBackground ? 0.30 : 0.40))
        } else {
            let isWordSung = currentTimeMs >= word.endMs
            let isWordActive = word.startMs <= currentTimeMs && currentTimeMs < word.endMs
            let duration = max(word.endMs - word.startMs, 1)
            let progress = isWordActive ? max(0.0, min(1.0, Double(currentTimeMs - word.startMs) / Double(duration))) : (isWordSung ? 1.0 : 0.0)

            let scale = isWordActive ? SpicySplines.scaleSpline.at(progress) : (isWordSung ? 1.0 : 0.96)
            let yLift = isWordActive ? SpicySplines.ySpline.at(progress) * 32.0 : 0.0
            let gradPos = isWordActive ? (-0.20 + 1.20 * progress) : (isWordSung ? 1.0 : -0.20)

            Text(cleanText)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isBackground ? 0.90 : 0.98), location: max(0.0, min(1.0, gradPos))),
                            .init(color: .white.opacity(isBackground ? 0.30 : 0.40), location: max(0.0, min(1.0, gradPos + 0.20)))
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .scaleEffect(scale)
                .offset(y: yLift)
        }
    }

    @ViewBuilder
    private var letterGroupView: some View {
        if !isLineActive {
            let isWordSung = isLinePast || currentTimeMs >= word.endMs
            Text(cleanText)
                .foregroundStyle(isWordSung ? (isBackground ? .white.opacity(0.90) : .white) : .white.opacity(isBackground ? 0.30 : 0.40))
        } else {
            HStack(spacing: 0) {
                ForEach(word.letters) { letter in
                    let isLetterSung = currentTimeMs >= letter.endMs
                    let isLetterActive = letter.startMs <= currentTimeMs && currentTimeMs < letter.endMs
                    let duration = max(letter.endMs - letter.startMs, 1)
                    let progress = isLetterActive ? max(0.0, min(1.0, Double(currentTimeMs - letter.startMs) / Double(duration))) : (isLetterSung ? 1.0 : 0.0)

                    let scale = isLetterActive ? SpicySplines.letterScaleSpline.at(progress) : (isLetterSung ? 1.0 : 0.96)
                    let yLift = isLetterActive ? SpicySplines.letterYSpline.at(progress) * 28.0 : 0.0
                    let gradPos = isLetterActive ? (-0.20 + 1.20 * progress) : (isLetterSung ? 1.0 : -0.20)

                    Text(letter.char)
                        .foregroundStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(isBackground ? 0.90 : 0.98), location: max(0.0, min(1.0, gradPos))),
                                    .init(color: .white.opacity(isBackground ? 0.30 : 0.40), location: max(0.0, min(1.0, gradPos + 0.20)))
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .scaleEffect(scale)
                        .offset(y: yLift)
                }
            }
        }
    }
}

// MARK: - Spicy Countdown Dot Line (AMLL-TTML-TOOL dotLine)

struct SpicyDotLineView: View {
    let line: LyricLine
    let currentTimeMs: Int

    var body: some View {
        let isPast = currentTimeMs > line.endMs
        let isPreCollapsing = currentTimeMs > line.endMs - 500
        let isVisible = currentTimeMs >= line.startMs && !isPast

        let total = max(line.endMs - line.startMs, 1)
        let base = Double(total) / 3.0
        let firstEnd = max(Double(line.startMs), Double(line.startMs) + base - 550.0 / 3.0)
        let secondEnd = max(firstEnd, Double(line.startMs) + base * 2.0 - (550.0 * 2.0) / 3.0)
        let thirdEnd = max(secondEnd, Double(line.endMs) - 550.0)

        let dotWindows: [(Double, Double)] = [
            (Double(line.startMs), firstEnd),
            (firstEnd, secondEnd),
            (secondEnd, thirdEnd)
        ]

        HStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { index in
                let window = dotWindows[index]
                let start = window.0
                let end = window.1
                let dur = max(end - start, 1.0)
                let p = max(0.0, min(1.0, (Double(currentTimeMs) - start) / dur))
                let isDotActive = currentTimeMs >= Int(start) && currentTimeMs < Int(end)
                let isDotSung = currentTimeMs >= Int(end)

                let scale = isDotActive ? SpicySplines.dotScaleSpline.at(p) : (isDotSung ? 1.0 : 0.75)
                let yOffset = isDotActive ? SpicySplines.dotYSpline.at(p) * 24.0 : 0.0
                let opacity = isDotSung ? 1.0 : (isDotActive ? SpicySplines.dotOpacitySpline.at(p) : 0.35)

                Text("•")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .scaleEffect(scale)
                    .offset(y: yOffset)
                    .opacity(opacity)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: line.oppositeAligned ? .trailing : .leading)
        .padding(line.oppositeAligned ? .leading : .trailing, 48)
        .scaleEffect(isVisible && !isPreCollapsing ? 1.0 : 0.0)
        .opacity(isVisible && !isPreCollapsing ? 1.0 : 0.0)
        .animation(.spring(response: 0.38, dampingFraction: 0.75), value: isPreCollapsing)
        .animation(.spring(response: 0.38, dampingFraction: 0.75), value: isVisible)
    }
}

// MARK: - Spicy Flow Layout (Word-Wrap preserving syllable clusters)

@available(iOS 16.0, macOS 13.0, *)
struct SpicyFlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 4

    init(alignment: HorizontalAlignment = .leading, horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 4) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentPoint = CGPoint.zero
        var maxRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            guard size.width > 0 else { continue }
            if currentPoint.x + size.width > width && currentPoint.x > 0 {
                currentPoint.x = 0
                currentPoint.y += maxRowHeight + verticalSpacing
                maxRowHeight = 0
            }
            maxRowHeight = max(maxRowHeight, size.height)
            currentPoint.x += size.width + horizontalSpacing
            totalWidth = max(totalWidth, currentPoint.x)
            totalHeight = currentPoint.y + maxRowHeight
        }
        return CGSize(width: min(width, totalWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var rows: [([LayoutSubview], [CGSize], CGFloat)] = []
        var currentRow: [LayoutSubview] = []
        var currentSizes: [CGSize] = []
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            guard size.width > 0 else { continue }
            if currentRowWidth + size.width > width && !currentRow.isEmpty {
                rows.append((currentRow, currentSizes, currentRowWidth))
                currentRow = []
                currentSizes = []
                currentRowWidth = 0
            }
            currentRow.append(subview)
            currentSizes.append(size)
            currentRowWidth += size.width + horizontalSpacing
        }
        if !currentRow.isEmpty {
            rows.append((currentRow, currentSizes, currentRowWidth))
        }

        var y = bounds.minY
        for (subviewsInRow, sizes, rowWidth) in rows {
            let actualRowWidth = rowWidth - (sizes.isEmpty ? 0 : horizontalSpacing)
            let xOffset: CGFloat
            switch alignment {
            case .trailing:
                xOffset = bounds.maxX - actualRowWidth
            case .center:
                xOffset = bounds.minX + (bounds.width - actualRowWidth) / 2
            default:
                xOffset = bounds.minX
            }

            var x = xOffset
            var rowMaxHeight: CGFloat = 0
            for (subview, size) in zip(subviewsInRow, sizes) {
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
                rowMaxHeight = max(rowMaxHeight, size.height)
            }
            y += rowMaxHeight + verticalSpacing
        }
    }
}

// MARK: - Spicy Lyric Line View

struct SpicyLyricLineView: View, Equatable {
    let line: LyricLine
    let currentTimeMs: Int
    let isLineActive: Bool
    let isLinePast: Bool
    let distance: Int
    let isRomanizationEnabled: Bool
    let isTranslationEnabled: Bool
    let isUserScrolling: Bool
    let onSeek: (Int) -> Void

    static func == (lhs: SpicyLyricLineView, rhs: SpicyLyricLineView) -> Bool {
        lhs.line == rhs.line &&
        lhs.isLineActive == rhs.isLineActive &&
        lhs.isLinePast == rhs.isLinePast &&
        lhs.distance == rhs.distance &&
        lhs.isRomanizationEnabled == rhs.isRomanizationEnabled &&
        lhs.isTranslationEnabled == rhs.isTranslationEnabled &&
        lhs.isUserScrolling == rhs.isUserScrolling &&
        (!lhs.isLineActive || lhs.currentTimeMs == rhs.currentTimeMs)
    }

    init(
        line: LyricLine,
        currentTimeMs: Int,
        isLineActive: Bool? = nil,
        isLinePast: Bool? = nil,
        distance: Int = 0,
        isRomanizationEnabled: Bool = false,
        isTranslationEnabled: Bool = false,
        isUserScrolling: Bool = false,
        onSeek: @escaping (Int) -> Void = { _ in }
    ) {
        self.line = line
        self.currentTimeMs = currentTimeMs
        self.isLineActive = isLineActive ?? (line.startMs <= currentTimeMs && currentTimeMs <= line.endMs)
        self.isLinePast = isLinePast ?? (currentTimeMs > line.endMs)
        self.distance = distance
        self.isRomanizationEnabled = isRomanizationEnabled
        self.isTranslationEnabled = isTranslationEnabled
        self.isUserScrolling = isUserScrolling
        self.onSeek = onSeek
    }

    var body: some View {
        Group {
            if line.isInterlude {
                if isLineActive {
                    SpicyDotLineView(line: line, currentTimeMs: currentTimeMs)
                        .padding(.vertical, 4)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            } else {
                VStack(alignment: line.oppositeAligned ? .trailing : .leading, spacing: 6) {
                    if line.isSongwriter {
                        Text(line.displayText.isEmpty ? " " : line.displayText)
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(maxWidth: .infinity, alignment: line.oppositeAligned ? .trailing : .leading)
                    } else if !line.isWordSynced || line.words.isEmpty {
                        // Clean whole-line display for line-synced songs (do not fake word-by-word karaoke)
                        Text(line.displayText.isEmpty ? " " : line.displayText)
                            .font(lineFont)
                            .tracking(-0.5)
                            .foregroundStyle(isLineActive ? (line.isBackground ? .white.opacity(0.90) : .white) : (isLinePast ? (line.isBackground ? .white.opacity(0.75) : .white.opacity(0.85)) : .white.opacity(line.isBackground ? 0.30 : 0.40)))
                            .frame(maxWidth: .infinity, alignment: line.oppositeAligned ? .trailing : .leading)
                    } else {
                        // Word groups with preserve-word line wrap and syllable-level progressive physics
                        SpicyFlowLayout(alignment: line.oppositeAligned ? .trailing : .leading) {
                            ForEach(line.wordGroups) { group in
                                HStack(spacing: 0) {
                                    ForEach(group.words) { word in
                                        SpicySyllableTokenView(
                                            word: word,
                                            currentTimeMs: currentTimeMs,
                                            isBackground: line.isBackground,
                                            isLineActive: isLineActive,
                                            isLinePast: isLinePast
                                        )
                                    }
                                    if group.hasTrailingSpace {
                                        Text(" ")
                                            .font(lineFont)
                                    }
                                }
                            }
                        }
                        .font(lineFont)
                        .tracking(-0.5)
                        .frame(maxWidth: .infinity, alignment: line.oppositeAligned ? .trailing : .leading)
                    }

                    if isRomanizationEnabled, let roman = line.romanization {
                        Text(roman)
                            .font(.system(size: line.isBackground ? 16 : 20, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(isLineActive ? 0.72 : 0.45))
                            .frame(maxWidth: .infinity, alignment: line.oppositeAligned ? .trailing : .leading)
                    }

                    if isTranslationEnabled, let translation = line.translation {
                        Text(translation)
                            .font(.system(size: line.isBackground ? 15 : 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(isLineActive ? 0.72 : 0.45))
                            .frame(maxWidth: .infinity, alignment: line.oppositeAligned ? .trailing : .leading)
                    }
                }
                .opacity(lineOpacity)
                .scaleEffect(isLineActive ? 1.0 : 0.96, anchor: line.oppositeAligned ? .trailing : .leading)
                .modifier(OptionalBlurModifier(radius: lineBlur))
                .padding(.top, line.isBackground ? -4 : 10)
                .padding(.bottom, line.isBackground ? 10 : 12)
                .frame(maxWidth: .infinity, alignment: line.oppositeAligned ? .trailing : .leading)
                .padding(line.oppositeAligned ? .leading : .trailing, 48)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !line.isSongwriter {
                        onSeek(line.startMs)
                    }
                }
                .animation(.spring(response: 0.44, dampingFraction: 0.82), value: isLineActive)
            }
        }
    }

    private var lineFont: Font {
        if line.isBackground {
            return .system(size: 24, weight: .bold, design: .rounded)
        }
        return .system(size: 32, weight: .heavy, design: .rounded)
    }

    private var lineOpacity: Double {
        if isLineActive { return 1.0 }
        if isUserScrolling { return 0.85 }
        return isLinePast ? 0.55 : 0.48
    }

    private var lineBlur: CGFloat {
        0.0 // Always 0 so text is never blurred in the middle or while scrolling
    }
}

private struct OptionalBlurModifier: ViewModifier {
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if radius > 0.1 {
            content.blur(radius: radius)
        } else {
            content
        }
    }
}

// MARK: - Spicy Lyrics Attribution Footer

struct SpicyLyricsAttributionFooterView: View {
    let source: String?
    let attribution: SpicyUploadAttribution?
    let songwriters: [String]

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            // Subtle glowing divider
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.0), location: 0),
                            .init(color: .white.opacity(0.18), location: 0.5),
                            .init(color: .white.opacity(0.0), location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)

            // Songwriters section
            if !songwriters.isEmpty {
                VStack(spacing: 4) {
                    Text("WRITTEN BY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(1.2)

                    Text(songwriters.joined(separator: ", "))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }

            // Maker & Uploader section (from Spicy Lyrics API)
            if let attr = attribution, (attr.maker != nil || attr.uploader != nil) {
                let maker = attr.maker
                let uploader = attr.uploader
                let isSamePerson = maker != nil && uploader != nil && (maker?.id == uploader?.id || maker?.username == uploader?.username)

                VStack(spacing: 10) {
                    Text("COMMUNITY SYNC")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(1.2)

                    HStack(spacing: 12) {
                        if isSamePerson, let user = maker {
                            userBadge(role: "Synced & Uploaded by", user: user)
                        } else {
                            if let maker = maker {
                                userBadge(role: "Synced by", user: maker)
                            }
                            if let uploader = uploader {
                                userBadge(role: "Uploaded by", user: uploader)
                            }
                        }
                    }
                }
            }

            // Provider badge
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange.opacity(0.9))

                Text(providerLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var providerLabel: String {
        switch source?.lowercased() {
        case "spicy_lyrics":
            return "Lyrics provided by Spicy Lyrics"
        case "apple_music":
            return "Lyrics provided by Apple Music via Spicy Lyrics"
        case "spotify":
            return "Lyrics provided by Spotify via Spicy Lyrics"
        default:
            return "Lyrics provided by Spicy Lyrics"
        }
    }

    @ViewBuilder
    private func userBadge(role: String, user: SpicyAttributionUser) -> some View {
        let avatarUrl = resolveAvatarUrl(id: user.id, avatar: user.avatar)
        let profileUrl = user.url.flatMap { URL(string: $0) }

        Button {
            if let profileUrl = profileUrl {
                openURL(profileUrl)
            }
        } label: {
            HStack(spacing: 8) {
                if let avatarUrl = avatarUrl {
                    AsyncImage(url: avatarUrl) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.white.opacity(0.6))
                        case .empty:
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.6)
                        @unknown default:
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(role)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))

                    HStack(spacing: 3) {
                        Text(user.username ?? "Unknown")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        if profileUrl != nil {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func resolveAvatarUrl(id: String?, avatar: String?) -> URL? {
        guard let avatar = avatar, !avatar.isEmpty else { return nil }
        if avatar.hasPrefix("http://") || avatar.hasPrefix("https://") {
            return URL(string: avatar)
        }
        if let id = id, !id.isEmpty {
            return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).png?size=128")
        }
        return nil
    }
}

