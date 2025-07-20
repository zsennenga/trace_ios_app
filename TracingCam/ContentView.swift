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
                }
            })
        }
        .onAppear {
            // Check if this is the first launch
            if settings.isFirstLaunch {
                showImagePicker = true
                settings.markAsLaunched()
            }
        }
    }
    
    // Load the overlay image from the stored URL
    private func loadOverlayImage() {
        guard let imageURL = settings.overlayImageURL else { return }
        
        if let imageData = try? Data(contentsOf: imageURL),
           let image = UIImage(data: imageData) {
            self.overlayImage = image
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
        hideControlsTask?.cancel()
        
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
            }
        }
        
        private func saveImageToTemporaryLocation(_ image: UIImage) -> URL? {
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileName = UUID().uuidString
            let fileURL = documentsDirectory.appendingPathComponent(fileName).appendingPathExtension("jpg")
            
            if let imageData = image.jpegData(compressionQuality: 0.8) {
                try? imageData.write(to: fileURL)
                return fileURL
            }
            
            return nil
        }
    }
}
