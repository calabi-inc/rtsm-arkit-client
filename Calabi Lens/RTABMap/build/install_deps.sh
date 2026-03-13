#!/bin/bash
# ──────────────────────────────────────────────────────────────
# install_deps.sh — Build RTAB-Map + all dependencies for iOS (arm64)
#
# Based on the official RTAB-Map iOS app install_deps.sh:
#   https://github.com/introlab/rtabmap/blob/master/app/ios/RTABMapApp/install_deps.sh
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
#   - ~15 GB disk space for sources + build artifacts
#
# Output:
#   ./output/ios/arm64/lib/*.a   — Static libraries
#   ./output/ios/arm64/include/  — Headers
# ──────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build_tmp"
OUTPUT_DIR="$SCRIPT_DIR/output/ios/arm64"
ESCAPED_OUTPUT_DIR="${OUTPUT_DIR// /\\ }"
NCPU=$(sysctl -n hw.ncpu)

IOS_DEPLOYMENT_TARGET="16.0"
IOS_ARCH="arm64"

# Common CMake toolchain flags for iOS cross-compilation
IOS_CMAKE_FLAGS=(
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_ARCHITECTURES=$IOS_ARCH
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include"

# Some macOS setups don't have pkg-config installed. FLANN only needs
# pkg-config to resolve liblz4, so provide a tiny local shim if needed.
if ! command -v pkg-config >/dev/null 2>&1; then
    PKG_CONFIG_SHIM="$BUILD_DIR/pkg-config"
    cat > "$PKG_CONFIG_SHIM" <<EOF
#!/bin/bash
set -euo pipefail
OUTPUT_DIR="$OUTPUT_DIR"
ESCAPED_OUTPUT_DIR="\${OUTPUT_DIR// /\\ }"
args=("\$@")
if [[ " \${args[*]} " == *" --version "* ]]; then
    echo "1.9.0"
    exit 0
fi
if [[ " \${args[*]} " == *" --help "* ]]; then
    echo "pkg-config shim for liblz4"
    exit 0
fi
pkg=""
for a in "\${args[@]}"; do
    if [[ "\$a" == "liblz4" ]]; then
        pkg="liblz4"
    fi
done
if [[ -z "\$pkg" ]]; then
    exit 1
fi
if [[ " \${args[*]} " == *" --exists "* ]]; then
    exit 0
fi
if [[ " \${args[*]} " == *" --modversion "* ]]; then
    echo "1.10.0"
    exit 0
fi
if [[ " \${args[*]} " == *" --variable=pcfiledir "* ]]; then
    echo "\$OUTPUT_DIR/lib/pkgconfig"
    exit 0
fi
if [[ " \${args[*]} " == *" --cflags-only-I "* ]] || [[ " \${args[*]} " == *" --cflags "* ]]; then
    echo "-I\${ESCAPED_OUTPUT_DIR}/include"
    exit 0
fi
if [[ " \${args[*]} " == *" --libs-only-L "* ]]; then
    echo "-L\${ESCAPED_OUTPUT_DIR}/lib"
    exit 0
fi
if [[ " \${args[*]} " == *" --libs-only-l "* ]]; then
    echo "-llz4"
    exit 0
fi
if [[ " \${args[*]} " == *" --libs "* ]]; then
    echo "-L\${ESCAPED_OUTPUT_DIR}/lib -llz4"
    exit 0
fi
exit 1
EOF
    chmod +x "$PKG_CONFIG_SHIM"
    export PATH="$BUILD_DIR:$PATH"
    echo ">>> pkg-config not found; using local liblz4 shim."
fi

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

if [ ! -f "$OUTPUT_DIR/lib/libboost_thread.a" ] || \
   [ ! -f "$OUTPUT_DIR/lib/libboost_filesystem.a" ] || \
   [ ! -f "$OUTPUT_DIR/lib/libboost_program_options.a" ] || \
   [ ! -f "$OUTPUT_DIR/lib/libboost_date_time.a" ] || \
   [ ! -f "$OUTPUT_DIR/lib/libboost_timer.a" ]; then
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
    ./bootstrap.sh --with-libraries=thread,system,chrono,serialization,regex,graph,filesystem,program_options,date_time,timer,iostreams

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
        cxxstd=17 \
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
        -DCMAKE_C_FLAGS="-I$ESCAPED_OUTPUT_DIR/include" \
        -DCMAKE_CXX_FLAGS="-I$ESCAPED_OUTPUT_DIR/include" \
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
        -DBUILD_opencv_highgui=ON \
        -DBUILD_opencv_videoio=ON \
        -DBUILD_opencv_video=ON \
        -DBUILD_opencv_ml=OFF \
        -DBUILD_opencv_dnn=OFF \
        -DBUILD_opencv_stitching=ON \
        -DBUILD_opencv_objdetect=ON \
        -DBUILD_opencv_photo=ON \
        -DBUILD_ZLIB=ON \
        -DBUILD_PNG=ON \
        -DBUILD_JPEG=ON \
        -DWITH_FFMPEG=OFF \
        -DWITH_GSTREAMER=OFF
    make -j$NCPU
    make install

    # OpenCV's cmake config references 3rdparty/libprotobuf but `make install`
    # doesn't copy it. Build and copy it manually.
    if [ ! -f "$OUTPUT_DIR/lib/opencv4/3rdparty/liblibprotobuf.a" ]; then
        echo "    Building and installing OpenCV 3rdparty protobuf..."
        make libprotobuf -j$NCPU 2>/dev/null || true
        mkdir -p "$OUTPUT_DIR/lib/opencv4/3rdparty"
        find . -name "liblibprotobuf.a" -exec cp {} "$OUTPUT_DIR/lib/opencv4/3rdparty/" \; 2>/dev/null || true
    fi

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
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DGTSAM_BUILD_TESTS=OFF \
        -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF \
        -DGTSAM_BUILD_UNSTABLE=OFF \
        -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF \
        -DGTSAM_SUPPORT_NESTED_DISSECTION=OFF \
        -DGTSAM_USE_SYSTEM_EIGEN=ON \
        -DEIGEN3_INCLUDE_DIR="$OUTPUT_DIR/include/eigen3" \
        -DEigen3_DIR="$OUTPUT_DIR/share/eigen3/cmake" \
        -DGTSAM_WITH_TBB=OFF \
        -DGTSAM_BUILD_PYTHON=OFF \
        -DGTSAM_INSTALL_MATLAB_TOOLBOX=OFF \
        -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
        -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
        -DBOOST_ROOT="$OUTPUT_DIR" \
        -DBoost_INCLUDE_DIR="$OUTPUT_DIR/include" \
        -DBoost_LIBRARY_DIR="$OUTPUT_DIR/lib" \
        -DBoost_LIBRARY_DIR_RELEASE="$OUTPUT_DIR/lib" \
        -DBoost_NO_SYSTEM_PATHS=ON
    make -j$NCPU
    make install
    echo "    GTSAM installed."
else
    echo ">>> GTSAM already built, skipping."
fi

# ──────────────────── 8. VTK 8.2.0 ────────────────────
# PCL needs VTK (at least for IO/common, even without visualization)
VTK_VER="8.2.0"

if [ ! -d "$OUTPUT_DIR/lib/vtk.framework" ]; then
    echo ">>> Building VTK $VTK_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "VTK-$VTK_VER" ]; then
        curl -L -o vtk.tar.gz \
            "https://github.com/Kitware/VTK/archive/refs/tags/v$VTK_VER.tar.gz"
        tar xf vtk.tar.gz
        rm vtk.tar.gz
    fi
    cd "VTK-$VTK_VER"
    if [ ! -f ".patched" ]; then
        # Patch CMake/vtkiOS.cmake to support arm64-only
        sed -i '' 's/set(IOS_SIMULATOR_ARCHITECTURES "x86_64"/set(IOS_SIMULATOR_ARCHITECTURES ""/g' CMake/vtkiOS.cmake 2>/dev/null || true

        # Patch vtkiOS.cmake to propagate CMAKE_POLICY_VERSION_MINIMUM into
        # inner ExternalProject builds (needed for CMake 4.x compatibility)
        sed -i '' '/vtk-compile-tools/,/ExternalProject_Add_Step/{
            /CMAKE_INSTALL_PREFIX/{
                a\
\      -DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5
            }
        }' CMake/vtkiOS.cmake 2>/dev/null || true

        # Also patch the crosscompile macro's CMAKE_ARGS
        sed -i '' '/macro(crosscompile/,/endmacro/{
            /CMAKE_INSTALL_PREFIX/{
                a\
\      -DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5
            }
        }' CMake/vtkiOS.cmake 2>/dev/null || true

        touch .patched
    fi
    mkdir -p build_ios && cd build_ios
    cmake .. \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_FRAMEWORK_INSTALL_PREFIX="$OUTPUT_DIR/lib" \
        -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DIOS_DEVICE_ARCHITECTURES="arm64" \
        -DIOS_SIMULATOR_ARCHITECTURES="" \
        -DIOS_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DVTK_IOS_BUILD=ON \
        -DModule_vtkFiltersModeling=ON
    cmake --build . --config Release
    echo "    VTK installed."
