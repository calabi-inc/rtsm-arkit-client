# ──────────────────────────────────────────────────────────────
# CMakeLists.txt — Minimal RTAB-Map iOS build (SLAM core only)
#
# This file documents the exact CMake flags used by install_deps.sh
# to build RTAB-Map for iOS. It is NOT used directly — the build
# script handles everything. This file serves as reference.
# ──────────────────────────────────────────────────────────────

cmake_minimum_required(VERSION 3.24)
project(RTABMapiOS LANGUAGES C CXX)

# ── iOS cross-compilation ──
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 16.0)
set(CMAKE_BUILD_TYPE Release)
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ── RTAB-Map build flags (SLAM core only, no visualization) ──
# These are the flags passed to RTAB-Map's own CMakeLists.txt:
#
# -DBUILD_APP=OFF           # No GUI application
# -DBUILD_TOOLS=OFF         # No CLI tools
# -DBUILD_EXAMPLES=OFF      # No examples
# -DWITH_QT=OFF             # No Qt GUI
# -DWITH_VTK=OFF            # No VTK visualization
# -DWITH_PCL=OFF            # No Point Cloud Library
# -DWITH_G2O=OFF            # No g2o optimizer (use GTSAM)
# -DWITH_GTSAM=ON           # Use GTSAM for pose graph optimization
#
# ── Required dependencies (built by install_deps.sh) ──
#
# Library          Version   Purpose
# ────────────────────────────────────────────────
# Boost            1.88.0    Smart pointers, threads, serialization
# Eigen            3.4.0     Linear algebra (header-only)
# OpenCV + contrib 4.11.0    Feature extraction, BoW, image processing
# GTSAM            4.2       Pose graph optimization
# FLANN            1.9.2     Nearest neighbor search
# LZ4              1.10.0    Compression
# SuiteSparse      7.6.1     Sparse linear algebra (GTSAM dependency)
#
# ── Excluded dependencies ──
#
# g2o       — Alternative optimizer (GTSAM sufficient)
# VTK       — 3D visualization (not needed for headless SLAM)
# PCL       — Point cloud processing (server-side in RTSM)
# LASzip    — LAS file compression (not needed)
# libLAS    — LAS file I/O (not needed)

message(STATUS "This CMakeLists.txt is reference-only. Use install_deps.sh to build.")
