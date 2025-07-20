import UIKit
import SwiftUI
import AVFoundation

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    /// Flag indicating the window / root‐view hierarchy has been created.
    private var didSetupWindow = false
    
    /// Notification posted when the scene becomes active and we want interested
    /// parties (e.g. `ContentView`) to refresh the camera explicitly.
    static let forceCameraRefreshNotification = Notification.Name("ForceCameraRefresh")

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).

        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView()

        // Use a UIHostingController as window root view controller.
        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIHostingController(rootView: contentView)
            self.window = window
            window.makeKeyAndVisible()

            didSetupWindow = true

#if DEBUG
            print("[SceneDelegate] Window hierarchy configured")
            print(" ├─ window: \(window)")
            if let root = window.rootViewController {
                print(" └─ rootVC: \(root)  (view: \(String(describing: root.view)))")
            }
#endif
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
        handleCameraPermission()

        // Force a camera refresh so the preview comes back after interruptions.
        if didSetupWindow {
#if DEBUG
            print("[SceneDelegate] Scene became active – requesting camera refresh")
#endif
            NotificationCenter.default.post(name: SceneDelegate.forceCameraRefreshNotification, object: nil)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
        // Ensure any pending UserDefaults writes are flushed to disk so the
        // latest overlay settings are not lost.
        UserDefaults.standard.synchronize()
    }

    // MARK: - Helpers
    /// If camera permission was denied, show an alert guiding the user to Settings.
    private func handleCameraPermission() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .denied else { return }

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

        // Present on top-most view controller
        window?.rootViewController?.present(alert, animated: true, completion: nil)
    }
}
