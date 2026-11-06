import Foundation

// Pairing Cherry for iOS with one of the user's other Macs (a device;
// docs/specs/mobile-pairing.md › Another Mac). This Mac shows the code and
// runs the listener; what the code says of that Mac, and its
// ~/.ssh/authorized_keys, are read and written there over its SSH
// connection (`RemoteDeviceShell`), with the line rules of this Mac's file
// (`AuthorizedPhoneKeys`). The key's line runs Cherry's gateway through the
// link beside this Cherry's installs there
// (`RemoteHostInstall.gatewayLinkRelativePath`), which pairing points at the
// device's install when it has none that runs the gateway.

/// What `RemotePhonePairing.inspectScript` reports of another Mac.
struct RemotePhonePairingReport: Equatable, Sendable {
    enum Keys: Equatable, Sendable {
        case missing
        /// A link to `destination`, which Cherry never writes through.
        case link(destination: String)
        /// Its text (nil when it isn't UTF-8), mode and SHA-256.
        case file(text: String?, mode: String, hash: String)
    }

    enum Gateway: Equatable, Sendable {
        /// The link runs the gateway (pointed at the install now, or kept).
        case ready
        /// No build there runs it: the install predates it, or there is none.
        case missing
        /// Not looked at.
        case unknown
    }

    var home: String?
    var user: String?
    /// The address and port its SSH connection reached (`SSH_CONNECTION`).
    var reachedAddress: String?
    var reachedPort: Int?
    var localHostName: String?
    /// Its interfaces' IPv4 addresses (up ones, loopback excluded).
    var addresses: [String] = []
    /// Its host keys' lines (Ed25519, ECDSA).
    var hostKeys: [String] = []
    var gateway: Gateway = .unknown
    var keys: Keys?

    init(fields: [(key: String, value: String)]) {
        var keysKind: String?
        var keysText: String?
        var keysMode = "600"
        var keysHash: String?
        var linkDestination = ""
        for (key, value) in fields {
            switch key {
            case "home": home = value.nilIfEmpty
            case "user": user = value.nilIfEmpty
            case "reached":
                let parts = value.split(separator: " ").map(String.init)
                if parts.count == 2 {
                    reachedAddress = parts[0]
                    reachedPort = Int(parts[1])
                }
            case "localhost": localHostName = value.nilIfEmpty
            case "address": addresses.append(value)
            case "hostkey": hostKeys.append(value)
            case "gateway": gateway = value == "ready" ? .ready : .missing
            case "keys": keysKind = value
            case "keys_link": linkDestination = value
            case "keys_mode": if !value.isEmpty, value.count <= 4, value.allSatisfy({ ("0"..."7").contains($0) }) { keysMode = value }
            case "keys_hash": keysHash = value
            case "keys_text": keysText = Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) }
            default: break
            }
        }
        switch keysKind {
        case "missing": keys = .missing
        case "link": keys = .link(destination: linkDestination)
        case "file": keys = keysHash.map { .file(text: keysText, mode: keysMode, hash: $0) }
        default: keys = nil
        }
    }

    /// Where the phone may reach it over SSH, best first: Tailscale
    /// addresses (100.64.0.0/10), the address this Mac reached it at, its
    /// Bonjour name, then other addresses (no loopback or link-local).
    var hosts: [String] {
        func isTailscale(_ address: String) -> Bool {
            let octets = address.split(separator: ".").compactMap { Int($0) }
            return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
        }
        func isUsable(_ address: String) -> Bool {
            !address.isEmpty && !address.hasPrefix("127.") && !address.hasPrefix("169.254.")
                && address != "::1" && !address.lowercased().hasPrefix("fe80")
        }
        let addresses = addresses.filter(isUsable)
        let reached = reachedAddress.map { [$0] }?.filter(isUsable) ?? []
        let bonjour = localHostName.map { ["\($0).local"] } ?? []
        return MobilePairingMac.unique(
            addresses.filter(isTailscale) + reached + bonjour + addresses.filter { !isTailscale($0) }
        )
    }

    /// The fingerprints of its host keys a phone can use.
    var hostKeyFingerprints: [String] {
        MobilePairingMac.unique(hostKeys.compactMap { SSHPublicKeyLine($0)?.fingerprint })
    }
}

