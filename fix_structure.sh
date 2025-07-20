#!/bin/bash

# fix_structure.sh
# Script to properly organize all files to match the structure expected by the Xcode project
# This will move all source files, assets, and resources to the TracingCam directory

set -e  # Exit immediately if a command exits with a non-zero status

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Print colored status messages
function echo_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

function echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo_status "Starting project structure reorganization..."

# Create backup directory
BACKUP_DIR="$SCRIPT_DIR/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo_status "Created backup directory: $BACKUP_DIR"

# Ensure TracingCam directory exists
mkdir -p "TracingCam"
mkdir -p "TracingCam/Base.lproj"

# List of Swift files to move to TracingCam directory
SWIFT_FILES=(
    "AppDelegate.swift"
    "SceneDelegate.swift"
    "ContentView.swift"
    "AppSettings.swift"
    "CameraService.swift"
)

# List of resource files to move
RESOURCE_FILES=(
    "Info.plist"
    "PrivacyInfo.xcprivacy"
)

# Function to safely move a file to the TracingCam directory
function safe_move() {
    local source="$1"
    local dest="$2"
    
    if [ -f "$source" ]; then
        echo_status "Moving $source to $dest"
        cp "$source" "$BACKUP_DIR/" # Backup first
        mv "$source" "$dest"
    else
        echo_warning "File not found: $source"
    fi
}

# Move Swift files
echo_status "Moving Swift source files to TracingCam directory..."
for file in "${SWIFT_FILES[@]}"; do
    if [ -f "$file" ]; then
        safe_move "$file" "TracingCam/"
    elif [ -f "TracingCam/$file" ]; then
        echo_status "File already in correct location: TracingCam/$file"
    else
        echo_warning "File not found in either location: $file"
    fi
done

# Move resource files
echo_status "Moving resource files to TracingCam directory..."
for file in "${RESOURCE_FILES[@]}"; do
    if [ -f "$file" ]; then
        safe_move "$file" "TracingCam/"
    elif [ -f "TracingCam/$file" ]; then
        echo_status "File already in correct location: TracingCam/$file"
    else
        echo_warning "File not found in either location: $file"
    fi
done

# Handle Assets.xcassets directory
if [ -d "Assets.xcassets" ]; then
    echo_status "Moving Assets.xcassets to TracingCam directory..."
    cp -r "Assets.xcassets" "$BACKUP_DIR/" # Backup first
    mv "Assets.xcassets" "TracingCam/"
elif [ -d "TracingCam/Assets.xcassets" ]; then
    echo_status "Assets.xcassets already in correct location"
else
    echo_warning "Assets.xcassets not found"
fi

# Handle LaunchScreen.storyboard
if [ -f "TracingCam/LaunchScreen.storyboard" ]; then
    echo_status "Moving LaunchScreen.storyboard to Base.lproj directory..."
    cp "TracingCam/LaunchScreen.storyboard" "$BACKUP_DIR/" # Backup first
    mv "TracingCam/LaunchScreen.storyboard" "TracingCam/Base.lproj/"
elif [ -f "LaunchScreen.storyboard" ]; then
    echo_status "Moving LaunchScreen.storyboard from root to Base.lproj directory..."
    cp "LaunchScreen.storyboard" "$BACKUP_DIR/" # Backup first
    mv "LaunchScreen.storyboard" "TracingCam/Base.lproj/"
elif [ -f "TracingCam/Base.lproj/LaunchScreen.storyboard" ]; then
    echo_status "LaunchScreen.storyboard already in correct location"
else
    echo_warning "LaunchScreen.storyboard not found"
fi

# Update the project file to reference the correct paths
PROJECT_FILE="TracingCam.xcodeproj/project.pbxproj"
if [ -f "$PROJECT_FILE" ]; then
    echo_status "Updating project file to reference the correct paths..."
    cp "$PROJECT_FILE" "$BACKUP_DIR/" # Backup first
    
    # Update path references in the project file
    sed -i.tmp 's/path = LaunchScreen\.storyboard/path = Base.lproj\/LaunchScreen.storyboard/g' "$PROJECT_FILE"
    
    # Remove temporary files created by sed
    rm -f "$PROJECT_FILE.tmp"
else
    echo_warning "Project file not found: $PROJECT_FILE"
fi

echo_status "Project structure reorganization completed!"
echo_status "Original files backed up to: $BACKUP_DIR"

# Commit the changes if git is available
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo_status "Committing changes to git..."
    git add .
    git commit -m "Fix project structure: organize files in TracingCam directory"
    echo_status "Changes committed to git."
fi

echo_status "You can now open the project in Xcode and build it."

# Make the script executable
chmod +x "$0"
