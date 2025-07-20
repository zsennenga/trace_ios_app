#!/bin/bash

# final_fix.sh
# Comprehensive script to create a clean Xcode project from scratch
# that properly references all files in their current locations

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

echo_status "Starting comprehensive project fix..."

# Create backup directory with timestamp
BACKUP_DIR="$SCRIPT_DIR/backup_final_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo_status "Created backup directory: $BACKUP_DIR"

# 1. Backup all existing project files
echo_status "Backing up existing project files..."
if [ -d "TracingCam.xcodeproj" ]; then
    cp -r "TracingCam.xcodeproj" "$BACKUP_DIR/"
fi

# 2. Remove Swift Package Manager files and backup
echo_status "Removing Swift Package Manager files..."
if [ -f "Package.swift" ]; then
    mv "Package.swift" "$BACKUP_DIR/"
fi
if [ -f "Package.swift.bak" ]; then
    mv "Package.swift.bak" "$BACKUP_DIR/"
fi
if [ -d "Sources" ]; then
    mv "Sources" "$BACKUP_DIR/"
fi
if [ -d "Sources.bak" ]; then
    mv "Sources.bak" "$BACKUP_DIR/"
fi
if [ -d ".swiftpm" ]; then
    mv ".swiftpm" "$BACKUP_DIR/"
fi

# 3. Ensure all files are in the correct locations
echo_status "Ensuring all files are in the correct locations..."

# Create necessary directories
mkdir -p "TracingCam"
mkdir -p "TracingCam/Base.lproj"

# List of Swift files that should be in TracingCam directory
SWIFT_FILES=(
    "AppDelegate.swift"
    "SceneDelegate.swift"
    "ContentView.swift"
    "AppSettings.swift"
    "CameraService.swift"
)

# List of resource files
RESOURCE_FILES=(
    "Info.plist"
    "PrivacyInfo.xcprivacy"
)

# Function to ensure a file is in the correct location
function ensure_file_location() {
    local file="$1"
    local target_dir="$2"
    
    # Check if file exists in root directory
    if [ -f "$file" ]; then
        echo_status "Moving $file to $target_dir/"
        cp "$file" "$BACKUP_DIR/" # Backup first
        mv "$file" "$target_dir/"
    # Check if file exists in backup directory but not in target
    elif [ -f "$BACKUP_DIR/$file" ] && [ ! -f "$target_dir/$file" ]; then
        echo_status "Restoring $file from backup to $target_dir/"
        cp "$BACKUP_DIR/$file" "$target_dir/"
    # Check if file doesn't exist in either location
    elif [ ! -f "$target_dir/$file" ]; then
        echo_warning "File not found: $file"
    else
        echo_status "File already in correct location: $target_dir/$file"
    fi
}

# Move Swift files to TracingCam directory
for file in "${SWIFT_FILES[@]}"; do
    ensure_file_location "$file" "TracingCam"
done

# Move resource files to TracingCam directory
for file in "${RESOURCE_FILES[@]}"; do
    ensure_file_location "$file" "TracingCam"
done

# Handle Assets.xcassets directory
if [ -d "Assets.xcassets" ]; then
    echo_status "Moving Assets.xcassets to TracingCam directory..."
    cp -r "Assets.xcassets" "$BACKUP_DIR/" # Backup first
    mv "Assets.xcassets" "TracingCam/"
elif [ ! -d "TracingCam/Assets.xcassets" ]; then
    echo_warning "Assets.xcassets not found"
fi

# Handle LaunchScreen.storyboard
if [ -f "LaunchScreen.storyboard" ]; then
    echo_status "Moving LaunchScreen.storyboard to Base.lproj directory..."
    cp "LaunchScreen.storyboard" "$BACKUP_DIR/" # Backup first
    mv "LaunchScreen.storyboard" "TracingCam/Base.lproj/"