else
    echo ">>> VTK already built, skipping."
fi

# ──────────────────── 9. PCL 1.14.1 ────────────────────
# Using PCL 1.14.1 (not 1.11.1) for Boost 1.88 compatibility
PCL_VER="1.14.1"

if [ ! -d "$OUTPUT_DIR/include/pcl-1.14" ]; then
    echo ">>> Building PCL $PCL_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "pcl-pcl-$PCL_VER" ]; then
        curl -L -o pcl.tar.gz \
            "https://github.com/PointCloudLibrary/pcl/archive/refs/tags/pcl-$PCL_VER.tar.gz"
        tar xf pcl.tar.gz
        rm pcl.tar.gz
    fi
    cd "pcl-pcl-$PCL_VER"
    if [ ! -f ".patched" ]; then
        # Disable hardware grabber sources that use deprecated boost::asio::io_service
        # (not needed on iOS and incompatible with Boost 1.88)
        sed -i '' 's|^\(.*src/hdl_grabber.cpp\)|#\1|' io/CMakeLists.txt
        sed -i '' 's|^\(.*src/vlp_grabber.cpp\)|#\1|' io/CMakeLists.txt
        sed -i '' 's|^\(.*src/robot_eye_grabber.cpp\)|#\1|' io/CMakeLists.txt
        sed -i '' 's|^\(.*src/tim_grabber.cpp\)|#\1|' io/CMakeLists.txt
        touch .patched
    fi
    mkdir -p build_ios && cd build_ios
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DBUILD_apps=OFF \
        -DBUILD_examples=OFF \
        -DBUILD_tools=OFF \
        -DBUILD_visualization=OFF \
        -DBUILD_tracking=OFF \
        -DBUILD_people=OFF \
        -DBUILD_global_tests=OFF \
        -DWITH_QT=OFF \
        -DWITH_OPENGL=OFF \
        -DWITH_VTK=ON \
        -DPCL_SHARED_LIBS=OFF \
        -DPCL_ENABLE_SSE=OFF \
        -DCMAKE_FIND_ROOT_PATH="$OUTPUT_DIR"
    make -j$NCPU
    make install

    # Fix installed PCL headers: replace deprecated boost::asio::io_service
    # with boost::asio::io_context (required for Boost 1.88+)
    echo "    Patching PCL headers for Boost 1.88 compatibility..."
    for header in hdl_grabber.h vlp_grabber.h robot_eye_grabber.h tim_grabber.h; do
        HPATH="$OUTPUT_DIR/include/pcl-1.14/pcl/io/$header"
        if [ -f "$HPATH" ]; then
            sed -i '' 's/io_service/io_context/g' "$HPATH"
        fi
    done

    echo "    PCL installed."
