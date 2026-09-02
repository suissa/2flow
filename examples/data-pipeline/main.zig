const std = @import("std");
const tools = @import("tools.zig");

const DataPipelineEvent = tools.DataPipelineEvent;
const TextSanitizerTool = tools.TextSanitizerTool;
const EntityExtractorTool = tools.EntityExtractorTool;
const PiiMaskerTool = tools.PiiMaskerTool;
const SentimentAnalyzerTool = tools.SentimentAnalyzerTool;
const AnalyticsEnricherTool = tools.AnalyticsEnricherTool;
const DataSinkWriterTool = tools.DataSinkWriterTool;

// ============================================================================
// PALETA DE CORES ANSI PARA A TUI
// ============================================================================
pub const Theme = struct {
    pub const red = "\x1b[38;2;248;113;113m";
    pub const green = "\x1b[38;2;74;222;128m";
    pub const yellow = "\x1b[38;2;250;204;21m";
    pub const blue = "\x1b[38;2;96;165;250m";
    pub const purple = "\x1b[38;2;192;132;252m";
    pub const cyan = "\x1b[38;2;56;189;248m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const reset = "\x1b[0m";
};

pub const RuntimeCtx = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn log(self: *RuntimeCtx, comptime fmt: []const u8, args: anytype) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mutex.unlock();
        std.debug.print("  " ++ Theme.cyan ++ "⚡ [2flow Pipeline]" ++ Theme.reset ++ " " ++ fmt ++ "\n", args);
    }
};

pub const AgentHandler = *const fn (ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool;

// ============================================================================
// PARSER COMPTIME 2FLOW (LÊ ARQUIVO EXTERNO config.2flow VIA @embedFile)
// ============================================================================
pub const TipoNoFlow = enum { modulo, sequencia, paralelo };

pub const NoFlowAST = struct {
    tipo: TipoNoFlow,
    nome: []const u8 = "",
    filhos: []const NoFlowAST = &.{},
    compensador_erro: []const u8 = "",
};

const TokenKind = enum { identifier, arrow, error_arrow, open_bracket, close_bracket, comma };
const Token = struct { kind: TokenKind, text: []const u8 };

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
            if (i + 3 <= input.len and std.mem.eql(u8, input[i .. i + 3], "!->")) {
                tokens = tokens ++ .{Token{ .kind = .error_arrow, .text = "!->" }};
                i += 3;
                continue;
            }
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
            @compileError("Caractere inválido na notação 2flow");
        }
        return tokens;
    }
}

const ParseResult = struct { node: NoFlowAST, read_count: usize };

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
                if (idx < tokens.len and tokens[idx].kind == .error_arrow) {
                    idx += 1;
                    if (idx >= tokens.len or tokens[idx].kind != .identifier) {
                        @compileError("Esperado identificador de agente após '!->'");
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
                    if (idx < tokens.len and tokens[idx].kind == .comma) idx += 1;
                }
                if (idx >= tokens.len or tokens[idx].kind != .close_bracket) @compileError("Esperado ']'");
                idx += 1;
                seq_nodes = seq_nodes ++ .{NoFlowAST{ .tipo = .paralelo, .filhos = branch_nodes }};
            } else if (tok.kind == .arrow) {
                idx += 1;
            } else {
                @compileError("Token inesperado no parser 2flow");
            }
        }
        if (seq_nodes.len == 1) return .{ .node = seq_nodes[0], .read_count = idx - start };
        return .{ .node = NoFlowAST{ .tipo = .sequencia, .filhos = seq_nodes }, .read_count = idx - start };
    }
}

pub fn parse2Flow(comptime script: []const u8) NoFlowAST {
    comptime {
        const tokens = tokenize(script);
        return parseExpression(tokens, 0).node;
    }
}

