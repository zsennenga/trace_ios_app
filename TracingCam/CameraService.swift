import AVFoundation
import UIKit
import Combine

/// CameraService
///
/// A lightweight helper that owns a single `AVCaptureSession` to provide a live-camera
/// preview layer.  It is **privacy–aware** (requests permission only when needed) and
/// **resource-aware** (automatically pauses the session while the app is backgrounded
/// and frees all resources on de-init).  No captured frames ever leave the device.
enum CameraError: Error {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case createCaptureInput(Error)
    case deniedAuthorization
    case restrictedAuthorization
    case unknownAuthorization
}

class CameraService: NSObject, ObservableObject {
    @Published var isAuthorized: Bool = false
    @Published var error: CameraError?
    
    let session = AVCaptureSession()
    private var isCaptureSessionConfigured = false
    private let sessionQueue = DispatchQueue(label: "com.tracingcam.sessionQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    /// `true` while we are inside `configureCaptureSession`; prevents a
    /// `startRunning` call between `beginConfiguration`/`commitConfiguration`.
    private var isSettingUp = false
    
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    override init() {
        super.init()
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
        checkPermissions()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        teardownSession()
    }

    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.isAuthorized = true
        case .notDetermined:
            requestPermissions()
        case .denied:
            self.isAuthorized = false
            self.error = .deniedAuthorization
        case .restricted:
            self.isAuthorized = false
            self.error = .restrictedAuthorization
        @unknown default:
            self.isAuthorized = false
            self.error = .unknownAuthorization
        }
        print("[CameraService] Authorization status checked – isAuthorized = \(isAuthorized)")
    }
    
    // MARK: - Permission Alert helper
    /// Convenience helper that returns an alert guiding the user to Settings
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
    /// Called when the app moves to background; stop the session to save battery.
    @objc private func appDidEnterBackground() {
        stopSession()
    }
    
    /// Called when the app re-enters foreground; attempt to resume the session.
    @objc private func appWillEnterForeground() {
        // Only restart if we already had permission
        if isAuthorized {
            startSession()
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                if !granted {
                    self?.error = .deniedAuthorization
                }
            }
        }
    }
    
    func setupCamera() {
        guard isAuthorized else { return }
        print("[CameraService] setupCamera() called")
        // Prevent multiple concurrent configurations
        guard !isSettingUp else { return }
        isSettingUp = true

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.configureCaptureSession { success in
                defer { self.isSettingUp = false }
                guard success else { return }

                // Start session **after** configuration block finished
                self.sessionQueue.async {
                    print("[CameraService] Starting session …")
                    self.session.startRunning()
                    print("[CameraService] session.startRunning() issued")
                }
            }
        }
    }
    
    func configureCaptureSession(completionHandler: (_ success: Bool) -> Void) {
        guard !isCaptureSessionConfigured else {
            completionHandler(true)
            return
        }
        
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        
        // Set up video device
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            DispatchQueue.main.async {
                self.error = .cameraUnavailable
            }
            completionHandler(false)
            return
        }
        
        // Add video input
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            } else {
                DispatchQueue.main.async {
                    self.error = .cannotAddInput
                }
                completionHandler(false)
                return
            }
        } catch {
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
        } else {
            DispatchQueue.main.async {
                self.error = .cannotAddOutput
            }
            completionHandler(false)
            return
        }
        
        isCaptureSessionConfigured = true
        print("[CameraService] configureCaptureSession finished – success")
        completionHandler(true)
    }
    
    func createPreviewLayer(for view: UIView) -> AVCaptureVideoPreviewLayer {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        self.previewLayer = previewLayer
        return previewLayer
    }
    
    func startSession() {
        guard !session.isRunning && isAuthorized && !isSettingUp && isCaptureSessionConfigured else { return }
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Update orientation before starting
            if let connection = self.previewLayer?.connection,
               connection.isVideoOrientationSupported {
                connection.videoOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation)
            }
            self.session.startRunning()
        }
    }
    
    func stopSession() {
        guard session.isRunning else { return }
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.stopRunning()
            // Break strong reference cycle to allow the session to be deallocated
            self.previewLayer?.session = nil
        }
    }

    /// Remove all inputs / outputs and allow the session to be deallocated.
    private func teardownSession() {
        guard isCaptureSessionConfigured else { return }
        /*  Using `sync` here could dead-lock if the caller is already
            executing on `sessionQueue`.  Switch to `async` so we always
            hop onto the queue safely.                                              */
        sessionQueue.async { [self] in
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.stopRunning()
            previewLayer?.session = nil
            isCaptureSessionConfigured = false
        }
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
