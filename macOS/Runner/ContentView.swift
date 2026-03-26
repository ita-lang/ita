import SwiftUI

struct ContentView: View {
    // Observa as mudanças no Engine
    @ObservedObject var engine = DartEngine.shared
    
    var body: some View {
       VStack(spacing: 20) {
           Text("Glutter Counter")
               .font(.headline)
           
           // O número vem do Dart!
           Text("\(engine.counterValue)")
               .font(.system(size: 72, weight: .bold))
               .foregroundColor(.blue)
           
           Button("Incrementar no Dart") {
               engine.onButtonClick()
           }
           .padding()
       }
       .frame(width: 300, height: 200)
    }
}
