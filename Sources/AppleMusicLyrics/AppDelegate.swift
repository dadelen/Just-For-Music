import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController(floatingLyricsVisible: AppPreferences.floatingLyricsVisible)
    private let translation = LocalTranslationService()
    private let onlineTranslation = OnlineTranslationService()
    private let artwork = ArtworkService()
    private let settings = SettingsWindowController()
    private let floating = FloatingLyricsController()
    private let applePlayback = PlaybackMonitor()
    private lazy var playback = PlaybackSession(appleMusic: applePlayback, netease: NetEasePlayback())
    private let lyricsService = LyricsService()
    private lazy var playbackController = MusicPlaybackController(monitor: playback)
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
    private var lastAppleMusicCacheRevision: AppleMusicCacheLyricsProvider.CacheRevision?
    private var lyricsRetryDelay: TimeInterval = 1.0
    private var lyricsTask: Task<Void, Never>?
    private var forceRefresh = false
    private var lastDisplayedLine: String?
    private var lastTrackKeyForUI: String?
    private var lastLoggedPlaybackState: String?
    private var updateTask: Task<Void, Never>?
    private var needlePlaybackTask: Task<Void, Never>?
    private var appleMusicAuthorizationProcess: Process?
    private var seekGeneration = 0

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
        playback.onUpdate = { [weak self] result in
            self?.handlePlaybackUpdate(result)
        }
        settings.actions.playbackSourceChanged = { [weak self] source in
            self?.selectPlayer(source)
        }
        settings.actions.authorizeAppleMusic = { [weak self] in self?.requestAppleMusicAutomation() }
        settings.actions.refreshAppleMusicCacheAccess = { [weak self] in
            guard let self else { return }
            let previouslyDenied = self.settings.actions.appleMusicCacheAccess == .denied
            if self.refreshAppleMusicCacheAccess() == .readable, previouslyDenied,
               self.playback.source == .appleMusic {
                self.forceRefreshLyrics()
            }
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
        settings.actions.floatingLyricsSize = { [weak self] mode in
            self?.floating.sizeOptions(for: mode)
                ?? (AppPreferences.floatingLyricsSize(for: mode), mode.minimumSize, mode.minimumSize)
        }
        settings.actions.floatingLyricsSizeChanged = { [weak self] mode, size in
            self?.floating.setSize(size, for: mode)
        }
        floating.onSizeChanged = { [weak self] in
            self?.settings.actions.floatingLyricsSizeRevision += 1
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
        menuBar.onSeek = { [weak self] position in self?.seek(to: position) }
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
            self?.toggleVinylPlayback()
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

        floating.onSeek = menuBar.onSeek
        floating.onVisibilityChanged = { [weak self] visible in
            self?.menuBar.setFloatingLyricsVisible(visible)
            guard AppPreferences.floatingLyricsVisible != visible else { return }
            AppPreferences.floatingLyricsVisible = visible
            self?.updateTranslationDemand()
        }
        let showFloating = AppPreferences.floatingLyricsVisible
        floating.setVisible(showFloating)
        selectPlayer(AppPreferences.playbackSource)
        settings.actions.updateStatus = UpdateService.isConfigured ? "从自有 GitHub 仓库获取更新" : "自有 GitHub 更新源待配置"
        checkForUpdates(manual: false)
    }

    private func selectPlayer(_ source: PlaybackSource) {
        guard playback.source != source else { return }
        needlePlaybackTask?.cancel()
        clearTrack()
        forceRefresh = false
        lastLoggedPlaybackState = nil
        resetPlaybackClocks()
        apply(.idle)
        playback.select(source)
    }

    private func seek(to position: TimeInterval) {
        guard let track = latestTrack, track.canSeek else { return }
        seekGeneration += 1
        let generation = seekGeneration
        playbackController.seek(to: position) { [weak self] succeeded in
            guard let self, self.seekGeneration == generation,
                  self.latestTrack?.identityKey == track.identityKey else { return }
            guard succeeded || track.source == .netease else { return }
            self.resetPlaybackClocks()
            if !succeeded {
                self.menuBar.discardPendingSeek()
                self.playback.sampleNow()
            }
        }
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
            if playback.source == .appleMusic { applePlayback.cancelCommandConfirmation() }
        }
        playbackController.perform(command)
    }

    private func toggleVinylPlayback() {
        guard needlePlaybackTask == nil else { return }
        guard floating.showsVinyl, let track = latestTrack,
              track.state == .playing || track.state == .paused else {
            performDirectTransport(.toggle)
            return
        }
        needlePlaybackTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.floating.finishNeedleCue()
                self.needlePlaybackTask = nil
            }
            guard !Task.isCancelled else { return }
            await NeedlePlayback.toggle(
                startingAt: track,
                moveNeedle: { await self.floating.cueNeedle(ontoRecord: $0) },
                setPlaybackState: { await self.setPlaybackState($0, trackKey: track.identityKey) },
                currentTrack: { self.latestTrack }
            )
        }
    }

    private func setPlaybackState(_ state: PlayerState, trackKey: String) async {
        let command: MusicPlaybackController.Command = state == .playing ? .play : .pause
        guard !Task.isCancelled, await playbackController.perform(command), !Task.isCancelled else { return }
        let expectation = PlaybackMonitor.CommandExpectation(state: state, trackKey: trackKey)
        // The helper returns a fresh state together with its command result.
        if let latestTrack, expectation.resolution(for: .track(latestTrack)) != nil { return }
        if playback.source == .appleMusic {
            _ = await applePlayback.confirmCommand(expectation)
            return
        }
        // AX actions can finish before the client updates its controls.
        playback.sampleNow()
        for _ in 0..<12 {
            do { try await Task.sleep(nanoseconds: 125_000_000) } catch { return }
            guard playback.source == .netease, let latestTrack else { return }
            if expectation.resolution(for: .track(latestTrack)) != nil { return }
        }
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
        playback.stop()
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
        let source = AppPreferences.playbackSource
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: source.bundleIdentifier
        ) else {
            presentMessage(title: "找不到\(source.title)", message: "请先安装所选播放器。")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { [logger] _, error in
            if let error {
                logger.warning("Unable to open \(source.title): \(error.localizedDescription)")
            }
        }
    }

    private func requestAppleMusicAutomation() {
        let actions = settings.actions
        guard !actions.requestingAppleMusicAutomation, !actions.appleMusicAutomationRequested,
              let helperURL = PlaybackMonitor.helperExecutableURL else { return }
        actions.requestingAppleMusicAutomation = true
        if NSRunningApplication.runningApplications(withBundleIdentifier: PlaybackSource.appleMusic.bundleIdentifier)
            .contains(where: { !$0.isTerminated }) {
            runAppleMusicAuthorization(helperURL)
        } else if let musicURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PlaybackSource.appleMusic.bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: musicURL, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.settings.actions.requestingAppleMusicAutomation = false
                        self.logger.warning("Unable to open Music for authorization: \(error.localizedDescription)")
                    } else {
                        self.runAppleMusicAuthorization(helperURL)
                    }
                }
            }
        } else {
            actions.requestingAppleMusicAutomation = false
        }
    }

    private func runAppleMusicAuthorization(_ helperURL: URL) {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--authorize"]
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.appleMusicAuthorizationProcess = nil
                self.settings.actions.requestingAppleMusicAutomation = false
                if status == 0 || errorText == "-1743" {
                    self.settings.actions.recordAppleMusicAutomationRequest()
                }
                if status != 0 { self.logger.warning("Music automation request ended; status=\(errorText)") }
                self.settings.actions.checkPlaybackPermissions()
                if self.playback.source == .appleMusic { self.playback.sampleNow() }
            }
        }
        do {
            try process.run()
            appleMusicAuthorizationProcess = process
        } catch {
            settings.actions.requestingAppleMusicAutomation = false
            logger.warning("Unable to start Music authorization: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func refreshAppleMusicCacheAccess() -> AppleMusicCacheLyricsProvider.CacheAccess {
        let access = lyricsService.appleMusicCacheAccess()
        if settings.actions.appleMusicCacheAccess != access {
            settings.actions.appleMusicCacheAccess = access
            if access == .denied { logger.warning("macOS denied access to the Apple Music lyric cache") }
        }
        return access
    }

    // MARK: - Playback updates

    private func clearTrack() {
        seekGeneration += 1
        latestTrack = nil
        currentTrackKey = nil
        lyricsGeneration = UUID()
        lyricsTask?.cancel()
        lyricsTask = nil
        isLoadingLyrics = false
        showsLoadingState = false
        sourceLyrics = .empty
        translatedLyrics = nil
        currentLyrics = .empty
        cancelTranslation()
        updateTranslationDemand()
    }

    private func handlePlaybackUpdate(_ result: PlaybackMonitor.Update) {
        switch result {
        case .failure(let error):
            let message = error.localizedDescription
            let state = "error: \(message)"
            guard lastLoggedPlaybackState != state else { return }
            clearTrack()
            lastLoggedPlaybackState = state
            logger.error("Playback request failed: \(message)")
            if playback.source == .netease {
                apply(.error(message))
            } else if message.localizedCaseInsensitiveContains("not allowed")
                || message.localizedCaseInsensitiveContains("(-1743)")
                || message.localizedCaseInsensitiveContains("authorization") {
                apply(.error("请在应用的「设置 → 播放来源」检查 Apple Music 自动化权限。"))
            } else {
                apply(.error("读取播放状态失败，请在设置中查看诊断信息。"))
            }

        case .track(let track):
            logPlaybackState("track available")
            latestTrack = track
            handle(track: track)

        case .stopped:
            guard lastLoggedPlaybackState != "playback stopped" else { return }
            logPlaybackState("playback stopped")
            clearTrack()
            apply(.stopped)

        case .musicNotRunning:
            guard lastLoggedPlaybackState != "selected player not running" else { return }
            logPlaybackState("selected player not running")
            clearTrack()
            apply(.musicNotRunning)
        }
    }

    private func handle(track: TrackInfo) {
        let key = track.identityKey
        let needsNewLyrics = currentTrackKey != key || forceRefresh

        if needsNewLyrics {
            let bypassMemory = forceRefresh
            logger.info(
                "Lyrics lookup triggered; reason=\(bypassMemory ? "manual refresh" : "track changed"); "
                    + "track=\(track.displayName); duration=\(Int(track.duration.rounded()))"
            )
            cancelTranslation()
            sourceLyrics = .empty
            translatedLyrics = nil
            currentTrackKey = key
            currentLyrics = .empty
            forceRefresh = false
            lyricsRetryDelay = track.source == .appleMusic ? 1.0 : 60
            loadLyrics(for: track, showLoading: true, bypassMemory: bypassMemory)
        }

        if needsNewLyrics || isLoadingLyrics {
            apply(showsLoadingState ? .loadingLyrics(track) : noLyricsStatus(for: track))
            return
        }

        if currentLyrics.isSynced || currentLyrics.plainText?.isEmpty == false {
            let line = currentLyrics.isSynced ? currentLyrics.line(at: track.position) : nil
            let text = line.flatMap { $0.text.isEmpty ? nil : $0.text } ?? track.displayName
            apply(.showing(track: track, lyrics: currentLyrics, currentLine: text))
            return
        }

        if track.source == .appleMusic, settings.actions.appleMusicCacheAccess == .denied {
            apply(noLyricsStatus(for: track))
            return
        }
        let elapsed = Date().timeIntervalSince(lastLyricsAttempt)
        // Retry when Music writes a response, even after polling has backed off.
        let cacheChanged = track.source == .appleMusic && elapsed >= 0.5
            && lastAppleMusicCacheRevision != lyricsService.appleMusicCacheRevision()
        if cacheChanged || elapsed >= lyricsRetryDelay {
            let maximumDelay: TimeInterval = track.source == .appleMusic ? 15 : 600
            lyricsRetryDelay = min(maximumDelay, lyricsRetryDelay * 1.5)
            loadLyrics(for: track, showLoading: false)
        }
        apply(noLyricsStatus(for: track))
    }

    private func noLyricsStatus(for track: TrackInfo) -> AppStatus {
        .noLyrics(track, cacheAccessDenied: track.source == .appleMusic && settings.actions.appleMusicCacheAccess == .denied)
    }

    private func loadLyrics(for track: TrackInfo, showLoading: Bool, bypassMemory: Bool = false) {
        lyricsTask?.cancel()
        lyricsGeneration = UUID()
        let generation = lyricsGeneration
        if track.source == .appleMusic, refreshAppleMusicCacheAccess() == .denied {
            lyricsTask = nil
            isLoadingLyrics = false
            showsLoadingState = false
            return
        }
        isLoadingLyrics = true
        showsLoadingState = showLoading
        lastLyricsAttempt = Date()
        if track.source == .appleMusic {
            lastAppleMusicCacheRevision = lyricsService.appleMusicCacheRevision()
        }
        let key = track.identityKey
        updateTranslationDemand()

        lyricsTask = Task { [weak self, lyricsService] in
            var document = await lyricsService.lyrics(for: track, bypassMemory: bypassMemory)
            if track.source == .appleMusic, showLoading, document.lines.isEmpty {
                // Pick up responses written shortly after the track changes, then back off.
                let retryIntervalsMS: [UInt64] = [250, 350, 500, 650, 750]
                for interval in retryIntervalsMS {
                    do { try await Task.sleep(nanoseconds: interval * 1_000_000) }
                    catch { return }
                    guard !Task.isCancelled, self?.lyricsGeneration == generation else { return }
                    document = await lyricsService.lyrics(for: track, recentIndexOnly: true)
                    if !document.lines.isEmpty {
                        break
                    }
                }
            }
            guard !Task.isCancelled, let self, self.currentTrackKey == key,
                  self.lyricsGeneration == generation else { return }
            self.lastLyricsAttempt = Date()
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
        playback.sampleNow()
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
        let track = status.track
        let url = track?.artworkURL ?? (track?.identityKey == currentTrackKey ? sourceLyrics.artworkURL : nil)
        artwork.update(track: track, url: url)
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
