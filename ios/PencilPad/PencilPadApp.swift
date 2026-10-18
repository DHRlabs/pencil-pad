import SwiftUI

@main
struct PencilPadApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            Surface(session: session).ignoresSafeArea()
            Chrome(s: session).ignoresSafeArea()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)  // the home indicator hides itself
        .defersSystemGestures(on: .all)     // a stroke near an edge is not taken over by a system swipe
        .preferredColorScheme(.dark)
        .onAppear { session.start() }
        .onChange(of: scenePhase) { _, new in session.sceneChanged(new) }
    }
}
