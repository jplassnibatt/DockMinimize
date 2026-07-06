#!/bin/bash
set -e 

echo "🔨 Step 1: Cleaning up old build artifacts..."
rm -rf build
mkdir -p build/DockMinimize.app/Contents/MacOS
mkdir -p build/DockMinimize.app/Contents/Resources

echo "🚀 Step 2: Compiling native Swift binary..."
swiftc src/main.swift \
    -o build/DockMinimize.app/Contents/MacOS/DockMinimize \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework SwiftUI \
    -framework ScreenCaptureKit \
    -parse-as-library

echo "📄 Step 3: Copying configurations and asset bundles..."
if [ -f "resources/Info.plist" ]; then
    cp resources/Info.plist build/DockMinimize.app/Contents/Info.plist
else
    echo "❌ ERROR: resources/Info.plist not found!" && exit 1
fi

if [ -f "resources/AppIcon.icns" ]; then
    cp resources/AppIcon.icns build/DockMinimize.app/Contents/Resources/AppIcon.icns
fi

echo "🔐 Step 4: Ad-hoc Code Signing for local execution..."
codesign --force --deep --sign - build/DockMinimize.app

echo "🚚 Step 5: Installing directly to system Applications folder..."
# Safely overwrite any old version sitting in your Applications directory
cp -R build/DockMinimize.app /Applications/

echo "🎉 SUCCESS: DockMinimize has been compiled, signed, and installed!"
echo "👉 You can now launch it directly from your Applications folder or Spotlight."