const std = @import("std");
const heavy = @import("../heavy_validator.zig");
const Status2FV = heavy.Status2FV;
const DomainValidator = heavy.DomainValidator;
const HeavyValidationPipeline = heavy.HeavyValidationPipeline;

// Timestamp de referência para testes reprodutíveis
const REF_TIMESTAMP: i64 = 1709424000;

// Gerador auxiliar de payload canônico válido
fn createValidCpfPayload(allocator: std.mem.Allocator) ![]u8 {
    // CPF Válido: 123.456.789-09
    // Idempotency: 550e8400-e29b-41d4-a716-446655440000
    // Total: 125000 cents (R$ 1.250,00)
    // Items: 1 item de 120000 cents (R$ 1.200,00)
    // Tax: 5000 cents (R$ 50,00)
    // Ledger: 120000 + 5000 = 125000 (OK)
    const idempotency = "550e8400-e29b-41d4-a716-446655440000";
    const doc = "123.456.789-09";
    const total_cents: i64 = 125000;
    const checksum = DomainValidator.computeFnv1a32(idempotency, total_cents, doc);

    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "idempotency_key": "{s}",
        \\  "timestamp": {d},
        \\  "account_id": "ACC-CORP-987123",
        \\  "recipient_document": "{s}",
        \\  "recipient_email": "financeiro@empresa.com.br",
        \\  "currency": "BRL",
        \\  "total_amount_cents": {d},
        \\  "tax_amount_cents": 5000,
        \\  "items": [
        \\    {{ "sku": "2FLOW-CORE", "name": "Licenca Core", "quantity": 1, "unit_price_cents": 120000 }}
        \\  ],
        \\  "checksum": "{s}",
        \\  "payload_notes": "Aprovacao contabil automatica 2FV"
        \\}}
    , .{ idempotency, REF_TIMESTAMP, doc, total_cents, &checksum });
}

fn createValidCnpjPayload(allocator: std.mem.Allocator) ![]u8 {
    // CNPJ Válido: 12.345.678/0001-90 (ou 11.222.333/0001-81)
    // Vamos usar 11.222.333/0001-81:
    // Pesos1: 5*1+4*1+3*2+2*2+9*2+8*3+7*3+6*3+5*0+4*0+3*0+2*1 = 5+4+6+4+18+24+21+18+0+0+0+2 = 102 % 11 = 3 -> 11-3 = 8
    // Pesos2: 6*1+5*1+4*2+3*2+2*2+9*3+8*3+7*3+6*0+5*0+4*0+3*1+2*8 = 6+5+8+6+4+27+24+21+0+0+0+3+16 = 120 % 11 = 10 -> 11-10 = 1
    const idempotency = "a0b1c2d3-e4f5-4a6b-8c9d-0e1f2a3b4c5d";
    const doc = "11.222.333/0001-81";
    const total_cents: i64 = 250000;
    const checksum = DomainValidator.computeFnv1a32(idempotency, total_cents, doc);

    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "idempotency_key": "{s}",
        \\  "timestamp": {d},
        \\  "account_id": "ACC-CORP-445566",
        \\  "recipient_document": "{s}",
        \\  "recipient_email": "suprimentos@fornecedor.com.br",
        \\  "currency": "BRL",
        \\  "total_amount_cents": {d},
        \\  "tax_amount_cents": 10000,
        \\  "items": [
        \\    {{ "sku": "ITM-01", "name": "Servidor Rack 1U", "quantity": 2, "unit_price_cents": 120000 }}
        \\  ],
        \\  "checksum": "{s}",
        \\  "payload_notes": "Compra faturada via CNPJ homologado"
        \\}}
    , .{ idempotency, REF_TIMESTAMP, doc, total_cents, &checksum });
}

// ============================================================================
// BATERIA DE TESTES DE QUEBRA: ESTÁGIO 1 - SEGURANÇA E CORRUPÇÃO BINÁRIA
// ============================================================================

