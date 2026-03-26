#include <iostream>
#include <fstream>
#include <vector>
#include <cstring>
#include "include/dart_api.h"
#include "dart_api_bridge.h"

// Globais
Dart_IsolateFlags flags;
static Dart_Isolate g_isolate = nullptr;
static Dart_PersistentHandle g_library = nullptr;
static SwiftCallback g_swiftCallback = nullptr;

// Helper de Arquivo
uint8_t* ReadFile(const char* path, intptr_t* size) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file.is_open()) return nullptr;
    std::streamsize fsize = file.tellg();
    file.seekg(0, std::ios::beg);
    uint8_t* buffer = new uint8_t[fsize];
    file.read(reinterpret_cast<char*>(buffer), fsize);
    *size = fsize;
    return buffer;
}

// Implementação Nativa: changeUI
void ChangeUI_Native(Dart_NativeArguments arguments) {
    int64_t value = 0;
    Dart_GetNativeIntegerArgument(arguments, 0, &value);
    
    // Avisa o Swift!
    if (g_swiftCallback) {
        g_swiftCallback((int)value);
    }
}

// Implementação Nativa: CustomPrint
void CustomPrint_Native(Dart_NativeArguments arguments) {
    Dart_Handle string = Dart_GetNativeArgument(arguments, 0);
    const char* c_str = nullptr;
    Dart_StringToCString(string, &c_str);
    std::cout << "[NATIVE LOG] " << c_str << std::endl;
}

// Resolver
Dart_NativeFunction MyResolver(Dart_Handle name, int num_args, bool* auto_setup_scope) {
    const char* func_name = nullptr;
    Dart_StringToCString(name, &func_name);
    
    if (strcmp(func_name, "changeUI") == 0) {
        *auto_setup_scope = true;
        return ChangeUI_Native;
    }
    if (strcmp(func_name, "CustomPrint") == 0) {
        *auto_setup_scope = true;
        return CustomPrint_Native;
    }
    return nullptr;
}

// Inicialização
bool InitializeDartEngine(const char* script_path, const char* platform_path, SwiftCallback callback) {
    // 1. Guarda o callback
    g_swiftCallback = callback;

    Dart_SetVMFlags(0, nullptr);
    Dart_InitializeParams params = {};
    params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
    if (Dart_Initialize(&params)) return false;

    Dart_IsolateFlagsInitialize(&flags);

    intptr_t platform_size = 0;
    uint8_t* platform_kernel = ReadFile(platform_path, &platform_size);
    if (!platform_kernel) return false;

    char* error = nullptr;
    g_isolate = Dart_CreateIsolateGroupFromKernel(script_path, "main", platform_kernel, platform_size, &flags, nullptr, nullptr, &error);
    if (!g_isolate) {
        std::cerr << "Isolate error: " << error << std::endl;
        return false;
    }

    // REMOVIDO: Dart_EnterIsolate(g_isolate); // O Create já entra!
    Dart_EnterScope();

    intptr_t app_size = 0;
    uint8_t* app_kernel = ReadFile(script_path, &app_size);
    if (!app_kernel) return false;

    Dart_Handle library = Dart_LoadLibraryFromKernel(app_kernel, app_size);
    if (Dart_IsError(library)) return false;

    Dart_SetNativeResolver(library, MyResolver, nullptr);
    g_library = Dart_NewPersistentHandle(library);

    // Chama o main() inicial
    Dart_Handle main_name = Dart_NewStringFromCString("main");
    Dart_Invoke(library, main_name, 0, nullptr);

    Dart_ExitScope();
    Dart_ExitIsolate();
    return true;
}

// Clique do Botão (Swift -> C++ -> Dart)
void NotifyButtonClick() {
    if (!g_isolate) return;
    
    Dart_EnterIsolate(g_isolate);
    Dart_EnterScope();
    
    Dart_Handle library = Dart_HandleFromPersistent(g_library);
    Dart_Handle name = Dart_NewStringFromCString("incrementHandler");
    
    Dart_Handle result = Dart_Invoke(library, name, 0, nullptr);
    if (Dart_IsError(result)) {
        std::cerr << "Erro no Dart: " << Dart_GetError(result) << std::endl;
    }
    
    Dart_ExitScope();
    Dart_ExitIsolate();
}

bool ShutdownDartEngine() {
    // Cleanup simples
    return true;
}