import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController(floatingLyricsVisible: AppPreferences.floatingLyricsVisible)
    private let translation = LocalTranslationService()
    private let onlineTranslation = OnlineTranslationService()
    private let artwork = ArtworkService()
    private let settings = SettingsWindowController()
    private let floating = FloatingLyricsController()
    private let playbackMonitor = PlaybackMonitor()
    private let lyricsService = LyricsService()
    private let playbackController = MusicPlaybackController()
    private let updateService = UpdateService()
    private let logger = DiagnosticLogger.shared

    private var currentTrackKey: String?
    private var latestTrack: TrackInfo?
    private var currentLyrics: LyricsDocument = .empty
    private var sourceLyrics: LyricsDocument = .empty
    private var translatedLyrics: LyricsDocument?
    private var automaticTranslationEnabled = AppPreferences.automaticTranslation
    private var translationProvider = AppPreferences.translationProvider
    private var lyricsGeneration = UUID()
    private var isLoadingLyrics = false
    private var showsLoadingState = false
    private var lastLyricsAttempt = Date.distantPast
    private var lyricsRetryDelay: TimeInterval = 2
    private var lyricsTask: Task<Void, Never>?
    private var forceRefresh = false
    private var lastDisplayedLine: String?
    private var lastTrackKeyForUI: String?
    private var lastLoggedPlaybackState: String?
    private var updateTask: Task<Void, Never>?
    private var needlePlaybackTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.migrate()
        logger.startSession()
        if let host = translation.hostView { floating.attachTranslationHost(host) }
        translation.onStatus = { [weak self] status in
            guard let self else { return }
            let reason = self.onlineTranslation.fallback?.reason
            self.settings.actions.translationStatus = reason.map { "\($0)\n\(status)" } ?? status
        }
        onlineTranslation.onStatus = { [weak self] in self?.settings.actions.translationStatus = $0 }
        translation.onResult = { [weak self] in self?.applyTranslation($0) }
        onlineTranslation.onResult = translation.onResult
        onlineTranslation.onFallback = { [weak self] document, track, fallback in
            self?.translation.startFallback(document: document, track: track, pendingLineIDs: fallback.pendingLineIDs,
                                            onlineTranslations: fallback.onlineTranslations)
        }
        settings.actions.retryLocalTranslation = { [weak self] in
            guard let self, AppPreferences.translationProvider == .local else { return }
            self.translation.cancel()
            self.updateTranslationDemand()
        }
        settings.actions.onlineTranslationConfigurationChanged = { [weak self] in
            guard let self, AppPreferences.translationProvider == .online else { return }
            self.resetTranslation()
            self.updateTranslationDemand()
        }
        settings.actions.retryOnlineTranslation = { [weak self] in
            guard let self, AppPreferences.translationProvider == .online else { return }
            self.cancelTranslation()
            self.updateTranslationDemand()
        }
        artwork.onChange = { [weak self] image in
            self?.menuBar.setArtwork(image)
            self?.floating.setArtwork(image)
        }
        playbackMonitor.onUpdate = { [weak self] result in
            self?.handlePlaybackUpdate(result)
        }
        settings.actions.refresh = { [weak self] in
            self?.forceRefreshLyrics()
        }
        settings.actions.floatingLyricsColorChanged = { [weak self] in
            self?.floating.reloadLyricsColor()
        }
        settings.actions.floatingLyricsFontSizeChanged = { [weak self] in
            self?.floating.reloadLyricsFontSize()
        }
        settings.actions.previewGlassTransparency = { [weak self] transparency in
            self?.floating.setGlassTransparency(transparency)
        }
        settings.actions.floatingLyricsShadowChanged = { [weak self] in
            self?.floating.updateBackdropAppearance()
        }
        settings.actions.floatingPositionLockChanged = { [weak self] in
            self?.floating.applyPositionLock()
        }
        settings.actions.checkUpdates = { [weak self] in
            self?.checkForUpdates(manual: true)
        }
        menuBar.onLyricsAppearanceChanged = { [weak self] in self?.floating.setMenuBarAppearance($0) }
        menuBar.onSettings = { [weak self] in self?.settings.show() }
        menuBar.onShowLyrics = { [weak self] in self?.floating.showFromPlayer() }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: AppPreferences.didChange, object: nil)
        menuBar.onSeek = { [weak self] position in
            self?.playbackController.seek(to: position) {
                self?.resetPlaybackClocks()
                self?.playbackMonitor.sampleNow()
            }
        }
        let previousTrack: () -> Void = { [weak self] in
            self?.performDirectTransport(.previous)
        }
        menuBar.onPreviousTrack = previousTrack
        floating.onPreviousTrack = previousTrack
        let togglePlayPause: () -> Void = { [weak self] in
            self?.performDirectTransport(.toggle)
        }
        menuBar.onTogglePlayPause = togglePlayPause
        floating.onTogglePlayPause = togglePlayPause
        floating.onVinylTogglePlayPause = { [weak self] in
            self?.performVinylTransport(.toggle)
        }
        let nextTrack: () -> Void = { [weak self] in
            self?.performDirectTransport(.next)
        }
        menuBar.onNextTrack = nextTrack
        floating.onNextTrack = nextTrack
        menuBar.onOpenMusic = { [weak self] in
            self?.openMusic()
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }

        floating.onSeek = { [weak self] position in
            self?.playbackController.seek(to: position) {
                self?.resetPlaybackClocks()
                self?.playbackMonitor.sampleNow()
            }
        }
        floating.onVisibilityChanged = { [weak self] visible in
            self?.menuBar.setFloatingLyricsVisible(visible)
            guard AppPreferences.floatingLyricsVisible != visible else { return }
            AppPreferences.floatingLyricsVisible = visible
            self?.updateTranslationDemand()
        }
        let showFloating = AppPreferences.floatingLyricsVisible
        floating.setVisible(showFloating)



        menuBar.apply(status: .idle)
        floating.apply(status: .idle)
        playbackMonitor.start()
        settings.actions.updateStatus = UpdateService.isConfigured ? "从自有 GitHub 仓库获取更新" : "自有 GitHub 更新源待配置"
        checkForUpdates(manual: false)
    }

    @objc private func preferencesChanged() {
        let automaticTranslation = AppPreferences.automaticTranslation
        let provider = AppPreferences.translationProvider
        if automaticTranslation != automaticTranslationEnabled || provider != translationProvider {
            automaticTranslationEnabled = automaticTranslation
            translationProvider = provider
            translatedLyrics = nil
            cancelTranslation()
        }
        floating.applyPreferences()
        floating.setVisible(AppPreferences.floatingLyricsVisible)
        menuBar.reloadAppearance()
        if let track = latestTrack {
            rebuildPresentation(for: track)
            lastDisplayedLine = nil
            handle(track: track)
        }
        updateTranslationDemand()
    }

    private func updateTranslationDemand() {
        guard AppPreferences.automaticTranslation else {
            settings.actions.translationStatus = "自动翻译已关闭。尚未发起联网请求。"
            return
        }
        let online = AppPreferences.translationProvider == .online
        guard let track = latestTrack else {
            settings.actions.translationStatus = online ? "尚未发起联网请求。没有当前歌曲。" : "没有当前歌曲。"
            return
        }
        guard floating.isVisible, AppPreferences.floatingLyricsShowTranslation else {
            translation.suspend()
            onlineTranslation.suspend()
            if online, onlineTranslation.fallback == nil {
                settings.actions.translationStatus = onlineTranslation.statusWhileHidden
            }
            return
        }
        guard !sourceLyrics.lines.isEmpty else {
            let reason = isLoadingLyrics ? "正在读取当前歌曲的歌词。" : "当前歌曲没有可用歌词。"
            settings.actions.translationStatus = online ? "尚未发起联网请求。\(reason)" : reason
            return
        }
        switch AppPreferences.translationProvider {
        case .local: translation.start(document: sourceLyrics, track: track)
        case .online:
            guard let configuration = AppPreferences.onlineTranslationProfiles.activeConfiguration else {
                settings.actions.translationStatus = "尚未发起联网请求。请先选择一个已保存的 API。"
                return
            }
            onlineTranslation.start(document: sourceLyrics, track: track, configuration: configuration)
        }
    }

    private func applyTranslation(_ document: LyricsDocument?) {
        translatedLyrics = document
        guard let track = latestTrack else { return }
        rebuildPresentation(for: track)
        lastDisplayedLine = nil
        handle(track: track)
    }

    private func resetTranslation() {
        cancelTranslation()
        applyTranslation(nil)
    }

    private func cancelTranslation() {
        translation.cancel()
        onlineTranslation.cancel()
    }

    private func rebuildPresentation(for track: TrackInfo) {
        let lyrics = AppPreferences.automaticTranslation ? (translatedLyrics ?? sourceLyrics) : sourceLyrics
        currentLyrics = AppPreferences.gapAnimation ? lyrics.addingGaps(duration: track.duration) : lyrics
    }

    private func performDirectTransport(_ command: MusicPlaybackController.Command) {
        if let needlePlaybackTask {
            needlePlaybackTask.cancel()
            playbackMonitor.cancelCommandConfirmation()
        }
        playbackController.perform(command) { [weak self] _ in self?.playbackMonitor.sampleNow() }
    }

    private func performVinylTransport(_ command: MusicPlaybackController.Command) {
        guard needlePlaybackTask == nil else { return }
        guard floating.showsVinyl, let track = latestTrack,
              track.state == .playing || track.state == .paused else {
            performDirectTransport(command)
            return
        }
        needlePlaybackTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.floating.finishNeedleCue()
                self.needlePlaybackTask = nil
            }
            guard !Task.isCancelled else { return }
            await NeedlePlayback.run(
                command, startingAt: track,
                moveNeedle: { await self.floating.cueNeedle(ontoRecord: $0) },
                perform: { await self.performAndSample($0) },
                currentTrack: { self.latestTrack }
            )
        }
    }

    private func performAndSample(_ command: MusicPlaybackController.Command) async -> Bool {
        guard !Task.isCancelled else { return false }
        let trackKey = latestTrack?.identityKey
        guard await playbackController.perform(command), !Task.isCancelled else { return false }
        let expectation: PlaybackMonitor.CommandExpectation
        switch command {
        case .play: expectation = .init(state: .playing, trackKey: trackKey)
        case .pause: expectation = .init(state: .paused, trackKey: trackKey)
        case .cuePrevious, .cueNext: expectation = .init(state: .paused, trackKey: nil)
        default: return false
        }
        return await playbackMonitor.confirmCommand(expectation)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        floating.savePendingPosition()
        logger.info("Application terminating")
        cancelTranslation()
        updateTask?.cancel()
        needlePlaybackTask?.cancel()
        lyricsTask?.cancel()
        playbackMonitor.stop()
        logger.flush()
    }

    // MARK: - Updates

    private func checkForUpdates(manual: Bool) {
        guard UpdateService.isConfigured else { return }
        if !manual,
           let lastCheck = AppPreferences.lastUpdateCheck,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }
        guard updateTask == nil else { return }

        settings.actions.checkingUpdates = true
        settings.actions.updateStatus = "正在查询 GitHub 最新版本…"
        updateTask = Task { [weak self, updateService] in
            do {
                let update = try await updateService.checkForUpdate()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                AppPreferences.lastUpdateCheck = Date()
                self.updateTask = nil
                self.settings.actions.checkingUpdates = false
                if let update {
                    let version = update.version.description
                    self.settings.actions.updateStatus = "发现新版本 \(version)"
                    if manual || AppPreferences.lastNotifiedUpdateVersion != version {
                        AppPreferences.lastNotifiedUpdateVersion = version
                        self.present(update: update)
                    }
                } else {
                    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    self.settings.actions.updateStatus = installed.map { "当前版本 \($0) 已是最新版本。" } ?? "当前已是最新版本。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.updateTask = nil
                self.settings.actions.checkingUpdates = false
                self.settings.actions.updateStatus = "检查失败：\(error.localizedDescription)"
                self.logger.warning("Update check failed: \(error.localizedDescription)")
                if manual {
                    self.presentMessage(
                        title: "无法检查更新",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func present(update: AppUpdate) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(update.version)"
        alert.informativeText = "可以从 GitHub 下载新版安装镜像，下载完成后会验证 SHA-256 校验值。"
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "查看发布页")
        alert.addButton(withTitle: "稍后")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            download(update)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.releasePageURL)
        default:
            break
        }
    }

    private func download(_ update: AppUpdate) {
        settings.actions.checkingUpdates = true
        settings.actions.updateStatus = "正在下载并校验 \(update.version)…"
        updateTask = Task { [weak self, updateService] in
            do {
                let fileURL = try await updateService.download(update)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.updateTask = nil
                self.settings.actions.checkingUpdates = false
                self.settings.actions.updateStatus = "已下载并校验 \(update.version)"
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                self.presentMessage(
                    title: "更新已下载",
                    message: "安装镜像已通过完整性校验并保存到“下载”文件夹。"
                )
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.updateTask = nil
                self.settings.actions.checkingUpdates = false
                self.settings.actions.updateStatus = "下载失败：\(error.localizedDescription)"
                self.logger.warning("Update download failed: \(error.localizedDescription)")
                self.presentMessage(title: "下载更新失败", message: error.localizedDescription)
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func openMusic() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Music"
        ) else {
            logger.warning("Unable to locate Music.app")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { [logger] _, error in
            if let error {
                logger.warning("Unable to open Music.app: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Playback updates

    private func handlePlaybackUpdate(_ result: PlaybackMonitor.Update) {
        switch result {
        case .failure(let error):
            currentTrackKey = nil
            lyricsGeneration = UUID()
            lyricsTask?.cancel()
            isLoadingLyrics = false
            cancelTranslation()
            latestTrack = nil
            updateTranslationDemand()
            let message = error.localizedDescription
            let isNewError = lastLoggedPlaybackState != "error"
            logPlaybackState("error")
            if isNewError {
                logger.error("Music AppleScript request failed: \(message)")
            }
            if message.localizedCaseInsensitiveContains("not allowed")
                || message.localizedCaseInsensitiveContains("(-1743)")
                || message.localizedCaseInsensitiveContains("authorization") {
                apply(.error("请在系统设置的「隐私与安全性 → 自动化」中允许访问音乐。"))
            } else {
                apply(.error("读取播放状态失败，请在设置中查看诊断信息。"))
            }

        case .track(let track):
            logPlaybackState("track available")
            latestTrack = track
            handle(track: track)

        case .stopped:
            logPlaybackState("playback stopped")
            latestTrack = nil
            cancelTranslation()
            lyricsGeneration = UUID()
            lyricsTask?.cancel()
            currentTrackKey = nil
            sourceLyrics = .empty
            translatedLyrics = nil
            currentLyrics = .empty
            updateTranslationDemand()
            apply(.stopped)

        case .musicNotRunning:
            logPlaybackState("Music.app not running")
            latestTrack = nil
            cancelTranslation()
            lyricsGeneration = UUID()
            lyricsTask?.cancel()
            currentTrackKey = nil
            sourceLyrics = .empty
            translatedLyrics = nil
            currentLyrics = .empty
            updateTranslationDemand()
            apply(.musicNotRunning)
        }
    }

    private func handle(track: TrackInfo) {
        let key = track.identityKey
        let trackChanged = currentTrackKey != key

        if trackChanged || forceRefresh {
            logger.info(
                "Lyrics lookup triggered; reason=\(trackChanged ? "track changed" : "manual refresh"); "
                    + "track=\(track.displayName); duration=\(Int(track.duration.rounded()))"
            )
            cancelTranslation()
            sourceLyrics = .empty
            translatedLyrics = nil
            currentTrackKey = key
            currentLyrics = .empty
            forceRefresh = false
            lyricsRetryDelay = 2
            loadLyrics(for: track, showLoading: true)
            apply(.loadingLyrics(track))
            return
        }

        if isLoadingLyrics {
            apply(showsLoadingState ? .loadingLyrics(track) : .noLyrics(track))
            return
        }

        if currentLyrics.isSynced, let line = currentLyrics.line(at: track.position) {
            let text = line.text.isEmpty ? track.displayName : line.text
            apply(.showing(track: track, lyrics: currentLyrics, currentLine: text))
        } else if currentLyrics.isSynced {
            apply(.showing(track: track, lyrics: currentLyrics, currentLine: track.displayName))
        } else if let plain = currentLyrics.plainText, !plain.isEmpty {
            apply(.showing(track: track, lyrics: currentLyrics, currentLine: track.displayName))
        } else {
            // Music may write the lyrics response shortly after the track-change
            // notification. Rescan quietly until the local cache catches up.
            if Date().timeIntervalSince(lastLyricsAttempt) >= lyricsRetryDelay {
                lyricsRetryDelay = min(30, lyricsRetryDelay * 2)
                loadLyrics(for: track, showLoading: false)
            }
            apply(.noLyrics(track))
        }
    }

    private func loadLyrics(for track: TrackInfo, showLoading: Bool) {
        lyricsTask?.cancel()
        isLoadingLyrics = true
        showsLoadingState = showLoading
        lastLyricsAttempt = Date()
        let key = track.identityKey
        lyricsGeneration = UUID()
        let generation = lyricsGeneration
        updateTranslationDemand()

        lyricsTask = Task { [weak self, lyricsService] in
            let document = await lyricsService.lyrics(for: track)
            guard !Task.isCancelled, let self, self.currentTrackKey == key,
                  self.lyricsGeneration == generation else { return }
            self.lyricsTask = nil
            self.sourceLyrics = document
            self.translatedLyrics = nil
            self.rebuildPresentation(for: track)
            self.isLoadingLyrics = false
            self.showsLoadingState = false
            if let latestTrack = self.latestTrack, latestTrack.identityKey == key {
                self.handle(track: latestTrack)
                self.updateTranslationDemand()
            }
        }
    }

    private func forceRefreshLyrics() {
        cancelTranslation()
        lyricsTask?.cancel()
        lyricsGeneration = UUID()
        logger.info("Manual lyrics refresh requested")
        currentTrackKey = nil
        lastDisplayedLine = nil
        lastTrackKeyForUI = nil
        forceRefresh = true
        playbackMonitor.sampleNow()
    }

    private func logPlaybackState(_ state: String) {
        guard lastLoggedPlaybackState != state else { return }
        lastLoggedPlaybackState = state
        logger.info("Playback state: \(state)")
    }

    private func resetPlaybackClocks() {
        menuBar.resetPlaybackClock()
        floating.resetPlaybackClock()
        lastDisplayedLine = nil
    }

    private func apply(_ status: AppStatus) {
        let url: URL?
        if case .showing(_, let lyrics, _) = status { url = lyrics.artworkURL } else { url = nil }
        artwork.update(track: status.track, url: url)
        // Skip full menu rebuild when the visible lyric line is unchanged.
        if case .showing(let track, let lyrics, let currentLine) = status {
            if lastTrackKeyForUI == track.identityKey, lastDisplayedLine == currentLine {
                menuBar.updateKaraokeProgress(track: track, lyrics: lyrics)
                floating.updateHighlight(for: track, lyrics: lyrics)
                return
            }
            lastTrackKeyForUI = track.identityKey
            lastDisplayedLine = currentLine
        } else {
            lastDisplayedLine = nil
            lastTrackKeyForUI = nil
        }

        menuBar.apply(status: status)
        floating.apply(status: status)
    }
}
