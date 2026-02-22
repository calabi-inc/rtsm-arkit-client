//
//  ARKitCaptureManager.swift
//  Calabi Lens
//
//  Created by Chi Feng Chang on 2/19/26.
//

import ARKit
import Combine

final class ARKitCaptureManager: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: - Published State

    @Published private(set) var trackingState: ARCamera.TrackingState = .notAvailable
    @Published private(set) var isRunning = false

    // MARK: - Callbacks

    var onFrameCaptured: ((ARFrame) -> Void)?
    var onDepthCaptured: ((ARDepthData) -> Void)?
    var onTrackingStateChanged: ((ARCamera.TrackingState) -> Void)?

    // MARK: - Session

    let session = ARSession()

    // MARK: - Hz Gating

    var targetFrameRate: Double = 30.0
    private var lastFrameTimestamp: TimeInterval = 0

    // MARK: - Init

    override init() {
        super.init()
        session.delegate = self
    }

    // MARK: - Lifecycle

    func run() {
        let configuration = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func pause() {
        session.pause()
        isRunning = false
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let interval = 1.0 / targetFrameRate
        guard frame.timestamp - lastFrameTimestamp >= interval else { return }
        lastFrameTimestamp = frame.timestamp

        onFrameCaptured?(frame)

        if let depthData = frame.sceneDepth {
            onDepthCaptured?(depthData)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingState = camera.trackingState
        onTrackingStateChanged?(camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        isRunning = false
    }

    func sessionWasInterrupted(_ session: ARSession) {
        isRunning = false
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        run()
    }
}
