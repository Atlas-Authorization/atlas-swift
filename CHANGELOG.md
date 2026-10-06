# Changelog

All notable changes to the Atlas Swift SDK. The package is versioned by git tag.

## 0.4.0

The SDK is now feature-complete — the full client-facing auth surface a native
iOS/macOS app needs, mirroring `@atlas/js`.

### Added

- **Multi-step flow driver.** `SignInFlow`, `SignUpFlow`, and `PasswordResetFlow`
  actors over `/v1/client/sign_ins`, `/v1/client/sign_ups`, and
  `/v1/client/password_resets`. They expose a `status` + `SignInStep`
  (`nextStep`/`advance`-style) API — password, email/phone code, second factor
  (TOTP / SMS / backup code), mid-sign-in MFA enrollment, and password reset. A
  non-complete status is surfaced so the caller drives the next step; a `complete`
  exchanges the ticket and persists the session. The step mapping
  (`signInStep(_:)`) is pure and exhaustive (unknown status → `.unknown`). The
  existing `signIn`/`signInWithPasskey` happy paths are unchanged.
- **Sign in with Apple / Google id_token exchange.**
  `signInWithIdToken(provider:idToken:nonce:)` and `mintNativeNonce(provider:)`
  over `POST /v1/client/sign_ins/id_token`; a `SignInWithApple`
  `ASAuthorizationController` helper that yields the Apple identity token.
- **Organizations, session listing & `/me` mutations.** `organizations()`,
  `createOrganization`, `setActiveOrganization`; `sessions()`, `revokeSession`,
  `revokeOtherSessions`; email add/verify/primary/remove; external-account
  connect/disconnect; `changePassword`/`setPassword`; `updateProfile` (profile +
  `unsafe_metadata`).
- **Prebuilt SwiftUI components.** `SignIn` (drives the flow driver end to end),
  `UserButton`, `UserProfile`, and an observable `AtlasAuthSession` (signed-in
  user, loading, error). Gated to iOS 15+/macOS 12+; the non-UI core still builds
  on lower targets via `#if canImport(SwiftUI)`.

### Internal

- The single request path now serialises arbitrary JSON bodies (`sendJSON`), with
  an authenticated `/me` helper (`authedSend`); the string-dict `send` delegates
  to it, so every request still sets the publishable key / cookie / content type
  in one place.

## 0.2.0

- Native session (first-party OAuth → session exchange, cookie-free):
  `exchangeForSession`, `refreshNativeSession`, `NativeSessionManager`.

## 0.1.0

- Initial client: password sign-in, OAuth authorize URL, ticket exchange,
  `currentUser`, `refresh`, `signOut`, Keychain token store, native passkeys.
