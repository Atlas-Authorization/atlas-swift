import Foundation

/// "Sign in on another device" — the OAuth 2.0 Device Authorization Grant
/// (RFC 8628) — for screens where typing a password is the wrong experience:
/// Apple TV, Apple Watch, a kiosk.
///
/// The device asks Atlas for a short `user_code` and a `verification_uri`, shows
/// them (and a QR code of `verification_uri_complete`), and polls the token
/// endpoint while the person approves on their phone or computer, where they are
/// already signed in. Once approved, the device trades the OAuth access token it
/// receives for a real Atlas session (the first-party token exchange — see
/// `NativeSession.swift`), persists it to the ``TokenStore`` and loads the user.
///
///   start: POST /oauth2/device_authorization          → user_code, verification_uri, …
///   wait : POST /oauth2/token  grant_type=device_code → authorization_pending / slow_down /
///                                                       access_denied / expired_token / tokens
///          POST /oauth2/token  grant_type=token-exchange, requested_token_type=session
///          GET  /v1/client/me
///
/// **Client setup.** Register a first-party OAuth client for the app with the
/// `urn:ietf:params:oauth:grant-type:device_code` and `refresh_token` grants
/// (public, no secret). The refresh grant is what makes the approval
/// session-eligible; without it the session exchange is refused.

// MARK: - model

/// A pending device sign-in: what to show the person, and what the device polls with.
public struct AtlasDeviceAuthorization: Sendable, Equatable {
    /// The OAuth client the code was issued to (the poll must present the same one).
    public let clientId: String
    /// The secret the device polls with. Never show it.
    public let deviceCode: String
    /// The short code the person types on their other device (`ABCD-EFGH`).
    public let userCode: String
    /// Where the person goes to enter ``userCode``.
    public let verificationURI: URL
    /// ``verificationURI`` with the code pre-filled — the QR code's content.
    public let verificationURIComplete: URL?
    /// Lifetime of the codes, in seconds, as the server reported it.
    public let expiresIn: Int
    /// The minimum polling interval, in seconds, as the server reported it.
    public let interval: Int
    /// When the codes were issued (the device clock at the response).
    public let issuedAt: Date

    public init(
        clientId: String,
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL?,
        expiresIn: Int,
        interval: Int,
        issuedAt: Date
    ) {
        self.clientId = clientId
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
        self.issuedAt = issuedAt
    }

    /// When the codes stop working.
    public var expiresAt: Date { issuedAt.addingTimeInterval(TimeInterval(expiresIn)) }

    /// Seconds left before the codes expire, never negative.
    public func secondsRemaining(at date: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(date).rounded(.up)))
    }

    /// The URL to encode in a QR code: the pre-filled link when the server sent one.
    public var qrCodeURL: URL { verificationURIComplete ?? verificationURI }

    /// ``verificationURI`` without the scheme (`example.com/oauth2/device`), the
    /// form people read off a TV screen and type.
    public var displayVerificationURI: String {
        let raw = verificationURI.absoluteString
        for scheme in ["https://", "http://"] where raw.hasPrefix(scheme) {
            return String(raw.dropFirst(scheme.count))
        }
        return raw
    }
}

/// The `/oauth2/device_authorization` response (RFC 8628 §3.2).
struct DeviceAuthorizationResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: Int
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// A successful `/oauth2/token` response (the device grant or the session exchange).
struct OAuthTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case sessionId = "session_id"
    }
}

/// The RFC 6749 §5.2 error body every OAuth endpoint answers with.
struct OAuthErrorBody: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// The OAuth error codes the device flow names.
public enum AtlasDeviceFlowError {
    /// The person has not approved yet; keep polling (handled inside the SDK).
    public static let authorizationPending = "authorization_pending"
    /// Polling too fast; add 5 seconds to the interval (handled inside the SDK).
    public static let slowDown = "slow_down"
    /// The person denied the request on their other device.
    public static let accessDenied = "access_denied"
    /// The codes expired before they were approved; start again.
    public static let expiredToken = "expired_token"
    /// No OAuth client id was configured or the server rejected it.
    public static let invalidClient = "invalid_client"
}

/// Map an OAuth error body onto ``AtlasError``: the OAuth `error` becomes the
/// code, `error_description` the message, so device-flow failures are caught and
/// branched on like every other SDK failure.
func parseOAuthError(status: Int, data: Data) -> AtlasError {
    if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data) {
        return .api(status: status, errors: [AtlasErrorItem(
            code: body.error,
            message: body.errorDescription ?? defaultOAuthMessage(body.error)
        )])
    }
    // Some deployments answer with the §9.1 envelope (a proxy, a disabled module).
    return parseErrorEnvelope(status: status, data: data)
}

