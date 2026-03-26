#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Definindo o tipo do callback que o Swift vai passar
typedef void (*SwiftCallback)(int value);

// Inicialização recebe o callback
bool InitializeDartEngine(const char* script_path, const char* platform_path, SwiftCallback callback);

// O Swift chama isso quando clicar
void NotifyButtonClick();

bool ShutdownDartEngine();

#ifdef __cplusplus
}
#endif