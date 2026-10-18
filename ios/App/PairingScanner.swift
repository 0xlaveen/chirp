import AVFoundation
import ChirpIOSCore
import SwiftUI
import UIKit

struct PairingScanner: UIViewControllerRepresentable {
    let onPair: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onPair: onPair) }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ScannerController, coordinator: ()) { uiViewController.stop() }
}

@MainActor
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = CameraSession()
    private let onPair: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var finished = false
    private let message = UILabel()
    init(onPair: @escaping (String) -> Void) { self.onPair = onPair; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.textColor = .white; message.numberOfLines = 0; message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body); message.adjustsFontForContentSizeCategory = true
        message.text = "Point the camera at the QR on your Mac. You can also paste the pairing link."
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([message.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)])
        Task { [weak self] in
            let permitted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, !self.finished else { return }
            guard permitted else { self.message.text = "Camera denied. Allow Camera in Settings or paste the pairing link."; return }
            self.capture.setDelegate(self)
            let layer = AVCaptureVideoPreviewLayer(session: self.capture.session)
            layer.videoGravity = .resizeAspectFill
            self.view.layer.insertSublayer(layer, at: 0); self.preview = layer; self.view.setNeedsLayout()
            self.capture.start { [weak self] success in
                Task { @MainActor in if !success { self?.message.text = "Camera unavailable. Paste the pairing link instead." } }
            }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { finished = true; capture.stop() }
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        guard let value, (try? PairingLink.parse(value)) != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            self.stop(); self.onPair(value)
        }
    }
}

/// CaptureSession configuration/start/stop share one serial queue; no camera work blocks SwiftUI.
private final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "dev.chirp.camera")
    @MainActor func setDelegate(_ delegate: any AVCaptureMetadataOutputObjectsDelegate) {
        output.setMetadataObjectsDelegate(delegate, queue: .main)
    }
    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output) else { completion(false); return }
            session.beginConfiguration(); session.addInput(input); session.addOutput(output)
            output.metadataObjectTypes = [.qr]; session.commitConfiguration(); session.startRunning(); completion(true)
        }
    }
    func stop() { queue.async { [self] in session.stopRunning() } }
}
