import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("rgbFormat") var rgbFormat = RGBFormat.jpeg
    @AppStorage("depthInclusion") var depthInclusion = DepthInclusion.none
    @AppStorage("depthFormat") var depthFormat = DepthFormat.float32
    @AppStorage("poseFormat") var poseFormat = PoseFormat.matrix4x4
}
