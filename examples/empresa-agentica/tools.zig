const std = @import("std");

// ============================================================================
// MODELO DE DADOS: CICLO OPERACIONAL DA MICRO-EMPRESA AGÊNTICA
// ============================================================================

pub const EmpresaEvent = struct {
    allocator: std.mem.Allocator,

    // ------------------------------------------------------------------------
    // DADO X: Entrada Bruta da Nota Fiscal de Compra do Fornecedor
    // ------------------------------------------------------------------------
    nfe_numero: u32,
    fornecedor_nome: []const u8,
    fornecedor_cnpj: []const u8,
    item_descricao: []const u8,
    quantidade_comprada: u32,
    valor_total_compra: f64,
    prazo_pagamento_dias: u32,

    // ------------------------------------------------------------------------
    // Estágio 1: Fornecedor
    // ------------------------------------------------------------------------
    fornecedor_homologado: bool = false,
    motivo_rejeicao: ?[]const u8 = null,

    // ------------------------------------------------------------------------
    // Estágio 2: Estoque
    // ------------------------------------------------------------------------
    sku: ?[]const u8 = null,
    saldo_estoque: u32 = 0,
    custo_unitario: f64 = 0.0,
    ponto_reposicao: u32 = 0,

    // ------------------------------------------------------------------------
    // Estágio 3: [Financeiro, Contábil] (Execução Concorrente via Fork-Join)
    // ------------------------------------------------------------------------
    // Financeiro
    contas_pagar_status: []const u8 = "NAO_AGENDADO",
    data_vencimento_str: ?[]const u8 = null,

    // Contábil
    credito_imposto_icms: f64 = 0.0,
    livro_diario_partida: ?[]const u8 = null,

    // ------------------------------------------------------------------------
    // Estágio 4: Marketing
    // ------------------------------------------------------------------------
    markup_percentual: f64 = 0.60, // 60% de markup sobre o custo
    preco_venda_unitario: f64 = 0.0,
    url_campanha: ?[]const u8 = null,
    copy_anuncio: ?[]const u8 = null,

    // ------------------------------------------------------------------------
    // Estágio 5: Vendas
    // ------------------------------------------------------------------------
    pedido_venda_id: ?[]const u8 = null,
    quantidade_vendida: u32 = 0,
    valor_total_venda: f64 = 0.0,
    cliente_nome: []const u8 = "",
    cliente_contato: []const u8 = "",
    reserva_confirmada: bool = false,

    // ------------------------------------------------------------------------
    // Estágio 6: Cliente / Despacho (INFORMAÇÃO Y)
    // ------------------------------------------------------------------------
    codigo_rastreio: ?[]const u8 = null,
    mensagem_notificacao: ?[]const u8 = null,
    lucro_bruto_venda: f64 = 0.0,
    margem_lucro_percent: f64 = 0.0,
    status_ciclo: []const u8 = "INICIADO",

    // Auditoria e Concorrência
    historico_passos: std.ArrayList([]const u8),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(
        allocator: std.mem.Allocator,
        nfe_numero: u32,
        fornecedor_nome: []const u8,
        fornecedor_cnpj: []const u8,
        item_descricao: []const u8,
        quantidade_comprada: u32,
        valor_total_compra: f64,
        prazo_pagamento_dias: u32,
    ) EmpresaEvent {
        return .{
            .allocator = allocator,
            .nfe_numero = nfe_numero,
            .fornecedor_nome = fornecedor_nome,
            .fornecedor_cnpj = fornecedor_cnpj,
            .item_descricao = item_descricao,
            .quantidade_comprada = quantidade_comprada,
            .valor_total_compra = valor_total_compra,
            .prazo_pagamento_dias = prazo_pagamento_dias,
            .historico_passos = .empty,
        };
    }

    pub fn deinit(self: *EmpresaEvent) void {
        if (self.sku) |s| self.allocator.free(s);
        if (self.data_vencimento_str) |d| self.allocator.free(d);
        if (self.livro_diario_partida) |l| self.allocator.free(l);
        if (self.url_campanha) |u| self.allocator.free(u);
        if (self.copy_anuncio) |c| self.allocator.free(c);
        if (self.pedido_venda_id) |p| self.allocator.free(p);
        if (self.codigo_rastreio) |r| self.allocator.free(r);
        if (self.mensagem_notificacao) |m| self.allocator.free(m);
        for (self.historico_passos.items) |p| {
            self.allocator.free(p);
        }
        self.historico_passos.deinit(self.allocator);
    }

    pub fn registrarPasso(self: *EmpresaEvent, passo: []const u8) !void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mutex.unlock();
        const dup = try self.allocator.dupe(u8, passo);
        try self.historico_passos.append(self.allocator, dup);
    }
};

