import Foundation

enum RGBFormat: String, CaseIterable {
    case jpeg
    case png
    case rawBGRA
}

enum DepthInclusion: String, CaseIterable {
    case auto
    case on
    case off
}

enum DepthFormat: String, CaseIterable {
    case uint16mm
    case float32m
    case pngUint16
}

enum PoseFormat: String, CaseIterable {
    case matrix4x4
    case quatTranslation
}

enum RGBResolution: String, CaseIterable {
    case original
    case downscaled
}