enum RemotePhonePairing {
    /// The script that reads another Mac: its home and user, and with
    /// `readsMac` what a code says of it (addresses, host keys, the port
    /// its SSH connection reached); with `readiesGateway` it points the
    /// iPhone link at the build directory `installDirectory` (the device's
    /// install, when its `cherry` runs the gateway), else keeps a link that
    /// runs it, and says whether one does; then its authorized_keys (a link,
    /// missing, or its text in base64 with its mode and SHA-256).
    static func inspectScript(
        installDirectory: String?, readsMac: Bool, readiesGateway: Bool, hostKeyDirectory: String = "/etc/ssh"
    ) -> String {
        var lines = [
            "printf '%s\\n' '\(RemoteDeviceProbe.beginMarker)'",
            "umask 077",
            "printf 'home=%s\\n' \"$HOME\"",
            "printf 'user=%s\\n' \"$(id -un 2>/dev/null)\"",
        ]
        if readsMac {
            lines += [
                "set -- $SSH_CONNECTION",
                "[ -n \"$4\" ] && printf 'reached=%s %s\\n' \"$3\" \"$4\"",
                "printf 'localhost=%s\\n' \"$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)\"",
                "/sbin/ifconfig -u 2>/dev/null | /usr/bin/awk '$1 == \"inet\" && $2 != \"127.0.0.1\" { print \"address=\" $2 }'",
            ]
            lines += MobilePairingMac.hostKeyFiles.map { file in
                let path = RemoteDeviceProbe.singleQuoted("\(hostKeyDirectory)/\(file)")
                return "[ -r \(path) ] && printf 'hostkey=%s\\n' \"$(/usr/bin/head -n 1 \(path))\""
            }
        }
        if readiesGateway {
            lines += [
                // The gateway refuses to run without the phone's command,
                // saying what it is; an older cherry has no such command.
                "runs_gateway() {",
                "  [ -x \"$1\" ] || return 1",
                "  out=$(/usr/bin/env -u SSH_ORIGINAL_COMMAND \"$1\" host mobile-gateway </dev/null 2>&1)",
                "  [ $? = 1 ] || return 1",
                "  case \"$out\" in *\"reaches only Cherry's sessions\"*) return 0 ;; esac",
                "  return 1",
                "}",
                "root=\"$HOME\"/" + RemoteDeviceProbe.singleQuoted(RemoteHostInstall.rootRelativePath),
                "install=" + RemoteDeviceProbe.singleQuoted(installDirectory ?? ""),
                "if [ -n \"$install\" ] && runs_gateway \"$root/$install/cherry\"; then",
            ]
            lines += RemoteHostInstall.gatewayLinkLines(nameVariable: "install").map { "  " + $0 }
            lines += [
                "fi",
                "if runs_gateway \"$HOME\"/" + RemoteDeviceProbe.singleQuoted(RemoteHostInstall.gatewayLinkRelativePath) + "; then echo gateway=ready; else echo gateway=missing; fi",
            ]
        }
        lines += [
            "f=\"$HOME/.ssh/authorized_keys\"",
            "if [ -L \"$f\" ]; then",
            "  echo keys=link",
            "  printf 'keys_link=%s\\n' \"$(readlink \"$f\")\"",
            "elif [ -e \"$f\" ]; then",
            "  echo keys=file",
            "  printf 'keys_mode=%s\\n' \"$(/usr/bin/stat -f %Lp \"$f\" 2>/dev/null)\"",
            "  printf 'keys_hash=%s\\n' \"$(\(RemoteHostInstaller.Tool.shasum) -a 256 \"$f\" | \(RemoteHostInstaller.Tool.awk) '{ print $1 }')\"",
            "  printf 'keys_text=%s\\n' \"$(/usr/bin/base64 < \"$f\" | tr -d '\\n')\"",
            "else",
            "  echo keys=missing",
            "fi",
            "printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The script that replaces another Mac's authorized_keys with `text`,
    /// only while the file is what the inspection read (`expectedHash`, or
    /// `missing`) and not a link: written to a file beside it with `mode`,
    /// then renamed over it (a `~/.ssh` it makes is 0700). It reports
    /// `written=ok`, `changed`, `link` or `failed`.
    static func writeScript(text: String, mode: String, expectedHash: String) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        return [
            "printf '%s\\n' '\(RemoteDeviceProbe.beginMarker)'",
            "umask 077",
            "f=\"$HOME/.ssh/authorized_keys\"",
            "if [ -L \"$f\" ]; then",
            "  echo written=link",
            "else",
            "  if [ -e \"$f\" ]; then found=$(\(RemoteHostInstaller.Tool.shasum) -a 256 \"$f\" | \(RemoteHostInstaller.Tool.awk) '{ print $1 }'); else found=missing; fi",
            "  if [ \"$found\" != \(RemoteDeviceProbe.singleQuoted(expectedHash)) ]; then",
            "    echo written=changed",
            "  else",
            "    [ -d \"$HOME/.ssh\" ] || mkdir -m 700 \"$HOME/.ssh\"",
            "    tmp=\"$HOME/.ssh/.authorized_keys.cherry-$$\"",
            "    if printf '%s' '\(encoded)' | /usr/bin/base64 -D > \"$tmp\" && chmod \(mode) \"$tmp\" && \(RemoteHostInstaller.Tool.perl) -e 'rename($ARGV[0], $ARGV[1]) or exit 1' \"$tmp\" \"$f\"; then",
            "      echo written=ok",
            "    else",
            "      rm -f \"$tmp\"",
            "      echo written=failed",
            "    fi",
            "  fi",
            "fi",
            "printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'",
        ].joined(separator: "\n") + "\n"
    }

    /// Pairing with `device`: its code is shown here, its key goes there.
    static func target(for device: RemoteDevice, keys: RemotePhoneKeys) -> MobilePairingTarget {
        MobilePairingTarget(
            displayName: device.name,
            isThisMac: false,
            describe: { await keys.describe(name: device.name) },
            addKey: { key, name in try await keys.add(key, name: name) }
        )
    }
}

/// The phones paired with another Mac: the lines Cherry wrote in its
/// `~/.ssh/authorized_keys`, read and changed over its SSH connection.
struct RemotePhoneKeys: Sendable {
    enum Failure: PhoneKeyFailure, Equatable {
        /// The script did not run (ssh failed): what ssh said.
        case unreachable(machine: String, detail: String)
        case linked(machine: String, destination: String, line: String)
        case unwritable(machine: String, reason: String, line: String)
        /// No build there runs Cherry's gateway.
        case noGateway(machine: String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let machine, let detail):
                "Cherry couldn't reach \(machine)\(detail.isEmpty ? "" : " (\(detail))")."
            case .linked(let machine, let destination, _):
                "~/.ssh/authorized_keys on \(machine) is a link to \(destination), which another tool manages, so Cherry leaves it alone. Add this line there:"
            case .unwritable(let machine, let reason, _):
                "Cherry couldn't change ~/.ssh/authorized_keys on \(machine) (\(reason)). Add this line there yourself:"
            case .noGateway(let machine):
                RemotePhoneKeys.noGatewayMessage(machine: machine)
            }
        }

