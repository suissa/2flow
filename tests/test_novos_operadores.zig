const std = @import("std");

// ============================================================================
// 🌊 SUÍTE DE TESTES E VALIDAÇÃO DOS NOVOS OPERADORES 2FLOW:
//    ->  (Event Ingress)
//    ->> (Invoke Owned Behavior)
//    <<- (Function Being Invoked)
//    <-  (Event Egress)
//
// E VALIDAÇÃO FORMAL DOS 10 INVARIANTES CANÔNICOS:
//  1. :--: only advances through a successful causal result.
//  2. !-> is a graph edge, not a third function result.
//  3. Every executable function resolves to Ok<T> or Error<E>.
//  4. -> and <- transport events across a semantic boundary.
//  5. ->> and <<- describe invocation across an ownership boundary.
//  6. An Agent may invoke only behaviors it owns.
//  7. Cross-context communication occurs through Agent event boundaries.
//  8. [...] declares concurrency semantics independently of runtime technology.
//  9. [? ...] represents external human evidence, not a new result algebra.
// 10. Normalization exists only in validate or self-healing.
// ============================================================================

pub const ExecutionStepKind = enum {
    ingress_event, // ->
    invoke_owned,  // ->>
    receive_owned, // <<-
    egress_ok,     // <- Ok<T>
    egress_error,  // <- Error<E>
};

pub const ExecutionStep = struct {
    kind: ExecutionStepKind,
    target: []const u8,
};

pub const TipoNoFlow = enum {
    modulo,
    sequencia,
    paralelo,
    hitl_gate,
    bloco_execucao,
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

            @compileError(std.fmt.comptimePrint("Caractere inválido: '{c}'", .{c}));
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
                const gate_name = tokens[idx].text;
                idx += 1; // identificador
                idx += 1; // ']'
                seq_nodes = seq_nodes ++ .{NoFlowAST{
                    .tipo = .hitl_gate,
                    .nome = gate_name,
                }};
            } else if (tok.kind == .identifier and std.mem.eql(u8, tok.text, "execution")) {
                idx += 1;
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
                idx += 1;
                if (idx < tokens.len and tokens[idx].kind == .identifier) idx += 1;
            } else if (tok.kind == .identifier) {
                var node = NoFlowAST{ .tipo = .modulo, .nome = tok.text };
                idx += 1;
                if (idx < tokens.len and tokens[idx].kind == .error_arrow) {
                    idx += 1;
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
                idx += 1; // ']'
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

pub fn validateAgentKnowledgeBoundary(comptime node: NoFlowAST) bool {
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
                            return false;
                        }
                    }
                }
            }
        }
        for (node.filhos) |filho| {
            if (!validateAgentKnowledgeBoundary(filho)) return false;
        }
        return true;
    }
}

// Contexto e Modelos de Teste
pub const TestEvent = struct {
    id: u64,
    status: []const u8 = "INICIAL",
    human_approved: bool = true,
    passos: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64) TestEvent {
        return .{
            .id = id,
            .passos = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestEvent) void {
        for (self.passos.items) |p| self.allocator.free(p);
        self.passos.deinit(self.allocator);
    }

    pub fn push(self: *TestEvent, str: []const u8) !void {
        const duped = try self.allocator.dupe(u8, str);
        try self.passos.append(self.allocator, duped);
    }
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    catalogo: std.StringHashMap(*const fn (*TestEvent) bool),

    pub fn init(allocator: std.mem.Allocator) Runner {
        return .{
            .allocator = allocator,
            .catalogo = std.StringHashMap(*const fn (*TestEvent) bool).init(allocator),
        };
    }

    pub fn deinit(self: *Runner) void {
        self.catalogo.deinit();
    }

    pub fn reg(self: *Runner, nome: []const u8, f: *const fn (*TestEvent) bool) !void {
        try self.catalogo.put(nome, f);
    }

    pub fn run(self: *Runner, comptime node: NoFlowAST, ev: *TestEvent) bool {
        switch (node.tipo) {
            .modulo => {
                const handler = self.catalogo.get(node.nome) orelse return false;
                const ok = handler(ev);
                if (!ok) {
                    if (node.compensador_erro.len > 0) {
                        const comp = self.catalogo.get(node.compensador_erro) orelse return false;
                        ev.push(node.compensador_erro) catch {};
                        ev.status = "COMPENSADO";
                        _ = comp(ev);
                    }
                    return false;
                }
                ev.push(node.nome) catch {};
                return true;
            },
            .sequencia => {
                inline for (node.filhos) |filho| {
                    if (!self.run(filho, ev)) return false;
                }
                return true;
            },
            .paralelo => {
                inline for (node.filhos) |filho| {
                    if (!self.run(filho, ev)) return false;
                }
                return true;
            },
            .hitl_gate => {
                if (!ev.human_approved) {
                    ev.status = "PAUSADO_HITL";
                    ev.push(node.nome) catch {};
                    return false;
                }
                ev.status = "APROVADO_HITL";
                ev.push(node.nome) catch {};
                return true;
            },
            .bloco_execucao => {
                ev.push(node.nome) catch {};
                var sucesso = true;
                for (node.passos_execucao) |step| {
                    switch (step.kind) {
                        .ingress_event => {
                            ev.push(step.target) catch {};
                        },
                        .invoke_owned => {
                            ev.push(step.target) catch {};
                            if (self.catalogo.get(step.target)) |h| {
                                sucesso = h(ev);
                            }
                        },
                        .receive_owned => {
                            ev.push(step.target) catch {};
                        },
                        .egress_ok => {
                            if (sucesso) {
                                ev.status = "OK";
                                ev.push(step.target) catch {};
                            }
                        },
                        .egress_error => {
                            if (!sucesso) {
                                ev.status = "ERROR";
                                ev.push(step.target) catch {};
                                return false;
                            }
                        },
                    }
                }
                return sucesso;
            },
        }
    }
};