else
    echo ">>> PCL already built, skipping."
fi

# ──────────────────── 10. RTAB-Map ────────────────────
RTABMAP_VER="0.21.8-ios"

if [ ! -f "$OUTPUT_DIR/lib/librtabmap_core.a" ]; then
    echo ">>> Building RTAB-Map $RTABMAP_VER..."
    cd "$BUILD_DIR"
    if [ ! -d "rtabmap-$RTABMAP_VER" ]; then
        curl -L -o rtabmap.tar.gz \
            "https://github.com/introlab/rtabmap/archive/refs/tags/$RTABMAP_VER.tar.gz"
        tar xf rtabmap.tar.gz
        rm rtabmap.tar.gz
    fi

    # Fix duplicate ENDIF() in rtabmap CMakeLists.txt (present in 0.21.8-ios release)
    if grep -q "^ENDIF()$" "$BUILD_DIR/rtabmap-$RTABMAP_VER/CMakeLists.txt" 2>/dev/null; then
        # Count occurrences near end of file — remove duplicate if present
        ENDIF_COUNT=$(tail -20 "$BUILD_DIR/rtabmap-$RTABMAP_VER/CMakeLists.txt" | grep -c "^ENDIF()$" || true)
        if [ "$ENDIF_COUNT" -gt 1 ]; then
            echo "    Fixing duplicate ENDIF() in rtabmap CMakeLists.txt..."
            # Remove the first standalone ENDIF() near line 916
            sed -i '' '916{/^ENDIF()$/d;}' "$BUILD_DIR/rtabmap-$RTABMAP_VER/CMakeLists.txt" 2>/dev/null || true
        fi
    fi

    # Step 1: Build res_tool for the host (needed for iOS cross-compilation)
    RTABMAP_SRC="$BUILD_DIR/rtabmap-$RTABMAP_VER"
    RES_TOOL="$RTABMAP_SRC/build_host/rtabmap-res_tool"
    if [ ! -f "$RES_TOOL" ]; then
        echo "    Building res_tool for host..."
        UTILITE_SRC="$RTABMAP_SRC/utilite/src"
        UTILITE_INC="$RTABMAP_SRC/utilite/include"
        mkdir -p "$RTABMAP_SRC/build_host"

        # First run cmake to generate the export header
        mkdir -p "$RTABMAP_SRC/build_gen" && cd "$RTABMAP_SRC/build_gen"
        cmake .. \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
            -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
            -DBUILD_APP=OFF -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF \
            -DWITH_QT=OFF -DWITH_VTK=OFF -DWITH_G2O=OFF -DWITH_GTSAM=OFF \
            -DWITH_OPENMP=OFF \
            -DCMAKE_FIND_ROOT_PATH="$OUTPUT_DIR" 2>/dev/null || true

        EXPORT_INC="$RTABMAP_SRC/build_gen/utilite/src/include"
        if [ ! -d "$EXPORT_INC" ]; then
            # Fallback: use existing build_ios export header if available
            EXPORT_INC="$RTABMAP_SRC/build_ios/utilite/src/include"
        fi

        c++ -std=c++17 -O2 \
            -DUTILITE_VERSION=\"0.3.0\" \
            -I"$UTILITE_INC" \
            -I"$EXPORT_INC" \
            "$UTILITE_SRC/UConversion.cpp" \
            "$UTILITE_SRC/UDirectory.cpp" \
            "$UTILITE_SRC/UFile.cpp" \
            "$UTILITE_SRC/ULogger.cpp" \
            "$UTILITE_SRC/UEventsHandler.cpp" \
            "$UTILITE_SRC/UEventsManager.cpp" \
            "$UTILITE_SRC/UEventsSender.cpp" \
            "$UTILITE_SRC/UProcessInfo.cpp" \
            "$UTILITE_SRC/UThread.cpp" \
            "$UTILITE_SRC/UTimer.cpp" \
            "$UTILITE_SRC/UVariant.cpp" \
            "$RTABMAP_SRC/utilite/resource_generator/main.cpp" \
            -o "$RES_TOOL" \
            -lpthread
        echo "    res_tool built."
    fi

    # Step 2: Build RTAB-Map for iOS
    mkdir -p "$RTABMAP_SRC/build_ios" && cd "$RTABMAP_SRC/build_ios"
    cmake .. "${IOS_CMAKE_FLAGS[@]}" \
        -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
        -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
        -DBUILD_APP=OFF \
        -DBUILD_TOOLS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DWITH_QT=OFF \
        -DWITH_G2O=OFF \
        -DWITH_GTSAM=ON \
        -DWITH_TORO=OFF \
        -DWITH_VERTIGO=OFF \
        -DWITH_MADGWICK=OFF \
        -DWITH_ORB_OCTREE=OFF \
        -DRTABMAP_RES_TOOL="$RES_TOOL" \
        -DCMAKE_FIND_ROOT_PATH="$OUTPUT_DIR" \
        -DGTSAM_DIR="$OUTPUT_DIR/lib/cmake/GTSAM" \
        -DOpenCV_DIR="$OUTPUT_DIR/lib/cmake/opencv4" \
        -DBOOST_ROOT="$OUTPUT_DIR" \
        -DBoost_NO_SYSTEM_PATHS=ON \
        -DBoost_INCLUDE_DIR="$OUTPUT_DIR/include" \
        -DBoost_LIBRARY_DIR="$OUTPUT_DIR/lib" \
        -DEIGEN3_INCLUDE_DIR="$OUTPUT_DIR/include/eigen3" \
        -DEigen3_DIR="$OUTPUT_DIR/share/eigen3/cmake" \
        -Wno-dev
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
