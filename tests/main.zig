const std = @import("std");

// ============================================================================
// 1. MODELOS DE DADOS E CONTEXTO DE TESTE DO 2FLOW
// ============================================================================
pub const TestEvent = struct {
    id: u64,
    payload: []const u8,
    valor: f64,
    status: []const u8,
    passos_executados: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64, valor: f64) TestEvent {
        return .{
            .id = id,
            .payload = "Payload de Teste Integrado 2flow",
            .valor = valor,
            .status = "INICIAL",
            .passos_executados = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestEvent) void {
        for (self.passos_executados.items) |p| {
            self.allocator.free(p);
        }
        self.passos_executados.deinit(self.allocator);
    }

    pub fn registarPasso(self: *TestEvent, nome: []const u8) !void {
        const duped = try self.allocator.dupe(u8, nome);
        try self.passos_executados.append(self.allocator, duped);
    }
};

pub const RuntimeCtx = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn log(self: *RuntimeCtx, comptime fmt: []const u8, args: anytype) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mutex.unlock();
        std.debug.print("  ⚡ [Test 2flow] " ++ fmt ++ "\n", args);
    }
};

pub const HandlerFn = *const fn (ctx: *RuntimeCtx, ev: *TestEvent) bool;

// ============================================================================
// 2. PARSER 2FLOW COMPTIME (ESTRUTURA AST REUTILIZADA)
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
                        @compileError("Esperado agente compensador após '!->'");
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
                @compileError("Token inesperado");
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
// 3. ORQUESTRADOR DE EXECUÇÃO DOS TESTES
// ============================================================================
pub const TestOrchestrator = struct {
    ctx: *RuntimeCtx,
    catalogo: std.StringHashMap(HandlerFn),
    forcar_falha_em: []const u8 = "",

    pub fn init(ctx: *RuntimeCtx) TestOrchestrator {
        return .{
            .ctx = ctx,
            .catalogo = std.StringHashMap(HandlerFn).init(ctx.allocator),
        };
    }

    pub fn deinit(self: *TestOrchestrator) void {
        self.catalogo.deinit();
    }

    pub fn registar(self: *TestOrchestrator, nome: []const u8, fn_ptr: HandlerFn) !void {
        try self.catalogo.put(nome, fn_ptr);
    }

    pub fn executar(self: *TestOrchestrator, comptime node: NoFlowAST, ev: *TestEvent) bool {
        switch (node.tipo) {
            .modulo => {
                const handler = self.catalogo.get(node.nome) orelse return false;

                // Simula falha controlada se solicitada para testar o operador !->
                const forcado = self.forcar_falha_em.len > 0 and std.mem.eql(u8, node.nome, self.forcar_falha_em);
                const sucesso = if (forcado) false else handler(self.ctx, ev);

                if (!sucesso) {
                    if (node.compensador_erro.len > 0) {
                        const comp = self.catalogo.get(node.compensador_erro) orelse return false;
                        ev.registarPasso(node.compensador_erro) catch {};
                        ev.status = "EM_ROLLBACK";
                        _ = comp(self.ctx, ev);
                    }
                    return false;
                }

                ev.registarPasso(node.nome) catch {};
                return true;
            },
            .sequencia => {
                inline for (node.filhos) |filho| {
                    if (!self.executar(filho, ev)) return false;
                }
                return true;
            },
            .paralelo => {
                var resultados: [node.filhos.len]bool = @splat(true);
                inline for (node.filhos, 0..) |filho, i| {
                    resultados[i] = self.executar(filho, ev);
                }
                inline for (node.filhos, 0..) |_, i| {
                    if (!resultados[i]) return false;
                }
                return true;
            },
        }
    }
};

// ============================================================================
// 4. HANDLERS MOCK DE TESTE
// ============================================================================
fn agenteOk(_: *RuntimeCtx, ev: *TestEvent) bool {
    ev.status = "OK";
    return true;
}

fn agenteFalha(_: *RuntimeCtx, ev: *TestEvent) bool {
    ev.status = "FALHOU";
    return false;
}

fn agenteRollback(_: *RuntimeCtx, ev: *TestEvent) bool {
    ev.status = "EM_ROLLBACK";
    return true;
}

