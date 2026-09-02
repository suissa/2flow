const std = @import("std");
const tools = @import("tools.zig");
const runner = @import("main.zig");

const EmpresaEvent = tools.EmpresaEvent;
const FornecedorTool = tools.FornecedorTool;
const EstoqueTool = tools.EstoqueTool;
const FinanceiroTool = tools.FinanceiroTool;
const ContabilTool = tools.ContabilTool;
const MarketingTool = tools.MarketingTool;
const VendasTool = tools.VendasTool;
const ClienteTool = tools.ClienteTool;

// ============================================================================
// 1. TESTES UNITÁRIOS DAS FERRAMENTAS EMPRESARIAIS
// ============================================================================

test "Tool 1: FornecedorTool valida CNPJ e consistência de valores" {
    // CNPJ Válido
    const res_valido = FornecedorTool.homologar("12.345.678/0001-90", 5000.00, 50);
    try std.testing.expect(res_valido.homologado);
    try std.testing.expect(res_valido.motivo == null);

    // CNPJ Inválido (formato quebrado)
    const res_invalido = FornecedorTool.homologar("12345678000190", 5000.00, 50);
    try std.testing.expect(!res_invalido.homologado);
    try std.testing.expect(res_invalido.motivo != null);
}

test "Tool 2: EstoqueTool gera SKU, calcula custo unitário e ponto de reposição" {
    const allocator = std.testing.allocator;

    const res = try EstoqueTool.processarEntrada(allocator, "Cadeira Gamer Ergonomica", 6000.00, 20);
    defer allocator.free(res.sku);

    try std.testing.expect(std.mem.indexOf(u8, res.sku, "CADEIRA-GAMER") != null);
    try std.testing.expectEqual(@as(f64, 300.00), res.custo_unitario);
    try std.testing.expectEqual(@as(u32, 20), res.saldo_novo);
    try std.testing.expectEqual(@as(u32, 4), res.ponto_reposicao);
}

test "Tool 3: FinanceiroTool agenda obrigação no Contas a Pagar" {
    const allocator = std.testing.allocator;

    const res = try FinanceiroTool.agendarPagamento(allocator, 30);
    defer allocator.free(res.data_vencimento);

    try std.testing.expectEqualStrings("AGENDADO_D30", res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.data_vencimento, "D+30") != null);
}

test "Tool 4: ContabilTool calcula crédito de imposto (18% ICMS) e partidas dobradas" {
    const allocator = std.testing.allocator;

    const res = try ContabilTool.registrarEntradaMercadoria(allocator, 10000.00);
    defer allocator.free(res.partida_dobrada);

    try std.testing.expectEqual(@as(f64, 1800.00), res.credito_imposto);
    try std.testing.expect(std.mem.indexOf(u8, res.partida_dobrada, "D: Estoque") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.partida_dobrada, "C: Fornecedores") != null);
}

