import Foundation

/// Where the SDK keeps the signed-in session between launches.
///
/// A protocol, not a concrete type, so the persistence policy is the app's to
/// choose — the Keychain in production, an in-memory store in tests, or a
/// customer's own vault. `AtlasClient` never assumes anything beyond these three
/// operations.
public protocol TokenStore: Sendable {
    /// Persist the session, replacing any existing one.
    func save(_ session: AtlasSession) throws
    /// The stored session, or nil when signed out.
    func load() throws -> AtlasSession?
    /// Remove the stored session (sign-out).
    func clear() throws
}

/// A process-lifetime store. The default for tests, and a sane fallback where
/// the Keychain is unavailable — but it does not survive a relaunch, so it is
/// never the right choice for a shipping app.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AtlasSession?

    public init(_ initial: AtlasSession? = nil) {
        self.session = initial
    }

    public func save(_ session: AtlasSession) throws {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    public func load() throws -> AtlasSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        session = nil
    }
}
