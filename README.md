# Atlas Swift SDK

The official native iOS / macOS SDK for the [Atlas](../../) auth platform — a
dependency-light Swift Package that speaks the Atlas Frontend API (FAPI) with
`URLSession` + `async/await` + `Codable`. It mirrors the vanilla JS client
(`@atlas/js`) endpoint-for-endpoint and shape-for-shape.

> **Complete as of 0.4.0.** The full client-facing auth surface a native app
> needs: the single-call sign-in plus a **multi-step flow driver** (password,
> email/phone code, second factor, MFA enrollment, password reset, sign-up),
> native **passkeys**, **Sign in with Apple / Google id_token** exchange,
> **organizations**, **session (device) management**, the `/me` **mutation**
> surface (emails, external accounts, password, profile + metadata), and prebuilt
> **SwiftUI** components (`SignIn`, `UserButton`, `UserProfile`, and an observable
> `AtlasAuthSession`). It mirrors `@atlas/js` endpoint-for-endpoint.

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
| `signInFlow()` driver | `POST /v1/client/sign_ins` (+ `…/:id/prepare_first_factor`, `attempt_first_factor`, `prepare_second_factor`, `attempt_second_factor`, `prepare_mfa_enrollment`, `attempt_mfa_enrollment`) |
| `signUpFlow()` driver | `POST /v1/client/sign_ups` (+ `…/:id/prepare_verification`, `attempt_verification`) |
| `passwordResetFlow()` driver | `POST /v1/client/password_resets` (+ `…/:id/attempt_verification`, `attempt_second_factor`, `set_new_password`) |
| `signInWithIdToken(provider:idToken:nonce:)` | `POST /v1/client/sign_ins/id_token` |
| `mintNativeNonce(provider:)` | `POST /v1/client/sign_ins/id_token/nonce` |
| `organizations()` / `createOrganization(name:slug:)` | `GET`/`POST /v1/client/me/organizations`, `POST /v1/client/organizations` |
| `setActiveOrganization(_:)` | `POST /v1/client/sessions/:id/touch` |
| `sessions()` / `revokeSession(id:)` / `revokeOtherSessions()` | `GET /v1/client/sessions`, `…/:id/revoke`, `…/revoke_all` |
| `addEmailAddress` / `verifyEmailAddress` / `setPrimaryEmailAddress` / `removeEmailAddress` | `/v1/client/me/email_addresses…` |
| `connectExternalAccount` / `disconnectExternalAccount` | `/v1/client/me/external_accounts…` |
| `changePassword` / `setPassword` / `updateProfile` | `POST /v1/client/me/change_password`, `…/set_password`, `PATCH /v1/client/me` |

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

The 0.4.0 surface is covered the same way, all offline against the mock: the
flow-driver state transitions (sign-in password/second-factor/email-code/MFA
enrollment, sign-up, password reset) walk the exact endpoints and bodies and
assert the completion is exchanged into a persisted session; the pure
`signInStep(_:)` mapping is checked for every status (including an unknown one);
the id_token request body and the Apple identity-token decode are pinned; and the
organizations / sessions / `/me` methods assert the exact method, path, cookie
presentation, and request/response mapping (including that `unsafe_metadata` is
sent and `public_metadata` never is). The on-device SwiftUI rendering and the live
Apple/Google system sheets are the only parts that need a simulator/device.

## Multi-step flow driver

The single-call `signIn(email:password:)` is the happy path. Anything else — a
second factor, an emailed code, mid-sign-in MFA enrollment, a sign-up, a password
reset — runs through a **flow driver**: an `actor` that holds the server attempt
and exposes its next ``SignInStep`` so **your UI drives the next action and the
server decides the flow** (§5). A `complete` status is turned into a real session
automatically (the completion ticket is exchanged and the JWT + refresh cookie
persisted), after which the step is `.done`.

```swift
let flow = atlas.signInFlow()

switch try await flow.start(identifier: "ada@example.com") {
case .collectFirstFactor(let strategies):
    if strategies.contains("password") {
        switch try await flow.attemptPassword("…") {
        case .done:                 break          // session already persisted
        case .collectSecondFactor:
            try await flow.attemptSecondFactor(code: "123456")   // TOTP / SMS / backup code
        case .enrollSecondFactor:
            let e = try await flow.prepareMfaEnrollment()        // secret + otpauth:// URI (shown once)
            try await flow.attemptMfaEnrollment(factorId: e.factorId, codes: ["123456"])
        default: break
        }
    } else {
        try await flow.prepareEmailCode()          // or preparePhoneCode(channel:)
        try await flow.attemptEmailCode("000111")
    }
default: break
}
```

