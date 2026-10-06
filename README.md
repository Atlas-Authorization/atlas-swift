# Atlas Swift SDK

The official native iOS / macOS SDK for the [Atlas](../../) auth platform — a
dependency-light Swift Package that speaks the Atlas Frontend API (FAPI) with
`URLSession` + `async/await` + `Codable`. It mirrors the vanilla JS client
(`@atlas/js`) endpoint-for-endpoint and shape-for-shape.

> **Scope.** This is a solid, tested *foundation*: the client-facing auth core a
> native app needs, now including native **passkeys** (register + sign in). It is
> not yet a complete SDK — see [Scope](#scope) for what a full release still needs
> (prebuilt UI, the multi-step MFA driver).

## Install

Swift Package Manager. In your `Package.swift`:

```swift
.package(path: "../ssoly/sdks/swift") // or the published git URL
```

or in Xcode: **File → Add Package Dependencies → Add Local**.

No third-party dependencies. Requires iOS 13+/macOS 12+ (async/await).

## Quick start

```swift
import Atlas

let atlas = AtlasClient(
    publishableKey: "pk_live_…",
    frontendApi: "clerk.your-domain.com"   // bare host is upgraded to https://
)

// Password sign-in: create attempt → attempt first factor → exchange ticket.
// The session JWT + refresh cookie are persisted to the Keychain.
let user = try await atlas.signIn(email: "ada@example.com", password: "…")
print(user.id, user.primaryEmailId ?? "")

// Read the signed-in user later.
let me = try await atlas.currentUser()

// Rotate the token (call before it expires, or on a 401 retry).
try await atlas.refresh()

// Sign out — revokes server-side and clears the Keychain.
try await atlas.signOut()
```

### OAuth (ASWebAuthenticationSession)

```swift
import AuthenticationServices

let authURL = try await atlas.oauthAuthorizeURL(
    provider: "google",
    redirectURI: "myapp://callback"
)

let session = ASWebAuthenticationSession(
    url: authURL,
    callbackURLScheme: "myapp"
) { callbackURL, error in
    guard let callbackURL else { return }
    // Atlas appends __atlas_attempt + __atlas_ticket to the callback.
    let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let attempt = items.first { $0.name == "__atlas_attempt" }?.value
    let ticket  = items.first { $0.name == "__atlas_ticket" }?.value
    if let attempt, let ticket {
        Task { try await atlas.exchangeTicket(attemptId: attempt, ticket: ticket) }
    }
}
session.presentationContextProvider = self
session.start()
```

### Passkeys (WebAuthn)

Native passkeys run through `ASAuthorizationController`, wrapped in `async/await`.
Two methods, one per ceremony; both take the relying-party id and challenge from
the server's `begin` response (never hardcoded), so they always match the
instance.

```swift
// Register a passkey for the signed-in user. Uses the session the SDK already
// holds. `name` is an optional label shown in the user's device passkey list.
let passkey = try await atlas.registerPasskey(name: "My iPhone")
print(passkey.id)

// Sign in with a passkey — no identifier needed, the credential names the user.
// On success the session (JWT + refresh token) is persisted like any sign-in,
// and the signed-in user is returned.
let user = try await atlas.signInWithPasskey()
```

Both throw `AtlasError` for an API failure and the platform `ASAuthorizationError`
if the system sheet fails or the user cancels. Available on **iOS 16+, macOS 12+,
tvOS 16+** (gated with `@available`; the rest of the SDK still builds on older
targets).

#### Setup (Associated Domains)

Passkeys are bound to a domain, so the app must claim the instance's Frontend API
host. In Xcode, add the **Associated Domains** capability and an entry:

```
webcredentials:clerk.your-domain.com
```

(Use your instance's FAPI host — the same value you pass as `frontendApi`.) Atlas
serves the matching `/.well-known/apple-app-site-association` on that host
automatically, per instance — **you do not self-host it**. Once the entitlement
and the served AASA agree, the system offers and verifies passkeys with no further
configuration.

## Surface

| Method | FAPI endpoint(s) |
| --- | --- |
| `signIn(email:password:)` | `POST /v1/client/sign_ins` → `…/attempt_first_factor` → `POST /v1/client/tickets/exchange` |
| `oauthAuthorizeURL(provider:redirectURI:)` | `POST /v1/client/sign_ins/oauth` |
| `exchangeTicket(attemptId:ticket:)` | `POST /v1/client/tickets/exchange` |
| `currentUser()` | `GET /v1/client/me` |
| `refresh()` | `POST /v1/client/sessions/:id/tokens` |
| `signOut()` | `POST /v1/client/sessions/:id/revoke` |
| `registerPasskey(name:)` | `POST /v1/client/me/passkeys/begin` → `…/finish` |
| `signInWithPasskey()` | `POST /v1/client/sign_ins/passkey/begin` → `…/finish` |

Every request sends `x-publishable-key`. The short-lived session **JWT** is
stored via the `TokenStore`; the long-lived **`__atlas_rt`** refresh token is
captured from the `Set-Cookie` header and re-presented on authenticated calls —
the app never handles it directly.

## Native session (first-party OAuth, cookie-free)

A **first-party** OAuth client can trade an OAuth access token it already holds
for a real Atlas session and then carry it by hand as a bearer — no cookie jar
needed. See `NativeSession.swift`:

- `exchangeForSession(baseURL:clientId:accessToken:)` — RFC 8693 token-exchange
  against `POST /oauth2/token`.
- `refreshNativeSession(baseURL:publishableKey:sessionId:refreshToken:)` — rotate
  without a cookie via `POST /v1/client/sessions/:id/tokens`.
- `NativeSessionManager` — an `actor` that holds the session, hands out a fresh
  bearer via `token()`/`authHeaders()` (lazy, single-flight refresh ~10s before
  expiry), and persists each rotated refresh token to the `TokenStore`.

Both helpers **fail soft** — they return `nil` on any error, the caller's cue to
re-run OAuth. (Added in **0.2.0**; there is no version constant in source — the
package is versioned by git tag.)

## Token storage

`TokenStore` is a protocol, so persistence is yours to choose:

- **`KeychainTokenStore`** (default) — one Keychain item, accessible after first
  unlock, `ThisDeviceOnly` so it never rides along in a backup.
- **`InMemoryTokenStore`** — process-lifetime; tests and previews.
- Conform your own type for a custom vault.

```swift
let atlas = AtlasClient(
    publishableKey: "pk_…",
    frontendApi: "clerk.your-domain.com",
    tokenStore: KeychainTokenStore(account: "pk_…", accessGroup: "TEAMID.com.you.shared")
)
```

## Errors

Everything throws `AtlasError`, decoded from the §9.1 envelope
`{ errors: [{ code, message, param? }] }`:

```swift
do {
    try await atlas.signIn(email: e, password: p)
} catch let error as AtlasError {
    switch error.code {
    case "form_password_incorrect": …
    case "form_identifier_not_found": …
    default: showBanner(error.message)   // message is always non-nil
    }
    print(error.status ?? -1)            // HTTP status for .api errors
}
```

`.transport` (network) and `.decoding` (contract drift) are distinct cases;
`.notSignedIn` is raised locally when an authenticated call has no session.

## Tests

```bash
swift test
```

The unit tests run entirely offline against a mocked `URLProtocol`
(`MockURLProtocol`) — no network. They pin: the auth header + base URL on every
request; that password sign-in walks the exact three endpoints with the exact
bodies and stores the returned JWT + refresh cookie; that a 4xx/5xx becomes an
`AtlasError` with the right `code`; that `currentUser()` decodes the full `/me`
shape and presents the cookie; that `refresh()` rotates the stored token; the
token-store round-trip; and the passkey `begin`-response decoding and
credential → `finish` body mapping (the base64url codec and exact field names),
which need no device.

## Scope

A complete native SDK on top of this foundation would add:

- **A multi-step flow driver** mirroring `@atlas/js`'s `nextStep` / `advance` —
  email-code, second factor, MFA enrollment, password reset — instead of the
  single password happy-path here.
- **Prebuilt SwiftUI components** (`<SignIn>` / `<UserButton>` equivalents) and
  an observable session object for reactive UI.
- **Sign in with Apple / Google One-Tap** native token exchange
  (`POST /v1/client/sign_ins/id_token`).
- Organizations, session listing, and the `/me` mutation surface (email,
  external accounts, metadata).
