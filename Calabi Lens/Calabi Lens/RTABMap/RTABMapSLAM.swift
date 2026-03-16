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

        print("[RTABMapSLAM] Stopped and cleaned up")
    }

    // MARK: - Frame Processing

    /// Process a single frame through RTAB-Map SLAM.
    ///
    /// Call this at the configured SLAM cadence (not every ARKit frame).
    /// The `mapToOdom` transform is updated after processing.
    ///
    /// - Parameters:
    ///   - frame: The ARKit frame to process
    ///   - frameId: The frame_id from the encoding pipeline (for mapping corrections)
    func processFrame(frame: ARFrame, frameId: UInt64) {
        slamQueue.async { [weak self] in
            self?._processFrame(frame: frame, frameId: frameId)
        }
    }

    private func _processFrame(frame: ARFrame, frameId: UInt64) {
        guard isRunning, let ptr = nativePtr else { return }
        guard let sceneDepth = frame.sceneDepth else { return }

        currentFrameId = frameId

        let camera = frame.camera
        let transform = camera.transform
        let intrinsics = camera.intrinsics

        // Store the odometry pose for mapToOdom computation
        lastOdometryPose = transform

        // Extract column-major 4x4 pose
        var pose: [Float] = [Float](repeating: 0, count: 16)
        for col in 0..<4 {
            for row in 0..<4 {
                pose[col * 4 + row] = transform[col][row]
            }
        }

        // Convert YCbCr (NV12) capturedImage to BGRA using CoreImage
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rgbW = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let rgbH = Int32(CVPixelBufferGetHeight(pixelBuffer))

        // Render CIImage to a BGRA pixel buffer
        var bgraBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(rgbW),
            kCVPixelBufferHeightKey as String: Int(rgbH),
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(rgbW), Int(rgbH),
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &bgraBuffer)
        guard let bgra = bgraBuffer else { return }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        ciContext.render(ciImage, to: bgra)

        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        let rgbData = CVPixelBufferGetBaseAddress(bgra)!
            .assumingMemoryBound(to: UInt8.self)

        // Get depth data (float32 meters)
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        let depthData = CVPixelBufferGetBaseAddress(depthMap)!
            .assumingMemoryBound(to: Float.self)
        let depthW = Int32(CVPixelBufferGetWidth(depthMap))
        let depthH = Int32(CVPixelBufferGetHeight(depthMap))

        // Post to RTAB-Map
        postOdometryEventNative(
            ptr,
            &pose,
            rgbData, rgbW, rgbH,
            depthData, depthW, depthH,
            intrinsics[0][0], intrinsics[1][1],
            intrinsics[2][0], intrinsics[2][1],
            frame.timestamp
        )

        CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
    }

    // MARK: - Stats Callback

    fileprivate func handleStatsUpdate(
        nodesCount: Int,
        wordsCount: Int,
        loopClosureId: Int,
        x: Float, y: Float, z: Float,
        roll: Float, pitch: Float, yaw: Float
    ) {
        print("[RTABMapSLAM] handleStatsUpdate: nodes=\(nodesCount) loopId=\(loopClosureId) pos=(\(x),\(y),\(z))")
        // Build corrected pose from Euler angles
        let correctedPose = makeTransform(x: x, y: y, z: z,
                                           roll: roll, pitch: pitch, yaw: yaw)

        // Store the current frame_id → node_id mapping
        nodeIdToFrameId[nodesCount] = currentFrameId

        // Compute mapToOdom (the correction transform):
        //   correctedPose = mapToOdom * odometryPose
        //   => mapToOdom = correctedPose * inverse(odometryPose)
        //
        // This correction is then applied to ALL frames (not just SLAM-processed ones):
        //   anyFrameCorrected = mapToOdom * anyFrameARKitPose
        let odomInverse = lastOdometryPose.inverse
        mapToOdom = correctedPose * odomInverse

        // Handle loop closure
        if loopClosureId > 0 {
            print("[RTABMapSLAM] Loop closure detected (id: \(loopClosureId))")
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
