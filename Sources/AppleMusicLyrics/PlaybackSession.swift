import Foundation

@MainActor
protocol PlaybackTransport: AnyObject {
    func performControl(_ arguments: [String], completion: @escaping (Bool) -> Void)
}

@MainActor
protocol PlaybackBackend: PlaybackTransport {
    var onUpdate: ((PlaybackMonitor.Update) -> Void)? { get set }
    func start()
    func stop()
    func sampleNow()
}

extension PlaybackMonitor: PlaybackBackend {}
extension NetEasePlayback: PlaybackBackend {}

/// Owns a single active player, including the lifetime of its callbacks.
@MainActor
final class PlaybackSession: PlaybackTransport {
    private let appleMusic: PlaybackBackend
    private let netease: PlaybackBackend
    private var backend: PlaybackBackend?
    private var generation = 0
    private(set) var source: PlaybackSource?
    var onUpdate: ((PlaybackMonitor.Update) -> Void)?

    init(appleMusic: PlaybackBackend, netease: PlaybackBackend) {
        self.appleMusic = appleMusic
        self.netease = netease
    }

    func select(_ source: PlaybackSource) {
        guard self.source != source else { return }
        stop()
        self.source = source
        let backend = source == .appleMusic ? appleMusic : netease
        self.backend = backend
        let generation = self.generation
        backend.onUpdate = { [weak self] update in
            guard let self, self.generation == generation else { return }
            self.onUpdate?(update)
        }
        backend.start()
    }

    func stop() {
        generation += 1
        source = nil
        backend?.onUpdate = nil
        backend?.stop()
        backend = nil
    }

    func sampleNow() { backend?.sampleNow() }

    func performControl(_ arguments: [String], completion: @escaping (Bool) -> Void) {
        guard let backend else { completion(false); return }
        let generation = self.generation
        backend.performControl(arguments) { [weak self] succeeded in
            completion(succeeded && self?.generation == generation)
        }
    }
}