The step mapping (`signInStep(_:)`) is a **pure, exhaustive** function: an unknown
server status becomes an explicit `.unknown(status:)` a UI can render as "update
required" rather than a blank login box. A failed step throws `AtlasError` and
**leaves the attempt intact**, so a wrong password/code is a retry, not a restart.

`signUpFlow()` drives `/v1/client/sign_ups` (start → email verification →
complete); `passwordResetFlow()` drives the standalone §5.4 reset
(`needs_email_verification` → `needs_second_factor` → `needs_new_password` →
`done`). Both exchange the completion ticket and sign the user in.

```swift
let reset = atlas.passwordResetFlow()
try await reset.start(email: "ada@example.com")
try await reset.attemptVerification(code: "111222")
try await reset.setNewPassword("new-password")   // .done → signed in
```

## Sign in with Apple / Google (id_token)

Exchange a provider `id_token` for a session without the redirect flow
(`POST /v1/client/sign_ins/id_token`). The Apple ceremony has a small
`ASAuthorizationController` wrapper; the token exchange is provider-agnostic.

```swift
// Apple — mint a nonce, run the system sheet, exchange the identity token.
let nonce = try await atlas.mintNativeNonce(provider: "apple")
let apple = try await SignInWithApple().signIn(nonce: nonce)   // iOS 13+/macOS 10.15+
switch try await atlas.signInWithIdToken(provider: "apple", idToken: apple.identityToken, nonce: nonce) {
case .complete(let user):        print("signed in", user.id)   // session persisted
case .needsNextStep(let flow):   try await flow.attemptSecondFactor(code: "123456")
}

// Google One-Tap / GSI — post the credential id_token your Google SDK produced.
_ = try await atlas.signInWithIdToken(provider: "google", idToken: googleCredential, nonce: nonce)
```

A `complete` result returns the signed-in `AtlasUser`; a `needs_second_factor`
result hands back a seeded `SignInFlow` so the 2FA step uses the same driver.

## Organizations, sessions & the `/me` surface

Typed methods over the authenticated client surface (all present the stored
session the way a browser does):

```swift
// Organizations
let memberships = try await atlas.organizations()            // GET /me/organizations
try await atlas.setActiveOrganization(memberships.first?.organization.id)   // touch; rotated JWT persisted
let org = try await atlas.createOrganization(name: "Acme", slug: "acme")    // when the instance allows it

// Sessions / devices
let devices = try await atlas.sessions()                     // GET /v1/client/sessions ("Chrome on macOS", …)
try await atlas.revokeSession(id: someDevice.id)             // sign out one device
let n = try await atlas.revokeOtherSessions()                // sign out every OTHER device

// Email addresses
let added = try await atlas.addEmailAddress("new@example.com")
try await atlas.verifyEmailAddress(id: added.id, code: "123456")
try await atlas.setPrimaryEmailAddress(id: added.id)
try await atlas.removeEmailAddress(id: added.id)

// External accounts — start an OAuth link, hand the URL to ASWebAuthenticationSession
let link = try await atlas.connectExternalAccount(provider: "github", redirectURL: "myapp://cb")
try await atlas.disconnectExternalAccount(id: "ext_1")

// Password & profile
try await atlas.changePassword(current: "old", new: "new")   // account with a password
try await atlas.setPassword("first-password")                // guest / OAuth-only account
let me = try await atlas.updateProfile(firstName: "Ada", unsafeMetadata: ["theme": .string("dark")])
```

`unsafe_metadata` is the only metadata a client may write — `public_metadata` is
backend-only and never sent (§4.1).

## SwiftUI components

Prebuilt, themeable views (gated to iOS 15+/macOS 12+; the non-UI core still
builds on lower targets via `#if canImport(SwiftUI)`). `AtlasAuthSession` is the
observable the UI binds to — the signed-in user, a loading flag, the last error.
(It is distinct from the persisted `AtlasSession` token value the `TokenStore`
holds.)

```swift
@StateObject private var session = AtlasAuthSession(client: atlas)

var body: some View {
    Group {
        if session.isSignedIn {
            UserButton(session: session)       // avatar + name + sign-out menu
            UserProfile(session: session)      // identity + email list + sign-out
        } else {
            SignIn(session: session)           // drives the flow: identifier → factors → 2FA → done
        }
    }
    .task { await session.load() }
}
```

`SignIn` wraps the flow driver end to end; `AtlasAuthSession` exposes
`signIn(email:password:)`, `signOut()`, and `reload()` as `async` methods that
keep `@Published` state in step. The on-device rendering and the live Apple/Google
system sheets need a simulator/device to verify; the logic they drive is covered
by the headless unit tests.
