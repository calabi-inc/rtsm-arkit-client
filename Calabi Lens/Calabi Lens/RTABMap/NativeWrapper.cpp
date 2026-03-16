/*
 * NativeWrapper.cpp — C++ implementations for the RTAB-Map SLAM bridge.
 *
 * Based on the official RTAB-Map iOS app. Trimmed to headless SLAM only:
 * no rendering, no mesh export, no OpenGL.
 *
 * The RTABMapApp class is from RTAB-Map's app/ios/RTABMapApp/RTABMapApp.h.
 * It manages the full SLAM pipeline: feature extraction, BoW, loop closure,
 * ICP refinement, and GTSAM pose graph optimization.
 */

// Ensure POSIX types (timespec) are available before C++ threading headers
#include <time.h>
#include <sys/types.h>

#include "NativeWrapper.hpp"

#include <rtabmap/core/Rtabmap.h>
#include <rtabmap/core/OdometryEvent.h>
#include <rtabmap/core/SensorData.h>
#include <rtabmap/core/util3d.h>
#include <rtabmap/core/util3d_transforms.h>
#include <rtabmap/core/CameraModel.h>
#include <rtabmap/core/Memory.h>
#include <rtabmap/utilite/ULogger.h>
#include <rtabmap/utilite/UEventsHandler.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <mutex>
#include <map>

// ──────────────────── Coordinate Frame Constants ────────────────────
//
// ARKit/OpenGL world: X-right, Y-up, Z-toward-viewer
// RTABMap world:      X-forward, Y-left, Z-up
//
// These transforms convert poses between the two conventions.
// Applied as: rtabmapPose = rtabmap_world_T_opengl_world * arkitPose * opengl_world_T_rtabmap_world

static const rtabmap::Transform rtabmap_world_T_opengl_world(
     0,  0, -1, 0,
    -1,  0,  0, 0,
     0,  1,  0, 0);

static const rtabmap::Transform opengl_world_T_rtabmap_world(
     0, -1,  0, 0,
     0,  0,  1, 0,
    -1,  0,  0, 0);

// Camera optical rotation: maps camera optical frame → device body frame.
// Required by CameraModel so RTABMap knows the sensor orientation.
static const rtabmap::Transform opticalRotation(
     0,  0,  1, 0,
    -1,  0,  0, 0,
     0, -1,  0, 0);

// ──────────────────── RTABMapApp (Headless SLAM) ────────────────────

class RTABMapApp {
public:
    RTABMapApp()
        : rtabmap_(new rtabmap::Rtabmap()),
          statsCallback_(nullptr),
          nodesCount_(0),
          wordsCount_(0),
          databaseSize_(0.0f),
          graphOptimization_(true),
          isFirstFrame_(true) {}

    ~RTABMapApp() {
        close();
        delete rtabmap_;
    }

    void setStatsCallback(StatsCallback callback) {
        statsCallback_ = callback;
    }

