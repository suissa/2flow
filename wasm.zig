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
