#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
source_image="$project_root/Resources/SSHLightningPipeMinimalIcon.png"
iconset_path="$project_root/.build-app/AppIcon.iconset"
mkdir -p "$iconset_path"

# Supply every standard macOS size and Retina counterpart. Let Apple's tool
# encode the small legacy representations; PNG-only icp4/icp5 chunks can
# decode incorrectly in Finder's list view even when the large icon works.
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$source_image" \
        --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$source_image" \
        --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done

/usr/bin/iconutil --convert icns "$iconset_path" \
    --output "$project_root/Resources/AppIcon.icns"
echo "Built $project_root/Resources/AppIcon.icns"
