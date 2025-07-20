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
    @State private var lastActiveTimestamp = Date()
    @State private var hideControlsTask: DispatchWorkItem?
    @State private var orientation = UIDevice.current.orientation
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var retryImageSelection = false
    @State private var cameraInitialized = false
    @State private var showCameraPermissionAlert = false
    @State private var showCameraDetails = false
    
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
                        print("[ContentView] onAppear - Setting up camera")
                        initializeCamera()
                        loadOverlayImage()
                        scheduleControlsHiding()
                        screenSize = geometry.size
                    }
                
                // Camera status and refresh button in top area
                VStack {
                    HStack {
                        // Camera status indicator
                        VStack(alignment: .leading) {
                            Button(action: {
                                withAnimation {
                                    showCameraDetails.toggle()
                                }
                            }) {
                                HStack {
                                    Circle()
                                        .fill(cameraService.isRunning ? Color.green : Color.red)
                                        .frame(width: 12, height: 12)
                                    
                                    Text(cameraService.isRunning ? "Camera active" : "Camera inactive")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                }
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(20)
                            }
                            .accessibilityLabel("Camera status: \(cameraService.isRunning ? "active" : "inactive")")
                            .accessibilityHint("Tap to show more camera details")
                            
                            // Expanded camera details
                            if showCameraDetails {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let error = cameraService.error {
                                        Text("Error: \(String(describing: error))")
                                            .font(.system(size: 12))
                                            .foregroundColor(.red)
                                    }
                                    
                                    Text(cameraService.cameraStatus)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                        .lineLimit(5)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                                .transition(.opacity)
                            }
                        }
                        
                        Spacer()
                        
                        // Camera refresh button
                        Button(action: {
                            cameraService.refreshCamera()
                        }) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .disabled(!cameraService.canPerformCameraOperations)
                        .accessibilityLabel("Refresh camera")
                        .accessibilityHint("Tap to restart the camera if it's not working")
                    }
                    .padding(.horizontal)
                    .padding(.top, 50)
                    
                    if !cameraService.isAuthorized {
                        Text("Camera not authorized")
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                }
                
                // Overlay image with gestures
                if let image = overlayImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // Apply current gestureScale for smooth live feedback
                        .frame(width: geometry.size.width * settings.imageScale * gestureScale)
                        .position(
                            x: geometry.size.width / 2 + settings.imagePosition.x + dragOffset.width,
                            y: geometry.size.height / 2 + settings.imagePosition.y + dragOffset.height
                        )
                        .opacity(settings.imageOpacity)
                        .accessibilityLabel("Tracing overlay image")
                        .accessibilityHint("Double tap to select, then drag to move or pinch to resize")
                        // Use gesture priority to avoid conflicts
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
                        .gesture(
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
                                        print("[ContentView] Opacity changed to: \(settings.imageOpacity)")
                                    }
                                    .accessibilityLabel("Overlay opacity")
                                    .accessibilityValue("\(Int(settings.imageOpacity * 100)) percent")
                            }
                            .padding(.horizontal)
                            
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
                                    Text("Choose Image")
                                        .font(.body.bold())
                                }
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .accessibilityLabel("Choose a new image")
                            .accessibilityHint("Opens photo picker to select a new tracing image")
                        }
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(15)
                        .padding(.bottom, 30)
                        .transition(.move(edge: .bottom))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Only toggle controls if we're not tapping on the camera status area
                withAnimation {
                    showControls.toggle()
                    // Auto-hide camera details when showing controls
                    if showControls && showCameraDetails {
                        showCameraDetails = false
                    }
                }
                userInteracted()
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(onImagePicked: { result in
                    if let (imageURL, directImage) = result {
                        print("[ContentView] Image picked with URL: \(imageURL.absoluteString)")
                        
                        // Store the image directly first
                        self.overlayImage = directImage
                        
                        // Then update settings (which will trigger file operations)
                        settings.resetForNewImage(with: imageURL)
                        
                        // Add a small delay to ensure file system operations complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            print("[ContentView] Delayed verification of image file")
                            if FileManager.default.fileExists(atPath: imageURL.path) {
                                print("[ContentView] Verified image file exists after delay")
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
                print("[ContentView] Main view appeared")
                
                // Check camera permission first
                checkCameraPermission()
                
                // Check if this is the first launch
                if settings.isFirstLaunch {
                    print("[ContentView] First launch detected")
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
                        print("[ContentView] App entered foreground, reloading image and camera")
                        loadOverlayImage() // Reload image in case it was deleted while app was in background
                        initializeCamera() // Re-initialize camera when coming back to foreground
                    }
                    .store(in: &cancellables)
            }
        }
    }
    
    // Initialize camera with proper error handling
    private func initializeCamera() {
        // Avoid camera calls while operations are unsafe (during config / cooldown)
        guard cameraService.canPerformCameraOperations else {
            print("[ContentView] Camera operations currently unsafe, deferring initialization")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                initializeCamera()
            }
            return
        }
        if !cameraService.isAuthorized {
            print("[ContentView] Camera not authorized, requesting permission")
            checkCameraPermission()
        } else {
            print("[ContentView] Setting up camera")
            cameraService.setupCamera()
            // Add a delay and retry if needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !cameraService.isRunning && cameraService.canPerformCameraOperations {
                    print("[ContentView] Camera session not running after 1s, retrying setup")
                    cameraService.setupCamera()
                }
            }
        }
    }
    
    // Check camera permission
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("[ContentView] Camera permission already granted")
            cameraService.setupCamera()
        case .notDetermined:
            print("[ContentView] Requesting camera permission")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("[ContentView] Camera permission granted")
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
            print("[ContentView] Photo library permission already granted")
            completion(true)
        case .notDetermined:
            print("[ContentView] Requesting photo library permission")
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
            // This is just an example - you may want different behavior
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
        print("[ContentView] Loading overlay image")
        
        // If we already have an overlay image loaded, don't reload it
        if overlayImage != nil {
            print("[ContentView] Using existing overlay image in memory")
            return
        }
        
        guard let imageURL = settings.overlayImageURL else {
            print("[ContentView] No image URL found in settings")
            overlayImage = nil
            return
        }
        
        // Use a dedicated queue for file operations to prevent race conditions
        fileOperationQueue.async {
            print("[ContentView] Attempting to load image from: \(imageURL.absoluteString)")
            
            // Create a fresh file URL to avoid any URL encoding issues
            let freshURL = URL(fileURLWithPath: imageURL.path).standardizedFileURL
            print("[ContentView] Using standardized URL path: \(freshURL.path)")
            
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
                print("[ContentView] Image file exists with size: \(fileSize) bytes")
                
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
                print("[ContentView] Reading image data from URL")
                let imageData = try Data(contentsOf: freshURL)
                print("[ContentView] Image data loaded: \(imageData.count) bytes")
                
                if let image = UIImage(data: imageData) {
                    print("[ContentView] Successfully created UIImage with size: \(image.size.width)x\(image.size.height)")
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
    
    func makeUIView(context: Context) -> UIView {
        print("[CameraPreview] Creating camera preview view")
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        view.isAccessibilityElement = false // The parent view handles accessibility
        
        let previewLayer = cameraService.createPreviewLayer(for: view)
        print("[CameraPreview] Created preview layer")
        // Render camera behind any SwiftUI overlay
        previewLayer.zPosition = -1
        
        // Avoid adding duplicate preview layers if makeUIView gets called
        if view.layer.sublayers?.contains(previewLayer) == false {
            print("[CameraPreview] Adding preview layer to view")
            view.layer.addSublayer(previewLayer)
        } else {
            print("[CameraPreview] Preview layer already present in view hierarchy")
        }
        
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
            print("[CameraPreview] Camera not authorized")
        } else if !cameraService.isRunning && cameraService.canPerformCameraOperations {
            print("[CameraPreview] Starting camera session")
            cameraService.startSession()
            
            // Double-check that session started
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !cameraService.isRunning {
                    print("[CameraPreview] Camera session failed to start, retrying")
                    cameraService.setupCamera()
                    cameraService.startSession()
                }
            }
        } else {
            print("[CameraPreview] Camera session already running")
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
                    print("[CameraPreview] Updating preview orientation to \(newOrientation.rawValue)")
                    connection.videoOrientation = newOrientation
                }
            }
            
            // Ensure camera is running when view updates
            if !cameraService.isRunning &&
               cameraService.isAuthorized &&
               cameraService.canPerformCameraOperations {
                print("[CameraPreview] Camera session not running during update, restarting")
                cameraService.startSession()
            }
        }
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        print("[CameraPreview] Dismantling camera preview view")
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
        print("[ImagePicker] Creating image picker")
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
            print("[ImagePicker] Finished picking with \(results.count) results")
            parent.presentationMode.wrappedValue.dismiss()
            
            guard !results.isEmpty else {
                print("[ImagePicker] No image selected (user cancelled)")
                // User cancelled without selecting an image
                return
            }
            
            guard let provider = results.first?.itemProvider else {
                print("[ImagePicker] No item provider in result")
                parent.onImagePicked(nil)
                return
            }
            
            if provider.canLoadObject(ofClass: UIImage.self) {
                print("[ImagePicker] Loading image from provider")
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
                        
                        print("[ImagePicker] Successfully loaded image: \(image.size.width)x\(image.size.height)")
                        
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
                                    print("[ImagePicker] Verified image exists at: \(imageURL.path)")
                                    
                                    // Try to load the image back to double-check
                                    if let verifyData = try? Data(contentsOf: imageURL),
                                       let verifiedImage = UIImage(data: verifyData) {
                                        print("[ImagePicker] Successfully verified image can be loaded")
                                        
                                        // Use path-based URL to avoid encoding issues
                                        let pathBasedURL = URL(fileURLWithPath: imageURL.path).standardizedFileURL
                                        print("[ImagePicker] Using standardized URL: \(pathBasedURL.path)")
                                        
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
            print("[ImagePicker] Saving image to: \(fileURL.path)")
            
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
                    print("[ImagePicker] File saved successfully, size: \(fileSize) bytes")
                    
                    // Force a sync to ensure the file is fully written to disk
                    let parentDir = fileURL.deletingLastPathComponent()
                    let dirContents = try? fileManager.contentsOfDirectory(atPath: parentDir.path)
                    print("[ImagePicker] Directory has \(dirContents?.count ?? 0) files after save")
                    
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
