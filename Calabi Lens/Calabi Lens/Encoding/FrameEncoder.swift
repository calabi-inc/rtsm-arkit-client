import ARKit
import UIKit

final class FrameEncoder {

    private static let targetRGBWidth = 640
    private static let targetRGBHeight = 480

    private var frameID: UInt64 = 0
    private let ciContext = CIContext()

    func resetFrameID() {
        frameID = 0
    }

    func encode(frame: ARFrame, settings: SessionSettings) -> Data {
        let currentFrameID = frameID
        frameID += 1

        let rgbData = encodeRGB(pixelBuffer: frame.capturedImage, settings: settings)
        let depthData = encodeDepth(frame: frame, settings: settings)

        let header = buildHeader(
            frame: frame,
            settings: settings,
            frameID: currentFrameID,
            rgbData: rgbData,
            depthData: depthData
        )

        let encoder = JSONEncoder()
        let jsonData = (try? encoder.encode(header)) ?? Data()

        return packMessage(json: jsonData, rgb: rgbData, depth: depthData)
    }

    // MARK: - RGB Encoding

    private func encodeRGB(pixelBuffer: CVPixelBuffer, settings: SessionSettings) -> Data {
        let ciImage = ciImageForRGB(pixelBuffer: pixelBuffer, settings: settings)

        switch settings.rgbFormat {
        case .jpeg:
            return encodeJPEG(ciImage: ciImage, quality: settings.jpegQuality / 100.0)
        case .png:
            return encodePNG(ciImage: ciImage)
        case .rawBGRA:
            return encodeRawBGRA(ciImage: ciImage)
        }
    }

    private func ciImageForRGB(pixelBuffer: CVPixelBuffer, settings: SessionSettings) -> CIImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard settings.rgbResolution == .downscaled else { return ciImage }

