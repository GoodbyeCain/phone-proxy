import Foundation
import Network

final class ProxyServer: ObservableObject {
    static let defaultPort: UInt16 = 1088

    @Published private(set) var status = "idle"
    @Published private(set) var log = ""
    @Published private(set) var connectionCount = 0
    @Published private(set) var isListening = false

    let port: UInt16 = ProxyServer.defaultPort

    private let queue = DispatchQueue(label: "com.saycain.phoneproxy.server")
    private var listener: NWListener?
    private var connections: [ProxyConnection] = []

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                    tcp.noDelay = true
                }
                guard let portValue = NWEndpoint.Port(rawValue: self.port) else { return }
                let listener = try NWListener(using: params, on: portValue)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.publish { $0.isListening = true; $0.status = "listening on 0.0.0.0:\(self.port)" }
                        self.note("listener ready")
                    case .failed(let error):
                        self.publish { $0.isListening = false; $0.status = "listener failed: \(error)" }
                        self.listener = nil
                    case .cancelled:
                        self.publish { $0.isListening = false; $0.status = "stopped" }
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: self.queue)
                self.publish { $0.status = "starting…" }
            } catch {
                self.publish { $0.status = "listen error: \(error)"; $0.isListening = false }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    func note(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        print("[PhoneProxy] \(stamp) \(line)")
        publish { server in
            server.log.append("\(stamp) \(line)\n")
            if server.log.count > 6000 {
                server.log.removeFirst(server.log.count - 6000)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let proxy = ProxyConnection(server: self, client: connection, queue: queue)
        connections.append(proxy)
        let count = connections.count
        publish { $0.connectionCount = count }
        proxy.start { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.connections.removeAll { $0 === proxy }
                let remaining = self.connections.count
                self.publish { $0.connectionCount = remaining }
            }
        }
    }

    private func publish(_ mutate: @escaping (ProxyServer) -> Void) {
        DispatchQueue.main.async { mutate(self) }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
