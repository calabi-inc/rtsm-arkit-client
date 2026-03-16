import ARKit
import Combine
import UIKit

final class AppViewModel: ObservableObject {

    // MARK: - Published State

    @Published var appState: AppState = .idle
    @Published var trackingState: ARCamera.TrackingState = .notAvailable

    // MARK: - Owned Components

    let captureManager = ARKitCaptureManager()
    let encoder = FrameEncoder()
    let streamer = WebSocketStreamer()
    let metrics = MetricsTracker()
    let settings = AppSettings()
    let wifiMonitor = WiFiMonitor()

    // MARK: - Private

    private let encodeQueue = DispatchQueue(label: "com.calabiLens.encode", qos: .userInitiated)
    private var currentSessionSettings: SessionSettings?
    private var rtabMapSLAM: RTABMapSLAM?
    private var lastSLAMProcessTime: TimeInterval = 0

    // MARK: - Init

    init() {
        wireCallbacks()
    }

    private func wireCallbacks() {
        // Frame pipeline: capture → extract (delegate thread) → pack (encodeQueue) → stream
        captureManager.onFrame = { [weak self] frame in
            guard let self, let sessionSettings = self.currentSessionSettings else { return }

            // Allocate a single frame ID for this frame — shared by both SLAM and encoding
            let fid = self.encoder.nextFrameID()

            // Feed frame to SLAM on the delegate thread (data extraction is synchronous,
            // heavy processing dispatches to slamQueue — does NOT block here)
            if let slam = self.rtabMapSLAM, slam.isRunning {
                let interval = sessionSettings.slamProcessingRate.intervalSeconds
                let now = frame.timestamp
                if interval == 0 || (now - self.lastSLAMProcessTime) >= interval {
                    self.lastSLAMProcessTime = now
                    slam.processFrame(frame: frame, frameId: fid)
                }
            }

            // Capture the current SLAM correction
            let mapToOdomSnapshot: simd_float4x4?
            if let slam = self.rtabMapSLAM, slam.isRunning {
                mapToOdomSnapshot = slam.mapToOdom
            } else {
                mapToOdomSnapshot = nil
            }

            let correctedPose: simd_float4x4?
            if let mapToOdom = mapToOdomSnapshot {
                correctedPose = mapToOdom * frame.camera.transform
            } else {
                correctedPose = nil
            }

            // Debug: log pose info every 30 frames
            if fid % 30 == 0 {
                let t = frame.camera.transform
                let arkitPos = (t.columns.3.x, t.columns.3.y, t.columns.3.z)
                let sentPose = correctedPose ?? t
                let sentPos = (sentPose.columns.3.x, sentPose.columns.3.y, sentPose.columns.3.z)
                let mapToOdomState: String
                if let mapToOdom = mapToOdomSnapshot {
                    mapToOdomState = (mapToOdom == matrix_identity_float4x4) ? "identity" : "MODIFIED"
                } else {
                    mapToOdomState = "inactive"
                }
                let depth = frame.sceneDepth?.depthMap
                let depthW = depth.map { CVPixelBufferGetWidth($0) } ?? 0
                let depthH = depth.map { CVPixelBufferGetHeight($0) } ?? 0
                let rgbW = CVPixelBufferGetWidth(frame.capturedImage)
                let rgbH = CVPixelBufferGetHeight(frame.capturedImage)
                let intr = frame.camera.intrinsics
                print("[FRAME \(fid)] arkit=(\(String(format: "%.3f,%.3f,%.3f", arkitPos.0, arkitPos.1, arkitPos.2))) sent=(\(String(format: "%.3f,%.3f,%.3f", sentPos.0, sentPos.1, sentPos.2))) mapToOdom=\(mapToOdomState) rgb=\(rgbW)x\(rgbH) depth=\(depthW)x\(depthH) fx=\(String(format: "%.1f", intr[0][0])) fy=\(String(format: "%.1f", intr[1][1])) cx=\(String(format: "%.1f", intr[2][0])) cy=\(String(format: "%.1f", intr[2][1]))")
            }

            // Extract & encode all pixel data NOW on the delegate thread.
            // After this call, the ARFrame can be released — no references retained.
            let extracted = self.encoder.extract(
                frame: frame,
                settings: sessionSettings,
                frameID: fid,
                correctedPose: correctedPose
            )

            // Only lightweight packing (JSON + binary assembly) goes to the queue
            self.encodeQueue.async {
                let data = self.encoder.pack(extracted)
                self.streamer.enqueue(data)
            }
        }

        // Tracking state
        captureManager.onTrackingStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.trackingState = state
            }
        }

        // Connection state
        streamer.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionStateChange(state)
            }
        }

        // RTT
        streamer.onRTT = { [weak self] ms in
            self?.metrics.recordRTT(ms)
        }

        // Metrics (bytes sent + queue depth)
        streamer.onMetricsUpdate = { [weak self] bytesSent, queueDepth in
            self?.metrics.recordSend(bytes: bytesSent)
            self?.metrics.updateQueueDepth(queueDepth)
        }

        // Drops
        streamer.onDropped = { [weak self] in
            self?.metrics.recordDrop()
        }
    }

    // MARK: - Connection State Handling

    private func handleConnectionStateChange(_ state: ConnectionState) {
        switch state {
        case .handshaking:
            if !appState.isRecording {
                appState = .connecting
            }

        case .connecting:
            if case .recording(let sessionID) = appState {
                // First reconnect attempt during recording
                captureManager.setStreaming(enabled: false, sessionSettings: nil)
                appState = .reconnecting(attempt: 1, sessionID: sessionID)
            } else if case .reconnecting(let attempt, let sessionID) = appState {
                // Subsequent reconnect attempt
                appState = .reconnecting(attempt: attempt + 1, sessionID: sessionID)
            } else if !appState.isRecording {
                appState = .connecting
            }

        case .connected:
            if case .reconnecting(_, let sessionID) = appState {
                // Reconnected during recording — resume streaming
                appState = .recording(sessionID: sessionID)
                if let sessionSettings = currentSessionSettings {
                    captureManager.setStreaming(enabled: true, sessionSettings: sessionSettings)
                }
                streamer.startPing(interval: 2)
            } else {
                appState = .connected
            }

        case .disconnected(let error):
            if case .reconnecting(_, _) = appState {
                // Max retries exceeded
                captureManager.setStreaming(enabled: false, sessionSettings: nil)
                rtabMapSLAM?.stop()
                rtabMapSLAM = nil
                streamer.disableReconnect()
                streamer.stopPing()
                metrics.freezeMetrics()
                currentSessionSettings = nil
                appState = .idle
            } else if case .recording(_) = appState {
                // Unexpected disconnect during an active recording session
                captureManager.setStreaming(enabled: false, sessionSettings: nil)
                rtabMapSLAM?.stop()
                rtabMapSLAM = nil
                streamer.disableReconnect()
                streamer.stopPing()
                metrics.freezeMetrics()
                currentSessionSettings = nil
                if error != nil {
                    appState = .failed(error)
                } else {
                    appState = .idle
                }
            } else if case .idle = appState {
                // Already idle (intentional stop) — ignore disconnect errors
                break
            } else if !appState.isRecording {
                if error != nil {
                    appState = .failed(error)
                } else {
                    appState = .idle
                }
            }
        }
    }

    // MARK: - Public Methods

    func connect() {
        guard let url = URL(string: settings.serverURL) else { return }
        appState = .connecting
        streamer.sessionID = UUID().uuidString
        streamer.deviceName = UIDevice.current.model
        streamer.connect(to: url)
    }

    func disconnect() {
        streamer.disconnect()
        appState = .idle
    }

    func startRecording() {
        guard appState == .connected else { return }
        guard case .normal = trackingState else { return }

        let sessionSettings = SessionSettings(from: settings)
        currentSessionSettings = sessionSettings

        encoder.resetFrameID()
        metrics.resetForSession()
        lastSLAMProcessTime = 0

        // Start RTAB-Map SLAM if enabled
        if sessionSettings.slamMode == .rtabmap {
            let slam = RTABMapSLAM()
            slam.onLoopClosure = { [weak self] corrections in
                self?.sendPoseCorrections(corrections)
            }
            slam.start()
            rtabMapSLAM = slam
        }

        captureManager.setStreaming(enabled: true, sessionSettings: sessionSettings)
        streamer.enableReconnect()
        streamer.startPing(interval: 2)

        appState = .recording(sessionID: sessionSettings.sessionID)
    }

    func stopRecording() {
        captureManager.setStreaming(enabled: false, sessionSettings: nil)
        rtabMapSLAM?.stop()
        rtabMapSLAM = nil
        streamer.disableReconnect()
        streamer.stopPing()
        streamer.flushAndDisconnect()
        metrics.freezeMetrics()
        currentSessionSettings = nil
        // appState will transition to .idle via onStateChange(.disconnected) from flushAndDisconnect
        appState = .idle
    }

    func handleBackground() {
        guard appState.isRecording else { return }
        captureManager.setStreaming(enabled: false, sessionSettings: nil)
        rtabMapSLAM?.stop()
        rtabMapSLAM = nil
        streamer.disableReconnect()
        streamer.stopPing()
        streamer.disconnect() // abort, not flush
        metrics.freezeMetrics()
        currentSessionSettings = nil
        appState = .idle
    }

    // MARK: - SLAM Pose Corrections

    private func sendPoseCorrections(_ corrections: [String: [Float]]) {
        let message: [String: Any] = [
            "type": "pose_corrections",
            "corrections": corrections
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message) else { return }
        streamer.sendTextMessage(jsonData)
    }
}
