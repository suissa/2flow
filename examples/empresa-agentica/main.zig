const std = @import("std");
const tools = @import("tools.zig");

const EmpresaEvent = tools.EmpresaEvent;
const FornecedorTool = tools.FornecedorTool;
const EstoqueTool = tools.EstoqueTool;
const FinanceiroTool = tools.FinanceiroTool;
const ContabilTool = tools.ContabilTool;
const MarketingTool = tools.MarketingTool;
const VendasTool = tools.VendasTool;
const ClienteTool = tools.ClienteTool;

// ============================================================================
// TEMA E CORES ANSI PARA A TUI
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

    pub fn log(self: *RuntimeCtx, departamento: []const u8, comptime fmt: []const u8, args: anytype) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mutex.unlock();
        std.debug.print("  " ++ Theme.cyan ++ "🏢 [Empresa Agêntica | {s}]" ++ Theme.reset ++ " " ++ fmt ++ "\n", .{departamento} ++ args);
    }
};

pub const AgentHandler = *const fn (ctx: *RuntimeCtx, ev: *EmpresaEvent) bool;

// ============================================================================
// PARSER 2FLOW COMPTIME (LÊ config.2flow)
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
// MOTOR DE EXECUÇÃO MULTI-THREAD DO FLUXO EMPRESARIAL
// ============================================================================
pub const EmpresaOrchestrator = struct {
    ctx: *RuntimeCtx,
    catalogo: std.StringHashMap(AgentHandler),

    pub fn init(ctx: *RuntimeCtx) EmpresaOrchestrator {
        return .{
            .ctx = ctx,
            .catalogo = std.StringHashMap(AgentHandler).init(ctx.allocator),
        };
    }

    pub fn deinit(self: *EmpresaOrchestrator) void {
        self.catalogo.deinit();
    }

    pub fn registrarAgente(self: *EmpresaOrchestrator, nome: []const u8, handler: AgentHandler) !void {
        try self.catalogo.put(nome, handler);
    }

    pub fn executar(self: *EmpresaOrchestrator, comptime node: NoFlowAST, ev: *EmpresaEvent) bool {
        switch (node.tipo) {
            .modulo => {
                const handler = self.catalogo.get(node.nome) orelse {
                    self.ctx.log("Sistema", Theme.red ++ "❌ Agente '{s}' não cadastrado!" ++ Theme.reset, .{node.nome});
                    return false;
                };

                ev.registrarPasso(node.nome) catch {};
                const sucesso = handler(self.ctx, ev);

                if (!sucesso) {
                    self.ctx.log("Sistema", Theme.red ++ "🚨 Agente '{s}' falhou!" ++ Theme.reset, .{node.nome});
                    if (node.compensador_erro.len > 0) {
                        const comp = self.catalogo.get(node.compensador_erro) orelse {
                            self.ctx.log("Sistema", Theme.red ++ "🚨 Agente compensador '{s}' ausente!" ++ Theme.reset, .{node.compensador_erro});
                            return false;
                        };
                        self.ctx.log("Saga", Theme.yellow ++ "🛡️ [Saga Rollback] Disparando compensador: {s}" ++ Theme.reset, .{node.compensador_erro});
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
                self.ctx.log("Sincronia", Theme.purple ++ "🔀 [Fork-Join] Disparando {d} departamentos em paralelo..." ++ Theme.reset, .{node.filhos.len});

                var resultados: [node.filhos.len]bool = @splat(true);
                var threads: std.ArrayList(std.Thread) = .empty;
                defer threads.deinit(self.ctx.allocator);

                inline for (node.filhos, 0..) |filho, i| {
                    const Worker = struct {
                        fn run(orch: *EmpresaOrchestrator, event: *EmpresaEvent, res: *bool) void {
                            res.* = orch.executar(filho, event);
                        }
                    };
                    const t = std.Thread.spawn(.{}, Worker.run, .{ self, ev, &resultados[i] }) catch {
                        self.ctx.log("Sincronia", Theme.red ++ "🚨 Falha ao instanciar thread corporativa." ++ Theme.reset, .{});
                        return false;
                    };
                    threads.append(self.ctx.allocator, t) catch {};
                }

                for (threads.items) |th| {
                    th.join();
                }

                inline for (node.filhos, 0..) |_, i| {
                    if (!resultados[i]) {
                        self.ctx.log("Sincronia", Theme.red ++ "❌ Falha em um dos departamentos paralelos." ++ Theme.reset, .{});
                        return false;
                    }
                }

                self.ctx.log("Sincronia", Theme.green ++ "✅ Departamentos sincronizados com sucesso." ++ Theme.reset, .{});
                return true;
            },
        }
    }
};

// ============================================================================
// AGENTES DE DEPARTAMENTO QUE EXECUTAM AS FERRAMENTAS REAIS
// ============================================================================

fn agenteHomologarFornecedor(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    const res = FornecedorTool.homologar(ev.fornecedor_cnpj, ev.valor_total_compra, ev.quantidade_comprada);
    if (res.homologado) {
        ev.fornecedor_homologado = true;
        ctx.log("Compras", "Fornecedor '{s}' (CNPJ: {s}) homologado e NF-e #{d} validada.", .{
            ev.fornecedor_nome,
            ev.fornecedor_cnpj,
            ev.nfe_numero,
        });
        return true;
    } else {
        ev.motivo_rejeicao = res.motivo;
        ctx.log("Compras", Theme.red ++ "Fornecedor rejeitado: {s}" ++ Theme.reset, .{res.motivo orelse "Inconsistência cadastral"});
        return false;
    }
}

fn agenteRejeitarFornecedor(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    ev.status_ciclo = "REJEITADO_NO_RECEBIMENTO";
    ctx.log("Compras", Theme.yellow ++ "Recusa fiscal gerada para NF-e #{d}. Mercadoria devolvida à transportadora." ++ Theme.reset, .{ev.nfe_numero});
    return true;
}

fn agenteDarEntradaEstoque(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    const res = EstoqueTool.processarEntrada(ctx.allocator, ev.item_descricao, ev.valor_total_compra, ev.quantidade_comprada) catch return false;
    ev.sku = res.sku;
    ev.custo_unitario = res.custo_unitario;
    ev.saldo_estoque = res.saldo_novo;
    ev.ponto_reposicao = res.ponto_reposicao;

    ctx.log("Estoque", "Entrada física efetuada. SKU: '{s}' | Qtd: {d} un | Custo Unitário: R$ {d:.2} | Ponto Reposição: {d} un", .{
        ev.sku.?,
        ev.saldo_estoque,
        ev.custo_unitario,
        ev.ponto_reposicao,
    });
    return true;
}

fn agenteEstornarEstoque(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    ev.saldo_estoque = 0;
    ev.status_ciclo = "ESTORNO_DE_ESTOQUE";
    ctx.log("Estoque", Theme.yellow ++ "Lote estornado e saldo de inventário zerado." ++ Theme.reset, .{});
    return true;
}

fn agenteLiquidarContasPagar(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    const res = FinanceiroTool.agendarPagamento(ctx.allocator, ev.prazo_pagamento_dias) catch return false;
    ev.contas_pagar_status = res.status;
    ev.data_vencimento_str = res.data_vencimento;

    ctx.log("Financeiro", "Contas a Pagar agendado: R$ {d:.2} em {s}. Projeção no fluxo de caixa atualizada.", .{
        ev.valor_total_compra,
        ev.data_vencimento_str.?,
    });
    return true;
}

fn agenteRegistrarLancamentoContabil(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    const res = ContabilTool.registrarEntradaMercadoria(ctx.allocator, ev.valor_total_compra) catch return false;
    ev.credito_imposto_icms = res.credito_imposto;
    ev.livro_diario_partida = res.partida_dobrada;

    ctx.log("Contabilidade", "Livro Diário atualizado: {s}", .{ev.livro_diario_partida.?});
    return true;
}

fn agentePublicarCampanhaMarketing(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    const sku = ev.sku orelse "SKU-GERAL";
    const res = MarketingTool.criarCampanha(ctx.allocator, sku, ev.item_descricao, ev.custo_unitario, ev.markup_percentual) catch return false;

    ev.preco_venda_unitario = res.preco_venda;
    ev.url_campanha = res.url_campanha;
    ev.copy_anuncio = res.copy_anuncio;

    ctx.log("Marketing", "Campanha lançada! Preço Sugerido (Markup {d:.0}%): R$ {d:.2} | URL: {s}", .{
        ev.markup_percentual * 100.0,
        ev.preco_venda_unitario,
        ev.url_campanha.?,
    });
    return true;
}

fn agenteProcessarPedidoVenda(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    // Simula a conversão de um cliente comprando 2 unidades do produto recém-chegado
    const qtd_compra_cliente: u32 = 2;
    const res_opt = VendasTool.fecharVenda(ctx.allocator, ev.saldo_estoque, qtd_compra_cliente, ev.preco_venda_unitario) catch return false;

    if (res_opt) |res| {
        ev.pedido_venda_id = res.pedido_id;
        ev.quantidade_vendida = res.qtd_vendida;
        ev.valor_total_venda = res.valor_total;
        ev.saldo_estoque = res.novo_saldo_estoque;
        ev.reserva_confirmada = true;

        ctx.log("Vendas", "🎉 Venda confirmada! Pedido: #{s} | Cliente: {s} | Qtd: {d} un | Total: R$ {d:.2} (Estoque Restante: {d} un)", .{
            ev.pedido_venda_id.?,
            ev.cliente_nome,
            ev.quantidade_vendida,
            ev.valor_total_venda,
            ev.saldo_estoque,
        });
        return true;
    } else {
        ctx.log("Vendas", Theme.red ++ "Estoque insuficiente para faturar a venda!" ++ Theme.reset, .{});
        return false;
    }
}

fn agenteCancelarReservaVenda(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    ev.reserva_confirmada = false;
    ev.status_ciclo = "VENDA_CANCELADA";
    ctx.log("Vendas", Theme.yellow ++ "Reserva de venda cancelada e unidades recompostas ao estoque." ++ Theme.reset, .{});
    return true;
}

fn agenteNotificarDespachoCliente(ctx: *RuntimeCtx, ev: *EmpresaEvent) bool {
    const res = ClienteTool.despacharENotificar(
        ctx.allocator,
        ev.cliente_nome,
        ev.item_descricao,
        ev.quantidade_vendida,
        ev.valor_total_venda,
        ev.custo_unitario,
    ) catch return false;

    ev.codigo_rastreio = res.codigo_rastreio;
    ev.mensagem_notificacao = res.mensagem;
    ev.lucro_bruto_venda = res.lucro_bruto;
    ev.margem_lucro_percent = res.margem_percent;
    ev.status_ciclo = "PRODUTO_VENDIDO_E_CLIENTE_NOTIFICADO";

    ctx.log("Logística/Cliente", "📦 Despacho gerado! Rastreamento: {s} | Mensagem enviada para '{s}'", .{
        ev.codigo_rastreio.?,
        ev.cliente_contato,
    });
    ctx.log("Controladoria", "💰 Rentabilidade apurada: Lucro Bruto R$ {d:.2} (Margem Líquida da Venda: {d:.1}%)", .{
        ev.lucro_bruto_venda,
        ev.margem_lucro_percent,
    });
    return true;
}

// ============================================================================
// MAIN - EXECUÇÃO DO CICLO EMPRESARIAL COMPLETO
// ============================================================================
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rctx = RuntimeCtx{ .allocator = allocator };

    // 1. Carrega e compila em Comptime a topologia do pipeline de micro-empresa
    const script_2flow = @embedFile("config.2flow");
    const ast = comptime parse2Flow(script_2flow);

    // 2. Registra os Agentes no Orquestrador
    var orch = EmpresaOrchestrator.init(&rctx);
    defer orch.deinit();

    try orch.registrarAgente("HomologarFornecedor", agenteHomologarFornecedor);
    try orch.registrarAgente("RejeitarFornecedor", agenteRejeitarFornecedor);
    try orch.registrarAgente("DarEntradaEstoque", agenteDarEntradaEstoque);
    try orch.registrarAgente("EstornarEstoque", agenteEstornarEstoque);
    try orch.registrarAgente("LiquidarContasPagar", agenteLiquidarContasPagar);
    try orch.registrarAgente("RegistrarLancamentoContabil", agenteRegistrarLancamentoContabil);
    try orch.registrarAgente("PublicarCampanhaMarketing", agentePublicarCampanhaMarketing);
    try orch.registrarAgente("ProcessarPedidoVenda", agenteProcessarPedidoVenda);
    try orch.registrarAgente("CancelarReservaVenda", agenteCancelarReservaVenda);
    try orch.registrarAgente("NotificarDespachoCliente", agenteNotificarDespachoCliente);

    // Banner da Empresa Agêntica
    std.debug.print("\n{s}╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗{s}\n", .{ Theme.cyan, Theme.reset });
    std.debug.print("{s}║   🏢 2FLOW ENGINE: MICRO-EMPRESA AGÊNTICA TOTALMENTE INTEGRADA (FORNECEDOR ➡️ CLIENTE FINAL)         ║{s}\n", .{ Theme.bold, Theme.reset });
    std.debug.print("{s}╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝{s}\n\n", .{ Theme.cyan, Theme.reset });

    // ------------------------------------------------------------------------
    // DADO X: Entrada da Nota Fiscal Bruta do Fornecedor
    // ------------------------------------------------------------------------
    var evento = EmpresaEvent.init(
        allocator,
        44921,
        "TechParts Distribuicao Ltda",
        "12.345.678/0001-90",
        "Teclado Mecanico RGB Pro",
        50,
        5000.00,
        30,
    );
    defer evento.deinit();

    evento.cliente_nome = "Mariana Souza";
    evento.cliente_contato = "mariana.souza@cliente.com.br";

    std.debug.print("{s}📦 [DADO X DE ENTRADA - NOTA FISCAL BRUTA DE COMPRA]:{s}\n", .{ Theme.yellow ++ Theme.bold, Theme.reset });
    std.debug.print("{s}   • NF-e Número:        #{d}\n", .{ Theme.dim, evento.nfe_numero });
    std.debug.print("{s}   • Fornecedor:         {s} (CNPJ: {s})\n", .{ Theme.dim, evento.fornecedor_nome, evento.fornecedor_cnpj });
    std.debug.print("{s}   • Item Comprado:      {s} ({d} unidades)\n", .{ Theme.dim, evento.item_descricao, evento.quantidade_comprada });
    std.debug.print("{s}   • Valor Total NF:     R$ {d:.2} (Condição: {d} dias)\n\n{s}", .{ Theme.dim, evento.valor_total_compra, evento.prazo_pagamento_dias, Theme.reset });

    std.debug.print("{s}🚀 Disparando Fluxo Agêntico 2flow através dos Departamentos da Empresa...{s}\n\n", .{ Theme.bold, Theme.reset });

    // 3. Execução do pipeline 2flow
    const ok = orch.executar(ast, &evento);

    // ------------------------------------------------------------------------
    // INFORMAÇÃO Y: Ciclo Completo Concluído com Sucesso
    // ------------------------------------------------------------------------
    std.debug.print("\n{s}✨ [INFORMAÇÃO Y DE SAÍDA - BALANÇO E EXECUÇÃO OPERACIONAL CONSOLIDADA]:{s}\n", .{ Theme.green ++ Theme.bold, Theme.reset });
    std.debug.print(
        \\{{
        \\  "status_ciclo": "{s}",
        \\  "produto_sku": "{s}",
        \\  "custo_unitario_aquisicao": {d:.2},
        \\  "preco_venda_praticado": {d:.2},
        \\  "contas_a_pagar": "{s}",
        \\  "credito_tributario_icms": {d:.2},
        \\  "venda_faturada": {{
        \\    "pedido_id": "{s}",
        \\    "cliente": "{s}",
        \\    "unidades": {d},
        \\    "receita_bruta": {d:.2},
        \\    "lucro_bruto": {d:.2},
        \\    "margem_liquida": "{d:.1}%"
        \\  }},
        \\  "logistica_entrega": {{
        \\    "codigo_rastreio": "{s}",
        \\    "canal_notificado": "{s}"
        \\  }}
        \\}}
        \\
    , .{
        evento.status_ciclo,
        evento.sku orelse "N/A",
        evento.custo_unitario,
        evento.preco_venda_unitario,
        evento.contas_pagar_status,
        evento.credito_imposto_icms,
        evento.pedido_venda_id orelse "N/A",
        evento.cliente_nome,
        evento.quantidade_vendida,
        evento.valor_total_venda,
        evento.lucro_bruto_venda,
        evento.margem_lucro_percent,
        evento.codigo_rastreio orelse "N/A",
        evento.cliente_contato,
    });

    // Tabela Comparativa de Transformação
    std.debug.print("\n{s}┌─────────────────────────┬───────────────────────────────────────────────────┬──────────────────────────────────────────┐{s}\n", .{ Theme.cyan, Theme.reset });
    std.debug.print("{s}│ Departamento / Etapa    │ Dado X (Origem da Compra)                         │ Informação Y (Ciclo Empresarial 2flow)   │{s}\n", .{ Theme.bold, Theme.reset });
    std.debug.print("{s}├─────────────────────────┼───────────────────────────────────────────────────┼──────────────────────────────────────────┤{s}\n", .{ Theme.cyan, Theme.reset });
    std.debug.print("{s}│ 1. Fornecedor           │ TechParts (CNPJ não validado)                     │ {s}Homologado e Habilitado fiscalmente   │{s}\n", .{ Theme.cyan, Theme.green, Theme.cyan });
    std.debug.print("{s}│ 2. Estoque              │ 50 un em trânsito sem SKU                         │ {s}SKU '{s:<14}' (Saldo: {d} un)       │{s}\n", .{ Theme.cyan, Theme.green, evento.sku orelse "N/A", evento.saldo_estoque, Theme.cyan });
    std.debug.print("{s}│ 3. Financeiro           │ Fatura aberta sem agendamento                     │ {s}Agendado D+30 no Contas a Pagar       │{s}\n", .{ Theme.cyan, Theme.green, Theme.cyan });
    std.debug.print("{s}│ 4. Contabilidade        │ Sem apropriação fiscal                            │ {s}R$ {d:.2} Crédito ICMS apropriado    │{s}\n", .{ Theme.cyan, Theme.green, evento.credito_imposto_icms, Theme.cyan });
    std.debug.print("{s}│ 5. Marketing            │ Custo bruto R$ {d:.2} sem precificação             │ {s}Markup 60% -> Venda a R$ {d:.2}      │{s}\n", .{ Theme.cyan, evento.custo_unitario, Theme.green, evento.preco_venda_unitario, Theme.cyan });
    std.debug.print("{s}│ 6. Vendas & Comercial   │ Nenhuma venda registrada                          │ {s}Pedido #{s} (Faturado: R$ {d:.2})     │{s}\n", .{ Theme.cyan, Theme.green, evento.pedido_venda_id orelse "N/A", evento.valor_total_venda, Theme.cyan });
    std.debug.print("{s}│ 7. Logística / Cliente  │ Nenhum cliente atendido                           │ {s}Rastreio {s} enviado a Mariana │{s}\n", .{ Theme.cyan, Theme.green, evento.codigo_rastreio orelse "N/A", Theme.cyan });
    std.debug.print("{s}│ 8. Resultado Financeiro │ R$ 5.000,00 Comprometidos                         │ {s}Lucro R$ {d:.2} (Margem: {d:.1}%)       │{s}\n", .{ Theme.cyan, Theme.green, evento.lucro_bruto_venda, evento.margem_lucro_percent, Theme.cyan });
    std.debug.print("{s}└─────────────────────────┴───────────────────────────────────────────────────┴──────────────────────────────────────────┘{s}\n\n", .{ Theme.cyan, Theme.reset });

    if (ok) {
        std.debug.print("{s}🏁 Ciclo da Micro-Empresa concluído com êxito! Do fornecedor à entrega ao cliente final.{s}\n\n", .{ Theme.bold, Theme.reset });
    }
}
