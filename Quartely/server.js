const express = require('express');
const path = require('path');
const sql = require('mssql');
const compression = require('compression');
const { criarQuartelyRouter } = require('./quartely-api');

const app = express();

// Middleware
app.use(compression());
app.use(express.json());

// Serve static files
app.use(express.static(__dirname, {
  etag: false,
  index: false,
  setHeaders: (res) => res.set('Cache-Control', 'no-store'),
}));

// ── Azure SQL Configuration ──────────────────────────────────────
const sqlConfig = {
  server: process.env.AZURE_SQL_SERVER,
  database: process.env.AZURE_SQL_DATABASE,
  authentication: {
    type: 'default',
    options: {
      userName: process.env.AZURE_SQL_USER,
      password: process.env.AZURE_SQL_PASSWORD,
    },
  },
  options: {
    port: parseInt(process.env.AZURE_SQL_PORT || '1433', 10),
    encrypt: true,
    trustServerCertificate: false,
    connectionTimeout: 30000,
    requestTimeout: 30000,
  },
};

let pool = null;

// ── Connection Management ────────────────────────────────────────
async function initializePool() {
  if (pool) return pool;

  const missingVars = [
    !process.env.AZURE_SQL_SERVER && 'AZURE_SQL_SERVER',
    !process.env.AZURE_SQL_DATABASE && 'AZURE_SQL_DATABASE',
    !process.env.AZURE_SQL_USER && 'AZURE_SQL_USER',
    !process.env.AZURE_SQL_PASSWORD && 'AZURE_SQL_PASSWORD',
  ].filter(Boolean);

  if (missingVars.length) {
    throw new Error(`Variáveis de ambiente ausentes: ${missingVars.join(', ')}`);
  }

  try {
    pool = new sql.ConnectionPool(sqlConfig);
    pool.on('error', err => {
      console.error('[sql] Pool error:', err);
      pool = null;
    });

    await pool.connect();
    console.log('[sql] Conexão com Azure SQL estabelecida');
    return pool;
  } catch (err) {
    console.error('[sql] Erro ao conectar:', err);
    pool = null;
    throw err;
  }
}

async function closePool() {
  if (pool) {
    try {
      await pool.close();
      pool = null;
      console.log('[sql] Pool de conexão fechado');
    } catch (err) {
      console.error('[sql] Erro ao fechar pool:', err);
    }
  }
}

// ── Query Execution ─────────────────────────────────────────────
async function executeQuery(sql) {
  const tQuery = Date.now();
  try {
    const p = await initializePool();
    const request = p.request();
    const result = await request.query(sql);
    const duration = Date.now() - tQuery;
    const firstLine = sql.trim().split('\n')[0].trim().slice(0, 48);
    console.log(`[sql] query=${duration}ms linhas=${result.recordset.length} :: ${firstLine}`);
    return result.recordset;
  } catch (err) {
    console.error('[sql] Query error:', err.message);
    throw err;
  }
}

// ── API Routes ──────────────────────────────────────────────────

// Serve index.html
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

// ── Rotas de dados ──────────────────────────────────────────────
// Mesmas rotas (/api/chart-data, /api/sites, /api/ping) e MESMA SQL
// usadas pelo app publicado: ambas vêm de quartely-api.js, para que
// editar a query aqui e não ver efeito em produção deixe de ser
// possível. O pool é o deste processo — só o adaptador muda, porque o
// módulo espera o formato do `mssql` ({ recordset }).
app.use('/api', criarQuartelyRouter({
  runQuery: async (query) => ({ recordset: await executeQuery(query) }),
}));

// Health check endpoint
app.get('/api/health', async (req, res) => {
  try {
    const p = await initializePool();
    const request = p.request();
    await request.query('SELECT 1 AS status');
    res.json({ status: 'healthy', database: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'unhealthy', error: err.message });
  }
});

// ── Error Handling ──────────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('[error]', err);
  res.status(500).json({ error: 'Internal server error' });
});

// ── Server Startup ──────────────────────────────────────────────
const PORT = process.env.PORT || 8000;

const server = app.listen(PORT, () => {
  console.log(`[server] Quartely Dashboard listening on port ${PORT}`);
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('[server] SIGTERM received, shutting down gracefully');
  server.close(async () => {
    await closePool();
    process.exit(0);
  });
});

process.on('SIGINT', async () => {
  console.log('[server] SIGINT received, shutting down gracefully');
  server.close(async () => {
    await closePool();
    process.exit(0);
  });
});
