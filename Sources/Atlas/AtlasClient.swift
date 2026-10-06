import Foundation

/// The Atlas FAPI client — the client-facing auth core for a native app.
///
/// It mirrors the vanilla JS (`@atlas/js`) FAPI contract exactly: every request
/// carries the `x-publishable-key` header, hits the `frontendApi` origin, and
/// speaks the §5 attempt / §9.1 error / §9.2 session shapes. The session token
/// (JWT) is persisted through a ``TokenStore`` (the Keychain in production); the
/// HttpOnly `__atlas_rt` refresh cookie is captured and re-presented so the SDK
/// can call `me` and rotate the token without the app ever handling it.
///
/// The client is intentionally thin. It does not drive multi-step MFA UI or own
/// a cookie jar — see the README's scope note. Native passkeys (register +
/// sign in) live in `Passkeys.swift` as an extension on this type. What it does,
/// it does to the letter of the server contract.
public final class AtlasClient: @unchecked Sendable {
    /// Cookie names the server sets (mirrors the API's `COOKIE_NAMES`).
    enum Cookie {
        static let session = "__session"
        static let refresh = "__atlas_rt"
    }

    public let publishableKey: String
    /// The resolved base URL, e.g. `https://clerk.example.com`.
    public let baseURL: URL
    public let tokenStore: TokenStore

    private let session: URLSession
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - publishableKey: the instance's `pk_...` publishable key. Sent as
    ///     `x-publishable-key` on every request.
    ///   - frontendApi: the instance's FAPI host (`clerk.example.com`) or a full
    ///     origin. A bare host is upgraded to `https://`.
    ///   - tokenStore: where the session is persisted. Defaults to the Keychain,
    ///     namespaced by the publishable key.
    ///   - urlSession: injectable for tests (a mocked `URLProtocol`); defaults to
    ///     an ephemeral session so cookies are never written to shared storage —
    ///     the SDK manages the refresh cookie itself.
    public init(
        publishableKey: String,
        frontendApi: String,
        tokenStore: TokenStore? = nil,
        urlSession: URLSession? = nil
    ) {
        self.publishableKey = publishableKey
        self.baseURL = AtlasClient.resolveBaseURL(frontendApi)
        self.tokenStore = tokenStore ?? KeychainTokenStore(account: publishableKey)

        if let urlSession {
            self.session = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // The SDK captures and replays the refresh cookie explicitly, so it
            // does not want URLSession quietly maintaining a second copy.
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }

        self.decoder = JSONDecoder()
    }