test "BREAK-01: Empty payload rejection" {
    const res = HeavyValidationPipeline.validate("", REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_EMPTY_PAYLOAD, res.status);
    try std.testing.expectEqual(@as(u8, 1), res.failed_stage);
}

test "BREAK-02: Null byte injection in middle of stream" {
    const malicious = "{\"idempotency_key\":\x00\"bad\"}";
    const res = HeavyValidationPipeline.validate(malicious, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_NULL_BYTE_INJECTION, res.status);
}

test "BREAK-03: Null byte injection at start of stream" {
    const malicious = "\x00{\"idempotency_key\":\"bad\"}";
    const res = HeavyValidationPipeline.validate(malicious, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_NULL_BYTE_INJECTION, res.status);
}

test "BREAK-04: Invalid UTF-8 orphaned continuation byte" {
    const bad_utf8 = "{\"data\": \"\x80\xBF\"}";
    const res = HeavyValidationPipeline.validate(bad_utf8, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UTF8, res.status);
}

test "BREAK-05: Invalid UTF-8 truncated 2-byte sequence" {
    const bad_utf8 = "{\"data\": \"\xC2\"}";
    const res = HeavyValidationPipeline.validate(bad_utf8, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UTF8, res.status);
}

test "BREAK-06: Invalid UTF-8 overlong 2-byte sequence (C0 AF)" {
    const bad_utf8 = "{\"data\": \"\xC0\xAF\"}";
    const res = HeavyValidationPipeline.validate(bad_utf8, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UTF8, res.status);
}

test "BREAK-07: Invalid UTF-8 overlong 3-byte sequence (E0 80 AF)" {
    const bad_utf8 = "{\"data\": \"\xE0\x80\xAF\"}";
    const res = HeavyValidationPipeline.validate(bad_utf8, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UTF8, res.status);
}

test "BREAK-08: Invalid UTF-8 UTF-16 surrogate (ED A0 80)" {
    const bad_utf8 = "{\"data\": \"\xED\xA0\x80\"}";
    const res = HeavyValidationPipeline.validate(bad_utf8, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UTF8, res.status);
}

test "BREAK-09: Invalid UTF-8 out-of-range byte (F5)" {
    const bad_utf8 = "{\"data\": \"\xF5\x80\x80\x80\"}";
    const res = HeavyValidationPipeline.validate(bad_utf8, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UTF8, res.status);
}

test "BREAK-10: XSS attack via script tags" {
    const p = "{\"notes\": \"<script>alert('pwn')</script>\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_XSS_DETECTED, res.status);
}

test "BREAK-11: XSS attack via uppercase SCRIPT tags" {
    const p = "{\"notes\": \"<SCRIPT SRC='//evil.com/xss.js'></SCRIPT>\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_XSS_DETECTED, res.status);
}

test "BREAK-12: XSS attack via javascript pseudo-protocol" {
    const p = "{\"url\": \"javascript:stealTokens()\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_XSS_DETECTED, res.status);
}

test "BREAK-13: XSS attack via onerror handler" {
    const p = "{\"img\": \"<img src=x onerror=alert(1)>\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_XSS_DETECTED, res.status);
}

test "BREAK-14: XSS attack via iframe injection" {
    const p = "{\"embed\": \"<iframe src='http://attacker.com'></iframe>\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_XSS_DETECTED, res.status);
}

test "BREAK-15: XSS attack via svg onload handler" {
    const p = "{\"badge\": \"<svg onload=alert(document.cookie)>\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_XSS_DETECTED, res.status);
}

test "BREAK-16: SQL injection via ' OR '1'='1" {
    const p = "{\"account_id\": \"admin' or '1'='1\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_SQLI_DETECTED, res.status);
}

test "BREAK-17: SQL injection via double quote \" OR 1=1" {
    const p = "{\"account_id\": \"admin\" or 1=1\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_SQLI_DETECTED, res.status);
}