    void openDatabase(const char* databasePath, bool clearDatabase) {
        std::lock_guard<std::mutex> lock(mutex_);

        // Configure RTAB-Map parameters for on-device SLAM
        rtabmap::ParametersMap params;

        // Memory management
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemRehearsalSimilarity(), "0.6"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemImageKept(), "false"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemBinDataKept(), "false"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemNotLinkedNodesKept(), "false"));

        // Loop closure
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRtabmapDetectionRate(), "2"));  // Max 2 Hz
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRtabmapTimeThr(), "0"));

        // Feature detection (ORB for speed on mobile)
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kKpDetectorStrategy(), "6"));  // ORB
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kKpMaxFeatures(), "200"));
        // kKpWordsPerImage removed in 0.21; kKpMaxFeatures controls this

        // Graph optimization (GTSAM)
        if (graphOptimization_) {
            params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerStrategy(), "2"));  // GTSAM
            params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerIterations(), "10"));
        }

        // ICP refinement at loop closure
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRegStrategy(), "1"));  // ICP
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kIcpCorrespondenceRatio(), "0.2"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kIcpMaxCorrespondenceDistance(), "0.05"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kIcpIterations(), "30"));

        // Proximity detection
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDProximityBySpace(), "true"));

        // --- Fix #5: Missing parameters from official app ---

        // Visual matching
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kVisMinInliers(), "25"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kVisMaxFeatures(), "200"));

        // Loop closure threshold
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRtabmapLoopThr(), "0.11"));

        // Graph optimization direction (optimize from latest node)
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDOptimizeFromGraphEnd(), "true"));

        // Node insertion rate thresholds (prevents redundant nodes)
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDLinearUpdate(), "0.05"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDAngularUpdate(), "0.05"));

        // Gravity constraints from ARKit IMU
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemUseOdomGravity(), "true"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerGravitySigma(), "0.2"));

        // ICP safety bounds
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kIcpPointToPlane(), "true"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kIcpMaxRotation(), "0.17"));

        // Speed-based outlier rejection
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDLinearSpeedUpdate(), "1.0"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDAngularSpeedUpdate(), "0.5"));

        isFirstFrame_ = true;

        rtabmap_->init(params, databasePath);

        if (clearDatabase) {
            rtabmap_->resetMemory();
        }
    }

    void setGraphOptimization(bool enabled) {
        graphOptimization_ = enabled;
    }

    void setOnlineBlending(bool /*enabled*/) {
        // No-op for headless SLAM (no rendering)
    }

    void postOdometryEvent(
        float pose[16],
        const unsigned char* rgbData, int rgbW, int rgbH,
        const float* depthData, int depthW, int depthH,
        float fx, float fy, float cx, float cy,
        double stampSeconds,
        int trackingQuality
    ) {
        std::lock_guard<std::mutex> lock(mutex_);

        // Build camera transform from column-major 4x4
        rtabmap::Transform cameraPose(
            pose[0], pose[4], pose[8],  pose[12],
            pose[1], pose[5], pose[9],  pose[13],
            pose[2], pose[6], pose[10], pose[14]
        );

        if (cameraPose.isNull()) {
            return;
        }

        // --- Fix #3: Convert ARKit (OpenGL) pose → RTABMap coordinate frame ---
        cameraPose = rtabmap_world_T_opengl_world * cameraPose * opengl_world_T_rtabmap_world;

        // Build RGB cv::Mat (BGRA → BGR)
        cv::Mat rgb(rgbH, rgbW, CV_8UC4, const_cast<unsigned char*>(rgbData));
        cv::Mat bgr;
        cv::cvtColor(rgb, bgr, cv::COLOR_BGRA2BGR);

        // Build depth cv::Mat (float32 meters)
        cv::Mat depth(depthH, depthW, CV_32FC1, const_cast<float*>(depthData));

        // --- Fix #1: Use optical rotation instead of identity ---
        rtabmap::CameraModel model(fx, fy, cx, cy,
            opticalRotation, 0,
            cv::Size(rgbW, rgbH));

        // Build SensorData
        rtabmap::SensorData data(bgr, depth, model, 0, stampSeconds);

        // --- Fix #4: Build covariance based on tracking quality ---
        cv::Mat covariance;
        if (isFirstFrame_) {
            covariance = cv::Mat::eye(6, 6, CV_64FC1) * 9999.0;
            isFirstFrame_ = false;
        } else {
            covariance = cv::Mat::eye(6, 6, CV_64FC1) * 0.00001;
            // Roll/pitch: 100x more confident (ARKit IMU fusion is excellent for these)
            covariance.at<double>(3, 3) *= 0.01;
            covariance.at<double>(4, 4) *= 0.01;
            if (trackingQuality < 2) {
                // Degraded tracking or upstream relocalization filtered:
                // inflate translation + yaw uncertainty by 10x
                covariance.at<double>(0, 0) *= 10.0;
                covariance.at<double>(1, 1) *= 10.0;
                covariance.at<double>(2, 2) *= 10.0;
                covariance.at<double>(5, 5) *= 10.0;
            }
        }

        // Process through RTAB-Map with covariance
        rtabmap_->process(data, cameraPose, covariance);

        // Extract stats
        const rtabmap::Statistics& stats = rtabmap_->getStatistics();
        nodesCount_ = static_cast<int>(rtabmap_->getMemory()->getWorkingMem().size() +
                                        rtabmap_->getMemory()->getStMem().size());
        const auto& statsData = stats.data();
        auto it = statsData.find(rtabmap::Statistics::kKeypointDictionary_size());
        wordsCount_ = (it != statsData.end()) ? static_cast<int>(it->second) : 0;

        int loopClosureId = stats.loopClosureId();

        // Get corrected pose (in RTABMap frame), convert back to ARKit frame
        rtabmap::Transform correctedRtabmap = stats.mapCorrection() * cameraPose;
        rtabmap::Transform correctedArkit = opengl_world_T_rtabmap_world * correctedRtabmap * rtabmap_world_T_opengl_world;
        float x = correctedArkit.x();
        float y = correctedArkit.y();
        float z = correctedArkit.z();
        float roll, pitch, yaw;
        correctedArkit.getEulerAngles(roll, pitch, yaw);

        // Store map correction for external use
        mapCorrection_ = stats.mapCorrection();

        // Store optimized poses if loop closure detected
        if (loopClosureId > 0) {
            optimizedPoses_ = rtabmap_->getLocalOptimizedPoses();
        }

        if (statsCallback_) {
            statsCallback_(
                nodesCount_, wordsCount_, databaseSize_,
                loopClosureId,
                x, y, z, roll, pitch, yaw
            );
        }
    }

    int getNodesCount() const {
        return nodesCount_;
    }

    int getOptimizedPoses(float* outPoses, int maxPoses) {
        std::lock_guard<std::mutex> lock(mutex_);

        int count = 0;
        const auto& poses = rtabmap_->getLocalOptimizedPoses();
        for (const auto& pair : poses) {
            if (count >= maxPoses) break;

            // Convert from RTABMap frame back to ARKit frame
            const rtabmap::Transform arkit = opengl_world_T_rtabmap_world * pair.second * rtabmap_world_T_opengl_world;
            float roll, pitch, yaw;
            arkit.getEulerAngles(roll, pitch, yaw);

            int idx = count * 7;
            outPoses[idx + 0] = arkit.x();
            outPoses[idx + 1] = arkit.y();
            outPoses[idx + 2] = arkit.z();
            outPoses[idx + 3] = roll;
            outPoses[idx + 4] = pitch;
            outPoses[idx + 5] = yaw;
            outPoses[idx + 6] = static_cast<float>(pair.first);
            count++;
        }
        return count;
    }

    void close() {
        std::lock_guard<std::mutex> lock(mutex_);
        rtabmap_->close();
    }

