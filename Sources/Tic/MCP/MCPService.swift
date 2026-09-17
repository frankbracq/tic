import Foundation
import MCP
import Network

/// The in-process MCP server. Listens on a Unix socket beside the database; every accepted
/// connection (one per `Tic --mcp` proxy, i.e. per agent) gets its own SDK `Server` session, so
/// agents never share a handshake or request ids. Tool handlers write through `AppDatabase`, and
/// the existing observers carry every change into the open notes — that is the whole "live update".
final class MCPService: @unchecked Sendable {
    /// `~/Library/Application Support/Tic/mcp.sock`. A 0600 file next to the DB: the same exposure as
    /// the DB itself, no port, no firewall prompt. (`sun_path` caps at 104 bytes; this is ~50.)
    static var socketPath: String {
        let dir = (try? AppDatabase.supportDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("mcp.sock").path
    }

    let socketPath: String
    private let database: AppDatabase
    /// Listener callbacks land here; `listener` and `sessions` are touched only on it.
    private let queue = DispatchQueue(label: "tic.mcp")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Server] = [:]
    /// Agents connected right now (the setup window's status line). Called off the main actor.
    var onConnectionCountChange: (@Sendable (Int) -> Void)?

    init(database: AppDatabase, socketPath: String = MCPService.socketPath) {
        self.database = database
        self.socketPath = socketPath
    }

    var connectionCount: Int { queue.sync { sessions.count } }

    /// Binds the socket (replacing a stale file a crash left behind) and returns once it accepts,
    /// so a failure (bad path, permissions) surfaces to the caller instead of a silent dead toggle.
    func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        let listener = try NWListener(using: parameters)

        let settled = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        listener.stateUpdateHandler = { [socketPath] state in
            switch state {
            case .ready:
                chmod(socketPath, 0o600)
                settled.signal()
            case .failed(let error):
                failure = error
                settled.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = settled.wait(timeout: .now() + .seconds(2))
        if let failure {
            listener.cancel()
            throw failure
        }
        self.listener = listener
    }

    /// Closes every session (each proxy sees EOF and exits) and removes the socket file, so a
    /// client's next spawn fails fast with the "MCP is off" hint.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            let open = sessions.values
            sessions = [:]
            for server in open { Task { await server.stop() } }
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        onConnectionCountChange?(0)
    }

    // MARK: - Sessions

    private func accept(_ connection: NWConnection) {
        // The SDK transport's defaults suit TCP clients, not an accepted server-side connection: the
        // heartbeat sends raw bytes that would corrupt the client's stdio through the proxy, and a
        // dropped accepted connection has nothing to reconnect to.
        let transport = NetworkTransport(
            connection: connection,
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .init(enabled: false)
        )
        let server = Server(
            name: "Tic",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            capabilities: .init(tools: .init())
        )
        let key = ObjectIdentifier(server)
        sessions[key] = server
        onConnectionCountChange?(sessions.count)

        Task { [weak self] in
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
            do {
                try await server.start(transport: transport)
            } catch {
                NSLog("[Tic] MCP session failed to start: \(error)")
            }
            await server.waitUntilCompleted()
            self?.drop(key)
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        queue.async { [weak self] in
            guard let self, self.sessions.removeValue(forKey: key) != nil else { return }
            self.onConnectionCountChange?(self.sessions.count)
        }
    }
}
