import AVFoundation
import UIKit
import Combine

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
    
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    override init() {
        super.init()
        checkPermissions()
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
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.configureCaptureSession { success in
                guard success else { return }
                
                self.session.startRunning()
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
        guard !session.isRunning && isAuthorized else { return }
        
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func stopSession() {
        guard session.isRunning else { return }
        
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }
}