// ============================================================================
// MOTOR DE EXECUÇÃO MULTI-THREAD DO PIPELINE (RUNTIME 2FLOW EM ZIG 0.16)
// ============================================================================
pub const PipelineOrchestrator = struct {
    ctx: *RuntimeCtx,
    catalogo: std.StringHashMap(AgentHandler),

    pub fn init(ctx: *RuntimeCtx) PipelineOrchestrator {
        return .{
            .ctx = ctx,
            .catalogo = std.StringHashMap(AgentHandler).init(ctx.allocator),
        };
    }

    pub fn deinit(self: *PipelineOrchestrator) void {
        self.catalogo.deinit();
    }

    pub fn registrarAgente(self: *PipelineOrchestrator, nome: []const u8, handler: AgentHandler) !void {
        try self.catalogo.put(nome, handler);
    }

    pub fn executar(self: *PipelineOrchestrator, comptime node: NoFlowAST, ev: *DataPipelineEvent) bool {
        switch (node.tipo) {
            .modulo => {
                const handler = self.catalogo.get(node.nome) orelse {
                    self.ctx.log(Theme.red ++ "❌ Agente '{s}' não registrado no catálogo!" ++ Theme.reset, .{node.nome});
                    return false;
                };

                self.ctx.log("▶️ Executando Agente: " ++ Theme.bold ++ "{s}" ++ Theme.reset, .{node.nome});
                ev.registrarPasso(node.nome) catch {};

                const sucesso = handler(self.ctx, ev);
                if (!sucesso) {
                    self.ctx.log(Theme.red ++ "🚨 Agente '{s}' falhou!" ++ Theme.reset, .{node.nome});
                    if (node.compensador_erro.len > 0) {
                        const comp = self.catalogo.get(node.compensador_erro) orelse {
                            self.ctx.log(Theme.red ++ "🚨 Agente de compensação '{s}' não encontrado!" ++ Theme.reset, .{node.compensador_erro});
                            return false;
                        };
                        self.ctx.log(Theme.yellow ++ "🛡️ [Saga Fallback] Disparando compensador: {s}" ++ Theme.reset, .{node.compensador_erro});
                        ev.registrarPasso(node.compensador_erro) catch {};
                        _ = comp(self.ctx, ev);
                    }
                    return false;
                }
                return true;
            },

            .sequencia => {
                inline for (node.filhos) |filho| {
                    const ok = self.executar(filho, ev);
                    if (!ok) return false;
                }
                return true;
            },

            .paralelo => {
                self.ctx.log(Theme.purple ++ "🔀 [Fork-Join Paralelo] Iniciando {d} ramos concorrentes em threads nativas..." ++ Theme.reset, .{node.filhos.len});

                var resultados: [node.filhos.len]bool = @splat(true);
                var threads: std.ArrayList(std.Thread) = .empty;
                defer threads.deinit(self.ctx.allocator);

                inline for (node.filhos, 0..) |filho, i| {
                    const Worker = struct {
                        fn run(orch: *PipelineOrchestrator, event: *DataPipelineEvent, res: *bool) void {
                            res.* = orch.executar(filho, event);
                        }
                    };
                    const t = std.Thread.spawn(.{}, Worker.run, .{ self, ev, &resultados[i] }) catch {
                        self.ctx.log(Theme.red ++ "🚨 Falha ao criar thread para ramo paralelo." ++ Theme.reset, .{});
                        return false;
                    };
                    threads.append(self.ctx.allocator, t) catch {};
                }

                for (threads.items) |th| {
                    th.join();
                }

                inline for (node.filhos, 0..) |_, i| {
                    if (!resultados[i]) {
                        self.ctx.log(Theme.red ++ "❌ Falha em um dos ramos da barreira Fork-Join." ++ Theme.reset, .{});
                        return false;
                    }
                }

                self.ctx.log(Theme.green ++ "✅ Barreira Fork-Join sincronizada com sucesso!" ++ Theme.reset, .{});
                return true;
            },
        }
    }
};

// ============================================================================
// IMPLEMENTAÇÃO CONCRETA DOS AGENTES QUE CONSOMEM AS FERRAMENTAS
// ============================================================================

fn agenteSanitizarEntrada(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    const res = TextSanitizerTool.sanitize(ctx.allocator, ev.raw_payload) catch null;
    if (res) |sanitized| {
        ev.sanitized_text = sanitized;
        ev.is_valid = true;
        ctx.log("   [Sanitizer] Texto higienizado e validado ({d} bytes)", .{sanitized.len});
        return true;
    } else {
        ctx.log("   [Sanitizer] Erro de validação: payload vazio ou corrompido.", .{});
        return false;
    }
}

fn agenteQuarentenaEvento(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    ev.status_final = "QUARENTENA";
    ev.motivo_quarentena = ctx.allocator.dupe(u8, "Payload rejeitado no estágio de sanitização") catch null;
    ctx.log(Theme.yellow ++ "   [Quarentena] Evento #{s} isolado para auditoria e revisão manual." ++ Theme.reset, .{ev.raw_id});
    return true;
}

fn agenteExtrairEntidades(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    const texto = ev.sanitized_text orelse ev.raw_payload;
    const ext = EntityExtractorTool.extract(ctx.allocator, texto) catch return false;

    ev.produto = ext.produto;
    ev.valor_monetario = ext.valor;
    ev.moeda = ext.moeda;

    ctx.log("   [Extrator] Produto: '{s}' | Valor: {d:.2} {s}", .{
        ev.produto orelse "Nenhum",
        ev.valor_monetario,
        ev.moeda,
    });
    return true;
}

