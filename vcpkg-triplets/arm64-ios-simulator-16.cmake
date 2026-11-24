# Pinewind deployment-pinned variant of the community arm64-ios-simulator
# triplet (hence the -16 suffix): builds libgit2 for the package's iOS floor
# (Package.swift .iOS(.v16)). Neither VCPKG_CMAKE_SYSTEM_VERSION nor the
# toolchain sets CMAKE_OSX_DEPLOYMENT_TARGET on Apple platforms, so the pin
# goes through the compiler/linker flags; a dedicated triplet name keeps
# its own ABI namespace independent of any stock/community install state.
#
# Install with: vcpkg install libgit2:arm64-ios-simulator-16 --overlay-triplets <repo>/vcpkg-triplets
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_SYSROOT iphonesimulator)

set(VCPKG_C_FLAGS "-mios-simulator-version-min=16.0")
set(VCPKG_CXX_FLAGS "-mios-simulator-version-min=16.0")
set(VCPKG_LINKER_FLAGS "-mios-simulator-version-min=16.0")
