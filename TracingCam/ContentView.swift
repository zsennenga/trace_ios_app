import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import Combine

struct ContentView: View {
    // Access to app settings
    @ObservedObject private var settings = AppSettings.shared
    
    // Camera service for live feed
    private let cameraService = CameraService()
    
    // State variables
    @State private var showImagePicker = false
    @State private var showControls = true
    @State private var overlayImage: UIImage? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastActiveTimestamp = Date()
    @State private var hideControlsTask: DispatchWorkItem?
    @State private var orientation = UIDevice.current.orientation
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var retryImageSelection = false
    @State private var cameraInitialized = false
    @State private var showCameraPermissionAlert = false
    
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
                
                // Debug overlay for camera status
                VStack {
                    if !cameraService.isAuthorized {
                        Text("Camera not authorized")
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    
                    if let error = cameraService.error {
                        Text("Camera error: \(String(describing: error))")
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(.top, 50)
                
                // Overlay image with gestures
                if let image = overlayImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width * settings.imageScale)
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
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = value
                                    userInteracted()
                                }
                                .onEnded { value in
                                    settings.imageScale = settings.imageScale * scale
                                    scale = 1.0
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
                withAnimation {
                    showControls.toggle()
                }
                userInteracted()
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(onImagePicked: { url in
                    if let url = url {
                        print("[ContentView] Image picked with URL: \(url.absoluteString)")
                        settings.resetForNewImage(with: url)
                        loadOverlayImage()
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
        if !cameraService.isAuthorized {
            print("[ContentView] Camera not authorized, requesting permission")
            checkCameraPermission()
        } else {
            print("[ContentView] Setting up camera")
            cameraService.setupCamera()
            // Add a delay and retry if needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !cameraService.session.isRunning {
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
        guard
            let imageURL = settings.overlayImageURL
        else {
            print("[ContentView] No image URL found in settings")
            overlayImage = nil
            return
        }
        
        print("[ContentView] Attempting to load image from: \(imageURL.absoluteString)")
        
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            print("[ContentView] Image file does not exist at path: \(imageURL.path)")
            overlayImage = nil
            showError(message: "The image file could not be found. Please select a new one.", allowRetry: true)
            return
        }

        do {
            print("[ContentView] Reading image data from URL")
            let imageData = try Data(contentsOf: imageURL)
            print("[ContentView] Image data loaded: \(imageData.count) bytes")
            
            if let image = UIImage(data: imageData) {
                print("[ContentView] Successfully created UIImage with size: \(image.size.width)x\(image.size.height)")
                self.overlayImage = image
            } else {
                print("[ContentView] Failed to create UIImage from data")
                self.overlayImage = nil
                showError(message: "Could not load the saved image. Please select a new one.", allowRetry: true)
            }
        } catch {
            print("[ContentView] Error loading image data: \(error.localizedDescription)")
            self.overlayImage = nil
            showError(message: "Error loading image: \(error.localizedDescription)", allowRetry: true)
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
    let cameraService: CameraService
    
    func makeUIView(context: Context) -> UIView {
        print("[CameraPreview] Creating camera preview view")
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        view.isAccessibilityElement = false // The parent view handles accessibility
        
        let previewLayer = cameraService.createPreviewLayer(for: view)
        print("[CameraPreview] Created preview layer")
        
        // Avoid adding duplicate preview layers if makeUIView gets called
        if view.layer.sublayers?.contains(previewLayer) == false {
            print("[CameraPreview] Adding preview layer to view")
            view.layer.addSublayer(previewLayer)
        }
        
        // Ensure camera is set up
        if !cameraService.isAuthorized {
            print("[CameraPreview] Camera not authorized")
        } else if !cameraService.session.isRunning {
            print("[CameraPreview] Starting camera session")
            cameraService.startSession()
            
            // Double-check that session started
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !cameraService.session.isRunning {
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
            
            // Ensure camera is running when view updates
            if !cameraService.session.isRunning && cameraService.isAuthorized {
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
    }
}

// Image picker using PHPickerViewController
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    var onImagePicked: (URL?) -> Void
    
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
                        
                        // Save image to temporary location and return URL
                        if let imageURL = self.saveImageToTemporaryLocation(image) {
                            print("[ImagePicker] Saved image to: \(imageURL.absoluteString)")
                            self.parent.onImagePicked(imageURL)
                        } else {
                            print("[ImagePicker] Failed to save image to temporary location")
                            self.parent.onImagePicked(nil)
                        }
                    }
                }
            } else {
                print("[ImagePicker] Provider cannot load UIImage object")
                parent.onImagePicked(nil)
            }
        }
        
        private func saveImageToTemporaryLocation(_ image: UIImage) -> URL? {
            do {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileName = UUID().uuidString
                let fileURL = documentsDirectory.appendingPathComponent(fileName).appendingPathExtension("jpg")
                
                // Ensure we have valid image data
                guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                    print("[ImagePicker] Could not create JPEG data from image")
                    return nil
                }
                
                try imageData.write(to: fileURL)
                return fileURL
            } catch {
                print("[ImagePicker] Error saving image: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
