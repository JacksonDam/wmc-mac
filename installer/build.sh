#!/bin/sh
# Builds "Media Center Installer.app" into build/installer/ (needs Xcode).
#
# The app carries what tools/make_app.sh needs (its tools and the native and
# managed sources) in Contents/Resources/project and runs it from there;
# nothing of Microsoft's is in it, and no test tools (the crawl stays here).
set -e
cd "$(dirname "$0")/.."
out="build/installer"
app="$out/Media Center Installer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/project"

# One program for both kinds of Mac (Apple silicon and Intel); it makes the
# Media Center app for the Mac it runs on.
for arch in arm64 x86_64; do
    xcrun swiftc -parse-as-library -O -target $arch-apple-macos11.0 \
        -o "$out/installer-$arch" installer/Sources/*.swift
done
lipo -create -output "$app/Contents/MacOS/Media Center Installer" "$out/installer-arm64" "$out/installer-x86_64"
rm "$out/installer-arm64" "$out/installer-x86_64"

project="$app/Contents/Resources/project"
mkdir -p "$project/tools/app" "$project/managed"
for f in make_app.sh make_app.py setup_toolchain.py extract_iso.py hive.py peinfo.py rgs.py build.py \
         gen_stubs.py setup_registry.py; do
    cp "tools/$f" "$project/tools/"
done
cp tools/app/launcher.c "$project/tools/app/"
rsync -a --exclude '._*' --exclude '.DS_Store' native "$project/"
rsync -a --exclude '._*' --exclude '.DS_Store' managed/wmctool managed/WmcStandins managed/WmcHost \
    managed/redirects.txt "$project/managed/"

xcrun swift installer/make_icon.swift "$out/icon.png"
iconset="$out/AppIcon.iconset"
rm -rf "$iconset" && mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$out/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$out/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Media Center Installer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.wmc-mac.installer</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Media Center Installer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.4.0</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$app"
echo "built $app"
