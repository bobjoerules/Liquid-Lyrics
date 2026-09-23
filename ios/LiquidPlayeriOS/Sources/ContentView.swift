import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

private var isMac: Bool {
    #if targetEnvironment(macCatalyst)
    return true
    #elseif canImport(UIKit)
    return UIDevice.current.userInterfaceIdiom == .mac || ProcessInfo.processInfo.isiOSAppOnMac
    #else
    return false
    #endif
}

struct ContentView: View {
    private enum AppTab: Hashable {
        case nowPlaying
        case library
        case settings
    }

    private enum LibraryTab: String, CaseIterable, Identifiable {
        case recents = "Recents"
        case favorites = "Favorites"

        var id: String { self.rawValue }
    }

    @StateObject private var viewModel = PlayerViewModel()
    @AppStorage("hasCompletedIntro") private var hasCompletedIntro = false
    @State private var isFullScreenNowPlaying = false
    @State private var isDraggingSlider = false
    @State private var dragValue: Double = 0.0
    @State private var selectedTab: AppTab = .nowPlaying
    @State private var libraryTab: LibraryTab = .recents
    @State private var isShowingQueue = false
    @State private var isUserScrollingLyrics = false
    @State private var userScrollResumeTask: Task<Void, Never>? = nil

    private var displayedTimeMs: Int {
        return max(0, viewModel.currentTimeMs + viewModel.lyricOffsetMs)
    }