    static func resolveBaseURL(_ frontendApi: String) -> URL {
        let trimmed = frontendApi.trimmingCharacters(in: .whitespaces)
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed)"
        // A trailing slash would double up against the leading slash in each path.
        let normalized = withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
        // Force-unwrap is safe: a scheme+host string is always a valid URL.
        return URL(string: normalized)!
    }

    // MARK: - Auth flows

    /// Password sign-in, end to end (§5 → §7.1 → §9.2):
    /// 1. `POST /v1/client/sign_ins` to create the attempt,
    /// 2. `POST …/attempt_first_factor` with `strategy: password`,
    /// 3. `POST /v1/client/tickets/exchange` to turn the completion ticket into a
    ///    session, persisting the JWT + refresh cookie.
    ///
    /// Returns the freshly signed-in user. Throws ``AtlasError`` on any bad step
    /// — a wrong password surfaces as `.api` with `form_password_incorrect`.
    @discardableResult
    public func signIn(email: String, password: String) async throws -> AtlasUser {
        let attempt: SignInAttempt = try await postJSON(
            "/v1/client/sign_ins",
            body: ["identifier": email]
        )

        let completed: SignInAttempt = try await postJSON(
            "/v1/client/sign_ins/\(attempt.id)/attempt_first_factor",
            body: ["strategy": "password", "password": password]
        )

        guard completed.isComplete, let ticket = completed.ticket else {
            // A non-complete status (e.g. needs_second_factor) is a real flow the
            // foundation does not yet drive. Surfacing the status is honest.
            throw AtlasError.api(
                status: 200,
                errors: [AtlasErrorItem(
                    code: "sign_in_not_complete",
                    message: "Sign-in needs an additional step: \(completed.status).",
                    param: nil
                )]
            )
        }

        try await exchangeTicket(attemptId: completed.id, ticket: ticket)
        return try await currentUser()
    }

    /// Exchange a one-time ticket for a session (`POST /v1/client/tickets/exchange`).
    /// Also the completion of an OAuth redirect: read `__atlas_attempt` +
    /// `__atlas_ticket` off the callback URL and pass them here.
    public func exchangeTicket(attemptId: String, ticket: String) async throws {
        let (data, response) = try await send(
            "POST",
            "/v1/client/tickets/exchange",
            body: ["attempt_id": attemptId, "ticket": ticket],
            refreshCookie: nil
        )
        try throwIfError(status: response.statusCode, data: data)

        let tokens = try decode(SessionTokens.self, from: data)
        let refresh = extractCookie(Cookie.refresh, from: response)
        let sessionId = tokens.resolvedSessionId ?? attemptId
        try tokenStore.save(AtlasSession(sessionId: sessionId, token: tokens.jwt, refreshToken: refresh))
    }

    /// Build the provider authorize URL for an OAuth sign-in
    /// (`POST /v1/client/sign_ins/oauth`). Hand the returned URL to
    /// `ASWebAuthenticationSession`; on the callback, pull the redirect params
    /// and call ``exchangeTicket(attemptId:ticket:)``.
    ///
    /// - Parameters:
    ///   - provider: the provider key (`google`, `github`, …).
    ///   - redirectURI: your app's callback URL / custom scheme.
    public func oauthAuthorizeURL(provider: String, redirectURI: String) async throws -> URL {
        let attempt: SignInAttempt = try await postJSON(
            "/v1/client/sign_ins/oauth",
            body: ["provider": provider, "redirect_url": redirectURI]
        )
        guard let raw = attempt.authorizationURL, let url = URL(string: raw) else {
            throw AtlasError.decoding("The server returned no authorization_url.")
        }
        return url
    }

    /// The signed-in user (`GET /v1/client/me`). Presents the stored refresh
    /// cookie for authentication; throws ``AtlasError/notSignedIn`` when there is
    /// no session.
    public func currentUser() async throws -> AtlasUser {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        let (data, response) = try await send(
            "GET",
            "/v1/client/me",
            body: nil,
            refreshCookie: cookieHeader(stored)
        )
        try throwIfError(status: response.statusCode, data: data)
        return try decode(AtlasUser.self, from: data)
    }

    /// Rotate the refresh token and mint a fresh JWT
    /// (`POST /v1/client/sessions/:id/tokens`). Updates the stored session with
    /// the new token and rotated cookie.
    @discardableResult
    public func refresh() async throws -> AtlasSession {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        let (data, response) = try await send(
            "POST",
            "/v1/client/sessions/\(stored.sessionId)/tokens",
            body: nil,
            refreshCookie: cookieHeader(stored)
        )
        try throwIfError(status: response.statusCode, data: data)

        let tokens = try decode(SessionTokens.self, from: data)
        let rotated = extractCookie(Cookie.refresh, from: response) ?? stored.refreshToken
        let updated = AtlasSession(
            sessionId: tokens.resolvedSessionId ?? stored.sessionId,
            token: tokens.jwt,
            refreshToken: rotated
        )
        try tokenStore.save(updated)
        return updated
    }

    /// Sign out: revoke the session server-side
    /// (`POST /v1/client/sessions/:id/revoke`) and clear local storage. Local
    /// state is cleared even if the network call fails — a client that keeps a
    /// token after the user tapped "sign out" is the worse failure.
    public func signOut() async throws {
        defer { try? tokenStore.clear() }
        guard let stored = try tokenStore.load() else { return }
        _ = try? await send(
            "POST",
            "/v1/client/sessions/\(stored.sessionId)/revoke",
            body: nil,
            refreshCookie: cookieHeader(stored)
        )
    }

    /// Whether a session is currently persisted. A cheap, offline check — it does
    /// not validate the token against the server.
    public func hasSession() -> Bool {
        ((try? tokenStore.load()) ?? nil) != nil
    }

    // MARK: - HTTP core

    private func postJSON<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        let (data, response) = try await send("POST", path, body: body, refreshCookie: nil)
        try throwIfError(status: response.statusCode, data: data)
        return try decode(T.self, from: data)
    }

    /// The single place a request is built and sent. Every call flows through
    /// here so the auth header, base URL, and JSON content type are set in
    /// exactly one place — the class of bug where one endpoint forgets the key.
    ///
    /// `authorization` carries a bearer token for the routes that authenticate
    /// with the session JWT in a header rather than a cookie (the cookieless
    /// passkey-register path); it is independent of `refreshCookie`.
    func send(
        _ method: String,
        _ path: String,
        body: [String: String]?,
        refreshCookie: String?,
        authorization: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        // A string-dict body is just a JSON object; it flows through the single
        // JSON request path so the auth header + content type are set in one place.
        try await sendJSON(method, path, json: body, refreshCookie: refreshCookie, authorization: authorization)
    }

    /// The single place a request is built and sent, for an arbitrary JSON object
    /// body. The flow drivers and the `/me` mutation surface need nested values,
    /// arrays (`codes`, `additional_scopes`), and free-form metadata that a
    /// `[String: String]` body cannot express — so every call funnels through here,
    /// keeping the publishable-key header, cookie, bearer, and content type in one
    /// place (the class of bug where one endpoint forgets the key).
    func sendJSON(
        _ method: String,
        _ path: String,
        json: [String: Any]?,
        refreshCookie: String?,
        authorization: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(publishableKey, forHTTPHeaderField: "x-publishable-key")
        if let refreshCookie {
            request.setValue(refreshCookie, forHTTPHeaderField: "Cookie")
        }
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AtlasError.transport("We could not reach the server: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AtlasError.transport("The server returned a non-HTTP response.")
        }
        return (data, http)
    }

    /// Send an authenticated `/v1/client/me/*` (or session) request, presenting the
    /// stored session JWT + refresh token as a browser would. Throws
    /// ``AtlasError/notSignedIn`` when there is no session, and maps a non-2xx to an
    /// ``AtlasError``. The one place the account-management surface reaches the server.
    @discardableResult
    func authedSend(
        _ method: String,
        _ path: String,
        json: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let stored = try tokenStore.load() else { throw AtlasError.notSignedIn }
        let (data, response) = try await sendJSON(
            method, path, json: json, refreshCookie: cookieHeader(stored)
        )
        try throwIfError(status: response.statusCode, data: data)
        return (data, response)
    }

    /// Decode an authenticated call's 2xx body into `T`.
    func authedDecode<T: Decodable>(
        _ type: T.Type,
        _ method: String,
        _ path: String,
        json: [String: Any]? = nil
    ) async throws -> T {
        let (data, _) = try await authedSend(method, path, json: json)
        return try decode(T.self, from: data)
    }

    /// Persist a session minted directly from a `jwt` + `Set-Cookie` refresh token
    /// (the passkey / id_token / flow-completion paths that answer with a session
    /// rather than a ticket to exchange).
    func persistDirectSession(jwt: String, sessionId: String?, response: HTTPURLResponse) throws {
        let refresh = extractCookie(Cookie.refresh, from: response)
        try tokenStore.save(AtlasSession(sessionId: sessionId ?? "", token: jwt, refreshToken: refresh))
    }

    func throwIfError(status: Int, data: Data) throws {
        guard (200..<300).contains(status) else {
            throw parseErrorEnvelope(status: status, data: data)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AtlasError.decoding("Could not decode \(type): \(error.localizedDescription)")
        }
    }

    /// Build the `Cookie` header from the stored session — both the session JWT
    /// and the refresh token, exactly as a browser would present them.
    private func cookieHeader(_ stored: AtlasSession) -> String {
        var parts = ["\(Cookie.session)=\(stored.token)"]
        if let refresh = stored.refreshToken {
            parts.append("\(Cookie.refresh)=\(refresh)")
        }
        return parts.joined(separator: "; ")
    }

    /// Pull one cookie value out of a response's `Set-Cookie` header(s).
    func extractCookie(_ name: String, from response: HTTPURLResponse) -> String? {
        guard let url = response.url else { return nil }
        // `allHeaderFields` collapses repeated Set-Cookie into a comma-joined
        // string on Foundation; HTTPCookie.cookies handles that parsing.
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                acc[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        return cookies.first(where: { $0.name == name })?.value
    }
}
