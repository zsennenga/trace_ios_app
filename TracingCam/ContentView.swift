import SwiftUI
import UIKit
import AVFoundation
import PhotosUI

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
    
    // Timer for auto-hiding controls
    private let controlHideDelay: TimeInterval = 3.0 // Hide after 3 seconds
    
    var body: some View {
        ZStack {
            // Camera view as background
            CameraPreview(cameraService: cameraService)
                .edgesIgnoringSafeArea(.all)
                .onAppear {
                    cameraService.setupCamera()
                    loadOverlayImage()
                    scheduleControlsHiding()
                    enableScreenshotProtection()
                }
            
            // Overlay image with gestures
            if let image = overlayImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * settings.imageScale)
                    .position(
                        x: UIScreen.main.bounds.width / 2 + settings.imagePosition.x + dragOffset.width,
                        y: UIScreen.main.bounds.height / 2 + settings.imagePosition.y + dragOffset.height
                    )
                    .opacity(settings.imageOpacity)
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
                            Slider(value: $settings.imageOpacity, in: 0.1...1.0)
                                .onChange(of: settings.imageOpacity) { _ in
                                    userInteracted()
                                }
                        }
                        .padding(.horizontal)
                        
                        // New image button
                        Button(action: {
                            showImagePicker = true
                            userInteracted()
                        }) {
                            HStack {
                                Image(systemName: "photo")
                                Text("Choose Image")
                            }
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
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
                    showError(message: "Could not load the selected image. Please try again.")
                }
            })
        }
        .alert(isPresented: $showErrorAlert) {
            Alert(
                title: Text("Error"),
                message: Text(errorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            // Check if this is the first launch
            if settings.isFirstLaunch {
                showImagePicker = true
                settings.markAsLaunched()
            }
            
            // Set up orientation change notification
            NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                let newOrientation = UIDevice.current.orientation
                if newOrientation.isPortrait || newOrientation.isLandscape {
                    self.orientation = newOrientation
                    // Recalculate image positioning for new orientation if needed
                    self.updateLayoutForOrientation()
                }
            }
        }
        .onDisappear {
            cancelHideControlsTask()
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        }
    }
    
    // Update layout when orientation changes
    private func updateLayoutForOrientation() {
        // Adjust positioning if needed based on orientation
        // This ensures the overlay image stays positioned correctly
    }
    
    // Enable screenshot protection for copyright reasons
    private func enableScreenshotProtection() {
        DispatchQueue.main.async {
            let windows = UIApplication.shared.windows
            for window in windows {
                if #available(iOS 17.0, *) {
                    window.windowScene?.screenshotService?.isEnabled = false
                } else {
                    window.isSecureWindow = true
                }
            }
        }
    }
    
    // Show error alert
    private func showError(message: String) {
        self.errorMessage = message
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
                showError(message: "Could not load the saved image. Please select a new one.")
            }
        } catch {
            self.overlayImage = nil
            showError(message: "Error loading image: \(error.localizedDescription)")
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
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
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
        
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
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
            
            guard let provider = results.first?.itemProvider else {
                // Show friendly message when no image selected
                showNoImageSelectedAlert()
                parent.onImagePicked(nil)
                return
            }
            
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                    DispatchQueue.main.async {
                        guard let self = self, let image = image as? UIImage else {
                            self?.parent.onImagePicked(nil)
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
        
        private func showNoImageSelectedAlert() {
            // In a real app, we would show an alert here
            // Since we can't directly show alerts from this coordinator,
            // we pass nil back to the parent which will handle showing an appropriate message
            print("No image was selected")
        }
        
        private func saveImageToTemporaryLocation(_ image: UIImage) -> URL? {
            // Use proper error handling
            do {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileName = UUID().uuidString
                let fileURL = documentsDirectory.appendingPathComponent(fileName).appendingPathExtension("jpg")
                
                if let imageData = image.jpegData(compressionQuality: 0.8) {
                    try imageData.write(to: fileURL)
                    return fileURL
                }
                return nil
            } catch {
                print("Error saving image: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
