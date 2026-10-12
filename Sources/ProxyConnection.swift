import Foundation
import Network

final class ProxyConnection {
    private enum Stage {
        case first
        case socksMethod
        case socksRequest
        case httpHead
        case relaying
    }

    private weak var server: ProxyServer?
    private let client: NWConnection
    private let queue: DispatchQueue
    private var target: NWConnection?
    private var buffer = Data()
    private var stage: Stage = .first
    private var finished = false
    private var onFinish: (() -> Void)?

    init(server: ProxyServer, client: NWConnection, queue: DispatchQueue) {
        self.server = server
        self.client = client
        self.queue = queue
    }

    func start(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        server?.note("client connected")
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    private func receive() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if self.buffer.isEmpty {
                if isComplete || error != nil {
                    self.finish()
                } else {
                    self.receive()
                }
                return
            }
            self.advance()
        }
    }

    private func advance() {
        guard !finished else { return }
        switch stage {
        case .first:
            if buffer[buffer.startIndex] == 0x05 {
                stage = .socksMethod
            } else {
                stage = .httpHead
            }
            advance()
        case .socksMethod:
            guard buffer.count >= 2 else { receive(); return }
            let methodCount = Int(buffer[buffer.startIndex + 1])
            guard buffer.count >= 2 + methodCount else { receive(); return }
            buffer = Data(buffer.dropFirst(2 + methodCount))
            server?.note("socks5 greeting")
            send(to: client, Data([0x05, 0x00])) {
                self.stage = .socksRequest
                self.advance()
            }
        case .socksRequest:
            parseSocksRequest()
        case .httpHead:
            parseHTTPHead()
        case .relaying:
            break
        }
    }

    private func parseSocksRequest() {
        guard buffer.count >= 4 else { receive(); return }
        let bytes = [UInt8](buffer)
        guard bytes[0] == 0x05 else { finish(); return }
        guard bytes[1] == 0x01 else {
            replySocksFailure()
            return
        }
        var host: String
        var headerLength = 0
        switch bytes[3] {
        case 0x01:
            guard bytes.count >= 10 else { receive(); return }
            host = "\(bytes[4]).\(bytes[5]).\(bytes[6]).\(bytes[7])"
            headerLength = 10
        case 0x03:
            let length = Int(bytes[4])
            guard bytes.count >= 5 + length + 2 else { receive(); return }
            host = String(decoding: bytes[5..<(5 + length)], as: UTF8.self)
            headerLength = 5 + length + 2
        case 0x04:
            guard bytes.count >= 22 else { receive(); return }
            var groups: [String] = []
            for index in stride(from: 4, to: 20, by: 2) {
                groups.append(String(format: "%02x%02x", bytes[index], bytes[index + 1]))
            }
            host = groups.joined(separator: ":")
            headerLength = 22
        default:
            replySocksFailure()
            return
        }
        let port = UInt16(bytes[headerLength - 2]) << 8 | UInt16(bytes[headerLength - 1])
        buffer = Data(buffer.dropFirst(headerLength))
        server?.note("socks5 connect \(host):\(port)")
        dial(
            host: host,
            port: port,
            successReply: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
            failureReply: Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        )
    }

    private func parseHTTPHead() {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: marker) else {
            if buffer.count > 16384 { finish() } else { receive() }
            return
        }
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer = Data(buffer.dropFirst(buffer.distance(from: buffer.startIndex, to: range.upperBound)))
        guard
            let firstLine = head.components(separatedBy: "\r\n").first,
            let requestLine = firstLine.split(separator: " ").first.map(String.init),
            requestLine.uppercased() == "CONNECT"
        else {
            finish()
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { finish(); return }
        let authority = String(parts[1])
        guard let separator = authority.lastIndex(of: ":") else { finish(); return }
        let host = String(authority[authority.startIndex..<separator])
        guard let port = UInt16(authority[authority.index(after: separator)...]) else { finish(); return }
        server?.note("http connect \(host):\(port)")
        dial(
            host: host,
            port: port,
            successReply: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
            failureReply: nil
        )
    }

    private func replySocksFailure() {
        send(to: client, Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])) {
            self.finish()
        }
    }

    private func dial(host: String, port: UInt16, successReply: Data, failureReply: Data?) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        guard let portValue = NWEndpoint.Port(rawValue: port) else { finish(); return }
        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: portValue),
            using: params
        )
        target = connection
        var settled = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !settled else { return }
            settled = true
            self.server?.note("dial timeout \(host):\(port)")
            if let failureReply {
                self.send(to: self.client, failureReply) { self.finish() }
            } else {
                self.finish()
            }
        }
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !settled else { return }
            switch state {
            case .ready:
                settled = true
                timeout.cancel()
                self.stage = .relaying
                self.send(to: self.client, successReply) {
                    self.beginRelaying(to: connection)
                }
            case .waiting(let error):
                self.server?.note("dial waiting \(host):\(port): \(error)")
            case .failed(let error):
                settled = true
                timeout.cancel()
                self.server?.note("dial failed \(host):\(port): \(error)")
                if let failureReply {
                    self.send(to: self.client, failureReply) { self.finish() }
                } else {
                    self.finish()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func beginRelaying(to connection: NWConnection) {
        let leftover = buffer
        buffer = Data()
        let startPumps = {
            self.pump(from: self.client, to: connection)
            self.pump(from: connection, to: self.client)
        }
        if leftover.isEmpty {
            startPumps()
        } else {
            send(to: connection, leftover) {
                startPumps()
            }
        }
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.send(to: destination, data) {
                    self.pump(from: source, to: destination)
                }
            } else if isComplete || error != nil {
                self.finish()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func send(to connection: NWConnection, _ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if error != nil {
                self.finish()
            } else {
                completion()
            }
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        server?.note("client closed")
        client.cancel()
        target?.cancel()
        target = nil
        onFinish?()
    }
}