test "BREAK-18: SQL injection via UNION SELECT" {
    const p = "{\"account_id\": \"1 UNION SELECT * FROM secret_keys\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_SQLI_DETECTED, res.status);
}

test "BREAK-19: SQL injection via comment sequence --" {
    const p = "{\"account_id\": \"admin'--\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_SQLI_DETECTED, res.status);
}

test "BREAK-20: SQL injection via multiline comment /* */" {
    const p = "{\"account_id\": \"admin' /* bypass */\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_SQLI_DETECTED, res.status);
}

test "BREAK-21: SQL injection via DROP TABLE command" {
    const p = "{\"account_id\": \"test; drop table ledger;\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_SQLI_DETECTED, res.status);
}

test "BREAK-22: Path traversal unix relative ../../etc" {
    const p = "{\"file_ref\": \"../../etc/shadow\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_PATH_TRAVERSAL, res.status);
}

test "BREAK-23: Path traversal windows relative ..\\..\\system32" {
    const p = "{\"file_ref\": \"..\\..\\windows\\system32\\cmd.exe\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_PATH_TRAVERSAL, res.status);
}

test "BREAK-24: Path traversal direct /etc/passwd" {
    const p = "{\"file_ref\": \"/etc/passwd\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_PATH_TRAVERSAL, res.status);
}

test "BREAK-25: OS command injection ; rm -rf" {
    const p = "{\"param\": \"test; rm -rf /var/data\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_CMD_INJECTION, res.status);
}

test "BREAK-26: OS command injection pipe | ls" {
    const p = "{\"param\": \"query | ls -la\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_CMD_INJECTION, res.status);
}

test "BREAK-27: OS command injection subshell $(whoami)" {
    const p = "{\"param\": \"user_$(whoami)\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_CMD_INJECTION, res.status);
}

test "BREAK-28: OS command injection backticks `whoami`" {
    const p = "{\"param\": \"user_`whoami`\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_CMD_INJECTION, res.status);
}

// ============================================================================
// BATERIA DE TESTES DE QUEBRA: ESTÁGIO 2 - SINTAXE, SCHEMA E UUID/EMAIL
// ============================================================================

test "BREAK-29: Malformed JSON missing closing brace" {
    const p = "{\"idempotency_key\": \"550e8400-e29b-41d4-a716-446655440000\"";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_JSON_MALFORMED, res.status);
}

test "BREAK-30: Malformed JSON plain text" {
    const p = "not a valid json payload at all";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_JSON_MALFORMED, res.status);
}

test "BREAK-31: Missing idempotency_key" {
    const p = "{\"account_id\": \"ACC-1\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_MISSING_REQUIRED_FIELD, res.status);
}

test "BREAK-32: UUIDv4 wrong length (35 chars)" {
    const p = "{\"idempotency_key\": \"550e8400-e29b-41d4-a716-44665544000\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UUID_FORMAT, res.status);
}

test "BREAK-33: UUIDv4 missing hyphens" {
    const p = "{\"idempotency_key\": \"550e8400e29b41d4a7164466554400001234\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UUID_FORMAT, res.status);
}

test "BREAK-34: UUIDv4 non-hex characters" {
    const p = "{\"idempotency_key\": \"550e8400-e29b-41d4-a716-44665544000z\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UUID_FORMAT, res.status);
}

test "BREAK-35: UUIDv4 wrong version digit (version 3 instead of 4)" {
    const p = "{\"idempotency_key\": \"550e8400-e29b-31d4-a716-446655440000\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UUID_FORMAT, res.status);
}

test "BREAK-36: UUIDv4 wrong variant bits (0 instead of 8,9,a,b)" {
    const p = "{\"idempotency_key\": \"550e8400-e29b-41d4-0716-446655440000\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_UUID_FORMAT, res.status);
}

test "BREAK-37: Missing recipient_email" {
    const p = "{\"idempotency_key\": \"550e8400-e29b-41d4-a716-446655440000\"}";
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_MISSING_REQUIRED_FIELD, res.status);
}