test "Tool 5: MarketingTool calcula markup de 60% e gera URL com UTM" {
    const allocator = std.testing.allocator;

    const res = try MarketingTool.criarCampanha(allocator, "MOUSE-RGB", "Mouse Gamer 16000 DPI", 100.00, 0.60);
    defer allocator.free(res.url_campanha);
    defer allocator.free(res.copy_anuncio);

    try std.testing.expectEqual(@as(f64, 160.00), res.preco_venda);
    try std.testing.expect(std.mem.indexOf(u8, res.url_campanha, "utm_source=2flow_agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.copy_anuncio, "R$ 160.00") != null);
}

test "Tool 6: VendasTool processa fechamento e deduz estoque com segurança" {
    const allocator = std.testing.allocator;

    // Venda bem-sucedida
    const res_opt = try VendasTool.fecharVenda(allocator, 10, 3, 150.00);
    try std.testing.expect(res_opt != null);
    const res = res_opt.?;
    defer allocator.free(res.pedido_id);

    try std.testing.expectEqual(@as(u32, 3), res.qtd_vendida);
    try std.testing.expectEqual(@as(f64, 450.00), res.valor_total);
    try std.testing.expectEqual(@as(u32, 7), res.novo_saldo_estoque);

    // Tentativa de compra sem saldo suficiente
    const res_falha = try VendasTool.fecharVenda(allocator, 2, 5, 150.00);
    try std.testing.expect(res_falha == null);
}

test "Tool 7: ClienteTool gera rastreio e apura margem líquida" {
    const allocator = std.testing.allocator;

    // 2 unidades vendidas por R$ 320.00 (custo de R$ 100 cada = R$ 200 custo) -> lucro R$ 120 (37.5%)
    const res = try ClienteTool.despacharENotificar(allocator, "Mariana", "Teclado RGB", 2, 320.00, 100.00);
    defer allocator.free(res.codigo_rastreio);
    defer allocator.free(res.mensagem);

    try std.testing.expect(std.mem.indexOf(u8, res.codigo_rastreio, "BR-TRK-") != null);
    try std.testing.expectEqual(@as(f64, 120.00), res.lucro_bruto);
    try std.testing.expectEqual(@as(f64, 37.5), res.margem_percent);
}

// ============================================================================
// 2. TESTES DE INTEGRAÇÃO DO CICLO COMPLETO 2FLOW
// ============================================================================

test "Pipeline 2flow: Ciclo Empresarial Completo de Ponta a Ponta" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rctx = runner.RuntimeCtx{ .allocator = allocator };

    const script = @embedFile("config.2flow");
    const ast = comptime runner.parse2Flow(script);

    var orch = runner.EmpresaOrchestrator.init(&rctx);
    defer orch.deinit();

    try orch.registrarAgente("HomologarFornecedor", struct {
        fn h(_: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res = FornecedorTool.homologar(ev.fornecedor_cnpj, ev.valor_total_compra, ev.quantidade_comprada);
            ev.fornecedor_homologado = res.homologado;
            return res.homologado;
        }
    }.h);

    try orch.registrarAgente("RejeitarFornecedor", struct {
        fn h(_: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            ev.status_ciclo = "FORNECEDOR_REJEITADO";
            return true;
        }
    }.h);

    try orch.registrarAgente("DarEntradaEstoque", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res = EstoqueTool.processarEntrada(ctx.allocator, ev.item_descricao, ev.valor_total_compra, ev.quantidade_comprada) catch return false;
            ev.sku = res.sku;
            ev.custo_unitario = res.custo_unitario;
            ev.saldo_estoque = res.saldo_novo;
            ev.ponto_reposicao = res.ponto_reposicao;
            return true;
        }
    }.h);

    try orch.registrarAgente("EstornarEstoque", struct {
        fn h(_: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            ev.status_ciclo = "ESTOQUE_ESTORNADO";
            return true;
        }
    }.h);

    try orch.registrarAgente("LiquidarContasPagar", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res = FinanceiroTool.agendarPagamento(ctx.allocator, ev.prazo_pagamento_dias) catch return false;
            ev.contas_pagar_status = res.status;
            ev.data_vencimento_str = res.data_vencimento;
            return true;
        }
    }.h);

    try orch.registrarAgente("RegistrarLancamentoContabil", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res = ContabilTool.registrarEntradaMercadoria(ctx.allocator, ev.valor_total_compra) catch return false;
            ev.credito_imposto_icms = res.credito_imposto;
            ev.livro_diario_partida = res.partida_dobrada;
            return true;
        }
    }.h);

    try orch.registrarAgente("PublicarCampanhaMarketing", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res = MarketingTool.criarCampanha(ctx.allocator, ev.sku.?, ev.item_descricao, ev.custo_unitario, ev.markup_percentual) catch return false;
            ev.preco_venda_unitario = res.preco_venda;
            ev.url_campanha = res.url_campanha;
            ev.copy_anuncio = res.copy_anuncio;
            return true;
        }
    }.h);

    try orch.registrarAgente("ProcessarPedidoVenda", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res_opt = VendasTool.fecharVenda(ctx.allocator, ev.saldo_estoque, 2, ev.preco_venda_unitario) catch return false;
            if (res_opt) |res| {
                ev.pedido_venda_id = res.pedido_id;
                ev.quantidade_vendida = res.qtd_vendida;
                ev.valor_total_venda = res.valor_total;
                ev.saldo_estoque = res.novo_saldo_estoque;
                ev.reserva_confirmada = true;
                return true;
            }
            return false;
        }
    }.h);

    try orch.registrarAgente("CancelarReservaVenda", struct {
        fn h(_: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            ev.status_ciclo = "VENDA_CANCELADA";
            return true;
        }
    }.h);

    try orch.registrarAgente("NotificarDespachoCliente", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res = ClienteTool.despacharENotificar(ctx.allocator, ev.cliente_nome, ev.item_descricao, ev.quantidade_vendida, ev.valor_total_venda, ev.custo_unitario) catch return false;
            ev.codigo_rastreio = res.codigo_rastreio;
            ev.mensagem_notificacao = res.mensagem;
            ev.lucro_bruto_venda = res.lucro_bruto;
            ev.margem_lucro_percent = res.margem_percent;
            ev.status_ciclo = "PRODUTO_VENDIDO_E_CLIENTE_NOTIFICADO";
            return true;
        }
    }.h);

    var ev = EmpresaEvent.init(allocator, 44921, "TechParts Ltda", "12.345.678/0001-90", "Monitor Gamer 144Hz", 10, 10000.00, 30);
    defer ev.deinit();

    ev.cliente_nome = "Lucas Pereira";
    ev.cliente_contato = "lucas@email.com";

    const ok = orch.executar(ast, &ev);

    try std.testing.expect(ok);
    try std.testing.expect(ev.fornecedor_homologado);
    try std.testing.expectEqual(@as(f64, 1000.00), ev.custo_unitario);
    try std.testing.expectEqual(@as(u32, 8), ev.saldo_estoque); // comprou 10, vendeu 2 -> restam 8
    try std.testing.expectEqualStrings("AGENDADO_D30", ev.contas_pagar_status);
    try std.testing.expectEqual(@as(f64, 1800.00), ev.credito_imposto_icms);
    try std.testing.expectEqual(@as(f64, 1600.00), ev.preco_venda_unitario); // Markup 60% sobre R$ 1000 = R$ 1600
    try std.testing.expectEqual(@as(f64, 3200.00), ev.valor_total_venda); // 2 * R$ 1600 = R$ 3200
    try std.testing.expectEqual(@as(f64, 1200.00), ev.lucro_bruto_venda); // 3200 - 2000 = 1200
    try std.testing.expectEqual(@as(f64, 37.5), ev.margem_lucro_percent);
    try std.testing.expectEqualStrings("PRODUTO_VENDIDO_E_CLIENTE_NOTIFICADO", ev.status_ciclo);
}

