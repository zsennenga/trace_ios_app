import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import Combine

/// Camera service that handles all camera interactions including permissions,
/// session setup, and capture. It provides a `previewLayer` for displaying the camera
/// preview layer.  It is **privacy–aware** (requests permission only when needed) and
/// **resource-aware** (automatically pauses the session while the app is backgrounded
/// and frees all resources on de-init).  No captured frames ever leave the device.
enum CameraError: Error, CustomStringConvertible {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case createCaptureInput(Error)
    case deniedAuthorization
    case restrictedAuthorization
    case unknownAuthorization
    case sessionStartFailed
    case deviceUnresponsive
    case configurationFailed
    case deviceLocked
    case noVideoSignal
    
    var description: String {
        switch self {
        case .cameraUnavailable:
            return "Camera hardware is unavailable"
        case .cannotAddInput:
            return "Cannot add camera input to session"
        case .cannotAddOutput:
            return "Cannot add video output to session"
        case .createCaptureInput(let error):
            return "Failed to create capture input: \(error.localizedDescription)"
        case .deniedAuthorization:
            return "Camera access denied by user"
        case .restrictedAuthorization:
            return "Camera access restricted"
        case .unknownAuthorization:
            return "Unknown camera authorization status"
        case .sessionStartFailed:
            return "Camera session failed to start"
        case .deviceUnresponsive:
            return "Camera device is unresponsive"
        case .configurationFailed:
            return "Camera configuration failed"
        case .deviceLocked:
            return "Camera device is locked or in use by another app"
        case .noVideoSignal:
            return "No video signal detected from camera"
        }
    }
}

