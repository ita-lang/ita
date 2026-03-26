import Foundation
import Combine

class DartEngine: ObservableObject {
    static let shared = DartEngine()
    
    // Variável reativa para a UI
    @Published var counterValue: Int = 0
    
    init() {
        let bundle = Bundle.main
        guard let scriptPath = bundle.path(forResource: "hello", ofType: "dill"),
              let platformPath = bundle.path(forResource: "vm_platform", ofType: "dill") else {
            print("Arquivos não encontrados")
            return
        }
        
        // Passamos uma closure C para o C++
        let callback: @convention(c) (Int32) -> Void = { val in
            // Volta para a Main Thread para atualizar UI
            DispatchQueue.main.async {
                DartEngine.shared.counterValue = Int(val)
            }
        }
        
        let result = InitializeDartEngine(scriptPath, platformPath, callback)
        print("Engine Iniciado: \(result)")
    }

    func onButtonClick() {
        NotifyButtonClick()
    }
}