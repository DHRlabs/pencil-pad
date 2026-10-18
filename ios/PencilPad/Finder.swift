import Foundation
import Network

/// A Mac advertising PencilPad on Bonjour.
struct FoundMac: Identifiable, Equatable, Sendable {
    let name: String
    /// The service without a fixed interface, so the system picks Wi-Fi or Apple's direct link (AWDL), whichever is up.
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Browses `_pencilpad._tcp`, over infrastructure Wi-Fi and Apple's peer-to-peer link.
@MainActor
final class Finder {
    static let type = "_pencilpad._tcp"

    var onChange: (([FoundMac]) -> Void)?
    /// Local Network permission refused (or the network is unusable): the reason, else nil.
    var onBlocked: ((String?) -> Void)?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: Self.type, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.onBlocked?(nil)
                case .waiting(let error):
                    log.error("browse waiting: \(error, privacy: .public)")
                    self.onBlocked?("\(error)")
                case .failed(let error):
                    log.error("browse failed: \(error, privacy: .public); restarting")
                    self.browser?.cancel()
                    self.browser = nil
                    self.onChange?([])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.start() } }
                default:
                    break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                // One result per interface for the same Mac: keep one per name.
                var names = Set<String>()
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint { names.insert(name + "\u{0}" + type + "\u{0}" + domain) }
                }
                let macs = names.sorted().map { key -> FoundMac in
                    let p = key.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
                    return FoundMac(name: p[0], endpoint: .service(name: p[0], type: p[1], domain: p[2], interface: nil))
                }
                log.notice("browse: \(macs.map(\.name).joined(separator: ", "), privacy: .public)")
                self?.onChange?(macs)
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Stops browsing (the app went to the background); `start()` begins again.
    func stop() {
        browser?.cancel()
        browser = nil
    }
}
