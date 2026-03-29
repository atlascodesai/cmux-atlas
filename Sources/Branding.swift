/// Centralized identity constants for the cmux Atlas fork.
/// Keep fork-specific app names, bundle IDs, and socket prefixes here so the
/// rebuilt fork can coexist with upstream without scattering raw literals.
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

    static let releaseFeedURL = "https://github.com/atlas-fork/cmux-atlas/releases/latest/download/appcast.xml"
}
