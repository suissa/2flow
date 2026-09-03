// @ts-check
const { test, expect } = require('@playwright/test');

test.describe('🛡️ 2FV (Two-Factor Validation) Pre-Flight E2E Pipeline', () => {

  test('Deve bloquear 100% dos payloads com erro no navegador e só liberar POST quando 100% válido', async ({ page }) => {
    page.on('console', msg => console.log('PAGE CONSOLE:', msg.type(), msg.text()));
    page.on('pageerror', err => console.log('PAGE ERROR:', err.message));
    page.on('requestfailed', req => console.log('REQUEST FAILED:', req.url(), req.failure()?.errorText));

    // 1. Acessa a interface de benchmark 2FV
    await page.goto('/2fv_benchmark.html');

    // 2. Aguarda a compilação e instanciação do WebAssembly
    const wasmBadge = page.locator('#wasm-status-badge');
    await expect(wasmBadge).toContainText('Ativo', { timeout: 10000 });
    console.log('⚡ [Playwright] Módulo WebAssembly 2flow.wasm inicializado no navegador com sucesso!');

    // 3. Teste Adversarial 1: Injeção XSS
    await page.click('#btn-load-xss');
    await page.click('#btn-submit-post');

    // Verifica que o Fator 1 barrou instantaneamente
    const statusBadge = page.locator('#status-badge');
    await expect(statusBadge).toContainText('BLOQUEADO');
    await expect(page.locator('#stat-post-blocked')).toHaveText('1');
    await expect(page.locator('#stat-post-sent')).toHaveText('0');
    console.log('🛡️ [Playwright] Payload XSS barrado no Fator 1: 0 requisições HTTP enviadas.');

    // 4. Teste Adversarial 2: CPF Inválido (Módulo 11)
    await page.click('#btn-load-cpf');
    await page.click('#btn-submit-post');

    await expect(statusBadge).toContainText('BLOQUEADO');
    await expect(page.locator('#stat-post-blocked')).toHaveText('2');
    await expect(page.locator('#stat-post-sent')).toHaveText('0');
    console.log('🛡️ [Playwright] CPF com Módulo 11 corrompido barrado no Fator 1: 0 requisições HTTP enviadas.');

    // 5. Executa a Bateria Completa de Testes de Quebra no Motor WASM
    await page.click('#btn-run-suite');
    const logBox = page.locator('#test-log');
    await expect(logBox).toContainText('RESULTADO FINAL DA BATERIA', { timeout: 15000 });
    await expect(logBox).toContainText('Requisições Inválidas que Atingiram o Servidor: 0 (ZERO!)');
    console.log('🧪 [Playwright] Bateria de testes de quebra executada 100% no motor WASM local!');

    // 6. Teste de Sucesso (Golden Payload 100% Válido)
    await page.click('#btn-load-valid');
    await page.click('#btn-submit-post');

    // Verifica que o Fator 1 APROVOU e o POST foi liberado para o servidor
    await expect(statusBadge).toContainText('APROVADO');
    await expect(page.locator('#stat-post-sent')).toHaveText('1');

    const statusDesc = page.locator('#status-desc');
    await expect(statusDesc).toContainText('200 OK');
    console.log('🚀 [Playwright] Payload 100% válido aprovado pelo Fator 1 e recebido pelo servidor com 200 OK!');

    // 7. Validação Final no Backend: Consulta métricas reais do servidor
    const metricsResp = await page.request.get('/api/v1/metrics');
    const metrics = await metricsResp.json();

    console.log('\n======================================================');
    console.log('📊 RELATÓRIO DE ECONOMIA DE VALIDAÇÃO NO BACKEND:');
    console.log('------------------------------------------------------');
    console.log(`  • Requisições totais recebidas pelo servidor: ${metrics.total_received}`);
    console.log(`  • Requisições inválidas que atingiram o backend: ${metrics.invalid_received} (0.0%)`);
    console.log(`  • Requisições válidas conciliadas pelo servidor: ${metrics.valid_received}`);
    console.log(`  • ECONOMIA DE PROCESSAMENTO NO BACKEND: 100% de desperdício evitado na borda!`);
    console.log('======================================================\n');

    expect(metrics.invalid_received).toBe(0);
    expect(metrics.valid_received).toBe(1);
  });

});
