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
    private var lyricsCache: [String: ParsedLyrics] = [:]
    private var hasPrefetchedForCurrentTrackEnding: Bool = false
    private var isPrefetchingQueue: Bool = false
    private var seekLockoutUntil: Date = .distantPast
    private var seekTargetMs: Int = 0

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

                // If user recently seeked, ignore stale pre-seek updates from Spotify
                if now < self.seekLockoutUntil {
                    let elapsedSinceSeek = max(0, now.timeIntervalSince(self.seekLockoutUntil.addingTimeInterval(-1.6)))
                    let expectedProgress = self.seekTargetMs + Int(elapsedSinceSeek * 1000.0)
                    if abs(progress - expectedProgress) > 1200 {
                        // Stale pre-seek report from Spotify, ignore!
                        return
                    }
                    // Spotify has caught up with our seek!
                    self.seekLockoutUntil = .distantPast
                }

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

        LibraryManager.shared.recordSongPlayed(from: track)

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
            hasPrefetchedForCurrentTrackEnding = false

            // If lyrics were prefetched ahead of time, apply instantly with zero loading spinner!
            if let cached = lyricsCache[trackId] {
                self.lines = cached.lines
                self.isLoadingLyrics = false
                self.lyricsStatus = cached.lines.isEmpty ? "" : "Synced with Spicy Lyrics"
                self.lyricsSource = cached.source
                self.lyricsAttribution = cached.attribution
                self.lyricsSongwriters = cached.songwriters
                self.authorMetadata = nowPlayingArtist
                LibraryManager.shared.saveLyrics(for: trackId, parsed: cached, track: track)
            } else {
                self.lines = []
                Task {
                    await fetchLyricsForTrack(trackId: trackId, trackTitle: track.name)
                }
            }

            // Immediately prefetch upcoming tracks while this track plays
            Task(priority: .background) {
                await self.prefetchUpcomingLyrics()
            }
        }
    }

    func fetchLyricsForTrack(trackId: String, trackTitle: String) async {
        if let cached = lyricsCache[trackId] {
            self.lines = cached.lines
            self.isLoadingLyrics = false
            self.lyricsStatus = cached.lines.isEmpty ? "" : "Synced with Spicy Lyrics"
            self.lyricsSource = cached.source
            self.lyricsAttribution = cached.attribution
            self.lyricsSongwriters = cached.songwriters
            self.authorMetadata = nowPlayingArtist
            LibraryManager.shared.saveLyrics(for: trackId, parsed: cached)
            return
        }

        // Check if we have valid (under 30 days) saved TTML in the library
        if let validTTML = LibraryManager.shared.getValidSavedTTML(for: trackId),
           let parsed = try? TTMLLyricsParser.parse(data: Data(validTTML.utf8)),
           !parsed.lines.isEmpty {
            self.lyricsCache[trackId] = parsed
            self.lines = parsed.lines
            self.isLoadingLyrics = false
            self.lyricsStatus = "Loaded from Saved TTML"
            self.lyricsSource = parsed.source ?? "Spicy Lyrics (Saved)"
            self.lyricsAttribution = parsed.attribution
            self.lyricsSongwriters = parsed.songwriters
            self.authorMetadata = nowPlayingArtist
            return
        }

        isLoadingLyrics = true
        lyricsStatus = "Fetching synced lyrics from Spicy Lyrics..."
        errorMessage = nil

        do {
            let parsed = try await SpicyLyricsService.shared.fetchLyrics(for: trackId)
            self.lyricsCache[trackId] = parsed
            self.lines = parsed.lines
            self.isLoadingLyrics = false
            self.lyricsStatus = parsed.lines.isEmpty ? "" : "Synced with Spicy Lyrics"
            self.lyricsSource = parsed.source
            self.lyricsAttribution = parsed.attribution
            self.lyricsSongwriters = parsed.songwriters
            self.authorMetadata = nowPlayingArtist
            if parsed.lines.isEmpty {
                LibraryManager.shared.markNoLyrics(for: trackId)
            } else {
                LibraryManager.shared.saveLyrics(for: trackId, parsed: parsed)
            }
        } catch {
            self.isLoadingLyrics = false
            self.lyricsStatus = ""
            self.lines = []
            self.lyricsSource = nil
            self.lyricsAttribution = nil
            self.lyricsSongwriters = []
            self.authorMetadata = nowPlayingArtist
            LibraryManager.shared.markNoLyrics(for: trackId)
        }
    }

    func playLibrarySong(_ song: LibrarySong) {
        Task {
            if let track = await spotifyService.fetchTrack(id: song.id) {
                await MainActor.run {
                    self.playSpotifyTrack(track)
                }
            } else {
                let uri = song.uri ?? "spotify:track:\(song.id)"
                await spotifyService.playTrack(uri: uri)
                await MainActor.run {
                    self.currentTrackId = song.id
                    self.nowPlayingTitle = song.name
                    self.nowPlayingArtist = song.artistNames
                }
                await fetchLyricsForTrack(trackId: song.id, trackTitle: song.name)
            }
        }
    }

    func shufflePlayLibrary() {
        let songs = LibraryManager.shared.songsPlayedInLast30Days
        guard !songs.isEmpty else { return }
        if let randomSong = songs.randomElement() {
            playLibrarySong(randomSong)
        }
    }

    // MARK: - High-Frequency Smooth Interpolation
    private func startInterpolationTimer() {
        interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            let elapsed = Date().timeIntervalSince(self.lastSyncTime)
            let interpolated = self.lastSyncProgressMs + Int(elapsed * 1000.0)
            self.currentTimeMs = min(interpolated, self.durationMs)

            // When song enters its final 35 seconds, ensure upcoming track lyrics are pre-fetched
            if self.durationMs > 40_000,
               self.currentTimeMs > (self.durationMs - 35_000),
               !self.hasPrefetchedForCurrentTrackEnding {
                self.hasPrefetchedForCurrentTrackEnding = true
                Task(priority: .background) {
                    await self.prefetchUpcomingLyrics()
                }
            }
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
        let now = Date()
        seekLockoutUntil = now.addingTimeInterval(1.6)
        seekTargetMs = positionMs
        lastSyncProgressMs = positionMs
        lastSyncTime = now
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
        let candidates = lines.filter { !$0.isBackground && !$0.isSongwriter }

        // 1. Inside an active sung line or interlude (preferring the starting/active line)
        if let current = candidates.filter({ $0.startMs <= timeMs && timeMs < $0.endMs }).last {
            return current.id
        }

        // 2. Exact boundary match on endMs fallback
        if let current = candidates.filter({ $0.startMs <= timeMs && timeMs <= $0.endMs }).last {
            return current.id
        }

        // 3. In between lines: stay on the most recently started line (never rewind backwards!)
        if let lastStarted = candidates.filter({ $0.startMs <= timeMs }).last {
            return lastStarted.id
        }

        // 4. Fallback to first line
        return candidates.first?.id
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

    // MARK: - Background Lyrics Prefetch Engine
    func prefetchUpcomingLyrics() async {
        guard !isPrefetchingQueue else { return }
        isPrefetchingQueue = true
        defer { isPrefetchingQueue = false }

        var trackIdsToPrefetch: [String] = []

        // 1. Tracks in manual / local playbackQueue
        for track in playbackQueue {
            if let id = track.id, lyricsCache[id] == nil, !trackIdsToPrefetch.contains(id) {
                trackIdsToPrefetch.append(id)
            }
        }

        // 2. Fetch live queue from Spotify
        if spotifyService.isAuthenticated {
            let upcoming = await spotifyService.fetchQueue()
            for track in upcoming {
                if let id = track.id, lyricsCache[id] == nil, !trackIdsToPrefetch.contains(id) {
                    trackIdsToPrefetch.append(id)
                }
            }
            if playbackQueue.isEmpty && !upcoming.isEmpty {
                self.playbackQueue = upcoming
            }
        }

        // 3. Sequential fallback from recentTracks or searchResults
        if let currentId = currentTrackId {
            if let idx = recentTracks.firstIndex(where: { $0.id == currentId }), idx + 1 < recentTracks.count {
                if let nextId = recentTracks[idx + 1].id, lyricsCache[nextId] == nil, !trackIdsToPrefetch.contains(nextId) {
                    trackIdsToPrefetch.append(nextId)
                }
            }
            if let idx = searchResults.firstIndex(where: { $0.id == currentId }), idx + 1 < searchResults.count {
                if let nextId = searchResults[idx + 1].id, lyricsCache[nextId] == nil, !trackIdsToPrefetch.contains(nextId) {
                    trackIdsToPrefetch.append(nextId)
                }
            }
        }

        // Prefetch lyrics for top 3 upcoming tracks in background
        for trackId in trackIdsToPrefetch.prefix(3) {
            guard lyricsCache[trackId] == nil else { continue }
            do {
                let parsed = try await SpicyLyricsService.shared.fetchLyrics(for: trackId)
                self.lyricsCache[trackId] = parsed
            } catch {
                // Silently ignore prefetch errors
            }
        }
    }
}

