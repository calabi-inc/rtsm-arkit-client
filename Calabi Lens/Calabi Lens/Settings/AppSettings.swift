import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "ws://192.168.1.100:8765/stream"
    @AppStorage("captureRate") var captureRate: Double = 10.0
    @AppStorage("depthInclusion") var depthInclusion = DepthInclusion.auto
    @AppStorage("depthFormat") var depthFormat = DepthFormat.uint16mm
    @AppStorage("poseFormat") var poseFormat = PoseFormat.matrix4x4
    @AppStorage("slamMode") var slamMode = SLAMMode.rtabmap
    @AppStorage("slamProcessingRate") var slamProcessingRate = SLAMProcessingRate.high_2hz
    // Keep disabled by default for backward-compatible 3-section wire format.
    @AppStorage("confidenceInclusion") var confidenceInclusion: Bool = false
}
