// The one place for the version. scripts/build-app.sh and scripts/release.sh read and write these lines.
public let SidekickVersion = "0.1.0"
public let SidekickBuild = 1
/// The release bundle id. Test builds override it in Info.plist; read the live one from Bundle.main.
public let SidekickBundleID = "com.jonnilundy.sidekick"