// ============================================================================
// 5. SUÍTE DE TESTES AUTOMATIZADOS (VALIDAÇÃO DE CADA OPERADOR)
// ============================================================================
test "1. Operador Simples de Sequência (:--:)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var rctx = RuntimeCtx{ .allocator = gpa.allocator() };
    const script = "PassoUm :--: PassoDois :--: PassoTres";
    const ast = comptime parse2Flow(script);

    var orch = TestOrchestrator.init(&rctx);
    defer orch.deinit();
    try orch.registar("PassoUm", agenteOk);
    try orch.registar("PassoDois", agenteOk);
    try orch.registar("PassoTres", agenteOk);

    var ev = TestEvent.init(gpa.allocator(), 1, 100.0);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 3), ev.passos_executados.items.len);
    try std.testing.expectEqualStrings("PassoUm", ev.passos_executados.items[0]);
    try std.testing.expectEqualStrings("PassoDois", ev.passos_executados.items[1]);
    try std.testing.expectEqualStrings("PassoTres", ev.passos_executados.items[2]);
}

test "2. Operador de Canal de Erro / Saga (!->)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var rctx = RuntimeCtx{ .allocator = gpa.allocator() };
    const script = "Validar :--: OperacaoRiscada !-> EstornarLancamento :--: Finalizar";
    const ast = comptime parse2Flow(script);

    var orch = TestOrchestrator.init(&rctx);
    defer orch.deinit();
    try orch.registar("Validar", agenteOk);
    try orch.registar("OperacaoRiscada", agenteFalha);
    try orch.registar("EstornarLancamento", agenteRollback);
    try orch.registar("Finalizar", agenteOk);

    orch.forcar_falha_em = "OperacaoRiscada";

    var ev = TestEvent.init(gpa.allocator(), 2, 500.0);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);
    try std.testing.expect(!ok); // O fluxo principal falhou
    try std.testing.expectEqualStrings("EM_ROLLBACK", ev.status);
    try std.testing.expectEqualStrings("EstornarLancamento", ev.passos_executados.items[1]);
}

test "3. Operador Paralelo Fork-Join ([...])" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var rctx = RuntimeCtx{ .allocator = gpa.allocator() };
    const script = "Inicio :--: [RamoAlfa, RamoBeta, RamoGama] :--: Sincronizar";
    const ast = comptime parse2Flow(script);

    var orch = TestOrchestrator.init(&rctx);
    defer orch.deinit();
    try orch.registar("Inicio", agenteOk);
    try orch.registar("RamoAlfa", agenteOk);
    try orch.registar("RamoBeta", agenteOk);
    try orch.registar("RamoGama", agenteOk);
    try orch.registar("Sincronizar", agenteOk);

    var ev = TestEvent.init(gpa.allocator(), 3, 1000.0);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);
    try std.testing.expect(ok);
}

test "4. Fluxo Completo Mestre Usando Todos os Operadores Múltiplas Vezes com Erros Tratados" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var rctx = RuntimeCtx{ .allocator = gpa.allocator() };
    // Master Script utilizando Sequência (:--:), Saga (!->), Fork-Join ([...]) e caminhos de erro declarados mais de uma vez
    const master_script =
        \\ValidarToken
        \\  :--: [AuditoriaFiscal, VerificarInventario]
        \\  :--: CobrarCartao !-> EstornarCartao
        \\  :--: [AlocarBaiaWMS, EmitirFatura !-> AnularFatura]
        \\  :--: DespacharTransporte
    ;

    const ast = comptime parse2Flow(master_script);

    var orch = TestOrchestrator.init(&rctx);
    defer orch.deinit();
    try orch.registar("ValidarToken", agenteOk);
    try orch.registar("AuditoriaFiscal", agenteOk);
    try orch.registar("VerificarInventario", agenteOk);
    try orch.registar("CobrarCartao", agenteOk);
    try orch.registar("EstornarCartao", agenteRollback);
    try orch.registar("AlocarBaiaWMS", agenteOk);
    try orch.registar("EmitirFatura", agenteOk);
    try orch.registar("AnularFatura", agenteRollback);
    try orch.registar("DespacharTransporte", agenteOk);

    var ev = TestEvent.init(gpa.allocator(), 99, 7850.00);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("OK", ev.status);
    std.debug.print("  ✅ [Test Master] Fluxo complexo com múltiplos operadores executado com 100% de sucesso!\n", .{});
}
