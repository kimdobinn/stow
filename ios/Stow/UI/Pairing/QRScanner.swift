@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The camera, full screen, until it sees a QR code.
struct QRScannerSheet: View {
    let onCode: (String) -> Void
    let onPaste: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var problem: ScannerProblem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let problem {
                VStack(spacing: 16) {
                    Image(systemName: problem == .denied ? "camera.badge.ellipsis" : "camera")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(problem.message)
                        .font(.body)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if problem == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Paste link", action: onPaste)
                        .foregroundStyle(.white)
                }
                .padding(32)
            } else {
                QRScannerView(onCode: onCode) { problem = $0 }
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 250, height: 250)
                    .accessibilityHidden(true)
                VStack {
                    Text("Point the camera at the code on the Mac.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.top, 72)
                    Spacer()
                }
            }
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Cancel")
                    Spacer()
                }
                .padding(.horizontal, 16)
                Spacer()
            }
        }
    }
}

enum ScannerProblem: Equatable {
    case denied
    case noCamera

    var message: String {
        switch self {
        case .denied: "Stow can't use the camera. Allow it in Settings, or paste the pairing link instead."
        case .noCamera: "There's no camera to scan with. Paste the pairing link instead."
        }
    }
}

/// AVFoundation's QR reader (it works on every iPhone, unlike VisionKit's DataScanner).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onProblem: (ScannerProblem) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        controller.onProblem = onProblem
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
        controller.onProblem = onProblem
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onProblem: ((ScannerProblem) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var found = false
    /// The capture session blocks while it starts and stops: not on the main thread.
    private let sessionQueue = DispatchQueue(label: "dev.stow.ios.qr")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { await setUp() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        sessionQueue.async { session.stopRunning() }
    }

    private func setUp() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return report(.denied) }
        default:
            return report(.denied)
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return report(.noCamera) }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return report(.noCamera) }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview
        let session = session
        sessionQueue.async { session.startRunning() }
    }

    private func report(_ problem: ScannerProblem) {
        onProblem?(problem)
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let code = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        // The delegate queue is the main queue.
        MainActor.assumeIsolated {
            guard let code, !found else { return }
            found = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let session = session
            sessionQueue.async { session.stopRunning() }
            onCode?(code)
        }
    }
}
