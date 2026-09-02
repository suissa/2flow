const std = @import("std");
const tools = @import("tools.zig");
const runner = @import("main.zig");

const DataPipelineEvent = tools.DataPipelineEvent;
const TextSanitizerTool = tools.TextSanitizerTool;
const EntityExtractorTool = tools.EntityExtractorTool;
const PiiMaskerTool = tools.PiiMaskerTool;
const SentimentAnalyzerTool = tools.SentimentAnalyzerTool;
const AnalyticsEnricherTool = tools.AnalyticsEnricherTool;
const DataSinkWriterTool = tools.DataSinkWriterTool;

// ============================================================================
// 1. TESTES UNITÁRIOS DAS FERRAMENTAS REAIS (TOOLS)
// ============================================================================

test "Tool 1: TextSanitizerTool normaliza espaços e bloqueia injeções" {
    const allocator = std.testing.allocator;

    // Teste de normalização e trim
    const entrada_suja = "   Olá   mundo \t\t com \n\n espaços   duplicados   ";
    const limpo = (try TextSanitizerTool.sanitize(allocator, entrada_suja)).?;
    defer allocator.free(limpo);

    try std.testing.expectEqualStrings("Olá mundo com espaços duplicados", limpo);

    // Teste de segurança contra script injection
    const entrada_maliciosa = "Texto normal com <script>alert('xss')</script> malicioso";
    const res_seguranca = try TextSanitizerTool.sanitize(allocator, entrada_maliciosa);
    try std.testing.expect(res_seguranca == null);
}

test "Tool 2: EntityExtractorTool extrai produto, valor e moeda" {
    const allocator = std.testing.allocator;

    const texto = "Compra de Servidor Cloud 64GB no valor de 4500.00 EUR pelo cliente";
    const ext = try EntityExtractorTool.extract(allocator, texto);
    defer if (ext.produto) |p| allocator.free(p);

    try std.testing.expect(ext.produto != null);
    try std.testing.expectEqualStrings("Servidor Cloud 64GB", ext.produto.?);
    try std.testing.expectEqual(@as(f64, 4500.00), ext.valor);
    try std.testing.expectEqualStrings("EUR", ext.moeda);
}

test "Tool 3: PiiMaskerTool mascara e-mail e IPv4 conforme LGPD" {
    const allocator = std.testing.allocator;

    const texto = "cliente carlos.silva@techcorp.com acessou via IP 192.168.1.55 hoje";
    const pii = try PiiMaskerTool.maskPii(allocator, texto);
    defer if (pii.email) |e| allocator.free(e);
    defer if (pii.ip) |ip| allocator.free(ip);

    try std.testing.expect(pii.email != null);
    try std.testing.expectEqualStrings("c****a@techcorp.com", pii.email.?);

    try std.testing.expect(pii.ip != null);
    try std.testing.expectEqualStrings("192.168.*.*", pii.ip.?);
}

test "Tool 4: SentimentAnalyzerTool quantifica polaridade léxica" {
    const texto_positivo = "PEDIDO CONFIRMADO com SUCESSO e EXCELENTE atendimento!";
    const res_pos = SentimentAnalyzerTool.analyze(texto_positivo);
    try std.testing.expectEqual(tools.Sentiment.positivo, res_pos.classificacao);
    try std.testing.expect(res_pos.score > 0.5);

    const texto_negativo = "Houve ERRO na transacao, FALHA na cobranca e RECUSADO!";
    const res_neg = SentimentAnalyzerTool.analyze(texto_negativo);
    try std.testing.expectEqual(tools.Sentiment.negativo, res_neg.classificacao);
    try std.testing.expect(res_neg.score < -0.5);
}

