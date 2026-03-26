import SwiftUI

@main
struct GlutterApp: App {
  let engine = DartEngine.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}