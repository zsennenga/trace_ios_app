import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import Combine

struct ContentView: View {
    // Access to app settings
    @ObservedObject private var settings = AppSettings.shared
    
    // Camera service for live feed
    @ObservedObject private var cameraService = CameraService()
    
    // State variables
    @State private var showImagePicker = false
    @State private var showControls = true
    @State private var overlayImage: UIImage? = nil
    @State private var dragOffset: CGSize = .zero
    // Live gesture scale used during pinch for smooth resizing
    @State private var gestureScale: CGFloat = 1.0
    // Live gesture rotation used during rotation for smooth feedback
    @State private var gestureRotation: Angle = .zero
    @State private var lastActiveTimestamp = Date()
    @State private var hideControlsTask: DispatchWorkItem?
    @State private var orientation = UIDevice.current.orientation
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var retryImageSelection = false
    @State private var cameraInitialized = false
    @State private var showCameraPermissionAlert = false
    // Indicates we are waiting for the camera session to boot.
    @State private var isCameraLoading = true
    
    // File operation queue to prevent race conditions
    private let fileOperationQueue = DispatchQueue(label: "com.tracingcam.fileOperations")
    
    // Store cancellables to prevent them from being deallocated
    @State private var cancellables = Set<AnyCancellable>()
    
    // Screen dimensions for orientation handling
    @State private var screenSize: CGSize = UIScreen.main.bounds.size
    
    // Timer for auto-hiding controls
    private let controlHideDelay: TimeInterval = 3.0 // Hide after 3 seconds
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera view as background
                CameraPreview(cameraService: cameraService)
                    .edgesIgnoringSafeArea(.all)
                    .accessibilityLabel("Live camera view")
                    .onAppear {
                        #if DEBUG
                        print("[ContentView] onAppear - Setting up camera")
                        #endif
                        initializeCamera()
                        loadOverlayImage()
                        scheduleControlsHiding()
                        screenSize = geometry.size
                        
                        // If the user has no saved overlay, immediately present picker
                        launchPickerIfNoOverlay()
                    }
                    // Keep track of camera running state to toggle a spinner
                    .onReceive(cameraService.$isRunning) { running in
                        // Camera considered "loading" until we receive frames
                        isCameraLoading = !running
                    }
                
                // Camera permission warning (only shown if needed)
                if !cameraService.isAuthorized {
                    Text("Camera not authorized")
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                }
                
