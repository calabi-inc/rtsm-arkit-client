import ARKit
import Combine

final class ARKitCaptureManager: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: - Published State

    @Published private(set) var trackingState: ARCamera.TrackingState = .notAvailable
    @Published private(set) var isRunning = false

    // MARK: - Callbacks

    var onFrame: ((ARFrame) -> Void)?
    var onTrackingStateChange: ((ARCamera.TrackingState) -> Void)?

    // MARK: - Depth Availability

    private(set) var isDepthAvailable = false

    // MARK: - Session Reference

    private weak var sceneView: ARSCNView?

    // MARK: - Streaming State

    private var isStreaming = false
    private var sessionSettings: SessionSettings?
    private var lastSentTimestamp: TimeInterval = 0

    // MARK: - Attach

    func attach(sceneView: ARSCNView) {
        self.sceneView = sceneView
        sceneView.session.delegate = self
    }

    // MARK: - Lifecycle

    func startSession() {
        guard let session = sceneView?.session else { return }

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stopSession() {
        sceneView?.session.pause()
        isRunning = false
    }

    // MARK: - Streaming Control

    func setStreaming(enabled: Bool, sessionSettings: SessionSettings?) {
        isStreaming = enabled
        self.sessionSettings = sessionSettings
        if enabled {
            lastSentTimestamp = 0
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Always check depth availability
        if !isDepthAvailable && frame.sceneDepth != nil {
            isDepthAvailable = true
        }

        // Hz gating only when streaming
        guard isStreaming, let settings = sessionSettings else { return }

        let interval = 1.0 / settings.captureRate
        guard frame.timestamp - lastSentTimestamp >= interval else { return }
        lastSentTimestamp = frame.timestamp

        onFrame?(frame)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingState = camera.trackingState
        onTrackingStateChange?(camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        isRunning = false
    }

    func sessionWasInterrupted(_ session: ARSession) {
        isRunning = false
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        startSession()
    }
}
