import Foundation

public enum USBError: Error, CustomStringConvertible {
    case unplugged
    case stall
    case timeout(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unplugged: "the guest reinitialised its USB controller"
        case .stall: "the endpoint stalled"
        case .timeout(let what): "timed out waiting for \(what)"
        case .malformed(let what): "malformed USB data: \(what)"
        }
    }
}

/// QEMU's vusb device, spoken directly over its chardev: the guest is the USB
/// device, and this end is the host. Every message is a little-endian length
/// and a body. Requests carry an endpoint and a type, replies a code and an
/// endpoint.
public final class VUSBLink: @unchecked Sendable {
    private enum Request {
        static let data: UInt8 = 1
        static let reset: UInt8 = 2
    }

    private enum Reply {
        static let data: UInt8 = 1
        static let stall: UInt8 = 2
        static let notReady: UInt8 = 3
        static let reset: UInt8 = 4
        static let abort: UInt8 = 5
        static let driverReset: UInt8 = 6
    }

    private struct Response {
        let code: UInt8
        let data: [UInt8]
    }

    private let socket: UnixSocket
    private let state = NSCondition()
    private let writeLock = NSLock()
    private let controlLock = NSLock()
    private var responses: [UInt8: [Response]] = [:]
    private var resetCodes: [UInt8] = []
    private var resetPending = false
    private var stage = 0
    private var closed = false

    public init(socketPath: String) throws {
        socket = try UnixSocket.connect(path: socketPath)
        let thread = Thread { [self] in receiveLoop() }
        thread.name = "vusb"
        thread.start()
    }

    public func close() {
        state.lock()
        closed = true
        state.broadcast()
        state.unlock()
        socket.close()
    }

    /// Bumped each time the guest reinitialises its controller: a new boot stage.
    public var currentStage: Int {
        state.lock()
        defer { state.unlock() }
        return stage
    }

    public func waitForStageChange(after stage: Int, timeout: TimeInterval) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        state.lock()
        defer { state.unlock() }
        while self.stage == stage {
            if closed { throw SocketError.closed }
            if !state.wait(until: deadline) { throw USBError.timeout("the next boot stage") }
        }
    }

    // MARK: - Transfers

    /// QEMU holds the reset until the stage's driver posts its first buffer.
    public func reset(timeout: TimeInterval) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        state.lock()
        let startingStage = stage
        resetCodes.removeAll()
        resetPending = true
        state.unlock()
        defer {
            state.lock()
            resetPending = false
            state.unlock()
        }
        while true {
            try send(endpoint: 0, type: Request.reset)
            state.lock()
            defer { state.unlock() }
            while resetCodes.isEmpty {
                if stage != startingStage { throw USBError.unplugged }
                if closed { throw SocketError.closed }
                if !state.wait(until: deadline) { throw USBError.timeout("the USB reset") }
            }
            let code = resetCodes.removeFirst()
            if code == Reply.reset { return }
            state.unlock()
            usleep(1000)
            state.lock()
        }
    }

    public func control(setup: [UInt8], data: [UInt8] = [], timeout: TimeInterval = 5) throws -> [UInt8] {
        controlLock.lock()
        defer { controlLock.unlock() }
        return try exchange(endpoint: 0, payload: setup + data, timeout: timeout)
    }

    public func bulkOut(endpoint: UInt8, data: [UInt8], timeout: TimeInterval = 600) throws {
        _ = try exchange(endpoint: endpoint, payload: data, timeout: timeout)
    }

    public func bulkIn(endpoint: UInt8, timeout: TimeInterval = .infinity) throws -> [UInt8] {
        try exchange(endpoint: endpoint | 0x80, payload: [], timeout: timeout)
    }

    private func exchange(endpoint: UInt8, payload: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        let deadline = timeout.isFinite ? Date(timeIntervalSinceNow: timeout) : nil
        state.lock()
        let startingStage = stage
        state.unlock()
        while true {
            try send(endpoint: endpoint, type: Request.data, payload: payload)
            let response = try nextResponse(endpoint: endpoint, stage: startingStage, deadline: deadline)
            switch response.code {
            case Reply.data:
                return response.data
            case Reply.stall:
                throw USBError.stall
            case Reply.notReady:
                usleep(1000)
            default:
                throw USBError.malformed("reply \(response.code) on endpoint \(endpoint)")
            }
        }
    }

    private func nextResponse(endpoint: UInt8, stage startingStage: Int, deadline: Date?) throws -> Response {
        state.lock()
        defer { state.unlock() }
        while responses[endpoint, default: []].isEmpty {
            if stage != startingStage { throw USBError.unplugged }
            if closed { throw SocketError.closed }
            if let deadline {
                if !state.wait(until: deadline) {
                    throw USBError.timeout("endpoint \(String(endpoint, radix: 16))")
                }
            } else {
                state.wait()
            }
        }
        return responses[endpoint]!.removeFirst()
    }

    // MARK: - Chardev

    private func send(endpoint: UInt8, type: UInt8, payload: [UInt8] = []) throws {
        var message = [UInt8]()
        message.reserveCapacity(payload.count + 6)
        message.appendLittleEndian(UInt32(payload.count))
        message.append(endpoint)
        message.append(type)
        message.append(contentsOf: payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        try socket.write(message)
    }

    private func receiveLoop() {
        do {
            while true {
                let header = try socket.read(exactly: 4)
                let length = Int(header.littleEndianUInt32(at: 0))
                if length == 0 { continue }
                guard (2...0x10000).contains(length) else {
                    throw USBError.malformed("message of \(length) bytes")
                }
                let message = try socket.read(exactly: length)
                receive(code: message[0], endpoint: message[1], data: Array(message[2...]))
            }
        } catch {
            state.lock()
            closed = true
            state.broadcast()
            state.unlock()
        }
    }

    private func receive(code: UInt8, endpoint: UInt8, data: [UInt8]) {
        state.lock()
        defer {
            state.broadcast()
            state.unlock()
        }
        switch code {
        case Reply.driverReset:
            stage += 1
            responses.removeAll()
        case Reply.reset:
            if resetPending { resetCodes.append(code) }
        case Reply.notReady where endpoint == 0 && resetPending:
            resetCodes.append(code)
        case Reply.abort:
            break
        default:
            responses[endpoint, default: []].append(Response(code: code, data: data))
        }
    }
}

// MARK: - Bytes

extension Array where Element == UInt8 {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func bigEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 |
            UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}
