import ARKit
import UIKit

final class FrameEncoder {

    private var frameID: UInt64 = 0

    func resetFrameID() {
        frameID = 0
    }

    /// Consume and return the next frame ID. Each call returns a unique value.
    func nextFrameID() -> UInt64 {
        let id = frameID
        frameID += 1
        return id
    }

    // MARK: - Extracted Frame (lightweight, no ARFrame reference)

    struct ExtractedFrame {
        let rgbData: Data
        let depthData: Data
        let confidenceData: Data
        let header: FrameHeader
    }

    /// Extract all data from an ARFrame synchronously. Call on the delegate thread.
    /// After this returns, the ARFrame can be released — no references are retained.
    func extract(frame: ARFrame, settings: SessionSettings, frameID: UInt64, correctedPose: simd_float4x4? = nil) -> ExtractedFrame {
        let rgbData = encodeNV12(pixelBuffer: frame.capturedImage)
        let depthData = encodeDepth(frame: frame, settings: settings)
        let confidenceData = encodeConfidence(frame: frame, settings: settings)

        let header = buildHeader(
            frame: frame,
            settings: settings,
            frameID: frameID,
            rgbData: rgbData,
            depthData: depthData,
            confidenceData: confidenceData,
            correctedPose: correctedPose
        )

        return ExtractedFrame(rgbData: rgbData, depthData: depthData, confidenceData: confidenceData, header: header)
    }

    /// Pack an extracted frame into binary wire format. Safe to call on any queue.
    func pack(_ extracted: ExtractedFrame) -> Data {
        let encoder = JSONEncoder()
        let jsonData = (try? encoder.encode(extracted.header)) ?? Data()
        return packMessage(json: jsonData, rgb: extracted.rgbData, depth: extracted.depthData, confidence: extracted.confidenceData)
    }

    // MARK: - NV12 (zero-cost raw copy)

    /// Copy raw NV12 biplanar data directly from ARKit's capturedImage.
    /// Layout: [Y plane: w*h bytes] [UV plane: w*h/2 bytes (interleaved CbCr)]
    /// Total: w * h * 1.5 bytes. Zero conversion cost.
    private func encodeNV12(pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount >= 2 else { return Data() }

        // Y plane (plane 0)
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)