elif [ -f "TracingCam/LaunchScreen.storyboard" ]; then
    echo_status "Moving LaunchScreen.storyboard from TracingCam to Base.lproj directory..."
    cp "TracingCam/LaunchScreen.storyboard" "$BACKUP_DIR/" # Backup first
    mv "TracingCam/LaunchScreen.storyboard" "TracingCam/Base.lproj/"
elif [ ! -f "TracingCam/Base.lproj/LaunchScreen.storyboard" ]; then
    echo_warning "LaunchScreen.storyboard not found"
fi

# 4. Remove old Xcode project and create a new one
echo_status "Removing old Xcode project..."
if [ -d "TracingCam.xcodeproj" ]; then
    rm -rf "TracingCam.xcodeproj"
fi

echo_status "Creating new Xcode project structure..."
mkdir -p "TracingCam.xcodeproj"

# Create project.pbxproj file with correct paths
cat > "TracingCam.xcodeproj/project.pbxproj" << 'EOL'
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		A1B2C3D4E5F6G7H8 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7H9 /* AppDelegate.swift */; };
		A1B2C3D4E5F6G7I0 /* SceneDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7I1 /* SceneDelegate.swift */; };
		A1B2C3D4E5F6G7I2 /* ContentView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7I3 /* ContentView.swift */; };
		A1B2C3D4E5F6G7I4 /* CameraService.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7I5 /* CameraService.swift */; };
		A1B2C3D4E5F6G7I6 /* AppSettings.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7I7 /* AppSettings.swift */; };
		A1B2C3D4E5F6G7I8 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7I9 /* Assets.xcassets */; };
		A1B2C3D4E5F6G7J0 /* LaunchScreen.storyboard in Resources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7J1 /* LaunchScreen.storyboard */; };
		A1B2C3D4E5F6G7J3 /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6G7J4 /* PrivacyInfo.xcprivacy */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A1B2C3D4E5F6G7J5 /* TracingCam.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TracingCam.app; sourceTree = BUILT_PRODUCTS_DIR; };
		A1B2C3D4E5F6G7H9 /* AppDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7I1 /* SceneDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SceneDelegate.swift; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7I3 /* ContentView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ContentView.swift; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7I5 /* CameraService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CameraService.swift; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7I7 /* AppSettings.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppSettings.swift; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7I9 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7J2 /* Base */ = {isa = PBXFileReference; lastKnownFileType = file.storyboard; name = Base; path = Base.lproj/LaunchScreen.storyboard; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7J4 /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };
		A1B2C3D4E5F6G7J6 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		A1B2C3D4E5F6G7J7 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A1B2C3D4E5F6G7J8 = {
			isa = PBXGroup;
			children = (
				A1B2C3D4E5F6G7J9 /* TracingCam */,
				A1B2C3D4E5F6G7K0 /* Products */,
			);
			sourceTree = "<group>";
		};
		A1B2C3D4E5F6G7K0 /* Products */ = {
			isa = PBXGroup;
			children = (
				A1B2C3D4E5F6G7J5 /* TracingCam.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		A1B2C3D4E5F6G7J9 /* TracingCam */ = {
			isa = PBXGroup;
			children = (
				A1B2C3D4E5F6G7H9 /* AppDelegate.swift */,
				A1B2C3D4E5F6G7I1 /* SceneDelegate.swift */,
				A1B2C3D4E5F6G7I3 /* ContentView.swift */,
				A1B2C3D4E5F6G7I5 /* CameraService.swift */,
				A1B2C3D4E5F6G7I7 /* AppSettings.swift */,
				A1B2C3D4E5F6G7I9 /* Assets.xcassets */,
				A1B2C3D4E5F6G7J1 /* LaunchScreen.storyboard */,
				A1B2C3D4E5F6G7J4 /* PrivacyInfo.xcprivacy */,
				A1B2C3D4E5F6G7J6 /* Info.plist */,
			);
			path = TracingCam;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A1B2C3D4E5F6G7K1 /* TracingCam */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A1B2C3D4E5F6G7K2 /* Build configuration list for PBXNativeTarget "TracingCam" */;
			buildPhases = (
				A1B2C3D4E5F6G7K3 /* Sources */,
				A1B2C3D4E5F6G7J7 /* Frameworks */,
				A1B2C3D4E5F6G7K4 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = TracingCam;
			productName = TracingCam;
			productReference = A1B2C3D4E5F6G7J5 /* TracingCam.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A1B2C3D4E5F6G7K5 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1430;
				LastUpgradeCheck = 1430;
				TargetAttributes = {
					A1B2C3D4E5F6G7K1 = {
						CreatedOnToolsVersion = 14.3;
					};
				};
			};
			buildConfigurationList = A1B2C3D4E5F6G7K6 /* Build configuration list for PBXProject "TracingCam" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A1B2C3D4E5F6G7J8;
			productRefGroup = A1B2C3D4E5F6G7K0 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A1B2C3D4E5F6G7K1 /* TracingCam */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		A1B2C3D4E5F6G7K4 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A1B2C3D4E5F6G7J0 /* LaunchScreen.storyboard in Resources */,
				A1B2C3D4E5F6G7I8 /* Assets.xcassets in Resources */,
				A1B2C3D4E5F6G7J3 /* PrivacyInfo.xcprivacy in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		A1B2C3D4E5F6G7K3 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A1B2C3D4E5F6G7H8 /* AppDelegate.swift in Sources */,
				A1B2C3D4E5F6G7I0 /* SceneDelegate.swift in Sources */,
				A1B2C3D4E5F6G7I2 /* ContentView.swift in Sources */,
				A1B2C3D4E5F6G7I4 /* CameraService.swift in Sources */,
				A1B2C3D4E5F6G7I6 /* AppSettings.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXVariantGroup section */
		A1B2C3D4E5F6G7J1 /* LaunchScreen.storyboard */ = {
			isa = PBXVariantGroup;
			children = (
				A1B2C3D4E5F6G7J2 /* Base */,
			);
			name = LaunchScreen.storyboard;
			sourceTree = "<group>";
		};
/* End PBXVariantGroup section */

/* Begin XCBuildConfiguration section */
		A1B2C3D4E5F6G7K7 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 15.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		A1B2C3D4E5F6G7K8 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 15.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				VALIDATE_PRODUCT = YES;
			};
			name = Release;
		};
		A1B2C3D4E5F6G7K9 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = TracingCam/Info.plist;
				INFOPLIST_KEY_NSCameraUsageDescription = "TracingCam needs camera access to provide a live camera feed for tracing images.";
				INFOPLIST_KEY_NSPhotoLibraryUsageDescription = "TracingCam needs photo library access to select images for tracing overlays.";
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.TracingCam;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
		A1B2C3D4E5F6G7L0 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = TracingCam/Info.plist;
				INFOPLIST_KEY_NSCameraUsageDescription = "TracingCam needs camera access to provide a live camera feed for tracing images.";
				INFOPLIST_KEY_NSPhotoLibraryUsageDescription = "TracingCam needs photo library access to select images for tracing overlays.";
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.TracingCam;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A1B2C3D4E5F6G7K6 /* Build configuration list for PBXProject "TracingCam" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A1B2C3D4E5F6G7K7 /* Debug */,
				A1B2C3D4E5F6G7K8 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		A1B2C3D4E5F6G7K2 /* Build configuration list for PBXNativeTarget "TracingCam" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A1B2C3D4E5F6G7K9 /* Debug */,
				A1B2C3D4E5F6G7L0 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = A1B2C3D4E5F6G7K5 /* Project object */;
}
EOL

# Create xcworkspace file structure
mkdir -p "TracingCam.xcodeproj/project.xcworkspace"
cat > "TracingCam.xcodeproj/project.xcworkspace/contents.xcworkspacedata" << 'EOL'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
EOL

# Create xcscheme file structure
mkdir -p "TracingCam.xcodeproj/xcshareddata/xcschemes"
cat > "TracingCam.xcodeproj/xcshareddata/xcschemes/TracingCam.xcscheme" << 'EOL'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1430"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "A1B2C3D4E5F6G7K1"
               BuildableName = "TracingCam.app"
               BlueprintName = "TracingCam"
               ReferencedContainer = "container:TracingCam.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A1B2C3D4E5F6G7K1"
            BuildableName = "TracingCam.app"
            BlueprintName = "TracingCam"
            ReferencedContainer = "container:TracingCam.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A1B2C3D4E5F6G7K1"
            BuildableName = "TracingCam.app"
            BlueprintName = "TracingCam"
            ReferencedContainer = "container:TracingCam.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
EOL

# 5. Verify all required files exist
echo_status "Verifying all required files exist..."

MISSING_FILES=0

# Function to check if a file exists
function check_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo_error "Missing required file: $file"
        MISSING_FILES=$((MISSING_FILES + 1))
    else
        echo_status "Found required file: $file"
    fi
}