test "BREAK-38: Malformed email missing @ symbol" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user.empresa.com.br"
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_EMAIL_FORMAT, res.status);
}

test "BREAK-39: Malformed email multiple @ symbols" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@@empresa.com.br"
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_EMAIL_FORMAT, res.status);
}

test "BREAK-40: Malformed email consecutive dots" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user..name@empresa.com.br"
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_EMAIL_FORMAT, res.status);
}

test "BREAK-41: Malformed email missing domain dot" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@localhost"
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_EMAIL_FORMAT, res.status);
}

// ============================================================================
// BATERIA DE TESTES DE QUEBRA: ESTÁGIO 3 - DOMÍNIO FISCAL (CPF/CNPJ E MOEDA)
// ============================================================================

test "BREAK-42: CPF with letters rejection" {
    const doc_status = DomainValidator.validateDocument("123.456.78A-00");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_DOCUMENT_FORMAT, doc_status);
}

test "BREAK-43: CPF all identical digits 000.000.000-00" {
    const doc_status = DomainValidator.validateDocument("000.000.000-00");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CPF_CHECKSUM, doc_status);
}

test "BREAK-44: CPF all identical digits 111.111.111-11" {
    const doc_status = DomainValidator.validateDocument("111.111.111-11");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CPF_CHECKSUM, doc_status);
}

test "BREAK-45: CPF all identical digits 999.999.999-99" {
    const doc_status = DomainValidator.validateDocument("999.999.999-99");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CPF_CHECKSUM, doc_status);
}

test "BREAK-46: CPF invalid first check digit (123.456.789-19 em vez de 09)" {
    const doc_status = DomainValidator.validateDocument("123.456.789-19");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CPF_CHECKSUM, doc_status);
}

test "BREAK-47: CPF invalid second check digit (123.456.789-08 em vez de 09)" {
    const doc_status = DomainValidator.validateDocument("123.456.789-08");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CPF_CHECKSUM, doc_status);
}

test "BREAK-48: CNPJ all identical digits 00.000.000/0000-00" {
    const doc_status = DomainValidator.validateDocument("00.000.000/0000-00");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CNPJ_CHECKSUM, doc_status);
}

test "BREAK-49: CNPJ invalid first check digit" {
    // Correto é 11.222.333/0001-81 -> Vamos alterar para 91
    const doc_status = DomainValidator.validateDocument("11.222.333/0001-91");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CNPJ_CHECKSUM, doc_status);
}

test "BREAK-50: CNPJ invalid second check digit" {
    // Correto é 11.222.333/0001-81 -> Vamos alterar para 82
    const doc_status = DomainValidator.validateDocument("11.222.333/0001-82");
    try std.testing.expectEqual(Status2FV.ERR_INVALID_CNPJ_CHECKSUM, doc_status);
}

test "BREAK-51: Unsupported currency XYZ" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "XYZ"
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_UNSUPPORTED_CURRENCY, res.status);
}

test "BREAK-52: Negative total amount" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": -5000
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_ZERO_OR_NEGATIVE_AMOUNT, res.status);
}

test "BREAK-53: Zero total amount" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 0
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_ZERO_OR_NEGATIVE_AMOUNT, res.status);
}

test "BREAK-54: Transaction exceeds operational ceiling (> 100_000_000 cents)" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 150000000
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_EXCEEDED_MAX_TRANSACTION, res.status);
}

// ============================================================================
// BATERIA DE TESTES DE QUEBRA: ESTÁGIO 4 - CONCILIAÇÃO CONTÁBIL E ITENS
// ============================================================================

test "BREAK-55: Missing items array" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 10000,
        \\  "tax_amount_cents": 500
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_MISSING_REQUIRED_FIELD, res.status);
}

test "BREAK-56: Empty items array []" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 10000,
        \\  "tax_amount_cents": 500,
        \\  "items": []
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_EMPTY_ITEMS_ARRAY, res.status);
}

