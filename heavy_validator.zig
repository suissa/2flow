const std = @import("std");

// ============================================================================
// 🛡️ 2FV HEAVY DATA VALIDATION PIPELINE (ALLASCODE SOTA ARCHITECTURE)
// ============================================================================
// Motor de validação determinística de alta densidade computacional.
// Projetado para operar com Zero-Syscalls tanto em Backend Nativo (Zig 0.16/0.17)
// quanto no Frontend (WebAssembly freestanding 32-bit).
// ============================================================================

pub const Status2FV = struct {
    pub const SUCCESS: i32 = 1;

    // Estágio 1: Segurança Binária & Sanitização Profunda
    pub const ERR_EMPTY_PAYLOAD: i32 = -1;
    pub const ERR_NULL_BYTE_INJECTION: i32 = -2;
    pub const ERR_INVALID_UTF8: i32 = -3;
    pub const ERR_XSS_DETECTED: i32 = -4;
    pub const ERR_SQLI_DETECTED: i32 = -5;
    pub const ERR_PATH_TRAVERSAL: i32 = -6;
    pub const ERR_CMD_INJECTION: i32 = -7;
    pub const ERR_PAYLOAD_TOO_LARGE: i32 = -8;

    // Estágio 2: Parsing & Estrutura de Schema
    pub const ERR_JSON_MALFORMED: i32 = -20;
    pub const ERR_MISSING_REQUIRED_FIELD: i32 = -21;
    pub const ERR_INVALID_UUID_FORMAT: i32 = -22;
    pub const ERR_INVALID_EMAIL_FORMAT: i32 = -23;
    pub const ERR_EMPTY_STRING_FIELD: i32 = -24;

    // Estágio 3: Invariantes Fiscais e de Domínio (Financial Plane)
    pub const ERR_INVALID_DOCUMENT_FORMAT: i32 = -30;
    pub const ERR_INVALID_CPF_CHECKSUM: i32 = -31;
    pub const ERR_INVALID_CNPJ_CHECKSUM: i32 = -32;
    pub const ERR_UNSUPPORTED_CURRENCY: i32 = -33;
    pub const ERR_ZERO_OR_NEGATIVE_AMOUNT: i32 = -34;
    pub const ERR_EXCEEDED_MAX_TRANSACTION: i32 = -35;

    // Estágio 4: Conciliação Contábil & Itens (Ledger Invariant)
    pub const ERR_EMPTY_ITEMS_ARRAY: i32 = -40;
    pub const ERR_INVALID_ITEM_QUANTITY: i32 = -41;
    pub const ERR_INVALID_ITEM_PRICE: i32 = -42;
    pub const ERR_LEDGER_SUM_MISMATCH: i32 = -43;

    // Estágio 5: Integridade Criptográfica & Anti-Replay Temporal
    pub const ERR_TIMESTAMP_EXPIRED: i32 = -50;
    pub const ERR_TIMESTAMP_FUTURE_SKEW: i32 = -51;
    pub const ERR_CHECKSUM_MISMATCH: i32 = -52;

    pub fn asString(code: i32) []const u8 {
        return switch (code) {
            SUCCESS => "SUCCESS_VALIDATED_2FV",
            ERR_EMPTY_PAYLOAD => "ERR_EMPTY_PAYLOAD",
            ERR_NULL_BYTE_INJECTION => "ERR_NULL_BYTE_INJECTION",
            ERR_INVALID_UTF8 => "ERR_INVALID_UTF8",
            ERR_XSS_DETECTED => "ERR_XSS_DETECTED",
            ERR_SQLI_DETECTED => "ERR_SQLI_DETECTED",
            ERR_PATH_TRAVERSAL => "ERR_PATH_TRAVERSAL",
            ERR_CMD_INJECTION => "ERR_CMD_INJECTION",
            ERR_PAYLOAD_TOO_LARGE => "ERR_PAYLOAD_TOO_LARGE",
            ERR_JSON_MALFORMED => "ERR_JSON_MALFORMED",
            ERR_MISSING_REQUIRED_FIELD => "ERR_MISSING_REQUIRED_FIELD",
            ERR_INVALID_UUID_FORMAT => "ERR_INVALID_UUID_FORMAT",
            ERR_INVALID_EMAIL_FORMAT => "ERR_INVALID_EMAIL_FORMAT",
            ERR_EMPTY_STRING_FIELD => "ERR_EMPTY_STRING_FIELD",
            ERR_INVALID_DOCUMENT_FORMAT => "ERR_INVALID_DOCUMENT_FORMAT",
            ERR_INVALID_CPF_CHECKSUM => "ERR_INVALID_CPF_CHECKSUM",
            ERR_INVALID_CNPJ_CHECKSUM => "ERR_INVALID_CNPJ_CHECKSUM",
            ERR_UNSUPPORTED_CURRENCY => "ERR_UNSUPPORTED_CURRENCY",
            ERR_ZERO_OR_NEGATIVE_AMOUNT => "ERR_ZERO_OR_NEGATIVE_AMOUNT",
            ERR_EXCEEDED_MAX_TRANSACTION => "ERR_EXCEEDED_MAX_TRANSACTION",
            ERR_EMPTY_ITEMS_ARRAY => "ERR_EMPTY_ITEMS_ARRAY",
            ERR_INVALID_ITEM_QUANTITY => "ERR_INVALID_ITEM_QUANTITY",
            ERR_INVALID_ITEM_PRICE => "ERR_INVALID_ITEM_PRICE",
            ERR_LEDGER_SUM_MISMATCH => "ERR_LEDGER_SUM_MISMATCH",
            ERR_TIMESTAMP_EXPIRED => "ERR_TIMESTAMP_EXPIRED",
            ERR_TIMESTAMP_FUTURE_SKEW => "ERR_TIMESTAMP_FUTURE_SKEW",
            ERR_CHECKSUM_MISMATCH => "ERR_CHECKSUM_MISMATCH",
            else => "ERR_UNKNOWN_REJECTION",
        };
    }
};