// ============================================================================
// TOOL 1: FORNECEDOR TOOL (Validação de Fornecedor e NF-e de Entrada)
// ============================================================================
pub const FornecedorTool = struct {
    pub const ValidacaoResult = struct {
        homologado: bool,
        motivo: ?[]const u8 = null,
    };

    pub fn homologar(cnpj: []const u8, total: f64, qtd: u32) ValidacaoResult {
        // Validação cadastral básica de CNPJ (deve ter 18 caracteres no formato XX.XXX.XXX/XXXX-XX)
        if (cnpj.len != 18 or cnpj[2] != '.' or cnpj[6] != '.' or cnpj[10] != '/' or cnpj[15] != '-') {
            return .{ .homologado = false, .motivo = "CNPJ do fornecedor inválido ou em formato incorreto" };
        }

        // Validação de coerência do pedido de compra
        if (total <= 0.0 or qtd == 0) {
            return .{ .homologado = false, .motivo = "Valor total ou quantidade de itens zerada na NF-e" };
        }

        return .{ .homologado = true, .motivo = null };
    }
};

// ============================================================================
// TOOL 2: ESTOQUE TOOL (Gestão de Inventário, SKU e Custo Médio)
// ============================================================================
pub const EstoqueTool = struct {
    pub const EntradaResult = struct {
        sku: []const u8,
        custo_unitario: f64,
        saldo_novo: u32,
        ponto_reposicao: u32,
    };

    pub fn processarEntrada(allocator: std.mem.Allocator, item_nome: []const u8, total: f64, qtd: u32) !EntradaResult {
        const custo_unit = total / @as(f64, @floatFromInt(qtd));

        // Gera SKU amigável derivado das primeiras letras em maiúsculas
        var sku_buf: [32]u8 = undefined;
        var out_idx: usize = 0;
        var new_word = true;

        for (item_nome) |c| {
            if (c == ' ' or c == '-' or c == '_') {
                new_word = true;
                if (out_idx > 0 and sku_buf[out_idx - 1] != '-') {
                    sku_buf[out_idx] = '-';
                    out_idx += 1;
                }
            } else if (new_word and ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) {
                sku_buf[out_idx] = std.ascii.toUpper(c);
                out_idx += 1;
                if (out_idx >= 16) break;
            }
        }

        const sku_slice = if (out_idx > 0) sku_buf[0..out_idx] else "SKU-GERAL";
        const sku = try std.fmt.allocPrint(allocator, "{s}-LOTE1", .{sku_slice});

        // Ponto de reposição padrão: 20% do lote recebido
        const ponto_rep = @max(1, qtd / 5);

        return .{
            .sku = sku,
            .custo_unitario = custo_unit,
            .saldo_novo = qtd,
            .ponto_reposicao = ponto_rep,
        };
    }
};

// ============================================================================
// TOOL 3: FINANCEIRO TOOL (Contas a Pagar e Fluxo de Caixa)
// ============================================================================
pub const FinanceiroTool = struct {
    pub const PagamentoResult = struct {
        status: []const u8,
        data_vencimento: []const u8,
    };

    pub fn agendarPagamento(allocator: std.mem.Allocator, prazo_dias: u32) !PagamentoResult {
        // Gera identificador e data prevista simulada (D+30)
        const vencimento = try std.fmt.allocPrint(allocator, "D+{d} (Previsão: 30 dias corridos)", .{prazo_dias});
        return .{
            .status = "AGENDADO_D30",
            .data_vencimento = vencimento,
        };
    }
};

// ============================================================================
// TOOL 4: CONTÁBIL TOOL (Partidas Dobradas e Crédito de Imposto)
// ============================================================================
pub const ContabilTool = struct {
    pub const LancamentoResult = struct {
        credito_imposto: f64,
        partida_dobrada: []const u8,
    };

    pub fn registrarEntradaMercadoria(allocator: std.mem.Allocator, total: f64) !LancamentoResult {
        // Alíquota de ICMS/IVA padrão para apropriação de crédito tributário (18%)
        const aliquota_credito: f64 = 0.18;
        const credito = total * aliquota_credito;

        // Partida Dobrada Contábil clássica:
        // D: Estoque de Mercadorias (Ativo Circulante)
        // C: Fornecedores a Pagar (Passivo Circulante)
        const partida = try std.fmt.allocPrint(
            allocator,
            "D: Estoque Mercadorias (R$ {d:.2}) | C: Fornecedores a Pagar (R$ {d:.2}) [Crédito ICMS 18%: R$ {d:.2}]",
            .{ total, total, credito },
        );

        return .{
            .credito_imposto = credito,
            .partida_dobrada = partida,
        };
    }
};