test "BREAK-57: Item with zero quantity" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 10000,
        \\  "tax_amount_cents": 0,
        \\  "items": [
        \\    { "sku": "A1", "name": "Item A", "quantity": 0, "unit_price_cents": 10000 }
        \\  ]
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_ITEM_QUANTITY, res.status);
}

test "BREAK-58: Item with negative unit price" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 10000,
        \\  "tax_amount_cents": 0,
        \\  "items": [
        \\    { "sku": "A1", "name": "Item A", "quantity": 1, "unit_price_cents": -500 }
        \\  ]
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_INVALID_ITEM_PRICE, res.status);
}

test "BREAK-59: Ledger sum mismatch (sum of items != total)" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 50000,
        \\  "tax_amount_cents": 5000,
        \\  "items": [
        \\    { "sku": "A1", "name": "Item A", "quantity": 1, "unit_price_cents": 10000 }
        \\  ]
        \\}
    ;
    // 10000 (item) + 5000 (tax) = 15000 != 50000 (total)
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_LEDGER_SUM_MISMATCH, res.status);
}

// ============================================================================
// BATERIA DE TESTES DE QUEBRA: ESTÁGIO 5 - REPLAY TEMPORAL E ADULTERAÇÃO
// ============================================================================

test "BREAK-60: Expired timestamp (> 24h old replay attack)" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 10000,
        \\  "tax_amount_cents": 0,
        \\  "items": [
        \\    { "sku": "A1", "name": "Item A", "quantity": 1, "unit_price_cents": 10000 }
        \\  ],
        \\  "timestamp": 1709300000
        \\}
    ;
    // 1709300000 é muito anterior a (1709424000 - 86400)
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_TIMESTAMP_EXPIRED, res.status);
}

test "BREAK-61: Future timestamp (> 300s clock skew)" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 10000,
        \\  "tax_amount_cents": 0,
        \\  "items": [
        \\    { "sku": "A1", "name": "Item A", "quantity": 1, "unit_price_cents": 10000 }
        \\  ],
        \\  "timestamp": 1709425000
        \\}
    ;
    // 1709425000 está 1000s no futuro (limite é +300s)
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_TIMESTAMP_FUTURE_SKEW, res.status);
}

test "BREAK-62: Tampered payload with forged checksum" {
    const p =
        \\{
        \\  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
        \\  "recipient_email": "user@empresa.com.br",
        \\  "account_id": "ACC-1",
        \\  "recipient_document": "123.456.789-09",
        \\  "currency": "BRL",
        \\  "total_amount_cents": 10000,
        \\  "tax_amount_cents": 0,
        \\  "items": [
        \\    { "sku": "A1", "name": "Item A", "quantity": 1, "unit_price_cents": 10000 }
        \\  ],
        \\  "timestamp": 1709424000,
        \\  "checksum": "00000000"
        \\}
    ;
    const res = HeavyValidationPipeline.validate(p, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.ERR_CHECKSUM_MISMATCH, res.status);
}

// ============================================================================
// CASOS DE SUCESSO: PAYLOADS 100% VÁLIDOS E APROVADOS PELO 2FV
// ============================================================================

test "GOLDEN-01: Valid CPF payload full pipeline pass" {
    const payload = try createValidCpfPayload(std.testing.allocator);
    defer std.testing.allocator.free(payload);

    const res = HeavyValidationPipeline.validate(payload, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.SUCCESS, res.status);
    try std.testing.expectEqual(@as(u8, 0), res.failed_stage);
}

test "GOLDEN-02: Valid CNPJ payload full pipeline pass" {
    const payload = try createValidCnpjPayload(std.testing.allocator);
    defer std.testing.allocator.free(payload);

    const res = HeavyValidationPipeline.validate(payload, REF_TIMESTAMP);
    try std.testing.expectEqual(Status2FV.SUCCESS, res.status);
    try std.testing.expectEqual(@as(u8, 0), res.failed_stage);
}
