import SwiftUI
import ARKit

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNetworkSheet = false
    @State private var showSettingsSheet = false

    var body: some View {
        ZStack {
            // Full-screen camera feed
            ARSCNViewRepresentable(captureManager: viewModel.captureManager)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                TopBarView(
                    appState: viewModel.appState,
                    showSettings: { showSettingsSheet = true }
                )

                Spacer()

                // Shutter button
                ShutterButtonView(
                    appState: viewModel.appState,
                    trackingState: viewModel.trackingState,
                    metrics: viewModel.metrics,
                    settings: viewModel.settings,
                    onRecord: { viewModel.startRecording() },
                    onStop: { viewModel.stopRecording() }
                )
                .padding(.bottom, 12)

                // Bottom overlay
                BottomOverlayView(
                    appState: viewModel.appState,
                    trackingState: viewModel.trackingState,
                    metrics: viewModel.metrics,
                    wifiMonitor: viewModel.wifiMonitor,
                    serverURL: viewModel.settings.serverURL,
                    onConnect: { viewModel.connect() },
                    onShowNetworkConfig: { showNetworkSheet = true }
                )
            }
        }
        .onAppear {
            viewModel.captureManager.startSession()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                viewModel.handleBackground()
            }
        }
        .sheet(isPresented: $showNetworkSheet) {
            NetworkConfigSheet(
                viewModel: viewModel,
                isPresented: $showNetworkSheet
            )
        }
        .sheet(isPresented: $showSettingsSheet) {
            StreamingSettingsSheet(
                settings: viewModel.settings,
                isRecording: viewModel.appState.isRecording,
                isPresented: $showSettingsSheet
            )
        }
    }
}

// MARK: - TopBarView

private struct TopBarView: View {
    let appState: AppState
    let showSettings: () -> Void

    private var pillConnected: Bool {
        switch appState {
        case .connected, .recording: return true
        default: return false
        }
    }

    var body: some View {
        HStack {
            // Connection pill
            HStack(spacing: 6) {
                Circle()
                    .fill(pillConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(pillConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.42))
            .clipShape(Capsule())

            Spacer()

            // Gear icon
            Button(action: showSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(appState.isRecording ? 0.2 : 0.7))
            }
            .disabled(appState.isRecording)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 32)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - ShutterButtonView

private struct ShutterButtonView: View {
    let appState: AppState
    let trackingState: ARCamera.TrackingState
    @ObservedObject var metrics: MetricsTracker
    @ObservedObject var settings: AppSettings
    let onRecord: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            // Shutter button
            Button(action: isRecording ? onStop : onRecord) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(isReady || isRecording ? 0.7 : 0.35), lineWidth: 3)
                        .frame(width: 76, height: 76)

                    if isRecording {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white)
                                .frame(width: 22, height: 22)
                        }
                    } else {
                        Circle()
                            .fill(isReady ? Color.red : Color(white: 0.28))
                            .frame(width: 60, height: 60)
                    }
                }
            }
            .disabled(!canTap)

            // Label
            if isRecording {
                if case .reconnecting = appState {
                    Text("Reconnecting\u{2026}")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                } else {
                    Text("\u{25CF} STREAMING \u{00B7} \(metrics.frameCounter) frames")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                }
            } else {
                Text("RECORD")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.5)
                    .foregroundColor(.white.opacity(isReady ? 0.75 : 0.45))
            }

            // Subtitle
            if isRecording, let sessionID = appState.sessionID {
                Text("session: \(sessionID.uuidString.prefix(8))\u{2026}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.25))
            } else {
                Text(settingsSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(isReady ? 0.35 : 0.25))
            }
        }
    }

    private var isRecording: Bool { appState.isRecording }

    private var isReady: Bool {
        if case .connected = appState, case .normal = trackingState { return true }
        return false
    }

    private var canTap: Bool {
        if isRecording { return true }
        return isReady
    }

    private var settingsSummary: String {
        let hz = Int(settings.captureRate)
        let rgb = settings.rgbEncoding.displayName
        let depth: String
        switch settings.depthFormat {
        case .uint16mm: depth = "uint16"
        case .float32m: depth = "f32"
        case .pngUint16: depth = "PNG-u16"
        }
        let pose: String
        switch settings.poseFormat {
        case .matrix4x4: pose = "4\u{00D7}4"
        case .quatTranslation: pose = "Q+T"
        }
        return "\(hz) Hz \u{00B7} \(rgb) \u{00B7} \(depth) \u{00B7} \(pose)"
    }
}

// MARK: - BottomOverlayView

