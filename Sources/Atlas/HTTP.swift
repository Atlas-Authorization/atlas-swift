import Foundation

/// The SDK's one HTTP round trip. Every request (``AtlasClient``, the device
/// flow, the native-session helpers) funnels through here, so a test harness can
/// answer a particular `URLSession`'s requests in memory. That matters on
/// watchOS, where `URLProtocol` subclasses registered on a session configuration
/// are not consulted, so the usual stubbing never sees the request.
enum AtlasHTTP {
    typealias Responder = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let lock = NSLock()
    private static var responders: [ObjectIdentifier: Responder] = [:]

    /// Answer every request sent through `session` with `responder` (tests only).
    static func register(_ session: URLSession, responder: @escaping Responder) {
        lock.lock(); defer { lock.unlock() }
        responders[ObjectIdentifier(session)] = responder
    }

    private static func responder(for session: URLSession) -> Responder? {
        lock.lock(); defer { lock.unlock() }
        return responders[ObjectIdentifier(session)]
    }

    /// Send `request` through `session` (or its registered responder).
    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        if let responder = responder(for: session) { return try await responder(request) }
        return try await session.data(for: request)
    }
}
