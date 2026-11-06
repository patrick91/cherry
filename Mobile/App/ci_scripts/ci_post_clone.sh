#!/bin/sh
# Xcode Cloud runs this after it clones the repository (ci_scripts must sit
# beside the project). The project is xcodegen's and git-ignored, so it is
# generated here. Xcode Cloud resolves no packages itself
# (-disableAutomaticPackageResolution) and wants the project's own
# Package.resolved, so the kit's (the app's only remote packages come through
# it) is copied in and resolved once, which keeps its pins and writes the
# project's origin hash.
set -eu

app_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$app_dir"

command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate --quiet

swiftpm=CherryMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$swiftpm"
cp ../CherryMobileKit/Package.resolved "$swiftpm/Package.resolved"
xcodebuild \
    -resolvePackageDependencies \
    -project CherryMobile.xcodeproj \
    -scheme CherryMobile \
    -quiet
