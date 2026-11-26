import AVFoundation
import SwiftUI

/// Live camera preview, aspect-fill, portrait.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Bumped when the lens changes, so the new connection gets the portrait rotation too.
    var configurationID = 0

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        _ = configurationID
        uiView.setNeedsLayout()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90   // portrait
            }
        }
    }
}
