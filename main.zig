const std = @import("std");

// ============================================================================
// 1. PALETA DE CORES E TEMA VISUAL TUI (ANSI)
// ============================================================================
pub const Theme = struct {
    pub const red = "\x1b[38;2;248;113;113m";
    pub const green = "\x1b[38;2;74;222;128m";
    pub const yellow = "\x1b[38;2;250;204;21m";
    pub const blue = "\x1b[38;2;96;165;250m";
    pub const purple = "\x1b[38;2;192;132;252m";
    pub const cyan = "\x1b[38;2;56;189;248m";
    pub const orange = "\x1b[38;2;251;146;60m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const reset = "\x1b[0m";
    pub const clear_screen = "\x1b[2J\x1b[H";
};

// ============================================================================
// 2. MODELOS DE DADOS E CONTRATOS DO PIPELINE DE AGENTES
// ============================================================================
pub const EventoTransacional = struct {
    id: u64,
    payload: []const u8,
    valor_eur: f64,
    status: []const u8,
};

pub const ContextoRuntime = struct {
    allocator: std.mem.Allocator,
    executando: bool = true,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator) ContextoRuntime {
        return .{ .allocator = allocator };
    }

    pub fn log(self: *ContextoRuntime, comptime fmt: []const u8, args: anytype) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mutex.unlock();
        std.debug.print("  {s}⚡ [2flow Runtime]{s} " ++ fmt ++ "\n", .{ Theme.cyan, Theme.reset } ++ args);
    }
};

// Assinatura padrão para qualquer agente dinâmico instanciado pelo 2flow
pub const AgenteHandlerFn = *const fn (ctx: *ContextoRuntime, ev: *EventoTransacional) bool;

pub const RegistoAgente = struct {
    nome: []const u8,
    handler: AgenteHandlerFn,
};

// ============================================================================
// 3. PARSER 2FLOW EM TEMPO DE COMPILAÇÃO (COMPTIME AST)
// ============================================================================
pub const TipoNoFlow = enum {
    modulo,
    sequencia,
    paralelo,
};

pub const NoFlowAST = struct {
    tipo: TipoNoFlow,
    nome: []const u8 = "",
    filhos: []const NoFlowAST = &.{},
    compensador_erro: []const u8 = "", // Suporte a !-> Rollback
};

const TokenKind = enum {
    identifier,
    arrow,
    error_arrow,
    open_bracket,
    close_bracket,
    comma,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

fn tokenize(comptime input: []const u8) []const Token {
    comptime {
        var tokens: []const Token = &.{};
        var i: usize = 0;
        while (i < input.len) {
            const c = input[i];

            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                i += 1;
                continue;
            }

            // Operador de erro/saga !->
            if (i + 3 <= input.len and std.mem.eql(u8, input[i .. i + 3], "!->")) {
                tokens = tokens ++ .{Token{ .kind = .error_arrow, .text = "!->" }};
                i += 3;
                continue;
            }

            // Operador de sequência :--:
            if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], ":--:")) {
                tokens = tokens ++ .{Token{ .kind = .arrow, .text = ":--:" }};
                i += 4;
                continue;
            }

            if (c == '[') {
                tokens = tokens ++ .{Token{ .kind = .open_bracket, .text = "[" }};
                i += 1;
                continue;
            }
            if (c == ']') {
                tokens = tokens ++ .{Token{ .kind = .close_bracket, .text = "]" }};
                i += 1;
                continue;
            }
            if (c == ',') {
                tokens = tokens ++ .{Token{ .kind = .comma, .text = "," }};
                i += 1;
                continue;
            }

            if (std.ascii.isAlphanumeric(c) or c == '_') {
                const start = i;
                while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
                    i += 1;
                }
                tokens = tokens ++ .{Token{ .kind = .identifier, .text = input[start..i] }};
                continue;
            }

            @compileError(std.fmt.comptimePrint("Caractere inválido na notação 2flow: '{c}'", .{c}));
        }

        return tokens;
    }
}

const ParseResult = struct {
    node: NoFlowAST,
    read_count: usize,
};

