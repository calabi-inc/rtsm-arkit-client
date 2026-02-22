import SwiftUI

struct NetworkConfigSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isPresented: Bool
    @State private var editedURL: String = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    // URL label
                    Text("SERVER WEBSOCKET URL")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.secondary)

                    // URL text field
                    TextField("ws://host:port/path", text: $editedURL)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(.separator), lineWidth: 1)
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .disabled(viewModel.appState.isRecording)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Status row
                HStack {
                    Text("Status")
                        .foregroundColor(.secondary)
                    Spacer()
                    statusBadge
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()

                // Buttons
                HStack(spacing: 10) {
                    Button(action: {
                        viewModel.settings.serverURL = editedURL
                        viewModel.connect()
                    }) {
                        Text("Connect")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(connectEnabled ? Color.blue : Color(.systemGray5))
                            .foregroundColor(connectEnabled ? .white : .secondary)
                            .cornerRadius(10)
                    }
                    .disabled(!connectEnabled)

                    Button(action: {
                        viewModel.disconnect()
                    }) {
                        Text("Disconnect")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(.separator), lineWidth: 1)
                            )
                    }
                    .disabled(!disconnectEnabled)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                // Tip
                Text("Tip: keep the phone and server on the same LAN Wi\u{2011}Fi. 5 GHz recommended.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                Spacer()
            }
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        viewModel.settings.serverURL = editedURL
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            editedURL = viewModel.settings.serverURL
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private var connectEnabled: Bool {
        if case .idle = viewModel.appState, viewModel.wifiMonitor.isWiFiConnected { return true }
        if case .failed = viewModel.appState, viewModel.wifiMonitor.isWiFiConnected { return true }
        return false
    }

    private var disconnectEnabled: Bool {
        switch viewModel.appState {
        case .connected, .recording, .reconnecting:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.appState {
        case .idle:
            badge(text: "Disconnected", color: .red)
        case .connecting:
            badge(text: "Connecting\u{2026}", color: .orange)
        case .connected:
            badge(text: "Connected", color: .green)
        case .recording:
            badge(text: "Connected (Recording)", color: .green)
        case .reconnecting:
            badge(text: "Reconnecting\u{2026}", color: .orange)
        case .permissionError:
            badge(text: "Error", color: .red)
        case .failed:
            badge(text: "Failed", color: .red)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .cornerRadius(6)
    }
}
