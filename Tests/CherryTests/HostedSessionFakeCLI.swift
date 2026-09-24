import Foundation
@testable import Cherry

/// A stand-in for the Rust `cherry` CLI that parses arguments the way its clap
/// definition does: an option takes the next argument only when that argument
/// does not start with "-", or an inline `--option=value`. Swift callers are
/// checked against the CLI contract instead of a script that accepts anything.
///
/// Behaviour switches are files in `directory`: `host-id` (default host-a),
/// `sessions` (comma-separated SessionInfo JSON), `list-fails` (printed to
/// stderr by a `list` that then exits 255, as ssh does when it cannot
/// connect), `new-rejects` and `new-transport-failures` (a count).
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
            --host=*|--socket=*) ;;
            --expected-host-id=*) expected=${1#*=} ;;
            --host|--socket) takes_value "$1" "$2"; shift ;;
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
          list)
            for argument in "$@"; do
              [ "$argument" = --json ] || fail "unexpected argument '$argument' found"
            done
            if [ -f "$dir/list-fails" ]; then cat "$dir/list-fails" >&2; exit 255; fi
            printf '{"host_id":"%s","sessions":[%s]}\n' "$host_id" "$(cat "$dir/sessions" 2>/dev/null)"
            ;;
          new)
            name=Terminal
            cwd=
            request=
            while [ $# -gt 0 ]; do
              case "$1" in
                --name=*) name=${1#--name=} ;;
                --cwd=*) cwd=${1#--cwd=} ;;
                --request-id=*) request=${1#--request-id=} ;;
                --name|--cwd|--request-id)
                  takes_value "$1" "$2"
                  case "$1" in
                    --name) name=$2 ;;
                    --cwd) cwd=$2 ;;
                    *) request=$2 ;;
                  esac
                  shift ;;
                --json) ;;
                --) shift; break ;;
                *) fail "unexpected argument '$1' found" ;;
              esac
              shift
            done
            [ -n "$cwd" ] || fail "the following required arguments were not provided: --cwd <CWD>"
            printf '%s\n' "$name" > "$dir/created-name"
            printf '%s\n' "$cwd" > "$dir/created-cwd"
            printf '%s\n' "$request" >> "$dir/request-ids"
            if [ -f "$dir/new-rejects" ]; then
              printf 'cherry: host rejected request (request_failed): working directory does not exist\n' >&2
              exit 1
            fi
            if [ -f "$dir/new-transport-failures" ]; then
              read -r remaining < "$dir/new-transport-failures"
              if [ "$remaining" -gt 0 ]; then
                printf '%s\n' $((remaining - 1)) > "$dir/new-transport-failures"
                printf 'cherry: connection to the host was lost\n' >&2
                exit 1
              fi
            fi
            printf '{"id":"session-%s","name":"Created","cwd":"/remote","command":["/bin/sh"],"cols":80,"rows":24,"state":"running","pid":42,"exit_code":null,"attached":false,"exit_signal":null}\n' "$request"
            ;;
          attach)
            [ $# -gt 0 ] || fail "the following required arguments were not provided: <ID>"
            id=$1
            shift
            while [ $# -gt 0 ]; do
              case "$1" in
                --takeover) ;;
                --detach-key=*|--status-file=*) ;;
                --detach-key|--status-file) takes_value "$1" "$2"; shift ;;
                *) fail "unexpected argument '$1' found" ;;
              esac
              shift
            done
            printf 'Attached %s\r\n' "$id"
            exec /bin/sleep 30
            ;;
          kill|remove)
            [ $# -eq 1 ] || fail "expected exactly one session id"
            ;;
          *) fail "unrecognized subcommand '$command'" ;;
        esac
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func client(timeout: TimeInterval = 5, loginEnvironment: [String: String] = [:]) -> HostedSessionClient {
        HostedSessionClient(
            executableURL: executable, timeout: timeout,
            loginEnvironment: { _ in .init(environment: loginEnvironment) }
        )
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
