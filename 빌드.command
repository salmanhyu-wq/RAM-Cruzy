#!/bin/zsh
set -eu
cd -- "${0:A:h}"
project="$PWD"
out="${AIRAM_BUILD_DIR:-$project/.build}"
app="$out/로컬 램 크루지_EX.app"
mkdir -p "$app/Contents/MacOS"
clang -O2 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=14.0 \
    Sources/GPUWiredLimit.c -o "$app/Contents/MacOS/GPUWiredLimit"
/usr/bin/codesign --force --sign - "$app/Contents/MacOS/GPUWiredLimit"
swiftc -O -swift-version 5 -module-cache-path "$out/ModuleCache" \
    Sources/AppLanguage.swift Sources/Memory.swift Sources/MemoryBoost.swift Sources/MemoryBoostView.swift Sources/Providers.swift Sources/Library.swift Sources/History.swift \
    Sources/ModelFiles.swift Sources/ServerTools.swift Sources/ManagementViews.swift Sources/AIActivity.swift Sources/Dashboard.swift Sources/Views.swift Sources/MemoryMenu.swift -lsqlite3 \
    -target arm64-apple-macos14.0 -o "$app/Contents/MacOS/AIRAMManager"
icons="$out/AppIcon.iconset"
mkdir -p "$icons" "$app/Contents/Resources"
if [[ ! -f "$out/AppIcon.icns" || ! -f "$out/MenuChip.png" || Resources/AppIcon.swift -nt "$out/AppIcon.icns" ]]; then
    swiftc -module-cache-path "$out/ModuleCache" Resources/AppIcon.swift -o "$out/make-app-icon"
    "$out/make-app-icon" "$out/AppIcon.png"
    "$out/make-app-icon" "$out/MenuChip.png" --menu-chip
    for size in 16 32 128 256 512; do
        double=$((size * 2))
        /usr/bin/sips -z "$size" "$size" "$out/AppIcon.png" --out "$icons/icon_${size}x${size}.png" >/dev/null
        /usr/bin/sips -z "$double" "$double" "$out/AppIcon.png" --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
    done
    /usr/bin/iconutil -c icns "$icons" -o "$out/AppIcon.icns"
fi
cp "$out/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$out/MenuChip.png" "$app/Contents/Resources/MenuChip.png"
cp Resources/MyMusicGacha.png "$app/Contents/Resources/MyMusicGacha.png"
for language in en ko; do
    mkdir -p "$app/Contents/Resources/$language.lproj"
    cp Resources/"$language.lproj/"*.strings "$app/Contents/Resources/$language.lproj/"
done
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AIRAMSourceFolder string $project" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
if [[ "${1:-}" != "--build-only" ]]; then
    /usr/bin/open "$app"
fi
