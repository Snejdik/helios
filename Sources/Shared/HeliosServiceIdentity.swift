/// The service identity is shared by the app and daemon targets.
/// Keep these names aligned with Resources/com.snejda.Helios.Daemon.plist.
enum HeliosServiceIdentity {
    static let appIdentifier = "com.snejda.Helios"
    static let machServiceName = "com.snejda.Helios.Daemon"
    static let launchDaemonPlistName = "com.snejda.Helios.Daemon.plist"
    static let protocolVersion = 3
}
