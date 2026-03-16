import ARKit
import CoreImage
import simd

/// On-device SLAM wrapper around RTAB-Map C++ library.
///
/// Provides loop closure detection, ICP refinement, and GTSAM pose graph
/// optimization on top of ARKit VIO. Runs headless (no rendering).
///
/// Usage:
///   1. Call `start()` at recording start
///   2. Call `processFrame()` at configured cadence (not every ARKit frame)
///   3. Read `mapToOdom` to correct ARKit poses: `correctedPose = mapToOdom * arkitPose`
///   4. Handle `onLoopClosure` to send retroactive corrections
///   5. Call `stop()` at recording end
/// Global reference for C callback (only one SLAM instance at a time)
private weak var _activeRTABMapSLAM: RTABMapSLAM?

private func _slamStatsCallback(
    _ nodesCount: Int32, _ wordsCount: Int32, _ databaseSize: Float,
    _ loopClosureId: Int32,
    _ x: Float, _ y: Float, _ z: Float,
    _ roll: Float, _ pitch: Float, _ yaw: Float
) {
    _activeRTABMapSLAM?.handleStatsUpdate(
        nodesCount: Int(nodesCount),
        wordsCount: Int(wordsCount),
        loopClosureId: Int(loopClosureId),
        x: x, y: y, z: z,
        roll: roll, pitch: pitch, yaw: yaw
    )
}

final class RTABMapSLAM {

    // MARK: - Public State

    /// The map-to-odom correction transform. Apply as: correctedPose = mapToOdom * arkitPose
    private(set) var mapToOdom: simd_float4x4 = matrix_identity_float4x4

    /// Whether the SLAM engine is currently running.
    private(set) var isRunning = false

    /// Callback when a loop closure is detected.
    /// Parameter: dictionary mapping frame_id (String, e.g. "ws_30") to corrected pose (16 floats, col-major).
    var onLoopClosure: (([String: [Float]]) -> Void)?

    // MARK: - Private

    private var nativePtr: UnsafeMutableRawPointer?
    private var databasePath: String?
    private let slamQueue = DispatchQueue(label: "com.calabiLens.slam", qos: .userInitiated)

    /// Map from RTAB-Map node ID → our frame_id for retroactive corrections
    private var nodeIdToFrameId: [Int: UInt64] = [:]
    private var currentFrameId: UInt64 = 0

    /// The ARKit odometry pose that was last fed to RTAB-Map.
    /// Needed to compute: mapToOdom = correctedPose * inverse(lastOdometryPose)
    private var lastOdometryPose: simd_float4x4 = matrix_identity_float4x4

    /// Reusable CIContext for YCbCr→BGRA conversion (expensive to create)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Target resolution for SLAM processing (full-res is way too slow on device)
    private static let slamWidth: Int = 480
    private static let slamHeight: Int = 360

    // --- Fix #2: Upstream relocalization filter ---
    // Detects sudden pose jumps from ARKit's internal relocalization and
    // substitutes a constant-velocity predicted pose to prevent graph corruption.
    private var prevFilteredPosition: simd_float3?
    private var prevVelocity: simd_float3?
    private var prevPoseTimestamp: Double = 0
    private var accumulatedTranslationOffset = simd_float3.zero
    /// Acceleration threshold: 6g ≈ 58.8 m/s² (matches official RTABMap app default)
    private static let relocAccThreshold: Float = 6.0 * 9.81

    // MARK: - Lifecycle

    /// Start the SLAM engine. Creates a fresh database in the temp directory.
    func start() {
        slamQueue.async { [weak self] in
            self?._start()
        }
    }

    private func _start() {
        guard !isRunning else { return }

        // Create fresh database in temp directory
        let dbName = "rtabmap_\(UUID().uuidString).db"
        let dbPath = NSTemporaryDirectory() + dbName
        databasePath = dbPath

        // Create native RTAB-Map instance
        let ptr = createNativeApplication()
        nativePtr = ptr

        // Setup stats callback (uses module-level function since C pointers can't capture context)
        _activeRTABMapSLAM = self
        setupCallbacksNative(ptr, _slamStatsCallback)

        // Disable rendering features (headless SLAM)
        setOnlineBlendingNative(ptr, false)

        // Enable graph optimization
        setGraphOptimizationNative(ptr, true)

        // Open fresh database
        openDatabaseNative(ptr, dbPath, true)

        nodeIdToFrameId.removeAll()
        isRunning = true

        print("[RTABMapSLAM] Started with database: \(dbPath)")
    }

