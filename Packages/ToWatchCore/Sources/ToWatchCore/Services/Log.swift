import os

/// Where the app writes what it did and what went wrong, for Console.app (filter by subsystem
/// `com.mehdi.towatchdb`). A sync or refresh that failed in the field left nothing behind to look at.
/// Never log tokens, keys, or URLs that carry them; title names are marked private.
public enum Log {
    static let subsystem = "com.mehdi.towatchdb"

    /// Saves, imports, and the library store.
    public static let library = Logger(subsystem: subsystem, category: "library")
    /// Refreshing titles from TMDB and IMDb ratings from OMDb.
    public static let refresh = Logger(subsystem: subsystem, category: "refresh")
    /// Dropbox sync.
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    /// The Keychain and the sealed secrets file.
    public static let secrets = Logger(subsystem: subsystem, category: "secrets")
}
