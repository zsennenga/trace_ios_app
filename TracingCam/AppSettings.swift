import UIKit
import SwiftUI

class AppSettings: ObservableObject {
    // Singleton instance
    static let shared = AppSettings()
    
    // Published properties to notify views when changes occur
    @Published var overlayImageURL: URL? = nil {
        didSet {
            saveSettings()
        }
    }
    
    @Published var imagePosition: CGPoint = CGPoint(x: 0, y: 0) {
        didSet {
            saveSettings()
        }
    }
    
    @Published var imageScale: CGFloat = 0.5 {
        didSet {
            saveSettings()
        }
    }
    
    @Published var imageOpacity: Double = 0.5 {
        didSet {
            saveSettings()
        }
    }

    // NEW: rotation angle in radians
    @Published var imageRotation: Double = 0.0 {
        didSet {
            saveSettings()
        }
    }
    
    // Default values
    private let defaultOpacity: Double = 0.5 // 50% opacity
    private let defaultScale: CGFloat = 0.5 // 50% width
    private let defaultPosition: CGPoint = CGPoint(x: 0, y: 0) // Centered (will be adjusted based on screen size)
    private let defaultRotation: Double = 0.0 // No rotation
    
    // Convenience to documents directory for local image cache
    // Computed each time to avoid stale paths and remove force-unwraps.
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // Keys for UserDefaults
    private enum Keys {
        static let imageURLString = "overlayImageURLString"
        static let positionX = "imagePositionX"
        static let positionY = "imagePositionY"
        static let scale = "imageScale"
        static let opacity = "imageOpacity"
        static let rotation = "imageRotation"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }
    
    // Private initializer for singleton
    private init() {
        // Load saved settings or use defaults
        loadSettings()
    }
    
    // Check if this is the first launch
    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: Keys.hasLaunchedBefore)
    }
    
    // Mark app as launched
    func markAsLaunched() {
        UserDefaults.standard.set(true, forKey: Keys.hasLaunchedBefore)
    }
    
    // Reset settings to default values
    func resetToDefaults() {
        imagePosition = defaultPosition
        imageScale = defaultScale
        imageOpacity = defaultOpacity
        // Note: We don't reset the image URL here as it's handled separately
    }
    
    // Reset all settings including image when selecting a new image
    func resetForNewImage(with url: URL) {
        // Remove any previously cached images to avoid storage bloat
        cleanUpOldImages(keeping: url)
        overlayImageURL = url
        resetToDefaults()
    }
    
    /// Remove previously stored overlay images in documents directory except the one we want to keep
    private func cleanUpOldImages(keeping urlToKeep: URL?) {
        let fm = FileManager.default
        // Normalise the URL we want to keep once so that path-comparisons are reliable
        let keepURL = urlToKeep?.standardizedFileURL
        do {
            let files = try fm.contentsOfDirectory(at: documentsDirectory,
                                                   includingPropertiesForKeys: nil)
            for file in files {
                let stdFile = file.standardizedFileURL
                
                // Skip the file we want to keep
                if let keepURL = keepURL, keepURL == stdFile {
#if DEBUG
                    print("AppSettings clean-up: keeping current overlay image \(stdFile.lastPathComponent)")
#endif
                    continue
                }

                // Delete only if it matches our overlay image criteria
                guard isOverlayImage(file) else { continue }

                // Extra safety: ensure file is deletable
                guard fm.fileExists(atPath: stdFile.path),
                      fm.isDeletableFile(atPath: stdFile.path) else {
#if DEBUG
                    print("AppSettings clean-up: file \(stdFile.lastPathComponent) not deletable or missing – skipping")
#endif
                    continue
                }

                do {
                    try fm.removeItem(at: stdFile)
#if DEBUG
                    print("AppSettings clean-up: deleted old overlay image \(stdFile.lastPathComponent)")
#endif
                } catch {
                    // Log but do not crash – non-critical cleanup failure
                    print("AppSettings clean-up error (\(stdFile.lastPathComponent)): \(error.localizedDescription)")
                }
            }
        } catch {
            print("AppSettings could not enumerate documents directory: \(error.localizedDescription)")
        }
    }

    /// Determines whether a given URL points to an image file we created for overlay use.
    /// Current heuristic:  check common image path extensions.
    private func isOverlayImage(_ url: URL) -> Bool {
        let validExtensions = ["jpg", "jpeg", "png", "heic"]
        return validExtensions.contains(url.pathExtension.lowercased())
    }

    // Save settings to UserDefaults
    private func saveSettings() {
        let defaults = UserDefaults.standard
        
        // Save image URL as string
        if let url = overlayImageURL {
            // Persist only the normalised on-disk *path* to avoid percent-encoding
            // or sandbox-container-relocation issues that can arise across launches.
            let path = url.standardizedFileURL.path
#if DEBUG
            print("[AppSettings] Saving overlay image URL → \(path)")
#endif
            defaults.set(path, forKey: Keys.imageURLString)
        } else {
            // Remove key when image is cleared
            defaults.removeObject(forKey: Keys.imageURLString)
        }
        
        // Save position
        defaults.set(imagePosition.x, forKey: Keys.positionX)
        defaults.set(imagePosition.y, forKey: Keys.positionY)
        
        // Save scale and opacity
        defaults.set(imageScale, forKey: Keys.scale)
        defaults.set(imageOpacity, forKey: Keys.opacity)

        // Save rotation
        defaults.set(imageRotation, forKey: Keys.rotation)
    }
    
    // Load settings from UserDefaults
    private func loadSettings() {
        let defaults = UserDefaults.standard
        
        // Load image URL
        if let storedPath = defaults.string(forKey: Keys.imageURLString) {
            let fileURL = URL(fileURLWithPath: storedPath)
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) && fm.isReadableFile(atPath: fileURL.path) {
#if DEBUG
                print("[AppSettings] Loaded overlay image URL ← \(fileURL.path)")
#endif
                overlayImageURL = fileURL.standardizedFileURL
            } else {
#if DEBUG
                print("[AppSettings] Stored overlay image path '\(fileURL.path)' not reachable – clearing reference")
#endif
                overlayImageURL = nil
            }
        } else {
            overlayImageURL = nil
        }
        
        // Load position or use default
        let x = defaults.object(forKey: Keys.positionX) as? CGFloat ?? defaultPosition.x
        let y = defaults.object(forKey: Keys.positionY) as? CGFloat ?? defaultPosition.y
        imagePosition = CGPoint(x: x, y: y)
        
        // Load scale or use default
        imageScale = defaults.object(forKey: Keys.scale) as? CGFloat ?? defaultScale
        
        // Load opacity or use default
        imageOpacity = defaults.object(forKey: Keys.opacity) as? Double ?? defaultOpacity

        // Load rotation or use default
        imageRotation = defaults.object(forKey: Keys.rotation) as? Double ?? defaultRotation
    }
}
