import Foundation
import os

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

public enum HTTPError: Error, Equatable, LocalizedError {
    case insecureURL(String)
    case insecureRedirect(String)
    case status(Int)
    case offline
    case timedOut
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url): String(localized: "Not an HTTPS address: \(url)")
        case .insecureRedirect(let url): String(localized: "Redirected to a non-HTTPS address: \(url)")
        case .status(let code): String(localized: "The server answered \(code)")
        case .offline: String(localized: "No internet connection")
        case .timedOut: String(localized: "Timed out")
        case .other(let message): message
        }
    }
}

public protocol HTTPClient: Sendable {
    /// GET a URL. Requests must be HTTPS; redirects to plain HTTP fail.
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse
    /// Download a URL to `destination`, reporting bytes received and the expected total.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
}

extension HTTPClient {
    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeout: Net.feedTimeout)
    }
}

public enum Net {
    public static let repository = URL(string: "https://github.com/EnigmaticZee/Burnish")!
    /// At most 8 network requests in flight.
    public static let maxInFlight = 8
    /// 10-second timeout per feed.
    public static let feedTimeout: TimeInterval = 10

    public static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Burnish/\(version) (+\(repository.absoluteString))"
    }

    static let log = Logger(subsystem: "io.github.enigmaticzee.Burnish", category: "net")
}

/// Limits how many requests run at once.
public actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ limit: Int) { available = limit }

    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