test "Pipeline 2flow: Saga !-> RejeitarFornecedor ao identificar CNPJ inválido" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rctx = runner.RuntimeCtx{ .allocator = allocator };
    const script = @embedFile("config.2flow");
    const ast = comptime runner.parse2Flow(script);

    var orch = runner.EmpresaOrchestrator.init(&rctx);
    defer orch.deinit();

    try orch.registrarAgente("HomologarFornecedor", struct {
        fn h(_: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            const res = FornecedorTool.homologar(ev.fornecedor_cnpj, ev.valor_total_compra, ev.quantidade_comprada);
            return res.homologado;
        }
    }.h);

    try orch.registrarAgente("RejeitarFornecedor", struct {
        fn h(_: *runner.RuntimeCtx, ev: *EmpresaEvent) bool {
            ev.status_ciclo = "FORNECEDOR_RECUSADO_NA_PORTARIA";
            return true;
        }
    }.h);

    // Registra stubs para os demais agentes (que não devem ser executados)
    try orch.registrarAgente("DarEntradaEstoque", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("EstornarEstoque", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("LiquidarContasPagar", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("RegistrarLancamentoContabil", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("PublicarCampanhaMarketing", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("ProcessarPedidoVenda", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("CancelarReservaVenda", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("NotificarDespachoCliente", struct {
        fn h(_: *runner.RuntimeCtx, _: *EmpresaEvent) bool {
            return true;
        }
    }.h);

    // Evento com CNPJ fraudulento/inválido
    var ev = EmpresaEvent.init(allocator, 99999, "Fornecedor Fantasma", "CNPJ_INVALIDO", "Item Ilegal", 10, 1000.00, 30);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);

    // Deve falhar o pipeline principal e ativar o compensador de rejeição
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings("FORNECEDOR_RECUSADO_NA_PORTARIA", ev.status_ciclo);
    try std.testing.expectEqual(@as(u32, 0), ev.saldo_estoque); // Estoque não foi incrementado
}
