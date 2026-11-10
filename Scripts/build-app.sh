#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
cd "$project_root"

# Generate a native icon bundle, including the small Finder/list variants.
zsh "$project_root/Scripts/build-icon.sh"

# Keep the packaged-app build cache separate from SwiftPM's default `.build`
# directory so an interrupted IDE or CLI build cannot prevent app packaging.
build_path="$project_root/.build-app"
build_args=(--scratch-path "$build_path" -c release --product FastSSHTunnel)
# The standalone macOS 27 tools lack the SwiftUI macro plugin. Use the
# installed macOS 26.5 SDK when building with this Command Line Tools setup.
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" &&
      -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    build_args+=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
swift build "${build_args[@]}"
bin_path=$(swift build "${build_args[@]}" --show-bin-path)

# The standard About panel reads CFBundleVersion from the packaged Info.plist.
# Keep the last successful build in the source plist so cleaning dist or the
# build cache does not reset the counter.
source_info="$project_root/Resources/Info.plist"
current_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$source_info")
if [[ "$current_build" != <-> ]]; then
    print -u2 "CFBundleVersion must be a nonnegative integer (found: $current_build)."
    exit 1
fi
next_build=$((10#$current_build + 1))

app_path="$project_root/dist/FastSSHTunnel.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# Replace the executable with a new file. Overwriting it with cp can leave
# macOS's cached code-signature pages associated with the previous build.
/usr/bin/ditto "$bin_path/FastSSHTunnel" "$app_path/Contents/MacOS/FastSSHTunnel"
cp "$source_info" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$app_path/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$project_root/Resources/SSHLightningPipeMinimalIcon.png" "$app_path/Contents/Resources/SSHLightningPipeMinimalIcon.png"

# Finder may attach metadata to a previously opened bundle that codesign
# rejects. Remove only these two packaging attributes from generated output.
/usr/bin/xattr -dr com.apple.FinderInfo "$app_path" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$app_path" 2>/dev/null || true

# Seal the completed bundle for local use, including Info.plist/resources.
# The linker's signature on the standalone executable is not a bundle signature.
/usr/bin/codesign --force --sign - --timestamp=none "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

# Advance the persistent counter only after packaging and signing succeed.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$source_info"

# Notify Finder that an existing bundle has new contents, including its icon.
/usr/bin/touch "$app_path"

echo "Built $app_path (build $next_build)"
