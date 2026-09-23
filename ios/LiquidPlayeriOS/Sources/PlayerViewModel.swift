import SwiftUI
import Combine
import MediaPlayer

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PlayerViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var lines: [LyricLine] = []
    @Published var currentTimeMs: Int = 0
    @Published var durationMs: Int = 0
    @Published var isPlaying: Bool = false
    #if canImport(UIKit)
    @Published var artwork: UIImage?
    #endif
    @Published var nowPlayingTitle: String = "No Track Playing"
    @Published var nowPlayingArtist: String = "Liquid Player"
    @Published var lyricsStatus: String = "Connect with Spotify to begin live playback."
    @Published var isLoadingLyrics: Bool = false
    @Published var errorMessage: String?
    @Published var lyricOffsetMs: Int = 0
    @Published var isShuffleEnabled: Bool = false
    @Published var isSpeaker: Bool = true
    @Published var authorMetadata: String = "Liquid Player"
    @Published var lyricsSource: String? = nil
    @Published var lyricsAttribution: SpicyUploadAttribution? = nil
    @Published var lyricsSongwriters: [String] = []
    @Published var currentTrackId: String?
    @Published var favoriteTrackIDs: Set<String> = []

    // Spotify & Search state
    @Published var spotifyService = SpotifyService()
    @Published var searchResults: [SpotifyTrackItem] = []
    @Published var isSearching: Bool = false
    @Published var recentTracks: [SpotifyTrackItem] = []
    @Published var playbackQueue: [SpotifyTrackItem] = []

    // Settings
    @Published var isRomanizationEnabled: Bool = UserDefaults.standard.object(forKey: "LiquidPlayeriOS.isRomanizationEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isRomanizationEnabled, forKey: "LiquidPlayeriOS.isRomanizationEnabled")
        }
    }
    @Published var isTranslationEnabled: Bool = UserDefaults.standard.object(forKey: "LiquidPlayeriOS.isTranslationEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isTranslationEnabled, forKey: "LiquidPlayeriOS.isTranslationEnabled")
        }
    }

    var selectedTrackID: String? {
        currentTrackId
    }

    private var cancellables = Set<AnyCancellable>()
    private var interpolationTimer: Timer?
    private var lastSyncTime: Date = Date()
    private var lastSyncProgressMs: Int = 0
    private var currentLyricsTrackId: String?

    init() {
        if let savedFavorites = UserDefaults.standard.stringArray(forKey: "LiquidPlayeriOS.favoriteTrackIDs") {
            favoriteTrackIDs = Set(savedFavorites)
        }
        bindSpotifyService()
        startInterpolationTimer()
        setupNowPlayingRemoteCommands()
    }

    deinit {
        interpolationTimer?.invalidate()
    }

    // MARK: - Spotify Binding & State Sync
    private func bindSpotifyService() {
        spotifyService.$currentTrack
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                if let track = track {
                    self.updateTrackInfo(track)
                }
            }
            .store(in: &cancellables)

        spotifyService.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self = self else { return }
                self.isPlaying = playing
                if playing {
                    self.lastSyncTime = Date()
                    self.lastSyncProgressMs = self.currentTimeMs
                } else {
                    self.lastSyncProgressMs = self.currentTimeMs
                }
            }
            .store(in: &cancellables)

        spotifyService.$progressMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self = self else { return }
                let now = Date()
                if !self.isPlaying {
                    self.lastSyncProgressMs = progress
                    self.lastSyncTime = now
                    self.currentTimeMs = progress
                } else {
                    let elapsed = now.timeIntervalSince(self.lastSyncTime)
                    let currentInterpolated = self.lastSyncProgressMs + Int(elapsed * 1000.0)
                    let diff = progress - currentInterpolated

                    if abs(diff) > 2000 {
                        // Large discrepancy (user seeked or track jumped): hard sync
                        self.lastSyncProgressMs = progress
                        self.lastSyncTime = now
                        self.currentTimeMs = progress
                    } else if abs(diff) > 400 {
                        // Moderate drift: soft nudge towards Spotify without jarring jump
                        let nudge = diff / 3
                        self.lastSyncProgressMs = currentInterpolated + nudge
                        self.lastSyncTime = now
                        self.currentTimeMs = self.lastSyncProgressMs
                    } else {
                        // Normal playback jitter (< 400ms): re-anchor seamlessly with zero backwards jump
                        self.lastSyncProgressMs = currentInterpolated
                        self.lastSyncTime = now
                    }
                }
            }
            .store(in: &cancellables)

        spotifyService.$durationMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self = self else { return }
                if duration > 0 {
                    self.durationMs = duration
                }
            }
            .store(in: &cancellables)

        spotifyService.$isShuffleEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shuffle in
                guard let self = self else { return }
                self.isShuffleEnabled = shuffle
            }
            .store(in: &cancellables)
    }

    private func updateTrackInfo(_ track: SpotifyTrackItem) {
        nowPlayingTitle = track.name
        nowPlayingArtist = track.artistNames
        authorMetadata = track.artistNames
        durationMs = track.duration_ms ?? 0
        currentTrackId = track.id

        if !recentTracks.contains(where: { $0.id == track.id }) {
            recentTracks.insert(track, at: 0)
            if recentTracks.count > 30 {
                recentTracks.removeLast()
            }
        }

        #if canImport(UIKit)
        if let artworkUrl = track.album?.images?.first?.url, let url = URL(string: artworkUrl) {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        self.artwork = image
                    }
                }
            }
        }
        #endif

        if let trackId = track.id, trackId != currentLyricsTrackId {
            currentLyricsTrackId = trackId
            self.lines = []
            Task {
                await fetchLyricsForTrack(trackId: trackId, trackTitle: track.name)
            }
        }
    }

    func fetchLyricsForTrack(trackId: String, trackTitle: String) async {
        isLoadingLyrics = true
        lyricsStatus = "Fetching synced lyrics from Spicy Lyrics..."
        errorMessage = nil

        do {
            let parsed = try await SpicyLyricsService.shared.fetchLyrics(for: trackId)
            self.lines = parsed.lines
            self.isLoadingLyrics = false
            self.lyricsStatus = parsed.lines.isEmpty ? "" : "Synced with Spicy Lyrics"
            self.lyricsSource = parsed.source
            self.lyricsAttribution = parsed.attribution
            self.lyricsSongwriters = parsed.songwriters
            self.authorMetadata = nowPlayingArtist
        } catch {
            self.isLoadingLyrics = false
            self.lyricsStatus = ""
            self.lines = []
            self.lyricsSource = nil
            self.lyricsAttribution = nil
            self.lyricsSongwriters = []
            self.authorMetadata = nowPlayingArtist
        }
    }

    // MARK: - High-Frequency Smooth Interpolation
    private func startInterpolationTimer() {
        interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            let elapsed = Date().timeIntervalSince(self.lastSyncTime)
            let interpolated = self.lastSyncProgressMs + Int(elapsed * 1000.0)
            self.currentTimeMs = min(interpolated, self.durationMs)
        }
    }

    // MARK: - Controls
    func togglePlayback() {
        togglePlayPause()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        Task {
            await spotifyService.play()
        }
    }

    func pause() {
        isPlaying = false
        lastSyncProgressMs = currentTimeMs
        Task {
            await spotifyService.pause()
        }
    }

    func playNextTrack() {
        nextTrack()
    }

    func nextTrack() {
        Task {
            await spotifyService.next()
        }
    }

    func playPreviousTrack() {
        previousTrack()
    }

    func previousTrack() {
        Task {
            await spotifyService.previous()
        }
    }

    func seek(to positionMs: Int) {
        lastSyncProgressMs = positionMs
        lastSyncTime = Date()
        currentTimeMs = positionMs
        Task {
            await spotifyService.seek(to: positionMs)
        }
    }

    func toggleShuffle() {
        Task {
            await spotifyService.toggleShuffle()
        }
    }

    func adjustLyricOffset(by deltaMs: Int) {
        lyricOffsetMs = min(max(lyricOffsetMs + deltaMs, -5000), 5000)
    }

    func resetLyricOffset() {
        lyricOffsetMs = 0
    }

    func activeLineID() -> UUID? {
        activeLineID(for: currentTimeMs)
    }

    func activeLineID(for timeMs: Int) -> UUID? {
        // 1. Inside an active sung line or interlude
        if let current = lines.first(where: { !$0.isBackground && !$0.isSongwriter && $0.startMs <= timeMs && timeMs <= $0.endMs }) {
            return current.id
        }
        // 2. In between lines: stay on the most recently started line (never rewind backwards!)
        if let lastStarted = lines.filter({ !$0.isBackground && !$0.isSongwriter && $0.startMs <= timeMs }).last {
            return lastStarted.id
        }
        // 3. Fallback to first line
        return lines.first(where: { !$0.isBackground && !$0.isSongwriter })?.id
    }

    func isTrackFavorite(_ trackId: String) -> Bool {
        favoriteTrackIDs.contains(trackId)
    }

    func isCurrentTrackFavorite() -> Bool {
        guard let id = currentTrackId else { return false }
        return isTrackFavorite(id)
    }

    func toggleFavoriteCurrentTrack() {
        guard let id = currentTrackId else { return }
        toggleFavorite(id)
    }

    func toggleFavorite(_ trackId: String) {
        if favoriteTrackIDs.contains(trackId) {
            favoriteTrackIDs.remove(trackId)
        } else {
            favoriteTrackIDs.insert(trackId)
        }
        UserDefaults.standard.set(Array(favoriteTrackIDs), forKey: "LiquidPlayeriOS.favoriteTrackIDs")
    }

    private var searchDebounceTask: Task<Void, Never>?

    func searchTracks(query: String, debounce: Bool = false) {
        searchDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchDebounceTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled else { return }
            let results = await spotifyService.searchTracks(query: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    func playSpotifyTrack(_ track: SpotifyTrackItem) {
        guard let uri = track.uri else { return }
        updateTrackInfo(track)
        Task {
            await spotifyService.playTrack(uri: uri)
        }
    }

    func loadDirectSpotifyTrack(idOrUrl: String) {
        var cleanId = idOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanId.contains("/track/") {
            let parts = cleanId.components(separatedBy: "/track/")
            if let lastPart = parts.last {
                cleanId = lastPart.components(separatedBy: "?").first ?? lastPart
            }
        }

        guard cleanId.count == 22 else {
            errorMessage = "Please enter a valid 22-character Spotify track ID or track URL."
            return
        }

        Task {
            if let track = await spotifyService.fetchTrack(id: cleanId) {
                await MainActor.run {
                    self.playSpotifyTrack(track)
                }
            } else {
                await MainActor.run {
                    self.currentTrackId = cleanId
                    self.nowPlayingTitle = "Spotify Track (\(cleanId.prefix(6))...)"
                }
                await fetchLyricsForTrack(trackId: cleanId, trackTitle: cleanId)
            }
        }
    }

    // MARK: - Remote Commands
    private func setupNowPlayingRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextTrack()
            return .success
        }
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousTrack()
            return .success
        }
    }

    // MARK: - Queue & Shuffle Helpers
    func removeTrackFromQueue(at offsets: IndexSet) {
        playbackQueue.remove(atOffsets: offsets)
    }

    func moveTrackInQueue(from source: IndexSet, to destination: Int) {
        playbackQueue.move(fromOffsets: source, toOffset: destination)
    }

    func clearQueue() {
        playbackQueue.removeAll()
    }

    func shufflePlay(tracks: [SpotifyTrackItem]? = nil) async {
        let pool = tracks ?? (!searchResults.isEmpty ? searchResults : recentTracks)
        guard let randomTrack = pool.randomElement() else { return }
        playSpotifyTrack(randomTrack)
    }
}

