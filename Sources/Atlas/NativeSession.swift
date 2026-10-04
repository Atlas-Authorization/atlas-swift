import Foundation

/// Native session — the first-party OAuth→session exchange, cookie-free.
///
/// A FIRST-PARTY OAuth client (the app IS the tenant's own property, not a
/// third-party integration) already holds an Atlas OAuth access token. On the
/// web that token would ride in a cookie and the browser would carry the session
/// for free; a native iOS/macOS app has no cookie jar against the FAPI origin, so
/// it trades that OAuth access token for a real Atlas SESSION and then carries the
/// session itself, by hand, as a bearer.
///
/// This file is the Swift peer of `@atlas/js`'s `native-session.ts`:
///
///   1. ``exchangeForSession(baseURL:clientId:accessToken:urlSession:)`` — POST the
///      RFC 8693 token-exchange form to `/oauth2/token` and get back a
///      ``NativeSession``.
///   2. ``refreshNativeSession(baseURL:publishableKey:sessionId:refreshToken:urlSession:)``
///      — rotate the session WITHOUT a cookie, via
///      `POST /v1/client/sessions/:sid/tokens` with the stored refresh token.
///   3. ``NativeSessionManager`` — holds the current session, hands out a live JWT
///      (auto-refreshing near expiry, single-flight), and persists each rotated
///      refresh token to the SDK's ``TokenStore`` (the Keychain in production).
///
/// Neither network helper ever throws — a failure is a `nil`, the caller's cue to
/// re-run the OAuth flow rather than crash.

/// RFC 8693 token-exchange grant.
private let tokenExchangeGrant = "urn:ietf:params:oauth:grant-type:token-exchange"
/// The subject token the first-party app presents is an OAuth access token.
private let accessTokenType = "urn:ietf:params:oauth:token-type:access_token"
/// What we ask for in return: an Atlas session, not another OAuth token.
private let sessionTokenType = "urn:atlas:token-type:session"

/// A live Atlas session held outside a cookie.
///
/// `sessionToken` is the short-lived (~60s) session JWT sent as `Authorization:
/// Bearer …` on `/v1/client/me/*`. `refreshToken` mints the next one and ROTATES
/// on every refresh — persist the new value, discard the old. `expiresInSeconds`
/// is the lifetime the server reported for `sessionToken`, a scheduling hint only.
public struct NativeSession: Codable, Sendable, Equatable {
    /// The short-lived session JWT. Bearer it on `/v1/client/me/*`.
    public let sessionToken: String
    /// The rotating refresh token. Persist the latest; the previous one is dead.
    public let refreshToken: String
    /// The session id (`sess_…`), the path segment the refresh call needs.
    public let sessionId: String
    /// Reported lifetime of `sessionToken`, in seconds. A hint, not a guarantee.
    public let expiresInSeconds: Int

    public init(sessionToken: String, refreshToken: String, sessionId: String, expiresInSeconds: Int) {
        self.sessionToken = sessionToken
        self.refreshToken = refreshToken
        self.sessionId = sessionId
        self.expiresInSeconds = expiresInSeconds
    }

    /// Map to the ``AtlasSession`` the SDK's ``TokenStore`` persists, so a native
    /// session reuses the same Keychain entry as the cookie-based client.
    public var asSession: AtlasSession {
        AtlasSession(sessionId: sessionId, token: sessionToken, refreshToken: refreshToken)
    }

    /// Rebuild from a persisted ``AtlasSession``. The reported expiry is not
    /// persisted, so it rehydrates as `0` — the manager treats the token as due
    /// for a refresh on its first use, which is the safe default.
    public init(session: AtlasSession) {
        self.init(
            sessionToken: session.token,
            refreshToken: session.refreshToken ?? "",
            sessionId: session.sessionId,
            expiresInSeconds: 0
        )
    }
}