fn parseExpression(comptime tokens: []const Token, comptime start: usize) ParseResult {
    comptime {
        var idx = start;
        var seq_nodes: []const NoFlowAST = &.{};
        while (idx < tokens.len) {
            const tok = tokens[idx];

            if (tok.kind == .close_bracket or tok.kind == .comma) break;

            if (tok.kind == .identifier) {
                var node = NoFlowAST{ .tipo = .modulo, .nome = tok.text };
                idx += 1;

                // Verifica se há canal de erro associado (!-> Compensador)
                if (idx < tokens.len and tokens[idx].kind == .error_arrow) {
                    idx += 1; // consome '!->'
                    if (idx >= tokens.len or tokens[idx].kind != .identifier) {
                        @compileError("Erro 2flow: Esperado identificador de agente após '!->'");
                    }
                    node.compensador_erro = tokens[idx].text;
                    idx += 1;
                }

                seq_nodes = seq_nodes ++ .{node};
            } else if (tok.kind == .open_bracket) {
                idx += 1;
                var branch_nodes: []const NoFlowAST = &.{};

                while (idx < tokens.len and tokens[idx].kind != .close_bracket) {
                    const res = parseExpression(tokens, idx);
                    branch_nodes = branch_nodes ++ .{res.node};
                    idx += res.read_count;

                    if (idx < tokens.len and tokens[idx].kind == .comma) {
                        idx += 1;
                    }
                }

                if (idx >= tokens.len or tokens[idx].kind != .close_bracket) {
                    @compileError("Erro 2flow: Esperado ']' para fechar o bloco paralelo.");
                }
                idx += 1;

                seq_nodes = seq_nodes ++ .{NoFlowAST{
                    .tipo = .paralelo,
                    .filhos = branch_nodes,
                }};
            } else if (tok.kind == .arrow) {
                idx += 1;
            } else {
                @compileError("Token inesperado no parser 2flow.");
            }
        }

        if (seq_nodes.len == 1) {
            return .{ .node = seq_nodes[0], .read_count = idx - start };
        }

        return .{
            .node = NoFlowAST{ .tipo = .sequencia, .filhos = seq_nodes },
            .read_count = idx - start,
        };
    }
}

pub fn parse2Flow(comptime script: []const u8) NoFlowAST {
    comptime {
        const tokens = tokenize(script);
        const res = parseExpression(tokens, 0);
        return res.node;
    }
}