class CameraService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: - Published Properties
    @Published var isAuthorized: Bool = false
    @Published var error: CameraError?
    @Published var isRunning: Bool = false
    @Published var cameraStatus: String = "Not initialized"
    @Published var canPerformCameraOperations: Bool = true
    
    // MARK: - Camera Properties
    let session = AVCaptureSession()
    private var isCaptureSessionConfigured = false
    private let sessionQueue = DispatchQueue(label: "com.tracingcam.sessionQueue", qos: .userInitiated)
    private let mainSetupQueue = DispatchQueue(label: "com.tracingcam.mainSetupQueue", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    // Setup state tracking
    private var isSettingUp = false
    private var isInConfiguration = false
    private var setupRetryCount = 0
    private let maxSetupRetries = 3
    private var setupTimer: Timer?
    private var configurationCompletionTime: Date?
    private let configurationCooldownPeriod: TimeInterval = 1.0 // 1 second cooldown after configuration
    
    // Session state tracking
    private var sessionStartTime: Date?
    private var lastSessionStatusCheck: Date?
    private var statusCheckTimer: Timer?
    private let statusCheckInterval: TimeInterval = 2.0
    private let maxConsecutiveFailures = 3
    private var consecutiveStatusCheckFailures = 0
    
    // Video signal monitoring
    private var hasReceivedVideoData = false
    private var lastFrameTime: Date?
    
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    // MARK: - Initialization & Lifecycle
    override init() {
        super.init()
        print("[CameraService] Initializing camera service")
        
        // Observe app life-cycle to pause / resume camera properly
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Check for camera interruption (phone calls, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        
        // Check for camera interruption ended
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
        
        // Monitor for session interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )

        // Listen for preview-layer dismantle so we don't keep a dangling reference
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(previewLayerWasDismantled),
            name: NSNotification.Name("CameraPreviewDismantled"),
            object: nil
        )
        
        checkPermissions()
    }
    
    deinit {
        print("[CameraService] Deinitializing camera service")
        NotificationCenter.default.removeObserver(self)
        cancelSetupTimer()
        stopStatusCheckTimer()
        teardownSession()
    }

    // MARK: - Preview-layer cleanup
    @objc private func previewLayerWasDismantled() {
        DispatchQueue.main.async {
            if self.previewLayer != nil {
                print("[CameraService] Preview layer dismantled – clearing reference")
            }
            self.previewLayer = nil
        }
    }
    
    // MARK: - Public Camera Operation Safety Check
    
    /// Check if camera operations can be performed safely
    /// This method can be called by ContentView to check if it's safe to call camera methods
    func canSafelyPerformCameraOperations() -> Bool {
        // Check if we're in the middle of a configuration
        if isInConfiguration {
            print("[CameraService] Camera operations unsafe: configuration in progress")
            return false
        }
        
        // Check if we're in the cooldown period after a configuration
        if let completionTime = configurationCompletionTime,
           Date().timeIntervalSince(completionTime) < configurationCooldownPeriod {
            print("[CameraService] Camera operations unsafe: in cooldown period after configuration")
            return false
        }
        
        // Check if we're in the middle of setup
        if isSettingUp {
            print("[CameraService] Camera operations unsafe: setup in progress")
            return false
        }
        
        return true
    }
    
    // MARK: - Permission Handling
    func checkPermissions() {
        print("[CameraService] Checking camera permissions")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.isAuthorized = true
            print("[CameraService] Camera access already authorized")
        case .notDetermined:
            print("[CameraService] Camera permission not determined, requesting")
            requestPermissions()
        case .denied:
            self.isAuthorized = false
            self.error = .deniedAuthorization
            print("[CameraService] Camera access denied")
        case .restricted:
            self.isAuthorized = false
            self.error = .restrictedAuthorization
            print("[CameraService] Camera access restricted")
        @unknown default:
            self.isAuthorized = false
            self.error = .unknownAuthorization
            print("[CameraService] Unknown camera authorization status")
        }
    }
    
    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAuthorized = granted
                print("[CameraService] Camera permission request result: \(granted ? "granted" : "denied")")
                
                if granted {
                    // If permission was just granted, automatically set up camera
                    self.setupCamera()
                } else {
                    self.error = .deniedAuthorization
                }
            }
        }
    }
    
    // MARK: - Permission Alert helper
    func makePermissionAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Camera Access Needed",
            message: "Camera access is required for this app. Please enable it in Settings.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(
            title: "Open Settings",
            style: .default
        ) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        return alert
    }
    
    // MARK: - App life-cycle
    @objc private func appDidEnterBackground() {
        print("[CameraService] App entered background - stopping camera")
        stopStatusCheckTimer()
        stopSession()
    }
    
    @objc private func appWillEnterForeground() {
        print("[CameraService] App entered foreground - restarting camera")
        // Only restart if we already had permission
        if isAuthorized {
            safelyResetAndRestartCamera()
        }
    }
    
    @objc private func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        print("[CameraService] Capture session runtime error: \(error.localizedDescription)")
        
        // Handle session errors
        if error.code == .mediaServicesWereReset {
            print("[CameraService] Media services were reset - attempting recovery")
            safelyResetAndRestartCamera()
        }
    }
    
    @objc private func sessionInterruptionEnded(notification: NSNotification) {
        print("[CameraService] Session interruption ended - restarting camera")
        // Add a delay to ensure the system is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startSession()
        }
    }
    
    @objc private func sessionWasInterrupted(notification: NSNotification) {
        guard let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: userInfoValue) else {
            return
        }
        
        print("[CameraService] Session was interrupted with reason: \(reasonString(for: reason))")
        
        // Update status
        DispatchQueue.main.async {
            self.isRunning = false
            self.cameraStatus = "Interrupted: \(self.reasonString(for: reason))"
        }
    }
    
    private func reasonString(for reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return "Device not available in background"
        case .audioDeviceInUseByAnotherClient:
            return "Audio device in use"
        case .videoDeviceInUseByAnotherClient:
            return "Camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "Camera not available with multiple apps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "Camera unavailable due to system pressure"
        @unknown default:
            return "Unknown reason (\(reason.rawValue))"
        }
    }
    
    // MARK: - Camera Status Checking
    
    /// Start periodic camera status checks
    private func startStatusCheckTimer() {
        stopStatusCheckTimer()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[CameraService] Starting camera status check timer")
            
            self.statusCheckTimer = Timer.scheduledTimer(
                withTimeInterval: self.statusCheckInterval,
                repeats: true
            ) { [weak self] _ in
                self?.checkCameraStatus()
            }
        }
    }
    
    /// Stop periodic camera status checks
    private func stopStatusCheckTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.statusCheckTimer?.invalidate()
            self?.statusCheckTimer = nil
        }
    }
    
    /// Comprehensive check of camera status
    private func checkCameraStatus() {
        guard isAuthorized && isCaptureSessionConfigured else {
            return
        }
        
        let isSessionRunning = session.isRunning
        let hasVideoInput = videoDeviceInput != nil
        let deviceConnected = videoDeviceInput?.device.isConnected ?? false
        let deviceHasMediaType = videoDeviceInput?.device.hasMediaType(.video) ?? false
        let previewHasConnection = previewLayer?.connection?.isEnabled ?? false
        let previewIsValid = previewLayer != nil  // Changed from isValid to a nil check
        
        // Check if camera device is locked (in use by another process)
        var isDeviceLocked = false
        if let device = videoDeviceInput?.device {
            do {
                try device.lockForConfiguration()
                device.unlockForConfiguration()
            } catch {
                isDeviceLocked = true
            }
        }
        
        // Calculate time since last frame
        var timeSinceLastFrame: TimeInterval? = nil
        if let lastFrameTime = lastFrameTime {
            timeSinceLastFrame = Date().timeIntervalSince(lastFrameTime)
        }
        
        // Build status string
        let statusComponents = [
            "Session running: \(isSessionRunning)",
            "Has video input: \(hasVideoInput)",
            "Device connected: \(deviceConnected)",
            "Device has media: \(deviceHasMediaType)",
            "Preview connected: \(previewHasConnection)",
            "Preview valid: \(previewIsValid)",
            "Device locked: \(isDeviceLocked)",
            "Has received frames: \(self.hasReceivedVideoData)",
            "In configuration: \(self.isInConfiguration)",
            timeSinceLastFrame != nil ? String(format: "Last frame: %.1fs ago", timeSinceLastFrame!) : "No frames yet"
        ]
        
        let statusString = statusComponents.joined(separator: ", ")
        print("[CameraService] Camera status check: \(statusString)")
        
        // Update published status
        DispatchQueue.main.async {
            self.cameraStatus = statusString
            self.isRunning = isSessionRunning && hasVideoInput && deviceConnected && previewHasConnection
            self.canPerformCameraOperations = !self.isInConfiguration && !self.isSettingUp
        }
        
        // Detect problems
        let hasProblems = !isSessionRunning || !hasVideoInput || !deviceConnected || 
                         !deviceHasMediaType || !previewHasConnection || !previewIsValid ||
                         isDeviceLocked || (self.hasReceivedVideoData && timeSinceLastFrame != nil && timeSinceLastFrame! > 3.0)
        
        if hasProblems {
            consecutiveStatusCheckFailures += 1
            print("[CameraService] Camera status check failed (\(consecutiveStatusCheckFailures)/\(maxConsecutiveFailures))")
            
            // After multiple consecutive failures, try to recover
            if consecutiveStatusCheckFailures >= maxConsecutiveFailures {
                print("[CameraService] Multiple consecutive camera status check failures - attempting recovery")
                
                // Set appropriate error
                DispatchQueue.main.async {
                    if isDeviceLocked {
                        self.error = .deviceLocked
                    } else if !self.hasReceivedVideoData || (timeSinceLastFrame != nil && timeSinceLastFrame! > 5.0) {
                        self.error = .noVideoSignal
                    } else {
                        self.error = .sessionStartFailed
                    }
                }
                
                // Attempt recovery
                safelyResetAndRestartCamera()
                consecutiveStatusCheckFailures = 0
            }
        } else {
            // Reset failure counter on successful check
            consecutiveStatusCheckFailures = 0
            
            // Clear error if everything is working
            if error != nil && isSessionRunning && hasVideoInput && deviceConnected {
                DispatchQueue.main.async {
                    self.error = nil
                }
            }
        }
    }
    
    /// Public method to force camera refresh - can be called from UI if needed
    func refreshCamera() {
        print("[CameraService] Manual camera refresh requested")
        
        // First check if it's safe to perform camera operations
        if !canSafelyPerformCameraOperations() {
            print("[CameraService] ⚠️ Cannot refresh camera now - operations unsafe")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                print("[CameraService] Retrying camera refresh after delay")
                self?.refreshCamera()
            }
            return
        }
        
        // Use the new forceCameraRefresh method for more comprehensive refresh
        forceCameraRefresh()
    }
    
    // MARK: - Debug Helpers
    /// Captures a snapshot of the current `previewLayer` and writes it as a JPEG
    /// into the application's Documents directory.  Useful for diagnosing whether
    /// the layer is being rendered but not displayed.
    func capturePreviewSnapshot() {
        DispatchQueue.main.async {
            guard let layer = self.previewLayer else {
                print("[CameraService][DEBUG] No previewLayer – cannot capture snapshot")
                return
            }
            let bounds = layer.bounds
            guard bounds.width > 1, bounds.height > 1 else {
                print("[CameraService][DEBUG] previewLayer bounds are zero – skipping snapshot")
                return
            }

            let renderer = UIGraphicsImageRenderer(size: bounds.size)
            let image = renderer.image { ctx in
                layer.render(in: ctx.cgContext)
            }

            guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
                print("[CameraService][DEBUG] Failed to create JPEG data from snapshot")
                return
            }

            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let timestamp = Int(Date().timeIntervalSince1970)
            let fileURL = docsDir.appendingPathComponent("preview_snapshot_\(timestamp).jpg")

            do {
                try jpegData.write(to: fileURL, options: .atomic)
                print("[CameraService][DEBUG] Preview snapshot saved to \(fileURL.path)")
            } catch {
                print("[CameraService][DEBUG] Failed to save snapshot: \(error.localizedDescription)")
            }
        }
    }

    /// Force a complete camera refresh including preview layer recreation
    /// This method is more aggressive than safelyResetAndRestartCamera and will:
    /// 1. Force the preview layer to be recreated
    /// 2. Ensure the session is brought to the foreground
    /// 3. Reset any interruption state
    /// 4. Completely restart the camera session
    func forceCameraRefresh() {
        print("[CameraService] Forcing complete camera refresh with preview layer recreation")
        
        // Update operation safety status
        DispatchQueue.main.async {
            self.canPerformCameraOperations = false
        }
        
        // First make sure we're not in the middle of a configuration
        if isInConfiguration {
            print("[CameraService] ⚠️ Attempted to force refresh during configuration - deferring")
            // Defer the refresh until after current configuration completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.forceCameraRefresh()
            }
            return
        }
        
        // Stop any existing session first
        stopSession()
        
        // Clear the preview layer reference to force a new one to be created
        DispatchQueue.main.async { [weak self] in
            print("[CameraService] Discarding existing preview layer to force recreation")
            if let layer = self?.previewLayer {
                layer.removeFromSuperlayer()
            }
            self?.previewLayer = nil
        }
        
        // Then perform the reset on the session queue
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            print("[CameraService] Executing camera reset with preview layer recreation")
            
            // Force the app to be considered in foreground mode for the camera
            self.session.automaticallyConfiguresApplicationAudioSession = false
            
            // Reset the camera configuration
            self.resetCameraConfiguration()
            
            // After reset, ensure we're ready for a fresh start
            DispatchQueue.main.async {
                // Reset any interruption state
                self.hasReceivedVideoData = false
                self.lastFrameTime = nil
                self.consecutiveStatusCheckFailures = 0
                
                // Update operation safety status
                self.canPerformCameraOperations = true
                
                // Notify that preview layer needs recreation
                NotificationCenter.default.post(name: NSNotification.Name("CameraPreviewNeedsRecreation"), object: nil)
            }
        }
    }
    
    /// Check if the camera device is in a valid state
    private func isCameraDeviceValid() -> Bool {
        guard let device = videoDeviceInput?.device else {
            return false
        }
        
        let isConnected = device.isConnected
        let hasMediaType = device.hasMediaType(.video)
        
        print("[CameraService] Camera device check: connected=\(isConnected), hasVideo=\(hasMediaType)")
        
        return isConnected && hasMediaType
    }
    
    // MARK: - Camera Setup
    func setupCamera() {
        guard isAuthorized else {
            print("[CameraService] Not authorized to access camera")
            return
        }
        
        print("[CameraService] Setting up camera")
        
        // Update operation safety status
        DispatchQueue.main.async {
            self.canPerformCameraOperations = false
        }
        
        // Prevent multiple concurrent setups
        guard !isSettingUp else {
            print("[CameraService] Setup already in progress, skipping")
            return
        }
        
        // Reset error state when starting setup
        DispatchQueue.main.async {
            self.error = nil
        }
        
        isSettingUp = true
        setupRetryCount = 0
        
        // Start setup process on dedicated queue
        mainSetupQueue.async { [weak self] in
            guard let self = self else { return }
            self.performCameraSetup()
        }
    }
    
    private func performCameraSetup() {
        print("[CameraService] Performing camera setup (attempt \(setupRetryCount + 1) of \(maxSetupRetries))")
        
        // Schedule a timeout for setup
        scheduleSetupTimeout()
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.configureCaptureSession { success in
                // Clear the timeout timer since setup completed (successfully or not)
                self.cancelSetupTimer()
                
                if success {
                    print("[CameraService] Camera configuration successful")
                    
                    // Record the configuration completion time
                    self.configurationCompletionTime = Date()
                    
                    // Add a delay before starting the session to avoid race conditions
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        print("[CameraService] Starting camera session after delay")
                        self.startSession()
                        
                        // Verify session started successfully after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.verifySessionRunning()
                        }
                    }
                } else {
                    print("[CameraService] Camera configuration failed")
                    self.handleSetupFailure()
                }
                
                // Setup process is complete
                self.isSettingUp = false
                
                // Update operation safety status
                DispatchQueue.main.async {
                    self.canPerformCameraOperations = true
                }
            }
        }
    }
    
    private func scheduleSetupTimeout() {
        // Cancel any existing timer
        cancelSetupTimer()
        
        // Create new timer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[CameraService] Scheduling setup timeout")
            
            self.setupTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                print("[CameraService] Setup timeout occurred")
                self.handleSetupTimeout()
            }
        }
    }
    
    private func cancelSetupTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.setupTimer?.invalidate()
            self?.setupTimer = nil
        }
    }
    
    private func handleSetupTimeout() {
        print("[CameraService] Camera setup timed out")
        
        // Check if device is responsive
        if !isDeviceResponsive() {
            print("[CameraService] Device appears to be unresponsive")
            DispatchQueue.main.async {
                self.error = .deviceUnresponsive
            }
            isSettingUp = false
            
            // Update operation safety status
            DispatchQueue.main.async {
                self.canPerformCameraOperations = true
            }
            return
        }
        
        // Otherwise try again
        handleSetupFailure()
    }
    
    private func handleSetupFailure() {
        setupRetryCount += 1
        
        if setupRetryCount < maxSetupRetries {
            print("[CameraService] Retrying camera setup (\(setupRetryCount)/\(maxSetupRetries))")
            
            // Wait a moment before retrying
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.performCameraSetup()
            }
        } else {
            print("[CameraService] Maximum setup retries reached, giving up")
            DispatchQueue.main.async {
                self.error = .configurationFailed
            }
            isSettingUp = false
            
            // Update operation safety status
            DispatchQueue.main.async {
                self.canPerformCameraOperations = true
            }
        }
    }
    
    private func isDeviceResponsive() -> Bool {
        // Simple check for device responsiveness
        // If the main thread is blocked, this operation will be delayed
        let startTime = Date()
        var isResponsive = false
        
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.async {
            isResponsive = true
            semaphore.signal()
        }
        
        // Wait for a short time for the main thread to respond
        _ = semaphore.wait(timeout: .now() + 2.0)
        
        let responseTime = Date().timeIntervalSince(startTime)
        print("[CameraService] Device responsiveness check: \(isResponsive ? "responsive" : "unresponsive") in \(responseTime) seconds")
        
        return isResponsive && responseTime < 1.0
    }
    
    // MARK: - Safe Reset and Restart
    
    /// Thread-safe way to reset and restart the camera
    /// This is the public entry point that ensures proper sequencing
    private func safelyResetAndRestartCamera() {
        print("[CameraService] Safely resetting and restarting camera")
        
        // Update operation safety status
        DispatchQueue.main.async {
            self.canPerformCameraOperations = false
        }
        
        // First make sure we're not in the middle of a configuration
        if isInConfiguration {
            print("[CameraService] ⚠️ Attempted to reset camera during configuration - deferring")
            // Defer the reset until after current configuration completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.safelyResetAndRestartCamera()
            }
            return
        }
        
        // Stop any existing session first
        stopSession()
        
        // Then perform the reset on the session queue
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            print("[CameraService] Executing camera reset on session queue")
            self.resetCameraConfiguration()
        }
    }
    
    /// Internal method to reset the camera configuration
    /// Must be called on the session queue
    private func resetCameraConfiguration() {
        // Mark that we're entering configuration
        isInConfiguration = true
        print("[CameraService] Beginning camera configuration reset")
        
        // Begin configuration
        session.beginConfiguration()
        
        // Remove all inputs and outputs
        for input in session.inputs {
            session.removeInput(input)
        }
        
        for output in session.outputs {
            session.removeOutput(output)
        }
        
        // Commit configuration
        session.commitConfiguration()
        
        // Mark as not configured and reset state
        isCaptureSessionConfigured = false
        hasReceivedVideoData = false
        lastFrameTime = nil
        
        // IMPORTANT: Reset the configuration flag after configuration is complete
        isInConfiguration = false
        
        // Record the configuration completion time
        configurationCompletionTime = Date()
        
        print("[CameraService] Camera configuration reset complete")
        
        // Add a delay before restarting setup to avoid race conditions
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            print("[CameraService] Initiating new camera setup after delay")
            self.setupCamera()
        }
    }
    
    // MARK: - Session Configuration
    func configureCaptureSession(completionHandler: @escaping (_ success: Bool) -> Void) {
        print("[CameraService] Configuring capture session")
        
        // If already configured, just succeed
        guard !isCaptureSessionConfigured else {
            print("[CameraService] Session already configured, skipping")
            completionHandler(true)
            return
        }
        
        // Mark that we're entering configuration
        isInConfiguration = true
        
        // Begin configuration
        session.beginConfiguration()
        
        defer {
            print("[CameraService] Committing session configuration")
            session.commitConfiguration()
            
            // IMPORTANT: Reset the configuration flag after configuration is complete
            isInConfiguration = false
            
            // Record the configuration completion time
            configurationCompletionTime = Date()
        }
        
        // Set session preset
        session.sessionPreset = .high
        
        // Set up video device
        guard let videoDevice = getBestCamera() else {
            print("[CameraService] No suitable camera found")
            DispatchQueue.main.async {
                self.error = .cameraUnavailable
            }
            completionHandler(false)
            return
        }
        
        print("[CameraService] Using camera: \(videoDevice.localizedName)")
        
        // Configure camera for highest frame rate
        do {
            try configureFrameRate(for: videoDevice)
        } catch {
            print("[CameraService] Warning: Could not configure optimal frame rate: \(error.localizedDescription)")
            // Continue anyway, this is not fatal
        }
        
        // Add video input
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                print("[CameraService] Added camera input to session")
            } else {
                print("[CameraService] Cannot add camera input to session")
                DispatchQueue.main.async {
                    self.error = .cannotAddInput
                }
                completionHandler(false)
                return
            }
        } catch {
            print("[CameraService] Error creating camera input: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.error = .createCaptureInput(error)
            }
            completionHandler(false)
            return
        }
        
        // Add video output
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            print("[CameraService] Added video output to session")
        } else {
            print("[CameraService] Cannot add video output to session")
            DispatchQueue.main.async {
                self.error = .cannotAddOutput
            }
            completionHandler(false)
            return
        }
        
        // Mark as configured
        isCaptureSessionConfigured = true
        print("[CameraService] Capture session configuration completed successfully")
        completionHandler(true)
    }
    
    private func getBestCamera() -> AVCaptureDevice? {
        // Try to get the back ultra wide camera first
        if let ultraWideCamera = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            print("[CameraService] Found ultra wide back camera")
            return ultraWideCamera
        }
        
        // Fall back to wide angle
        if let wideCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            print("[CameraService] Found wide angle back camera")
            return wideCamera
        }
        
        // Last resort - any available camera
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: .unspecified
        )
        
        if let firstCamera = discoverySession.devices.first {
            print("[CameraService] Using fallback camera: \(firstCamera.localizedName)")
            return firstCamera
        }
        
        print("[CameraService] No cameras available")
        return nil
    }
    
    private func configureFrameRate(for device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        // Find highest frame rate available
        var bestFrameRateRange: AVFrameRateRange?
        // `maxFrameRate` is a `Double`; keep our accumulator the same type to
        // avoid Float/Double mismatches during comparison & assignment.
        var bestFrameRate: Double = 0
        
        for range in device.activeFormat.videoSupportedFrameRateRanges {
            // `maxFrameRate` is `Double`; `bestFrameRate` is also `Double`
            if range.maxFrameRate > bestFrameRate {
                bestFrameRate = range.maxFrameRate
                bestFrameRateRange = range
            }
        }
        
        if let frameRateRange = bestFrameRateRange {
            print("[CameraService] Setting frame rate to \(frameRateRange.maxFrameRate) fps")
            device.activeVideoMinFrameDuration = frameRateRange.minFrameDuration
            device.activeVideoMaxFrameDuration = frameRateRange.minFrameDuration
        }
    }
    
    // MARK: - Preview Layer
    func createPreviewLayer(for view: UIView) -> AVCaptureVideoPreviewLayer {
        print("[CameraService] Creating preview layer for view")
        print("[CameraService]   • Session running: \(session.isRunning)")
        print("[CameraService]   • Session inputs: \(session.inputs.count), outputs: \(session.outputs.count)")
        print("[CameraService]   • View dimensions: \(view.bounds.width)x\(view.bounds.height)")

        // If we already have a layer, reuse it (helps during hot-reloads)
        if let existingLayer = self.previewLayer {
            print("[CameraService] Re-using existing preview layer")
            
            // Ensure proper frame and position
            existingLayer.frame = view.bounds
            existingLayer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            
            // Force immediate layout update
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            existingLayer.layoutIfNeeded()
            CATransaction.commit()
            
            return existingLayer
        }

        // Create a new preview layer with explicit settings
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        
        // Configure visual appearance for better visibility
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.opacity = 1.0
        previewLayer.backgroundColor = UIColor.black.cgColor // Base background color
        
        // Set debug color to help identify layer presence (will be visible until camera feed appears)
        let debugColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0).cgColor
        previewLayer.backgroundColor = debugColor
        
        // Ensure layer is visible by setting proper z position
        previewLayer.zPosition = -1  // Behind other UI elements but visible
        
        // Set explicit frame with proper bounds and position
        let viewBounds = view.bounds
        previewLayer.frame = viewBounds
        previewLayer.bounds = CGRect(x: 0, y: 0, width: viewBounds.width, height: viewBounds.height)
        previewLayer.position = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        
        // Add rounded corners for visual debugging (will help identify if layer is present)
        previewLayer.cornerRadius = 0  // No corner radius for camera view
        previewLayer.masksToBounds = true
        
        // Store reference
        self.previewLayer = previewLayer

        // Validate connection and log detailed status
        if let connection = previewLayer.connection {
            print("[CameraService]   • Preview connection created (enabled=\(connection.isEnabled))")
            
            // Force orientation update immediately
            if connection.isVideoOrientationSupported {
                let orientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation)
                connection.videoOrientation = orientation
                print("[CameraService]   • Set initial orientation to: \(orientation.rawValue)")
            }
        } else {
            print("[CameraService]   ⚠️ Preview connection is nil")
        }
        
        // Log detailed layer properties for debugging
        print("[CameraService]   • Layer frame: \(previewLayer.frame)")
        print("[CameraService]   • Layer z-position: \(previewLayer.zPosition)")
        print("[CameraService]   • Layer opacity: \(previewLayer.opacity)")
        
        // Force immediate layout update
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.layoutIfNeeded()
        CATransaction.commit()

        return previewLayer
    }
    
    /// Force recreation of the preview layer, discarding any existing layer
    /// This is useful when the camera feed is not visible despite the camera being active
    func recreatePreviewLayer(for view: UIView) -> AVCaptureVideoPreviewLayer {
        print("[CameraService] Forcing preview layer recreation")
        
        // Remove any existing layer
        if let existingLayer = previewLayer {
            print("[CameraService] Removing existing preview layer")
            existingLayer.removeFromSuperlayer()
            self.previewLayer = nil
        }
        
        // Create a fresh layer with high visibility settings
        let newLayer = AVCaptureVideoPreviewLayer(session: session)
        
        // Configure for maximum visibility
        newLayer.videoGravity = .resizeAspectFill
        newLayer.opacity = 1.0
        
        // Use a distinctive background color so we can tell if the layer is visible
        newLayer.backgroundColor = UIColor(red: 0.2, green: 0.0, blue: 0.0, alpha: 1.0).cgColor
        
        // Ensure layer is visible in the view hierarchy
        newLayer.zPosition = -1
        
        // Set explicit frame with proper bounds and position
        let viewBounds = view.bounds
        newLayer.frame = viewBounds
        newLayer.position = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        
        // Add a subtle border to help identify the layer boundaries
        newLayer.borderColor = UIColor.red.withAlphaComponent(0.3).cgColor
        newLayer.borderWidth = 2
        
        // Store reference
        self.previewLayer = newLayer
        
        // Force connection to be enabled and set orientation
        if let connection = newLayer.connection {
            connection.isEnabled = true
            
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation)
            }
        }
        
        print("[CameraService] Created new preview layer with dimensions: \(newLayer.frame.width)x\(newLayer.frame.height)")
        
        // Force immediate layout update
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newLayer.layoutIfNeeded()
        CATransaction.commit()
        
        return newLayer
    }
    
    // MARK: - Session Control
    func startSession() {
        // Check if we can start the session
        guard !session.isRunning && isAuthorized && isCaptureSessionConfigured else {
            print("[CameraService] Cannot start session: running=\(session.isRunning), authorized=\(isAuthorized), configured=\(isCaptureSessionConfigured)")
            return
        }
        
        // CRITICAL: Never start a session during configuration
        if isInConfiguration {
            print("[CameraService] ⚠️ ERROR: Attempted to start session during configuration - ABORTING")
            DispatchQueue.main.async {
                self.error = .sessionStartFailed
            }
            return
        }
        
        // Check if we're in the cooldown period after configuration
        if let completionTime = configurationCompletionTime,
           Date().timeIntervalSince(completionTime) < configurationCooldownPeriod {
            print("[CameraService] ⚠️ Attempted to start session too soon after configuration - deferring")
            
            // Calculate remaining cooldown time
            let remainingCooldown = configurationCooldownPeriod - Date().timeIntervalSince(completionTime)
            
            // Defer the start until after cooldown completes
            DispatchQueue.main.asyncAfter(deadline: .now() + remainingCooldown + 0.1) { [weak self] in
                print("[CameraService] Cooldown period complete, starting session")
                self?.startSession()
            }
            return
        }
        
        print("[CameraService] Starting camera session")
        sessionStartTime = Date()
        
        // Force this to happen on the session queue for reliability
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Double check we're not in configuration mode
            guard !self.isInConfiguration else {
                print("[CameraService] ⚠️ ERROR: Configuration in progress, cannot start session")
                return
            }
            
            // Update orientation before starting
            self.updateVideoOrientation()
            
            // Start the session
            print("[CameraService] Starting session on session queue")
            self.session.startRunning()
            
            // Update state
            DispatchQueue.main.async {
                self.isRunning = self.session.isRunning
                print("[CameraService] Session running state: \(self.session.isRunning)")
                
                // Start status check timer
                if self.session.isRunning {
                    self.startStatusCheckTimer()
                }
            }
        }
    }
    
    private func verifySessionRunning() {
        print("[CameraService] Verifying session is running")
        
        if !session.isRunning {
            print("[CameraService] Session failed to start, retrying")
            
            // Try once more on the session queue
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                
                // Double check we're not in configuration mode
                guard !self.isInConfiguration else {
                    print("[CameraService] ⚠️ ERROR: Configuration in progress, cannot start session")
                    return
                }
                
                self.session.startRunning()
                
                // Final check
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !self.session.isRunning {
                        print("[CameraService] Session failed to start after retry")
                        self.error = .sessionStartFailed
                        
                        // Try a full reset as a last resort
                        self.safelyResetAndRestartCamera()
                    } else {
                        print("[CameraService] Session started successfully after retry")
                        self.isRunning = true
                        self.startStatusCheckTimer()
                        
                        // Schedule an additional verification to ensure we're getting frames
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            if !self.hasReceivedVideoData {
                                print("[CameraService] No video frames received after 2 seconds")
                                self.error = .noVideoSignal
                                self.safelyResetAndRestartCamera()
                            }
                        }
                    }
                }
            }
        } else {
            print("[CameraService] Session is running correctly")
            DispatchQueue.main.async {
                self.isRunning = true
                self.startStatusCheckTimer()
            }
        }
    }
    
    func stopSession() {
        guard session.isRunning else {
            print("[CameraService] Session already stopped")
            return
        }
        
        print("[CameraService] Stopping camera session")
        stopStatusCheckTimer()
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.stopRunning()
            
            // Update state on main thread
            DispatchQueue.main.async {
                self.isRunning = false
            }
            
            print("[CameraService] Camera session stopped")
        }
    }
    
    private func updateVideoOrientation() {
        if let connection = self.previewLayer?.connection,
           connection.isVideoOrientationSupported {
            let orientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation)
            connection.videoOrientation = orientation
            print("[CameraService] Updated video orientation to: \(orientation.rawValue)")
        }
    }
    
    /// Remove all inputs / outputs and allow the session to be deallocated.
    private func teardownSession() {
        print("[CameraService] Tearing down camera session")
        
        guard isCaptureSessionConfigured else {
            print("[CameraService] Session not configured, nothing to tear down")
            return
        }
        
        sessionQueue.async { [self] in
            print("[CameraService] Removing all inputs and outputs")
            
            // Mark that we're entering configuration
            isInConfiguration = true
            
            // Begin configuration
            session.beginConfiguration()
            
            // Remove all inputs and outputs
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            
            // Commit configuration
            session.commitConfiguration()
            
            // IMPORTANT: Reset the configuration flag after configuration is complete
            isInConfiguration = false
            
            // Stop the session
            session.stopRunning()
            previewLayer?.session = nil
            isCaptureSessionConfigured = false
            
            print("[CameraService] Session teardown complete")
            
            // Update state on main thread
            DispatchQueue.main.async {
                self.isRunning = false
                self.canPerformCameraOperations = true
            }
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // We don't need to process the frame, just note that we received one
        if !self.hasReceivedVideoData {
            print("[CameraService] First video frame received")
            DispatchQueue.main.async {
                self.hasReceivedVideoData = true
            }
        }
        
        // Update last frame time
        lastFrameTime = Date()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("[CameraService] Frame dropped")
    }
}

// MARK: - Helpers

// Make the extension public so it can be used from other files
public extension AVCaptureVideoOrientation {
    /// Map a `UIDeviceOrientation` to an `AVCaptureVideoOrientation`
    /// This initializer always returns a valid orientation, defaulting to portrait for unknown cases
    /// - Parameter deviceOrientation: The device orientation to convert
    init(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeRight  // Intentionally reversed
        case .landscapeRight:
            self = .landscapeLeft   // Intentionally reversed
        case .faceUp, .faceDown, .unknown:
            // Default to portrait for any other orientation
            self = .portrait
        @unknown default:
            // Future-proof for any new device orientations
            self = .portrait
        }
    }
}
