# Тулчейн CMake для iOS arm64 (минимум iOS 15).
# На macOS SDK берётся из xcrun; на Linux задайте SDKROOT=/путь/к/iPhoneOS.sdk (только для проверки кода).
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0 CACHE STRING "")

if(DEFINED ENV{SDKROOT} AND NOT "$ENV{SDKROOT}" STREQUAL "")
    set(CMAKE_OSX_SYSROOT "$ENV{SDKROOT}" CACHE PATH "")
else()
    set(CMAKE_OSX_SYSROOT iphoneos CACHE STRING "")
endif()

if(NOT CMAKE_HOST_APPLE)
    # Кросс-сборка с Linux: системный clang + lld вместо Xcode.
    find_program(XR_IOS_CLANG clang REQUIRED)
    find_program(XR_IOS_CLANGXX clang++ REQUIRED)
    set(CMAKE_C_COMPILER "${XR_IOS_CLANG}")
    set(CMAKE_CXX_COMPILER "${XR_IOS_CLANGXX}")
    set(CMAKE_C_COMPILER_TARGET arm64-apple-ios15.0)
    set(CMAKE_CXX_COMPILER_TARGET arm64-apple-ios15.0)
    set(CMAKE_ASM_COMPILER_TARGET arm64-apple-ios15.0)
    set(CMAKE_OBJC_COMPILER "${XR_IOS_CLANG}")
    set(CMAKE_OBJCXX_COMPILER "${XR_IOS_CLANGXX}")
    set(CMAKE_OBJC_COMPILER_TARGET arm64-apple-ios15.0)
    set(CMAKE_OBJCXX_COMPILER_TARGET arm64-apple-ios15.0)
    set(CMAKE_INSTALL_NAME_TOOL llvm-install-name-tool-18 CACHE FILEPATH "")
    set(CMAKE_LIPO llvm-lipo-18 CACHE FILEPATH "")
    set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_AR llvm-ar-18 CACHE FILEPATH "")
    set(CMAKE_RANLIB llvm-ranlib-18 CACHE FILEPATH "")
endif()

# Проверки компилятора собирают статическую библиотеку, а не приложение (его нужно подписывать).
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH "${CMAKE_OSX_SYSROOT}" "${XR_IOS_PREFIX}" "$ENV{XR_IOS_PREFIX}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
