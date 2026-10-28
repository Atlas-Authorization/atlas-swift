# AtlasVapor

Atlas session authentication for [Vapor](https://vapor.codes). A separate package so the Atlas client package stays dependency-free in apps.

```swift
// Package.swift
.package(url: "https://github.com/Atlas-Authorization/atlas-vapor.git", from: "0.1.0"),
// target dependency: .product(name: "AtlasVapor", package: "atlas-vapor")
```

```swift
import AtlasVapor
import Vapor

app.atlas.configure(.init(
    issuer: "https://auth.example.com",
    jwksURL: "https://auth.example.com/.well-known/jwks.json",
    authorizedParties: ["https://app.example.com"]
))

let protected = app.grouped(AtlasAuthMiddleware())
protected.get("me") { req in try req.requireAtlasSession().userId }

protected.grouped(AtlasRequireMiddleware(.permission("org:billing:read")))
    .get("billing") { _ in "ok" }
```

- The token is `Authorization: Bearer <jwt>`, else the `__session` cookie. It is verified locally against the cached key set (RS256 and ES256): issuer, expiry and not-before with 5 seconds of clock skew, the `azp` allowlist, and the session-token guard (an OAuth access token or ID token signed with the same key is refused). No call to Atlas per request; an unknown `kid` refetches the keys at most once a minute.
- A request without a verified session is a 401 with `WWW-Authenticate: Bearer`; `AtlasRequireMiddleware` answers 403. `AtlasAuthMiddleware(required: false)` lets anonymous requests through with `req.atlasSession == nil`.
- Fail closed: an unreachable key set with no earlier keys, a malformed token, or an unconfigured app (a 500) never lets a request through unchecked.
