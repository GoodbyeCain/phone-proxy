import Foundation
import Network

enum NetworkDiagnostics {
    private static let queue = DispatchQueue(label: "com.saycain.phoneproxy.diag")
    private static var monitor: NWPathMonitor?

    static func start(server: ProxyServer) {
        guard monitor == nil else { return }
        log("interfaces: \(describeInterfaces())")
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            let kinds = path.availableInterfaces.map { "\($0.name)/\($0.type)" }.joined(separator: ",")
            log("path status=\(path.status) reason=\(path.unsatisfiedReason) interfaces=[\(kinds)] expensive=\(path.isExpensive)")
            if path.status == .satisfied {
                log("interfaces: \(describeInterfaces())")
            }
        }
        monitor.start(queue: queue)

        for type in [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet] {
            let typed = NWPathMonitor(requiredInterfaceType: type)
            typed.pathUpdateHandler = { path in
                log("path[\(type)] status=\(path.status) reason=\(path.unsatisfiedReason)")
            }
            typed.start(queue: queue)
        }

        queue.asyncAfter(deadline: .now() + 2) {
            probeRawTLS(server: server)
        }
        queue.asyncAfter(deadline: .now() + 3) {
            probeURLSession(server: server)
        }
    }

    private static func probeRawTLS(server: ProxyServer) {
        let params = NWParameters.tcp
        let connection = NWConnection(to: .hostPort(host: "1.1.1.1", port: 443), using: params)
        var settled = false
        connection.stateUpdateHandler = { state in
            guard !settled else { return }
            switch state {
            case .ready:
                settled = true
                log("raw dial 1.1.1.1:443 ready")
                connection.cancel()
            case .waiting(let error), .failed(let error):
                settled = true
                log("raw dial 1.1.1.1:443 failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = server
    }

    private static func probeURLSession(server: ProxyServer) {
        var request = URLRequest(url: URL(string: "https://www.baidu.com/")!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                log("urlsession baidu failed: \(error)")
            } else if let response = response as? HTTPURLResponse {
                log("urlsession baidu status=\(response.statusCode)")
            }
        }.resume()
        _ = server
    }

    private static func describeInterfaces() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return "none" }
        defer { freeifaddrs(head) }
        var parts: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            if flags & IFF_UP != 0, let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    parts.append("\(String(cString: entry.pointee.ifa_name))=\(String(cString: host))")
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }

    private static func log(_ line: String) {
        print("[PhoneProxy] diag \(line)")
    }
}