private func defaultOAuthMessage(_ code: String) -> String {
    switch code {
    case AtlasDeviceFlowError.accessDenied: return "The sign-in was denied."
    case AtlasDeviceFlowError.expiredToken: return "The code expired. Get a new code and try again."
    default: return "The sign-in failed (\(code))."
    }
}

extension AtlasError {
    /// The device codes expired before they were approved (`expired_token`).
    /// Start a new device sign-in.
    public var isDeviceCodeExpired: Bool { code == AtlasDeviceFlowError.expiredToken }

    /// The person denied the device sign-in on their other device (`access_denied`).
    public var isDeviceSignInDenied: Bool { code == AtlasDeviceFlowError.accessDenied }

    /// The device codes expired, raised locally once the deadline passes so the
    /// device never polls a dead code.
    static let deviceCodeExpired = AtlasError.api(status: 400, errors: [AtlasErrorItem(
        code: AtlasDeviceFlowError.expiredToken,
        message: defaultOAuthMessage(AtlasDeviceFlowError.expiredToken)
    )])
}

/// One poll's outcome.
enum DevicePollResult {
    case approved(accessToken: String)
    case pending
    case slowDown
}

// MARK: - client API

private let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"
private let tokenExchangeGrantType = "urn:ietf:params:oauth:grant-type:token-exchange"
private let accessTokenTypeURN = "urn:ietf:params:oauth:token-type:access_token"
private let sessionTokenTypeURN = "urn:atlas:token-type:session"

/// RFC 8628 §3.5: each `slow_down` adds 5 seconds to the polling interval.
let deviceFlowSlowDownIncrement = 5
/// Ceiling for the backoff after a network failure.
let deviceFlowMaxBackoff = 60

