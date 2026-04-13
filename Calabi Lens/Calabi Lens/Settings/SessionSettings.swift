import Foundation

struct SessionSettings {
    let sessionID: UUID
    let captureRate: Double
    let rgbEncoding: RGBEncoding
    let depthInclusion: DepthInclusion
    let depthFormat: DepthFormat
    let poseFormat: PoseFormat
    let slamMode: SLAMMode
    let slamProcessingRate: SLAMProcessingRate
    let confidenceInclusion: Bool

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
        self.rgbEncoding = settings.rgbEncoding
        self.depthInclusion = settings.depthInclusion
        self.depthFormat = settings.depthFormat
        self.poseFormat = settings.poseFormat
        self.slamMode = settings.slamMode
        self.slamProcessingRate = settings.slamProcessingRate
        self.confidenceInclusion = settings.confidenceInclusion
    }
}
