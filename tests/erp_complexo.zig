const std = @import("std");

// Importa o MOTOR REAL do 2flow (parser comptime + orquestrador multi-thread),
// sem recriar nenhuma cópia do parser. O módulo `flow` é mapeado para o
// main.zig da raiz via argumentos de módulo (ver Makefile: alvo `test-erp`):
//   zig test --dep flow -Mroot=tests/erp_complexo.zig -Mflow=main.zig
const flow = @import("flow");

const NoFlowAST = flow.NoFlowAST;
const ContextoRuntime = flow.ContextoRuntime;
const EventoTransacional = flow.EventoTransacional;
const TwoFlowOrchestrator = flow.TwoFlowOrchestrator;

// ============================================================================
// FLUXO DE ERP COMPLEXO (Order-to-Cash + Procure-to-Pay + Logística)
//
// Combina os 3 operadores implementados várias vezes:
//   :--:  sequência causal          (18x)
//   [...]  fork-join concorrente     (4x, incluindo 1 aninhado)
//   !->   compensador de saga        (5x, incl. 2 dentro de ramos paralelos)
// ============================================================================
const ERP_SCRIPT =
    \\ReceberPedidoCliente
    \\  :--: [VerificarCadastroCliente, AnaliseCreditoSerasa, ValidarDisponibilidadeSKU]
    \\  :--: ReservarEstoque !-> LiberarReservaEstoque
    \\  :--: CalcularImpostos
    \\  :--: [EmitirNotaFiscal !-> CancelarNotaFiscal, GerarBoletoPagamento !-> CancelarBoleto]
    \\  :--: ConfirmarPagamento !-> EstornarPagamento
    \\  :--: [SepararMercadoria, [ContratarFrete, AgendarColeta] :--: EmitirEtiquetaEnvio]
    \\  :--: DespacharTransportadora !-> AcionarLogisticaReversa
    \\  :--: BaixarEstoqueDefinitivo
    \\  :--: [AtualizarContasReceber, RegistrarComissaoVendedor, NotificarClienteRastreamento]
    \\  :--: FecharPedido
;

// Todos os agentes referenciados no script (principais + compensadores).
const AGENTES = [_][]const u8{
    "ReceberPedidoCliente",
    "VerificarCadastroCliente",
    "AnaliseCreditoSerasa",
    "ValidarDisponibilidadeSKU",
    "ReservarEstoque",
    "LiberarReservaEstoque",
    "CalcularImpostos",
    "EmitirNotaFiscal",
    "CancelarNotaFiscal",
    "GerarBoletoPagamento",
    "CancelarBoleto",
    "ConfirmarPagamento",
    "EstornarPagamento",
    "SepararMercadoria",
    "ContratarFrete",
    "AgendarColeta",
    "EmitirEtiquetaEnvio",
    "DespacharTransportadora",
    "AcionarLogisticaReversa",
    "BaixarEstoqueDefinitivo",
    "AtualizarContasReceber",
    "RegistrarComissaoVendedor",
    "NotificarClienteRastreamento",
    "FecharPedido",
};

// ============================================================================
// INSTRUMENTAÇÃO: rastreio thread-safe da ordem de execução dos agentes
// ============================================================================
const Trace = struct {
    // Allocator próprio e persistente (não é destruído entre testes, como
    // seria um DebugAllocator local), já que `passos` é estado global.
    const alloc = std.heap.page_allocator;

    var mutex: std.atomic.Mutex = .unlocked;
    var passos: std.ArrayListUnmanaged([]const u8) = .empty;
    var falhar_em: []const u8 = "";

    fn lock() void {
        while (!mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn reset(falha: []const u8) void {
        passos.clearRetainingCapacity();
        falhar_em = falha;
    }

    fn registrar(nome: []const u8) void {
        lock();
        defer mutex.unlock();
        passos.append(alloc, nome) catch @panic("OOM no trace");
    }

    fn executou(nome: []const u8) bool {
        lock();
        defer mutex.unlock();
        for (passos.items) |p| {
            if (std.mem.eql(u8, p, nome)) return true;
        }
        return false;
    }

    fn total() usize {
        lock();
        defer mutex.unlock();
        return passos.items.len;
    }

    fn indiceDe(nome: []const u8) ?usize {
        lock();
        defer mutex.unlock();
        for (passos.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, nome)) return i;
        }
        return null;
    }
};

/// Compila o script ERP para AST. Precisa elevar o limite de branches de
/// comptime: o tokenizer/parser padrão do 2flow estoura a cota default de
/// 1000 em fluxos com mais de ~10 nós (nenhum call-site do repo faz isso).
fn compilarErp() NoFlowAST {
    @setEvalBranchQuota(500_000);
    return flow.parse2Flow(ERP_SCRIPT);
}