extension AtlasClient {
    /// A sensible device name for the session list: the kind of device this is.
    public static var platformDeviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(watchOS)
        return "Apple Watch"
        #elseif os(visionOS)
        return "Apple Vision Pro"
        #elseif os(macOS)
        return "Mac"
        #else
        return "iPhone or iPad"
        #endif
    }

    /// Start a device sign-in (`POST /oauth2/device_authorization`, RFC 8628 §3.1).
    ///
    /// Show the returned ``AtlasDeviceAuthorization/userCode`` and
    /// ``AtlasDeviceAuthorization/verificationURI`` (and a QR code of
    /// ``AtlasDeviceAuthorization/qrCodeURL``), then call
    /// ``waitForDeviceSignIn(_:deviceName:)``.
    ///
    /// - Parameters:
    ///   - clientId: the first-party OAuth client; defaults to ``oauthClientId``.
    ///   - scopes: scopes to request; empty (the default) asks for the client's
    ///     configured set.
    /// - Throws: ``AtlasError`` — `invalid_client` when no client id is set or the
    ///   server rejects it, `unauthorized_client` when the client lacks the
    ///   device_code grant, `invalid_scope` for a scope outside its allow-list.
    public func startDeviceSignIn(
        clientId: String? = nil,
        scopes: [String] = []
    ) async throws -> AtlasDeviceAuthorization {
        guard let clientId = (clientId ?? oauthClientId), !clientId.isEmpty else {
            throw AtlasError.api(status: 400, errors: [AtlasErrorItem(
                code: AtlasDeviceFlowError.invalidClient,
                message: "Device sign-in needs the app's OAuth client id (AtlasClient oauthClientId).",
                param: "client_id"
            )])
        }
        var form = [("client_id", clientId)]
        if !scopes.isEmpty { form.append(("scope", scopes.joined(separator: " "))) }

        let (data, response) = try await postForm("/oauth2/device_authorization", form)
        guard (200..<300).contains(response.statusCode) else {
            throw parseOAuthError(status: response.statusCode, data: data)
        }
        let body = try decode(DeviceAuthorizationResponse.self, from: data)
        guard let verification = URL(string: body.verificationUri) else {
            throw AtlasError.decoding("The server returned an invalid verification_uri.")
        }
        return AtlasDeviceAuthorization(
            clientId: clientId,
            deviceCode: body.deviceCode,
            userCode: body.userCode,
            verificationURI: verification,
            verificationURIComplete: body.verificationUriComplete.flatMap(URL.init(string:)),
            expiresIn: body.expiresIn,
            // RFC 8628 §3.2: when the server omits it, the client MUST use 5 seconds.
            interval: max(1, body.interval ?? 5),
            issuedAt: deviceFlowClock()
        )
    }

    /// Wait for the person to approve a device sign-in, then establish the session.
    ///
    /// Polls `POST /oauth2/token` every ``AtlasDeviceAuthorization/interval``
    /// seconds: `authorization_pending` keeps waiting, `slow_down` adds 5 seconds
    /// to the interval for the rest of the wait, a network failure backs off
    /// exponentially (up to 60 seconds) and keeps going. Once approved, the access
    /// token is exchanged for an Atlas session that is persisted to the
    /// ``TokenStore``, and the signed-in user is returned.
    ///
    /// The wait ends at the code's expiry without polling a dead code. Cancel the
    /// calling task to stop waiting (it throws `CancellationError`).
    ///
    /// - Parameter deviceName: the name shown in the person's device list;
    ///   defaults to ``platformDeviceName``.
    /// - Throws: ``AtlasError`` — ``AtlasError/isDeviceCodeExpired`` when the code
    ///   lapses (start again), ``AtlasError/isDeviceSignInDenied`` when the person
    ///   declines, the server's error for anything else (e.g. `invalid_grant`).
    @discardableResult
    public func waitForDeviceSignIn(
        _ authorization: AtlasDeviceAuthorization,
        deviceName: String? = nil
    ) async throws -> AtlasUser {
        var interval = TimeInterval(max(1, authorization.interval))
        while true {
            try Task.checkCancellation()
            let remaining = authorization.expiresAt.timeIntervalSince(deviceFlowClock())
            guard remaining > 0 else { throw AtlasError.deviceCodeExpired }
            try await deviceFlowSleep(min(interval, remaining))
            try Task.checkCancellation()
            guard authorization.expiresAt.timeIntervalSince(deviceFlowClock()) > 0 else {
                throw AtlasError.deviceCodeExpired
            }

            let result: DevicePollResult
            do {
                result = try await pollDeviceToken(authorization)
            } catch let error as AtlasError {
                guard case .transport = error else { throw error }
                // RFC 8628 §3.5: back off on a connection failure and keep waiting.
                interval = min(interval * 2, TimeInterval(deviceFlowMaxBackoff))
                continue
            }

            switch result {
            case .pending:
                continue
            case .slowDown:
                interval += TimeInterval(deviceFlowSlowDownIncrement)
            case let .approved(accessToken):
                try await establishDeviceSession(
                    clientId: authorization.clientId,
                    accessToken: accessToken,
                    deviceName: deviceName ?? AtlasClient.platformDeviceName
                )
                return try await currentUser()
            }
        }
    }

    /// One `/oauth2/token` poll with the device_code grant.
    func pollDeviceToken(_ authorization: AtlasDeviceAuthorization) async throws -> DevicePollResult {
        let (data, response) = try await postForm("/oauth2/token", [
            ("grant_type", deviceCodeGrant),
            ("device_code", authorization.deviceCode),
            ("client_id", authorization.clientId),
        ])
        if (200..<300).contains(response.statusCode) {
            let tokens = try decode(OAuthTokenResponse.self, from: data)
            guard let accessToken = tokens.accessToken, !accessToken.isEmpty else {
                throw AtlasError.decoding("The token response carried no access_token.")
            }
            return .approved(accessToken: accessToken)
        }
        let error = parseOAuthError(status: response.statusCode, data: data)
        switch error.code {
        case AtlasDeviceFlowError.authorizationPending: return .pending
        case AtlasDeviceFlowError.slowDown: return .slowDown
        default: throw error
        }
    }

    /// Trade the device grant's access token for an Atlas session (RFC 8693, the
    /// first-party session exchange) and persist it.
    func establishDeviceSession(clientId: String, accessToken: String, deviceName: String) async throws {
        let (data, response) = try await postForm("/oauth2/token", [
            ("grant_type", tokenExchangeGrantType),
            ("client_id", clientId),
            ("subject_token", accessToken),
            ("subject_token_type", accessTokenTypeURN),
            ("requested_token_type", sessionTokenTypeURN),
            ("device_name", deviceName),
        ])
        guard (200..<300).contains(response.statusCode) else {
            throw parseOAuthError(status: response.statusCode, data: data)
        }
        let body = try decode(OAuthTokenResponse.self, from: data)
        guard let jwt = body.accessToken, let sessionId = body.sessionId else {
            throw AtlasError.decoding("The session exchange returned no session.")
        }
        try tokenStore.save(AtlasSession(sessionId: sessionId, token: jwt, refreshToken: body.refreshToken))
    }

    /// POST an `application/x-www-form-urlencoded` body (the OAuth endpoints'
    /// encoding) with the publishable key, through the shared transport.
    func postForm(_ path: String, _ pairs: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "x-publishable-key")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = Data(formEncode(pairs).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await AtlasHTTP.data(for: request, session: session)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw AtlasError.transport("We could not reach the server: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AtlasError.transport("The server returned a non-HTTP response.")
        }
        return (data, http)
    }
}

/// Percent-encode form pairs (RFC 3986 unreserved characters pass through).
func formEncode(_ pairs: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return pairs.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }.joined(separator: "&")
}