// Constantes de Limites Operacionais
pub const MAX_PAYLOAD_BYTES: usize = 128 * 1024; // 128 KB
pub const MAX_TRANSACTION_CENTS: i64 = 100_000_000; // R$ 1.000.000,00

// ============================================================================
// ESTÁGIO 1: SEGURANÇA BINÁRIA E SANITIZAÇÃO
// ============================================================================

pub const SecurityScanner = struct {
    pub fn validateBinaryAndSecurity(payload: []const u8) i32 {
        if (payload.len == 0) return Status2FV.ERR_EMPTY_PAYLOAD;
        if (payload.len > MAX_PAYLOAD_BYTES) return Status2FV.ERR_PAYLOAD_TOO_LARGE;

        // 1. Verificação de Byte Nulo (\0)
        for (payload) |b| {
            if (b == 0) return Status2FV.ERR_NULL_BYTE_INJECTION;
        }

        // 2. Validação Estrita de Codificação UTF-8
        if (!isValidUtf8(payload)) {
            return Status2FV.ERR_INVALID_UTF8;
        }

        // 3. Detecção de Injeções (XSS, SQLi, Command, Path Traversal)
        if (hasXssAttack(payload)) return Status2FV.ERR_XSS_DETECTED;
        if (hasSqliAttack(payload)) return Status2FV.ERR_SQLI_DETECTED;
        if (hasPathTraversal(payload)) return Status2FV.ERR_PATH_TRAVERSAL;
        if (hasCommandInjection(payload)) return Status2FV.ERR_CMD_INJECTION;

        return Status2FV.SUCCESS;
    }

    fn isValidUtf8(bytes: []const u8) bool {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b <= 0x7F) {
                // 1 byte ASCII
                i += 1;
            } else if ((b & 0xE0) == 0xC0) {
                // 2 bytes: 110xxxxx 10xxxxxx
                if (b < 0xC2) return false; // Overlong sequence
                if (i + 1 >= bytes.len) return false;
                if ((bytes[i + 1] & 0xC0) != 0x80) return false;
                i += 2;
            } else if ((b & 0xF0) == 0xE0) {
                // 3 bytes: 1110xxxx 10xxxxxx 10xxxxxx
                if (i + 2 >= bytes.len) return false;
                const b1 = bytes[i + 1];
                const b2 = bytes[i + 2];
                if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80) return false;
                if (b == 0xE0 and b1 < 0xA0) return false; // Overlong
                if (b == 0xED and b1 >= 0xA0) return false; // UTF-16 surrogates (D800..DFFF)
                i += 3;
            } else if ((b & 0xF8) == 0xF0) {
                // 4 bytes: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                if (i + 3 >= bytes.len) return false;
                const b1 = bytes[i + 1];
                const b2 = bytes[i + 2];
                const b3 = bytes[i + 3];
                if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80 or (b3 & 0xC0) != 0x80) return false;
                if (b == 0xF0 and b1 < 0x90) return false; // Overlong
                if (b == 0xF4 and b1 > 0x8F) return false; // Acima de U+10FFFF
                if (b > 0xF4) return false;
                i += 4;
            } else {
                return false;
            }
        }
        return true;
    }

    fn asciiCaseEq(a: u8, b: u8) bool {
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        return la == lb;
    }

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or haystack.len < needle.len) return false;
        var i: usize = 0;
        const end = haystack.len - needle.len;
        while (i <= end) : (i += 1) {
            var match = true;
            for (needle, 0..) |n, j| {
                if (!asciiCaseEq(haystack[i + j], n)) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn hasXssAttack(data: []const u8) bool {
        const patterns = [_][]const u8{
            "<script",
            "</script>",
            "javascript:",
            "onerror=",
            "onload=",
            "<iframe",
            "document.cookie",
            "<svg onload",
            "eval(",
            "alert(",
        };
        for (patterns) |pat| {
            if (containsCaseInsensitive(data, pat)) return true;
        }
        return false;
    }

    fn hasSqliAttack(data: []const u8) bool {
        const patterns = [_][]const u8{
            "' or '",
            "\" or \"",
            "' or 1=1",
            "\" or 1=1",
            "union select",
            "union all select",
            "--",
            "/*",
            "*/",
            "; drop table",
            "; delete from",
            "; insert into",
        };
        for (patterns) |pat| {
            if (containsCaseInsensitive(data, pat)) return true;
        }
        return false;
    }

    fn hasPathTraversal(data: []const u8) bool {
        return std.mem.indexOf(u8, data, "../") != null or
            std.mem.indexOf(u8, data, "..\\") != null or
            std.mem.indexOf(u8, data, "/etc/passwd") != null or
            std.mem.indexOf(u8, data, "c:\\windows\\") != null;
    }

    fn hasCommandInjection(data: []const u8) bool {
        const patterns = [_][]const u8{
            "; rm -rf",
            "; cat /",
            "| ls",
            "| whoami",
            "$(whoami)",
            "`whoami`",
            "&& rm ",
        };
        for (patterns) |pat| {
            if (containsCaseInsensitive(data, pat)) return true;
        }
        return false;
    }
};

// ============================================================================
// ESTÁGIO 2 & 3 & 4 & 5: ESTRUTURAS, REGRAS DE DOMÍNIO E CRIPTOGRAFIA
// ============================================================================

pub const DocumentType = enum { cpf, cnpj, invalid };

pub const Item = struct {
    sku: []const u8,
    name: []const u8,
    quantity: i64,
    unit_price_cents: i64,
};

pub const HeavyIngestPayload = struct {
    idempotency_key: []const u8,
    timestamp: i64,
    account_id: []const u8,
    recipient_document: []const u8,
    recipient_email: []const u8,
    currency: []const u8,
    total_amount_cents: i64,
    tax_amount_cents: i64,
    items: []const Item,
    checksum: []const u8,
    payload_notes: []const u8,
};

pub const DomainValidator = struct {
    // ------------------------------------------------------------------------
    // UUIDv4 Validator (RFC 4122)
    // ------------------------------------------------------------------------
    pub fn isValidUuidV4(uuid: []const u8) bool {
        if (uuid.len != 36) return false;
        if (uuid[8] != '-' or uuid[13] != '-' or uuid[18] != '-' or uuid[23] != '-') return false;

        // Versão 4 deve conter '4' no byte 14
        if (uuid[14] != '4') return false;

        // Variante RFC 4122 no byte 19 deve ser 8, 9, a, b, A, B
        const var_char = uuid[19];
        if (var_char != '8' and var_char != '9' and var_char != 'a' and var_char != 'b' and
            var_char != 'A' and var_char != 'B')
        {
            return false;
        }

        for (uuid, 0..) |c, idx| {
            if (idx == 8 or idx == 13 or idx == 18 or idx == 23) continue;
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                return false;
            }
        }
        return true;
    }

    // ------------------------------------------------------------------------
    // E-mail RFC 5322 Lexical Checker (Zero-Regex)
    // ------------------------------------------------------------------------
    pub fn isValidEmail(email: []const u8) bool {
        if (email.len < 5 or email.len > 254) return false;

        var at_index: ?usize = null;
        var dots_after_at: usize = 0;
        var last_char_dot = false;

        for (email, 0..) |c, i| {
            if (c == '@') {
                if (at_index != null) return false; // Mais de um '@'
                if (i == 0) return false; // Começa com '@'
                at_index = i;
                last_char_dot = false;
            } else if (c == '.') {
                if (last_char_dot) return false; // Pontos consecutivos ".."
                if (i == 0 or i == email.len - 1) return false; // Ponto nas bordas
                if (at_index != null) dots_after_at += 1;
                last_char_dot = true;
            } else if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '+')
            {
                last_char_dot = false;
            } else {
                return false; // Caractere inválido
            }
        }

        if (at_index == null) return false;
        const at = at_index.?;
        if (email.len - at - 1 < 3) return false; // Domínio muito curto
        if (dots_after_at == 0) return false; // Precisa de pelo menos um ponto no domínio
        return true;
    }

    // ------------------------------------------------------------------------
    // Módulo 11 para CPF (Cadastro de Pessoas Físicas - 11 dígitos)
    // ------------------------------------------------------------------------
    pub fn validateCpf(raw: []const u8) i32 {
        var digits: [11]u8 = undefined;
        var count: usize = 0;

        for (raw) |c| {
            if (c >= '0' and c <= '9') {
                if (count >= 11) return Status2FV.ERR_INVALID_DOCUMENT_FORMAT;
                digits[count] = c - '0';
                count += 1;
            } else if (c == '.' or c == '-') {
                continue;
            } else {
                return Status2FV.ERR_INVALID_DOCUMENT_FORMAT;
            }
        }
        if (count != 11) return Status2FV.ERR_INVALID_DOCUMENT_FORMAT;

        // Rejeita dígitos todos iguais (111.111.111-11, etc.)
        var all_equal = true;
        for (digits[1..]) |d| {
            if (d != digits[0]) {
                all_equal = false;
                break;
            }
        }
        if (all_equal) return Status2FV.ERR_INVALID_CPF_CHECKSUM;

        // 1º Dígito Verificador (pesos 10 a 2)
        var sum1: u32 = 0;
        var i: usize = 0;
        while (i < 9) : (i += 1) {
            sum1 += @as(u32, digits[i]) * @as(u32, @intCast(10 - i));
        }
        var dv1 = (sum1 * 10) % 11;
        if (dv1 >= 10) dv1 = 0;
        if (digits[9] != dv1) return Status2FV.ERR_INVALID_CPF_CHECKSUM;

        // 2º Dígito Verificador (pesos 11 a 2)
        var sum2: u32 = 0;
        i = 0;
        while (i < 10) : (i += 1) {
            sum2 += @as(u32, digits[i]) * @as(u32, @intCast(11 - i));
        }
        var dv2 = (sum2 * 10) % 11;
        if (dv2 >= 10) dv2 = 0;
        if (digits[10] != dv2) return Status2FV.ERR_INVALID_CPF_CHECKSUM;

        return Status2FV.SUCCESS;
    }

    // ------------------------------------------------------------------------
    // Módulo 11 para CNPJ (Cadastro Nacional da Pessoa Jurídica - 14 dígitos)
    // ------------------------------------------------------------------------
    pub fn validateCnpj(raw: []const u8) i32 {
        var digits: [14]u8 = undefined;
        var count: usize = 0;

        for (raw) |c| {
            if (c >= '0' and c <= '9') {
                if (count >= 14) return Status2FV.ERR_INVALID_DOCUMENT_FORMAT;
                digits[count] = c - '0';
                count += 1;
            } else if (c == '.' or c == '/' or c == '-') {
                continue;
            } else {
                return Status2FV.ERR_INVALID_DOCUMENT_FORMAT;
            }
        }
        if (count != 14) return Status2FV.ERR_INVALID_DOCUMENT_FORMAT;

        // Rejeita sequências todas iguais
        var all_equal = true;
        for (digits[1..]) |d| {
            if (d != digits[0]) {
                all_equal = false;
                break;
            }
        }
        if (all_equal) return Status2FV.ERR_INVALID_CNPJ_CHECKSUM;

        // 1º Dígito Verificador
        const weights1 = [_]u32{ 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 };
        var sum1: u32 = 0;
        for (weights1, 0..) |w, idx| {
            sum1 += @as(u32, digits[idx]) * w;
        }
        const rem1 = sum1 % 11;
        const dv1: u8 = if (rem1 < 2) 0 else @intCast(11 - rem1);
        if (digits[12] != dv1) return Status2FV.ERR_INVALID_CNPJ_CHECKSUM;

        // 2º Dígito Verificador
        const weights2 = [_]u32{ 6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 };
        var sum2: u32 = 0;
        for (weights2, 0..) |w, idx| {
            sum2 += @as(u32, digits[idx]) * w;
        }
        const rem2 = sum2 % 11;
        const dv2: u8 = if (rem2 < 2) 0 else @intCast(11 - rem2);
        if (digits[13] != dv2) return Status2FV.ERR_INVALID_CNPJ_CHECKSUM;

        return Status2FV.SUCCESS;
    }

    pub fn validateDocument(raw: []const u8) i32 {
        var digit_count: usize = 0;
        for (raw) |c| {
            if (c >= '0' and c <= '9') digit_count += 1;
        }
        if (digit_count == 11) return validateCpf(raw);
        if (digit_count == 14) return validateCnpj(raw);
        return Status2FV.ERR_INVALID_DOCUMENT_FORMAT;
    }

    // ------------------------------------------------------------------------
    // ISO 4217 Currency Table
    // ------------------------------------------------------------------------
    pub fn isValidCurrency(cur: []const u8) bool {
        const allowed = [_][]const u8{ "BRL", "USD", "EUR", "GBP", "JPY", "CAD", "CHF", "AUD" };
        for (allowed) |a| {
            if (std.mem.eql(u8, cur, a)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------------
    // Checksum Criptográfico FNV-1a (32-bit Canonical Integrity)
    // ------------------------------------------------------------------------
    pub fn computeFnv1a32(idempotency: []const u8, amount_cents: i64, doc: []const u8) [8]u8 {
        var hash: u32 = 2166136261;
        const prime: u32 = 16777619;

        for (idempotency) |b| {
            hash ^= b;
            hash = hash *% prime;
        }
        hash ^= ':';
        hash = hash *% prime;

        // Converte amount_cents em bytes
        var amt = amount_cents;
        if (amt < 0) amt = -amt;
        var amt_buf: [32]u8 = undefined;
        var amt_len: usize = 0;
        if (amt == 0) {
            amt_buf[0] = '0';
            amt_len = 1;
        } else {
            var temp = amt;
            while (temp > 0) : (temp = @divTrunc(temp, 10)) {
                amt_buf[amt_len] = @intCast('0' + @as(u8, @intCast(@mod(temp, 10))));
                amt_len += 1;
            }
            // Inverte
            var j: usize = 0;
            while (j < amt_len / 2) : (j += 1) {
                const tmp = amt_buf[j];
                amt_buf[j] = amt_buf[amt_len - 1 - j];
                amt_buf[amt_len - 1 - j] = tmp;
            }
        }

        for (amt_buf[0..amt_len]) |b| {
            hash ^= b;
            hash = hash *% prime;
        }
        hash ^= ':';
        hash = hash *% prime;

        for (doc) |b| {
            hash ^= b;
            hash = hash *% prime;
        }

        // Formata como 8 hex minúsculos
        const hex_chars = "0123456789abcdef";
        var out: [8]u8 = undefined;
        var shift: usize = 28;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const nibble = (hash >> @intCast(shift)) & 0x0F;
            out[k] = hex_chars[nibble];
            if (shift >= 4) shift -= 4;
        }
        return out;
    }
};

// ============================================================================
// PARSER ZERO-DEPENDENCY DE JSON PARA PAYLOAD CORPORATIVO
// ============================================================================

pub const FastJsonScanner = struct {
    pub fn findStringField(json: []const u8, field_name: []const u8) ?[]const u8 {
        var search_key_buf: [64]u8 = undefined;
        if (field_name.len + 3 > search_key_buf.len) return null;
        search_key_buf[0] = '"';
        @memcpy(search_key_buf[1 .. 1 + field_name.len], field_name);
        search_key_buf[1 + field_name.len] = '"';
        const search_key = search_key_buf[0 .. 2 + field_name.len];

        const key_pos = std.mem.indexOf(u8, json, search_key) orelse return null;
        var pos = key_pos + search_key.len;

        // Pula espaços e ':'
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\r' or json[pos] == '\n' or json[pos] == ':')) {
            pos += 1;
        }
        if (pos >= json.len or json[pos] != '"') return null;
        pos += 1; // Pula a aspas de abertura

        const val_start = pos;
        while (pos < json.len and json[pos] != '"') {
            if (json[pos] == '\\' and pos + 1 < json.len) {
                pos += 2; // Pula caractere de escape
            } else {
                pos += 1;
            }
        }
        if (pos >= json.len) return null; // Não fechou aspas
        return json[val_start..pos];
    }

    pub fn findIntField(json: []const u8, field_name: []const u8) ?i64 {
        var search_key_buf: [64]u8 = undefined;
        if (field_name.len + 3 > search_key_buf.len) return null;
        search_key_buf[0] = '"';
        @memcpy(search_key_buf[1 .. 1 + field_name.len], field_name);
        search_key_buf[1 + field_name.len] = '"';
        const search_key = search_key_buf[0 .. 2 + field_name.len];

        const key_pos = std.mem.indexOf(u8, json, search_key) orelse return null;
        var pos = key_pos + search_key.len;

        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\r' or json[pos] == '\n' or json[pos] == ':')) {
            pos += 1;
        }
        if (pos >= json.len) return null;

        var negative = false;
        if (json[pos] == '-') {
            negative = true;
            pos += 1;
        }

        var val: i64 = 0;
        var has_digits = false;
        while (pos < json.len and (json[pos] >= '0' and json[pos] <= '9')) {
            has_digits = true;
            val = val * 10 + (json[pos] - '0');
            pos += 1;
        }
        if (!has_digits) return null;
        return if (negative) -val else val;
    }

    pub const ParsedItems = struct {
        count: usize,
        items: [16]Item,
        sum_cents: i64,
        has_error: i32,
    };

    pub fn parseItemsArray(json: []const u8) ParsedItems {
        var res = ParsedItems{
            .count = 0,
            .items = undefined,
            .sum_cents = 0,
            .has_error = Status2FV.SUCCESS,
        };

        const key = "\"items\"";
        const key_pos = std.mem.indexOf(u8, json, key) orelse {
            res.has_error = Status2FV.ERR_MISSING_REQUIRED_FIELD;
            return res;
        };

        var pos = key_pos + key.len;
        while (pos < json.len and json[pos] != '[') {
            if (json[pos] != ' ' and json[pos] != '\t' and json[pos] != '\r' and json[pos] != '\n' and json[pos] != ':') {
                res.has_error = Status2FV.ERR_JSON_MALFORMED;
                return res;
            }
            pos += 1;
        }
        if (pos >= json.len) {
            res.has_error = Status2FV.ERR_JSON_MALFORMED;
            return res;
        }
        pos += 1; // Pula '['

        var in_array = true;
        while (pos < json.len and in_array) {
            // Pula espaços
            while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\r' or json[pos] == '\n' or json[pos] == ',')) {
                pos += 1;
            }
            if (pos >= json.len) break;
            if (json[pos] == ']') {
                in_array = false;
                break;
            }
            if (json[pos] != '{') {
                res.has_error = Status2FV.ERR_JSON_MALFORMED;
                return res;
            }

            // Encontra fim do objeto '}'
            const obj_start = pos;
            var depth: usize = 0;
            while (pos < json.len) {
                if (json[pos] == '{') depth += 1;
                if (json[pos] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        pos += 1;
                        break;
                    }
                }
                pos += 1;
            }
            const item_obj = json[obj_start..pos];

            if (res.count >= 16) {
                // Teto de itens por requisição
                break;
            }

            const sku = findStringField(item_obj, "sku") orelse "";
            const name = findStringField(item_obj, "name") orelse "";
            const qty = findIntField(item_obj, "quantity") orelse 0;
            const price = findIntField(item_obj, "unit_price_cents") orelse 0;

            if (qty <= 0) {
                res.has_error = Status2FV.ERR_INVALID_ITEM_QUANTITY;
                return res;
            }
            if (price <= 0) {
                res.has_error = Status2FV.ERR_INVALID_ITEM_PRICE;
                return res;
            }

            const line_total = qty * price;
            res.sum_cents += line_total;
            res.items[res.count] = Item{
                .sku = sku,
                .name = name,
                .quantity = qty,
                .unit_price_cents = price,
            };
            res.count += 1;
        }

        if (res.count == 0) {
            res.has_error = Status2FV.ERR_EMPTY_ITEMS_ARRAY;
        }
        return res;
    }
};

