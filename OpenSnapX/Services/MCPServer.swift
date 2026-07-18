import Darwin
import Foundation
import OSLog

@MainActor
final class UnixSocketMCPServer: MCPServer {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenSnapX", category: "MCP")
    private let toolHandler: any MCPToolHandling
    private let fileManager: FileManager
    private let socketDirectory: URL
    private let pointerURL: URL

    private var listener: MCPUnixSocketListener?
    private var generation: UUID?

    private(set) var status = MCPServerStatus()
    var onStatusChange: (@MainActor (MCPServerStatus) -> Void)?

    init(
        toolHandler: any MCPToolHandling,
        fileManager: FileManager = .default,
        socketDirectory: URL? = nil,
        pointerURL: URL? = nil
    ) {
        self.toolHandler = toolHandler
        self.fileManager = fileManager
        self.socketDirectory = socketDirectory ?? fileManager.temporaryDirectory
        self.pointerURL = pointerURL ?? Self.defaultPointerURL(fileManager: fileManager)
    }

    func start() {
        guard listener == nil else { return }
        setStatus(MCPServerStatus(phase: .starting))
        let generation = UUID()
        self.generation = generation

        do {
            let socketURL = socketDirectory.appendingPathComponent(
                "opensnapx-mcp-\(generation.uuidString.prefix(12)).sock",
                isDirectory: false
            )
            let listener = try MCPUnixSocketListener(socketURL: socketURL, toolHandler: toolHandler)
            listener.onStatusChange = { [weak self] clients, activeRequests in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.setStatus(MCPServerStatus(
                        phase: .listening,
                        connectedClients: clients,
                        activeRequests: activeRequests
                    ))
                }
            }
            listener.onFailure = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.fail(message)
                }
            }
            try listener.start()
            self.listener = listener
            try publishSocketPath(socketURL.path)
            setStatus(MCPServerStatus(phase: .listening))
            logger.info("Local MCP server started")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        generation = nil
        listener?.stop()
        listener = nil
        try? fileManager.removeItem(at: pointerURL)
        setStatus(MCPServerStatus(phase: .stopped))
        logger.info("Local MCP server stopped")
    }

    static func defaultPointerURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport
            .appendingPathComponent("OpenSnapX", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("socket-path", isDirectory: false)
    }

    private func publishSocketPath(_ path: String) throws {
        let directory = pointerURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(path.utf8).write(to: pointerURL, options: .atomic)
        guard chmod(pointerURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func fail(_ message: String) {
        generation = nil
        listener?.stop()
        listener = nil
        try? fileManager.removeItem(at: pointerURL)
        setStatus(MCPServerStatus(phase: .failed(message)))
        logger.error("Local MCP server failed: \(message, privacy: .public)")
    }

    private func setStatus(_ status: MCPServerStatus) {
        self.status = status
        onStatusChange?(status)
    }
}

private final class MCPUnixSocketListener: @unchecked Sendable {
    static let maximumRequestBytes = 1_024 * 1_024
    static let maximumPendingMessagesPerConnection = 32
    static let maximumConnections = 8

    private let socketURL: URL
    private let toolHandler: any MCPToolHandling
    private let queue = DispatchQueue(label: "io.github.alan13367.OpenSnapX.mcp.listener", qos: .userInitiated)

    private var listenerDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: MCPUnixConnection] = [:]
    private var activeRequests = 0
    private var stopped = false

    var onStatusChange: (@Sendable (Int, Int) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    init(socketURL: URL, toolHandler: any MCPToolHandling) throws {
        self.socketURL = socketURL
        self.toolHandler = toolHandler
        guard socketURL.path.utf8.count < Self.maximumUnixPathBytes else {
            throw MCPServerTransportError.socketPathTooLong
        }
    }

    func start() throws {
        try? FileManager.default.removeItem(at: socketURL)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        listenerDescriptor = descriptor

        do {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketURL.path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                destination.copyBytes(from: pathBytes)
            }
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw currentPOSIXError() }
            guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else { throw currentPOSIXError() }
            guard Darwin.listen(descriptor, SOMAXCONN) == 0 else { throw currentPOSIXError() }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw currentPOSIXError()
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptConnections() }
            source.setCancelHandler { Darwin.close(descriptor) }
            acceptSource = source
            source.resume()
        } catch {
            if acceptSource == nil, descriptor >= 0 { Darwin.close(descriptor) }
            listenerDescriptor = -1
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            acceptSource?.cancel()
            acceptSource = nil
            listenerDescriptor = -1
            let currentConnections = Array(connections.values)
            connections.removeAll()
            currentConnections.forEach { $0.close() }
            activeRequests = 0
            try? FileManager.default.removeItem(at: socketURL)
        }
    }

    private func acceptConnections() {
        guard !stopped else { return }
        while true {
            let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
            if descriptor < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                onFailure?(currentPOSIXError().localizedDescription)
                return
            }

            guard connections.count < Self.maximumConnections else {
                Darwin.close(descriptor)
                continue
            }

            var peerUserID: uid_t = 0
            var peerGroupID: gid_t = 0
            guard getpeereid(descriptor, &peerUserID, &peerGroupID) == 0,
                  peerUserID == getuid() else {
                Darwin.close(descriptor)
                continue
            }

            let connectionFlags = fcntl(descriptor, F_GETFL)
            if connectionFlags >= 0 {
                _ = fcntl(descriptor, F_SETFL, connectionFlags & ~O_NONBLOCK)
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                &sendTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            )

            let connection = MCPUnixConnection(
                descriptor: descriptor,
                maximumRequestBytes: Self.maximumRequestBytes,
                maximumPendingMessages: Self.maximumPendingMessagesPerConnection,
                toolHandler: toolHandler,
                onToolActivity: { [weak self] active in
                    self?.queue.async { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.activeRequests = max(0, self.activeRequests + (active ? 1 : -1))
                        self.reportStatus()
                    }
                }
            )
            let identifier = ObjectIdentifier(connection)
            connection.onClose = { [weak self, weak connection] in
                self?.queue.async { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.connections.removeValue(forKey: ObjectIdentifier(connection))
                    self.reportStatus()
                }
            }
            connections[identifier] = connection
            connection.start()
            reportStatus()
        }
    }

    private func reportStatus() {
        onStatusChange?(connections.count, activeRequests)
    }

    private static var maximumUnixPathBytes: Int {
        var address = sockaddr_un()
        return withUnsafeBytes(of: &address.sun_path) { $0.count }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private final class MCPUnixConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let maximumRequestBytes: Int
    private let maximumPendingMessages: Int
    private let queue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let session: MCPClientSession
    private let stateLock = NSLock()

    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var pendingMessages: [Data] = []
    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UInt64 = 0
    private var closed = false

    var onClose: (@Sendable () -> Void)?

    init(
        descriptor: Int32,
        maximumRequestBytes: Int,
        maximumPendingMessages: Int,
        toolHandler: any MCPToolHandling,
        onToolActivity: @escaping @Sendable (Bool) -> Void
    ) {
        self.descriptor = descriptor
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumPendingMessages = maximumPendingMessages
        queue = DispatchQueue(label: "io.github.alan13367.OpenSnapX.mcp.connection.\(descriptor)")
        writeQueue = DispatchQueue(label: "io.github.alan13367.OpenSnapX.mcp.writer.\(descriptor)")
        session = MCPClientSession(toolHandler: toolHandler, onToolActivity: onToolActivity)
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailableBytes() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()

        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        queue.async { [self] in finishClosing() }
    }

    private func finishClosing() {
        source?.cancel()
        source = nil
        processingGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        pendingMessages.removeAll()
        buffer.removeAll(keepingCapacity: false)
        onClose?()
        onClose = nil
    }

    private func readAvailableBytes() {
        guard !isClosed else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if count > 0 {
                buffer.append(bytes, count: count)
                guard processCompleteLines(), buffer.count <= maximumRequestBytes else {
                    close()
                    return
                }
            } else if count == 0 {
                close()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                close()
                return
            }
        }
    }

    private func processCompleteLines() -> Bool {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            guard line.count <= maximumRequestBytes,
                  pendingMessages.count + (processingTask == nil ? 0 : 1) < maximumPendingMessages else {
                return false
            }
            pendingMessages.append(line)
            startNextMessageIfNeeded()
        }
        return true
    }

    private func startNextMessageIfNeeded() {
        guard processingTask == nil, !pendingMessages.isEmpty, !isClosed else { return }
        let line = pendingMessages.removeFirst()
        processingGeneration &+= 1
        let generation = processingGeneration
        processingTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let response = await self.session.handle(line)
            if !Task.isCancelled, let response { self.send(response) }
            self.queue.async { [weak self] in
                guard let self,
                      self.processingGeneration == generation,
                      self.processingTask != nil else { return }
                self.processingTask = nil
                self.startNextMessageIfNeeded()
            }
        }
    }

    private func send(_ response: Data) {
        var framed = response
        framed.append(0x0A)
        let framedResponse = framed
        writeQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            let result = framedResponse.withUnsafeBytes { rawBuffer -> Bool in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(
                        self.descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    if count > 0 {
                        written += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            if !result { self.close() }
        }
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }
}

private enum MCPServerTransportError: LocalizedError {
    case socketPathTooLong

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong:
            "The local MCP socket path is too long for macOS."
        }
    }
}