/// Gera um handler nomeado. Falha deterministicamente se o nome bater com
/// `Trace.falhar_em`, permitindo validar sagas e barreiras de junção.
fn fazAgente(comptime nome: []const u8) flow.AgenteHandlerFn {
    return struct {
        fn handler(_: *ContextoRuntime, ev: *EventoTransacional) bool {
            if (Trace.falhar_em.len > 0 and std.mem.eql(u8, Trace.falhar_em, nome)) {
                Trace.registrar(nome ++ " (FALHOU)");
                return false;
            }
            Trace.registrar(nome);
            ev.status = "EM_PROGRESSO";
            return true;
        }
    }.handler;
}

fn montarOrquestrador(orch: *TwoFlowOrchestrator) !void {
    inline for (AGENTES) |nome| {
        try orch.registarAgente(nome, fazAgente(nome));
    }
}

// ============================================================================
// VISUALIZAÇÃO DA AST GERADA EM COMPTIME (prova que a topologia foi construída)
// ============================================================================
fn imprimirAst(comptime node: NoFlowAST, nivel: usize) void {
    var i: usize = 0;
    while (i < nivel) : (i += 1) std.debug.print("  ", .{});
    switch (node.tipo) {
        .modulo => {
            if (node.compensador_erro.len > 0) {
                std.debug.print("• {s}   !-> {s}\n", .{ node.nome, node.compensador_erro });
            } else {
                std.debug.print("• {s}\n", .{node.nome});
            }
        },
        .sequencia => {
            std.debug.print("SEQ  ({d} nós)\n", .{node.filhos.len});
            inline for (node.filhos) |f| imprimirAst(f, nivel + 1);
        },
        .paralelo => {
            std.debug.print("FORK ({d} ramos)\n", .{node.filhos.len});
            inline for (node.filhos) |f| imprimirAst(f, nivel + 1);
        },
    }
}

fn contarNos(comptime node: NoFlowAST) struct { modulos: usize, seq: usize, par: usize, comp: usize } {
    var m: usize = 0;
    var s: usize = 0;
    var p: usize = 0;
    var c: usize = 0;
    switch (node.tipo) {
        .modulo => {
            m += 1;
            if (node.compensador_erro.len > 0) c += 1;
        },
        .sequencia => {
            s += 1;
            inline for (node.filhos) |f| {
                const sub = contarNos(f);
                m += sub.modulos;
                s += sub.seq;
                p += sub.par;
                c += sub.comp;
            }
        },
        .paralelo => {
            p += 1;
            inline for (node.filhos) |f| {
                const sub = contarNos(f);
                m += sub.modulos;
                s += sub.seq;
                p += sub.par;
                c += sub.comp;
            }
        },
    }
    return .{ .modulos = m, .seq = s, .par = p, .comp = c };
}

// ============================================================================
// TESTES
// ============================================================================

test "ERP: AST compilada em comptime tem a topologia esperada" {
    const ast = comptime compilarErp();
    const stats = comptime contarNos(ast);

    std.debug.print("\n===== AST 2flow do fluxo ERP (gerada 100% em comptime) =====\n", .{});
    imprimirAst(ast, 0);
    std.debug.print("-----------------------------------------------------------\n", .{});
    std.debug.print("módulos={d}  sequências={d}  forks={d}  compensadores={d}\n\n", .{
        stats.modulos, stats.seq, stats.par, stats.comp,
    });

    try std.testing.expect(ast.tipo == .sequencia);
    // Compensadores (!->) NÃO viram nós: ficam num campo `compensador_erro` do
    // nó .modulo antecessor. Logo há 19 nós .modulo, 5 deles com compensador.
    try std.testing.expectEqual(@as(usize, 19), stats.modulos);
    try std.testing.expectEqual(@as(usize, 5), stats.comp);
    // 4 forks declarados + 1 fork aninhado dentro de um ramo = 5
    try std.testing.expectEqual(@as(usize, 5), stats.par);
    // sequência raiz + a sub-sequência do ramo aninhado = 2
    try std.testing.expectEqual(@as(usize, 2), stats.seq);
}