// MARK: - Library Manager
@MainActor
final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    private let storageKey = "LiquidPlayeriOS.librarySongs.v3"
    private let ttmlDirectoryName = "SavedTTML"

    @Published private(set) var songs: [LibrarySong] = []
    @Published var updatingTrackIds: Set<String> = []
    @Published var isBatchUpdating = false

    private init() {
        loadSongs()
        ensureTTMLDirectoryExists()
    }

    // All songs played in the last 30 days, sorted by most recently played first
    var songsPlayedInLast30Days: [LibrarySong] {
        songs.filter { $0.isPlayedInLast30Days }
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    // Songs in the last 30 days that have valid (non-expired) saved TTML
    var songsWithValidTTML: [LibrarySong] {
        songsPlayedInLast30Days.filter { $0.hasTTML && !$0.isTTMLExpired }
    }

    // Songs in the last 30 days whose TTML is missing or older than 30 days (needs update)
    var songsNeedingTTMLUpdate: [LibrarySong] {
        songsPlayedInLast30Days.filter { $0.needsUpdate }
    }

    // MARK: - Record Playback
    func recordSongPlayed(
        trackId: String,
        title: String,
        artist: String,
        album: String? = nil,
        artworkUrl: String? = nil,
        durationMs: Int = 0,
        uri: String? = nil
    ) {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        let now = Date()

        if let index = songs.firstIndex(where: { $0.id == cleanId }) {
            var existing = songs[index]
            existing.lastPlayedAt = now
            existing.name = title
            existing.artistNames = artist
            if let album = album { existing.albumName = album }
            if let artworkUrl = artworkUrl { existing.artworkUrl = artworkUrl }
            if durationMs > 0 { existing.durationMs = durationMs }
            if let uri = uri { existing.uri = uri }

            // Move to front
            songs.remove(at: index)
            songs.insert(existing, at: 0)
        } else {
            // Check if on-disk TTML file exists from previous sessions
            let (fileContent, fileSavedAt) = loadTTMLFromDisk(for: cleanId)

            let newSong = LibrarySong(
                id: cleanId,
                name: title,
                artistNames: artist,
                albumName: album,
                artworkUrl: artworkUrl,
                durationMs: durationMs,
                uri: uri,
                lastPlayedAt: now,
                ttmlContent: fileContent,
                ttmlSavedAt: fileSavedAt,
                lyricsSource: nil,
                hasNoLyrics: nil,
                lastCheckedForLyricsAt: fileSavedAt
            )
            songs.insert(newSong, at: 0)
        }

        saveSongs()
    }

    func recordSongPlayed(from track: SpotifyTrackItem) {
        guard let id = track.id else { return }
        recordSongPlayed(
            trackId: id,
            title: track.name,
            artist: track.artistNames,
            album: track.album?.name,
            artworkUrl: track.album?.images?.first?.url,
            durationMs: track.duration_ms ?? 0,
            uri: track.uri
        )
    }

    // MARK: - Save TTML
    func saveTTML(for trackId: String, ttml: String, source: String?) {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        let now = Date()
        writeTTMLToDisk(for: cleanId, content: ttml)

        if let index = songs.firstIndex(where: { $0.id == cleanId }) {
            songs[index].ttmlContent = ttml
            songs[index].ttmlSavedAt = now
            songs[index].lyricsSource = source
            songs[index].hasNoLyrics = false
            songs[index].lastCheckedForLyricsAt = now
        }
        saveSongs()
    }

    func markNoLyrics(for trackId: String) {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        let now = Date()
        if let index = songs.firstIndex(where: { $0.id == cleanId }) {
            songs[index].hasNoLyrics = true
            songs[index].lastCheckedForLyricsAt = now
            saveSongs()
        }
    }

    func saveLyrics(for trackId: String, parsed: ParsedLyrics, track: SpotifyTrackItem? = nil) {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        let title = track?.name ?? songs.first(where: { $0.id == cleanId })?.name
        let artist = track?.artistNames ?? songs.first(where: { $0.id == cleanId })?.artistNames

        let ttml = TTMLExporter.export(parsed: parsed, title: title, artist: artist)
        saveTTML(for: cleanId, ttml: ttml, source: parsed.source)
    }

    // MARK: - Retrieve Saved TTML
    /// Returns valid saved TTML if it is saved and LESS than 30 days old.
    /// Returns nil if not found or if expired (older than 30 days), triggering a fresh update.
    func getValidSavedTTML(for trackId: String) -> String? {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let song = songs.first(where: { $0.id == cleanId }) else {
            return nil
        }

        // Must have TTML and must not be expired (< 30 days)
        guard song.hasTTML, !song.isTTMLExpired, let content = song.ttmlContent else {
            return nil
        }
        return content
    }

    // MARK: - Refresh / Update TTML
    func updateTTML(for trackId: String) async -> Bool {
        let cleanId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return false }

        updatingTrackIds.insert(cleanId)
        defer { updatingTrackIds.remove(cleanId) }

        do {
            let parsed = try await SpicyLyricsService.shared.fetchLyrics(for: cleanId)
            if parsed.lines.isEmpty {
                markNoLyrics(for: cleanId)
                return true
            }
            let song = songs.first(where: { $0.id == cleanId })
            let ttml = TTMLExporter.export(parsed: parsed, title: song?.name, artist: song?.artistNames)
            saveTTML(for: cleanId, ttml: ttml, source: parsed.source)
            return true
        } catch {
            markNoLyrics(for: cleanId)
            return false
        }
    }

    // Update all songs played in the last 30 days whose saved TTML is older than 30 days
    func updateAllExpired() async {
        let expired = songsNeedingTTMLUpdate
        guard !expired.isEmpty else { return }

        isBatchUpdating = true
        defer { isBatchUpdating = false }

        for song in expired {
            _ = await updateTTML(for: song.id)
            // Polite delay between requests
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
    }

    func deleteSong(id: String) {
        songs.removeAll { $0.id == id }
        deleteTTMLFromDisk(for: id)
        saveSongs()
    }

    // MARK: - Persistence
    private func saveSongs() {
        if let encoded = try? JSONEncoder().encode(songs) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    private func loadSongs() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([LibrarySong].self, from: data) {
            self.songs = decoded
            return
        }

        // Migrate from v2: preserve played song history, but clear old TTML cache so clean lyrics are loaded
        if let oldData = UserDefaults.standard.data(forKey: "LiquidPlayeriOS.librarySongs.v2"),
           let oldDecoded = try? JSONDecoder().decode([LibrarySong].self, from: oldData) {
            self.songs = oldDecoded.map { song in
                var s = song
                s.ttmlContent = nil
                s.ttmlSavedAt = nil
                return s
            }
            saveSongs()
            try? FileManager.default.removeItem(at: ttmlDirectoryURL)
            ensureTTMLDirectoryExists()
        }
    }

    // MARK: - On-Disk TTML Files
    private var ttmlDirectoryURL: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return appSupport.appendingPathComponent(ttmlDirectoryName, isDirectory: true)
    }

    private func ensureTTMLDirectoryExists() {
        let dir = ttmlDirectoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func ttmlFileURL(for trackId: String) -> URL {
        ttmlDirectoryURL.appendingPathComponent("\(trackId).ttml")
    }

    private func writeTTMLToDisk(for trackId: String, content: String) {
        ensureTTMLDirectoryExists()
        let fileUrl = ttmlFileURL(for: trackId)
        try? content.write(to: fileUrl, atomically: true, encoding: .utf8)
    }

    private func loadTTMLFromDisk(for trackId: String) -> (String?, Date?) {
        let fileUrl = ttmlFileURL(for: trackId)
        guard FileManager.default.fileExists(atPath: fileUrl.path),
              let content = try? String(contentsOf: fileUrl, encoding: .utf8) else {
            return (nil, nil)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileUrl.path)
        let modDate = attributes?[.modificationDate] as? Date
        return (content, modDate)
    }

    private func deleteTTMLFromDisk(for trackId: String) {
        let fileUrl = ttmlFileURL(for: trackId)
        try? FileManager.default.removeItem(at: fileUrl)
    }
}


