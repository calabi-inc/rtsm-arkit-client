import Foundation

struct SessionSettings {
    let sessionID: UUID
    let captureRate: Double
    let rgbFormat: RGBFormat
    let jpegQuality: Double
    let depthInclusion: DepthInclusion
    let depthFormat: DepthFormat
    let poseFormat: PoseFormat
    let rgbResolution: RGBResolution

    var depthScale: Double {
        switch depthFormat {
        case .uint16mm: return 0.001
        case .float32m: return 1.0
        case .pngUint16: return 0.001
        }
    }

    init(from settings: AppSettings) {
        self.sessionID = UUID()
        self.captureRate = settings.captureRate
        self.rgbFormat = settings.rgbFormat
        self.jpegQuality = settings.jpegQuality
        self.depthInclusion = settings.depthInclusion
        self.depthFormat = settings.depthFormat
        self.poseFormat = settings.poseFormat
        self.rgbResolution = settings.rgbResolution
    }
}