/// The shape `/oauth2/token` answers a successful token-exchange with.
private struct TokenExchangeResponse: Decodable {
    let accessToken: String?
    let sessionId: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case sessionId = "session_id"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// The shape `/v1/client/sessions/:sid/tokens` answers a cookie-free refresh with.
private struct SessionTokensResponse: Decodable {
    let jwt: String?
    let sessionId: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case jwt
        case sessionId = "session_id"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Percent-encode form pairs for an `application/x-www-form-urlencoded` body.
private func formURLEncode(_ pairs: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return pairs.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }.joined(separator: "&")
}

private func is2xx(_ response: URLResponse?) -> Bool {
    guard let http = response as? HTTPURLResponse else { return false }
    return (200..<300).contains(http.statusCode)
}

/// Exchange a first-party OAuth access token for an Atlas session.
///
/// POSTs the RFC 8693 token-exchange form to `{baseURL}/oauth2/token` and parses
/// the result into a ``NativeSession``. Returns `nil` — never throws — on a
/// network failure, a non-2xx, or a body missing the session token or id, so a
/// caller treats a failed exchange as "re-run OAuth" rather than a crash.
public func exchangeForSession(
    baseURL: URL,
    clientId: String,
    accessToken: String,
    urlSession: URLSession = .shared
) async -> NativeSession? {
    var request = URLRequest(url: baseURL.appendingPathComponent("/oauth2/token"))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.httpBody = Data(formURLEncode([
        ("grant_type", tokenExchangeGrant),
        ("client_id", clientId),
        ("subject_token", accessToken),
        ("subject_token_type", accessTokenType),
        ("requested_token_type", sessionTokenType),
    ]).utf8)

    guard
        let (data, response) = try? await urlSession.data(for: request),
        is2xx(response),
        let body = try? JSONDecoder().decode(TokenExchangeResponse.self, from: data),
        // A session is only a session if it carries both the JWT and the id the
        // refresh path needs; anything short of that is a failed exchange.
        let token = body.accessToken,
        let sessionId = body.sessionId
    else {
        return nil
    }

    return NativeSession(
        sessionToken: token,
        refreshToken: body.refreshToken ?? "",
        sessionId: sessionId,
        expiresInSeconds: body.expiresIn ?? 0
    )
}

/// Rotate a native session WITHOUT a cookie.
///
/// POSTs the stored refresh token to `/v1/client/sessions/{sessionId}/tokens` with
/// the publishable-key header, and returns the rotated ``NativeSession``. Each
/// refresh ROTATES the refresh token — the caller MUST persist what comes back. If
/// the server omits a fresh `refresh_token` (it may, when it reuses the presented
/// one), the presented token is carried forward. Returns `nil` — never throws — on
/// a network failure, a non-2xx, or a body with no `jwt`.
public func refreshNativeSession(
    baseURL: URL,
    publishableKey: String,
    sessionId: String,
    refreshToken: String,
    urlSession: URLSession = .shared
) async -> NativeSession? {
    var request = URLRequest(url: baseURL.appendingPathComponent("/v1/client/sessions/\(sessionId)/tokens"))
    request.httpMethod = "POST"
    request.setValue(publishableKey, forHTTPHeaderField: "x-publishable-key")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

    guard
        let (data, response) = try? await urlSession.data(for: request),
        is2xx(response),
        let body = try? JSONDecoder().decode(SessionTokensResponse.self, from: data),
        let jwt = body.jwt
    else {
        return nil
    }

    return NativeSession(
        sessionToken: jwt,
        // Carry the rotated token; fall back to the presented one if the server
        // reused it rather than issuing a new value.
        refreshToken: body.refreshToken ?? refreshToken,
        sessionId: body.sessionId ?? sessionId,
        expiresInSeconds: body.expiresIn ?? 0
    )
}

/// Holds the current ``NativeSession`` and keeps its JWT live.
///
/// An `actor`, so concurrent callers of ``token()`` share one in-flight refresh
/// (single-flight) without a lock of their own. It refreshes LAZILY — on
/// ``token()``/``authHeaders()``, when the token is within the refresh lead (~10s)
/// of expiry — rather than on a timer, because a backgrounded app cannot keep one
/// alive anyway. Each rotation persists the new session to the ``TokenStore`` so
/// the Keychain captures the rotated refresh token; the previous one is dead.
public actor NativeSessionManager {
    /// How close to expiry the token may get before ``token()`` rotates it.
    public static let refreshLeadSeconds: TimeInterval = 10

    public let publishableKey: String
    /// The resolved FAPI base URL, e.g. `https://clerk.example.com`.
    public let baseURL: URL
    /// The first-party OAuth client id; `nil` disables in-manager ``exchange(accessToken:)``.
    public let clientId: String?
    public let tokenStore: TokenStore

    private let urlSession: URLSession
    private let now: @Sendable () -> Date
    private let refreshLead: TimeInterval

    private var session: NativeSession?
    /// Absolute expiry of the current `sessionToken`.
    private var expiresAt: Date = .distantPast
    /// Single-flight guard: concurrent ``token()`` calls share one refresh.
    private var refreshTask: Task<NativeSession?, Never>?

    /// - Parameters:
    ///   - publishableKey: the instance's `pk_...` key, sent on the refresh call
    ///     and in ``authHeaders()``.
    ///   - frontendApi: the FAPI host (`clerk.example.com`) or a full origin.
    ///   - clientId: the first-party OAuth client id for ``exchange(accessToken:)``.
    ///   - tokenStore: where the session is persisted; defaults to the Keychain,
    ///     namespaced by the publishable key.
    ///   - urlSession: injectable for tests; defaults to a cookie-less ephemeral
    ///     session (the manager carries the session as a bearer, not a cookie).
    ///   - now: injectable clock, for testing refresh timing.
    public init(
        publishableKey: String,
        frontendApi: String,
        clientId: String? = nil,
        tokenStore: TokenStore? = nil,
        urlSession: URLSession? = nil,
        refreshLead: TimeInterval = NativeSessionManager.refreshLeadSeconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.publishableKey = publishableKey
        self.baseURL = AtlasClient.resolveBaseURL(frontendApi)
        self.clientId = clientId
        self.tokenStore = tokenStore ?? KeychainTokenStore(account: publishableKey)
        self.refreshLead = refreshLead
        self.now = now

        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.urlSession = URLSession(configuration: configuration)
        }

        // Rehydrate a persisted session. Its expiry is unknown (not persisted), so
        // seed it as already-due: the first `token()` refreshes before use.
        if let stored = (try? self.tokenStore.load()) ?? nil {
            self.session = NativeSession(session: stored)
            self.expiresAt = now()
        }
    }

