import Foundation

struct SessionSettings {
    var rgbFormat: RGBFormat
    var depthInclusion: DepthInclusion
    var depthFormat: DepthFormat
    var poseFormat: PoseFormat

    var depthScale: Float {
        switch depthFormat {
        case .float32:
            return 1.0
        case .float16:
            return 1000.0
        }
    }
}