fn agenteMascararPII(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    const texto = ev.sanitized_text orelse ev.raw_payload;
    const masked = PiiMaskerTool.maskPii(ctx.allocator, texto) catch return false;

    ev.email_mascarado = masked.email;
    ev.ip_mascarado = masked.ip;

    ctx.log("   [PII Masker] E-mail anonimizado: {s} | IP: {s}", .{
        ev.email_mascarado orelse "N/A",
        ev.ip_mascarado orelse "N/A",
    });
    return true;
}

fn agenteAnalisarSentimento(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    const texto = ev.sanitized_text orelse ev.raw_payload;
    const sent = SentimentAnalyzerTool.analyze(texto);

    ev.sentimento = sent.classificacao;
    ev.score_sentimento = sent.score;

    ctx.log("   [Sentimento] Polaridade: {s} (Score: {d:.2})", .{
        ev.sentimento.asString(),
        ev.score_sentimento,
    });
    return true;
}

fn agenteEnriquecerAnalitica(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    const enr = AnalyticsEnricherTool.enrich(ctx.allocator, ev) catch return false;

    ev.prioridade = enr.prioridade;
    ev.lead_score = enr.lead_score;
    ev.sla_minutos = enr.sla_minutos;
    ev.resumo_analitico = enr.resumo;

    ctx.log("   [Enriquecedor] Prioridade: {s} | Lead Score: {d} | SLA: {d}m", .{
        ev.prioridade.asString(),
        ev.lead_score,
        ev.sla_minutos,
    });
    return true;
}

fn agenteExportarDestino(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    ev.status_final = "PROCESSADO_COM_SUCESSO";
    ev.export_json = DataSinkWriterTool.serialize(ctx.allocator, ev) catch return false;

    ctx.log("   [DataSink] Informação Y exportada em JSON estruturado com sucesso.", .{});
    return true;
}

fn agenteRegistrarFalhaExportacao(ctx: *RuntimeCtx, ev: *DataPipelineEvent) bool {
    ev.status_final = "FALHA_EXPORTACAO";
    ctx.log(Theme.red ++ "   [Alerta] Notificação enviada aos engenheiros de dados para retentativa." ++ Theme.reset, .{});
    return true;
}