    /// The current session, or `nil` when signed out. Does NOT refresh.
    public var current: NativeSession? { session }

    /// Exchange a first-party OAuth access token for a session, store it, and
    /// return it. Returns `nil` when no `clientId` was configured or the exchange
    /// fails (the caller's cue to re-run OAuth).
    @discardableResult
    public func exchange(accessToken: String) async -> NativeSession? {
        guard let clientId else { return nil }
        guard let session = await exchangeForSession(
            baseURL: baseURL,
            clientId: clientId,
            accessToken: accessToken,
            urlSession: urlSession
        ) else { return nil }
        setSession(session)
        return session
    }

    /// The current session JWT, refreshed first if it is within the refresh lead
    /// of expiry. Returns `nil` when signed out. If the refresh fails the EXISTING
    /// token is handed back rather than `nil` — a truly-dead token is rejected on
    /// use (the 401 is the caller's cue), a better failure than pre-emptive
    /// sign-out on a flaky connection.
    public func token() async -> String? {
        guard let session else { return nil }
        if needsRefresh(), let rotated = await refresh() {
            return rotated.sessionToken
        }
        return session.sessionToken
    }

    /// The headers an authenticated `/v1/client/me/*` call needs: a fresh bearer
    /// (auto-refreshed like ``token()``) plus the publishable key. When signed out,
    /// only the publishable key is returned.
    public func authHeaders() async -> [String: String] {
        if let token = await token() {
            return ["Authorization": "Bearer \(token)", "x-publishable-key": publishableKey]
        }
        return ["x-publishable-key": publishableKey]
    }

    /// Replace the current session and persist it (e.g. after a manual exchange).
    public func setSession(_ session: NativeSession) {
        self.session = session
        self.expiresAt = now().addingTimeInterval(TimeInterval(session.expiresInSeconds))
        try? tokenStore.save(session.asSession)
    }

    /// Forget the session (sign-out). Does not touch the store.
    public func clear() {
        session = nil
        expiresAt = .distantPast
        refreshTask = nil
    }

    /// Rotate the session now. Single-flight: a refresh already in progress is
    /// shared rather than duplicated. On success the new session is stored and
    /// `nil` on failure, leaving the current session untouched.
    @discardableResult
    public func refresh() async -> NativeSession? {
        if let refreshTask { return await refreshTask.value }
        guard let session else { return nil }

        let task = Task { [baseURL, publishableKey, urlSession, session] in
            await refreshNativeSession(
                baseURL: baseURL,
                publishableKey: publishableKey,
                sessionId: session.sessionId,
                refreshToken: session.refreshToken,
                urlSession: urlSession
            )
        }
        refreshTask = task
        let rotated = await task.value
        refreshTask = nil
        if let rotated { setSession(rotated) }
        return rotated
    }

    private func needsRefresh() -> Bool {
        guard session != nil else { return false }
        return expiresAt.addingTimeInterval(-refreshLead) <= now()
    }
}