// ============================================================================
// TOOL 5: MARKETING TOOL (Markup, Precificação e Campanha Digital)
// ============================================================================
pub const MarketingTool = struct {
    pub const CampanhaResult = struct {
        preco_venda: f64,
        url_campanha: []const u8,
        copy_anuncio: []const u8,
    };

    pub fn criarCampanha(
        allocator: std.mem.Allocator,
        sku: []const u8,
        item_nome: []const u8,
        custo_unit: f64,
        markup: f64,
    ) !CampanhaResult {
        const preco = custo_unit * (1.0 + markup);

        const url = try std.fmt.allocPrint(
            allocator,
            "https://loja.microempresa.com.br/produto/{s}?utm_source=2flow_agent&utm_campaign=lancamento",
            .{sku},
        );

        const copy = try std.fmt.allocPrint(
            allocator,
            "🔥 NOVIDADE NO ESTOQUE: {s} por apenas R$ {d:.2}! Pronta entrega com envio imediato.",
            .{ item_nome, preco },
        );

        return .{
            .preco_venda = preco,
            .url_campanha = url,
            .copy_anuncio = copy,
        };
    }
};

// ============================================================================
// TOOL 6: VENDAS TOOL (Processamento de Pedido, Baixa de Estoque e Reserva)
// ============================================================================
pub const VendasTool = struct {
    pub const PedidoResult = struct {
        pedido_id: []const u8,
        qtd_vendida: u32,
        valor_total: f64,
        novo_saldo_estoque: u32,
    };

    var pedido_seq: u32 = 88120;

    pub fn fecharVenda(
        allocator: std.mem.Allocator,
        saldo_disponivel: u32,
        qtd_desejada: u32,
        preco_unitario: f64,
    ) !?PedidoResult {
        if (saldo_disponivel < qtd_desejada or qtd_desejada == 0) {
            return null; // Falha de estoque para atender o pedido
        }

        pedido_seq += 1;
        const total_venda = @as(f64, @floatFromInt(qtd_desejada)) * preco_unitario;
        const pedido_id = try std.fmt.allocPrint(allocator, "PED-{d}", .{pedido_seq});
        const novo_saldo = saldo_disponivel - qtd_desejada;

        return .{
            .pedido_id = pedido_id,
            .qtd_vendida = qtd_desejada,
            .valor_total = total_venda,
            .novo_saldo_estoque = novo_saldo,
        };
    }
};

// ============================================================================
// TOOL 7: CLIENTE TOOL (Rastreamento, Notificação e Margem Líquida)
// ============================================================================
pub const ClienteTool = struct {
    pub const DespachoResult = struct {
        codigo_rastreio: []const u8,
        mensagem: []const u8,
        lucro_bruto: f64,
        margem_percent: f64,
    };

    var rastreio_seq: u32 = 918230;

    pub fn despacharENotificar(
        allocator: std.mem.Allocator,
        cliente_nome: []const u8,
        item_nome: []const u8,
        qtd_vendida: u32,
        receita_venda: f64,
        custo_unitario: f64,
    ) !DespachoResult {
        rastreio_seq += 1;
        const codigo_rastreio = try std.fmt.allocPrint(
            allocator,
            "BR-TRK-{d}",
            .{rastreio_seq},
        );

        const custo_mercadoria = @as(f64, @floatFromInt(qtd_vendida)) * custo_unitario;
        const lucro = receita_venda - custo_mercadoria;
        const margem = if (receita_venda > 0.0) (lucro / receita_venda) * 100.0 else 0.0;

        const mensagem = try std.fmt.allocPrint(
            allocator,
            "Olá {s}! Seu pedido de {d}x '{s}' foi faturado e despachado com sucesso! Rastreamento: {s}.",
            .{ cliente_nome, qtd_vendida, item_nome, codigo_rastreio },
        );

        return .{
            .codigo_rastreio = codigo_rastreio,
            .mensagem = mensagem,
            .lucro_bruto = lucro,
            .margem_percent = margem,
        };
    }
};
