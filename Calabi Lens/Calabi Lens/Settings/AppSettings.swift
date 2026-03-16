import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "ws://192.168.1.100:8765/stream"
    @AppStorage("captureRate") var captureRate: Double = 10.0
    @AppStorage("rgbFormat") var rgbFormat = RGBFormat.jpeg
    @AppStorage("jpegQuality") var jpegQuality: Double = 75.0
    @AppStorage("depthInclusion") var depthInclusion = DepthInclusion.auto
    @AppStorage("depthFormat") var depthFormat = DepthFormat.uint16mm
    @AppStorage("poseFormat") var poseFormat = PoseFormat.matrix4x4
    @AppStorage("rgbResolution") var rgbResolution = RGBResolution.downscaled
    @AppStorage("slamMode") var slamMode = SLAMMode.rtabmap
    @AppStorage("slamProcessingRate") var slamProcessingRate = SLAMProcessingRate.medium_1hz
    @AppStorage("confidenceInclusion") var confidenceInclusion: Bool = false
}
