import SwiftUI
import UIKit

@main
struct PhoneProxyApp: App {
    @StateObject private var server = ProxyServer()

    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    AudioKeeper.shared.start()
                    server.start()
                    NetworkDiagnostics.start(server: server)
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var server: ProxyServer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(server.isListening ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("PhoneProxy  :\(String(server.port))")
                    .font(.headline)
            }
            Text(server.status)
                .font(.system(.footnote, design: .monospaced))
            Text("connections: \(server.connectionCount)")
                .font(.footnote)
            Divider()
            ScrollView {
                Text(server.log)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}
