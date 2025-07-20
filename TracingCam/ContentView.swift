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
                        cameraService.setupCamera()
                        loadOverlayImage()
                        scheduleControlsHiding()
                        enableScreenshotProtection()
                        screenSize = geometry.size
                    }
                
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
                                    }
                                    .accessibilityLabel("Overlay opacity")
                                    .accessibilityValue("\(Int(settings.imageOpacity * 100)) percent")
                            }
                            .padding(.horizontal)
                            
                            // New image button
                            Button(action: {
                                showImagePicker = true
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
                // Check if this is the first launch
                if settings.isFirstLaunch {
                    showImagePicker = true
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
                        loadOverlayImage() // Reload image in case it was deleted while app was in background
                    }
                    .store(in: &cancellables)
            }
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
    
    // Enable screenshot protection for copyright reasons
    private func enableScreenshotProtection() {
        DispatchQueue.main.async {
            // Use modern API to access windows
            if #available(iOS 15.0, *) {
                // Get the active scene's windows
                for scene in UIApplication.shared.connectedScenes {
                    guard let windowScene = scene as? UIWindowScene else { continue }
                    for window in windowScene.windows {
                        if #available(iOS 11.0, *) {
                            // Dim the window while screen-capture is active; this is a public,
                            // App-Store-safe technique that avoids private APIs.
                            let updateSecureState: () -> Void = {
                                window.alpha = window.screen.isCaptured ? 0.1 : 1.0
                            }
                            updateSecureState()
                            NotificationCenter.default.addObserver(
                                forName: UIScreen.capturedDidChangeNotification,
                                object: window.screen,
                                queue: .main
                            ) { _ in updateSecureState() }
                        }
                    }
                }
            } else {
                // Fallback for older iOS versions
                for window in UIApplication.shared.windows {
                    if #available(iOS 11.0, *) {
                        window.alpha = window.screen.isCaptured ? 0.1 : 1.0
                    }
                }
            }
        }
    }
    
    // Show error alert
    private func showError(message: String, allowRetry: Bool = false) {
        self.errorMessage = message
        self.retryImageSelection = allowRetry
        self.showErrorAlert = true
    }
    
    // Load the overlay image from the stored URL
    private func loadOverlayImage() {
        guard
            let imageURL = settings.overlayImageURL,
            FileManager.default.fileExists(atPath: imageURL.path)
        else {
            overlayImage = nil
            return
        }

        do {
            let imageData = try Data(contentsOf: imageURL)
            if let image = UIImage(data: imageData) {
                self.overlayImage = image
            } else {
                self.overlayImage = nil
                showError(message: "Could not load the saved image. Please select a new one.", allowRetry: true)
            }
        } catch {
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
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        view.isAccessibilityElement = false // The parent view handles accessibility
        
        let previewLayer = cameraService.createPreviewLayer(for: view)
        view.layer.addSublayer(previewLayer)
        
        cameraService.startSession()
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = cameraService.previewLayer {
            previewLayer.frame = uiView.bounds
        }
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
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
            parent.presentationMode.wrappedValue.dismiss()
            
            guard !results.isEmpty else {
                // User cancelled without selecting an image
                return
            }
            
            guard let provider = results.first?.itemProvider else {
                parent.onImagePicked(nil)
                return
            }
            
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        
                        if let error = error {
                            print("Image loading error: \(error.localizedDescription)")
                            self.parent.onImagePicked(nil)
                            return
                        }
                        
                        guard let image = image as? UIImage else {
                            self.parent.onImagePicked(nil)
                            return
                        }
                        
                        // Save image to temporary location and return URL
                        if let imageURL = self.saveImageToTemporaryLocation(image) {
                            self.parent.onImagePicked(imageURL)
                        } else {
                            self.parent.onImagePicked(nil)
                        }
                    }
                }
            } else {
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
                    print("Could not create JPEG data from image")
                    return nil
                }
                
                try imageData.write(to: fileURL)
                return fileURL
            } catch {
                print("Error saving image: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
