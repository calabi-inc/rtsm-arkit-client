#!/bin/bash
# ──────────────────────────────────────────────────────────────
# install_deps.sh — Build RTAB-Map + minimal dependencies for iOS (arm64)
#
# Based on the official RTAB-Map iOS app install_deps.sh:
#   https://github.com/introlab/rtabmap/blob/master/app/ios/RTABMapApp/install_deps.sh
#
# Trimmed to SLAM-only (no visualization): excludes g2o, VTK, PCL, LASzip, libLAS.
#
# Usage:
#   cd "Calabi Lens/RTABMap/build"
#   chmod +x install_deps.sh
#   ./install_deps.sh
#
# Requirements:
#   - macOS with Xcode and Command Line Tools installed
#   - CMake 3.24+ (brew install cmake)
#   - git
#   - ~10 GB disk space for sources + build artifacts
#
# Output:
#   ./output/ios/arm64/lib/*.a   — Static libraries
#   ./output/ios/arm64/include/  — Headers
# ──────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build_tmp"
OUTPUT_DIR="$SCRIPT_DIR/output/ios/arm64"
NCPU=$(sysctl -n hw.ncpu)

IOS_DEPLOYMENT_TARGET="16.0"
IOS_ARCH="arm64"

# Common CMake toolchain flags for iOS cross-compilation
IOS_CMAKE_FLAGS=(
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_ARCHITECTURES=$IOS_ARCH
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET
    -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include"

echo "=== RTAB-Map iOS Dependency Builder ==="
echo "Build dir:  $BUILD_DIR"
echo "Output dir: $OUTPUT_DIR"
echo "CPUs:       $NCPU"
echo "iOS target: $IOS_DEPLOYMENT_TARGET ($IOS_ARCH)"
echo ""

# ──────────────────── 1. Boost 1.88.0 ────────────────────
BOOST_VER="1.88.0"
BOOST_VER_US="1_88_0"
BOOST_DIR="$BUILD_DIR/boost_${BOOST_VER_US}"

if [ ! -f "$OUTPUT_DIR/lib/libboost_thread.a" ]; then
    echo ">>> Building Boost $BOOST_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "$BOOST_DIR" ]; then
        curl -L -o boost.tar.bz2 \
            "https://archives.boost.io/release/${BOOST_VER}/source/boost_${BOOST_VER_US}.tar.bz2"
        tar xf boost.tar.bz2
        rm boost.tar.bz2
    fi
    cd "$BOOST_DIR"

    # Bootstrap b2
    ./bootstrap.sh --with-libraries=thread,system,chrono,serialization,regex,graph

    # Build for iOS arm64
    cat > user-config.jam <<EOF
using darwin : ios
    : xcrun --sdk iphoneos clang++ -arch $IOS_ARCH -miphoneos-version-min=$IOS_DEPLOYMENT_TARGET -fembed-bitcode
    : <striper> <root>$(xcrun --sdk iphoneos --show-sdk-path)
    ;
EOF

    ./b2 \
        --user-config=user-config.jam \
        toolset=darwin-ios \
        target-os=iphone \
        architecture=arm \
        address-model=64 \
        link=static \
        variant=release \
        threading=multi \
        --prefix="$OUTPUT_DIR" \
        --layout=system \
        -j$NCPU \
        install 2>&1 | tail -5

    echo "    Boost installed."
else
    echo ">>> Boost already built, skipping."
fi

# ──────────────────── 2. Eigen 3.4.0 ────────────────────
EIGEN_VER="3.4.0"

if [ ! -d "$OUTPUT_DIR/include/eigen3" ]; then
    echo ">>> Installing Eigen $EIGEN_VER (header-only)..."
    cd "$BUILD_DIR"
    if [ ! -d "eigen-$EIGEN_VER" ]; then
        curl -L -o eigen.tar.bz2 \
            "https://gitlab.com/libeigen/eigen/-/archive/$EIGEN_VER/eigen-$EIGEN_VER.tar.bz2"
        tar xf eigen.tar.bz2
        rm eigen.tar.bz2
    fi
    mkdir -p "eigen-$EIGEN_VER/build_ios" && cd "eigen-$EIGEN_VER/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" -DBUILD_TESTING=OFF
    cmake --install .
    echo "    Eigen installed."
else
    echo ">>> Eigen already installed, skipping."
fi

# ──────────────────── 3. FLANN 1.9.2 ────────────────────
FLANN_VER="1.9.2"

if [ ! -f "$OUTPUT_DIR/lib/libflann_cpp_s.a" ]; then
    echo ">>> Building FLANN $FLANN_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "flann-$FLANN_VER" ]; then
        curl -L -o flann.tar.gz \
            "https://github.com/flann-lib/flann/archive/refs/tags/$FLANN_VER.tar.gz"
        tar xf flann.tar.gz
        rm flann.tar.gz
    fi
    mkdir -p "flann-$FLANN_VER/build_ios" && cd "flann-$FLANN_VER/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_PYTHON_BINDINGS=OFF \
        -DBUILD_MATLAB_BINDINGS=OFF \
        -DBUILD_DOC=OFF
    make -j$NCPU
    make install
    echo "    FLANN installed."
else
    echo ">>> FLANN already built, skipping."
fi

# ──────────────────── 4. LZ4 1.10.0 ────────────────────
LZ4_VER="1.10.0"

if [ ! -f "$OUTPUT_DIR/lib/liblz4.a" ]; then
    echo ">>> Building LZ4 $LZ4_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "lz4-$LZ4_VER" ]; then
        curl -L -o lz4.tar.gz \
            "https://github.com/lz4/lz4/releases/download/v$LZ4_VER/lz4-$LZ4_VER.tar.gz"
        tar xf lz4.tar.gz
        rm lz4.tar.gz
    fi
    mkdir -p "lz4-$LZ4_VER/build/cmake/build_ios" && cd "lz4-$LZ4_VER/build/cmake/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DLZ4_BUILD_CLI=OFF \
        -DLZ4_BUILD_LEGACY_LZ4C=OFF
    make -j$NCPU
    make install
    echo "    LZ4 installed."
else
    echo ">>> LZ4 already built, skipping."
fi

# ──────────────────── 5. SuiteSparse 7.6.1 ────────────────────
# GTSAM needs SuiteSparse for sparse Cholesky (CHOLMOD)
SUITESPARSE_VER="7.6.1"

if [ ! -f "$OUTPUT_DIR/lib/libcholmod.a" ]; then
    echo ">>> Building SuiteSparse $SUITESPARSE_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "SuiteSparse-$SUITESPARSE_VER" ]; then
        curl -L -o suitesparse.tar.gz \
            "https://github.com/DrTimothyAldenDavis/SuiteSparse/archive/refs/tags/v$SUITESPARSE_VER.tar.gz"
        tar xf suitesparse.tar.gz
        rm suitesparse.tar.gz
    fi
    mkdir -p "SuiteSparse-$SUITESPARSE_VER/build_ios" && cd "SuiteSparse-$SUITESPARSE_VER/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DSUITESPARSE_ENABLE_PROJECTS="suitesparse_config;amd;camd;colamd;ccolamd;cholmod" \
        -DSUITESPARSE_USE_CUDA=OFF \
        -DSUITESPARSE_USE_FORTRAN=OFF \
        -DBUILD_TESTING=OFF \
        -DSUITESPARSE_DEMOS=OFF
    make -j$NCPU
    make install
    echo "    SuiteSparse installed."
else
    echo ">>> SuiteSparse already built, skipping."
fi

# ──────────────────── 6. OpenCV 4.11.0 + contrib ────────────────────
OPENCV_VER="4.11.0"

if [ ! -f "$OUTPUT_DIR/lib/libopencv_core.a" ]; then
    echo ">>> Building OpenCV $OPENCV_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "opencv-$OPENCV_VER" ]; then
        curl -L -o opencv.tar.gz \
            "https://github.com/opencv/opencv/archive/refs/tags/$OPENCV_VER.tar.gz"
        tar xf opencv.tar.gz
        rm opencv.tar.gz
    fi
    if [ ! -d "opencv_contrib-$OPENCV_VER" ]; then
        curl -L -o opencv_contrib.tar.gz \
            "https://github.com/opencv/opencv_contrib/archive/refs/tags/$OPENCV_VER.tar.gz"
        tar xf opencv_contrib.tar.gz
        rm opencv_contrib.tar.gz
    fi
    mkdir -p "opencv-$OPENCV_VER/build_ios" && cd "opencv-$OPENCV_VER/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DOPENCV_EXTRA_MODULES_PATH="$BUILD_DIR/opencv_contrib-$OPENCV_VER/modules" \
        -DBUILD_opencv_apps=OFF \
        -DBUILD_opencv_js=OFF \
        -DBUILD_opencv_python3=OFF \
        -DBUILD_opencv_java=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_PERF_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DWITH_OPENCL=OFF \
        -DWITH_EIGEN=ON \
        -DEIGEN_INCLUDE_PATH="$OUTPUT_DIR/include/eigen3" \
        -DBUILD_opencv_xfeatures2d=ON \
        -DBUILD_opencv_features2d=ON \
        -DBUILD_opencv_flann=ON \
        -DBUILD_opencv_calib3d=ON \
        -DBUILD_opencv_imgproc=ON \
        -DBUILD_opencv_imgcodecs=ON \
        -DBUILD_opencv_highgui=OFF \
        -DBUILD_opencv_videoio=OFF \
        -DBUILD_opencv_video=OFF \
        -DBUILD_opencv_ml=OFF \
        -DBUILD_opencv_dnn=OFF \
        -DBUILD_opencv_stitching=OFF \
        -DBUILD_opencv_objdetect=OFF \
        -DBUILD_opencv_photo=OFF \
        -DBUILD_ZLIB=ON \
        -DBUILD_PNG=ON \
        -DBUILD_JPEG=ON \
        -DWITH_FFMPEG=OFF \
        -DWITH_GSTREAMER=OFF
    make -j$NCPU
    make install
    echo "    OpenCV installed."
else
    echo ">>> OpenCV already built, skipping."
fi

# ──────────────────── 7. GTSAM 4.2 ────────────────────
GTSAM_VER="4.2"

if [ ! -f "$OUTPUT_DIR/lib/libgtsam.a" ]; then
    echo ">>> Building GTSAM $GTSAM_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "gtsam-$GTSAM_VER" ]; then
        curl -L -o gtsam.tar.gz \
            "https://github.com/borglab/gtsam/archive/refs/tags/$GTSAM_VER.tar.gz"
        tar xf gtsam.tar.gz
        rm gtsam.tar.gz
    fi
    mkdir -p "gtsam-$GTSAM_VER/build_ios" && cd "gtsam-$GTSAM_VER/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DGTSAM_BUILD_TESTS=OFF \
        -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF \
        -DGTSAM_BUILD_UNSTABLE=OFF \
        -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF \
        -DGTSAM_USE_SYSTEM_EIGEN=ON \
        -DEIGEN3_INCLUDE_DIR="$OUTPUT_DIR/include/eigen3" \
        -DGTSAM_WITH_TBB=OFF \
        -DGTSAM_BUILD_PYTHON=OFF \
        -DGTSAM_INSTALL_MATLAB_TOOLBOX=OFF \
        -DBOOST_ROOT="$OUTPUT_DIR" \
        -DBoost_NO_SYSTEM_PATHS=ON
    make -j$NCPU
    make install
    echo "    GTSAM installed."
else
    echo ">>> GTSAM already built, skipping."
fi

# ──────────────────── 8. RTAB-Map (SLAM core only) ────────────────────
RTABMAP_VER="0.21.8"

if [ ! -f "$OUTPUT_DIR/lib/librtabmap_core.a" ]; then
    echo ">>> Building RTAB-Map $RTABMAP_VER (SLAM core only)..."
    cd "$BUILD_DIR"
    if [ ! -d "rtabmap-$RTABMAP_VER" ]; then
        curl -L -o rtabmap.tar.gz \
            "https://github.com/introlab/rtabmap/archive/refs/tags/$RTABMAP_VER.tar.gz"
        tar xf rtabmap.tar.gz
        rm rtabmap.tar.gz
    fi
    mkdir -p "rtabmap-$RTABMAP_VER/build_ios" && cd "rtabmap-$RTABMAP_VER/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DBUILD_APP=OFF \
        -DBUILD_TOOLS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DWITH_QT=OFF \
        -DWITH_VTK=OFF \
        -DWITH_PCL=OFF \
        -DWITH_G2O=OFF \
        -DWITH_GTSAM=ON \
        -DGTSAM_DIR="$OUTPUT_DIR/lib/cmake/gtsam" \
        -DOpenCV_DIR="$OUTPUT_DIR/lib/cmake/opencv4" \
        -DFLANN_INCLUDE_DIR="$OUTPUT_DIR/include" \
        -DFLANN_LIBRARY="$OUTPUT_DIR/lib/libflann_cpp_s.a" \
        -DLZ4_INCLUDE_DIR="$OUTPUT_DIR/include" \
        -DLZ4_LIBRARY="$OUTPUT_DIR/lib/liblz4.a" \
        -DBOOST_ROOT="$OUTPUT_DIR" \
        -DBoost_NO_SYSTEM_PATHS=ON \
        -DEigen3_DIR="$OUTPUT_DIR/share/eigen3/cmake"
    make -j$NCPU
    make install
    echo "    RTAB-Map installed."
else
    echo ">>> RTAB-Map already built, skipping."
fi

echo ""
echo "=== All dependencies built ==="
echo "Output: $OUTPUT_DIR"
echo ""
echo "Static libraries:"
ls -1 "$OUTPUT_DIR/lib/"*.a 2>/dev/null || echo "  (none found)"
echo ""
echo "Next steps:"
echo "  1. Open Calabi Lens.xcodeproj in Xcode"
echo "  2. Add Library Search Paths: $OUTPUT_DIR/lib"
echo "  3. Add Header Search Paths: $OUTPUT_DIR/include"
echo "  4. Link static libraries (see README.md)"
