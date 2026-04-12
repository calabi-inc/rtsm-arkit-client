import VideoToolbox
import CoreMedia

/// Hardware-accelerated H.264 encoder using VideoToolbox.
///
/// Accepts raw CVPixelBuffers (NV12 from ARKit) and outputs H.264 Annex B
/// NAL units suitable for streaming. Designed to be called from a single
/// serial queue — not thread-safe for concurrent encode calls.
///
/// Usage:
///   1. Create with frame dimensions: `H264Encoder(width: 1920, height: 1440)`
///   2. Call `encode(pixelBuffer:timestamp:)` for each frame — returns Annex B Data
///   3. Call `invalidate()` when done (e.g., recording stopped)
final class H264Encoder {

    // MARK: - Configuration

    private let width: Int32
    private let height: Int32

    // MARK: - Session

    private var session: VTCompressionSession?

    /// Whether the encoder was successfully initialized. If false, encode() returns empty Data.
    private(set) var isReady: Bool = false

    // MARK: - Output Buffer (written by callback, read by encode())

    /// Encoded NAL data from the most recent output callback.
    /// Protected by the guarantee that encode() is only called from one serial queue.
    private var encodedData: Data?

    /// Retained reference to self, preventing deallocation while VTCompressionSession holds
    /// our raw pointer as refcon. Released in invalidate() after the session is torn down.
    private var retainedSelf: Unmanaged<H264Encoder>?

    // MARK: - Init

