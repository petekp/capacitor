# Assets

This directory contains application assets for Claude HUD.

## Required Files

### AppIcon.icns
The application icon in Apple's .icns format.

**To create from a PNG:**
1. Create a 1024x1024 PNG image
2. Create an iconset folder: `mkdir AppIcon.iconset`
3. Generate sizes:
   ```bash
   sips -z 16 16     icon.png --out AppIcon.iconset/icon_16x16.png
   sips -z 32 32     icon.png --out AppIcon.iconset/icon_16x16@2x.png
   sips -z 32 32     icon.png --out AppIcon.iconset/icon_32x32.png
   sips -z 64 64     icon.png --out AppIcon.iconset/icon_32x32@2x.png
   sips -z 128 128   icon.png --out AppIcon.iconset/icon_128x128.png
   sips -z 256 256   icon.png --out AppIcon.iconset/icon_128x128@2x.png
   sips -z 256 256   icon.png --out AppIcon.iconset/icon_256x256.png
   sips -z 512 512   icon.png --out AppIcon.iconset/icon_256x256@2x.png
   sips -z 512 512   icon.png --out AppIcon.iconset/icon_512x512.png
   sips -z 1024 1024 icon.png --out AppIcon.iconset/icon_512x512@2x.png
   ```
4. Convert to icns: `iconutil -c icns AppIcon.iconset`

## Optional Files

### dmg-background.png
Background image for DMG installer window (660x400 recommended).
