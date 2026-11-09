import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ImageError: Error, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - Reference

/// `registry/repository:tag` or `registry/repository@sha256:…`.
public struct OCIReference: Sendable, CustomStringConvertible {
    public let registry: String
    public let repository: String
    public let reference: String

    public init(_ text: String) throws {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost" else {
            throw ImageError("\(text) does not name a registry, as in ghcr.io/owner/image:tag")
        }
        registry = parts[0]
        var rest = parts[1]
        if let at = rest.firstIndex(of: "@") {
            reference = String(rest[rest.index(after: at)...])
            rest = String(rest[..<at])
        } else if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("/") {
            reference = String(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        } else {
            reference = "latest"
        }
        repository = rest
        guard !repository.isEmpty, !reference.isEmpty, !registry.contains("@") else {
            throw ImageError("\(text) is not an image reference like ghcr.io/owner/image:tag")
        }
    }

    public var description: String {
        reference.hasPrefix("sha256:") ? "\(registry)/\(repository)@\(reference)" : "\(registry)/\(repository):\(reference)"
    }
}

// MARK: - Manifest

struct OCIDescriptor: Codable, Sendable {
    let mediaType: String
    let digest: String
    let size: Int64
    let annotations: [String: String]?
}

struct OCIManifest: Codable, Sendable {
    static let mediaType = "application/vnd.oci.image.manifest.v1+json"

    let schemaVersion: Int
    let mediaType: String?
    let config: OCIDescriptor
    let layers: [OCIDescriptor]
}

enum Digest {
    static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Registry

/// Pulls from an OCI distribution registry, anonymously or with the bearer
/// token it hands out for public repositories.
final class OCIRegistry: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let reference: OCIReference
    private var session: URLSession!
    private let lock = NSLock()
    private var token: String?

    init(_ reference: OCIReference) {
        self.reference = reference
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func manifest() throws -> (manifest: OCIManifest, digest: String) {
        let data = try send("manifests/\(reference.reference)", accept: OCIManifest.mediaType) { try self.data($0) }
        let digest = Digest.sha256(data)
        if reference.reference.hasPrefix("sha256:"), digest != reference.reference {
            throw ImageError("the manifest is \(digest), not \(reference.reference)")
        }
        guard let manifest = try? JSONDecoder().decode(OCIManifest.self, from: data), manifest.schemaVersion == 2 else {
            throw ImageError("\(reference) is not an OCI image manifest")
        }
        if let type = manifest.mediaType, type != OCIManifest.mediaType {
            throw ImageError("\(reference) is \(type); expected an OCI image manifest")
        }
        return (manifest, digest)
    }

    /// A blob small enough to hold in memory, checked against its descriptor.
    func blob(_ descriptor: OCIDescriptor) throws -> Data {
        guard descriptor.size <= 64 << 20 else { throw ImageError("\(descriptor.digest) is too large") }
        let data = try send("blobs/\(descriptor.digest)", accept: nil) { try self.data($0) }
        guard Int64(data.count) == descriptor.size, Digest.sha256(data) == descriptor.digest else {
            throw ImageError("blob \(descriptor.digest) does not match its digest; pull again")
        }
        return data
    }

    /// Downloads a blob to `file` and checks it against its descriptor.
    func download(_ descriptor: OCIDescriptor, to file: URL) throws {
        try send("blobs/\(descriptor.digest)", accept: nil) { try self.download($0, to: file) }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        guard size == descriptor.size, try Digest.sha256(file: file) == descriptor.digest else {
            throw ImageError("blob \(descriptor.digest) does not match its digest; pull again")
        }
    }

    // MARK: Requests

    @discardableResult
    private func send<Value>(
        _ endpoint: String,
        accept: String?,
        _ perform: (URLRequest) throws -> (Value, HTTPURLResponse)
    ) throws -> Value {
        guard let url = URL(string: "https://\(reference.registry)/v2/\(reference.repository)/\(endpoint)") else {
            throw ImageError("\(reference) is not an image reference")
        }
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue("vmapple-cli", forHTTPHeaderField: "User-Agent")
            if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
            if let token = lock.withLock({ token }) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (value, response) = try perform(request)
            if response.statusCode == 401, attempt == 0 {
                try authenticate(response)
                continue
            }
            guard response.statusCode == 200 else {
                throw ImageError("\(url.absoluteString) returned HTTP \(response.statusCode); check that the image exists and is public")
            }
            return value
        }
        throw ImageError("\(url.absoluteString) returned HTTP 401; check that the image is public")
    }

    /// Answers a `Bearer` challenge with an anonymous token.
    private func authenticate(_ response: HTTPURLResponse) throws {
        guard let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let challenge = Self.bearerChallenge(header),
              let realm = challenge["realm"],
              var components = URLComponents(string: realm) else {
            throw ImageError("\(reference.registry) returned HTTP 401 without a bearer challenge; only anonymous pulls are supported")
        }
        components.queryItems = ["service", "scope"].compactMap { key in
            challenge[key].map { URLQueryItem(name: key, value: $0) }
        }
        guard let url = components.url else { throw ImageError("unusable token service \(realm)") }
        let (data, http) = try self.data(URLRequest(url: url))
        let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard http.statusCode == 200, let token = (reply?["token"] ?? reply?["access_token"]) as? String else {
            throw ImageError("\(url.absoluteString) returned HTTP \(http.statusCode); check that the image exists and is public")
        }
        lock.withLock { self.token = token }
    }

    /// `Bearer realm="…",service="…",scope="…"`, whose quoted values may hold commas.
    static func bearerChallenge(_ header: String) -> [String: String]? {
        guard header.lowercased().hasPrefix("bearer ") else { return nil }
        var values: [String: String] = [:]
        var rest = Substring(header.dropFirst(7))
        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " ,")).lowercased()
            rest = rest[rest.index(after: equals)...]
            if rest.first == "\"" {
                rest = rest.dropFirst()
                let end = rest.firstIndex(of: "\"") ?? rest.endIndex
                values[key] = String(rest[..<end])
                rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                values[key] = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
        }
        return values
    }

    private func data(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let result = Completion<(Data, HTTPURLResponse)>()
        session.dataTask(with: request) { data, response, error in
            result.finish((response as? HTTPURLResponse).map { (data ?? Data(), $0) }, error)
        }.resume()
        return try result.wait()
    }

    private func download(_ request: URLRequest, to file: URL) throws -> (Void, HTTPURLResponse) {
        let result = Completion<HTTPURLResponse>()
        session.downloadTask(with: request) { location, response, error in
            // The file at `location` is gone once this returns.
            var failure = error
            if let location {
                do {
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: location, to: file)
                } catch {
                    failure = error
                }
            }
            result.finish(response as? HTTPURLResponse, failure)
        }.resume()
        return ((), try result.wait())
    }

    /// A redirect to blob storage elsewhere must not carry the registry's token.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var request = request
        if request.url?.host != task.originalRequest?.url?.host {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

/// Waits for a task's completion handler.
private final class Completion<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var value: Value?
    private var error: Error?

    func finish(_ value: Value?, _ error: Error?) {
        self.value = value
        self.error = error
        done.signal()
    }

    func wait() throws -> Value {
        done.wait()
        if let error { throw error }
        guard let value else { throw ImageError("no response from the registry") }
        return value
    }
}
