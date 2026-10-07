import SwiftUI

@main
struct VlogCamApp: App {
    @State private var store: ClipStore
    @State private var camera: CameraModel

    init() {
        let store = ClipStore()
        _store = State(initialValue: store)
        _camera = State(initialValue: CameraModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(store)
                .environment(camera)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
