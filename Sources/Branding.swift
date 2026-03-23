/// Centralised branding constants for the cmux Atlas fork.
/// Every hardcoded bundle ID, socket path prefix, and directory name
/// should reference these instead of raw string literals.
enum Branding {
    static let bundleIdentifierBase = "com.atlascodes.cmux-atlas"
    static let releaseBundleIdentifier = "com.atlascodes.cmux-atlas"
    static let debugBundleIdentifier = "com.atlascodes.cmux-atlas.debug"
    static let stagingBundleIdentifier = "com.atlascodes.cmux-atlas.staging"
    static let nightlyBundleIdentifier = "com.atlascodes.cmux-atlas.nightly"

    static let appSupportDirectoryName = "cmux-atlas"
    static let socketPrefix = "cmux-atlas"

    static let legacyStableSocketPath = "/tmp/cmux-atlas.sock"
    static let debugSocketPath = "/tmp/cmux-atlas-debug.sock"
    static let stagingSocketPath = "/tmp/cmux-atlas-staging.sock"
    static let nightlySocketPath = "/tmp/cmux-atlas-nightly.sock"
    static let lastSocketPathFile = "/tmp/cmux-atlas-last-socket-path"
}
