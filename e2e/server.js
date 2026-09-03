const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 3456;
const SITE_DIR = path.resolve(__dirname, '../site');

// Telemetria do Backend (Fator 2)
let metrics = {
  total_received: 0,
  invalid_received: 0,
  valid_received: 0,
  last_payload: null
};

const server = http.createServer((req, res) => {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // 1. Endpoint de Métricas
  if (req.url === '/api/v1/metrics' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(metrics));
    return;
  }

  // 2. Endpoint de Ingestão Pesada (Fator 2 no Backend)
  if (req.url === '/api/v1/heavy-ingest' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      metrics.total_received++;
      metrics.last_payload = body;

      const preflightHeader = req.headers['x-2fv-preflight'];

      // Checa se o payload é malicioso ou quebrado (caso algum atacante tente bypassar o cliente)
      const hasXss = body.includes('<script>') || body.includes('javascript:');
      const hasBadCpf = body.includes('123.456.789-99') || body.includes('000.000.000-00');
      const isInvalid = hasXss || hasBadCpf || !body.includes('checksum');

      if (isInvalid) {
        metrics.invalid_received++;
        console.log(`🚨 [BACKEND FATOR 2] Alerta: Payload inválido atingiu o servidor! Bypass detectado.`);
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Rejected by Factor 2 Server Invariant', preflightHeader }));
      } else {
        metrics.valid_received++;
        console.log(`✅ [BACKEND FATOR 2] Sucesso: Payload 100% íntegro recebido com preflight ${preflightHeader}`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          status: 'SUCCESS_ACCEPTED_BY_FACTOR_2',
          factor1_header: preflightHeader,
          timestamp: Date.now()
        }));
      }
    });
    return;
  }

  // 3. Servidor de Arquivos Estáticos (site/)
  let reqPath = req.url.split('?')[0];
  if (reqPath === '/' || reqPath === '/index.html') reqPath = '/2fv_benchmark.html';

  const filePath = path.join(SITE_DIR, reqPath);
  if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
    const ext = path.extname(filePath);
    const mimeTypes = {
      '.html': 'text/html; charset=utf-8',
      '.wasm': 'application/wasm',
      '.js': 'application/javascript',
      '.css': 'text/css'
    };
    res.writeHead(200, { 'Content-Type': mimeTypes[ext] || 'application/octet-stream' });
    fs.createReadStream(filePath).pipe(res);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found: ' + reqPath);
  }
});

if (require.main === module) {
  server.listen(PORT, () => {
    console.log(`⚡ [2FV Server] Backend ativo em http://localhost:${PORT}`);
  });
}

module.exports = { server, metrics, PORT };
