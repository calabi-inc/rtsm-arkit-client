/*
 * NativeWrapper.hpp — C extern bridge between Swift and RTAB-Map C++ SLAM.
 *
 * Based on the official RTAB-Map iOS app NativeWrapper, trimmed to SLAM-only
 * functions (no rendering, no mesh export).
 *
 * This header is included by the Objective-C bridging header so Swift can call
 * these functions directly.
 */

#ifndef NativeWrapper_hpp
#define NativeWrapper_hpp

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Stats callback signature.
 *
 * Called by RTAB-Map after processing each frame with updated SLAM state.
 *
 * Parameters:
 *   nodesCount        — Total nodes in the SLAM graph
 *   wordsCount        — Total visual words
 *   databaseSize      — Database size in MB
 *   loopClosureId     — ID of the loop closure node (0 if none detected)
 *   x, y, z           — Corrected position (meters, world frame)
 *   roll, pitch, yaw  — Corrected orientation (radians)
 */
typedef void (*StatsCallback)(
    int nodesCount,
    int wordsCount,
    float databaseSize,
    int loopClosureId,
    float x, float y, float z,
    float roll, float pitch, float yaw
);

/*
 * Create a new headless RTAB-Map application instance.
 * Returns an opaque pointer to the C++ RTABMapApp object.
 */
void* createNativeApplication(void);

/*
 * Register the stats callback for receiving corrected poses and SLAM state.
 * Must be called before openDatabaseNative.
 */
void setupCallbacksNative(void* app, StatsCallback callback);

/*
 * Open (or create) a SLAM database at the given path.
 * Must be called before posting odometry events.
 *
 * Parameters:
 *   databasePath — Full filesystem path for the .db file.
 *   clearDatabase — If true, delete existing data and start fresh.
 */
void openDatabaseNative(void* app, const char* databasePath, bool clearDatabase);

/*
 * Enable or disable graph optimization.
 * Default: enabled. Disable for debugging only.
 */
void setGraphOptimizationNative(void* app, bool enabled);

/*
 * Set online blending mode. Disable for headless SLAM (no rendering).
 */
void setOnlineBlendingNative(void* app, bool enabled);

/*
 * Post an odometry event (one camera frame) to RTAB-Map for SLAM processing.
 *
 * Parameters:
 *   pose            — 16 floats, column-major 4x4 transform (ARKit camera.transform)
 *   rgbData         — Pointer to RGB pixel data (BGRA8 format)
 *   rgbWidth        — Width of the RGB image
 *   rgbHeight       — Height of the RGB image
 *   depthData       — Pointer to depth data (Float32, meters)
 *   depthWidth      — Width of the depth map
 *   depthHeight     — Height of the depth map
 *   fx, fy, cx, cy  — Camera intrinsics
 *   stampSeconds    — Frame timestamp in seconds (ARFrame.timestamp)
 */
void postOdometryEventNative(
    void* app,
    float pose[16],
    const unsigned char* rgbData,
    int rgbWidth,
    int rgbHeight,
    const float* depthData,
    int depthWidth,
    int depthHeight,
    float fx, float fy,
    float cx, float cy,
    double stampSeconds
);

/*
 * Get the number of optimized nodes currently in working memory.
 * Useful for knowing how many corrected poses are available after loop closure.
 */
int getNodesCountNative(void* app);

/*
 * Get all optimized poses from the SLAM graph.
 *
 * Parameters:
 *   outPoses    — Pre-allocated buffer for pose data. Each pose is 7 floats:
 *                 [x, y, z, roll, pitch, yaw, nodeId].
 *   maxPoses    — Maximum number of poses to return (size of outPoses / 7).
 *
 * Returns:
 *   Number of poses written to outPoses.
 */
int getOptimizedPosesNative(void* app, float* outPoses, int maxPoses);

/*
 * Destroy the RTAB-Map application instance and free resources.
 */
void destroyNativeApplication(void* app);

#ifdef __cplusplus
}
#endif

#endif /* NativeWrapper_hpp */