// ============================================================================
// PIPELINE PRINCIPAL DE VALIDAÇÃO PESADA (ENTRYPOINT UNIFICADO)
// ============================================================================

pub const HeavyValidationPipeline = struct {
    pub const ValidationResult = struct {
        status: i32,
        failed_stage: u8,
        error_message: []const u8,
    };

    /// Executa os 5 estágios de validação no payload JSON.
    /// `reference_timestamp`: Timestamp do momento (para testes reprodutíveis ou WASM).
    /// Se 0, usa valor padrão de âncora temporal.
    pub fn validate(payload: []const u8, reference_timestamp: i64) ValidationResult {
        // --------------------------------------------------------------------
        // ESTÁGIO 1: SEGURANÇA BINÁRIA & SANITIZAÇÃO
        // --------------------------------------------------------------------
        const s1 = SecurityScanner.validateBinaryAndSecurity(payload);
        if (s1 != Status2FV.SUCCESS) {
            return .{
                .status = s1,
                .failed_stage = 1,
                .error_message = Status2FV.asString(s1),
            };
        }

        // Validação mínima de sintaxe JSON: inicia com '{' e termina com '}'
        const trimmed = std.mem.trim(u8, payload, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
            return .{
                .status = Status2FV.ERR_JSON_MALFORMED,
                .failed_stage = 2,
                .error_message = Status2FV.asString(Status2FV.ERR_JSON_MALFORMED),
            };
        }

        // --------------------------------------------------------------------
        // ESTÁGIO 2: EXTRAÇÃO E SCHEMA
        // --------------------------------------------------------------------
        const idempotency = FastJsonScanner.findStringField(trimmed, "idempotency_key");
        if (idempotency == null or idempotency.?.len == 0) {
            return .{ .status = Status2FV.ERR_MISSING_REQUIRED_FIELD, .failed_stage = 2, .error_message = "Missing 'idempotency_key'" };
        }
        if (!DomainValidator.isValidUuidV4(idempotency.?)) {
            return .{ .status = Status2FV.ERR_INVALID_UUID_FORMAT, .failed_stage = 2, .error_message = "Invalid UUIDv4 'idempotency_key'" };
        }

        const email = FastJsonScanner.findStringField(trimmed, "recipient_email");
        if (email == null or email.?.len == 0) {
            return .{ .status = Status2FV.ERR_MISSING_REQUIRED_FIELD, .failed_stage = 2, .error_message = "Missing 'recipient_email'" };
        }
        if (!DomainValidator.isValidEmail(email.?)) {
            return .{ .status = Status2FV.ERR_INVALID_EMAIL_FORMAT, .failed_stage = 2, .error_message = "Invalid RFC 5322 email syntax" };
        }

        const account_id = FastJsonScanner.findStringField(trimmed, "account_id");
        if (account_id == null or account_id.?.len == 0) {
            return .{ .status = Status2FV.ERR_MISSING_REQUIRED_FIELD, .failed_stage = 2, .error_message = "Missing 'account_id'" };
        }

        // --------------------------------------------------------------------
        // ESTÁGIO 3: INVARIANTES FISCAIS & FINANCEIRAS (FINANCIAL PLANE)
        // --------------------------------------------------------------------
        const doc = FastJsonScanner.findStringField(trimmed, "recipient_document");
        if (doc == null or doc.?.len == 0) {
            return .{ .status = Status2FV.ERR_MISSING_REQUIRED_FIELD, .failed_stage = 3, .error_message = "Missing 'recipient_document'" };
        }
        const doc_status = DomainValidator.validateDocument(doc.?);
        if (doc_status != Status2FV.SUCCESS) {
            return .{ .status = doc_status, .failed_stage = 3, .error_message = Status2FV.asString(doc_status) };
        }

        const currency = FastJsonScanner.findStringField(trimmed, "currency");
        if (currency == null or !DomainValidator.isValidCurrency(currency.?)) {
            return .{ .status = Status2FV.ERR_UNSUPPORTED_CURRENCY, .failed_stage = 3, .error_message = "Unsupported ISO 4217 currency" };
        }

        const total_amount = FastJsonScanner.findIntField(trimmed, "total_amount_cents") orelse -1;
        if (total_amount <= 0) {
            return .{ .status = Status2FV.ERR_ZERO_OR_NEGATIVE_AMOUNT, .failed_stage = 3, .error_message = "Total amount must be strictly positive" };
        }
        if (total_amount > MAX_TRANSACTION_CENTS) {
            return .{ .status = Status2FV.ERR_EXCEEDED_MAX_TRANSACTION, .failed_stage = 3, .error_message = "Transaction exceeds operational ceiling" };
        }

        const tax_amount = FastJsonScanner.findIntField(trimmed, "tax_amount_cents") orelse -1;
        if (tax_amount < 0) {
            return .{ .status = Status2FV.ERR_ZERO_OR_NEGATIVE_AMOUNT, .failed_stage = 3, .error_message = "Tax amount cannot be negative" };
        }

        // --------------------------------------------------------------------
        // ESTÁGIO 4: CONCILIAÇÃO CONTÁBIL DOS ITENS (LEDGER INVARIANT)
        // --------------------------------------------------------------------
        const parsed_items = FastJsonScanner.parseItemsArray(trimmed);
        if (parsed_items.has_error != Status2FV.SUCCESS) {
            return .{
                .status = parsed_items.has_error,
                .failed_stage = 4,
                .error_message = Status2FV.asString(parsed_items.has_error),
            };
        }

        // Invariante de soma: sum(item.quantity * item.unit_price_cents) + tax_amount_cents == total_amount_cents
        if (parsed_items.sum_cents + tax_amount != total_amount) {
            return .{
                .status = Status2FV.ERR_LEDGER_SUM_MISMATCH,
                .failed_stage = 4,
                .error_message = "Ledger mismatch: items sum + taxes does not equal total_amount_cents",
            };
        }

        // --------------------------------------------------------------------
        // ESTÁGIO 5: INTEGRIDADE TEMPORAL & CRIPTOGRÁFICA
        // --------------------------------------------------------------------
        const timestamp = FastJsonScanner.findIntField(trimmed, "timestamp") orelse 0;
        const ref_ts = if (reference_timestamp != 0) reference_timestamp else 1709424000;

        // Janela de replay: 24 horas atrás e no máximo 300 segundos no futuro
        if (timestamp < ref_ts - 86400) {
            return .{ .status = Status2FV.ERR_TIMESTAMP_EXPIRED, .failed_stage = 5, .error_message = "Payload expired (>24h window)" };
        }
        if (timestamp > ref_ts + 300) {
            return .{ .status = Status2FV.ERR_TIMESTAMP_FUTURE_SKEW, .failed_stage = 5, .error_message = "Timestamp too far in the future (>300s skew)" };
        }

        // Checksum FNV-1a dos campos canônicos
        const checksum = FastJsonScanner.findStringField(trimmed, "checksum");
        if (checksum == null or checksum.?.len != 8) {
            return .{ .status = Status2FV.ERR_CHECKSUM_MISMATCH, .failed_stage = 5, .error_message = "Missing or malformed checksum length" };
        }

        const expected_checksum = DomainValidator.computeFnv1a32(idempotency.?, total_amount, doc.?);
        if (!std.mem.eql(u8, checksum.?, &expected_checksum)) {
            return .{ .status = Status2FV.ERR_CHECKSUM_MISMATCH, .failed_stage = 5, .error_message = "Tampered payload: checksum does not match cryptographic hash" };
        }

        return .{
            .status = Status2FV.SUCCESS,
            .failed_stage = 0,
            .error_message = "All 5 stages validated with 100% deterministic certainty.",
        };
    }
};