test "Tool 5: AnalyticsEnricherTool calcula score, SLA e gera resumo executivo" {
    const allocator = std.testing.allocator;

    var ev = DataPipelineEvent.init(allocator, "EVT-TEST", "compra urgente", 1000);
    defer ev.deinit();

    ev.sanitized_text = try allocator.dupe(u8, "Compra urgente de equipamento");
    ev.produto = try allocator.dupe(u8, "Servidor Cloud 64GB");
    ev.valor_monetario = 4500.00;
    ev.moeda = "EUR";
    ev.email_mascarado = try allocator.dupe(u8, "c****a@techcorp.com");
    ev.sentimento = .positivo;

    const enr = try AnalyticsEnricherTool.enrich(allocator, &ev);
    defer allocator.free(enr.resumo);

    try std.testing.expectEqual(tools.Priority.critica, enr.prioridade);
    try std.testing.expectEqual(@as(u32, 100), enr.lead_score);
    try std.testing.expectEqual(@as(u32, 15), enr.sla_minutos);
    try std.testing.expect(std.mem.indexOf(u8, enr.resumo, "Servidor Cloud 64GB") != null);
}

test "Tool 6: DataSinkWriterTool serializa JSON analítico tipado" {
    const allocator = std.testing.allocator;

    var ev = DataPipelineEvent.init(allocator, "EVT-TEST-JSON", "payload", 1000);
    defer ev.deinit();

    ev.status_final = "PROCESSADO";
    ev.produto = try allocator.dupe(u8, "Laptop Pro");
    ev.valor_monetario = 1200.00;
    ev.moeda = "USD";
    ev.email_mascarado = try allocator.dupe(u8, "u****r@domain.com");
    ev.ip_mascarado = try allocator.dupe(u8, "10.0.*.*");
    ev.sentimento = .positivo;
    ev.score_sentimento = 0.8;
    ev.prioridade = .alta;
    ev.lead_score = 90;
    ev.sla_minutos = 30;
    ev.resumo_analitico = try allocator.dupe(u8, "Resumo de teste");

    const json = try DataSinkWriterTool.serialize(allocator, &ev);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"evento_id\": \"EVT-TEST-JSON\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cliente_lgpd\": \"u****r@domain.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"valor\": 1200.00") != null);
}

// ============================================================================
// 2. TESTES DE INTEGRAÇÃO DO PIPELINE COMPLETO 2FLOW
// ============================================================================

test "Pipeline 2flow: Fluxo Feliz (Dado X bruto vira Informação Y enriquecida)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rctx = runner.RuntimeCtx{ .allocator = allocator };

    // Carrega o config.2flow externo
    const config_script = @embedFile("config.2flow");
    const ast = comptime runner.parse2Flow(config_script);

    var orch = runner.PipelineOrchestrator.init(&rctx);
    defer orch.deinit();

    try orch.registrarAgente("SanitizarEntrada", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            const res = TextSanitizerTool.sanitize(ctx.allocator, ev.raw_payload) catch null;
            if (res) |s| {
                ev.sanitized_text = s;
                ev.is_valid = true;
                return true;
            }
            return false;
        }
    }.h);

    try orch.registrarAgente("QuarentenaEvento", struct {
        fn h(_: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            ev.status_final = "QUARENTENA";
            return true;
        }
    }.h);

    try orch.registrarAgente("ExtrairEntidades", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            const ext = EntityExtractorTool.extract(ctx.allocator, ev.sanitized_text.?) catch return false;
            ev.produto = ext.produto;
            ev.valor_monetario = ext.valor;
            ev.moeda = ext.moeda;
            return true;
        }
    }.h);

    try orch.registrarAgente("MascararPII", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            const masked = PiiMaskerTool.maskPii(ctx.allocator, ev.sanitized_text.?) catch return false;
            ev.email_mascarado = masked.email;
            ev.ip_mascarado = masked.ip;
            return true;
        }
    }.h);

    try orch.registrarAgente("AnalisarSentimento", struct {
        fn h(_: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            const sent = SentimentAnalyzerTool.analyze(ev.sanitized_text.?);
            ev.sentimento = sent.classificacao;
            ev.score_sentimento = sent.score;
            return true;
        }
    }.h);

    try orch.registrarAgente("EnriquecerAnalitica", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            const enr = AnalyticsEnricherTool.enrich(ctx.allocator, ev) catch return false;
            ev.prioridade = enr.prioridade;
            ev.lead_score = enr.lead_score;
            ev.sla_minutos = enr.sla_minutos;
            ev.resumo_analitico = enr.resumo;
            return true;
        }
    }.h);

    try orch.registrarAgente("ExportarDestino", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            ev.status_final = "PROCESSADO_COM_SUCESSO";
            ev.export_json = DataSinkWriterTool.serialize(ctx.allocator, ev) catch return false;
            return true;
        }
    }.h);

    try orch.registrarAgente("RegistrarFalhaExportacao", struct {
        fn h(_: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            ev.status_final = "FALHA_EXPORTACAO";
            return true;
        }
    }.h);

    // Dado X: bruto, com espaços e dados sensíveis
    const payload_x = "   PEDIDO CONFIRMADO!! Compra de Servidor Cloud 64GB no valor de 4500.00 EUR pelo cliente Carlos Silva (carlos.silva@techcorp.com), IP 192.168.1.55. Entrega urgente solicitada!   ";

    var ev = DataPipelineEvent.init(allocator, "EVT-TEST-E2E", payload_x, 1725293800);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);

    // Verificações da transformação
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("PROCESSADO_COM_SUCESSO", ev.status_final);
    try std.testing.expectEqualStrings("Servidor Cloud 64GB", ev.produto.?);
    try std.testing.expectEqual(@as(f64, 4500.00), ev.valor_monetario);
    try std.testing.expectEqualStrings("EUR", ev.moeda);
    try std.testing.expectEqualStrings("c****a@techcorp.com", ev.email_mascarado.?);
    try std.testing.expectEqualStrings("192.168.*.*", ev.ip_mascarado.?);
    try std.testing.expectEqual(tools.Sentiment.positivo, ev.sentimento);
    try std.testing.expectEqual(tools.Priority.critica, ev.prioridade);
    try std.testing.expectEqual(@as(u32, 100), ev.lead_score);
    try std.testing.expectEqual(@as(u32, 15), ev.sla_minutos);
    try std.testing.expect(ev.export_json != null);
}