// ============================================================================
// 4. MOTOR DE EXECUÇÃO E ORQUESTRAÇÃO DE DADOS (RUNTIME ORCHESTRATOR)
// ============================================================================
pub const TwoFlowOrchestrator = struct {
    ctx: *ContextoRuntime,
    catalogo: std.StringHashMap(AgenteHandlerFn),

    pub fn init(ctx: *ContextoRuntime) TwoFlowOrchestrator {
        return .{
            .ctx = ctx,
            .catalogo = std.StringHashMap(AgenteHandlerFn).init(ctx.allocator),
        };
    }

    pub fn deinit(self: *TwoFlowOrchestrator) void {
        self.catalogo.deinit();
    }

    pub fn registarAgente(self: *TwoFlowOrchestrator, nome: []const u8, handler: AgenteHandlerFn) !void {
        try self.catalogo.put(nome, handler);
    }

    /// Executa recursivamente a AST gerada pelo 2flow, orquestrando o fluxo de dados
    pub fn executarFlow(self: *TwoFlowOrchestrator, comptime node: NoFlowAST, ev: *EventoTransacional) bool {
        const T = Theme;

        switch (node.tipo) {
            .modulo => {
                const handler = self.catalogo.get(node.nome) orelse {
                    self.ctx.log("{s}🚨 Erro crítico: Agente '{s}' não está registado no catálogo!{s}", .{ T.red, node.nome, T.reset });
                    return false;
                };

                self.ctx.log("▶️ Executando Agente: {s}{s}{s} (ID Ev: {d})", .{ T.bold, node.nome, T.reset, ev.id });
                const sucesso = handler(self.ctx, ev);

                if (!sucesso) {
                    self.ctx.log("{s}❌ Agente '{s}' falhou!{s}", .{ T.red, node.nome, T.reset });

                    // Verifica se existe canal de compensação configurado via !->
                    if (node.compensador_erro.len > 0) {
                        const compensador = self.catalogo.get(node.compensador_erro) orelse {
                            self.ctx.log("{s}🚨 Agente compensador '{s}' não registado!{s}", .{ T.red, node.compensador_erro, T.reset });
                            return false;
                        };

                        self.ctx.log("{s}🛡️ [Saga Rollback] ACIONANDO compensador: {s}{s}{s}", .{ T.yellow, T.bold, node.compensador_erro, T.reset });
                        ev.status = "EM_ROLLBACK";
                        _ = compensador(self.ctx, ev);
                    }
                    return false;
                }

                return true;
            },

            .sequencia => {
                inline for (node.filhos) |filho| {
                    const ok = self.executarFlow(filho, ev);
                    if (!ok) return false; // Interrompe o pipeline em caso de falha não tratada
                }
                return true;
            },

            .paralelo => {
                self.ctx.log("🔀 [Fork Paralelo] A disparar {d} ramos concorrentes...", .{node.filhos.len});

                var resultados: [node.filhos.len]bool = @splat(true);
                var threads: std.ArrayList(std.Thread) = .empty;
                defer threads.deinit(self.ctx.allocator);

                inline for (node.filhos, 0..) |filho, i| {
                    const Worker = struct {
                        fn run(orch: *TwoFlowOrchestrator, event: *EventoTransacional, res: *bool) void {
                            res.* = orch.executarFlow(filho, event);
                        }
                    };
                    const t = std.Thread.spawn(.{}, Worker.run, .{ self, ev, &resultados[i] }) catch {
                        self.ctx.log("🚨 Falha ao criar thread para ramo paralelo.", .{});
                        return false;
                    };
                    threads.append(self.ctx.allocator, t) catch {};
                }

                for (threads.items) |th| {
                    th.join();
                }

                // Verifica se algum ramo falhou na barreira de junção (Join)
                inline for (node.filhos, 0..) |_, i| {
                    if (!resultados[i]) {
                        self.ctx.log("{s}❌ Barreira Fork-Join falhou num dos ramos.{s}", .{ T.red, T.reset });
                        return false;
                    }
                }

                self.ctx.log("✅ Barreira Fork-Join concluída com sucesso.", .{});
                return true;
            },
        }
    }
};

// ============================================================================
// 5. IMPLEMENTAÇÃO DOS AGENTES DE NEGÓCIO DO ERP
// ============================================================================

