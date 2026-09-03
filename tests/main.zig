const std = @import("std");

// ============================================================================
// 1. MODELOS DE DADOS E CONTEXTO DE TESTE DO 2FLOW
// ============================================================================
pub const TestEvent = struct {
    id: u64,
    payload: []const u8,
    valor: f64,
    status: []const u8,
    human_approved: bool = true,
    passos_executados: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64, valor: f64) TestEvent {
        return .{
            .id = id,
            .payload = "Payload de Teste Integrado 2flow",
            .valor = valor,
            .status = "INICIAL",
            .human_approved = true,
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
// 2. PARSER 2FLOW COMPTIME (TOPOLÓGICO + PROTOCOLO DE EXECUÇÃO)
// ============================================================================
pub const TipoNoFlow = enum {
    modulo,
    sequencia,
    paralelo,
    hitl_gate,
    bloco_execucao,
};

pub const ExecutionStepKind = enum {
    ingress_event, // -> Entrada de evento no escopo
    invoke_owned,  // ->> Invocação de função interna própria
    receive_owned, // <<- Recepção da chamada pela função
    egress_ok,     // <- Ok<T> Saída de sucesso
    egress_error,  // <- Error<E> Saída de erro
};

pub const ExecutionStep = struct {
    kind: ExecutionStepKind,
    target: []const u8,
};

pub const NoFlowAST = struct {
    tipo: TipoNoFlow,
    nome: []const u8 = "",
    filhos: []const NoFlowAST = &.{},
    compensador_erro: []const u8 = "",
    passos_execucao: []const ExecutionStep = &.{},
};

const TokenKind = enum {
    identifier,
    arrow,         // :--:
    error_arrow,   // !->
    open_bracket,  // [
    close_bracket, // ]
    open_hitl,     // [?
    comma,         // ,
    event_ingress, // ->
    event_egress,  // <-
    invoke_owned,  // ->>
    receive_owned, // <<-
};

const Token = struct { kind: TokenKind, text: []const u8 };

fn tokenize(comptime input: []const u8) []const Token {
    comptime {
        var tokens: []const Token = &.{};
        var i: usize = 0;
        while (i < input.len) {
            const c = input[i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '#') {
                if (c == '#') {
                    while (i < input.len and input[i] != '\n') : (i += 1) {}
                    continue;
                }
                i += 1;
                continue;
            }

            if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], ":--:")) {
                tokens = tokens ++ .{Token{ .kind = .arrow, .text = ":--:" }};
                i += 4;
                continue;
            }
            if (i + 3 <= input.len and std.mem.eql(u8, input[i .. i + 3], "!->")) {
                tokens = tokens ++ .{Token{ .kind = .error_arrow, .text = "!->" }};
                i += 3;
                continue;
            }
            if (i + 3 <= input.len and std.mem.eql(u8, input[i .. i + 3], "->>")) {
                tokens = tokens ++ .{Token{ .kind = .invoke_owned, .text = "->>" }};
                i += 3;
                continue;
            }
            if (i + 3 <= input.len and std.mem.eql(u8, input[i .. i + 3], "<<-")) {
                tokens = tokens ++ .{Token{ .kind = .receive_owned, .text = "<<-" }};
                i += 3;
                continue;
            }
            if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[?")) {
                tokens = tokens ++ .{Token{ .kind = .open_hitl, .text = "[?" }};
                i += 2;
                continue;
            }
            if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "->")) {
                tokens = tokens ++ .{Token{ .kind = .event_ingress, .text = "->" }};
                i += 2;
                continue;
            }
            if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<-")) {
                tokens = tokens ++ .{Token{ .kind = .event_egress, .text = "<-" }};
                i += 2;
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

            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '<' or c == '>') {
                const start = i;
                while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_' or input[i] == '.' or input[i] == '<' or input[i] == '>')) {
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

const ParseResult = struct { node: NoFlowAST, read_count: usize };

fn parseExpression(comptime tokens: []const Token, comptime start: usize) ParseResult {
    comptime {
        var idx = start;
        var seq_nodes: []const NoFlowAST = &.{};
        while (idx < tokens.len) {
            const tok = tokens[idx];
            if (tok.kind == .close_bracket or tok.kind == .comma) break;

            if (tok.kind == .open_hitl) {
                idx += 1;
                if (idx >= tokens.len or tokens[idx].kind != .identifier) {
                    @compileError("Erro 2flow: Esperado identificador de gate após '[?'");
                }
                const gate_name = tokens[idx].text;
                idx += 1;
                if (idx >= tokens.len or tokens[idx].kind != .close_bracket) {
                    @compileError("Erro 2flow: Esperado ']' para fechar o gate '[?'");
                }
                idx += 1;
                seq_nodes = seq_nodes ++ .{NoFlowAST{
                    .tipo = .hitl_gate,
                    .nome = gate_name,
                }};
            } else if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "execution")) {
                idx += 1;
                if (idx >= tokens.len or tokens[idx].kind != .identifier) {
                    @compileError("Erro 2flow: Esperado nome do escopo após 'execution'");
                }
                const scope_name = tokens[idx].text;
                idx += 1;

                var steps: []const ExecutionStep = &.{};
                while (idx < tokens.len) {
                    const step_tok = tokens[idx];
                    if (step_tok.kind == .event_ingress) {
                        idx += 1;
                        steps = steps ++ .{ExecutionStep{ .kind = .ingress_event, .target = tokens[idx].text }};
                        idx += 1;
                    } else if (step_tok.kind == .invoke_owned) {
                        idx += 1;
                        steps = steps ++ .{ExecutionStep{ .kind = .invoke_owned, .target = tokens[idx].text }};
                        idx += 1;
                    } else if (step_tok.kind == .receive_owned) {
                        idx += 1;
                        steps = steps ++ .{ExecutionStep{ .kind = .receive_owned, .target = tokens[idx].text }};
                        idx += 1;
                    } else if (step_tok.kind == .event_egress) {
                        idx += 1;
                        const target_str = tokens[idx].text;
                        idx += 1;
                        if (std.mem.startsWith(u8, target_str, "Error<")) {
                            steps = steps ++ .{ExecutionStep{ .kind = .egress_error, .target = target_str }};
                        } else {
                            steps = steps ++ .{ExecutionStep{ .kind = .egress_ok, .target = target_str }};
                        }
                    } else if (step_tok.kind == .arrow or step_tok.kind == .close_bracket) {
                        break;
                    } else if (step_tok.kind == .identifier and (std.mem.eql(u8, step_tok.text, "execution") or std.mem.eql(u8, step_tok.text, "flow"))) {
                        break;
                    } else {
                        idx += 1;
                    }
                }

                seq_nodes = seq_nodes ++ .{NoFlowAST{
                    .tipo = .bloco_execucao,
                    .nome = scope_name,
                    .passos_execucao = steps,
                }};
            } else if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "flow")) {
                // Pula palavra-chave 'flow' e seu nome declarativo
                idx += 1;
                if (idx < tokens.len and tokens[idx].kind == .identifier) {
                    idx += 1;
                }
            } else if (tok.kind == .identifier) {
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
                idx += 1;
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

/// Invariante Semântico: Agent Knowledge Boundary
/// Verifica se uma função invocada com `->>` ou `<<-` pertence estritamente ao mesmo Agente que possui o escopo
pub fn validateKnowledgeBoundary(comptime node: NoFlowAST) bool {
    comptime {
        if (node.tipo == .bloco_execucao) {
            var agent_prefix: []const u8 = node.nome;
            if (std.mem.indexOfScalar(u8, node.nome, '.')) |dot| {
                agent_prefix = node.nome[0..dot];
            }
            for (node.passos_execucao) |step| {
                if (step.kind == .invoke_owned or step.kind == .receive_owned) {
                    if (std.mem.indexOfScalar(u8, step.target, '.')) |target_dot| {
                        const target_agent = step.target[0..target_dot];
                        if (!std.mem.eql(u8, target_agent, agent_prefix)) {
                            return false; // Violação de fronteira! Agente chamando outro agente diretamente
                        }
                    }
                }
            }
        }
        for (node.filhos) |filho| {
            if (!validateKnowledgeBoundary(filho)) return false;
        }
        return true;
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
            .hitl_gate => {
                // Avaliação de evidência externa humana
                if (!ev.human_approved) {
                    ev.status = "PAUSADO_HITL";
                    ev.registarPasso(node.nome) catch {};
                    return false;
                }
                ev.status = "APROVADO_HITL";
                ev.registarPasso(node.nome) catch {};
                return true;
            },
            .bloco_execucao => {
                ev.registarPasso(node.nome) catch {};
                var sucesso_funcao = true;
                for (node.passos_execucao) |step| {
                    switch (step.kind) {
                        .ingress_event => {
                            ev.registarPasso(step.target) catch {};
                        },
                        .invoke_owned => {
                            const handler = self.catalogo.get(step.target) orelse return false;
                            ev.registarPasso(step.target) catch {};
                            sucesso_funcao = handler(self.ctx, ev);
                        },
                        .receive_owned => {
                            ev.registarPasso(step.target) catch {};
                        },
                        .egress_ok => {
                            if (sucesso_funcao) {
                                ev.status = "OK";
                                ev.registarPasso(step.target) catch {};
                            }
                        },
                        .egress_error => {
                            if (!sucesso_funcao) {
                                ev.status = "ERROR";
                                ev.registarPasso(step.target) catch {};
                                return false;
                            }
                        },
                    }
                }
                return sucesso_funcao;
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

test "4. Operador de Intervenção Humana / HITL Gate ([?...])" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var rctx = RuntimeCtx{ .allocator = gpa.allocator() };

    const script = "AvaliarLimiteCredito :--: [?AprovacaoDiretoria] :--: TransferirFundosSEPA";
    const ast = comptime parse2Flow(script);

    var orch = TestOrchestrator.init(&rctx);
    defer orch.deinit();
    try orch.registar("AvaliarLimiteCredito", agenteOk);
    try orch.registar("TransferirFundosSEPA", agenteOk);

    // Cenário A: Evidência humana ainda NÃO fornecida (Pausa o fluxo)
    {
        var ev_pausado = TestEvent.init(gpa.allocator(), 10, 50000.0);
        defer ev_pausado.deinit();
        ev_pausado.human_approved = false;

        const ok = orch.executar(ast, &ev_pausado);
        try std.testing.expect(!ok);
        try std.testing.expectEqualStrings("PAUSADO_HITL", ev_pausado.status);
        try std.testing.expectEqual(@as(usize, 2), ev_pausado.passos_executados.items.len);
        try std.testing.expectEqualStrings("AvaliarLimiteCredito", ev_pausado.passos_executados.items[0]);
        try std.testing.expectEqualStrings("AprovacaoDiretoria", ev_pausado.passos_executados.items[1]);
    }

    // Cenário B: Evidência humana fornecida com sucesso (Avança até a transferência)
    {
        var ev_aprovado = TestEvent.init(gpa.allocator(), 11, 50000.0);
        defer ev_aprovado.deinit();
        ev_aprovado.human_approved = true;

        const ok = orch.executar(ast, &ev_aprovado);
        try std.testing.expect(ok);
        try std.testing.expectEqualStrings("OK", ev_aprovado.status);
        try std.testing.expectEqual(@as(usize, 3), ev_aprovado.passos_executados.items.len);
        try std.testing.expectEqualStrings("TransferirFundosSEPA", ev_aprovado.passos_executados.items[2]);
    }
}

test "5. Protocolo de Execução 2flow (-> Ingress, ->> Invoke, <<- Receive, <- Egress)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var rctx = RuntimeCtx{ .allocator = gpa.allocator() };

    const script_exec =
        \\execution StockAgent.DecreaseStock
        \\  -> Ok<SaleResolved>
        \\  ->> DecreaseStock
        \\  <<- DecreaseStock
        \\  <- Ok<StockExitCommitted>
        \\  <- Error<StockExitError>
    ;

    const ast = comptime parse2Flow(script_exec);
    try std.testing.expect(ast.tipo == .bloco_execucao);
    try std.testing.expectEqualStrings("StockAgent.DecreaseStock", ast.nome);
    try std.testing.expectEqual(@as(usize, 5), ast.passos_execucao.len);
    try std.testing.expectEqual(ExecutionStepKind.ingress_event, ast.passos_execucao[0].kind);
    try std.testing.expectEqual(ExecutionStepKind.invoke_owned, ast.passos_execucao[1].kind);
    try std.testing.expectEqual(ExecutionStepKind.receive_owned, ast.passos_execucao[2].kind);
    try std.testing.expectEqual(ExecutionStepKind.egress_ok, ast.passos_execucao[3].kind);
    try std.testing.expectEqual(ExecutionStepKind.egress_error, ast.passos_execucao[4].kind);

    var orch = TestOrchestrator.init(&rctx);
    defer orch.deinit();
    try orch.registar("DecreaseStock", agenteOk);

    var ev = TestEvent.init(gpa.allocator(), 42, 250.0);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("OK", ev.status);
    try std.testing.expectEqual(@as(usize, 5), ev.passos_executados.items.len);
    try std.testing.expectEqualStrings("StockAgent.DecreaseStock", ev.passos_executados.items[0]);
    try std.testing.expectEqualStrings("Ok<SaleResolved>", ev.passos_executados.items[1]);
    try std.testing.expectEqualStrings("DecreaseStock", ev.passos_executados.items[2]);
    try std.testing.expectEqualStrings("DecreaseStock", ev.passos_executados.items[3]);
    try std.testing.expectEqualStrings("Ok<StockExitCommitted>", ev.passos_executados.items[4]);

    // Teste de canal Error<E> na execução
    var orch_fail = TestOrchestrator.init(&rctx);
    defer orch_fail.deinit();
    try orch_fail.registar("DecreaseStock", agenteFalha);

    var ev_fail = TestEvent.init(gpa.allocator(), 43, 250.0);
    defer ev_fail.deinit();

    const ok_fail = orch_fail.executar(ast, &ev_fail);
    try std.testing.expect(!ok_fail);
    try std.testing.expectEqualStrings("ERROR", ev_fail.status);
    try std.testing.expectEqualStrings("Error<StockExitError>", ev_fail.passos_executados.items[ev_fail.passos_executados.items.len - 1]);
}

test "6. Invariante de Fronteira do Agente (Agent Knowledge Boundary)" {
    // Caso Válido: StockAgent chama comportamento que pertence ao próprio StockAgent
    const script_valido =
        \\execution StockAgent.DecreaseStock
        \\  -> Ok<SaleResolved>
        \\  ->> DecreaseStock
        \\  <<- DecreaseStock
        \\  <- Ok<StockExitCommitted>
    ;
    const ast_valida = comptime parse2Flow(script_valido);
    const valida_ok = comptime validateKnowledgeBoundary(ast_valida);
    try std.testing.expect(valida_ok);

    // Caso Inválido: FinancialAgent tenta chamar diretamente uma função interna de StockAgent
    const script_invalido =
        \\execution FinancialAgent.AuditProcess
        \\  -> Ok<SaleDetected>
        \\  ->> StockAgent.DecreaseStock
        \\  <- Ok<AuditComplete>
    ;
    const ast_invalida = comptime parse2Flow(script_invalido);
    const valida_fail = comptime validateKnowledgeBoundary(ast_invalida);
    try std.testing.expect(!valida_fail); // Detectou violação de acoplamento indevido!
}

test "7. Fluxo Completo Mestre Usando Todos os Operadores Múltiplas Vezes com Erros Tratados" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var rctx = RuntimeCtx{ .allocator = gpa.allocator() };

    const master_script =
        \\ValidarToken
        \\  :--: [AuditoriaFiscal, VerificarInventario]
        \\  :--: CobrarCartao !-> EstornarCartao
        \\  :--: [?AprovacaoGerente]
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
    ev.human_approved = true;

    const ok = orch.executar(ast, &ev);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("OK", ev.status);
    std.debug.print("  ✅ [Test Master] Fluxo complexo com múltiplos operadores topológicos e de governança executado com 100% de sucesso!\n", .{});
}