    /// Stop the SLAM engine and clean up.
    func stop() {
        slamQueue.async { [weak self] in
            self?._stop()
        }
    }

    private func _stop() {
        guard isRunning else { return }
        isRunning = false

        if let ptr = nativePtr {
            destroyNativeApplication(ptr)
            nativePtr = nil
        }

        // Delete temporary database
        if let path = databasePath {
            try? FileManager.default.removeItem(atPath: path)
            databasePath = nil
        }

        mapToOdom = matrix_identity_float4x4
        lastOdometryPose = matrix_identity_float4x4
        nodeIdToFrameId.removeAll()

        // Reset relocalization filter state
        prevFilteredPosition = nil
        prevVelocity = nil
        prevPoseTimestamp = 0
        accumulatedTranslationOffset = .zero

        print("[RTABMapSLAM] Stopped and cleaned up")
    }

    // MARK: - Frame Processing

    /// Extracted frame data — copied off the ARFrame so we don't retain it across queues.
    private struct SLAMFrameData {
        let pose: [Float]           // 16 floats, col-major
        let transform: simd_float4x4
        let bgraPixels: Data        // downscaled BGRA bytes
        let rgbW: Int32
        let rgbH: Int32
        let depthPixels: Data       // float32 meters
        let depthW: Int32
        let depthH: Int32
        let fx: Float, fy: Float, cx: Float, cy: Float
        let timestamp: Double
        let frameId: UInt64
        let trackingNormal: Bool    // true if ARKit tracking is .normal
    }