    var body: some View {
        mainContent
            .sheet(isPresented: $isShowingQueue) {
                QueueView(viewModel: viewModel)
            }
            .background {
                Button("") {
                    viewModel.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            }
    }

    private var mainContent: some View {
        ZStack(alignment: .topTrailing) {
            #if canImport(UIKit)
            AnimatedArtworkBackground(artwork: viewModel.artwork)
            #else
            Color.black.ignoresSafeArea()
            #endif

            if !hasCompletedIntro && !viewModel.spotifyService.isAuthenticated && viewModel.selectedTrackID == nil {
                introductionView
            } else if isFullScreenNowPlaying {
                fullScreenNowPlayingView
            } else {
                TabView(selection: $selectedTab) {
                    nowPlayingPage
                        .tag(AppTab.nowPlaying)
                        .tabItem {
                            Label("Now Playing", systemImage: "quote.bubble.fill")
                        }

                    // Library tab hidden for now
                    /*
                    libraryPage
                        .tag(AppTab.library)
                        .tabItem {
                            Label("Library", systemImage: "music.note.list")
                        }
                    */

                    settingsPage
                        .tag(AppTab.settings)
                        .tabItem {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                }
                .tint(.white)
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .safeAreaInset(edge: .bottom) {
                    if viewModel.selectedTrackID != nil && selectedTab != .nowPlaying {
                        miniPlayerBar
                            .padding(.horizontal, 14)
                            .padding(.bottom, 58)
                    }
                }
            }
        }
    }

    // MARK: - Now Playing Page
    private var nowPlayingPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            topBar(title: "Now Playing")

            if viewModel.selectedTrackID != nil && viewModel.lines.isEmpty && !viewModel.isLoadingLyrics {
                Spacer()

                VStack(spacing: 24) {
                    dynamicArtworkView(size: isMac ? 280 : 220)
                        .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 10)

                    VStack(spacing: 6) {
                        MarqueeText(
                            text: viewModel.nowPlayingTitle,
                            font: .system(size: isMac ? 32 : 24, weight: .bold),
                            color: .white,
                            alignment: .center
                        )
                        .padding(.horizontal, 32)

                        MarqueeText(
                            text: viewModel.authorMetadata,
                            font: .system(size: isMac ? 18 : 15, weight: .semibold),
                            color: .white.opacity(0.6),
                            alignment: .center
                        )
                        .padding(.horizontal, 32)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()

                VStack(spacing: 16) {
                    timelineSeekBar
                    controls
                }
            } else if viewModel.selectedTrackID != nil {
                heroPanel
                timelineSeekBar
                lyricsPanel()
                controls

                Spacer(minLength: 0)
            } else {
                // Empty state when nothing is playing
                Spacer()

                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.1, green: 0.8, blue: 0.5).opacity(0.2), Color.blue.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 140, height: 140)

                        Image(systemName: "music.note")
                            .font(.system(size: 54))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    VStack(spacing: 8) {
                        Text("No Spotify Track Active")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Play a track on Spotify or connect your account to start live syllable synchronization.")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    HStack(spacing: 14) {
                        if !viewModel.spotifyService.isAuthenticated {
                            Button {
                                viewModel.spotifyService.login()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "link")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("Connect Spotify")
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: Capsule())
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }

                        /*
                        Button {
                            selectedTab = .library
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Library")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        */
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    // MARK: - Settings Page
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar(title: "Settings")
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 8)

            SettingsView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Library Page
    private var libraryPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    Text("Library")
                        .font(.system(size: isMac ? 48 : 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await viewModel.shufflePlay()
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .modifier(MiniPlayerCapsuleButtonModifier())
                        }
                        .buttonStyle(.plain)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                // Category Selector
                Picker("Category", selection: $libraryTab) {
                    ForEach(LibraryTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                if libraryTab == .recents {
                    recentsList
                } else {
                    favoritesList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 120)
        }
    }

    private var recentsList: some View {
        Group {
            if viewModel.recentTracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("No recently played tracks")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.recentTracks) { track in
                        SpotifyTrackListRow(
                            track: track,
                            isActive: viewModel.selectedTrackID == track.id,
                            isFavorite: viewModel.isTrackFavorite(track.id ?? ""),
                            onSelect: {
                                viewModel.playSpotifyTrack(track)
                                selectedTab = .nowPlaying
                            },
                            onToggleFavorite: {
                                if let id = track.id {
                                    viewModel.toggleFavorite(id)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var favoritesList: some View {
        let favorites = viewModel.recentTracks.filter { viewModel.isTrackFavorite($0.id ?? "") }
        return Group {
            if favorites.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "heart")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("No favorite tracks yet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Tap the heart icon while playing or searching to add favorites.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(favorites) { track in
                        SpotifyTrackListRow(
                            track: track,
                            isActive: viewModel.selectedTrackID == track.id,
                            isFavorite: true,
                            onSelect: {
                                viewModel.playSpotifyTrack(track)
                                selectedTab = .nowPlaying
                            },
                            onToggleFavorite: {
                                if let id = track.id {
                                    viewModel.toggleFavorite(id)
                                }
                            }
                        )
                    }
                }
            }
        }
    }


    // MARK: - Top Bar
    private func topBar(title: String) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: isMac ? 48 : 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.67))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if title == "Now Playing", viewModel.selectedTrackID != nil {
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            isFullScreenNowPlaying = true
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: isMac ? 17 : 14, weight: isMac ? .bold : .semibold))
                            .foregroundStyle(.white)
                            .frame(width: isMac ? 44 : 38, height: isMac ? 44 : 38)
                            .modifier(MiniPlayerButtonBackgroundModifier())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var syncSection: some View {
        HStack(spacing: 10) {
            syncButton(title: "-100") {
                viewModel.adjustLyricOffset(by: -100)
            }

            syncButton(title: "Reset") {
                viewModel.resetLyricOffset()
            }

            syncButton(title: "+100") {
                viewModel.adjustLyricOffset(by: 100)
            }

            Spacer()

            Text("Sync \(viewModel.lyricOffsetMs >= 0 ? "+" : "")\(viewModel.lyricOffsetMs) ms")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    private var heroPanel: some View {
        HStack(spacing: 16) {
            artworkView
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        isFullScreenNowPlaying = true
                    }
                }

            VStack(alignment: .leading, spacing: 8) {
                MarqueeText(
                    text: viewModel.nowPlayingTitle,
                    font: .system(size: isMac ? 36 : 28, weight: .semibold),
                    color: .white
                )

                MarqueeText(
                    text: viewModel.authorMetadata,
                    font: .system(size: isMac ? 19 : 15, weight: .medium),
                    color: .white.opacity(0.64)
                )
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var miniPlayerBar: some View {
        HStack(spacing: 14) {
            compactArtworkView
                .onTapGesture {
                    selectedTab = .nowPlaying
                }

            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(
                    text: viewModel.nowPlayingTitle,
                    font: .system(size: isMac ? 18 : 15, weight: .semibold),
                    color: .white
                )

                Text(viewModel.authorMetadata)
                    .font(.system(size: isMac ? 14 : 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        await viewModel.playNextTrack()
                    }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(MiniPlayerBackgroundModifier())
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            selectedTab = .nowPlaying
        }
    }

    private var compactArtworkView: some View {
        Group {
            #if canImport(UIKit)
            if let artwork = viewModel.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                artworkFallback
            }
            #else
            artworkFallback
            #endif
        }
        .frame(width: isMac ? 68 : 52, height: isMac ? 68 : 52)
        .clipShape(RoundedRectangle(cornerRadius: isMac ? 10 : 8, style: .continuous))
    }

    private var artworkView: some View {
        Group {
            #if canImport(UIKit)
            if let artwork = viewModel.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                artworkFallback
            }
            #else
            artworkFallback
            #endif
        }
        .frame(width: isMac ? 150 : 108, height: isMac ? 150 : 108)
        .clipShape(RoundedRectangle(cornerRadius: isMac ? 14 : 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isMac ? 14 : 10, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
    }

    private var artworkFallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: isMac ? 44 : 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var hasTranslations: Bool {
        viewModel.lines.contains { $0.translation != nil }
    }

    private var hasRomanization: Bool {
        viewModel.lines.contains { $0.romanization != nil }
    }

    private func lyricsPanel(isFullScreen: Bool = false) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if hasTranslations || hasRomanization {
                    HStack(spacing: 8) {
                        if hasRomanization {
                            Toggle(isOn: $viewModel.isRomanizationEnabled) {
                                Text("Romaji")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .toggleStyle(.button)
                            .tint(.white.opacity(0.18))
                        }

                        if hasTranslations {
                            Toggle(isOn: $viewModel.isTranslationEnabled) {
                                Text("Translation")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .toggleStyle(.button)
                            .tint(.white.opacity(0.18))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if viewModel.isLoadingLyrics {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .tint(.white)
                                Text("Fetching lyrics from Spicy Lyrics...")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 80)
                        } else if viewModel.lines.isEmpty {
                            Spacer(minLength: 0)
                        } else {
                            let activeID: UUID? = viewModel.activeLineID(for: displayedTimeMs)
                            let activeIndex: Int = viewModel.lines.firstIndex { $0.id == activeID } ?? -1
                            let lyricLines: [LyricLine] = viewModel.lines.filter { !$0.isSongwriter }

                            ForEach(Array(lyricLines.enumerated()), id: \.element.id) { index, line in
                                lyricLineRow(
                                    line: line,
                                    index: index,
                                    activeID: activeID,
                                    activeIndex: activeIndex
                                )
                            }

                            SpicyLyricsAttributionFooterView(
                                source: viewModel.lyricsSource,
                                attribution: viewModel.lyricsAttribution,
                                songwriters: viewModel.lyricsSongwriters
                            )
                            .padding(.top, 36)
                            .padding(.bottom, 64)
                        }
                    }
                    .padding(.vertical, 26)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in
                            isUserScrollingLyrics = true
                            userScrollResumeTask?.cancel()
                            userScrollResumeTask = Task {
                                try? await Task.sleep(nanoseconds: 4_500_000_000)
                                if !Task.isCancelled {
                                    await MainActor.run {
                                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                                            isUserScrollingLyrics = false
                                        }
                                    }
                                }
                            }
                        }
                )
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Group {
                    if !isFullScreen {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(.white.opacity(0.08))
                    }
                }
            )
            .overlay(
                Group {
                    if !isFullScreen {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                }
            )
            .overlay(alignment: .bottom) {
                if isUserScrollingLyrics, let activeID = viewModel.activeLineID(for: displayedTimeMs) {
                    Button {
                        userScrollResumeTask?.cancel()
                        withAnimation(.spring(response: 0.52, dampingFraction: 0.88)) {
                            isUserScrollingLyrics = false
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("Center")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 12)
                }
            }
            .onChange(of: viewModel.activeLineID(for: displayedTimeMs), initial: false) { _, activeID in
                guard let activeID = activeID else {
                    return
                }

                if !isUserScrollingLyrics {
                    withAnimation(.spring(response: 0.52, dampingFraction: 0.88)) {
                        proxy.scrollTo(activeID, anchor: .center)
                    }
                }
            }
            .onChange(of: viewModel.currentTrackId) { _, _ in
                isUserScrollingLyrics = false
                userScrollResumeTask?.cancel()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if let targetID = viewModel.activeLineID(for: displayedTimeMs) ?? viewModel.lines.first?.id {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: viewModel.lines.map(\.id)) { _, newIds in
                isUserScrollingLyrics = false
                guard !newIds.isEmpty else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if let targetID = viewModel.activeLineID(for: displayedTimeMs) ?? newIds.first {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
            }
            .onAppear {
                isUserScrollingLyrics = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if let activeID = viewModel.activeLineID(for: displayedTimeMs) ?? viewModel.lines.first?.id {
                        proxy.scrollTo(activeID, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lyricLineRow(
        line: LyricLine,
        index: Int,
        activeID: UUID?,
        activeIndex: Int
    ) -> some View {
        let effectiveEnd: Int = max(line.endMs, line.words.last?.endMs ?? line.startMs)
        let isTimeActive: Bool = (line.startMs <= displayedTimeMs && displayedTimeMs <= effectiveEnd)
        let isActive: Bool = isTimeActive || (line.id == activeID)
        let isPast: Bool = !isActive && (displayedTimeMs > effectiveEnd)
        let distance: Int = activeIndex >= 0 ? (index - activeIndex) : 0
        let lineTimeMs: Int = isActive ? displayedTimeMs : 0

        SpicyLyricLineView(
            line: line,
            currentTimeMs: lineTimeMs,
            isLineActive: isActive,
            isLinePast: isPast,
            distance: distance,
            isRomanizationEnabled: viewModel.isRomanizationEnabled,
            isTranslationEnabled: viewModel.isTranslationEnabled,
            isUserScrolling: isUserScrollingLyrics,
            onSeek: { seekMs in
                userScrollResumeTask?.cancel()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    isUserScrollingLyrics = false
                }
                viewModel.seek(to: seekMs)
            }
        )
        .equatable()
        .id(line.id)
    }

    private var controls: some View {
        ZStack {
            // Far left control
            HStack {
                controlButton(systemName: "shuffle", isActive: viewModel.isShuffleEnabled, isAction: false) {
                    viewModel.toggleShuffle()
                }
                Spacer()
            }

            // Far right control
            HStack {
                Spacer()
                controlButton(
                    systemName: viewModel.isCurrentTrackFavorite() ? "heart.fill" : "heart",
                    isActive: viewModel.isCurrentTrackFavorite(),
                    isAction: false
                ) {
                    viewModel.toggleFavoriteCurrentTrack()
                }
            }

            // Centered controls
            HStack(spacing: 24) {
                controlButton(systemName: "backward.fill") {
                    Task {
                        await viewModel.playPreviousTrack()
                    }
                }

                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                controlButton(systemName: "forward.fill") {
                    Task {
                        await viewModel.playNextTrack()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func controlButton(systemName: String, isActive: Bool = false, isAction: Bool = true, action: @escaping () -> Void) -> some View {
        let isHighlighted = isActive || isAction
        let isHeart = systemName.contains("heart")
        let foregroundColor: Color = {
            if isHeart && isActive {
                return .red
            }
            return isHighlighted ? .white : .white.opacity(0.48)
        }()

        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func syncButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var fullScreenNowPlayingView: some View {
        VStack(spacing: 20) {
            // Header with dismiss button and title
            HStack {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        isFullScreenNowPlaying = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Now Playing")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                Color.clear
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            if viewModel.selectedTrackID != nil && viewModel.lines.isEmpty && !viewModel.isLoadingLyrics {
                Spacer()

                VStack(spacing: 28) {
                    dynamicArtworkView(size: isMac ? 340 : 280)
                        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 12)

                    VStack(spacing: 8) {
                        MarqueeText(
                            text: viewModel.nowPlayingTitle,
                            font: .system(size: isMac ? 32 : 26, weight: .bold),
                            color: .white,
                            alignment: .center
                        )
                        .padding(.horizontal, 32)

                        MarqueeText(
                            text: viewModel.authorMetadata,
                            font: .system(size: isMac ? 19 : 16, weight: .semibold),
                            color: .white.opacity(0.6),
                            alignment: .center
                        )
                        .padding(.horizontal, 32)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()

                VStack(spacing: 24) {
                    timelineSeekBar
                    controls
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            } else {
                HStack(spacing: 20) {
                    largeArtworkView

                    VStack(alignment: .leading, spacing: 6) {
                        MarqueeText(
                            text: viewModel.nowPlayingTitle,
                            font: .system(size: 24, weight: .bold),
                            color: .white
                        )

                        MarqueeText(
                            text: viewModel.authorMetadata,
                            font: .system(size: 15, weight: .medium),
                            color: .white.opacity(0.6)
                        )
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)

                lyricsPanel(isFullScreen: true)

                timelineSeekBar
                    .padding(.horizontal, 20)

                controls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
        }
    }

    private var largeArtworkView: some View {
        dynamicArtworkView(size: 86)
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }

    private func dynamicArtworkView(size: CGFloat) -> some View {
        let cornerRadius = min(max(size * 0.045, 8), 16)
        return Group {
            #if canImport(UIKit)
            if let artwork = viewModel.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                dynamicFallback(size: size)
            }
            #else
            dynamicFallback(size: size)
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func dynamicFallback(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var timelineSeekBar: some View {
        let duration = Double(viewModel.durationMs)
        let current = Double(viewModel.currentTimeMs)
        let progress = duration > 0 ? current / duration : 0.0

        return VStack(spacing: 6) {
            GeometryReader { proxy in
                let trackWidth = proxy.size.width
                let progressWidth = isDraggingSlider
                    ? max(0, min(dragValue / max(duration, 1) * trackWidth, trackWidth))
                    : max(0, min(progress * trackWidth, trackWidth))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 8)

                    Capsule()
                        .fill(.white)
                        .frame(width: progressWidth, height: 8)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            isDraggingSlider = true
                            let locationX = gesture.location.x
                            let percentage = max(0, min(locationX / trackWidth, 1.0))
                            dragValue = percentage * max(duration, 1)
                        }
                        .onEnded { gesture in
                            let locationX = gesture.location.x
                            let percentage = max(0, min(locationX / trackWidth, 1.0))
                            let targetTime = percentage * max(duration, 1)
                            viewModel.seek(to: Int(targetTime))

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isDraggingSlider = false
                            }
                        }
                )
            }
            .frame(height: 10)

            HStack {
                Text(timecode(Int(isDraggingSlider ? dragValue : current)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Text(timecode(viewModel.durationMs))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .disabled(viewModel.durationMs == 0)
    }

    private func timecode(_ ms: Int) -> String {
        let totalSeconds = max(ms / 1000, 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var introductionView: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 36) {
                    VStack(spacing: 12) {
                        Text("Liquid Player")
                            .font(.system(size: isMac ? 54 : 42, weight: .black))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(red: 0.11, green: 0.85, blue: 0.45), Color(red: 0.2, green: 0.65, blue: 1.0)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Text("Your Music, Liquid & Synchronized.")
                            .font(.system(size: isMac ? 22 : 18, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Syllable-synchronized lyrics powered by Spicy Lyrics and Spotify.")
                            .font(.system(size: isMac ? 16 : 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 40)

                    VStack(alignment: .leading, spacing: 24) {
                        tutorialRow(
                            systemImage: "waveform.badge.magnifyingglass",
                            title: "Spotify Web API",
                            description: "Connect your Spotify account to control playback, search tracks, and sync state smoothly in real-time."
                        )

                        tutorialRow(
                            systemImage: "quote.bubble.fill",
                            title: "Spicy Lyrics API",
                            description: "Instant syllable-level and line-level synchronized lyrics rendered with bouncy physics."
                        )

                        tutorialRow(
                            systemImage: "sparkles",
                            title: "Liquid Experience",
                            description: "Dynamic artwork background, Romaji romanization, instant translation, and keyboard shortcuts."
                        )
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 40)
            }

            VStack(spacing: 16) {
                Button {
                    viewModel.spotifyService.login()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 18, weight: .bold))
                        Text("Connect with Spotify")
                            .font(.system(size: 17, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button("Explore App First") {
                    withAnimation(.spring()) {
                        hasCompletedIntro = true
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private func tutorialRow(systemImage: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(Color(red: 0.11, green: 0.85, blue: 0.45))
                .frame(width: 36)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)

                Text(description)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.04), lineWidth: 1)
        )
    }
}

// MARK: - Spotify Track Row & Artwork Components
struct SpotifyArtworkView: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    init(url: URL?, size: CGFloat = 54, cornerRadius: CGFloat = 8) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(0.12))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct SpotifyTrackListRow: View {
    let track: SpotifyTrackItem
    let isActive: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: isMac ? 16 : 12) {
                SpotifyArtworkView(url: track.artworkURL, size: isMac ? 60 : 48, cornerRadius: 12)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.system(size: isMac ? 17 : 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(track.artistNames)
                        .font(.system(size: isMac ? 14 : 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.red)
                    }

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isActive ? Color(red: 0.11, green: 0.85, blue: 0.45) : .white.opacity(0.4))
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? Color(red: 0.11, green: 0.85, blue: 0.45).opacity(0.5) : .white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onToggleFavorite()
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
            }
        }
    }
}




private struct AnimatedArtworkBackground: View {
    let artwork: UIImage?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            GeometryReader { proxy in
                let size = proxy.size
                let time = context.date.timeIntervalSinceReferenceDate

                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.09, blue: 0.12), Color(red: 0.16, green: 0.12, blue: 0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    orb(
                        color: Color(red: 1.0, green: 0.54, blue: 0.45),
                        size: min(size.width, size.height) * 0.72,
                        x: size.width * (0.14 + 0.08 * sin(time * 0.35)),
                        y: size.height * (0.20 + 0.10 * cos(time * 0.28))
                    )

                    orb(
                        color: Color(red: 0.98, green: 0.82, blue: 0.63),
                        size: min(size.width, size.height) * 0.52,
                        x: size.width * (0.82 + 0.08 * cos(time * 0.26)),
                        y: size.height * (0.28 + 0.12 * sin(time * 0.31))
                    )

                    orb(
                        color: Color(red: 0.88, green: 0.36, blue: 0.28),
                        size: min(size.width, size.height) * 0.66,
                        x: size.width * (0.58 + 0.07 * sin(time * 0.20)),
                        y: size.height * (0.84 + 0.05 * cos(time * 0.23))
                    )

                    if let artwork {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 90)
                            .opacity(0.34)
                            .ignoresSafeArea()
                    }

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.02), Color.black.opacity(0.76)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .drawingGroup()
                .ignoresSafeArea()
            }
        }
    }

    private func orb(color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .position(x: x, y: y)
            .blur(radius: size * 0.22)
            .opacity(0.52)
            .blendMode(.screen)
    }
}


private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var alignment: Alignment = .leading
    
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var startTime: TimeInterval = Date().timeIntervalSinceReferenceDate
    
    var body: some View {
        Text(" ")
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            updateContainerWidth(geo.size.width)
                        }
                        .onChange(of: geo.size.width) { _, newWidth in
                            updateContainerWidth(newWidth)
                        }
                }
            )
            .overlay(alignment: alignment) {
                if containerWidth > 0 {
                    let isOverflowing = textWidth > containerWidth + 2
                    let scrollDistance = max(0, textWidth - containerWidth)
                    
                    TimelineView(.animation(paused: !isOverflowing)) { timelineContext in
                        let offset = calculateOffset(
                            currentTime: timelineContext.date.timeIntervalSinceReferenceDate,
                            scrollDistance: scrollDistance,
                            isOverflowing: isOverflowing
                        )
                        
                        let isLeadingFaded = isOverflowing && -offset > 4
                        let isTrailingFaded = isOverflowing && -offset < (scrollDistance - 4)
                        
                        ZStack(alignment: alignment) {
                            Text(text)
                                .font(font)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(
                                    GeometryReader { textGeo in
                                        Color.clear
                                            .onAppear {
                                                updateTextWidth(textGeo.size.width)
                                            }
                                            .onChange(of: text) { _, _ in
                                                updateTextWidth(textGeo.size.width)
                                            }
                                            .onChange(of: textGeo.size.width) { _, newWidth in
                                                updateTextWidth(newWidth)
                                            }
                                    }
                                )
                                .offset(x: offset)
                                .frame(width: isOverflowing ? nil : containerWidth, alignment: alignment)
                        }
                        .frame(width: containerWidth, alignment: alignment)
                        .clipped()
                        .mask(
                            Group {
                                if isOverflowing {
                                    HStack(spacing: 0) {
                                        if isLeadingFaded {
                                            LinearGradient(
                                                colors: [.clear, .black],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                            .frame(width: 12)
                                        }
                                        
                                        Color.black
                                        
                                        if isTrailingFaded {
                                            LinearGradient(
                                                colors: [.black, .clear],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                            .frame(width: 12)
                                        }
                                    }
                                } else {
                                    Color.black
                                }
                            }
                        )
                    }
                }
            }
            .foregroundStyle(color)
            .onChange(of: text) { _, _ in
                resetStartTime()
            }
            .onAppear {
                resetStartTime()
            }
    }
    
    private func resetStartTime() {
        startTime = Date().timeIntervalSinceReferenceDate
    }
    
    private func updateContainerWidth(_ width: CGFloat) {
        if abs(containerWidth - width) > 0.5 {
            containerWidth = width
        }
    }
    
    private func updateTextWidth(_ width: CGFloat) {
        if abs(textWidth - width) > 0.5 {
            textWidth = width
        }
    }
    
    private func calculateOffset(currentTime: TimeInterval, scrollDistance: CGFloat, isOverflowing: Bool) -> CGFloat {
        guard isOverflowing, scrollDistance > 0 else { return 0 }
        
        let speed: Double = 28.0
        let scrollDuration = Double(scrollDistance) / speed
        let pauseDuration: Double = 2.0
        let singlePassDuration = pauseDuration + scrollDuration
        let totalCycleDuration = singlePassDuration * 2.0
        
        let rawElapsed = currentTime - startTime
        guard rawElapsed >= 0 else { return 0 }
        
        let elapsed = rawElapsed.truncatingRemainder(dividingBy: totalCycleDuration)
        
        if elapsed < pauseDuration {
            return 0
        } else if elapsed < singlePassDuration {
            let progress = (elapsed - pauseDuration) / scrollDuration
            let easedProgress = (1.0 - cos(progress * .pi)) / 2.0
            return -scrollDistance * CGFloat(easedProgress)
        } else if elapsed < singlePassDuration + pauseDuration {
            return -scrollDistance
        } else {
            let progress = (elapsed - (singlePassDuration + pauseDuration)) / scrollDuration
            let easedProgress = (1.0 - cos(progress * .pi)) / 2.0
            return -scrollDistance * CGFloat(1.0 - easedProgress)
        }
    }
}


// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var spicyLyricsKey: String = APIConfig.spicyLyricsApiKey
    @State private var spotifyClientId: String = APIConfig.spotifyClientId
    @State private var spotifyClientSecret: String = APIConfig.spotifyClientSecret
    @State private var isSavedAlertPresented: Bool = false

    var body: some View {
        Form {
            Section("Spotify Connection") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account Status")
                            .font(.system(size: 15, weight: .semibold))
                        Text(viewModel.spotifyService.isAuthenticated ? "Connected (\(viewModel.spotifyService.activeDeviceName ?? "Active Device"))" : "Not Connected")
                            .font(.system(size: 13))
                            .foregroundStyle(viewModel.spotifyService.isAuthenticated ? Color(red: 0.11, green: 0.85, blue: 0.45) : .secondary)
                    }

                    Spacer()

                    if viewModel.spotifyService.isAuthenticated {
                        Button("Disconnect", role: .destructive) {
                            viewModel.spotifyService.logout()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Connect") {
                            viewModel.spotifyService.login()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.11, green: 0.73, blue: 0.33))
                    }
                }
            }

            Section("API Configuration") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spicy Lyrics API Key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    SecureField("Spicy Lyrics Key", text: $spicyLyricsKey)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Spotify Client ID")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Spotify Client ID", text: $spotifyClientId)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Spotify Client Secret (Optional)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    SecureField("Optional (Not needed for PKCE)", text: $spotifyClientSecret)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }

                Button("Save Configuration") {
                    APIConfig.spicyLyricsApiKey = spicyLyricsKey
                    APIConfig.spotifyClientId = spotifyClientId
                    APIConfig.spotifyClientSecret = spotifyClientSecret
                    isSavedAlertPresented = true
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.11, green: 0.85, blue: 0.45))

                Button("Reset to Defaults") {
                    APIConfig.resetToDefaults()
                    spicyLyricsKey = APIConfig.spicyLyricsApiKey
                    spotifyClientId = APIConfig.spotifyClientId
                    spotifyClientSecret = APIConfig.spotifyClientSecret
                    isSavedAlertPresented = true
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }

            Section("About Liquid Player") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0 (Beta)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("OAuth Callback")
                    Spacer()
                    Text(APIConfig.spotifyRedirectUri)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .alert("Settings Saved", isPresented: $isSavedAlertPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your API configuration has been safely updated.")
        }
    }
}

typealias SettingsSheet = SettingsView

private struct MiniPlayerBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        }
    }
}

private struct MiniPlayerButtonBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(in: Circle())
        } else {
            content
                .background(.thinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .fill(.white.opacity(0.03))
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
    }
}

private struct MiniPlayerCapsuleButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(in: Capsule())
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .fill(.white.opacity(0.03))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
    }
}

struct QueueView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    if viewModel.playbackQueue.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 48))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("Queue is Empty")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("Search songs on Spotify or play from library to populate upcoming tracks.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(viewModel.playbackQueue) { track in
                                HStack(spacing: 12) {
                                    SpotifyArtworkView(url: track.artworkURL, size: 40, cornerRadius: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        Text(track.artistNames)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 8)
                                .contentShape(.dragPreview, Rectangle())
                                .listRowBackground(Color.white.opacity(0.06))
                                .listRowSeparator(.visible)
                                .listRowSeparatorTint(.white.opacity(0.08))
                            }
                            .onDelete(perform: viewModel.removeTrackFromQueue(at:))
                            .onMove(perform: viewModel.moveTrackInQueue(from:to:))
                        }
                        .listStyle(.plain)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 16)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .environment(\.editMode, .constant(.active))
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !viewModel.playbackQueue.isEmpty {
                        Button("Clear") {
                            viewModel.clearQueue()
                        }
                        .foregroundStyle(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}


