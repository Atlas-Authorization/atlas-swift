import Foundation

/// A `URLProtocol` that answers requests from an in-memory queue — no network,
/// fully deterministic. Each registered handler sees the outgoing request (so a
/// test can assert on the URL, method, headers, and body) and returns the status,
/// headers, and body to reply with.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    /// Every request the session made, in order — the mutation-check surface.
    static var recorded: [URLRequest] = []
    /// Bodies, captured separately because URLProtocol strips `httpBody` from the
    /// request it hands us (it moves to `httpBodyStream`).
    static var recordedBodies: [Data] = []
    /// FIFO queue of canned responses.
    static var stubs: [Stub] = []

    static func reset() {
        recorded = []
        recordedBodies = []
        stubs = []
    }

    static func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        var merged = headers
        if merged["Content-Type"] == nil { merged["Content-Type"] = "application/json" }
        stubs.append(Stub(status: status, headers: merged, body: Data(json.utf8)))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.recorded.append(request)
        MockURLProtocol.recordedBodies.append(Self.bodyData(of: request))

        guard !MockURLProtocol.stubs.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let stub = MockURLProtocol.stubs.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Read the request body whether it survived as `httpBody` or was moved to a
    /// stream (URLSession does the latter).
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// Build a session whose only transport is this mock.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}
