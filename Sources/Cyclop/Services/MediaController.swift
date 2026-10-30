import AppKit

/// Reads and controls Apple Music and Spotify through their AppleScript APIs.
/// Browser players are not visible through this public scripting route.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var key: String
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkIsPending = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var sourceName: String?
    @Published private(set) var canSkip = true

    private var activeApp: PlayerApp?
    private var artworkKey: String?
    private var artworkDeadline: DispatchWorkItem?
    private var anchor: (position: TimeInterval, at: Date)?
    private var pendingSeek: (target: TimeInterval, at: Date)?
    private var ticker: Timer?
    private var observers: [Any] = []
    private var isStarted = false
    private var isActive = false

    func start() {
        isStarted = true
        if isActive {
            observePlayers()
            refreshFromPlayers()
        }
    }

    func stop() {
        isStarted = false
        removeObservers()
        artworkDeadline?.cancel()
        artworkDeadline = nil
        ticker?.invalidate()
        ticker = nil
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active && isStarted {
            observePlayers()
            refreshFromPlayers()
        } else {
            removeObservers()
            updateTicker()
        }
    }

    func togglePlayPause() {
        guard let activeApp else { return }
        isPlaying.toggle()
        setAnchor(position)
        PlayerBridge.playPause(activeApp)
    }

    func next() {
        guard let activeApp else { return }
        PlayerBridge.next(activeApp)
    }

    func previous() {
        guard let activeApp else { return }
        PlayerBridge.previous(activeApp)
    }

    func seek(to seconds: TimeInterval) {
        guard let activeApp, duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        pendingSeek = (clamped, Date())
        PlayerBridge.seek(activeApp, to: clamped)
    }

    private func observePlayers() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            observers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFromPlayers() }
            })
        }
    }

    private func removeObservers() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
    }

    private func refreshFromPlayers() {
        guard isStarted, isActive else { return }
        PlayerBridge.currentState { [weak self] state in
            guard let self else { return }
            guard let state else { return self.clear() }

            self.activeApp = state.app
            self.sourceName = state.app.displayName
            self.track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
            self.isPlaying = state.isPlaying
            self.duration = state.duration
            self.canSkip = true

            if let pending = self.pendingSeek {
                let settled = abs(state.position - pending.target) < 2.5
                let expired = Date().timeIntervalSince(pending.at) > 1.5
                if settled || expired {
                    self.pendingSeek = nil
                    self.adopt(state.position)
                }
            } else {
                self.adopt(state.position)
            }
            self.updateTicker()

            guard self.artworkKey != state.key else { return }
            self.artworkKey = state.key
            self.artwork = nil
            self.expectArtwork(for: state.key)
            PlayerBridge.artwork(for: state) { [weak self] image in
                guard let self, self.artworkKey == state.key else { return }
                self.settleArtwork(image)
            }
        }
    }

    private func expectArtwork(for key: String) {
        artworkDeadline?.cancel()
        artworkIsPending = true
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.artworkKey == key, self.artwork == nil else { return }
                self.artworkIsPending = false
            }
        }
        artworkDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: deadline)
    }

    private func settleArtwork(_ image: NSImage?) {
        artworkDeadline?.cancel()
        artworkDeadline = nil
        artwork = image
        artworkIsPending = false
    }

    private func clear() {
        activeApp = nil
        track = nil
        artworkKey = nil
        settleArtwork(nil)
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        canSkip = true
        pendingSeek = nil
        updateTicker()
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, Date())
    }

    private func adopt(_ reported: TimeInterval) {
        let value = max(0, duration > 0 ? min(reported, duration) : reported)
        let delta = value - position
        if delta >= 0.75 || delta <= -2 {
            position = value
            anchor = (value, Date())
        } else {
            anchor = (position, Date())
        }
    }

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        guard isPlaying, isActive else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let anchor, isPlaying else { return }
        let value = anchor.position + Date().timeIntervalSince(anchor.at)
        position = duration > 0 ? min(value, duration) : value
    }
}
