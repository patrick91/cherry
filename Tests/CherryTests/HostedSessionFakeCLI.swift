import Foundation
@testable import Cherry

/// A stand-in for the Rust `cherry` CLI's `attach` (the attach adapter) that
/// parses arguments the way its clap definition does: an option takes the
/// next argument only when that argument does not start with "-", or an
/// inline `--option=value`. Swift callers are checked against the CLI
/// contract instead of a script that accepts anything. Control actions use
/// `cherry control`; see `FakeControlHelper`.
///
/// Behaviour switches (files in `directory`): `host-id` (default host-a),
/// which `--expected-host-id` must match; `attach-status`, whose contents an
/// attach writes to its `--status-file` (atomically, as the CLI does) once
/// it started, as the adapter's live state (`attachedStatus`). Without it,
/// an attach reports nothing, like one still attaching; tests then write
/// its status file themselves (`writeStatus`).
struct HostedSessionFakeCLI {
    let directory: URL
    let executable: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-fake-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("cherry")
        let quotedDirectory = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = #"""
        #!/bin/sh
        dir=\#(quotedDirectory)
        # Tests wait for `calls` to show a long-running attach, then read the
        # other files: replace those whole first and append the call last.
        record() { cat > "$dir/.$1.$$" && mv -f "$dir/.$1.$$" "$dir/$1"; }
        printf '%s\n' "$@" | record last-arguments
        printf '%s' "${SSH_AUTH_SOCK-}" | record ssh-auth-sock
        printf '%s' "${TERM-}" | record term
        printf '%s\n' "$*" >> "$dir/calls"
        fail() { printf 'error: %s\n' "$1" >&2; exit 2; }
        takes_value() {
          case "$2" in
            -*|'') fail "a value is required for '$1' but none was supplied" ;;
          esac
        }
        host_id=host-a
        [ -f "$dir/host-id" ] && read -r host_id < "$dir/host-id"
        expected=
        while [ $# -gt 0 ]; do
          case "$1" in
            --host=*|--socket=*|--ssh-control-path=*) ;;
            --expected-host-id=*) expected=${1#*=} ;;
            --host|--socket|--ssh-control-path) takes_value "$1" "$2"; shift ;;
            --expected-host-id) takes_value "$1" "$2"; expected=$2; shift ;;
            -*) fail "unexpected argument '$1' found" ;;
            *) break ;;
          esac
          shift
        done
        [ $# -gt 0 ] || fail "a subcommand is required"
        command=$1
        shift
        if [ -n "$expected" ] && [ "$expected" != "$host_id" ]; then
          printf 'cherry: host identity changed (expected %s, received %s); reconnect to the intended host before using this session\n' "$expected" "$host_id" >&2
          exit 1
        fi
        case "$command" in
          attach)
            [ $# -gt 0 ] || fail "the following required arguments were not provided: <ID>"
            id=$1
            shift
            status_file=
            while [ $# -gt 0 ]; do
              case "$1" in
                --takeover) ;;
                --detach-key=*) ;;
                --status-file=*) status_file=${1#*=} ;;
                --detach-key) takes_value "$1" "$2"; shift ;;
                --status-file) takes_value "$1" "$2"; status_file=$2; shift ;;
                *) fail "unexpected argument '$1' found" ;;
              esac
              shift
            done
            printf 'Attached %s\r\n' "$id"
            if [ -n "$status_file" ] && [ -f "$dir/attach-status" ]; then
              cat "$dir/attach-status" > "$status_file.$$" && mv -f "$status_file.$$" "$status_file"
            fi
            exec /bin/sleep 30
            ;;
          *) fail "unrecognized subcommand '$command'" ;;
        esac
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func client(loginEnvironment: [String: String] = [:]) -> HostedSessionClient {
        HostedSessionClient(executableURL: executable, loginEnvironment: { _ in .init(environment: loginEnvironment) })
    }

    func write(_ name: String, _ contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func lines(_ name: String) -> [String] {
        (read(name) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
    }

    var calls: [String] { lines("calls") }

    /// A running adapter's live state, as `cherry attach` writes it.
    static func attachedStatus(viewport: Bool = false, reconnecting: Bool = false) -> String {
        #"{"outcome":"attached","viewport":\#(viewport),"reconnecting":\#(reconnecting),"exit_code":null,"signal":null,"message":null}"#
    }

    /// Makes every attach from now on report itself attached with this
    /// state (nil: report nothing).
    func reportAttach(viewport: Bool = false, reconnecting: Bool = false) throws {
        try write("attach-status", Self.attachedStatus(viewport: viewport, reconnecting: reconnecting))
    }

    /// The `--status-file` of an attach call (a line of `calls`).
    static func statusFile(of call: String) -> URL? {
        let parts = call.split(separator: " ").map(String.init)
        guard let index = parts.firstIndex(of: "--status-file"), parts.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: parts[index + 1])
    }

    /// Replaces a status file atomically, as the CLI does (the app follows
    /// renames in its directory).
    static func writeStatus(_ json: String, to file: URL) throws {
        try Data(json.utf8).write(to: file, options: .atomic)
    }
    var lastArguments: [String] { lines("last-arguments") }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
func makeIsolatedHostedSessionHostStore() throws -> (store: HostedSessionHostStore, defaults: UserDefaults, suite: String) {
    let suite = "CherryTests.HostedSessions.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw HostedSessionError.message("Could not create an isolated defaults suite")
    }
    return (HostedSessionHostStore(defaults: defaults), defaults, suite)
}
