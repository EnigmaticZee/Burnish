import Foundation

/// The real client. Every Burnish request goes through one of these.
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let limiter: AsyncLimiter

    public init(limiter: AsyncLimiter = AsyncLimiter(Net.maxInFlight)) {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": Net.userAgent]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        self.limiter = limiter
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        try Self.requireHTTPS(url)
        var builder = URLRequest(url: url, timeoutInterval: timeout)
        for (name, value) in headers { builder.setValue(value, forHTTPHeaderField: name) }
        let request = builder
        let delegate = RedirectGuard(original: url)
        return try await limiter.run {
            do {
                let (data, response) = try await session.data(for: request, delegate: delegate)
                if let error = delegate.rejection { throw error }
                guard let http = response as? HTTPURLResponse else { throw HTTPError.other("Not an HTTP response") }
                var headerMap: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headerMap[key] = value }
                }
                return HTTPResponse(status: http.statusCode, headers: headerMap, body: data)
            } catch {
                throw Self.map(error, rejection: delegate.rejection)
            }
        }
    }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try Self.requireHTTPS(url)
        try await limiter.run {
            let delegate = DownloadDelegate(original: url, destination: destination, progress: progress)
            let config = URLSessionConfiguration.ephemeral
            config.httpAdditionalHeaders = ["User-Agent": Net.userAgent]
            config.timeoutIntervalForRequest = 60
            config.httpCookieAcceptPolicy = .never
            let downloadSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { downloadSession.finishTasksAndInvalidate() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.start(downloadSession.downloadTask(with: url), continuation: continuation)
                }
            } onCancel: {
                delegate.cancel()
            }
        }
    }

    public static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL(url.absoluteString) }
    }

    static func map(_ error: Error, rejection: HTTPError?) -> Error {
        if let rejection { return rejection }
        if let error = error as? HTTPError { return error }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return HTTPError.offline
        case NSURLErrorTimedOut:
            return HTTPError.timedOut
        case NSURLErrorCancelled:
            return CancellationError()
        default:
            return HTTPError.other(ns.localizedDescription)
        }
    }
}

/// Refuses redirects to plain HTTP and logs redirects to another host (install rule 1).
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    /// The last URL in the redirect chain, to spot a hop to another host.
    private var last: URL
    private var _rejection: HTTPError?

    init(original: URL) {
        last = original
    }

    var rejection: HTTPError? { lock.withLock { _rejection } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let next = request.url else { return nil }
        let previous = lock.withLock {
            defer { last = next }
            return last
        }
        guard next.scheme?.lowercased() == "https" else {
            lock.withLock { _rejection = .insecureRedirect(next.absoluteString) }
            Net.log.error("Refused redirect to non-HTTPS \(next.absoluteString, privacy: .public)")
            return nil
        }
        if HostFamily(previous) != HostFamily(next) {
            Net.log.notice("Redirect \(previous.host ?? "?", privacy: .public) → \(next.host ?? "?", privacy: .public)")
        }
        return request
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let redirects: RedirectGuard
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionTask?
    private var moved = false
    private var moveError: Error?

    init(original: URL, destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        redirects = RedirectGuard(original: original)
        self.destination = destination
        self.progress = progress
    }

    func start(_ task: URLSessionTask, continuation: CheckedContinuation<Void, Error>) {
        lock.withLock {
            self.task = task
            self.continuation = continuation
        }
        task.resume()
    }

    func cancel() { lock.withLock { task }?.cancel() }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        await redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it now.
        let http = downloadTask.response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            lock.withLock { moveError = HTTPError.status(http.statusCode) }
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            lock.withLock { moved = true }
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, moved, moveError) = lock.withLock {
            let c = self.continuation
            self.continuation = nil
            return (c, self.moved, self.moveError)
        }
        guard let continuation else { return }
        if let rejection = redirects.rejection {
            continuation.resume(throwing: rejection)
        } else if let error {
            continuation.resume(throwing: URLSessionHTTPClient.map(error, rejection: nil))
        } else if let moveError {
            continuation.resume(throwing: moveError)
        } else if moved {
            continuation.resume()
        } else {
            continuation.resume(throwing: HTTPError.other("Download produced no file"))
        }
    }
}

/// Hosts belong to the same family when they share the last two labels (`dl.google.com` ~ `www.google.com`).
public struct HostFamily: Equatable {
    public let value: String
    public init(_ url: URL) {
        let labels = (url.host ?? "").lowercased().split(separator: ".")
        value = labels.suffix(2).joined(separator: ".")
    }
}