# Check all required files
check_file "TracingCam/AppDelegate.swift"
check_file "TracingCam/SceneDelegate.swift"
check_file "TracingCam/ContentView.swift"
check_file "TracingCam/CameraService.swift"
check_file "TracingCam/AppSettings.swift"
check_file "TracingCam/Info.plist"
check_file "TracingCam/PrivacyInfo.xcprivacy"
check_file "TracingCam/Base.lproj/LaunchScreen.storyboard"

# Check if Assets.xcassets directory exists
if [ ! -d "TracingCam/Assets.xcassets" ]; then
    echo_error "Missing required directory: TracingCam/Assets.xcassets"
    MISSING_FILES=$((MISSING_FILES + 1))
else
    echo_status "Found required directory: TracingCam/Assets.xcassets"
fi

# If any files are missing, try to recover them from backup
if [ $MISSING_FILES -gt 0 ]; then
    echo_warning "$MISSING_FILES required files are missing. Attempting to recover from backup..."
    
    # Look for backup files in all backup directories
    for backup_dir in backup_*; do
        if [ -d "$backup_dir" ]; then
            echo_status "Checking backup directory: $backup_dir"
            
            # Try to recover each missing file
            for file in AppDelegate.swift SceneDelegate.swift ContentView.swift CameraService.swift AppSettings.swift Info.plist PrivacyInfo.xcprivacy; do
                if [ ! -f "TracingCam/$file" ] && [ -f "$backup_dir/$file" ]; then
                    echo_status "Recovering $file from $backup_dir"
                    cp "$backup_dir/$file" "TracingCam/"
                fi
            done
            
            # Try to recover LaunchScreen.storyboard
            if [ ! -f "TracingCam/Base.lproj/LaunchScreen.storyboard" ] && [ -f "$backup_dir/LaunchScreen.storyboard" ]; then
                echo_status "Recovering LaunchScreen.storyboard from $backup_dir"
                cp "$backup_dir/LaunchScreen.storyboard" "TracingCam/Base.lproj/"
            fi
            
            # Try to recover Assets.xcassets
            if [ ! -d "TracingCam/Assets.xcassets" ] && [ -d "$backup_dir/Assets.xcassets" ]; then
                echo_status "Recovering Assets.xcassets from $backup_dir"
                cp -r "$backup_dir/Assets.xcassets" "TracingCam/"
            fi
        fi
    done
fi

# 6. Commit changes to git if available
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo_status "Committing changes to git..."
    git add .
    git commit -m "Complete project structure fix: clean Xcode project with correct file references"
    echo_status "Changes committed to git."
fi

echo_status "Project fix completed!"
echo_status "You can now open the project in Xcode by running: open TracingCam.xcodeproj"

# Make the script executable
chmod +x "$0"
