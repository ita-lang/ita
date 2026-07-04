# Makefile para Itá SDK

# --- Ferramentas ---
# SDK stable pinado (ver dart-sdk.pin). Paths relativos a ita/ (raiz do Makefile).
DART_BIN ?= .dart-sdk/3.12.2/dart-sdk/bin/dart
PLATFORM_DILL ?= .dart-sdk/3.12.2/dart-sdk/lib/_internal/vm_platform.dill
PACKAGES ?= compiler/.dart_tool/package_config.json

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

# Regenerar o RUNTIME-LIB do parser TOML robusto (compiler/lib/toml/toml.dart
# -> compiler/lib/toml/toml.runtime.dill). O codegen linka essa lib e faz
# Toml.parse() usar parseToml (TOML 1.0 completo) no lugar do parser sintetizado.
# O codegen tambem gera sob demanda (lazy); este target e o caminho manual.
runtime:
	@ITA_DART_BIN=$(DART_BIN) ITA_PLATFORM_DILL=$(PLATFORM_DILL) ITA_PACKAGES=$(PACKAGES) \
		bash compiler/tool/gen_toml_runtime.sh

# Limpar artefatos
clean:
	@rm -rf $(BUILD_DIR)
	@rm -f compiler/lib/toml/toml.runtime.dill
	@echo "Build limpo."

.PHONY: run build test runtime clean
