# ==============================================================================
# 🌊 2flow — Full Agentic Stack (AllasCode)
# Makefile: Automação de Build, Testes e Compilação WebAssembly (2FV)
# ==============================================================================

ZIG ?= zig
TARGET_WASM = wasm32-freestanding
WASM_OUT = 2flow.wasm

.PHONY: all wasm wasm-fast wasm-debug test test-wasm test-all run-datapipeline run-empresa fmt clean help

# Alvo padrão: compila o módulo WASM otimizado e executa todos os testes
all: wasm test-all

# ------------------------------------------------------------------------------
# ⚡ COMPILAÇÃO WEBASSEMBLY (2FV - TWO-FACTOR VALIDATION NO FRONTEND)
# ------------------------------------------------------------------------------

## wasm: Compila o motor de validação semântica para WASM (ReleaseSmall - ideal para navegadores)
wasm:
	@echo "📦 [2flow 2FV] Compilando WebAssembly para Pre-Flight no Frontend (ReleaseSmall)..."
	$(ZIG) build-exe wasm.zig -target $(TARGET_WASM) -O ReleaseSmall -rdynamic --name 2flow
	@echo "✅ [2flow 2FV] Módulo WebAssembly gerado com sucesso: $(WASM_OUT)"

## wasm-fast: Compila para WebAssembly com otimização de velocidade máxima
wasm-fast:
	@echo "🚀 [2flow 2FV] Compilando WebAssembly (ReleaseFast)..."
	$(ZIG) build-exe wasm.zig -target $(TARGET_WASM) -O ReleaseFast -rdynamic --name 2flow
	@echo "✅ [2flow 2FV] Módulo WebAssembly (Fast) gerado com sucesso: $(WASM_OUT)"

## wasm-debug: Compila para WebAssembly em modo Debug com símbolos completos
wasm-debug:
	@echo "🐛 [2flow 2FV] Compilando WebAssembly em modo Debug..."
	$(ZIG) build-exe wasm.zig -target $(TARGET_WASM) -O Debug -rdynamic --name 2flow
	@echo "✅ [2flow 2FV] Módulo WebAssembly (Debug) gerado com sucesso: $(WASM_OUT)"

# ------------------------------------------------------------------------------
# 🧪 TESTES AUTOMATIZADOS (ZIG 0.16)
# ------------------------------------------------------------------------------

## test-wasm: Executa testes unitários do módulo WASM 2FV
test-wasm:
	@echo "🧪 [2flow] Executando testes unitários do módulo WASM 2FV..."
	$(ZIG) test wasm.zig

## test: Executa a suíte de testes do motor central 2flow
test:
	@echo "🧪 [2flow] Executando testes da topologia central..."
	$(ZIG) test tests/main.zig

## test-erp: Valida o MOTOR REAL (main.zig) com um fluxo ERP complexo de ponta a ponta
test-erp:
	@echo "🧪 [2flow] Validando o motor real com o fluxo ERP complexo..."
	$(ZIG) test --dep flow -Mroot=tests/erp_complexo.zig -Mflow=main.zig

## test-all: Executa TODOS os testes do ecossistema 2flow
test-all: test-wasm test test-erp
	@echo "🧪 [2flow] Executando testes do Data Pipeline..."
	cd examples/data-pipeline && $(ZIG) test test_pipeline.zig
	@echo "🧪 [2flow] Executando testes da Empresa Agêntica..."
	cd examples/empresa-agentica && $(ZIG) test test_empresa.zig
	@echo "🎉 Todos os testes de todos os módulos passaram com 100% de êxito!"

# ------------------------------------------------------------------------------
# 🚀 EXECUÇÃO DE EXEMPLOS
# ------------------------------------------------------------------------------

## run-datapipeline: Executa o pipeline moderno de telemetria e higienização
run-datapipeline:
	cd examples/data-pipeline && $(ZIG) run main.zig

## run-empresa: Executa o ciclo corporativo completo da micro-empresa agêntica
run-empresa:
	cd examples/empresa-agentica && $(ZIG) run main.zig

# ------------------------------------------------------------------------------
# 🧹 MANUTENÇÃO E FORMATAÇÃO
# ------------------------------------------------------------------------------

## fmt: Formata todo o código Zig do repositório conforme as diretrizes canônicas
fmt:
	$(ZIG) fmt wasm.zig main.zig tests/main.zig examples/data-pipeline/ examples/empresa-agentica/

## clean: Remove binários compilados e caches temporários
clean:
	rm -f $(WASM_OUT) wasm.wasm wasm.o wasm.wasm.o 2flow.o
	rm -rf zig-cache zig-out .zig-cache
	@echo "✨ Artefatos de compilação limpos."

## help: Exibe os comandos disponíveis
help:
	@echo ""
	@echo "🌊 2flow — Full Agentic Stack (AllasCode) — Comandos Disponíveis:"
	@echo ""
	@echo "  make wasm              Compila 2flow.wasm (ReleaseSmall para browsers)"
	@echo "  make wasm-fast         Compila 2flow.wasm otimizado para velocidade"
	@echo "  make wasm-debug        Compila 2flow.wasm com símbolos de debug"
	@echo "  make test-wasm         Roda os testes do validador 2FV WASM"
	@echo "  make test              Roda os testes da DSL central 2flow"
	@echo "  make test-erp          Valida o motor real com um fluxo ERP complexo"
	@echo "  make test-all          Roda todos os testes do repositório"
	@echo "  make run-datapipeline  Executa o exemplo Modern Data Pipeline"
	@echo "  make run-empresa       Executa o exemplo Micro-Empresa Agêntica"
	@echo "  make fmt               Formata todo o código Zig"
	@echo "  make clean             Limpa os arquivos .wasm e temporários"
	@echo ""