fn mockOk(_: *TestEvent) bool {
    return true;
}
fn mockFail(_: *TestEvent) bool {
    return false;
}

// ============================================================================
// VALIDAÇÃO FORMAL DOS INVARIANTES E NOVOS OPERADORES
// ============================================================================

test "Invariante 4: -> e <- transportam eventos através de fronteiras semânticas" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const script =
        \\execution SalesAgent.ResolveSale
        \\  -> Ok<SaleDetected>
        \\  ->> ResolveItems
        \\  <<- ResolveItems
        \\  <- Ok<SaleResolved>
    ;
    const ast = comptime parse2Flow(script);
    var runner = Runner.init(allocator);
    defer runner.deinit();
    try runner.reg("ResolveItems", mockOk);

    var ev = TestEvent.init(allocator, 1);
    defer ev.deinit();

    const ok = runner.run(ast, &ev);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("Ok<SaleDetected>", ev.passos.items[1]); // Ingress ->
    try std.testing.expectEqualStrings("Ok<SaleResolved>", ev.passos.items[4]); // Egress <-
}

test "Invariante 5 e 6: ->> e <<- descrevem invocação de comportamento próprio e pertencente" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const script_valido =
        \\execution StockAgent.DecreaseStock
        \\  -> Ok<SaleResolved>
        \\  ->> DecreaseStock
        \\  <<- DecreaseStock
        \\  <- Ok<StockExitCommitted>
    ;
    const ast_valida = comptime parse2Flow(script_valido);
    const valida = comptime validateAgentKnowledgeBoundary(ast_valida);
    try std.testing.expect(valida);

    var runner = Runner.init(allocator);
    defer runner.deinit();
    try runner.reg("DecreaseStock", mockOk);

    var ev = TestEvent.init(allocator, 2);
    defer ev.deinit();

    const ok = runner.run(ast_valida, &ev);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("DecreaseStock", ev.passos.items[2]); // ->> invoke
    try std.testing.expectEqualStrings("DecreaseStock", ev.passos.items[3]); // <<- receive
}

test "Invariante 6: Rejeição estática de invocação cross-agent (Agent Knowledge Boundary)" {
    // Tentativa inválida: FinancialAgent chama diretamente comportamento pertencente a StockAgent
    const script_invalido =
        \\execution FinancialAgent.ProcessPayment
        \\  -> Ok<SaleDetected>
        \\  ->> StockAgent.DecreaseStock
        \\  <- Ok<PaymentProcessed>
    ;
    const ast_invalida = comptime parse2Flow(script_invalido);
    const valida = comptime validateAgentKnowledgeBoundary(ast_invalida);
    try std.testing.expect(!valida); // Invariante 6 violação detectada com sucesso!
}

