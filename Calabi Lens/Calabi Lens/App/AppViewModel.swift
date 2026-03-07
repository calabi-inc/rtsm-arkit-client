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

    // MARK: - Init

    init() {
        wireCallbacks()
    }

    private func wireCallbacks() {
        // Frame pipeline: capture → encode → stream
        captureManager.onFrame = { [weak self] frame in
            guard let self, let sessionSettings = self.currentSessionSettings else { return }
            self.encodeQueue.async {
                let data = self.encoder.encode(frame: frame, settings: sessionSettings)
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
        captureManager.setStreaming(enabled: true, sessionSettings: sessionSettings)
        streamer.enableReconnect()
        streamer.startPing(interval: 2)

        appState = .recording(sessionID: sessionSettings.sessionID)
    }

    func stopRecording() {
        captureManager.setStreaming(enabled: false, sessionSettings: nil)
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
        streamer.disableReconnect()
        streamer.stopPing()
        streamer.disconnect() // abort, not flush
        metrics.freezeMetrics()
        currentSessionSettings = nil
        appState = .idle
    }
}