test "ERP: caminho feliz executa todos os 19 agentes e nenhum compensador" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    Trace.reset("");

    var ctx = ContextoRuntime.init(a);
    var orch = TwoFlowOrchestrator.init(&ctx);
    defer orch.deinit();
    try montarOrquestrador(&orch);

    const ast = comptime compilarErp();
    var ev = EventoTransacional{
        .id = 500100,
        .payload = "Pedido B2B: 40x Notebooks corporativos + 40x Docking Stations",
        .valor_eur = 62400.00,
        .status = "PENDENTE",
    };

    const ok = orch.executarFlow(ast, &ev);

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 19), Trace.total());
    try std.testing.expect(Trace.executou("ReceberPedidoCliente"));
    try std.testing.expect(Trace.executou("AnaliseCreditoSerasa"));
    try std.testing.expect(Trace.executou("EmitirNotaFiscal"));
    try std.testing.expect(Trace.executou("GerarBoletoPagamento"));
    try std.testing.expect(Trace.executou("ContratarFrete")); // ramo dentro de ramo
    try std.testing.expect(Trace.executou("AgendarColeta"));
    try std.testing.expect(Trace.executou("EmitirEtiquetaEnvio"));
    try std.testing.expect(Trace.executou("FecharPedido"));
    // nenhum compensador foi acionado
    try std.testing.expect(!Trace.executou("EstornarPagamento"));
    try std.testing.expect(!Trace.executou("LiberarReservaEstoque"));
    try std.testing.expect(!Trace.executou("AcionarLogisticaReversa"));
}

test "ERP: falha em ConfirmarPagamento dispara saga e aborta o downstream" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    Trace.reset("ConfirmarPagamento");

    var ctx = ContextoRuntime.init(a);
    var orch = TwoFlowOrchestrator.init(&ctx);
    defer orch.deinit();
    try montarOrquestrador(&orch);

    const ast = comptime compilarErp();
    var ev = EventoTransacional{
        .id = 500101,
        .payload = "Pedido com cartão recusado",
        .valor_eur = 9990.00,
        .status = "PENDENTE",
    };

    const ok = orch.executarFlow(ast, &ev);

    try std.testing.expect(!ok);
    try std.testing.expect(Trace.executou("ConfirmarPagamento (FALHOU)"));
    try std.testing.expect(Trace.executou("EstornarPagamento")); // compensador rodou
    // o compensador roda imediatamente após a falha do nó que ele protege
    try std.testing.expectEqual(
        Trace.indiceDe("ConfirmarPagamento (FALHOU)").? + 1,
        Trace.indiceDe("EstornarPagamento").?,
    );
    // etapas anteriores concluíram
    try std.testing.expect(Trace.executou("CalcularImpostos"));
    try std.testing.expect(Trace.executou("EmitirNotaFiscal"));
    // etapas posteriores NÃO devem ter rodado
    try std.testing.expect(!Trace.executou("SepararMercadoria"));
    try std.testing.expect(!Trace.executou("DespacharTransportadora"));
    try std.testing.expect(!Trace.executou("BaixarEstoqueDefinitivo"));
    try std.testing.expect(!Trace.executou("FecharPedido"));
}

test "ERP: falha num ramo do fork-join quebra a barreira de junção" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    Trace.reset("AnaliseCreditoSerasa");

    var ctx = ContextoRuntime.init(a);
    var orch = TwoFlowOrchestrator.init(&ctx);
    defer orch.deinit();
    try montarOrquestrador(&orch);

    const ast = comptime compilarErp();
    var ev = EventoTransacional{
        .id = 500102,
        .payload = "Cliente sem crédito aprovado",
        .valor_eur = 15000.00,
        .status = "PENDENTE",
    };

    const ok = orch.executarFlow(ast, &ev);

    try std.testing.expect(!ok);
    try std.testing.expect(Trace.executou("AnaliseCreditoSerasa (FALHOU)"));
    // barreira falhou -> nada depois do primeiro fork roda
    try std.testing.expect(!Trace.executou("ReservarEstoque"));
    try std.testing.expect(!Trace.executou("CalcularImpostos"));
    try std.testing.expect(!Trace.executou("LiberarReservaEstoque"));
    try std.testing.expect(!Trace.executou("FecharPedido"));
}

test "ERP: compensador declarado DENTRO de um ramo paralelo é acionado" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    Trace.reset("GerarBoletoPagamento");

    var ctx = ContextoRuntime.init(a);
    var orch = TwoFlowOrchestrator.init(&ctx);
    defer orch.deinit();
    try montarOrquestrador(&orch);

    const ast = comptime compilarErp();
    var ev = EventoTransacional{
        .id = 500103,
        .payload = "Falha na emissão do boleto bancário",
        .valor_eur = 4200.00,
        .status = "PENDENTE",
    };

    const ok = orch.executarFlow(ast, &ev);

    try std.testing.expect(!ok);
    try std.testing.expect(Trace.executou("GerarBoletoPagamento (FALHOU)"));
    try std.testing.expect(Trace.executou("CancelarBoleto")); // compensador no ramo
    // o outro ramo do mesmo fork (nota fiscal) rodou e NÃO foi compensado
    try std.testing.expect(Trace.executou("EmitirNotaFiscal"));
    try std.testing.expect(!Trace.executou("CancelarNotaFiscal"));
    // pipeline abortou após a barreira
    try std.testing.expect(!Trace.executou("ConfirmarPagamento"));
    try std.testing.expect(!Trace.executou("FecharPedido"));
}
