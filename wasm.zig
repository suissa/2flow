const std = @import("std");

// Importa os modelos e ferramentas das pipelines de dados e de micro-empresa
const data_tools = @import("examples/data-pipeline/tools.zig");
const empresa_tools = @import("examples/empresa-agentica/tools.zig");

// ============================================================================
// MEMÓRIA E ALOCADOR LINEAR PARA WEBASSEMBLY (ZERO SYSCALLS / ZERO RUNTIME)
// ============================================================================
var wasm_heap: [128 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&wasm_heap);

pub export fn _start() void {}

/// Aloca memória na heap do WASM para o JavaScript injetar payloads
pub export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = fba.allocator().alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Libera a memória ou reseta o bump allocator após validação
pub export fn wasm_reset_heap() void {
    fba.reset();
}

// ============================================================================
// 2FV (TWO-FACTOR VALIDATION) - FATOR 1: PRE-FLIGHT NO CLIENTE (FRONTEND)
// ============================================================================

/// Códigos de Retorno Padronizados do 2FV
pub const Status2FV = struct {
    pub const SUCCESS: i32 = 1;
    pub const ERR_EMPTY_PAYLOAD: i32 = -1;
    pub const ERR_SECURITY_INJECTION: i32 = -2;
    pub const ERR_INVALID_CNPJ_FORMAT: i32 = -10;
    pub const ERR_INVALID_MONETARY_VALUE: i32 = -11;
    pub const ERR_INVALID_QUANTITY: i32 = -12;
    pub const ERR_UNKNOWN_FLOW: i32 = -99;
};

/// Validador do Data Pipeline (Fator 1)
/// Executado no Browser do cliente antes de disparar HTTP POST ao backend
pub export fn validate_2fv_data_pipeline(ptr: [*]const u8, len: usize) i32 {
    if (len == 0) return Status2FV.ERR_EMPTY_PAYLOAD;
    const raw_text = ptr[0..len];

    // Sanitização e checagem de injeção (XSS / SQLi / Byte Nulo)
    const allocator = fba.allocator();
    const sanitized = data_tools.TextSanitizerTool.sanitize(allocator, raw_text) catch {
        return Status2FV.ERR_SECURITY_INJECTION;
    };

    if (sanitized == null) {
        return Status2FV.ERR_SECURITY_INJECTION;
    }

    return Status2FV.SUCCESS;
}

/// Validador da Micro-Empresa Agêntica (Fator 1)
/// Valida CNPJ do fornecedor e coerência contábil antes de enviar pedido de compra
pub export fn validate_2fv_empresa(
    cnpj_ptr: [*]const u8,
    cnpj_len: usize,
    valor_total: f64,
    quantidade: u32,
) i32 {
    if (cnpj_len == 0) return Status2FV.ERR_EMPTY_PAYLOAD;
    const cnpj = cnpj_ptr[0..cnpj_len];

    const res = empresa_tools.FornecedorTool.homologar(cnpj, valor_total, quantidade);
    if (!res.homologado) {
        if (cnpj.len != 18) return Status2FV.ERR_INVALID_CNPJ_FORMAT;
        if (valor_total <= 0.0) return Status2FV.ERR_INVALID_MONETARY_VALUE;
        if (quantidade == 0) return Status2FV.ERR_INVALID_QUANTITY;
        return Status2FV.ERR_INVALID_CNPJ_FORMAT;
    }

    return Status2FV.SUCCESS;
}

/// Validador Universal 2FV via Payload JSON
/// Permite ao frontend validar qualquer formulário corporativo em < 0.05ms
pub export fn validate_2fv_json(ptr: [*]const u8, len: usize) i32 {
    if (len == 0) return Status2FV.ERR_EMPTY_PAYLOAD;
    const json = ptr[0..len];

    // Checagem prévia de injeção de script
    if (std.mem.indexOf(u8, json, "<script>") != null or std.mem.indexOf(u8, json, "</script>") != null) {
        return Status2FV.ERR_SECURITY_INJECTION;
    }

    // Checagem de integridade básica
    if (json[0] != '{' or json[json.len - 1] != '}') {
        return Status2FV.ERR_EMPTY_PAYLOAD;
    }

    return Status2FV.SUCCESS;
}

// ============================================================================
// VALIDADOR PESADO CORPORATIVO (ALLASCODE FINANCIAL & SECURITY 2FV)
// ============================================================================
const heavy = @import("heavy_validator.zig");

var last_validation_status: i32 = heavy.Status2FV.SUCCESS;
var last_failed_stage: u8 = 0;
var last_error_msg_buf: [256]u8 = undefined;
var last_error_msg_len: usize = 0;

/// Validador Pesado 2FV de Alta Densidade Computacional (Fator 1)
/// Executa os 5 estágios (Segurança, Schema, Fiscal Módulo 11, Ledger e Criptografia) no navegador
pub export fn validate_heavy_2fv(ptr: [*]const u8, len: usize, ref_ts: i64) i32 {
    if (len == 0) {
        last_validation_status = heavy.Status2FV.ERR_EMPTY_PAYLOAD;
        last_failed_stage = 1;
        const msg = "ERR_EMPTY_PAYLOAD";
        @memcpy(last_error_msg_buf[0..msg.len], msg);
        last_error_msg_len = msg.len;
        return last_validation_status;
    }

    const payload = ptr[0..len];
    const res = heavy.HeavyValidationPipeline.validate(payload, ref_ts);
    last_validation_status = res.status;
    last_failed_stage = res.failed_stage;

    const msg_len = @min(res.error_message.len, last_error_msg_buf.len);
    @memcpy(last_error_msg_buf[0..msg_len], res.error_message[0..msg_len]);
    last_error_msg_len = msg_len;

    return res.status;
}

