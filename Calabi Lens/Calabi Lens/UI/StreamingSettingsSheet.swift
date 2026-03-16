import SwiftUI

struct StreamingSettingsSheet: View {
    @ObservedObject var settings: AppSettings
    let isRecording: Bool
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Capture Rate
                    sectionHeader("CAPTURE RATE")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Frequency")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(Int(settings.captureRate)) Hz")
                                .foregroundColor(.blue)
                                .fontWeight(.semibold)
                            if settings.captureRate == 10 {
                                defaultBadge
                            }
                        }
                        Slider(value: $settings.captureRate, in: 5...20, step: 5)
                            .disabled(isRecording)
                        HStack {
                            Text("5 Hz").font(.system(size: 10)).foregroundColor(.secondary)
                            Spacer()
                            Text("10 Hz").font(.system(size: 10)).foregroundColor(.secondary)
                            Spacer()
                            Text("15 Hz").font(.system(size: 10)).foregroundColor(.secondary)
                            Spacer()
                            Text("20 Hz").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                    divider

                    // RGB Encoding
                    sectionHeader("RGB ENCODING")
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("RGB Format", selection: $settings.rgbFormat) {
                            Text("JPEG \u{2605}").tag(RGBFormat.jpeg)
                            Text("PNG").tag(RGBFormat.png)
                            Text("Raw BGRA").tag(RGBFormat.rawBGRA)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRecording)

                        if settings.rgbFormat == .jpeg {
                            HStack {
                                Text("JPEG Quality")
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(Int(settings.jpegQuality))")
                                    .foregroundColor(.blue)
                                    .fontWeight(.semibold)
                            }
                            Slider(value: $settings.jpegQuality, in: 50...95, step: 1)
                                .disabled(isRecording)
                            HStack {
                                Text("50").font(.system(size: 10)).foregroundColor(.secondary)
                                Spacer()
                                Text("95").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }

                        // RGB Resolution
                        Picker("Resolution", selection: $settings.rgbResolution) {
                            Text("640\u{00D7}480 \u{2605}").tag(RGBResolution.downscaled)
                            Text("Original").tag(RGBResolution.original)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRecording)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                    divider

                    // Depth Encoding
                    sectionHeader("DEPTH ENCODING")
                    VStack(alignment: .leading, spacing: 10) {
                        // Depth Inclusion
                        Picker("Depth Inclusion", selection: $settings.depthInclusion) {
                            Text("Auto \u{2605}").tag(DepthInclusion.auto)
                            Text("On").tag(DepthInclusion.on)
                            Text("Off").tag(DepthInclusion.off)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRecording)

                        // Depth Format
                        Picker("Depth Format", selection: $settings.depthFormat) {
                            Text("uint16 mm \u{2605}").tag(DepthFormat.uint16mm)
                            Text("float32 m").tag(DepthFormat.float32m)
                            Text("PNG-u16").tag(DepthFormat.pngUint16)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRecording)

                        // depth_scale display
                        HStack {
                            Text("depth_scale")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(depthScaleString) (auto)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        // Confidence map
                        Toggle("Include Confidence Map", isOn: $settings.confidenceInclusion)
                            .disabled(isRecording)
                        Text("Sends ARKit depth confidence (0=low, 1=medium, 2=high) for server-side filtering")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                    divider

                    // Pose Format
                    sectionHeader("POSE FORMAT")
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Pose Format", selection: $settings.poseFormat) {
                            Text("4\u{00D7}4 matrix \u{2605}").tag(PoseFormat.matrix4x4)
                            Text("Quat + T").tag(PoseFormat.quatTranslation)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRecording)

                        HStack {
                            Text("\u{2605} = recommended default")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                    divider

                    // SLAM
                    sectionHeader("ON-DEVICE SLAM")
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("SLAM Mode", selection: $settings.slamMode) {
                            Text("Off \u{2605}").tag(SLAMMode.off)
                            Text("RTAB-Map").tag(SLAMMode.rtabmap)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRecording)

                        if settings.slamMode == .rtabmap {
                            Text("RTAB-Map runs on-device SLAM with loop closure, ICP refinement, and pose graph optimization. Requires LiDAR.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            // Processing rate picker
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Processing Rate")
                                    .foregroundColor(.primary)
                                Picker("Rate", selection: $settings.slamProcessingRate) {
                                    ForEach(SLAMProcessingRate.allCases, id: \.self) { rate in
                                        Text(rate.displayName).tag(rate)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .disabled(isRecording)

                                // Description for selected rate
                                Text(settings.slamProcessingRate.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)

                                if settings.slamProcessingRate == .medium_1hz {
                                    defaultBadge
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Streaming Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
            .padding(.vertical, 0)
    }

    private var defaultBadge: some View {
        Text("default")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15))
            .cornerRadius(4)
    }

    private var depthScaleString: String {
        switch settings.depthFormat {
        case .uint16mm, .pngUint16: return "0.001"
        case .float32m: return "1.0"
        }
    }
}