// ============================================================================
// MAIN - EXECUTA O PIPELINE COM DADO X E GERA INFORMAÇÃO Y
// ============================================================================
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rctx = RuntimeCtx{ .allocator = allocator };

    // 1. Carrega o arquivo externo de configuração 2flow via @embedFile
    const config_script = @embedFile("config.2flow");

    // 2. Compila a AST da DSL 2flow em 100% Comptime
    const ast = comptime parse2Flow(config_script);

    // 3. Inicializa Orquestrador e registra Agentes dinâmicos
    var orchestrator = PipelineOrchestrator.init(&rctx);
    defer orchestrator.deinit();

    try orchestrator.registrarAgente("SanitizarEntrada", agenteSanitizarEntrada);
    try orchestrator.registrarAgente("QuarentenaEvento", agenteQuarentenaEvento);
    try orchestrator.registrarAgente("ExtrairEntidades", agenteExtrairEntidades);
    try orchestrator.registrarAgente("MascararPII", agenteMascararPII);
    try orchestrator.registrarAgente("AnalisarSentimento", agenteAnalisarSentimento);
    try orchestrator.registrarAgente("EnriquecerAnalitica", agenteEnriquecerAnalitica);
    try orchestrator.registrarAgente("ExportarDestino", agenteExportarDestino);
    try orchestrator.registrarAgente("RegistrarFalhaExportacao", agenteRegistrarFalhaExportacao);

    // TUI Header
    std.debug.print("\n{s}╔════════════════════════════════════════════════════════════════════════════════════════════════════╗{s}\n", .{ Theme.cyan, Theme.reset });
    std.debug.print("{s}║   🌊 2FLOW ENGINE: MODERN DATA PIPELINE - DE DADO BRUTO (X) PARA INFORMAÇÃO ACIONÁVEL (Y)    ║{s}\n", .{ Theme.bold, Theme.reset });
    std.debug.print("{s}╚════════════════════════════════════════════════════════════════════════════════════════════════════╝{s}\n\n", .{ Theme.cyan, Theme.reset });

    // ------------------------------------------------------------------------
    // DEMONSTRAÇÃO DO DADO X (Entrada Bruta Desestruturada e Sensível)
    // ------------------------------------------------------------------------
    const dado_x_payload =
        "   PEDIDO CONFIRMADO!! Compra de Servidor Cloud 64GB no valor de 4500.00 EUR pelo cliente Carlos Silva (carlos.silva@techcorp.com), IP 192.168.1.55. Entrega urgente solicitada!   ";

    var evento = DataPipelineEvent.init(allocator, "EVT-89210-PROD", dado_x_payload, 1725293800);
    defer evento.deinit();

    std.debug.print("{s}📦 [DADO X DE ENTRADA - PAYLOAD BRUTO NÃO ESTRUTURADO]:{s}\n", .{ Theme.yellow ++ Theme.bold, Theme.reset });
    std.debug.print("{s}   ID:          {s}{s}\n", .{ Theme.dim, evento.raw_id, Theme.reset });
    std.debug.print("{s}   Timestamp:   {d}{s}\n", .{ Theme.dim, evento.timestamp, Theme.reset });
    std.debug.print("{s}   Conteúdo:    \"{s}\"{s}\n\n", .{ Theme.dim, evento.raw_payload, Theme.reset });

    std.debug.print("{s}🚀 Disparando Pipeline 2flow compilado em tempo de compilação...{s}\n\n", .{ Theme.bold, Theme.reset });

    // 4. Execução do fluxo de dados
    const ok = orchestrator.executar(ast, &evento);

    // ------------------------------------------------------------------------
    // DEMONSTRAÇÃO DA INFORMAÇÃO Y (Dado Estruturado, Enriquecido e Conforme LGPD)
    // ------------------------------------------------------------------------
    std.debug.print("\n{s}✨ [INFORMAÇÃO Y DE SAÍDA - SCHEMA ESTRUTURADO & ANALÍTICO]:{s}\n", .{ Theme.green ++ Theme.bold, Theme.reset });
    if (evento.export_json) |json| {
        std.debug.print("{s}{s}{s}\n\n", .{ Theme.green, json, Theme.reset });
    }

    // ------------------------------------------------------------------------
    // TABELA COMPARATIVA DE TRANSFORMAÇÃO: DADO X -> INFORMAÇÃO Y
    // ------------------------------------------------------------------------
    std.debug.print("{s}┌─────────────────────────┬─────────────────────────────────────────────────┬────────────────────────────────────────┐{s}\n", .{ Theme.cyan, Theme.reset });
    std.debug.print("{s}│ Propriedade             │ Dado X (Entrada Bruta)                          │ Informação Y (Enriquecido 2flow)       │{s}\n", .{ Theme.bold, Theme.reset });
    std.debug.print("{s}├─────────────────────────┼─────────────────────────────────────────────────┼────────────────────────────────────────┤{s}\n", .{ Theme.cyan, Theme.reset });
    std.debug.print("{s}│ Formato                 │ String com ruído e múltiplos espaços            │ JSON Estruturado Estritamente Tipado   │{s}\n", .{ Theme.cyan, Theme.reset });
    std.debug.print("{s}│ Privacidade (LGPD)      │ carlos.silva@techcorp.com (Exposto!)            │ {s}{s:<38}{s} │{s}\n", .{ Theme.cyan, Theme.yellow, evento.email_mascarado orelse "N/A", Theme.reset, Theme.cyan });
    std.debug.print("{s}│ Origem IP               │ 192.168.1.55 (Exposto!)                         │ {s}{s:<38}{s} │{s}\n", .{ Theme.cyan, Theme.yellow, evento.ip_mascarado orelse "N/A", Theme.reset, Theme.cyan });
    std.debug.print("{s}│ Entidade Produto        │ Texto livre mesclado na string                  │ {s}{s:<38}{s} │{s}\n", .{ Theme.cyan, Theme.green, evento.produto orelse "N/A", Theme.reset, Theme.cyan });
    std.debug.print("{s}│ Valor Financeiro        │ '4500.00 EUR' como caractere plano              │ {s}{d:.2} {s:<34}{s} │{s}\n", .{ Theme.cyan, Theme.green, evento.valor_monetario, evento.moeda, Theme.reset, Theme.cyan });
    std.debug.print("{s}│ Análise de Sentimento   │ Inexistente                                     │ {s}{s:<8} (Score: {d:.2}){s:<10} │{s}\n", .{ Theme.cyan, Theme.green, evento.sentimento.asString(), evento.score_sentimento, Theme.reset, Theme.cyan });
    std.debug.print("{s}│ Prioridade & SLA        │ Desconhecido                                    │ {s}{s:<7} ({d}m SLA, Score: {d}){s:<6} │{s}\n", .{ Theme.cyan, Theme.green, evento.prioridade.asString(), evento.sla_minutos, evento.lead_score, Theme.reset, Theme.cyan });
    std.debug.print("{s}│ Status Final            │ INICIADO                                        │ {s}🟢 {s:<35}{s} │{s}\n", .{ Theme.cyan, Theme.green, evento.status_final, Theme.reset, Theme.cyan });
    std.debug.print("{s}└─────────────────────────┴─────────────────────────────────────────────────┴────────────────────────────────────────┘{s}\n\n", .{ Theme.cyan, Theme.reset });

    if (ok) {
        std.debug.print("{s}🏁 Pipeline concluído com 100% de sucesso sem overhead de runtime!{s}\n\n", .{ Theme.bold, Theme.reset });
    }
}