private:
    rtabmap::Rtabmap* rtabmap_;
    StatsCallback statsCallback_;
    std::mutex mutex_;

    int nodesCount_;
    int wordsCount_;
    float databaseSize_;
    bool graphOptimization_;
    bool isFirstFrame_;

    rtabmap::Transform mapCorrection_;
    std::map<int, rtabmap::Transform> optimizedPoses_;
};

// ──────────────────── C Extern Implementations ────────────────────

void* createNativeApplication(void) {
    return new RTABMapApp();
}

void setupCallbacksNative(void* app, StatsCallback callback) {
    static_cast<RTABMapApp*>(app)->setStatsCallback(callback);
}

void openDatabaseNative(void* app, const char* databasePath, bool clearDatabase) {
    static_cast<RTABMapApp*>(app)->openDatabase(databasePath, clearDatabase);
}

void setGraphOptimizationNative(void* app, bool enabled) {
    static_cast<RTABMapApp*>(app)->setGraphOptimization(enabled);
}

void setOnlineBlendingNative(void* app, bool enabled) {
    static_cast<RTABMapApp*>(app)->setOnlineBlending(enabled);
}

void postOdometryEventNative(
    void* app,
    float pose[16],
    const unsigned char* rgbData, int rgbWidth, int rgbHeight,
    const float* depthData, int depthWidth, int depthHeight,
    float fx, float fy, float cx, float cy,
    double stampSeconds,
    int trackingQuality
) {
    static_cast<RTABMapApp*>(app)->postOdometryEvent(
        pose, rgbData, rgbWidth, rgbHeight,
        depthData, depthWidth, depthHeight,
        fx, fy, cx, cy, stampSeconds, trackingQuality
    );
}

int getNodesCountNative(void* app) {
    return static_cast<RTABMapApp*>(app)->getNodesCount();
}

int getOptimizedPosesNative(void* app, float* outPoses, int maxPoses) {
    return static_cast<RTABMapApp*>(app)->getOptimizedPoses(outPoses, maxPoses);
}

void destroyNativeApplication(void* app) {
    delete static_cast<RTABMapApp*>(app);
}
