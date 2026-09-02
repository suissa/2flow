const std = @import("std");

// ============================================================================
// ENUMS E ESTRUTURAS DE DADOS DO PIPELINE
// ============================================================================

pub const Sentiment = enum {
    negativo,
    neutro,
    positivo,

    pub fn asString(self: Sentiment) []const u8 {
        return switch (self) {
            .negativo => "NEGATIVO",
            .neutro => "NEUTRO",
            .positivo => "POSITIVO",
        };
    }
};

pub const Priority = enum {
    baixa,
    media,
    alta,
    critica,

    pub fn asString(self: Priority) []const u8 {
        return switch (self) {
            .baixa => "BAIXA",
            .media => "MEDIA",
            .alta => "ALTA",
            .critica => "CRITICA",
        };
    }
};

/// Estado compartilhado que transita por todos os agentes do 2flow.
/// Contém o Dado X de entrada e se transforma na Informação Y final.
pub const DataPipelineEvent = struct {
    allocator: std.mem.Allocator,

    // ------------------------------------------------------------------------
    // DADO X (Entrada Bruta / Raw Ingestion)
    // ------------------------------------------------------------------------
    raw_id: []const u8,
    raw_payload: []const u8,
    timestamp: i64,

    // ------------------------------------------------------------------------
    // ESTÁGIO 1: Sanitização e Validação
    // ------------------------------------------------------------------------
    sanitized_text: ?[]const u8 = null,
    is_valid: bool = false,

    // ------------------------------------------------------------------------
    // ESTÁGIO 2: Extrações Concorrentes (Fork-Join em Paralelo)
    // ------------------------------------------------------------------------
    // 2a. Extração de Entidades
    produto: ?[]const u8 = null,
    valor_monetario: f64 = 0.0,
    moeda: []const u8 = "EUR",

    // 2b. Anonimização LGPD / GDPR
    email_mascarado: ?[]const u8 = null,
    ip_mascarado: ?[]const u8 = null,

    // 2c. Análise de Sentimento Léxica
    sentimento: Sentiment = .neutro,
    score_sentimento: f32 = 0.0,

    // ------------------------------------------------------------------------
    // ESTÁGIO 3: Enriquecimento Analítico (INFORMAÇÃO Y)
    // ------------------------------------------------------------------------
    prioridade: Priority = .media,
    lead_score: u32 = 0,
    sla_minutos: u32 = 60,
    resumo_analitico: ?[]const u8 = null,

    // ------------------------------------------------------------------------
    // ESTÁGIO 4: Exportação & Auditoria
    // ------------------------------------------------------------------------
    status_final: []const u8 = "INICIADO",
    export_json: ?[]const u8 = null,
    motivo_quarentena: ?[]const u8 = null,
    historico_passos: std.ArrayList([]const u8),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, raw_id: []const u8, raw_payload: []const u8, timestamp: i64) DataPipelineEvent {
        return .{
            .allocator = allocator,
            .raw_id = raw_id,
            .raw_payload = raw_payload,
            .timestamp = timestamp,
            .historico_passos = .empty,
        };
    }

    pub fn deinit(self: *DataPipelineEvent) void {
        if (self.sanitized_text) |t| self.allocator.free(t);
        if (self.produto) |p| self.allocator.free(p);
        if (self.email_mascarado) |e| self.allocator.free(e);
        if (self.ip_mascarado) |ip| self.allocator.free(ip);
        if (self.resumo_analitico) |r| self.allocator.free(r);
        if (self.export_json) |j| self.allocator.free(j);
        if (self.motivo_quarentena) |m| self.allocator.free(m);
        for (self.historico_passos.items) |h| {
            self.allocator.free(h);
        }
        self.historico_passos.deinit(self.allocator);
    }

    pub fn registrarPasso(self: *DataPipelineEvent, passo: []const u8) !void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mutex.unlock();
        const dup = try self.allocator.dupe(u8, passo);
        try self.historico_passos.append(self.allocator, dup);
    }
};

