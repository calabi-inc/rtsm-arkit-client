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
        // Frame pipeline: capture → [SLAM] → encode → stream
        captureManager.onFrame = { [weak self] frame in
            guard let self, let sessionSettings = self.currentSessionSettings else { return }
            self.encodeQueue.async {
                var correctedPose: simd_float4x4? = nil

                if let slam = self.rtabMapSLAM, slam.isRunning {
                    // Apply current mapToOdom correction to every frame
                    correctedPose = slam.mapToOdom

                    // Feed frame to RTAB-Map at configured cadence
                    let interval = sessionSettings.slamProcessingRate.intervalSeconds
                    let now = frame.timestamp
                    if interval == 0 || (now - self.lastSLAMProcessTime) >= interval {
                        self.lastSLAMProcessTime = now
                        slam.processFrame(frame: frame, frameId: self.encoder.currentFrameID)
                    }
                }

                let data = self.encoder.encode(
                    frame: frame,
                    settings: sessionSettings,
                    correctedPose: correctedPose
                )
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
                metrics.freezeMetrics()
                currentSessionSettings = nil
                appState = .idle
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