test "Pipeline 2flow: Saga e Quarentena via !-> em caso de Dado X corrompido" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rctx = runner.RuntimeCtx{ .allocator = allocator };
    const config_script = @embedFile("config.2flow");
    const ast = comptime runner.parse2Flow(config_script);

    var orch = runner.PipelineOrchestrator.init(&rctx);
    defer orch.deinit();

    try orch.registrarAgente("SanitizarEntrada", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            const res = TextSanitizerTool.sanitize(ctx.allocator, ev.raw_payload) catch null;
            if (res) |s| {
                ev.sanitized_text = s;
                return true;
            }
            return false;
        }
    }.h);

    try orch.registrarAgente("QuarentenaEvento", struct {
        fn h(ctx: *runner.RuntimeCtx, ev: *DataPipelineEvent) bool {
            ev.status_final = "QUARENTENA";
            ev.motivo_quarentena = ctx.allocator.dupe(u8, "Injeção de script detectada no payload") catch null;
            return true;
        }
    }.h);

    try orch.registrarAgente("ExtrairEntidades", struct {
        fn h(_: *runner.RuntimeCtx, _: *DataPipelineEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("MascararPII", struct {
        fn h(_: *runner.RuntimeCtx, _: *DataPipelineEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("AnalisarSentimento", struct {
        fn h(_: *runner.RuntimeCtx, _: *DataPipelineEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("EnriquecerAnalitica", struct {
        fn h(_: *runner.RuntimeCtx, _: *DataPipelineEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("ExportarDestino", struct {
        fn h(_: *runner.RuntimeCtx, _: *DataPipelineEvent) bool {
            return true;
        }
    }.h);
    try orch.registrarAgente("RegistrarFalhaExportacao", struct {
        fn h(_: *runner.RuntimeCtx, _: *DataPipelineEvent) bool {
            return true;
        }
    }.h);

    // Dado X malicioso contendo <script>
    const payload_malicioso = "Ataque <script>alert(1)</script> injetado no webhook";

    var ev = DataPipelineEvent.init(allocator, "EVT-MALICIOSO", payload_malicioso, 1725293800);
    defer ev.deinit();

    const ok = orch.executar(ast, &ev);

    // Deve falhar o pipeline principal e ativar QuarentenaEvento via !->
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings("QUARENTENA", ev.status_final);
    try std.testing.expectEqualStrings("Injeção de script detectada no payload", ev.motivo_quarentena.?);

    // Garante que o restante do pipeline NÃO rodou
    try std.testing.expect(ev.produto == null);
    try std.testing.expect(ev.export_json == null);
}
