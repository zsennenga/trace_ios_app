#!/bin/bash
#
# generate_icons.sh
# Script to generate all required iOS app icon sizes from an SVG source file
# Uses svgexport (https://github.com/shakiba/svgexport) which must be installed via npm
#

# Check if svgexport is installed
if ! command -v svgexport &> /dev/null; then
    echo "Error: svgexport is not installed."
    echo "Please install it using: npm install -g svgexport"
    exit 1
fi

# Set paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SVG_SOURCE="$SCRIPT_DIR/TracingCam/Assets.xcassets/AppIcon.appiconset/icon-1024.svg"
ICON_DIR="$SCRIPT_DIR/TracingCam/Assets.xcassets/AppIcon.appiconset"

# Check if source SVG exists
if [ ! -f "$SVG_SOURCE" ]; then
    echo "Error: Source SVG file not found at $SVG_SOURCE"
    exit 1
fi

# Create icon directory if it doesn't exist
mkdir -p "$ICON_DIR"

# Function to generate a PNG icon of specified size
generate_icon() {
    local size=$1
    local filename=$2
    local output_path="$ICON_DIR/$filename"
    
    echo "Generating $filename ($size x $size)..."
    svgexport "$SVG_SOURCE" "$output_path" "$size:$size"
    
    if [ $? -eq 0 ]; then
        echo "✅ Created $filename"
    else
        echo "❌ Failed to create $filename"
    fi
}

echo "Generating iOS app icons from SVG source..."

# iPhone icons
generate_icon 40 "icon-20@2x.png"     # 20pt@2x
generate_icon 60 "icon-20@3x.png"     # 20pt@3x
generate_icon 58 "icon-29@2x.png"     # 29pt@2x
generate_icon 87 "icon-29@3x.png"     # 29pt@3x
generate_icon 80 "icon-40@2x.png"     # 40pt@2x
generate_icon 120 "icon-40@3x.png"    # 40pt@3x
generate_icon 120 "icon-60@2x.png"    # 60pt@2x
generate_icon 180 "icon-60@3x.png"    # 60pt@3x

# iPad icons
generate_icon 20 "icon-20@1x.png"     # 20pt@1x
# 20pt@2x is already generated for iPhone
generate_icon 29 "icon-29@1x.png"     # 29pt@1x
# 29pt@2x is already generated for iPhone
generate_icon 40 "icon-40@1x.png"     # 40pt@1x
# 40pt@2x is already generated for iPhone
generate_icon 76 "icon-76@1x.png"     # 76pt@1x
generate_icon 152 "icon-76@2x.png"    # 76pt@2x
generate_icon 167 "icon-83.5@2x.png"  # 83.5pt@2x

# App Store icon
generate_icon 1024 "icon-1024.png"    # 1024pt@1x

echo "Icon generation complete!"
echo "You may need to refresh the Xcode asset catalog to see the changes."

# Make the SVG file executable
chmod +x "$0"
