import Foundation

/// Builds the command run on the remote host.
///
/// The directory is a constant and the file name comes from the clock plus
/// random bytes. There is no shell injection surface and no quoting to
/// validate, provided the only file name ever passed in is one produced by
/// `newFilename()` — which always has the form
/// `clipboard-<digits>-<4 lowercase hex characters>.png`. This type is
/// internal (not `public`) precisely so that guarantee cannot be broken by a
/// caller outside this module passing an arbitrary string.
enum RemoteCommand {
    static let remoteDirectory = "/tmp"

    /// Four lowercase hex characters. Prevents collisions when two machines send
    /// to the same host within the same second.
    static func randomSuffix() -> String {
        String(format: "%04x", UInt16.random(in: UInt16.min...UInt16.max))
    }

    static func filename(epoch: Int, suffix: String) -> String {
        "clipboard-\(epoch)-\(suffix).png"
    }

    static func newFilename() -> String {
        filename(epoch: Int(Date().timeIntervalSince1970), suffix: randomSuffix())
    }

    static func remotePath(filename: String) -> String {
        "\(remoteDirectory)/\(filename)"
    }

    /// `umask 077` gives the file mode 0600, so screenshots are not readable by
    /// other users on a shared host. `set -C` (noclobber) makes the redirect
    /// fail instead of following a file or symlink an attacker pre-created at
    /// the guessable path — `/tmp` is world-writable, so a plain `>` would
    /// silently write the screenshot through such a link.
    static func uploadCommand(filename: String) -> String {
        "/bin/sh -c 'umask 077; set -C; cat > \"$1\"' sh \(shellQuoted(remotePath(filename: filename)))"
    }

    /// Wraps `value` in single quotes for use as one word in a POSIX shell
    /// command, escaping any embedded single quote so it cannot end the
    /// quoted word early. `filename` is always module-generated today (see
    /// the type comment above), so this only guards a future caller.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