        // UV plane (plane 1, interleaved CbCr)
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)

        // Total: Y (w*h) + UV (w*h/2)
        var result = Data(capacity: yWidth * yHeight + uvWidth * 2 * uvHeight)

        // Copy Y plane row-by-row (handles row padding)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<yHeight {
            result.append(yPtr + row * yBytesPerRow, count: yWidth)
        }

        // Copy UV plane row-by-row
        let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<uvHeight {
            result.append(uvPtr + row * uvBytesPerRow, count: uvWidth * 2)
        }

        return result
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

    // MARK: - Confidence Encoding

    private func encodeConfidence(frame: ARFrame, settings: SessionSettings) -> Data {
        guard settings.confidenceInclusion,
              let confidenceMap = frame.sceneDepth?.confidenceMap else {
            return Data()
        }

        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }

        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return Data()
        }

        // confidenceMap is kCVPixelFormatType_OneComponent8 (UInt8, values 0/1/2)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Copy row-by-row to handle potential row padding
        var result = Data(capacity: width * height)
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            result.append(ptr + rowStart, count: width)
        }
        return result
    }

    // MARK: - Frame Header

    private func buildHeader(
        frame: ARFrame,
        settings: SessionSettings,
        frameID: UInt64,
        rgbData: Data,
        depthData: Data,
        confidenceData: Data = Data(),
        correctedPose: simd_float4x4? = nil
    ) -> FrameHeader {
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let pixelBuffer = frame.capturedImage

        // Pose — use corrected SLAM pose if provided, otherwise raw ARKit VIO
        let transform = correctedPose ?? camera.transform
        let poseSource = correctedPose != nil ? "rtabmap_slam" : "arkit_vio"
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

        // RGB dimensions — always original resolution (NV12 is raw, no downscaling)
        let rgbWidth = CVPixelBufferGetWidth(pixelBuffer)
        let rgbHeight = CVPixelBufferGetHeight(pixelBuffer)

        // Confidence map info
        let hasConfidence = !confidenceData.isEmpty
        let confMap = hasConfidence ? frame.sceneDepth?.confidenceMap : nil
        let confWidth: Int? = confMap.map { CVPixelBufferGetWidth($0) }.flatMap { $0 > 0 ? $0 : nil }
        let confHeight: Int? = confMap.map { CVPixelBufferGetHeight($0) }.flatMap { $0 > 0 ? $0 : nil }
        let hasConfidenceMetadata = confWidth != nil && confHeight != nil

        return FrameHeader(
            session_id: settings.sessionID.uuidString,
            frame_id: frameID,
            timestamp_ns: UInt64(frame.timestamp * 1e9),
            unix_timestamp: Date().timeIntervalSince1970,
            rgb_format: "nv12",
            rgb_width: rgbWidth,
            rgb_height: rgbHeight,
            image_orientation: Self.currentImageOrientation(),
            depth_format: hasDepth ? settings.depthFormat.wireString : nil,
            depth_width: depthWidth,
            depth_height: depthHeight,
            depth_scale: hasDepth ? settings.depthScale : nil,
            confidence_format: hasConfidence && hasConfidenceMetadata ? "uint8" : nil,
            confidence_width: confWidth,
            confidence_height: confHeight,
            fx: Double(intrinsics[0][0]),
            fy: Double(intrinsics[1][1]),
            cx: Double(intrinsics[2][0]),
            cy: Double(intrinsics[2][1]),
            intrinsics_width: rgbWidth,
            intrinsics_height: rgbHeight,
            pose_format: settings.poseFormat.wireString,
            T_wc: twc,
            tracking_state: trackingStateStr,
            tracking_reason: trackingReasonStr,
            pose_source: poseSource,
            device_orientation: {
                switch UIDevice.current.orientation {
                case .portrait: return "portrait"
                case .landscapeLeft: return "landscapeLeft"
                case .landscapeRight: return "landscapeRight"
                case .portraitUpsideDown: return "portraitUpsideDown"
                default: return "unknown"
                }
            }(),
            image_rotation: Self.gravityAlignedRotation(from: camera.transform)
        )
    }

    /// Degrees of clockwise rotation to apply to the raw image to make it gravity-aligned.
    private static func gravityAlignedRotation(from transform: simd_float4x4) -> Double {
        let gx = Double(-transform.columns.0.y)
        let gy = Double(-transform.columns.1.y)
        return atan2(-gx, -gy) * 180.0 / .pi
    }

    private static func currentImageOrientation() -> String {
        let orientation = UIDevice.current.orientation
        switch orientation {
        case .portrait: return "portrait"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .portraitUpsideDown: return "portraitUpsideDown"
        default: return "landscapeRight"
        }
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

    private func packMessage(json: Data, rgb: Data, depth: Data, confidence: Data = Data()) -> Data {
        var message = Data(capacity: 16 + json.count + rgb.count + depth.count + confidence.count)

        var jsonLen = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &jsonLen) { message.append(contentsOf: $0) }
        message.append(json)

        var rgbLen = UInt32(rgb.count).littleEndian
        withUnsafeBytes(of: &rgbLen) { message.append(contentsOf: $0) }
        message.append(rgb)

        var depthLen = UInt32(depth.count).littleEndian
        withUnsafeBytes(of: &depthLen) { message.append(contentsOf: $0) }
        message.append(depth)

        // Confidence section (optional, backward compatible)
        if !confidence.isEmpty {
            var confLen = UInt32(confidence.count).littleEndian
            withUnsafeBytes(of: &confLen) { message.append(contentsOf: $0) }
            message.append(confidence)
        }

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
    let depth_format: String?
    let depth_width: Int?
    let depth_height: Int?
    let depth_scale: Double?
    let confidence_format: String?
    let confidence_width: Int?
    let confidence_height: Int?
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
    let device_orientation: String
    let image_rotation: Double
}

// MARK: - Wire String Extensions

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
