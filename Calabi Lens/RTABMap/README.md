# RTAB-Map iOS Integration — Build & Setup Guide

## Overview

This directory contains build scripts and configuration for integrating RTAB-Map's C++ SLAM library into the Calabi Lens iOS app. RTAB-Map runs on-device as a headless SLAM engine, providing loop closure detection, ICP refinement, and GTSAM pose graph optimization on top of ARKit's VIO.

## Prerequisites

- **macOS** with Xcode 15+ and Command Line Tools
- **CMake 3.24+**: `brew install cmake`
- **git**
- **~10 GB** free disk space (sources + build artifacts)
- **iPhone with LiDAR** (iPhone 12 Pro or newer) for testing

## Step 1: Build Dependencies

```bash
cd "Calabi Lens/RTABMap/build"
chmod +x install_deps.sh
./install_deps.sh
```

This cross-compiles all dependencies as static arm64 iOS libraries:

| Library      | Version | Purpose                              |
|-------------|---------|--------------------------------------|
| Boost       | 1.88.0  | Smart pointers, threads, serialization |
| Eigen       | 3.4.0   | Linear algebra (header-only)         |
| OpenCV      | 4.11.0  | Feature extraction, BoW, image proc  |
| GTSAM       | 4.2     | Pose graph optimization              |
| FLANN       | 1.9.2   | Nearest neighbor search              |
| LZ4         | 1.10.0  | Compression                          |
| SuiteSparse | 7.6.1   | Sparse linear algebra (GTSAM dep)    |
| RTAB-Map    | 0.21.8  | SLAM core                            |

Build time: ~30-60 minutes depending on your Mac.

Output location:
```
build/output/ios/arm64/
├── lib/          # Static libraries (.a files)
└── include/      # Headers
```

## Step 2: Xcode Project Configuration

### 2a. Add Static Libraries

1. Open `Calabi Lens.xcodeproj` in Xcode
2. Select the **Calabi Lens** target → **Build Phases** tab
3. Expand **Link Binary With Libraries** and click **+**
4. Click **Add Other... → Add Files...** and navigate to `RTABMap/build/output/ios/arm64/lib/`
5. Select all `.a` files:
   - `librtabmap_core.a`
   - `librtabmap_utilite.a`
   - `libgtsam.a`
   - `libopencv_core.a`
   - `libopencv_features2d.a`
   - `libopencv_xfeatures2d.a`
   - `libopencv_flann.a`
   - `libopencv_imgproc.a`
   - `libopencv_imgcodecs.a`
   - `libopencv_calib3d.a`
   - `libflann_cpp_s.a`
   - `liblz4.a`
   - `libcholmod.a`
   - `libamd.a`
   - `libcamd.a`
   - `libcolamd.a`
   - `libccolamd.a`
   - `libsuitesparseconfig.a`
   - `libboost_thread.a`
   - `libboost_system.a`
   - `libboost_chrono.a`
   - `libboost_serialization.a`
   - `libboost_regex.a`
   - `libboost_graph.a`
6. Also add these system frameworks (click **+** → search):
   - `Accelerate.framework`
   - `libc++.tbd`
   - `libsqlite3.tbd`
   - `libz.tbd`

### 2b. Add Header Search Paths

1. Select target → **Build Settings** tab
2. Search for **Header Search Paths**
3. Add (recursive):
   ```
   $(PROJECT_DIR)/../RTABMap/build/output/ios/arm64/include
   ```

### 2c. Add Library Search Paths

1. Search for **Library Search Paths**
2. Add:
   ```
   $(PROJECT_DIR)/../RTABMap/build/output/ios/arm64/lib
   ```

### 2d. Configure Bridging Header

1. Search for **Objective-C Bridging Header**
2. Set to:
   ```
   Calabi Lens/Calabi Lens-Bridging-Header.h
   ```

### 2e. Add C++ Files to Build

1. In Xcode's Project Navigator, right-click the `RTABMap` group
2. **Add Files to "Calabi Lens"...**
3. Select `NativeWrapper.cpp` and `NativeWrapper.hpp`
4. Ensure **Target Membership** is checked for `Calabi Lens`

### 2f. Enable C++ Interop

1. Search for **Other Linker Flags**
2. Add: `-lstdc++`
3. Search for **Apple Clang - Language - C++** → **C++ Language Dialect**
4. Set to: **C++17** (`-std=c++17`)

## Step 3: Build & Deploy

1. Connect your iPhone via USB
2. Select your device as the build target (not a simulator — arm64 only)
3. **Product → Build** (Cmd+B)
4. If build succeeds, **Product → Run** (Cmd+R) to deploy

### Common Build Issues

| Issue | Fix |
|-------|-----|
| `Undefined symbols for architecture arm64` | Missing static library in Link Binary With Libraries |
| `'rtabmap/core/Rtabmap.h' file not found` | Check Header Search Paths includes the output/include directory |
| `ld: framework not found Accelerate` | Add Accelerate.framework in Link Binary With Libraries |
| `duplicate symbol` | Ensure you're not linking both static and dynamic versions |
| Build works but crashes on launch | Check that all GTSAM/SuiteSparse libs are linked |

## Step 4: Verify Integration

1. Launch the app on your iPhone
2. Go to **Settings → SLAM Mode → RTAB-Map**
3. Connect to server and start recording
4. Walk around a room, then return to your starting position
5. Check the console for:
   - `[RTABMapSLAM] Started` — SLAM engine initialized
   - `[RTABMapSLAM] Loop closure detected (id: N)` — Loop closure found
   - `[RTABMapSLAM] Pose corrections sent for N keyframes` — Corrections sent

## Architecture

```
ARKit VIO + LiDAR depth
    │
    ▼
RTABMapSLAM.swift (configurable cadence: 0.5-10 Hz)
    │
    ├── postOdometryEventNative(pose, rgb, depth, intrinsics)
    │
    ▼
RTAB-Map C++ (on-device, headless)
    ├── Feature extraction (ORB)
    ├── Bag-of-Words loop closure detection
    ├── ICP refinement at closure seams
    └── GTSAM pose graph optimization
    │
    ▼
statsUpdatedCallback
    ├── correctedPose → mapToOdom correction
    └── loopClosureId > 0 → query all optimized poses
    │
    ▼
Calabi Lens WebSocket streamer
    ├── T_wc = mapToOdom × ARKit pose (corrected)
    ├── pose_source = "rtabmap_slam"
    └── On loop closure: send pose_corrections text message
```
