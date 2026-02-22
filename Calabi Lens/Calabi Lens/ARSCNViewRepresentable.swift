import SwiftUI
import ARKit

struct ARSCNViewRepresentable: UIViewRepresentable {

    let captureManager: ARKitCaptureManager

    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView()
        sceneView.scene = SCNScene()
        sceneView.automaticallyUpdatesLighting = true
        sceneView.rendersCameraGrain = true
        captureManager.attach(sceneView: sceneView)
        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Session is managed by ARKitCaptureManager; no updates needed here.
    }
}
