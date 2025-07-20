import UIKit
import SwiftUI

class AppSettings: ObservableObject {
    // Singleton instance
    static let shared = AppSettings()
    
    // Published properties to notify views when changes occur
    @Published var overlayImageURL: URL? {
        didSet {
            saveSettings()
        }
    }
    
    @Published var imagePosition: CGPoint {
        didSet {
            saveSettings()
        }
    }
    
    @Published var imageScale: CGFloat {
        didSet {
            saveSettings()
        }
    }
    
    @Published var imageOpacity: Double {
        didSet {
            saveSettings()
        }
    }
    
    // Default values
    private let defaultOpacity: Double = 0.5 // 50% opacity
    private let defaultScale: CGFloat = 0.5 // 50% width
    private let defaultPosition: CGPoint = CGPoint(x: 0, y: 0) // Centered (will be adjusted based on screen size)
    
    // Keys for UserDefaults
    private enum Keys {
        static let imageURLString = "overlayImageURLString"
        static let positionX = "imagePositionX"
        static let positionY = "imagePositionY"
        static let scale = "imageScale"
        static let opacity = "imageOpacity"
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
        overlayImageURL = url
        resetToDefaults()
    }
    
    // Save settings to UserDefaults
    private func saveSettings() {
        let defaults = UserDefaults.standard
        
        // Save image URL as string
        if let url = overlayImageURL {
            defaults.set(url.absoluteString, forKey: Keys.imageURLString)
        }
        
        // Save position
        defaults.set(imagePosition.x, forKey: Keys.positionX)
        defaults.set(imagePosition.y, forKey: Keys.positionY)
        
        // Save scale and opacity
        defaults.set(imageScale, forKey: Keys.scale)
        defaults.set(imageOpacity, forKey: Keys.opacity)
    }
    
    // Load settings from UserDefaults
    private func loadSettings() {
        let defaults = UserDefaults.standard
        
        // Load image URL
        if let urlString = defaults.string(forKey: Keys.imageURLString),
           let url = URL(string: urlString) {
            overlayImageURL = url
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
    }
}