private struct BottomOverlayView: View {
    let appState: AppState
    let trackingState: ARCamera.TrackingState
    @ObservedObject var metrics: MetricsTracker
    @ObservedObject var wifiMonitor: WiFiMonitor
    let serverURL: String
    let onConnect: () -> Void
    let onShowNetworkConfig: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.15))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            // Network section
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("NETWORK")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.3))
                    Spacer()
                }
                .padding(.bottom, 2)

                // Wi-Fi status
                HStack(spacing: 5) {
                    Text("\u{25B2}")
                        .font(.system(size: 12))
                        .foregroundColor(wifiMonitor.isWiFiConnected ? .green : .red)
                    if wifiMonitor.isWiFiConnected {
                        Text("Wi-Fi Connected \u{00B7} \(wifiMonitor.localIP ?? "---")")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        Text("No Wi-Fi")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                // Server URL + Connect
                HStack(spacing: 7) {
                    Button(action: onShowNetworkConfig) {
                        Text(serverURL)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(appState.isRecording ? 0.35 : 0.7))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(appState.isRecording ? 0.06 : 0.08))
                            .cornerRadius(7)
                    }
                    .disabled(appState.isRecording)

                    Button(action: onConnect) {
                        Text("Connect")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(connectButtonEnabled ? .white : .white.opacity(0.2))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(connectButtonEnabled ? Color.blue : Color.white.opacity(0.06))
                            .cornerRadius(7)
                    }
                    .disabled(!connectButtonEnabled)
                }

                // Status line
                HStack {
                    Text("Status")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    statusBadge
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            // Health & Telemetry section
            VStack(alignment: .leading, spacing: 5) {
                Text("HEALTH & TELEMETRY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.bottom, 2)

                // Tracking state
                HStack {
                    Text("Tracking")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                    Spacer()
                    trackingBadge
                }

                // Metrics grid (2 columns)
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 1) {
                    metricRow(label: "RTT", value: metrics.rttMs > 0 ? "\(Int(metrics.rttMs)) ms" : "\u{2014} ms")
                    metricRow(label: "Throughput", value: throughputString)
                    metricRow(label: "Dropped", value: "\(metrics.droppedFramesTotal)", isWarning: metrics.droppedFramesLast60s > 0)
                    metricRow(label: "Queue", value: metrics.queueDepth > 0 ? "\(metrics.queueDepth)" : "\u{2014}")
                    metricRow(label: "Last Send", value: lastSendString)
                    metricRow(label: "Frames", value: metrics.frameCounter > 0 ? "\(metrics.frameCounter)" : "\u{2014}")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 22)
        }
        .background(Color(white: 0.03).opacity(0.94))
        .clipShape(RoundedCornerShape(radius: 22, corners: [.topLeft, .topRight]))
    }

    // MARK: - Helpers

    private var connectButtonEnabled: Bool {
        if case .idle = appState, wifiMonitor.isWiFiConnected { return true }
        return false
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch appState {
        case .idle:
            badgeView(text: "\u{25CF} Disconnected", color: .red)
        case .connecting:
            badgeView(text: "\u{25CF} Connecting\u{2026}", color: .yellow)
        case .connected, .recording:
            badgeView(text: "\u{25CF} Connected", color: .green)
        case .reconnecting(let attempt, _):
            badgeView(text: "Reconnecting\u{2026} (\(attempt)/3)", color: .yellow)
        case .permissionError:
            badgeView(text: "\u{25CF} Error", color: .red)
        case .failed:
            badgeView(text: "\u{25CF} Failed", color: .red)
        }
    }

    @ViewBuilder
    private var trackingBadge: some View {
        switch trackingState {
        case .normal:
            badgeView(text: "\u{25CF} Normal", color: .green)
        case .limited:
            badgeView(text: "\u{25CF} Limited", color: .yellow)
        case .notAvailable:
            badgeView(text: "\u{25CF} Unavailable", color: .red)
        }
    }

    private func badgeView(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(5)
    }

    private func metricRow(label: String, value: String, isWarning: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: isWarning ? .semibold : .regular, design: .monospaced))
                .foregroundColor(isWarning ? .yellow : .white.opacity(appState.isRecording ? 0.7 : 0.18))
        }
    }

    private var throughputString: String {
        let bps = metrics.throughputBytesPerSec
        if bps <= 0 { return "\u{2014} KB/s" }
        if bps >= 1_000_000 {
            return String(format: "%.1f MB/s", bps / 1_000_000)
        }
        return String(format: "%.0f KB/s", bps / 1000)
    }

    private var lastSendString: String {
        guard let date = metrics.lastSendTime else { return "\u{2014}" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - RoundedCornerShape

private struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
