import Foundation

enum RGBEncoding: String, CaseIterable {
    case h264
    case nv12
    case jpeg

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .nv12: return "NV12"
        case .jpeg: return "JPEG"
        }
    }

    var description: String {
        switch self {
        case .h264: return "Hardware-accelerated H.264 via VideoToolbox. Best for RTSM — compact, low latency, natively supported downstream."
        case .nv12: return "Raw YCbCr from ARKit — zero encoding cost, large frames. Server decodes with cv2.cvtColor(COLOR_YUV2BGR_NV12)."
        case .jpeg: return "JPEG compression — moderate size, widely compatible. Higher CPU than H.264."
        }
    }

    var wireString: String {
        switch self {
        case .h264: return "h264"
        case .nv12: return "nv12"
        case .jpeg: return "jpeg"
        }
    }
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

enum SLAMMode: String, CaseIterable {
    case off
    case rtabmap
}

enum SLAMProcessingRate: String, CaseIterable {
    case low_0_5hz
    case medium_1hz
    case high_2hz
    case everyFrame

    var intervalSeconds: Double {
        switch self {
        case .low_0_5hz: return 2.0
        case .medium_1hz: return 1.0
        case .high_2hz: return 0.5
        case .everyFrame: return 0.0
        }
    }

    var displayName: String {
        switch self {
        case .low_0_5hz: return "~0.5 Hz"
        case .medium_1hz: return "~1 Hz"
        case .high_2hz: return "~2 Hz"
        case .everyFrame: return "Every frame"
        }
    }

    var description: String {
        switch self {
        case .low_0_5hz: return "Lowest CPU, fewer loop closure checks"
        case .medium_1hz: return "Balanced — good correction quality with moderate CPU"
        case .high_2hz: return "More frequent corrections, higher CPU usage"
        case .everyFrame: return "Best SLAM quality, highest battery cost"
        }
    }
}
