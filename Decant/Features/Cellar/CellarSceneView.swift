import SceneKit
import SwiftUI

/// SwiftUI bridge for `CellarSceneController`.
struct CellarSceneView: UIViewRepresentable {
    var bottles: [CellarBottle]
    var layout: CellarLayout
    var finish: ShelfFinish
    var dimmed: Set<UUID>
    var controllerRef: (CellarSceneController) -> Void = { _ in }
    var onInspect: (UUID?) -> Void
    var onMove: (UUID, CellarLayout.Slot) -> Void
    var onBeginMove: (UUID) -> Void

    func makeCoordinator() -> CellarSceneController {
        CellarSceneController()
    }

    func makeUIView(context: Context) -> SCNView {
        let controller = context.coordinator
        controllerRef(controller)
        return controller.view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let controller = context.coordinator
        controller.callbacks = .init(onInspect: onInspect, onMove: onMove, onBeginMove: onBeginMove)
        controller.update(bottles: bottles, layout: layout, finish: finish, dimmed: dimmed)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: CellarSceneController) {
        coordinator.teardown()
    }
}
