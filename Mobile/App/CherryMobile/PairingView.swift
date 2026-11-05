@preconcurrency import AVFoundation
import CherryMobileKit
import SwiftUI
import UIKit

/// Pairs with a Mac from the code its Cherry shows (Settings › Devices ›
/// Pair iPhone…): scans it, unless the camera opened it already, finds the
/// Mac, waits while you allow this iPhone there (showing this iPhone's key
/// to compare), then adds the Mac and connects.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let offer: PairingOffer?

    fileprivate enum Step: Equatable {
        case scanning
        case looking(mac: String)
        case waiting(mac: String)
        case paired(mac: String)
        case failed(String)
    }

    @State private var step: Step = .scanning
    @State private var camera: CameraAccess = .unknown

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !step.isPaired {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .task {
            if let offer {
                await pair(offer)
            } else {
                camera = await CameraAccess.request()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .scanning:
            scanner
        case .looking(let mac):
            VStack(spacing: 14) {
                ProgressView()
                Text("Looking for \(mac)…")
                    .foregroundStyle(.secondary)
            }
        case .waiting(let mac):
            VStack(spacing: 16) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Allow this iPhone on \(mac)")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Cherry on \(mac) asks whether to let it connect. Its key should match:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let fingerprint {
                    // One line: a wrapped key gets a hyphen it does not have.
                    Text(fingerprint)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                ProgressView()
                    .padding(.top, 4)
            }
        case .paired(let mac):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("\(mac) is paired")
                    .font(.title3.weight(.semibold))
                Text("Its agents and sessions show in the inbox.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Scan Again") {
                    step = .scanning
                    Task { camera = await CameraAccess.request() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var scanner: some View {
        VStack(spacing: 18) {
            switch camera {
            case .unknown:
                ProgressView()
                    .frame(width: 280, height: 280)
            case .granted:
                QRScanner { text in
                    guard step == .scanning else { return }
                    if let url = URL(string: text), let offer = PairingOffer(url: url) {
                        Task { await pair(offer) }
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.tint, lineWidth: 3))
            case .denied:
                ContentUnavailableView {
                    Label("Camera off for Cherry", systemImage: "camera.fill")
                } description: {
                    Text("Allow the camera in Settings to scan the code, or scan it with the Camera app.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            case .unavailable:
                ContentUnavailableView("No camera", systemImage: "camera.fill", description: Text("Scan the code with another device's camera, or add the Mac by hand."))
            }
            Text("On your Mac, open Cherry's Settings › Devices › Pair iPhone…, then point the camera at the code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var fingerprint: String? {
        guard case .success(let line) = model.deviceKey else { return nil }
        return SSHKeys.fingerprint(ofOpenSSHLine: line)
    }

    private func pair(_ offer: PairingOffer) async {
        step = .looking(mac: offer.name)
        do {
            let endpoint = try await model.pair(with: offer) { _ in
                await MainActor.run { step = .waiting(mac: offer.name) }
            }
            step = .paired(mac: endpoint.name)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }
}

private extension PairingView.Step {
    var isPaired: Bool {
        if case .paired = self { return true }
        return false
    }
}

/// Whether Cherry may use the camera.
enum CameraAccess: Equatable {
    case unknown
    case granted
    case denied
    case unavailable

    /// Asks the first time; no camera (the simulator) is unavailable.
    static func request() async -> CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: return .denied
        }
    }
}

/// The camera, reading QR codes: `found` gets each one's text.
struct QRScanner: UIViewRepresentable {
    let found: (String) -> Void

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        view.found = found
        view.start()
        return view
    }

    func updateUIView(_ view: ScannerView, context: Context) {
        view.found = found
    }

    static func dismantleUIView(_ view: ScannerView, coordinator: ()) {
        view.stop()
    }
}

final class ScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((String) -> Void)?
    private let session = AVCaptureSession()

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    func start() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = layer as! AVCaptureVideoPreviewLayer
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func stop() {
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let texts = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            for text in texts {
                found?(text)
            }
        }
    }
}