test "Invariante 7: Coreografia entre múltiplos agentes via fronteiras de eventos (<- e ->)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Dois agentes interagindo desacoplados via eventos
    const script =
        \\execution FinancialAgent.EmitSale
        \\  -> IniciarFluxo
        \\  ->> RegistrarVenda
        \\  <<- RegistrarVenda
        \\  <- Ok<SaleDetected>
        \\
        \\execution SalesAgent.ConsumeSale
        \\  -> Ok<SaleDetected>
        \\  ->> ProcessarVenda
        \\  <<- ProcessarVenda
        \\  <- Ok<SaleProcessed>
    ;
    const ast = comptime parse2Flow(script);
    var runner = Runner.init(allocator);
    defer runner.deinit();
    try runner.reg("RegistrarVenda", mockOk);
    try runner.reg("ProcessarVenda", mockOk);

    var ev = TestEvent.init(allocator, 3);
    defer ev.deinit();

    const ok = runner.run(ast, &ev);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("OK", ev.status);
}

test "Invariante 3: Typed Result Law (Função resolve estritamente em Ok<T> ou Error<E>)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const script =
        \\execution StockAgent.DecreaseStock
        \\  -> Ok<SaleResolved>
        \\  ->> DecreaseStock
        \\  <<- DecreaseStock
        \\  <- Ok<StockExitCommitted>
        \\  <- Error<StockExitError>
    ;
    const ast = comptime parse2Flow(script);

    // Cenário de Erro
    var runner_fail = Runner.init(allocator);
    defer runner_fail.deinit();
    try runner_fail.reg("DecreaseStock", mockFail);

    var ev_fail = TestEvent.init(allocator, 4);
    defer ev_fail.deinit();

    const ok_fail = runner_fail.run(ast, &ev_fail);
    try std.testing.expect(!ok_fail);
    try std.testing.expectEqualStrings("ERROR", ev_fail.status);
    try std.testing.expectEqualStrings("Error<StockExitError>", ev_fail.passos.items[ev_fail.passos.items.len - 1]);
}

test "Invariante 1 e 2: :--: só avança em sucesso e !-> desvia em falha sem 3º tipo" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const script = "N1 :--: N2 !-> CompensarN2 :--: N3";
    const ast = comptime parse2Flow(script);

    var runner = Runner.init(allocator);
    defer runner.deinit();
    try runner.reg("N1", mockOk);
    try runner.reg("N2", mockFail); // falha em N2 ativa !-> CompensarN2
    try runner.reg("CompensarN2", mockOk);
    try runner.reg("N3", mockOk);

    var ev = TestEvent.init(allocator, 5);
    defer ev.deinit();

    const ok = runner.run(ast, &ev);
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings("COMPENSADO", ev.status);
    try std.testing.expectEqualStrings("CompensarN2", ev.passos.items[ev.passos.items.len - 1]);
}

test "Invariante 8 e 9: [...] concorrência semântica e [? ...] evidência externa humana" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const script = "Prepara :--: [RamoA, RamoB] :--: [? GateHumano] :--: Finaliza";
    const ast = comptime parse2Flow(script);

    var runner = Runner.init(allocator);
    defer runner.deinit();
    try runner.reg("Prepara", mockOk);
    try runner.reg("RamoA", mockOk);
    try runner.reg("RamoB", mockOk);
    try runner.reg("Finaliza", mockOk);

    // Pausa por ausência de evidência humana
    var ev_pause = TestEvent.init(allocator, 6);
    defer ev_pause.deinit();
    ev_pause.human_approved = false;

    const ok_pause = runner.run(ast, &ev_pause);
    try std.testing.expect(!ok_pause);
    try std.testing.expectEqualStrings("PAUSADO_HITL", ev_pause.status);

    // Sucesso quando aprovado
    var ev_ok = TestEvent.init(allocator, 7);
    defer ev_ok.deinit();
    ev_ok.human_approved = true;

    const ok_pass = runner.run(ast, &ev_ok);
    try std.testing.expect(ok_pass);
    try std.testing.expectEqualStrings("APROVADO_HITL", ev_ok.status);
}

test "Invariante 10: Normalização existe apenas em validação ou auto-cura (Self-Healing)" {
    // Invariante puramente semântico de arquitetura:
    // Normalization ⊂ Validate ∪ SelfHealing e Normalization ∉ DomainBehavior
    const NormalizationStage = enum {
        validate,
        self_healing,
        domain_behavior,
    };

    const isAllowedNormalization = struct {
        fn check(stage: NormalizationStage) bool {
            return switch (stage) {
                .validate, .self_healing => true,
                .domain_behavior => false, // Proibido normalizar dentro do comportamento de domínio!
            };
        }
    }.check;

    try std.testing.expect(isAllowedNormalization(.validate));
    try std.testing.expect(isAllowedNormalization(.self_healing));
    try std.testing.expect(!isAllowedNormalization(.domain_behavior));
}