        var line: String? {
            switch self {
            case .linked(_, _, let line), .unwritable(_, _, let line): line
            case .unreachable, .noGateway: nil
            }
        }
    }

    static func noGatewayMessage(machine: String) -> String {
        "Cherry's session host on \(machine) is too old for Cherry for iOS. Use Update Session Host… on its card in Settings › Devices, then try again."
    }

    /// The Mac's name, for messages.
    let machine: String
    let destination: String
    /// The build directory of the device's install (`remoteHostPath`),
    /// which the iPhone link is pointed at when it has none that works.
    let installDirectory: String?
    /// How to reach it: through its SSH master when up, else a login of
    /// its own (the app's `RemoteDeviceShell.app(through:)`).
    let shell: @Sendable () async -> RemoteDeviceShell
    /// Where its host keys are: /etc/ssh, a test's folder.
    let hostKeyDirectory: String

    init(
        machine: String, destination: String, installDirectory: String?, hostKeyDirectory: String = "/etc/ssh",
        shell: @escaping @Sendable () async -> RemoteDeviceShell
    ) {
        self.machine = machine
        self.destination = destination
        self.installDirectory = installDirectory
        self.hostKeyDirectory = hostKeyDirectory
        self.shell = shell
    }

    /// The app's, for `device`.
    init(device: RemoteDevice) {
        let destination = device.sshDestination
        self.init(
            machine: device.name,
            destination: destination,
            installDirectory: RemoteHostInstall.directoryName(ofRemoteHostPath: device.remoteHostPath),
            shell: { await RemoteDeviceShell.app(through: destination) }
        )
    }

    /// The phones Cherry added there, in the file's order.
    func phones() async throws -> [AuthorizedPhoneKeys.Phone] {
        let report = try await inspect(readsMac: false, readiesGateway: false)
        guard case .file(let text?, _, _) = report.keys else { return [] }
        return AuthorizedPhoneKeys.phones(in: AuthorizedPhoneKeys.lines(of: text))
    }

    /// What a code says of the Mac (`name`), once its gateway is ready.
    func describe(name: String) async -> Result<MobilePairingMacDescription, MobilePairingTarget.Problem> {
        let report: RemotePhonePairingReport
        do {
            report = try await inspect(readsMac: true, readiesGateway: true)
        } catch {
            return .failure(.unavailable((error as? Failure)?.errorDescription ?? error.localizedDescription))
        }
        guard report.gateway == .ready else { return .failure(.unavailable(Self.noGatewayMessage(machine: machine))) }
        guard let user = report.user else { return .failure(.unavailable("Cherry couldn't tell which user it logs in to \(machine) as.")) }
        let hosts = report.hosts
        guard !hosts.isEmpty else { return .failure(.unavailable("Cherry couldn't find an address of \(machine) for your iPhone.")) }
        let fingerprints = report.hostKeyFingerprints
        guard !fingerprints.isEmpty else {
            return .failure(.unavailable("Cherry couldn't read the SSH host keys of \(machine) (/etc/ssh), which your iPhone checks when it connects."))
        }
        return .success(MobilePairingMacDescription(
            name: name, user: user, hosts: hosts, sshPort: report.reachedPort ?? 22, hostKeyFingerprints: fingerprints
        ))
    }

    /// Adds `key` for the phone `name`, limited to Cherry's gateway there
    /// (`AuthorizedPhoneKeys.adding`).
    func add(_ key: SSHPublicKeyLine, name: String) async throws {
        try await rewrite(readiesGateway: true) { home in
            guard let line = AuthorizedPhoneKeys.line(for: key, name: name, gateway: Self.gateway(home: home)) else { return nil }
            return (line, { AuthorizedPhoneKeys.adding(key, line: line, to: $0) })
        }
    }

    /// Limits a phone paired before Cherry limited keys.
    func limit(_ phone: AuthorizedPhoneKeys.Phone) async throws {
        try await add(phone.key, name: phone.name)
    }

    /// Removes the lines Cherry wrote there for `phone`'s key.
    func remove(_ phone: AuthorizedPhoneKeys.Phone) async throws {
        try await rewrite(readiesGateway: false) { home in
            let line = AuthorizedPhoneKeys.line(for: phone.key, name: phone.name, gateway: Self.gateway(home: home))
                ?? "\(phone.key.line) \(AuthorizedPhoneKeys.marker) \(phone.name)"
            return (line, { AuthorizedPhoneKeys.removing(phone.key, from: $0) })
        }
    }

    /// The gateway link under `home`.
    static func gateway(home: String) -> String {
        "\(home)/\(RemoteHostInstall.gatewayLinkRelativePath)"
    }

    // MARK: The file

    private func inspect(readsMac: Bool, readiesGateway: Bool) async throws -> RemotePhonePairingReport {
        let output = await shell().run(
            RemotePhonePairing.inspectScript(
                installDirectory: installDirectory, readsMac: readsMac, readiesGateway: readiesGateway, hostKeyDirectory: hostKeyDirectory
            ),
            on: destination
        )
        guard let fields = RemoteHostInstaller.fields(output) else { throw Failure.unreachable(machine: machine, detail: Self.detail(output)) }
        return RemotePhonePairingReport(fields: fields)
    }

    /// Reads the file, makes the change `plan` gives for its home (the
    /// line it adds or removes, for messages, and what the lines become;
    /// nil: no gateway), and writes it, reading again once if the file
    /// changed meanwhile.
    private func rewrite(
        readiesGateway: Bool,
        _ plan: (String) -> (line: String, change: ([String]) -> [String]?)?
    ) async throws {
        for attempt in 0..<2 {
            let report = try await inspect(readsMac: false, readiesGateway: readiesGateway)
            guard let home = report.home else { throw Failure.unreachable(machine: machine, detail: "it reported no home folder") }
            if readiesGateway, report.gateway != .ready { throw Failure.noGateway(machine: machine) }
            guard let planned = plan(home) else { throw Failure.noGateway(machine: machine) }
            let line = planned.line
            let file: (lines: [String], mode: String, hash: String)
            switch report.keys {
            case .missing:
                file = ([], "600", "missing")
            case .link(let destination):
                throw Failure.linked(machine: machine, destination: destination.isEmpty ? "another file" : destination, line: line)
            case .file(let text?, let mode, let hash):
                file = (AuthorizedPhoneKeys.lines(of: text), mode, hash)
            case .file(nil, _, _):
                throw Failure.unwritable(machine: machine, reason: "it isn't UTF-8 text", line: line)
            case nil:
                throw Failure.unreachable(machine: machine, detail: "it didn't say what its authorized_keys is")
            }
            guard let changed = planned.change(file.lines) else { return }
            let output = await shell().run(
                RemotePhonePairing.writeScript(text: AuthorizedPhoneKeys.text(of: changed), mode: file.mode, expectedHash: file.hash),
                on: destination
            )
            guard let fields = RemoteHostInstaller.fields(output) else { throw Failure.unreachable(machine: machine, detail: Self.detail(output)) }
            switch fields.last(where: { $0.key == "written" })?.value {
            case "ok": return
            case "changed" where attempt == 0: continue
            case "link": throw Failure.linked(machine: machine, destination: "another file", line: line)
            case "changed": throw Failure.unwritable(machine: machine, reason: "it kept changing while Cherry wrote it", line: line)
            default: throw Failure.unwritable(machine: machine, reason: "writing it failed", line: line)
            }
        }
    }

    /// What ssh said when a script did not run.
    private static func detail(_ output: RemoteDeviceShell.Output) -> String {
        if output.timedOut { return "it didn't answer in time" }
        return output.standardError.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
