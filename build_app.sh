#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="KeySight"
BUNDLE_ID="com.xinque.KeySight"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "🔨 Building $APP_NAME (release)..."
cd "$PROJECT_DIR"
swift build --disable-sandbox -c release

BIN_PATH="$PROJECT_DIR/.build/release/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "❌ Binary not found at $BIN_PATH"
    exit 1
fi

echo "📦 Assembling $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Generate bespoke AppIcon.icns directly using CoreGraphics + CoreText + standard ICNS container
ICON_TMP="$PROJECT_DIR/.build/icon_tmp"
rm -rf "$ICON_TMP"
mkdir -p "$ICON_TMP"

cat > "$ICON_TMP/gen_icon.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outIcnsPath = CommandLine.arguments[1]
let colorSpace = CGColorSpaceCreateDeviceRGB()

func renderIconPNG(px: Int) -> Data? {
    let w = CGFloat(px)
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: w, height: w)
    let inset = w * 0.08
    let cardRect = rect.insetBy(dx: inset, dy: inset)
    let radius = cardRect.width * 0.225

    // Clip to rounded squircle and draw deep indigo-blue gradient
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    let colors = [
        CGColor(colorSpace: colorSpace, components: [0.10, 0.13, 0.25, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.19, 0.30, 0.65, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.32, 0.48, 0.94, 1.0])!
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: cardRect.minX, y: cardRect.minY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.maxY),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle frosted inner keycap plate
    let innerRect = cardRect.insetBy(dx: cardRect.width * 0.14, dy: cardRect.height * 0.14)
    let innerRadius = innerRect.width * 0.20
    let innerPath = CGPath(roundedRect: innerRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
    ctx.addPath(innerPath)
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.14])!)
    ctx.fillPath()

    ctx.addPath(innerPath)
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.36])!)
    ctx.setLineWidth(max(1.0, w * 0.014))
    ctx.strokePath()

    // Crisp ⌘ glyph via CoreText
    let font = CTFontCreateWithName("SFProDisplay-Semibold" as CFString, w * 0.44, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.98])!
    ]
    let attrStr = CFAttributedStringCreate(nil, "⌘" as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrStr)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    let drawX = (w - bounds.width) / 2 - bounds.origin.x
    let drawY = (w - bounds.height) / 2 - bounds.origin.y
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: drawX, y: drawY)
    CTLineDraw(line, ctx)

    let mutableData = NSMutableData()
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return mutableData as Data
}

// Standard modern macOS PNG-backed ICNS chunk types
let chunksSpec: [(String, Int)] = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024)
]

var body = Data()
for (fourCC, px) in chunksSpec {
    guard let png = renderIconPNG(px: px) else { continue }
    let chunkSize = UInt32(8 + png.count).bigEndian
    body.append(contentsOf: fourCC.utf8)
    withUnsafeBytes(of: chunkSize) { body.append(contentsOf: $0) }
    body.append(png)
}

var icns = Data()
icns.append(contentsOf: "icns".utf8)
let totalSize = UInt32(8 + body.count).bigEndian
withUnsafeBytes(of: totalSize) { icns.append(contentsOf: $0) }
icns.append(body)

try icns.write(to: URL(fileURLWithPath: outIcnsPath))
SWIFT

swift "$ICON_TMP/gen_icon.swift" "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICON_TMP"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>KeySight 需要与当前应用交互以提示并触发快捷键操作。</string>
</dict>
</plist>
EOF

echo "🔏 Ad-hoc signing $APP_BUNDLE..."
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"

echo "✅ Done! App bundle created at: $APP_BUNDLE"