pub export fn get_last_error_stage() u8 {
    return last_failed_stage;
}

pub export fn get_last_error_message(out_ptr: [*]u8, max_len: usize) usize {
    const copy_len = @min(last_error_msg_len, max_len);
    if (copy_len > 0) {
        @memcpy(out_ptr[0..copy_len], last_error_msg_buf[0..copy_len]);
    }
    return copy_len;
}

pub export fn compute_checksum_2fv(
    idemp_ptr: [*]const u8,
    idemp_len: usize,
    amount_cents: i64,
    doc_ptr: [*]const u8,
    doc_len: usize,
    out_ptr: [*]u8,
) usize {
    const idemp = idemp_ptr[0..idemp_len];
    const doc = doc_ptr[0..doc_len];
    const chk = heavy.DomainValidator.computeFnv1a32(idemp, amount_cents, doc);
    @memcpy(out_ptr[0..8], &chk);
    return 8;
}

// ============================================================================
// TESTES DO MÓDULO WASM 2FV
// ============================================================================

test "2FV WASM: Data Pipeline sanitization and injection prevention" {
    const payload_valido = "Pedido de compra normal com e-mail carlos@empresa.com";
    const status_valido = validate_2fv_data_pipeline(payload_valido.ptr, payload_valido.len);
    try std.testing.expectEqual(Status2FV.SUCCESS, status_valido);

    const payload_malicioso = "Ataque <script>alert('pwn')</script>";
    const status_malicioso = validate_2fv_data_pipeline(payload_malicioso.ptr, payload_malicioso.len);
    try std.testing.expectEqual(Status2FV.ERR_SECURITY_INJECTION, status_malicioso);

    const status_vazio = validate_2fv_data_pipeline("", 0);
    try std.testing.expectEqual(Status2FV.ERR_EMPTY_PAYLOAD, status_vazio);
}

test "2FV WASM: Empresa Agentica supplier and fiscal pre-flight" {
    const cnpj_valido = "12.345.678/0001-90";
    const s_ok = validate_2fv_empresa(cnpj_valido.ptr, cnpj_valido.len, 5000.00, 50);
    try std.testing.expectEqual(Status2FV.SUCCESS, s_ok);

    const cnpj_invalido = "12345678000190";
    const s_cnpj_err = validate_2fv_empresa(cnpj_invalido.ptr, cnpj_invalido.len, 5000.00, 50);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CNPJ_FORMAT, s_cnpj_err);

    const s_val_err = validate_2fv_empresa(cnpj_valido.ptr, cnpj_valido.len, -100.00, 50);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_MONETARY_VALUE, s_val_err);

    const s_qtd_err = validate_2fv_empresa(cnpj_valido.ptr, cnpj_valido.len, 5000.00, 0);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_QUANTITY, s_qtd_err);
}

test "2FV WASM: JSON universal validator" {
    const json_valido = "{\"item\": \"teclado\", \"qtd\": 10}";
    const s_json = validate_2fv_json(json_valido.ptr, json_valido.len);
    try std.testing.expectEqual(Status2FV.SUCCESS, s_json);

    const json_xss = "{\"payload\": \"<script>bad()</script>\"}";
    const s_xss = validate_2fv_json(json_xss.ptr, json_xss.len);
    try std.testing.expectEqual(Status2FV.ERR_SECURITY_INJECTION, s_xss);
}

test "2FV WASM: Heavy Validator 5-stage pre-flight" {
    const idemp = "550e8400-e29b-41d4-a716-446655440000";
    const doc = "123.456.789-09";
    const total: i64 = 125000;
    var chk_buf: [8]u8 = undefined;
    _ = compute_checksum_2fv(idemp.ptr, idemp.len, total, doc.ptr, doc.len, &chk_buf);

    var valid_buf: [1024]u8 = undefined;
    const valid_json = try std.fmt.bufPrint(&valid_buf,
        \\{{
        \\  "idempotency_key": "{s}",
        \\  "timestamp": 1709424000,
        \\  "account_id": "ACC-123",
        \\  "recipient_document": "{s}",
        \\  "recipient_email": "finance@empresa.com",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 125000,
        \\  "tax_amount_cents": 5000,
        \\  "items": [
        \\    {{ "sku": "A1", "name": "Item A", "quantity": 1, "unit_price_cents": 120000 }}
        \\  ],
        \\  "checksum": "{s}",
        \\  "payload_notes": "Valid"
        \\}}
    , .{ idemp, doc, &chk_buf });

    const status_ok = validate_heavy_2fv(valid_json.ptr, valid_json.len, 1709424000);
    try std.testing.expectEqual(heavy.Status2FV.SUCCESS, status_ok);

    const bad_xss = "{\"data\": \"<script>alert(1)</script>\"}";
    const status_xss = validate_heavy_2fv(bad_xss.ptr, bad_xss.len, 1709424000);
    try std.testing.expectEqual(heavy.Status2FV.ERR_XSS_DETECTED, status_xss);
    try std.testing.expectEqual(@as(u8, 1), get_last_error_stage());
}

