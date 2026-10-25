import Foundation

/// A test double that answers from canned responses and records every request.
/// Lives in the main target so every module's tests can use it.
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    public typealias Handler = @Sendable (URL, [String: String]) throws -> HTTPResponse

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var downloads: [String: Data] = [:]
    private var _requests: [URL] = []

    public init() {}

    public var requests: [URL] { lock.withLock { _requests } }

    public func respond(to url: String, status: Int = 200, headers: [String: String] = [:], body: Data) {
        lock.withLock {
            handlers[url] = { requested, _ in HTTPResponse(status: status, headers: headers, body: body, url: requested) }
        }
    }

    public func respond(to url: String, status: Int = 200, headers: [String: String] = [:], text: String) {
        respond(to: url, status: status, headers: headers, body: Data(text.utf8))
    }

    public func respond(to url: String, handler: @escaping Handler) {
        lock.withLock { handlers[url] = handler }
    }

    public func serveDownload(_ url: String, data: Data) {
        lock.withLock { downloads[url] = data }
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        try URLSessionHTTPClient.requireHTTPS(url)
        let handler = lock.withLock { () -> Handler? in
            _requests.append(url)
            return handlers[url.absoluteString]
        }
        guard let handler else { return HTTPResponse(status: 404, url: url) }
        return try handler(url, headers)
    }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> DownloadResult {
        try URLSessionHTTPClient.requireHTTPS(url)
        let data = lock.withLock { () -> Data? in
            _requests.append(url)
            return downloads[url.absoluteString]
        }
        guard let data else { throw HTTPError.status(404) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        progress(Int64(data.count), Int64(data.count))
        return DownloadResult(file: destination, redirectChain: [url], mimeType: nil, suggestedFilename: url.lastPathComponent)
    }
}