                // Overlay image with gestures
                if let image = overlayImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // Apply current gestureScale for smooth live feedback
                        .frame(width: geometry.size.width * settings.imageScale * gestureScale)
                        .rotationEffect(Angle(radians: settings.imageRotation) + gestureRotation)
                        .position(
                            x: geometry.size.width / 2 + settings.imagePosition.x + dragOffset.width,
                            y: geometry.size.height / 2 + settings.imagePosition.y + dragOffset.height
                        )
                        .opacity(settings.imageOpacity)
                        .accessibilityLabel("Tracing overlay image")
                        .accessibilityHint("Double tap to select, then drag to move, pinch to resize, or twist to rotate")
                        // Use gesture priority and simultaneousGesture to combine gestures
                        .gesture(
                            DragGesture()
                                .onChanged { gesture in
                                    dragOffset = gesture.translation
                                    userInteracted()
                                }
                                .onEnded { gesture in
                                    settings.imagePosition = CGPoint(
                                        x: settings.imagePosition.x + dragOffset.width,
                                        y: settings.imagePosition.y + dragOffset.height
                                    )
                                    dragOffset = .zero
                                }
                        )
                        .simultaneousGesture(
                            // Smooth pinch-to-resize gesture
                            MagnificationGesture()
                                .onChanged { value in
                                    gestureScale = value      // live update
                                    userInteracted()
                                }
                                .onEnded { finalValue in
                                    // Persist the new scale relative to previous persisted scale
                                    settings.imageScale *= finalValue
                                    gestureScale = 1.0         // reset for next gesture
                                }
                        )
                        .simultaneousGesture(
                            // Rotation gesture for twisting the image
                            RotationGesture()
                                .onChanged { value in
                                    gestureRotation = value    // live update
                                    userInteracted()
                                }
                                .onEnded { finalValue in
                                    // Persist the new rotation by adding to the existing rotation
                                    settings.imageRotation += finalValue.radians
                                    gestureRotation = .zero    // reset for next gesture
                                }
                        )
                } else {
                    // Show a message if no image is loaded
                    if settings.overlayImageURL != nil {
                        Text("Image failed to load")
                            .foregroundColor(.yellow)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                }
                
                // Controls overlay
                VStack {
                    Spacer()
                    
                    // Camera loading indicator (shows only if picker not visible)
                    if isCameraLoading && !showImagePicker {
                        ProgressView("Connecting camera…")
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(10)
                            .transition(.opacity)
                            .padding(.bottom, 20)
                    }
                    
                    if showControls {
                        VStack(spacing: 20) {
                            // Opacity slider
                            HStack {
                                Text("Opacity:")
                                    .foregroundColor(.white)
                                    .font(.body)
                                    .accessibilityHidden(true)
                                
                                Slider(value: $settings.imageOpacity, in: 0.1...1.0)
                                    .onChange(of: settings.imageOpacity) { _ in
                                        userInteracted()
                                        #if DEBUG
                                        print("[ContentView] Opacity changed to: \(settings.imageOpacity)")
                                        #endif
                                    }
                                    .accessibilityLabel("Overlay opacity")
                                    .accessibilityValue("\(Int(settings.imageOpacity * 100)) percent")
                            }
                            .padding(.horizontal)
                            
                            HStack(spacing: 15) {
                                // New image button
                                Button(action: {
                                    checkPhotoLibraryPermission { granted in
                                        if granted {
                                            showImagePicker = true
                                        } else {
                                            showError(message: "Photo library access is required to select images. Please enable it in Settings.", allowRetry: false)
                                        }
                                    }
                                    userInteracted()
                                }) {
                                    HStack {
                                        Image(systemName: "photo")
                                            .imageScale(.large)
                                        Text("Change Image")
                                            .font(.body.bold())
                                    }
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                                .accessibilityLabel("Change image")
                                .accessibilityHint("Opens photo picker to select a new tracing image")
                                
                                // Reset button
                                Button(action: {
                                    resetImageTransforms()
                                    userInteracted()
                                }) {
                                    HStack {
                                        Image(systemName: "arrow.counterclockwise")
                                            .imageScale(.large)
                                        Text("Reset")
                                            .font(.body.bold())
                                    }
                                    .padding()
                                    .background(Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                                .accessibilityLabel("Reset image position")
                                .accessibilityHint("Resets the image position, scale, and rotation")
                                .disabled(overlayImage == nil)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(15)
                        .padding(.bottom, 30)
                        .transition(.move(edge: .bottom))
                        .gesture(
                            DragGesture()
                                .onChanged { gesture in
                                    // Only respond to downward swipes
                                    if gesture.translation.height > 0 {
                                        userInteracted()
                                    }
                                }
                                .onEnded { gesture in
                                    // If swiped down with enough force, dismiss controls
                                    if gesture.translation.height > 50 || gesture.predictedEndTranslation.height > 100 {
                                        withAnimation {
                                            showControls = false
                                        }
                                    }
                                }
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    showControls.toggle()
                }
                userInteracted()
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(onImagePicked: { result in
                    if let (imageURL, directImage) = result {
                        #if DEBUG
                        print("[ContentView] Image picked with URL: \(imageURL.absoluteString)")
                        #endif
                        
                        // Store the image directly first
                        self.overlayImage = directImage
                        
                        // Save the new image URL but preserve current transform settings
                        let currentRotation = settings.imageRotation
                        let currentScale = settings.imageScale
                        let currentOpacity = settings.imageOpacity
                        
                        // Only reset the position, not the other transform properties
                        settings.resetForNewImage(with: imageURL)
                        
                        // Restore the saved settings
                        settings.imageRotation = currentRotation
                        settings.imageScale = currentScale
                        settings.imageOpacity = currentOpacity
                        
                        // Add a small delay to ensure file system operations complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            #if DEBUG
                            print("[ContentView] Delayed verification of image file")
                            #endif
                            if FileManager.default.fileExists(atPath: imageURL.path) {
                                #if DEBUG
                                print("[ContentView] Verified image file exists after delay")
                                #endif
                            } else {
                                print("[ContentView] WARNING: Image file still doesn't exist after delay")
                                showError(message: "The image file could not be found. Please select a new one.", allowRetry: true)
                            }
                        }
                    } else {
                        showError(message: "Could not load the selected image. Please try again.", allowRetry: true)
                    }
                })
            }
            .alert(isPresented: $showErrorAlert) {
                retryImageSelection ?
                Alert(
                    title: Text("Error"),
                    message: Text(errorMessage),
                    primaryButton: .default(Text("Try Again")) {
                        showImagePicker = true
                    },
                    secondaryButton: .cancel()
                ) :
                Alert(
                    title: Text("Error"),
                    message: Text(errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onChange(of: geometry.size) { newSize in
                screenSize = newSize
                updateLayoutForOrientation()
            }
            .onAppear {
                #if DEBUG
                print("[ContentView] Main view appeared")
                #endif
                
                // Check camera permission first
                checkCameraPermission()
                
                // Check if this is the first launch
                if settings.isFirstLaunch {
                    #if DEBUG
                    print("[ContentView] First launch detected")
                    #endif
                    checkPhotoLibraryPermission { granted in
                        if granted {
                            showImagePicker = true
                        } else {
                            showError(message: "Photo library access is required to select images. Please enable it in Settings.", allowRetry: false)
                        }
                    }
                    settings.markAsLaunched()
                }
                
                // Setup orientation change publisher
                NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
                    .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                    .sink { _ in
                        let newOrientation = UIDevice.current.orientation
                        if newOrientation.isPortrait || newOrientation.isLandscape {
                            orientation = newOrientation
                            updateLayoutForOrientation()
                        }
                    }
                    .store(in: &cancellables)
                
                // Setup app foreground/background publishers
                NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                    .sink { _ in
                        #if DEBUG
                        print("[ContentView] App entered foreground, reloading image and camera")
                        #endif
                        loadOverlayImage() // Reload image in case it was deleted while app was in background
                        initializeCamera() // Re-initialize camera when coming back to foreground
                    }
                    .store(in: &cancellables)

                // Listen for explicit camera-refresh notifications from SceneDelegate
                NotificationCenter.default.publisher(for: SceneDelegate.forceCameraRefreshNotification)
                    .sink { _ in
                        #if DEBUG
                        print("[ContentView] Received force-camera-refresh notification")
                        #endif
                        forceRefreshCamera()
                    }
                    .store(in: &cancellables)
            }
        }
    }

    /// Presents the image picker immediately if no overlay is configured.
    private func launchPickerIfNoOverlay() {
        // If no saved URL and no in-memory image, bring up the picker.
        if settings.overlayImageURL == nil && overlayImage == nil {
            DispatchQueue.main.async {
                showImagePicker = true
            }
        }
    }

    /// Called when an external notification explicitly requests the camera be refreshed
    private func forceRefreshCamera() {
        #if DEBUG
        print("[ContentView] Forcing camera refresh")
        #endif
        // Recreate preview layer if needed & restart camera
        cameraService.refreshCamera()
    }
    
    /// Reset image position, scale, and rotation to default values
    private func resetImageTransforms() {
        #if DEBUG
        print("[ContentView] Resetting image transforms")
        #endif
        settings.imagePosition = .zero
        settings.imageScale = 0.5 // Default scale
        settings.imageRotation = 0.0 // Reset rotation
        dragOffset = .zero
        gestureScale = 1.0
        gestureRotation = .zero
    }
    
    // Initialize camera with proper error handling
    private func initializeCamera() {
        // Avoid camera calls while operations are unsafe (during config / cooldown)
        guard cameraService.canPerformCameraOperations else {
            #if DEBUG
            print("[ContentView] Camera operations currently unsafe, deferring initialization")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                initializeCamera()
            }
            return
        }
        if !cameraService.isAuthorized {
            #if DEBUG
            print("[ContentView] Camera not authorized, requesting permission")
            #endif
            checkCameraPermission()
        } else {
            #if DEBUG
            print("[ContentView] Setting up camera")
            #endif
            cameraService.setupCamera()
            // Add a delay and retry if needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !cameraService.isRunning && cameraService.canPerformCameraOperations {
                    #if DEBUG
                    print("[ContentView] Camera session not running after 1s, retrying setup")
                    #endif
                    cameraService.setupCamera()
                }
            }
        }
    }
    
    // Check camera permission
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            #if DEBUG
            print("[ContentView] Camera permission already granted")
            #endif
            cameraService.setupCamera()
        case .notDetermined:
            #if DEBUG
            print("[ContentView] Requesting camera permission")
            #endif
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        #if DEBUG
                        print("[ContentView] Camera permission granted")
                        #endif
                        cameraService.setupCamera()
                    } else {
                        print("[ContentView] Camera permission denied")
                        showError(message: "Camera access is required for this app. Please enable it in Settings.", allowRetry: false)
                    }
                }
            }
        case .denied, .restricted:
            print("[ContentView] Camera permission denied or restricted")
            showError(message: "Camera access is required for this app. Please enable it in Settings.", allowRetry: false)
        @unknown default:
            print("[ContentView] Unknown camera permission status")
            showError(message: "Unknown camera permission status. Please check your privacy settings.", allowRetry: false)
        }
    }
    
    // Check photo library permission
    private func checkPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .authorized, .limited:
            #if DEBUG
            print("[ContentView] Photo library permission already granted")
            #endif
            completion(true)
        case .notDetermined:
            #if DEBUG
            print("[ContentView] Requesting photo library permission")
            #endif
            PHPhotoLibrary.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    completion(newStatus == .authorized || newStatus == .limited)
                }
            }
        case .denied, .restricted:
            print("[ContentView] Photo library permission denied or restricted")
            completion(false)
        @unknown default:
            print("[ContentView] Unknown photo library permission status")
            completion(false)
        }
    }
    
    // Update layout when orientation changes
    private func updateLayoutForOrientation() {
        // Adjust positioning based on orientation and screen size
        let isLandscape = orientation.isLandscape
        let screenWidth = screenSize.width
        let screenHeight = screenSize.height
        
        // If we're in landscape, we might want to adjust the default scale
        if isLandscape && overlayImage != nil {
            // Adjust scale if needed based on orientation
            if let image = overlayImage {
                let imageAspect = image.size.width / image.size.height
                let screenAspect = screenWidth / screenHeight
                
                // Only adjust if the change is significant
                if abs(imageAspect - screenAspect) > 0.2 {
                    // Keep the image at a reasonable size in both orientations
                    // but don't change user's manual adjustments
                    if dragOffset == .zero && settings.imageScale == 0.5 {
                        // Only adjust the default positioning
                        settings.imageScale = isLandscape ? 0.4 : 0.5
                    }
                }
            }
        }
    }
    
    // Show error alert
    private func showError(message: String, allowRetry: Bool = false) {
        print("[ContentView] Error: \(message)")
        self.errorMessage = message
        self.retryImageSelection = allowRetry
        self.showErrorAlert = true
    }
    
    // Load the overlay image from the stored URL
    private func loadOverlayImage() {
        #if DEBUG
        print("[ContentView] Loading overlay image")
        #endif
        
        // If we already have an overlay image loaded, don't reload it
        if overlayImage != nil {
            #if DEBUG
            print("[ContentView] Using existing overlay image in memory")
            #endif
            return
        }
        
        guard let imageURL = settings.overlayImageURL else {
            #if DEBUG
            print("[ContentView] No image URL found in settings")
            #endif
            overlayImage = nil
            return
        }
        
        // Use a dedicated queue for file operations to prevent race conditions
        fileOperationQueue.async {
            #if DEBUG
            print("[ContentView] Attempting to load image from: \(imageURL.absoluteString)")
            #endif
            
            // Create a fresh file URL to avoid any URL encoding issues
            let freshURL = URL(fileURLWithPath: imageURL.path).standardizedFileURL
            
            // Check if file exists with proper error handling
            var isDirectory: ObjCBool = false
            let fileExists = FileManager.default.fileExists(atPath: freshURL.path, isDirectory: &isDirectory)
            
            if !fileExists || isDirectory.boolValue {
                print("[ContentView] Image file does not exist at path: \(freshURL.path)")
                DispatchQueue.main.async {
                    self.overlayImage = nil
                    self.showError(message: "The image file could not be found. Please select a new one.", allowRetry: true)
                }
                return
            }
            
            // Try to get file attributes
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: freshURL.path)
                let fileSize = attributes[.size] as? UInt64 ?? 0
                #if DEBUG
                print("[ContentView] Image file exists with size: \(fileSize) bytes")
                #endif
                
                if fileSize == 0 {
                    print("[ContentView] Image file is empty")
                    DispatchQueue.main.async {
                        self.overlayImage = nil
                        self.showError(message: "The image file is empty. Please select a new one.", allowRetry: true)
                    }
                    return
                }
            } catch {
                print("[ContentView] Error getting file attributes: \(error.localizedDescription)")
            }

            do {
                #if DEBUG
                print("[ContentView] Reading image data from URL")
                #endif
                let imageData = try Data(contentsOf: freshURL)
                #if DEBUG
                print("[ContentView] Image data loaded: \(imageData.count) bytes")
                #endif
                
                if let image = UIImage(data: imageData) {
                    #if DEBUG
                    print("[ContentView] Successfully created UIImage with size: \(image.size.width)x\(image.size.height)")
                    #endif
                    DispatchQueue.main.async {
                        self.overlayImage = image
                    }
                } else {
                    print("[ContentView] Failed to create UIImage from data")
                    DispatchQueue.main.async {
                        self.overlayImage = nil
                        self.showError(message: "Could not load the saved image. Please select a new one.", allowRetry: true)
                    }
                }
            } catch {
                print("[ContentView] Error loading image data: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.overlayImage = nil
                    self.showError(message: "Error loading image: \(error.localizedDescription)", allowRetry: true)
                }
            }
        }
    }
    
    // Track user interaction and reset the auto-hide timer
    private func userInteracted() {
        lastActiveTimestamp = Date()
        
        if !showControls {
            withAnimation {
                showControls = true
            }
        }
        
        scheduleControlsHiding()
    }
    
    // Schedule hiding of controls after inactivity
    private func scheduleControlsHiding() {
        // Cancel any existing hide task
        cancelHideControlsTask()
        
        // Create a new task
        let task = DispatchWorkItem {
            if Date().timeIntervalSince(self.lastActiveTimestamp) >= self.controlHideDelay {
                DispatchQueue.main.async {
                    withAnimation {
                        self.showControls = false
                    }
                }
            }
        }
        
        // Schedule the new task
        hideControlsTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + controlHideDelay, execute: task)
    }

    // Cancel hide control task if any
    private func cancelHideControlsTask() {
        hideControlsTask?.cancel()
        hideControlsTask = nil
    }
}