// ============================================================================
// FERRAMENTA 1: TEXT SANITIZER TOOL (Sanitização e Higienização de Texto)
// ============================================================================
pub const TextSanitizerTool = struct {
    pub fn sanitize(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
        // Validação de segurança: rejeitar injeção ou caracteres nulos corrompidos
        if (std.mem.indexOf(u8, raw, "<script>") != null or std.mem.indexOfScalar(u8, raw, 0) != null) {
            return null; // Falha de validação -> direciona para quarentena
        }

        // Remove espaços extras nas extremidades
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;

        // Normalização: substitui múltiplos espaços/tabs/newlines consecutivos por um único espaço
        var buffer = try allocator.alloc(u8, trimmed.len);
        errdefer allocator.free(buffer);

        var out_idx: usize = 0;
        var last_was_space = false;

        for (trimmed) |c| {
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (!last_was_space) {
                    buffer[out_idx] = ' ';
                    out_idx += 1;
                    last_was_space = true;
                }
            } else {
                buffer[out_idx] = c;
                out_idx += 1;
                last_was_space = false;
            }
        }

        const result = try allocator.dupe(u8, buffer[0..out_idx]);
        allocator.free(buffer);
        return result;
    }
};

// ============================================================================
// FERRAMENTA 2: ENTITY EXTRACTOR TOOL (Extração Estruturada de Negócio)
// ============================================================================
pub const EntityExtractorTool = struct {
    pub const Extraction = struct {
        produto: ?[]const u8,
        valor: f64,
        moeda: []const u8,
    };

    pub fn extract(allocator: std.mem.Allocator, text: []const u8) !Extraction {
        var produto: ?[]const u8 = null;
        var valor: f64 = 0.0;
        var moeda: []const u8 = "EUR";

        // 1. Extração de produto pelo marcador "Produto:" ou "Compra de"
        const marcadores_produto = [_][]const u8{ "Produto: ", "Compra de " };
        for (marcadores_produto) |marcador| {
            if (std.mem.indexOf(u8, text, marcador)) |pos| {
                const start = pos + marcador.len;
                // Procura delimitador seguinte (, ou . ou no valor)
                var end = start;
                while (end < text.len) : (end += 1) {
                    const c = text[end];
                    if (c == ',' or c == '.' or c == '!' or (end + 9 <= text.len and std.mem.eql(u8, text[end .. end + 9], " no valor"))) {
                        break;
                    }
                }
                if (end > start) {
                    produto = try allocator.dupe(u8, std.mem.trim(u8, text[start..end], " "));
                    break;
                }
            }
        }

        // 2. Extração de moeda (EUR, BRL, USD, R$)
        if (std.mem.indexOf(u8, text, "EUR") != null or std.mem.indexOf(u8, text, "€") != null) {
            moeda = "EUR";
        } else if (std.mem.indexOf(u8, text, "BRL") != null or std.mem.indexOf(u8, text, "R$") != null) {
            moeda = "BRL";
        } else if (std.mem.indexOf(u8, text, "USD") != null or std.mem.indexOf(u8, text, "$") != null) {
            moeda = "USD";
        }

        // 3. Extração numérica do valor após marcador "valor:" ou "valor de"
        const marcadores_valor = [_][]const u8{ "valor: ", "valor de ", "valor: R$ ", "valor de R$ " };
        for (marcadores_valor) |marcador| {
            if (std.mem.indexOf(u8, text, marcador)) |pos| {
                const start = pos + marcador.len;
                var end = start;
                while (end < text.len and ((text[end] >= '0' and text[end] <= '9') or text[end] == '.')) : (end += 1) {}
                if (end > start) {
                    valor = std.fmt.parseFloat(f64, text[start..end]) catch 0.0;
                    break;
                }
            }
        }

        return .{
            .produto = produto,
            .valor = valor,
            .moeda = moeda,
        };
    }
};

