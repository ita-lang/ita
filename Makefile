# Makefile para Glutter (Mini-Flutter) - Versão App Bundle (Final com Organização)

# --- Ferramentas ---
CXX = g++
SWIFTC = swiftc
# Ajuste se necessário
DART_BIN = /Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/dart

# --- Diretórios ---
BUILD_DIR = build
ENGINE_DIR = engine
MACOS_DIR = macos/Runner
LIB_DART_DIR = lib

# --- Arquivos ---
# O executável bruto (antes de virar .app)
EXEC_NAME = GlutterApp
EXEC_PATH = $(BUILD_DIR)/$(EXEC_NAME)

# O Bundle final
APP_BUNDLE = $(BUILD_DIR)/$(EXEC_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents/MacOS
APP_RESOURCES = $(APP_BUNDLE)/Contents/Resources

# Objetos e Kernels
DART_HOST_OBJ = $(BUILD_DIR)/dart_host.o
APP_KERNEL = $(BUILD_DIR)/hello.dill
PLATFORM_KERNEL = $(BUILD_DIR)/vm_platform.dill

# Fontes
CPP_SRC = $(ENGINE_DIR)/dart_host.cpp
SWIFT_SRC = $(MACOS_DIR)/GlutterApp.swift \
            $(MACOS_DIR)/ContentView.swift \
            $(MACOS_DIR)/DartEngine.swift
BRIDGE_HEADER = $(MACOS_DIR)/Bridging-Header.h

# Bibliotecas e Flags
INCLUDES = -I$(ENGINE_DIR)/include
LIBS_DIR = -L$(ENGINE_DIR)/lib

DART_LIBS_FLAGS = $(LIBS_DIR) \
                  -Xlinker -ldart_jit \
                  -Xlinker -ldart_engine_jit_static \
                  -Xlinker -lc++_google \
                  -Xlinker -lc++ \
                  -Xlinker -framework -Xlinker CoreFoundation \
                  -Xlinker -framework -Xlinker CoreServices

# --- Regras ---

# Regra principal
all: bundle

# 1. Prepara diretórios e copia a plataforma
prepare:
	@mkdir -p $(BUILD_DIR)
	@printf "📂 Preparando ambiente... "
	@cp $(ENGINE_DIR)/lib/vm_platform.dill $(PLATFORM_KERNEL)
	@echo "✅"

# 2. Compila Dart (Source -> Dill)
$(APP_KERNEL): $(LIB_DART_DIR)/main.dart prepare
	@printf "📦 Compilando Dart Kernel... "
	@$(DART_BIN) --snapshot-kind=kernel --snapshot=$(APP_KERNEL) $(LIB_DART_DIR)/main.dart
	@echo "✅"

# 3. Compila C++ (Cpp -> Object) dentro da pasta build
$(DART_HOST_OBJ): $(CPP_SRC) prepare
	@printf "🔧 Compilando Engine C++... "
	@$(CXX) -c $(CPP_SRC) $(INCLUDES) -o $(DART_HOST_OBJ) -std=c++14
	@echo "✅"

# 4. Compila Swift e Linka (Swift + Object + Libs -> Executável)
$(EXEC_PATH): $(APP_KERNEL) $(DART_HOST_OBJ) $(SWIFT_SRC)
	@printf "🍎 Compilando App Swift e Linkando... "
	@$(SWIFTC) $(SWIFT_SRC) \
		-import-objc-header $(BRIDGE_HEADER) \
		$(DART_HOST_OBJ) \
		-I$(ENGINE_DIR)/include \
		$(DART_LIBS_FLAGS) \
		-o $(EXEC_PATH)
	@echo "✅"

# 5. Monta o App Bundle
bundle: $(EXEC_PATH)
	@printf "🍏 Montando App Bundle... "
	@mkdir -p $(APP_CONTENTS)
	@mkdir -p $(APP_RESOURCES)
	@cp $(EXEC_PATH) $(APP_CONTENTS)/
	@cp $(PLATFORM_KERNEL) $(APP_RESOURCES)/vm_platform.dill
	@cp $(APP_KERNEL) $(APP_RESOURCES)/hello.dill
	@echo '&lt;?xml version="1.0" encoding="UTF-8"?&gt;&lt;!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"&gt;&lt;plist version="1.0"&gt;&lt;dict&gt;&lt;key&gt;CFBundleExecutable&lt;/key&gt;&lt;string&gt;$(EXEC_NAME)&lt;/string&gt;&lt;key&gt;CFBundleIdentifier&lt;/key&gt;&lt;string&gt;com.example.glutter&lt;/string&gt;&lt;/dict&gt;&lt;/plist&gt;' > $(APP_BUNDLE)/Contents/Info.plist
	@echo "✅"

# Roda o App
run: bundle
	@echo "🚀 Rodando GlutterApp..."
	@$(APP_CONTENTS)/$(EXEC_NAME)

clean:
	@printf "🧹 Limpando pasta build... "
	@rm -rf $(BUILD_DIR)
	@echo "✅"

.PHONY: all prepare bundle run clean