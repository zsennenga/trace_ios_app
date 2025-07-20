# TracingCam

TracingCam is a minimal iOS application that lets you trace over a live camera feed by displaying a semi-transparent reference image on top of the camera preview.  
It was designed for quick personal use (e.g. sketching, wood-working, nail art, cake decorating, etc.) and keeps the UI as simple and distraction-free as possible.

---

## Features

• First-launch image picker – choose the reference image the very first time you open the app.  
• Live camera feed – shows the back-camera preview full-screen.  
• Overlay image – initially centered at **50 % width / proportional height** with **50 % opacity**.  
• Multi-touch gestures  
  • **Drag** to move the image.  
  • **Pinch** to scale the image.  
• Opacity slider – adjust transparency from 10 % to 100 %.  
• “Choose Image” button – pick a new reference image at any time (resets position, scale, and opacity to defaults).  
• Auto-hide controls – if the screen is untouched for 3 s the slider & button fade away; tap anywhere to bring them back.  
• State persistency – the selected image, its position/scale, and opacity are saved and automatically restored on the next launch.  

---

## Quick Start

1. **Clone or download** this repository.  
2. **Open** `TracingCam.xcodeproj` in Xcode 14 + (or the latest stable release).  
3. **Build & run** on an iPhone (real device required for camera access).  
4. On first launch, **grant Camera & Photo Library permissions** when prompted.  
5. **Pick a reference image** from your photo library – it will appear semi-transparent over the camera feed.  
6. **Trace away!**

---

## Using the App

| Action | How |
|-------|-----|
| Move image | Touch-drag with one finger |
| Resize image | Pinch with two fingers |
| Change opacity | Use the slider (bottom overlay) |
| Pick a new image | Tap “Choose Image” |
| Reveal / hide UI | Tap anywhere on the screen; it auto-hides after 3 s of inactivity |

Tip: If the UI disappears while you are adjusting the picture, just tap once on the screen to bring it back.

---

## Requirements

* iOS 15.0 or later  
* Swift 5.8+  
* Xcode 14+  
* An iPhone with a rear camera (the simulator will show a black feed)

---

## Permissions

TracingCam requests:
* **Camera** – to show the live feed behind your reference image.  
* **Photo Library** – to let you pick images for tracing.

These permissions are only used for the stated purposes; no data is sent off-device.

---

## Project Structure (High-Level)

```
TracingCam/
├─ AppDelegate.swift       // UIApplication entry point
├─ SceneDelegate.swift     // Sets up SwiftUI ContentView
├─ ContentView.swift       // Main UI – camera preview, overlay, controls
├─ CameraService.swift     // AVFoundation camera handling
├─ AppSettings.swift       // Saves & restores overlay state (UserDefaults)
├─ LaunchScreen.storyboard // Simple launch screen
└─ Assets.xcassets         // App icon & accent color
```

---

## Customisation Ideas

* Support front camera selection.  
* Add rotation gesture for the overlay.  
* Export a snapshot of camera + overlay.  
* iPad-specific UI refinements.

Feel free to fork and tinker!

---

## License

This project is released under the MIT License. See `LICENSE` for details.