    /// Create an H.264 hardware encoder.
    ///
    /// - Parameters:
    ///   - width: Frame width in pixels (e.g., 1920)
    ///   - height: Frame height in pixels (e.g., 1440)
    ///   - bitRate: Target average bitrate in bits/sec (default 4 Mbps)
    ///   - maxKeyFrameInterval: Maximum frames between keyframes (default 60 ≈ 2s at 30fps)
    init(width: Int, height: Int, bitRate: Int = 4_000_000, maxKeyFrameInterval: Int = 60) {
        self.width = Int32(width)
        self.height = Int32(height)

        // Retain self so VTCompressionSession's refcon pointer stays valid
        // until invalidate() is called. This prevents use-after-free in the
        // output callback if the encoder is deallocated unexpectedly.
        let retained = Unmanaged.passRetained(self)
        self.retainedSelf = retained

        // Encoder specification: enable low-latency rate control
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true
        ]

        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: h264OutputCallback,
            refcon: retained.toOpaque(),
            compressionSessionOut: &sessionOut
        )

        guard status == noErr, let session = sessionOut else {
            print("[H264Encoder] CRITICAL: Failed to create compression session: \(status)")
            retainedSelf?.release()
            retainedSelf = nil
            return
        }

        self.session = session

        // Configure session properties
        setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        setProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        setProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: maxKeyFrameInterval as CFNumber)
        setProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)

        // Data rate limit: cap at 1.5x average bitrate per second.
        // Use explicit NSNumber to ensure correct CFNumber types for VideoToolbox.
        let bytesPerSecond = Int(Double(bitRate) * 1.5 / 8.0)
        let dataRateLimits: [NSNumber] = [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)]
        setProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        isReady = true
        print("[H264Encoder] Initialized \(width)x\(height) @ \(bitRate / 1_000_000)Mbps")
    }

    // MARK: - Encode

    /// Encode a single CVPixelBuffer into H.264 Annex B data.
    ///
    /// This call is synchronous — it submits the frame to the hardware encoder,
    /// flushes it, and returns the compressed data. Typically completes in ~2ms.
    ///
    /// - Parameters:
    ///   - pixelBuffer: Raw NV12 pixel buffer from ARKit's `frame.capturedImage`
    ///   - timestamp: ARFrame timestamp (seconds since session start)
    /// - Returns: H.264 Annex B data (SPS+PPS+IDR for keyframes, NAL units for P-frames),
    ///            or empty Data if encoding fails
    func encode(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> Data {
        guard let session else { return Data() }

        encodedData = nil

        // Convert timestamp to CMTime (nanosecond precision)
        let pts = CMTime(seconds: timestamp, preferredTimescale: 1_000_000_000)

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        guard status == noErr else {
            print("[H264Encoder] EncodeFrame failed: \(status)")
            return Data()
        }

        // Flush synchronously — blocks until the output callback has fired
        let flushStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if flushStatus != noErr {
            print("[H264Encoder] CompleteFrames failed: \(flushStatus)")
        }

        return encodedData ?? Data()
    }

    // MARK: - Invalidate

    /// Tear down the encoder session. Must be called before releasing the encoder.
    /// After this call, no further callbacks will fire and the retained self-reference
    /// is released, allowing deallocation.
    func invalidate() {
        if let session {
            // Invalidate stops all callbacks and releases internal resources.
            // No output callbacks will fire after this returns.
            VTCompressionSessionInvalidate(session)
            self.session = nil
            isReady = false
            print("[H264Encoder] Invalidated")
        }

        // Release the retained self-reference that kept us alive for the callback.
        // Must happen after session invalidation to prevent use-after-free.
        if retainedSelf != nil {
            retainedSelf?.release()
            retainedSelf = nil
        }
    }

    deinit {
        // Safety net — invalidate should have been called already.
        // If session is still alive here, something went wrong.
        if session != nil {
            print("[H264Encoder] WARNING: deinit called without invalidate()")
            VTCompressionSessionInvalidate(session!)
            session = nil
        }
        // Note: do NOT release retainedSelf here — if we got to deinit,
        // the retain cycle is already broken (retainedSelf was released in invalidate,
        // or was never set due to init failure).
    }

    // MARK: - Output Callback

    /// Called by VideoToolbox when a compressed frame is ready.
    /// Extracts NAL units from the CMSampleBuffer and converts AVCC → Annex B.
    fileprivate func handleEncodedOutput(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        guard status == noErr, let sampleBuffer else {
            if status != noErr {
                print("[H264Encoder] Output callback error: \(status)")
            }
            return
        }

        encodedData = extractAnnexBData(from: sampleBuffer)
    }

    // MARK: - AVCC → Annex B Conversion

    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    /// Extract H.264 Annex B data from a CMSampleBuffer (AVCC format).
    private func extractAnnexBData(from sampleBuffer: CMSampleBuffer) -> Data {
        var result = Data()

        let isKeyframe = isKeyFrame(sampleBuffer)

        // For keyframes, prepend SPS and PPS parameter sets
        if isKeyframe {
            if let paramData = extractParameterSets(from: sampleBuffer) {
                result.append(paramData)
            }
        }

        // Extract NAL units from the block buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return result
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard blockStatus == kCMBlockBufferNoErr, let dataPointer else {
            return result
        }

        // Walk AVCC-formatted NAL units (4-byte big-endian length prefix → NAL data)
        var offset = 0
        while offset < totalLength - 4 {
            // Read 4-byte big-endian NAL unit length
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, 4)
            nalLength = nalLength.bigEndian
            offset += 4

            guard nalLength > 0, offset + Int(nalLength) <= totalLength else {
                break
            }

            // Replace AVCC length prefix with Annex B start code
            result.append(Self.startCode)
            result.append(Data(bytes: dataPointer + offset, count: Int(nalLength)))
            offset += Int(nalLength)
        }

        return result
    }

    /// Check if the sample buffer contains a keyframe (IDR).
    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            // No attachments → assume keyframe (conservative)
            return true
        }
        // kCMSampleAttachmentKey_NotSync == true means NOT a keyframe
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    /// Extract SPS and PPS parameter sets from the format description.
    private func extractParameterSets(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        var result = Data()

        // SPS (index 0)
        var spsPointer: UnsafePointer<UInt8>?
        var spsLength = 0
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsLength,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        if spsStatus == noErr, let spsPointer {
            result.append(Self.startCode)
            result.append(Data(bytes: spsPointer, count: spsLength))
        }

        // PPS (index 1)
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsLength = 0
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsLength,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        if ppsStatus == noErr, let ppsPointer {
            result.append(Self.startCode)
            result.append(Data(bytes: ppsPointer, count: ppsLength))
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Helpers

    private func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            print("[H264Encoder] Failed to set \(key): \(status)")
        }
    }
}

// MARK: - C Output Callback

/// C function pointer for VTCompressionSession output callback.
/// Bridges back to the H264Encoder instance via the refcon pointer.
private func h264OutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedOutput(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}