        let scaleX = CGFloat(Self.targetRGBWidth) / ciImage.extent.width
        let scaleY = CGFloat(Self.targetRGBHeight) / ciImage.extent.height
        return ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    private func encodeJPEG(ciImage: CIImage, quality: Double) -> Data {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return Data()
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: CGFloat(quality)) ?? Data()
    }

    private func encodePNG(ciImage: CIImage) -> Data {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return Data()
        }
        return UIImage(cgImage: cgImage).pngData() ?? Data()
    }

    private func encodeRawBGRA(ciImage: CIImage) -> Data {
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        let rowBytes = width * 4
        var buffer = [UInt8](repeating: 0, count: height * rowBytes)
        buffer.withUnsafeMutableBytes { ptr in
            ciContext.render(ciImage,
                            toBitmap: ptr.baseAddress!,
                            rowBytes: rowBytes,
                            bounds: ciImage.extent,
                            format: .BGRA8,
                            colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return Data(buffer)
    }

    // MARK: - Depth Encoding

    private func shouldIncludeDepth(frame: ARFrame, settings: SessionSettings) -> Bool {
        switch settings.depthInclusion {
        case .off: return false
        case .on, .auto: return frame.sceneDepth != nil
        }
    }

    private func encodeDepth(frame: ARFrame, settings: SessionSettings) -> Data {
        guard shouldIncludeDepth(frame: frame, settings: settings),
              let depthMap = frame.sceneDepth?.depthMap else {
            return Data()
        }

        switch settings.depthFormat {
        case .uint16mm:
            return encodeDepthUint16mm(depthMap: depthMap)
        case .float32m:
            return encodeDepthFloat32m(depthMap: depthMap)
        case .pngUint16:
            return encodeDepthPNGUint16(depthMap: depthMap)
        }
    }

    private func encodeDepthUint16mm(depthMap: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return Data() }

        let floatPtr = baseAddress.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.size

        var result = Data(capacity: width * height * 2)
        for y in 0..<height {
            for x in 0..<width {
                let meters = floatPtr[y * floatsPerRow + x]
                let mm: UInt16
                if meters.isNaN || meters.isInfinite || meters <= 0 {
                    mm = 0
                } else {
                    mm = UInt16(min(65535, max(1, (meters * 1000.0).rounded())))
                }
                var le = mm.littleEndian
                withUnsafeBytes(of: &le) { result.append(contentsOf: $0) }
            }
        }
        return result
    }

    private func encodeDepthFloat32m(depthMap: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return Data() }

        let floatPtr = baseAddress.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.size

        var result = Data(capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value = floatPtr[y * floatsPerRow + x]
                if value.isNaN || value.isInfinite || value <= 0 {
                    value = 0
                }
                var le = value.bitPattern.littleEndian
                withUnsafeBytes(of: &le) { result.append(contentsOf: $0) }
            }
        }
        return result
    }

    private func encodeDepthPNGUint16(depthMap: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return Data() }

        let floatPtr = baseAddress.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.size

        var uint16Buffer = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let meters = floatPtr[y * floatsPerRow + x]
                if meters.isNaN || meters.isInfinite || meters <= 0 {
                    uint16Buffer[y * width + x] = 0
                } else {
                    uint16Buffer[y * width + x] = UInt16(min(65535, max(1, (meters * 1000.0).rounded())))
                }
            }
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageByteOrderInfo.order16Little.rawValue)
        let data = Data(bytes: &uint16Buffer, count: uint16Buffer.count * 2)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 16, bitsPerPixel: 16,
                  bytesPerRow: width * 2,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return Data()
        }

        return UIImage(cgImage: cgImage).pngData() ?? Data()
    }

    // MARK: - Frame Header

    private func buildHeader(
        frame: ARFrame,
        settings: SessionSettings,
        frameID: UInt64,
        rgbData: Data,
        depthData: Data
    ) -> FrameHeader {
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let imageResolution = camera.imageResolution
        let pixelBuffer = frame.capturedImage

        // Pose
        let transform = camera.transform
        let twc: [Double]
        switch settings.poseFormat {
        case .matrix4x4:
            twc = (0..<4).flatMap { col in
                (0..<4).map { row in Double(transform[col][row]) }
            }
        case .quatTranslation:
            let t = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let rotMatrix = simd_float3x3(
                simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )
            let q = simd_quaternion(rotMatrix)
            twc = [Double(q.vector.x), Double(q.vector.y), Double(q.vector.z), Double(q.vector.w),
                   Double(t.x), Double(t.y), Double(t.z)]
        }

        // Tracking state
        let (trackingStateStr, trackingReasonStr) = trackingStateStrings(camera.trackingState)

        // Depth info
        let hasDepth = !depthData.isEmpty
        let depthMap = hasDepth ? frame.sceneDepth?.depthMap : nil
        let depthWidth: Int? = depthMap.map { CVPixelBufferGetWidth($0) }
        let depthHeight: Int? = depthMap.map { CVPixelBufferGetHeight($0) }

        // RGB dimensions and intrinsics scaling
        let rgbWidth: Int
        let rgbHeight: Int
        let scaledFx: Double
        let scaledFy: Double
        let scaledCx: Double
        let scaledCy: Double
        let reportedIntrinsicsWidth: Int
        let reportedIntrinsicsHeight: Int

        if settings.rgbResolution == .downscaled {
            rgbWidth = Self.targetRGBWidth
            rgbHeight = Self.targetRGBHeight
            let intrinsicsScaleX = Double(Self.targetRGBWidth) / Double(imageResolution.width)
            let intrinsicsScaleY = Double(Self.targetRGBHeight) / Double(imageResolution.height)
            scaledFx = Double(intrinsics[0][0]) * intrinsicsScaleX
            scaledFy = Double(intrinsics[1][1]) * intrinsicsScaleY
            scaledCx = Double(intrinsics[2][0]) * intrinsicsScaleX
            scaledCy = Double(intrinsics[2][1]) * intrinsicsScaleY
            reportedIntrinsicsWidth = Self.targetRGBWidth
            reportedIntrinsicsHeight = Self.targetRGBHeight
        } else {
            rgbWidth = CVPixelBufferGetWidth(pixelBuffer)
            rgbHeight = CVPixelBufferGetHeight(pixelBuffer)
            scaledFx = Double(intrinsics[0][0])
            scaledFy = Double(intrinsics[1][1])
            scaledCx = Double(intrinsics[2][0])
            scaledCy = Double(intrinsics[2][1])
            reportedIntrinsicsWidth = Int(imageResolution.width)
            reportedIntrinsicsHeight = Int(imageResolution.height)
        }

        return FrameHeader(
            session_id: settings.sessionID.uuidString,
            frame_id: frameID,
            timestamp_ns: UInt64(frame.timestamp * 1e9),
            unix_timestamp: Date().timeIntervalSince1970,
            rgb_format: settings.rgbFormat.wireString,
            rgb_width: rgbWidth,
            rgb_height: rgbHeight,
            image_orientation: "landscapeRight",
            jpeg_quality: settings.rgbFormat == .jpeg ? settings.jpegQuality : nil,
            depth_format: hasDepth ? settings.depthFormat.wireString : nil,
            depth_width: depthWidth,
            depth_height: depthHeight,
            depth_scale: hasDepth ? settings.depthScale : nil,
            fx: scaledFx,
            fy: scaledFy,
            cx: scaledCx,
            cy: scaledCy,
            intrinsics_width: reportedIntrinsicsWidth,
            intrinsics_height: reportedIntrinsicsHeight,
            pose_format: settings.poseFormat.wireString,
            T_wc: twc,
            tracking_state: trackingStateStr,
            tracking_reason: trackingReasonStr,
            pose_source: "arkit_vio"
        )
    }

    private func trackingStateStrings(_ state: ARCamera.TrackingState) -> (String, String?) {
        switch state {
        case .normal: return ("normal", nil)
        case .notAvailable: return ("not_available", nil)
        case .limited(let reason):
            let reasonStr: String
            switch reason {
            case .initializing: reasonStr = "initializing"
            case .excessiveMotion: reasonStr = "excessive_motion"
            case .insufficientFeatures: reasonStr = "insufficient_features"
            case .relocalizing: reasonStr = "relocalizing"
            @unknown default: reasonStr = "unknown"
            }
            return ("limited", reasonStr)
        }
    }

    // MARK: - Binary Packing

    private func packMessage(json: Data, rgb: Data, depth: Data) -> Data {
        var message = Data(capacity: 12 + json.count + rgb.count + depth.count)

        var jsonLen = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &jsonLen) { message.append(contentsOf: $0) }
        message.append(json)

        var rgbLen = UInt32(rgb.count).littleEndian
        withUnsafeBytes(of: &rgbLen) { message.append(contentsOf: $0) }
        message.append(rgb)

        var depthLen = UInt32(depth.count).littleEndian
        withUnsafeBytes(of: &depthLen) { message.append(contentsOf: $0) }
        message.append(depth)

        return message
    }
}

// MARK: - FrameHeader

struct FrameHeader: Codable {
    let session_id: String
    let frame_id: UInt64
    let timestamp_ns: UInt64
    let unix_timestamp: Double
    let rgb_format: String
    let rgb_width: Int
    let rgb_height: Int
    let image_orientation: String
    let jpeg_quality: Double?
    let depth_format: String?
    let depth_width: Int?
    let depth_height: Int?
    let depth_scale: Double?
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let intrinsics_width: Int
    let intrinsics_height: Int
    let pose_format: String
    let T_wc: [Double]
    let tracking_state: String
    let tracking_reason: String?
    let pose_source: String
}

// MARK: - Wire String Extensions

extension RGBFormat {
    var wireString: String {
        switch self {
        case .jpeg: return "jpeg"
        case .png: return "png"
        case .rawBGRA: return "bgra"
        }
    }
}

extension DepthFormat {
    var wireString: String {
        switch self {
        case .uint16mm: return "uint16_mm"
        case .float32m: return "float32_m"
        case .pngUint16: return "png_uint16"
        }
    }
}

extension PoseFormat {
    var wireString: String {
        switch self {
        case .matrix4x4: return "matrix4x4_col_major"
        case .quatTranslation: return "quat_translation"
        }
    }
}
