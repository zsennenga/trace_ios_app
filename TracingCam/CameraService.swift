import AVFoundation
import UIKit
import Combine

/// CameraService
///
/// A lightweight helper that owns a single `AVCaptureSession` to provide a live-camera
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

class CameraService: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isAuthorized: Bool = false
    @Published var error: CameraError?
    @Published var isRunning: Bool = false
    @Published var cameraStatus: String = "Not initialized"
    
    // MARK: - Camera Properties
    let session = AVCaptureSession()
    private var isCaptureSessionConfigured = false
    private let sessionQueue = DispatchQueue(label: "com.tracingcam.sessionQueue")
    private let mainSetupQueue = DispatchQueue(label: "com.tracingcam.mainSetupQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    // Setup state tracking
    private var isSettingUp = false
    private var setupRetryCount = 0
    private let maxSetupRetries = 3
    private var setupTimer: Timer?
    
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
        
        checkPermissions()
    }
    
    deinit {
        print("[CameraService] Deinitializing camera service")
        NotificationCenter.default.removeObserver(self)
        cancelSetupTimer()
        stopStatusCheckTimer()
        teardownSession()
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
            message: "Please allow camera access in Settings to use the live preview.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(
            UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        )
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
            resetAndRestartCamera()
        }
    }
    
    @objc private func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        print("[CameraService] Capture session runtime error: \(error.localizedDescription)")
        
        // Handle session errors
        if error.code == .mediaServicesWereReset {
            print("[CameraService] Media services were reset - attempting recovery")
            resetAndRestartCamera()
        }
    }
    
    @objc private func sessionInterruptionEnded(notification: NSNotification) {
        print("[CameraService] Session interruption ended - restarting camera")
        startSession()
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
        let previewIsValid = previewLayer?.isValid ?? false
        
        // Check if camera device is locked (in use by another process)
        var isDeviceLocked = false
        if let device = videoDeviceInput?.device {
            isDeviceLocked = !device.lockForConfiguration(nil)
            if !isDeviceLocked {
                device.unlockForConfiguration()
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
            "Has received frames: \(hasReceivedVideoData)",
            timeSinceLastFrame != nil ? String(format: "Last frame: %.1fs ago", timeSinceLastFrame!) : "No frames yet"
        ]
        
        let statusString = statusComponents.joined(separator: ", ")
        print("[CameraService] Camera status check: \(statusString)")
        
        // Update published status
        DispatchQueue.main.async {
            self.cameraStatus = statusString
            self.isRunning = isSessionRunning && hasVideoInput && deviceConnected && previewHasConnection
        }
        
        // Detect problems
        let hasProblems = !isSessionRunning || !hasVideoInput || !deviceConnected || 
                         !deviceHasMediaType || !previewHasConnection || !previewIsValid ||
                         isDeviceLocked || (hasReceivedVideoData && timeSinceLastFrame != nil && timeSinceLastFrame! > 3.0)
        
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
                    } else if !hasReceivedVideoData || (timeSinceLastFrame != nil && timeSinceLastFrame! > 5.0) {
                        self.error = .noVideoSignal
                    } else {
                        self.error = .sessionStartFailed
                    }
                }
                
                // Attempt recovery
                resetAndRestartCamera()
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
        resetAndRestartCamera()
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
                    
                    // Start session on main thread for reliability
                    DispatchQueue.main.async {
                        print("[CameraService] Starting camera session on main thread")
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
    
    private func resetAndRestartCamera() {
        print("[CameraService] Resetting and restarting camera")
        
        // Stop any existing session
        stopSession()
        
        // Reset session configuration
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Remove all inputs and outputs
            self.session.beginConfiguration()
            
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            
            self.session.commitConfiguration()
            
            // Mark as not configured
            self.isCaptureSessionConfigured = false
            self.hasReceivedVideoData = false
            self.lastFrameTime = nil
            
            // Restart setup process
            DispatchQueue.main.async {
                self.setupCamera()
            }
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
        
        // Begin configuration
        session.beginConfiguration()
        
        defer {
            print("[CameraService] Committing session configuration")
            session.commitConfiguration()
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
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        self.previewLayer = previewLayer
        return previewLayer
    }
    
    // MARK: - Session Control
    func startSession() {
        // Check if we can start the session
        guard !session.isRunning && isAuthorized && isCaptureSessionConfigured else {
            print("[CameraService] Cannot start session: running=\(session.isRunning), authorized=\(isAuthorized), configured=\(isCaptureSessionConfigured)")
            return
        }
        
        print("[CameraService] Starting camera session")
        sessionStartTime = Date()
        
        // Force this to happen on main thread for reliability
        if Thread.isMainThread {
            performSessionStart()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performSessionStart()
            }
        }
    }
    
    private func performSessionStart() {
        // Update orientation before starting
        updateVideoOrientation()
        
        // Start the session
        print("[CameraService] Starting session on \(Thread.isMainThread ? "main thread" : "background thread")")
        session.startRunning()
        
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
    
    private func verifySessionRunning() {
        print("[CameraService] Verifying session is running")
        
        if !session.isRunning {
            print("[CameraService] Session failed to start, retrying")
            
            // Try once more on the main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.session.startRunning()
                
                // Final check
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !self.session.isRunning {
                        print("[CameraService] Session failed to start after retry")
                        self.error = .sessionStartFailed
                        
                        // Try a full reset as a last resort
                        self.resetAndRestartCamera()
                    } else {
                        print("[CameraService] Session started successfully after retry")
                        self.isRunning = true
                        self.startStatusCheckTimer()
                        
                        // Schedule an additional verification to ensure we're getting frames
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            if !self.hasReceivedVideoData {
                                print("[CameraService] No video frames received after 2 seconds")
                                self.error = .noVideoSignal
                                self.resetAndRestartCamera()
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
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            
            session.stopRunning()
            previewLayer?.session = nil
            isCaptureSessionConfigured = false
            
            print("[CameraService] Session teardown complete")
            
            // Update state on main thread
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // We don't need to process the frame, just note that we received one
        if !hasReceivedVideoData {
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

private extension AVCaptureVideoOrientation {
    /// Map a `UIDeviceOrientation` to an `AVCaptureVideoOrientation`
    init(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .landscapeLeft:  self = .landscapeRight
        case .landscapeRight: self = .landscapeLeft
        case .portraitUpsideDown: self = .portraitUpsideDown
        default: self = .portrait
        }
    }
}
