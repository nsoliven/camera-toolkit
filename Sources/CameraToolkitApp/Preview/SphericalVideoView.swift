import AVFoundation
import AppKit
import SceneKit
import SwiftUI

/// Look-around view for an equirectangular 360° clip: the player's video
/// is the texture on the inside of a sphere with the camera at its centre.
/// Drag to look around, pinch or scroll to change the field of view. The
/// same `AVPlayer` the flat pane uses drives it, so play/pause and position
/// carry over when the viewer toggles.
struct SphericalVideoView: NSViewRepresentable {
    let player: AVPlayer

    /// Look direction and field of view, clamped so the view never flips
    /// over the poles or zooms into mush.
    struct Orientation: Equatable {
        static let defaultFieldOfView: CGFloat = 80
        static let fieldOfViewRange: ClosedRange<CGFloat> = 30...110
        static let pitchLimit: CGFloat = .pi / 2 - 0.01

        var yaw: CGFloat = 0
        var pitch: CGFloat = 0
        var fieldOfView: CGFloat = defaultFieldOfView

        /// A drag of `delta` points on a view `width` points wide: one full
        /// width pans by the current field of view, so the scene tracks the
        /// cursor.
        mutating func drag(by delta: CGSize, viewWidth width: CGFloat) {
            let radiansPerPoint = (fieldOfView * .pi / 180) / max(width, 1)
            yaw += delta.width * radiansPerPoint
            pitch = min(max(pitch + delta.height * radiansPerPoint, -Self.pitchLimit), Self.pitchLimit)
        }

        mutating func zoom(by factor: CGFloat) {
            guard factor.isFinite, factor > 0 else { return }
            fieldOfView = min(max(fieldOfView / factor, Self.fieldOfViewRange.lowerBound), Self.fieldOfViewRange.upperBound)
        }
    }

    final class Coordinator: NSObject {
        let cameraNode = SCNNode()
        var orientation = Orientation()
        private var lastTranslation: CGPoint = .zero

        func apply() {
            cameraNode.eulerAngles = SCNVector3(orientation.pitch, orientation.yaw, 0)
            cameraNode.camera?.fieldOfView = orientation.fieldOfView
        }

        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            if gesture.state == .began { lastTranslation = .zero }
            let delta = CGSize(width: translation.x - lastTranslation.x, height: translation.y - lastTranslation.y)
            lastTranslation = translation
            orientation.drag(by: delta, viewWidth: view.bounds.width)
            apply()
        }

        @objc func magnify(_ gesture: NSMagnificationGestureRecognizer) {
            orientation.zoom(by: 1 + gesture.magnification)
            gesture.magnification = 0
            apply()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = ScrollZoomSCNView()
        view.coordinator = context.coordinator
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.scene = Self.makeScene(player: player, cameraNode: context.coordinator.cameraNode)
        view.pointOfView = context.coordinator.cameraNode
        view.isPlaying = true
        context.coordinator.apply()
        view.addGestureRecognizer(NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.magnify(_:))))
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        guard let material = nsView.scene?.rootNode.childNodes.first?.geometry?.firstMaterial,
              (material.diffuse.contents as? AVPlayer) !== player else { return }
        material.diffuse.contents = player
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        nsView.isPlaying = false
        nsView.scene?.rootNode.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = nil
        nsView.scene = nil
    }

    static func makeScene(player: AVPlayer, cameraNode: SCNNode) -> SCNScene {
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = player
        // Seen from inside: draw the back faces, and mirror horizontally so
        // the scene isn't reversed.
        material.cullMode = .front
        material.diffuse.wrapS = .repeat
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)
        sphere.firstMaterial = material
        scene.rootNode.addChildNode(SCNNode(geometry: sphere))

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3Zero
        scene.rootNode.addChildNode(cameraNode)
        return scene
    }
}

/// Scroll wheel zoom for the sphere view — trackpad pinch arrives as a
/// magnification gesture, a mouse wheel as scroll events.
private final class ScrollZoomSCNView: SCNView {
    weak var coordinator: SphericalVideoView.Coordinator?

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator else { return super.scrollWheel(with: event) }
        coordinator.orientation.zoom(by: 1 + event.scrollingDeltaY * 0.01)
        coordinator.apply()
    }
}
