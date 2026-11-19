import Foundation
import Network

/// Discovers Android companion apps advertising `_androidconnect._tcp` via Bonjour/mDNS.
@MainActor
@Observable
final class MDNSBrowserService {

    // MARK: - Published State

    private(set) var discoveredEndpoints: [DiscoveredEndpoint] = []
    private(set) var isBrowsing: Bool = false

    // MARK: - Types

    struct DiscoveredEndpoint: Identifiable, Equatable {
        let id: String          // Bonjour name
        let name: String
        let host: String
        let port: UInt16
    }

    // MARK: - Private

    private var browser: NWBrowser?
    private let serviceType = "_androidconnect._tcp"
    private var restartTask: Task<Void, Never>?
    private var retryCount = 0
    private let maxRetryDelay: TimeInterval = 30.0

    // MARK: - Lifecycle

    func startBrowsing() {
        guard !isBrowsing else { return }
        restartTask?.cancel()
        restartTask = nil

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResultsChange(results)
            }
        }

        newBrowser.start(queue: .main)
        browser = newBrowser
        isBrowsing = true
    }

    func stopBrowsing() {
        restartTask?.cancel()
        restartTask = nil
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discoveredEndpoints = []
    }

    func restartBrowsing() {
        stopBrowsing()
        retryCount = 0
        startBrowsing()
    }

    // MARK: - Handlers

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            retryCount = 0
            print("[MDNSBrowser] Browser ready, discovering services...")
        case .failed(let error):
            print("[MDNSBrowser] Failed: \(error)")
            stopBrowsing()

            retryCount += 1
            let delay = min(5.0 * Double(retryCount), maxRetryDelay)
            print("[MDNSBrowser] Retrying discovery in \(Int(delay))s (attempt \(retryCount))...")

            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.startBrowsing()
            }
        case .cancelled:
            isBrowsing = false
        default:
            break
        }
    }

    private func handleResultsChange(_ results: Set<NWBrowser.Result>) {
        for result in results {
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                // Resolve via NWConnection to get actual host/port
                resolveEndpoint(name: name, type: type, domain: domain)
            default:
                break
            }
        }

        // Keep existing resolved endpoints that are still in results
        let resultNames = Set(results.compactMap { result -> String? in
            if case .service(let name, _, _, _) = result.endpoint {
                return name
            }
            return nil
        })

        discoveredEndpoints = discoveredEndpoints.filter { resultNames.contains($0.id) }
    }

    private func resolveEndpoint(name: String, type: String, domain: String) {
        // Use NWConnection to resolve the Bonjour service
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {
                    let hostString: String
                    switch host {
                    case .ipv4(let addr):
                        hostString = "\(addr)"
                    case .ipv6(let addr):
                        hostString = "\(addr)"
                    case .name(let nameStr, _):
                        hostString = nameStr
                    @unknown default:
                        hostString = "\(host)"
                    }

                    let resolved = DiscoveredEndpoint(
                        id: name,
                        name: name,
                        host: hostString,
                        port: port.rawValue
                    )

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !self.discoveredEndpoints.contains(where: { $0.id == name }) {
                            self.discoveredEndpoints.append(resolved)
                        }
                    }
                }
                connection.cancel()

            case .failed:
                connection.cancel()

            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        // Timeout resolution after 5 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if connection.state != .ready {
                connection.cancel()
            }
        }
    }
}