// Camera preview wrapper for SwiftUI
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var cameraService: CameraService
    
    // Helper function to convert UIDeviceOrientation to AVCaptureVideoOrientation
    private func videoOrientation(from deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .landscapeLeft:  return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject {
        private var parent: CameraPreview?
        private weak var hostView: UIView?
        private var observer: NSObjectProtocol?
        
        init(parent: CameraPreview) {
            self.parent = parent
            super.init()
            
            observer = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("CameraPreviewNeedsRecreation"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleRecreation()
            }
        }
        
        deinit {
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        /// Called from `makeUIView` to remember the hosting view whose
        /// layer tree we should update when a recreation notification arrives.
        func startObservingRecreation(on view: UIView) {
            self.hostView = view
        }
        
        @objc private func handleRecreation() {
            guard
                let view = hostView,
                let parent = parent
            else { return }
            
            let previewLayer = parent.cameraService.recreatePreviewLayer(for: view)
            
            if !(view.layer.sublayers?.contains(previewLayer) ?? false) {
                view.layer.addSublayer(previewLayer)
            }
            
            // Ensure the layer is at the back
            previewLayer.zPosition = -1
        }
    }
    
    func makeUIView(context: Context) -> UIView {
        #if DEBUG
        print("[CameraPreview] Creating camera preview view")
        #endif
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        view.isAccessibilityElement = false // The parent view handles accessibility
        
        // Always use the more robust recreation API so we never reuse a bad layer
        let previewLayer = cameraService.recreatePreviewLayer(for: view)
        #if DEBUG
        print("[CameraPreview] Created preview layer")
        #endif
        
        // Render camera behind any SwiftUI overlay
        previewLayer.zPosition = -1
        
        // Avoid adding duplicate preview layers if makeUIView gets called
        if view.layer.sublayers?.contains(previewLayer) == false {
            #if DEBUG
            print("[CameraPreview] Adding preview layer to view")
            #endif
            view.layer.addSublayer(previewLayer)
        } else {
            #if DEBUG
            print("[CameraPreview] Preview layer already present in view hierarchy")
            #endif
        }

        // Store observer to rebuild layer if requested by CameraService
        context.coordinator.startObservingRecreation(on: view)

        // Ensure the preview layer orientation matches device immediately
        DispatchQueue.main.async {
            if let connection = self.cameraService.previewLayer?.connection,
               connection.isVideoOrientationSupported {
                let orientation = self.videoOrientation(from: UIDevice.current.orientation)
                connection.videoOrientation = orientation
            }
        }
        
        // Ensure camera is set up
        if !cameraService.isAuthorized {
            #if DEBUG
            print("[CameraPreview] Camera not authorized")
            #endif
        } else if !cameraService.isRunning && cameraService.canPerformCameraOperations {
            #if DEBUG
            print("[CameraPreview] Starting camera session")
            #endif
            cameraService.startSession()
            
            // Double-check that session started
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !cameraService.isRunning {
                    #if DEBUG
                    print("[CameraPreview] Camera session failed to start, retrying")
                    #endif
                    cameraService.setupCamera()
                    cameraService.startSession()
                }
            }
        } else {
            #if DEBUG
            print("[CameraPreview] Camera session already running")
            #endif
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = cameraService.previewLayer {
            previewLayer.frame = uiView.bounds
            // Keep layer at back
            previewLayer.zPosition = -1
            
            // Update orientation on each layout change
            if let connection = previewLayer.connection,
               connection.isVideoOrientationSupported {
                let newOrientation = videoOrientation(from: UIDevice.current.orientation)
                if connection.videoOrientation != newOrientation {
                    #if DEBUG
                    print("[CameraPreview] Updating preview orientation to \(newOrientation.rawValue)")
                    #endif
                    connection.videoOrientation = newOrientation
                }
            }
            
            // Ensure camera is running when view updates
            if !cameraService.isRunning &&
               cameraService.isAuthorized &&
               cameraService.canPerformCameraOperations {
                #if DEBUG
                print("[CameraPreview] Camera session not running during update, restarting")
                #endif
                cameraService.startSession()
            }
        }
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        #if DEBUG
        print("[CameraPreview] Dismantling camera preview view")
        #endif
        // Ensure we clean up any resources when view is removed
        for layer in uiView.layer.sublayers ?? [] {
            layer.removeFromSuperlayer()
        }
        // Clear reference to avoid dangling layer
        uiView.layer.sublayers?.removeAll()
        
        // Let camera service know layer is gone - use notification instead of direct access
        NotificationCenter.default.post(name: NSNotification.Name("CameraPreviewDismantled"), object: nil)
    }
}

// Image picker using PHPickerViewController
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    // Modified to return both URL and UIImage directly
    var onImagePicked: ((URL, UIImage)?) -> Void
    
    // File operation serialization
    private let fileOperationLock = NSLock()
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        #if DEBUG
        print("[ImagePicker] Creating image picker")
        #endif
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        
        // Make picker accessible
        picker.view.accessibilityLabel = "Photo Picker"
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            #if DEBUG
            print("[ImagePicker] Finished picking with \(results.count) results")
            #endif
            parent.presentationMode.wrappedValue.dismiss()
            
            guard !results.isEmpty else {
                #if DEBUG
                print("[ImagePicker] No image selected (user cancelled)")
                #endif
                // User cancelled without selecting an image
                return
            }
            
            guard let provider = results.first?.itemProvider else {
                print("[ImagePicker] No item provider in result")
                parent.onImagePicked(nil)
                return
            }
            
            if provider.canLoadObject(ofClass: UIImage.self) {
                #if DEBUG
                print("[ImagePicker] Loading image from provider")
                #endif
                provider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        
                        if let error = error {
                            print("[ImagePicker] Image loading error: \(error.localizedDescription)")
                            self.parent.onImagePicked(nil)
                            return
                        }
                        
                        guard let image = image as? UIImage else {
                            print("[ImagePicker] Failed to cast loaded object to UIImage")
                            self.parent.onImagePicked(nil)
                            return
                        }
                        
                        #if DEBUG
                        print("[ImagePicker] Successfully loaded image: \(image.size.width)x\(image.size.height)")
                        #endif
                        
                        // Use a dedicated queue for file operations
                        DispatchQueue(label: "com.tracingcam.imageSaving").async {
                            // Lock to ensure thread safety
                            self.parent.fileOperationLock.lock()
                            defer { self.parent.fileOperationLock.unlock() }
                            
                            // Save image to app's documents directory
                            if let imageURL = self.saveImageToAppDocuments(image) {
                                // Perform synchronous verification to ensure file exists
                                let fileManager = FileManager.default
                                
                                // Force a filesystem sync to ensure writes are completed
                                try? fileManager.contentsOfDirectory(atPath: imageURL.deletingLastPathComponent().path)
                                
                                if fileManager.fileExists(atPath: imageURL.path) {
                                    #if DEBUG
                                    print("[ImagePicker] Verified image exists at: \(imageURL.path)")
                                    #endif
                                    
                                    // Try to load the image back to double-check
                                    if let verifyData = try? Data(contentsOf: imageURL),
                                       let verifiedImage = UIImage(data: verifyData) {
                                        #if DEBUG
                                        print("[ImagePicker] Successfully verified image can be loaded")
                                        #endif
                                        
                                        // Use path-based URL to avoid encoding issues
                                        let pathBasedURL = URL(fileURLWithPath: imageURL.path).standardizedFileURL
                                        #if DEBUG
                                        print("[ImagePicker] Using standardized URL: \(pathBasedURL.path)")
                                        #endif
                                        
                                        // Pass both the URL and the image directly
                                        DispatchQueue.main.async {
                                            self.parent.onImagePicked((pathBasedURL, verifiedImage))
                                        }
                                    } else {
                                        print("[ImagePicker] Image verification failed - can't load data")
                                        DispatchQueue.main.async {
                                            self.parent.onImagePicked(nil)
                                        }
                                    }
                                } else {
                                    print("[ImagePicker] File verification failed - doesn't exist at path")
                                    DispatchQueue.main.async {
                                        self.parent.onImagePicked(nil)
                                    }
                                }
                            } else {
                                print("[ImagePicker] Failed to save image to app documents")
                                DispatchQueue.main.async {
                                    self.parent.onImagePicked(nil)
                                }
                            }
                        }
                    }
                }
            } else {
                print("[ImagePicker] Provider cannot load UIImage object")
                parent.onImagePicked(nil)
            }
        }
        
        // Saves a *copy* of the user-selected image inside the app sandbox so
        // we retain access to it even after the PHPicker reference is gone.
        private func saveImageToAppDocuments(_ image: UIImage) -> URL? {
            let fileManager = FileManager.default
            
            // Get the documents directory URL
            guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                print("[ImagePicker] Could not access documents directory")
                return nil
            }
            
            // Create a unique filename
            let fileName = UUID().uuidString
            let fileURL = documentsDirectory.appendingPathComponent(fileName).appendingPathExtension("jpg")
            #if DEBUG
            print("[ImagePicker] Saving image to: \(fileURL.path)")
            #endif
            
            do {
                // Ensure we have valid image data with good quality
                guard let imageData = image.jpegData(compressionQuality: 0.9) else {
                    print("[ImagePicker] Could not create JPEG data from image")
                    return nil
                }
                
                // Write the data to the file URL with atomic option for safety
                try imageData.write(to: fileURL, options: [.atomic])
                
                // Verify the file was written
                if fileManager.fileExists(atPath: fileURL.path) {
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    let fileSize = attributes[.size] as? UInt64 ?? 0
                    #if DEBUG
                    print("[ImagePicker] File saved successfully, size: \(fileSize) bytes")
                    #endif
                    
                    // Force a sync to ensure the file is fully written to disk
                    let parentDir = fileURL.deletingLastPathComponent()
                    let dirContents = try? fileManager.contentsOfDirectory(atPath: parentDir.path)
                    #if DEBUG
                    print("[ImagePicker] Directory has \(dirContents?.count ?? 0) files after save")
                    #endif
                    
                    return fileURL
                } else {
                    print("[ImagePicker] File doesn't exist immediately after writing!")
                    return nil
                }
            } catch {
                print("[ImagePicker] Error saving image: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
