import Foundation
import Darwin

/// Minimal Unix-domain SOCK_STREAM listener. Each accepted connection is
/// read line-by-line; every line is handed to `onLine` on a background
/// queue. Designed for short, fire-and-forget messages from clawdex-hook
/// via `nc -U`. Robust to clients that connect and disconnect immediately.
final class SocketServer {
    private let path: String
    private let queue = DispatchQueue(label: "clawdex.socket", qos: .utility)
    private var listenSource: DispatchSourceRead?
    private var fd: Int32 = -1

    let onLine: (String) -> Void

    init(path: String, onLine: @escaping (String) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                Darwin.bind(fd, saddr, size)
            }
        }
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        // Tighten permissions — only the user can talk to the socket.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.listenSource = source
    }

    private func acceptOne() {
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = Darwin.accept(fd, &addr, &len)
        guard client >= 0 else { return }
        queue.async { [weak self] in self?.readLines(client) }
    }

    private func readLines(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        let chunkSize = 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(client, ptr.baseAddress, chunkSize)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(n))

            // Drain complete lines.
            while let nl = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
            }
        }
        // Trailing line without newline.
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            onLine(line)
        }
    }

    func stop() {
        listenSource?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }
}