fn sleepMs(ms: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    io.sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn agenteValidarOrdem(ctx: *ContextoRuntime, ev: *EventoTransacional) bool {
    ctx.log("   [AgenteValidar] A analisar dados da ordem: {s} (Montante: {d:.2} EUR)", .{ ev.payload, ev.valor_eur });
    sleepMs(40);
    ev.status = "VALIDADO";
    return true;
}

fn agenteAuditoriaFiscal(ctx: *ContextoRuntime, ev: *EventoTransacional) bool {
    ctx.log("   [AgenteFiscal] NIF validado com 23% IVA para o evento #{d}", .{ev.id});
    sleepMs(50);
    return true;
}

fn agenteVerificarEstoque(ctx: *ContextoRuntime, ev: *EventoTransacional) bool {
    ctx.log("   [AgenteEstoque] Stock verificado no armazém central para #{d}", .{ev.id});
    sleepMs(30);
    return true;
}

fn agenteDebitarConta(ctx: *ContextoRuntime, ev: *EventoTransacional) bool {
    ctx.log("   [AgenteTesouraria] A tentar debitar {d:.2} EUR da conta bancária...", .{ev.valor_eur});
    sleepMs(60);
    // Simula sucesso no débito
    ev.status = "DEBITADO";
    return true;
}

fn agenteEstornarConta(ctx: *ContextoRuntime, ev: *EventoTransacional) bool {
    ctx.log("   [AgenteEstorno] SAGA ROLLBACK: Devolvendo fundos à conta e cancelando ordem #{d}.", .{ev.id});
    sleepMs(50);
    ev.status = "ESTORNADO";
    return true;
}

fn agenteEmitirNota(ctx: *ContextoRuntime, ev: *EventoTransacional) bool {
    ctx.log("   [AgenteFaturacao] Nota fiscal emitida com sucesso para o evento #{d}.", .{ev.id});
    sleepMs(40);
    ev.status = "CONCLUIDO";
    return true;
}

// ============================================================================
// 6. MAIN - COMPILAÇÃO DA DSL 2FLOW E EXECUÇÃO
// ============================================================================
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime_ctx = ContextoRuntime.init(allocator);

    const T = Theme;

    std.debug.print("{s}", .{T.clear_screen});
    std.debug.print("{s}╔═══════════════════════════════════════════════════════════════════════════════════════════════╗{s}\n", .{ T.cyan, T.reset });
    std.debug.print("{s}║ 🌊 ORQUESTRADOR NATIVO 2FLOW EM ZIG: PARSER COMPTIME, REGISTO DINÂMICO & FLUXO DE DADOS     ║{s}\n", .{ T.bold, T.reset });
    std.debug.print("{s}╚═══════════════════════════════════════════════════════════════════════════════════════════════╝{s}\n\n", .{ T.cyan, T.reset });

    // 1. Definição da nossa notação 2flow combinando Sequência, Fork-Join e Saga (!->)
    const script_2flow =
        \\AgenteValidarOrdem 
        \\  :--: [AgenteAuditoriaFiscal, AgenteVerificarEstoque] 
        \\  :--: AgenteDebitarConta !-> AgenteEstornarConta 
        \\  :--: AgenteEmitirNota
    ;

    // 2. Análise e parsing 100% em tempo de compilação (comptime)
    const ast_compilada = comptime parse2Flow(script_2flow);

    std.debug.print("{s}📋 AST do 2flow gerada com sucesso em Comptime.{s}\n\n", .{ T.bold, T.reset });

    // 3. Inicialização do Orquestrador Runtime
    var orquestrador = TwoFlowOrchestrator.init(&runtime_ctx);
    defer orquestrador.deinit();

    // 4. Registo dos Agentes dinâmicos no catálogo do orquestrador
    try orquestrador.registarAgente("AgenteValidarOrdem", agenteValidarOrdem);
    try orquestrador.registarAgente("AgenteAuditoriaFiscal", agenteAuditoriaFiscal);
    try orquestrador.registarAgente("AgenteVerificarEstoque", agenteVerificarEstoque);
    try orquestrador.registarAgente("AgenteDebitarConta", agenteDebitarConta);
    try orquestrador.registarAgente("AgenteEstornarConta", agenteEstornarConta);
    try orquestrador.registarAgente("AgenteEmitirNota", agenteEmitirNota);

    std.debug.print("{s}▶️ A Disparar Evento Transacional pelo Motor 2flow...{s}\n\n", .{ T.bold, T.reset });

    var evento = EventoTransacional{
        .id = 88401,
        .payload = "Compra de 10x Servidores Rack 1U - Datacenter Lisboa",
        .valor_eur = 7850.00,
        .status = "PENDENTE",
    };

    // 5. Execução do fluxo de dados orquestrado
    const sucesso = orquestrador.executarFlow(ast_compilada, &evento);
    _ = sucesso;

    std.debug.print("\n{s}┌── 🏁 RESULTADO DA ORQUESTRAÇÃO 2FLOW ───────────────────────────────────────────┐{s}\n", .{ T.green, T.reset });
    std.debug.print("{s}│{s} • ID do Evento         : {s}{d}{s}\n", .{ T.green, T.reset, T.yellow, evento.id, T.reset });
    std.debug.print("{s}│{s} • Estado Final da Transação: {s}🟢 {s}{s}\n", .{ T.green, T.reset, T.green, evento.status, T.reset });
    std.debug.print("{s}│{s} • Orquestração 2flow   : {s}Sucesso com Zero Overhead em Comptime{s}          {s}│{s}\n", .{ T.green, T.reset, T.cyan, T.reset, T.green, T.reset });
    std.debug.print("{s}└──────────────────────────────────────────────────────────────────────────────────┘{s}\n\n", .{ T.green, T.reset });
}
