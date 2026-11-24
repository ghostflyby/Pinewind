# Pinewind deployment-pinned variant of arm64-osx (hence the -15 suffix):
# builds libgit2 for the package's macOS floor (Package.swift .macOS(.v15)).
# The stock arm64-osx triplet leaves CMAKE_OSX_DEPLOYMENT_TARGET unset, so
# objects default to the host SDK baseline; and reusing the stock name
# would collide with any previous stock-triplet install state in the same
# vcpkg root (its compiler hash and status pins short-circuit "already
# installed" before this overlay is consulted). A dedicated name gets its
# own ABI namespace and always builds with the flags below.
#
# Install with: vcpkg install libgit2:arm64-osx-15 --overlay-triplets <repo>/vcpkg-triplets
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)

set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)

set(VCPKG_C_FLAGS "-mmacosx-version-min=15.0")
set(VCPKG_CXX_FLAGS "-mmacosx-version-min=15.0")
set(VCPKG_LINKER_FLAGS "-mmacosx-version-min=15.0")
