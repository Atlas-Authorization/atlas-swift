# Changelog

All notable changes to the Atlas Swift SDK. The package is versioned by git tag.

## 0.8.0 — 2026-10-24

### Added

- **Policy acceptance (terms of service, privacy, any policy).** Core API: `AtlasClient.policies(locale:)` (`GET /v1/client/policies`: sanitized `contentHTML` + `contentSHA256`), `policies(resolving:locale:)` (fills a held sign-in's pending list with content), `myPolicies()` and `acceptMyPolicies(_:)` (`/v1/client/me/policies[/accept]`, in-app re-acceptance), `buildPolicyAcceptances(_:evidence:locale:)` and the `PolicyAcceptanceState` value type (ticks, scroll-to-end and view-time evidence, `canSubmit`, `pendingScroll`, `build()`). `SignUpFlow.start` and `PasskeySignUpFlow.start` take `policyAcceptances:`; a 422 `POLICY_ACCEPTANCE_REQUIRED` is `AtlasError.isPolicyAcceptanceRequired` with the per-policy reasons in `AtlasError.policyProblems` (`AtlasErrorItem.meta`).
- **Held attempts.** The new sign-in status `needs_policy_acceptance` is `SignInStep.acceptPolicies(pending:)` (and `ResetStep.acceptPolicies`); `SignInFlow`, `SignUpFlow`, `PasswordResetFlow` and `PasskeySignUpFlow` gain `acceptPolicies(_:pollSecret:)` (`POST /v1/client/sign_ins/:id/accept_policies` with the one-time `policy_acceptance_token`, else the poll secret). `SignInAttempt` decodes `pendingPolicies` and `policyAcceptanceToken`. `signInWithPasskey` throws `AtlasPolicyAcceptanceNeeded` (carrying the flow to continue) when the server holds a verified passkey sign-in for a policy.
- **Redirect callbacks.** `AtlasRedirectResult(url:)` and `AtlasClient.completeRedirect(_:)` read `__atlas_attempt`, `__atlas_ticket`, `__atlas_status` and the one-time `__atlas_policy_token` from an `ASWebAuthenticationSession` callback and either sign in or return a flow that keeps the token.
- **SwiftUI.** `PolicyAcceptanceModel`, `AtlasPolicyConsent` (combined or per-policy checkbox with an in-app document viewer, clickwrap text, the unskippable scroll sheet: no close, no swipe or Esc dismissal, Accept enabled once the end is visible or the text fits, Decline cancels) and `AtlasPolicyGate` (a banner for in-app re-acceptance). The sanitized HTML is drawn as attributed text, with no web view, so it works on tvOS and watchOS. The prebuilt `SignIn` shows the "accept to continue" step (and can `resume` a flow from a redirect); the new prebuilt `SignUp` view creates the account with the instance's policies, the emailed code and the held step. tvOS: per-policy Read buttons and focusable text for the remote; watchOS: the crown scrolls the document and the buttons sit at its end.

### Changed

- `SignInStep` gains `acceptPolicies(pending:)`, `SignInStatus` gains `needsPolicyAcceptance`, `AtlasErrorItem` gains an optional `meta`, and `AtlasErrorCode` gains `policyAcceptanceRequired`: an exhaustive `switch` over these needs the new case.

## 0.7.0 — 2026-10-24

### Added

- **Upstream logout on sign-out.** `signOut(returnURL:followLogoutURL:)` now returns an `AtlasSignOutResult` with the upstream OIDC provider's `upstreamLogoutURL` and the SAML `samlLogoutURL` (https only) that Atlas hands back when the session came from such a provider, and opens it through `AtlasClient.logoutURLOpener` — by default `AtlasClient.openInSystemBrowser(_:)` (`UIApplication.open` on iOS / visionOS, `NSWorkspace.open` on macOS; none on tvOS and watchOS). `returnURL` must be on an allowed origin.
- **Device sign-in approval.** `lookupDeviceAuthorization(userCode:)`, `approveDeviceAuthorization(_:)`, `denyDeviceAuthorization(_:)` (`PendingDeviceAuthorization`) let a signed-in iPhone approve the code an Apple TV, Watch or CLI shows; `AtlasClient.formatUserCode(_:)`, `AtlasClient.userCodeFromURL(_:)` (for a scanned QR code). A refusal needing a fresh re-authentication is an `AtlasError` with code `STEP_UP_REQUIRED`.
- **Passkey PRF pass-through.** `registerPasskey`, `signInWithPasskey` and `createSignUpPasskey` take `prf: AtlasPasskeyPRF` (salts as `Data`, or `AtlasPasskeyPRF(salt:)` as UTF-8; per-credential salts on sign-in) and `onPRFResult`. On iOS 18 / macOS 15 / visionOS 2 the salts go to `ASAuthorizationPublicKeyCredentialPRF…Input` and the outputs (`AtlasPasskeyPRFResult`) reach only the callback — nothing PRF-related is sent to Atlas. Earlier OS versions (and tvOS) run the ceremony without PRF.

### Changed

- `signOut()` returns `AtlasSignOutResult` (`@discardableResult`; existing calls compile unchanged).

## 0.6.0 — 2026-10-23

### Added

- **Sign in on another device (RFC 8628).** `AtlasClient.startDeviceSignIn(clientId:scopes:)`
  (`POST /oauth2/device_authorization`) returns an `AtlasDeviceAuthorization`
  (`userCode`, `verificationURI`, `verificationURIComplete`, `expiresIn`,
  `interval`, `expiresAt`, `secondsRemaining(at:)`, `qrCodeURL`,
  `displayVerificationURI`). `waitForDeviceSignIn(_:deviceName:)` polls
  `/oauth2/token` (authorization_pending, slow_down +5 s, exponential backoff on
  network failure capped at 60 s, local expiry), exchanges the approved access
  token for an Atlas session, persists it and returns the user. Typed outcomes:
  `AtlasError.isDeviceCodeExpired`, `isDeviceSignInDenied`; the OAuth error code
  and description map onto `AtlasError`. `AtlasClient(oauthClientId:)` configures
  the first-party client; `AtlasClient.platformDeviceName` names the device.
- **`AtlasDeviceSignInView`.** The device flow as SwiftUI: large code, QR code,
  verification address, countdown, automatic renewal of expired codes, retry
  after denial; native layouts for tvOS, watchOS and the rest; dashboard design.
- **`AtlasQRCode` / `AtlasQRCodeView`.** QR codes drawn as vector modules: Core
  Image's `CIQRCodeGenerator` where available, a pure-Swift ISO/IEC 18004
  encoder (byte mode, versions 1–40, all four error-correction levels, penalty
  mask selection) on watchOS.
- **Native tvOS and watchOS `SignIn`.** tvOS: sign in on another device beside
  sign in on this TV (passkey, Sign in with Apple, the email form), each a focus
  section, with focus lift on design-styled buttons and fields and the design at
  TV scale. watchOS: sign in on another device, then Sign in with Apple, the email
  form on request. TOTP enrolment shows a QR code on both.
- **Sign in with Apple on tvOS and watchOS.** `SignInWithApple` now builds for
  tvOS 13+ and watchOS 6+ (the watch presents the Apple ID sheet itself).

- **Device id on account-creating starts.** Email sign-up and the social / SSO / id_token sign-in starts carry a stable, random `device_id` (`DeviceId`, kept in `UserDefaults`) for the instance's accounts-per-device abuse limit, like the JS SDK. `AtlasClient.deviceIdProvider` overrides it (return nil to send none).
- **Passkey sign-in captcha.** `signInWithPasskey(captchaToken:)` forwards the sign-in captcha token; an instance that challenges sign-ins answers `CAPTCHA_REQUIRED` without one (`AtlasError.isCaptchaRequired`, `AtlasErrorCode.captchaRequired` / `.captchaFailed` / `.challengeUnavailable`).
- **Passkey-only sign-up.** `PasskeySignUpFlow` (`POST /v1/client/sign_ups/passkey`, email verification when required, `awaitingPasskey`) and `AtlasClient.createSignUpPasskey(_:name:)` (begin → system ceremony → finish). The account exists only once the passkey is registered.
- **SMS MFA enrolment mid-sign-in.** `SignInFlow.prepareSmsMfaEnrollment(phone:)` and `attemptMfaEnrollment(factorId:code:)`. `MfaEnrollment` carries `strategy`, `phone`, and for TOTP the QR image `qrCode` (a `data:image/...` URL) with `qrImageData`.
- **Organization audit log.** `organizationAuditLog(organizationId:limit:startingAfter:action:)` (`GET /v1/client/organizations/:id/audit_logs`, organization admins).

### Changed

- The prebuilt SwiftUI types are available on **tvOS 17+ and watchOS 10+** (were
  iOS/macOS/visionOS only); they use the platform's own `Menu`, materials and
  field styles there. iOS, macOS and visionOS layouts are unchanged. The core
  client's deployment targets are unchanged.
- `UserButton` on watchOS opens the system confirmation sheet with "Sign out"
  (watchOS has no menus).

## 0.5.0

### Added

- **Dashboard design in `SignIn`.** The view reads `GET /v1/appearance` (also
  public as `client.appearance(organization:)`) and, when the app owner saved a
  design, renders it natively: light/dark palettes (system or forced
  `colorScheme`), card + control radii (999 = capsule), border width, card style
  / shadow / width, density spacing, button style (solid / outline / soft /
  gradient), input style (outline / filled / underline), social-button layout
  (list / grid / icons), font size / weights / type scale / uppercase buttons,
  and the light/dark logo. Catalog fonts are used when the app bundles them,
  else the system font of the same design (default / serif / monospaced). With
  `design: null` the view is unchanged from 0.4.x.
- **`appearance` overrides.** `SignIn(session:appearance:)` takes an
  `AtlasAppearance` that overrides any design token in code (code wins over the
  dashboard; `applyDashboardDesign = false` ignores the dashboard).
- **Social buttons.** `onSocialSignIn` shows the enabled providers in the
  design's layout; `AtlasSocialButtons` is public for custom screens.
- **Design model.** `AtlasDesign` (tolerant decoder of `design.resolved`:
  unknown keys ignored, missing/invalid values default), `AtlasAppearanceInfo`,
  and the token enums.
- **Typed error codes.** `AtlasError.knownCode` → `AtlasErrorCode`;
  `isEmailDeliveryNotConfigured` for the new 422
  `EMAIL_DELIVERY_NOT_CONFIGURED`. `SignIn` shows the server's message and stops
  offering "Email me a code" after that refusal.

### Fixed

- A request path carrying a query string is no longer percent-escaped into the
  path.

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
