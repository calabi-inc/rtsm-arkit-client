import Foundation

enum RGBFormat: String, CaseIterable {
    case jpeg
    case hevc
}

enum DepthInclusion: String, CaseIterable {
    case none
    case withRGB
    case separate
}

enum DepthFormat: String, CaseIterable {
    case float32
    case float16
}

enum PoseFormat: String, CaseIterable {
    case matrix4x4
    case quaternion
}