    /// Process a single frame through RTAB-Map SLAM.
    ///
    /// Extracts pixel data synchronously (releasing the ARFrame), then dispatches
    /// the heavy RTAB-Map processing to the SLAM queue.
    func processFrame(frame: ARFrame, frameId: UInt64) {
        guard isRunning else { return }
        guard let sceneDepth = frame.sceneDepth else { return }

        // --- Extract everything from ARFrame on the caller's thread ---
        let camera = frame.camera
        let transform = camera.transform
        let intrinsics = camera.intrinsics

        // Column-major 4x4 pose
        var pose = [Float](repeating: 0, count: 16)
        for col in 0..<4 {
            for row in 0..<4 {
                pose[col * 4 + row] = transform[col][row]
            }
        }

        // Downscale YCbCr → BGRA at SLAM resolution
        let targetW = Self.slamWidth
        let targetH = Self.slamHeight
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(targetW) / CGFloat(CVPixelBufferGetWidth(frame.capturedImage)),
                y: CGFloat(targetH) / CGFloat(CVPixelBufferGetHeight(frame.capturedImage))
            ))

        var bgraBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: targetW,
            kCVPixelBufferHeightKey as String: targetH,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &bgraBuffer)
        guard let bgra = bgraBuffer else { return }
        ciContext.render(ciImage, to: bgra)

        // Copy BGRA pixels into Data
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        let bgraPtr = CVPixelBufferGetBaseAddress(bgra)!
        let bgraByteCount = CVPixelBufferGetBytesPerRow(bgra) * targetH
        let bgraData = Data(bytes: bgraPtr, count: bgraByteCount)
        CVPixelBufferUnlockBaseAddress(bgra, .readOnly)

        // Scale intrinsics to match downscaled resolution
        let origW = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let origH = Float(CVPixelBufferGetHeight(frame.capturedImage))
        let scaleX = Float(targetW) / origW
        let scaleY = Float(targetH) / origH
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY

        // Copy depth pixels into Data
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        let depthPtr = CVPixelBufferGetBaseAddress(depthMap)!
        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        let depthByteCount = depthW * depthH * MemoryLayout<Float>.size
        let depthData = Data(bytes: depthPtr, count: depthByteCount)
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)

        let isTrackingNormal: Bool
        if case .normal = camera.trackingState { isTrackingNormal = true } else { isTrackingNormal = false }

        // --- Data sheet: print every 60 SLAM frames for server alignment verification ---
        if frameId % 60 == 0 {
            // Depth stats (sample from copied data)
            let depthFloatCount = depthW * depthH
            var depthMin: Float = .greatestFiniteMagnitude
            var depthMax: Float = 0
            var depthSum: Double = 0
            var validCount = 0
            depthData.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for i in 0..<depthFloatCount {
                    let v = floats[i]
                    if v > 0 && v.isFinite {
                        depthMin = min(depthMin, v)
                        depthMax = max(depthMax, v)
                        depthSum += Double(v)
                        validCount += 1
                    }
                }
            }
            let depthMean = validCount > 0 ? Float(depthSum / Double(validCount)) : 0

            // Original (pre-scale) intrinsics
            let origFx = intrinsics[0][0]
            let origFy = intrinsics[1][1]
            let origCx = intrinsics[2][0]
            let origCy = intrinsics[2][1]

            print("""
            [SLAM-DATA-SHEET] frameId=\(frameId) timestamp=\(String(format: "%.6f", frame.timestamp))
              RGB: \(CVPixelBufferGetWidth(frame.capturedImage))x\(CVPixelBufferGetHeight(frame.capturedImage)) (YCbCr) → \(targetW)x\(targetH) (BGRA for SLAM)
              Depth: \(depthW)x\(depthH) format=Float32 unit=meters
              Depth stats: min=\(String(format: "%.3f", depthMin))m max=\(String(format: "%.3f", depthMax))m mean=\(String(format: "%.3f", depthMean))m valid=\(validCount)/\(depthFloatCount)
              Intrinsics (original \(CVPixelBufferGetWidth(frame.capturedImage))x\(CVPixelBufferGetHeight(frame.capturedImage))): fx=\(String(format: "%.2f", origFx)) fy=\(String(format: "%.2f", origFy)) cx=\(String(format: "%.2f", origCx)) cy=\(String(format: "%.2f", origCy))
              Intrinsics (scaled \(targetW)x\(targetH)): fx=\(String(format: "%.2f", fx)) fy=\(String(format: "%.2f", fy)) cx=\(String(format: "%.2f", cx)) cy=\(String(format: "%.2f", cy))
              ARKit pose (col-major, Y-up): t=(\(String(format: "%.4f", transform.columns.3.x)), \(String(format: "%.4f", transform.columns.3.y)), \(String(format: "%.4f", transform.columns.3.z)))
              ARKit pose R col0=(\(String(format: "%.4f", transform.columns.0.x)),\(String(format: "%.4f", transform.columns.0.y)),\(String(format: "%.4f", transform.columns.0.z))) col1=(\(String(format: "%.4f", transform.columns.1.x)),\(String(format: "%.4f", transform.columns.1.y)),\(String(format: "%.4f", transform.columns.1.z))) col2=(\(String(format: "%.4f", transform.columns.2.x)),\(String(format: "%.4f", transform.columns.2.y)),\(String(format: "%.4f", transform.columns.2.z)))
              Tracking: \(camera.trackingState) confidence=\(frame.sceneDepth?.confidenceMap != nil ? "available" : "none")
              BGRA bytesPerRow=\(CVPixelBufferGetBytesPerRow(bgra)) totalBytes=\(bgraByteCount)
              Depth bytesPerRow=\(CVPixelBufferGetBytesPerRow(depthMap)) totalBytes=\(depthByteCount)
            """)
        }

        let frameData = SLAMFrameData(
            pose: pose, transform: transform,
            bgraPixels: bgraData, rgbW: Int32(targetW), rgbH: Int32(targetH),
            depthPixels: depthData, depthW: Int32(depthW), depthH: Int32(depthH),
            fx: fx, fy: fy, cx: cx, cy: cy,
            timestamp: frame.timestamp, frameId: frameId,
            trackingNormal: isTrackingNormal
        )

        // --- Dispatch heavy processing (no ARFrame reference held) ---
        slamQueue.async { [weak self] in
            self?._processFrameData(frameData)
        }
    }

    private func _processFrameData(_ data: SLAMFrameData) {
        guard isRunning, let ptr = nativePtr else { return }

        currentFrameId = data.frameId

        var pose = data.pose

        // --- Fix #2: Upstream relocalization filter ---
        let relocFiltered = applyRelocalizationFilter(&pose, timestamp: data.timestamp)

        // Tracking quality: 0 = degraded, 2 = normal
        let trackingQuality: Int32
        if !data.trackingNormal || relocFiltered {
            trackingQuality = 0
        } else {
            trackingQuality = 2
        }

        // Update lastOdometryPose with the (potentially filtered) pose
        lastOdometryPose = makeSimdFromColMajor(pose)

        data.bgraPixels.withUnsafeBytes { bgraRaw in
            data.depthPixels.withUnsafeBytes { depthRaw in
                let rgbPtr = bgraRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let depthPtr = depthRaw.baseAddress!.assumingMemoryBound(to: Float.self)

                postOdometryEventNative(
                    ptr,
                    &pose,
                    rgbPtr, data.rgbW, data.rgbH,
                    depthPtr, data.depthW, data.depthH,
                    data.fx, data.fy, data.cx, data.cy,
                    data.timestamp,
                    trackingQuality
                )
            }
        }
    }

    // MARK: - Upstream Relocalization Filter

    /// Detects sudden pose jumps from ARKit's internal relocalization by measuring
    /// acceleration. When a jump exceeds the threshold, substitutes a constant-velocity
    /// predicted position to prevent SLAM graph corruption.
    ///
    /// Returns `true` if the pose was filtered (relocalization detected).
    private func applyRelocalizationFilter(_ pose: inout [Float], timestamp: Double) -> Bool {
        // Apply accumulated translation offset from previous filterings
        var pos = simd_float3(pose[12], pose[13], pose[14]) + accumulatedTranslationOffset
        let dt = Float(timestamp - prevPoseTimestamp)

        defer {
            prevPoseTimestamp = timestamp
        }

        guard dt > 0, let prevPos = prevFilteredPosition else {
            // First frame — initialize state
            prevFilteredPosition = pos
            prevPoseTimestamp = timestamp
            pose[12] = pos.x; pose[13] = pos.y; pose[14] = pos.z
            return false
        }

        let velocity = (pos - prevPos) / dt

        if let prevVel = prevVelocity {
            let acceleration = (velocity - prevVel) / dt
            let accMagnitude = length(acceleration)
            let distance = length(pos - prevPos)

            if accMagnitude >= Self.relocAccThreshold && distance > 0.02 {
                // Upstream relocalization detected — use constant velocity prediction
                let predictedPos = prevPos + prevVel * dt
                let correction = predictedPos - pos
                accumulatedTranslationOffset += correction
                pos = predictedPos

                prevFilteredPosition = pos
                // Keep previous velocity (constant velocity model)
                print("[RTABMapSLAM] Upstream relocalization filtered (acc=\(String(format: "%.1f", accMagnitude)) m/s², dist=\(String(format: "%.3f", distance))m)")
                pose[12] = pos.x; pose[13] = pos.y; pose[14] = pos.z
                return true
            }
        }

        prevFilteredPosition = pos
        prevVelocity = velocity
        pose[12] = pos.x; pose[13] = pos.y; pose[14] = pos.z
        return false
    }

    /// Reconstruct a simd_float4x4 from a 16-float column-major array.
    private func makeSimdFromColMajor(_ m: [Float]) -> simd_float4x4 {
        return simd_float4x4(columns: (
            simd_float4(m[0], m[1], m[2], m[3]),
            simd_float4(m[4], m[5], m[6], m[7]),
            simd_float4(m[8], m[9], m[10], m[11]),
            simd_float4(m[12], m[13], m[14], m[15])
        ))
    }

    // MARK: - Stats Callback

    fileprivate func handleStatsUpdate(
        nodesCount: Int,
        wordsCount: Int,
        loopClosureId: Int,
        x: Float, y: Float, z: Float,
        roll: Float, pitch: Float, yaw: Float
    ) {
        print("[SLAM] nodes=\(nodesCount) words=\(wordsCount) loopId=\(loopClosureId) pos=(\(String(format: "%.3f", x)),\(String(format: "%.3f", y)),\(String(format: "%.3f", z)))")

        // Store the current frame_id → node_id mapping
        nodeIdToFrameId[nodesCount] = currentFrameId

        // Only update mapToOdom when a loop closure is detected.
        // Without loop closure, RTAB-Map's reported pose is its own odometry estimate
        // which diverges slightly from ARKit's — applying that as a "correction" causes
        // frame-to-frame jitter and the "multiple layers" effect.
        if loopClosureId > 0 {
            let correctedPose = makeTransform(x: x, y: y, z: z,
                                               roll: roll, pitch: pitch, yaw: yaw)
            let odomInverse = lastOdometryPose.inverse
            mapToOdom = correctedPose * odomInverse

            print("[RTABMapSLAM] Loop closure detected (id: \(loopClosureId)), mapToOdom updated")
            handleLoopClosure()
        }
    }

    private func handleLoopClosure() {
        guard let ptr = nativePtr else { return }

        // Query all optimized poses from RTAB-Map
        let maxPoses = 10000
        var posesBuffer = [Float](repeating: 0, count: maxPoses * 7)
        let count = getOptimizedPosesNative(ptr, &posesBuffer, Int32(maxPoses))

        guard count > 0 else { return }

        // Build corrections dictionary: frame_id → [16 floats col-major]
        var corrections: [String: [Float]] = [:]

        for i in 0..<Int(count) {
            let base = i * 7
            let x = posesBuffer[base + 0]
            let y = posesBuffer[base + 1]
            let z = posesBuffer[base + 2]
            let roll = posesBuffer[base + 3]
            let pitch = posesBuffer[base + 4]
            let yaw = posesBuffer[base + 5]
            let nodeId = Int(posesBuffer[base + 6])

            // Look up our frame_id for this RTAB-Map node
            guard let frameId = nodeIdToFrameId[nodeId] else { continue }

            // Convert Euler → 4x4 column-major
            let t = makeTransform(x: x, y: y, z: z, roll: roll, pitch: pitch, yaw: yaw)
            var colMajor = [Float](repeating: 0, count: 16)
            for col in 0..<4 {
                for row in 0..<4 {
                    colMajor[col * 4 + row] = t[col][row]
                }
            }

            // Use the WebSocket frame_id format: "ws_<frame_id>"
            corrections["ws_\(frameId)"] = colMajor
        }

        if !corrections.isEmpty {
            print("[RTABMapSLAM] Pose corrections sent for \(corrections.count) keyframes")
            onLoopClosure?(corrections)
        }
    }

    // MARK: - Math Helpers

    /// Build a 4x4 transform from position + Euler angles.
    private func makeTransform(x: Float, y: Float, z: Float,
                                roll: Float, pitch: Float, yaw: Float) -> simd_float4x4 {
        // Rotation matrices
        let cr = cos(roll),  sr = sin(roll)
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw),   sy = sin(yaw)

        // ZYX Euler convention (yaw-pitch-roll)
        let r00 = cy * cp
        let r01 = cy * sp * sr - sy * cr
        let r02 = cy * sp * cr + sy * sr
        let r10 = sy * cp
        let r11 = sy * sp * sr + cy * cr
        let r12 = sy * sp * cr - cy * sr
        let r20 = -sp
        let r21 = cp * sr
        let r22 = cp * cr

        return simd_float4x4(columns: (
            simd_float4(r00, r10, r20, 0),
            simd_float4(r01, r11, r21, 0),
            simd_float4(r02, r12, r22, 0),
            simd_float4(x,   y,   z,   1)
        ))
    }
}
