import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › Devices › Pair iPhone… (this Mac's, or one of the other Macs'
/// cards'): the offer as a QR code that the iPhone's camera (or Cherry for
/// iOS) reads, then Allow or Deny for the phone that sends its key, and
/// what is wrong when Remote Login is off, the other Mac can't be paired
/// with, or the key could not be added.
struct PairPhoneSheet: View {
    @StateObject private var model: MobilePairingModel
    @Environment(\.dismiss) private var dismiss

    init(model: MobilePairingModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(target.isThisMac ? "Pair iPhone" : "Pair iPhone with \(target.displayName)").font(.title2.weight(.semibold))
                Text("Cherry for iOS reaches \(target.displayName) over SSH to show your agents and sessions, and to answer them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button(isDone ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(isDone ? .defaultAction : .cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.startIfNeeded() }
        .onDisappear { model.stop() }
    }

    private var target: MobilePairingTarget { model.target }

    private var isDone: Bool {
        if case .paired = model.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(target.isThisMac ? "Checking Remote Login…" : "Reaching \(target.displayName)…").foregroundStyle(.secondary)
            }
            .frame(minHeight: 120)
        case .remoteLoginOff:
            VStack(alignment: .leading, spacing: 10) {
                Label("Turn on Remote Login", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fontWeight(.medium)
                Text("Your iPhone reaches this Mac over SSH. Turn on Remote Login in System Settings › General › Sharing, then check again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Sharing Settings") { Self.openSharingSettings() }
                    Button("Check Again") { Task { await model.start() } }
                }
            }
        case .waiting(let offer):
            HStack(alignment: .top, spacing: 18) {
                QRCodeView(text: offer.url.absoluteString)
                    .frame(width: 200, height: 200)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan this code with your iPhone's camera, or in Cherry for iOS (Macs › Pair a Mac).")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your iPhone…").foregroundStyle(.secondary)
                    }
                    Text("The code works once, for 10 minutes. \(reachSentence) If macOS asks whether Cherry may accept incoming connections, allow it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .asking(let prompt):
            VStack(alignment: .leading, spacing: 10) {
                Text("Allow “\(prompt.phone)” to connect?")
                    .font(.headline)
                Text("It can then reach your Cherry sessions on \(target.displayName) over SSH, as \(model.describedMac?.user ?? NSUserName()): see them and type into them, and a terminal session runs what it types. Its key is added to ~/.ssh/authorized_keys\(target.isThisMac ? "" : " on \(target.displayName)") limited to that: it can't log in, run other commands or forward ports.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Its key, as Cherry for iOS shows it:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(prompt.fingerprint)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Deny") { Task { await model.deny() } }
                    Button("Allow") { Task { await model.allow() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .adding(let phone):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Adding “\(phone)”\(target.isThisMac ? "" : " to \(target.displayName)")…").foregroundStyle(.secondary)
            }
            .frame(minHeight: 60, alignment: .leading)
        case .paired(let phone):
            Label("“\(phone)” can reach \(target.displayName) now.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fontWeight(.medium)
                .frame(minHeight: 60, alignment: .leading)
        case .failed(let message, let line):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let line {
                    // One line that scrolls: a wrapped key gets hyphens it
                    // does not have.
                    ScrollView(.horizontal) {
                        Text(line)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize()
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy Line") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                    }
                } else {
                    Button("Try Again") { Task { await model.start() } }
                }
            }
        case .expired:
            VStack(alignment: .leading, spacing: 10) {
                Text("The code expired.").foregroundStyle(.secondary)
                Button("Show a New Code") { Task { await model.start() } }
            }
        }
    }

    /// Where the phone must be: near this Mac, and for another Mac able to
    /// reach that one too.
    private var reachSentence: String {
        target.isThisMac
            ? "Your iPhone needs to reach this Mac: on the same network, or both on Tailscale."
            : "Your iPhone needs to reach this Mac to pair, and \(target.displayName) from then on: on the same network, or on Tailscale."
    }

    static func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// `text` as a QR code, black on white with its quiet zone, in light and
/// dark mode alike.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Pairing code")
        }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        // Ten pixels a module: sharp however it is scaled.
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