// ============================================================================
// FERRAMENTA 3: PII MASKER TOOL (Anonimização LGPD / GDPR)
// ============================================================================
pub const PiiMaskerTool = struct {
    pub const MaskedPII = struct {
        email: ?[]const u8,
        ip: ?[]const u8,
    };

    pub fn maskPii(allocator: std.mem.Allocator, text: []const u8) !MaskedPII {
        var masked_email: ?[]const u8 = null;
        var masked_ip: ?[]const u8 = null;

        // 1. Localização e mascaramento de e-mail (ex: carlos.silva@techcorp.com -> c****a@techcorp.com)
        if (std.mem.indexOfScalar(u8, text, '@')) |at_pos| {
            var start = at_pos;
            while (start > 0 and text[start - 1] != ' ' and text[start - 1] != '(' and text[start - 1] != ':') : (start -= 1) {}
            var end = at_pos;
            while (end < text.len) : (end += 1) {
                const c = text[end];
                if (c == ' ' or c == ')' or c == ',' or c == ';' or c == '!' or c == '?') break;
                if (c == '.' and (end + 1 == text.len or text[end + 1] == ' ')) break;
            }

            const email = text[start..end];
            const at_relative = at_pos - start;
            if (at_relative > 1) {
                const domain = email[at_relative..];
                const first_char = email[0];
                const last_char = email[at_relative - 1];
                masked_email = try std.fmt.allocPrint(allocator, "{c}****{c}{s}", .{ first_char, last_char, domain });
            } else {
                masked_email = try allocator.dupe(u8, "****@protegido.lgpd");
            }
        }

        // 2. Localização e mascaramento de IP IPv4 (ex: 192.168.1.55 -> 192.168.*.*)
        const marcador_ip = "IP ";
        if (std.mem.indexOf(u8, text, marcador_ip)) |pos| {
            const start = pos + marcador_ip.len;
            var end = start;
            while (end < text.len and ((text[end] >= '0' and text[end] <= '9') or text[end] == '.')) : (end += 1) {}
            const ip_str = text[start..end];

            var dot_count: usize = 0;
            var second_dot: ?usize = null;
            for (ip_str, 0..) |c, i| {
                if (c == '.') {
                    dot_count += 1;
                    if (dot_count == 2) {
                        second_dot = i;
                        break;
                    }
                }
            }

            if (second_dot) |dot2| {
                masked_ip = try std.fmt.allocPrint(allocator, "{s}.*.*", .{ip_str[0..dot2]});
            } else {
                masked_ip = try allocator.dupe(u8, "*.*.*.*");
            }
        }

        return .{
            .email = masked_email,
            .ip = masked_ip,
        };
    }
};

// ============================================================================
// FERRAMENTA 4: SENTIMENT ANALYZER TOOL (Motor Léxico de Polaridade)
// ============================================================================
pub const SentimentAnalyzerTool = struct {
    pub const SentimentResult = struct {
        classificacao: Sentiment,
        score: f32,
    };

    pub fn analyze(text: []const u8) SentimentResult {
        // Dicionário léxico com pesos
        const termos_positivos = [_][]const u8{
            "SUCESSO", "CONFIRMADO", "EXCELENTE", "OTIMO", "APROVADO", "URGENTE", "RAPIDO",
        };
        const termos_negativos = [_][]const u8{
            "ERRO", "FALHA", "ATRASO", "DEFEITO", "CANCELAR", "RECLAMACAO", "FRAUDE", "RECUSADO",
        };

        var score: f32 = 0.0;

        // Análise insensível a maiúsculas/minúsculas de termos
        for (termos_positivos) |termo| {
            if (containsCaseInsensitive(text, termo)) {
                score += 0.35;
            }
        }

        for (termos_negativos) |termo| {
            if (containsCaseInsensitive(text, termo)) {
                score -= 0.50;
            }
        }

        const classificacao: Sentiment = if (score >= 0.25)
            .positivo
        else if (score <= -0.25)
            .negativo
        else
            .neutro;

        return .{
            .classificacao = classificacao,
            .score = score,
        };
    }

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var match = true;
            for (needle, 0..) |nc, j| {
                const hc = std.ascii.toUpper(haystack[i + j]);
                if (hc != nc) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }
};

