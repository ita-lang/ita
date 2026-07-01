# Makefile para Itá SDK

# --- Ferramentas ---
DART_BIN ?= /Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/dart
PLATFORM_DILL ?= /Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/vm_platform.dill
PACKAGES ?= /Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/.dart_tool/package_config.json

# --- Diretórios ---
COMPILER = compiler/bin/itac.dart
BUILD_DIR = build

# --- Regras ---

# Compilar e executar um arquivo .tu
# Uso: make run FILE=examples/hello.tu
run:
	@$(DART_BIN) --packages=$(PACKAGES) $(COMPILER) run $(FILE)

# Compilar um arquivo .tu para .dill
# Uso: make build FILE=examples/hello.tu
build:
	@mkdir -p $(BUILD_DIR)
	@$(DART_BIN) --packages=$(PACKAGES) $(COMPILER) build $(FILE)

# Rodar os testes do compilador
test:
	@$(DART_BIN) --packages=$(PACKAGES) compiler/test/test_runner.dart

# Limpar artefatos
clean:
	@rm -rf $(BUILD_DIR)
	@echo "Build limpo."

.PHONY: run build test clean
