#!/bin/bash

# fix_storyboard.sh
# Script to update the Xcode project file to reference the LaunchScreen.storyboard file directly
# instead of looking for it in a Base.lproj directory

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

PROJECT_FILE="TracingCam.xcodeproj/project.pbxproj"

echo_status "Starting storyboard reference fix..."

# Check if project file exists
if [ ! -f "$PROJECT_FILE" ]; then
    echo_error "Project file not found at: $PROJECT_FILE"
    exit 1
fi

# Backup the original project file
BACKUP_FILE="$PROJECT_FILE.bak"
echo_status "Creating backup of project file to $BACKUP_FILE"
cp "$PROJECT_FILE" "$BACKUP_FILE"

# Update the project file to reference the storyboard directly
echo_status "Updating storyboard references in project file..."

# Replace "Base.lproj/LaunchScreen.storyboard" with "LaunchScreen.storyboard"
sed -i.tmp 's/Base\.lproj\/LaunchScreen\.storyboard/LaunchScreen.storyboard/g' "$PROJECT_FILE"

# Also update any path references
sed -i.tmp 's/path = Base\.lproj\/LaunchScreen\.storyboard/path = LaunchScreen.storyboard/g' "$PROJECT_FILE"

# Remove temporary files created by sed
rm -f "$PROJECT_FILE.tmp"

echo_status "Storyboard references updated successfully!"
echo_status "Original project file backed up to: $BACKUP_FILE"
echo_status "You can now open the project in Xcode and build it."

# Commit the changes if git is available
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo_status "Committing changes to git..."
    git add "$PROJECT_FILE"
    git commit -m "Fix storyboard reference path in project file"
    echo_status "Changes committed to git."
fi

echo_status "Done!"

# Make the script executable
chmod +x "$0"
