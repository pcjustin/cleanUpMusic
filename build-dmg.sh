#!/bin/sh
# Builds dist/CleanUpMusic.dmg: the release app with TagLib, OpenCC and the s2tw dictionaries inside, ad-hoc signed.
set -eu
cd "$(dirname "$0")"

swift build -c release
bin=.build/release
app=dist/CleanUpMusic.app
res=$app/Contents/Resources
rm -rf dist
mkdir -p "$app/Contents/MacOS" "$res/opencc" dist/icon.iconset

cp "$bin/CleanUpMusic" "$app/Contents/MacOS/"
cp -R "$bin/CleanUpMusic_CleanUpMusic.bundle" "$res/"

opencc=$(brew --prefix opencc)/share/opencc
cp "$opencc/s2tw.json" "$res/opencc/"
for dict in $(sed -n 's/.*"file": *"\([^"]*\)".*/\1/p' "$opencc/s2tw.json" | sort -u); do
    cp "$opencc/$dict" "$res/opencc/"
done

sips -s format png -z 1024 1024 Sources/CleanUpMusic/Resources/AppIcon.svg --out dist/icon.iconset/icon_512x512@2x.png >/dev/null
iconutil -c icns dist/icon.iconset -o "$res/AppIcon.icns"
rm -r dist/icon.iconset

# Homebrew bottles target the macOS they were built on, so the app needs at least that.
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CleanUpMusic</string>
    <key>CFBundleIdentifier</key><string>io.github.pcjustin.CleanUpMusic</string>
    <key>CFBundleName</key><string>CleanUpMusic</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$(sw_vers -productVersion | cut -d. -f1).0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

dylibbundler -cd -of -b -x "$app/Contents/MacOS/CleanUpMusic" -d "$app/Contents/Frameworks" -p @executable_path/../Frameworks/
codesign --force --deep -s - "$app"

mkdir dist/dmg
mv "$app" dist/dmg/
ln -s /Applications dist/dmg/Applications
diskutil image create from --volumeName CleanUpMusic dist/dmg dist/CleanUpMusic.dmg
rm -rf dist/dmg
echo "DMG: dist/CleanUpMusic.dmg"