// ============================================================================
// FERRAMENTA 5: ANALYTICS ENRICHER TOOL (Fusão e Enriquecimento de Negócio)
// ============================================================================
pub const AnalyticsEnricherTool = struct {
    pub const EnrichmentResult = struct {
        prioridade: Priority,
        lead_score: u32,
        sla_minutos: u32,
        resumo: []const u8,
    };

    pub fn enrich(allocator: std.mem.Allocator, ev: *const DataPipelineEvent) !EnrichmentResult {
        var prioridade: Priority = .media;
        var score: u32 = 50;
        var sla: u32 = 60;

        // Regra de alto valor
        if (ev.valor_monetario >= 4000.00) {
            score += 30;
            prioridade = .alta;
            sla = 30;
        }

        // Regra de sentimento positivo
        if (ev.sentimento == .positivo) {
            score += 15;
        } else if (ev.sentimento == .negativo) {
            score = if (score >= 20) score - 20 else 0;
            prioridade = .critica; // Problema com cliente requer atenção crítica
            sla = 15;
        }

        // Regra de urgência expressa no texto
        if (ev.sanitized_text) |t| {
            if (std.mem.indexOf(u8, t, "urgente") != null or std.mem.indexOf(u8, t, "URGENTE") != null) {
                prioridade = if (prioridade == .alta) .critica else .alta;
                sla = 15;
                score += 5;
            }
        }

        const prod = ev.produto orelse "Item Não Especificado";
        const email = ev.email_mascarado orelse "N/A";
        const resumo = try std.fmt.allocPrint(
            allocator,
            "[{s}] Pedido de '{s}' no montante de {d:.2} {s}. Cliente: {s}. Sentimento: {s}.",
            .{
                prioridade.asString(),
                prod,
                ev.valor_monetario,
                ev.moeda,
                email,
                ev.sentimento.asString(),
            },
        );

        return .{
            .prioridade = prioridade,
            .lead_score = score,
            .sla_minutos = sla,
            .resumo = resumo,
        };
    }
};

// ============================================================================
// FERRAMENTA 6: DATA SINK WRITER TOOL (Exportação em JSON Estruturado)
// ============================================================================
pub const DataSinkWriterTool = struct {
    pub fn serialize(allocator: std.mem.Allocator, ev: *const DataPipelineEvent) ![]const u8 {
        return try std.fmt.allocPrint(
            allocator,
            \\{{
            \\  "evento_id": "{s}",
            \\  "status": "{s}",
            \\  "cliente_lgpd": "{s}",
            \\  "origem_ip": "{s}",
            \\  "produto": "{s}",
            \\  "valor": {d:.2},
            \\  "moeda": "{s}",
            \\  "sentimento": "{s}",
            \\  "score_sentimento": {d:.2},
            \\  "prioridade": "{s}",
            \\  "lead_score": {d},
            \\  "sla_minutos": {d},
            \\  "resumo_executivo": "{s}"
            \\}}
        ,
            .{
                ev.raw_id,
                ev.status_final,
                ev.email_mascarado orelse "anônimo",
                ev.ip_mascarado orelse "0.0.0.0",
                ev.produto orelse "indefinido",
                ev.valor_monetario,
                ev.moeda,
                ev.sentimento.asString(),
                ev.score_sentimento,
                ev.prioridade.asString(),
                ev.lead_score,
                ev.sla_minutos,
                ev.resumo_analitico orelse "",
            },
        );
    }
};
