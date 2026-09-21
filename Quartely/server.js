const express = require('express');
const path = require('path');
const sql = require('mssql');
const compression = require('compression');

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

// ── Cache Management ────────────────────────────────────────────
const CACHE_TTL_MS = 5 * 60 * 1000;
const cache = new Map();

async function withCache(key, fetcher) {
  const hit = cache.get(key);
  if (hit && hit.expiresAt > Date.now()) {
    return hit.data;
  }

  const data = await fetcher();
  cache.set(key, { data, expiresAt: Date.now() + CACHE_TTL_MS });
  return data;
}

// Clear cache periodically
setInterval(() => {
  const now = Date.now();
  let cleared = 0;
  for (const [key, value] of cache.entries()) {
    if (value.expiresAt <= now) {
      cache.delete(key);
      cleared++;
    }
  }
  if (cleared > 0) {
    console.log(`[cache] Limpeza: ${cleared} itens expirados removidos`);
  }
}, 60000);

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

// Serve chart data endpoint
app.get('/api/chart-data', async (req, res) => {
  try {
    const data = await withCache('chart-data', async () => {
      const chartSql = `
DECLARE @DT_INI AS DATE, @DT_FIM AS DATE, @DT_REF AS DATE

SET @DT_INI = '2025-01-01'
SET @DT_FIM = CAST(DATEADD(MONTH, 0, CONCAT(YEAR(DATEFROMPARTS(YEAR(DATEADD(MONTH, 0, GETDATE()-1)), MONTH(DATEADD(MONTH, -1, GETDATE()-1)), 1)), '-12-01')) AS DATE)
SET @DT_REF = (SELECT DATEADD(MONTH, -1, DT_INI) AS DT_INI_MENOS_1_MES FROM IBP.CONTROLE_PROCESSOS WHERE ID_PROCESSO = 2)

-- MONTH
SELECT
  PVC.DT_REF,
  PVC.ID_SISTEMA,
  PVC.ID_SITE,
  PVC.ID_OPERACAO,
  PVC.ID_KPI,
  DASH.NM_KPIS_DASH AS 'NM_KPI',
  DASH.ID_ORDEM,
  CASE WHEN UnpivotedData.Type = 'Budget' THEN 0
    WHEN UnpivotedData.Type = 'Supply' THEN 1
    ELSE 2 END AS 'ORDEM_GRAFICO',
  CASE WHEN UnpivotedData.Type = 'Budget' THEN 0
    WHEN UnpivotedData.Type = 'Supply' THEN 2
    ELSE 1 END AS 'ID_TYPE',
  CASE WHEN UnpivotedData.Type = 'Budget' THEN 'Budget'
    WHEN UnpivotedData.Type = 'Supply' THEN 'Plan'
    ELSE 'Act/Fcst' END AS 'NM_TYPE',
  CASE WHEN UnpivotedData.Type = 'Budget' THEN CONCAT(FORMAT(DT_REF, 'MMM'),' B')
    WHEN UnpivotedData.Type = 'Supply' THEN CONCAT(FORMAT(DT_REF, 'MMM'),' P')
    WHEN UnpivotedData.Type = 'Forecast'  AND PVC.DT_REF <= @DT_REF THEN CONCAT(FORMAT(DT_REF, 'MMM'),' A')
    WHEN UnpivotedData.Type = 'Forecast'  THEN CONCAT(FORMAT(DT_REF, 'MMM'),' F')
  END AS 'Type',
  CASE WHEN UnpivotedData.Value IS NULL THEN 0 ELSE UnpivotedData.Value END AS [Value]
FROM
  IBP.PEDRAVISAOCONSOLIDADA PVC
  INNER JOIN IBP.DASHBOARD DASH
    ON PVC.ID_SISTEMA = DASH.ID_SISTEMA
    AND CONCAT(PVC.ID_SITE, PVC.ID_OPERACAO, PVC.ID_KPI) = CONCAT(DASH.ID_SITE, DASH.ID_OPERACAO, DASH.ID_KPI)
  CROSS APPLY (
    SELECT 'Budget' AS Type, PVC.VL_ORC  * DASH.VL_FATOR AS Value
    UNION ALL
    SELECT 'Supply' AS Type, PVC.VL_SUPPLY  * DASH.VL_FATOR AS Value
    UNION ALL
    SELECT 'Forecast' AS Type,
    CASE WHEN PVC.DT_REF <= DATEFROMPARTS(YEAR(DATEADD(MONTH, -1, @DT_REF)), MONTH(DATEADD(MONTH, -1, @DT_REF)), 1) AND PVC.VL_REAL IS NULL THEN 0
      WHEN PVC.DT_REF <= DATEFROMPARTS(YEAR(DATEADD(MONTH, -1, @DT_REF)), MONTH(DATEADD(MONTH, -1, @DT_REF)), 1) AND PVC.VL_REAL IS NOT NULL THEN PVC.VL_REAL  * DASH.VL_FATOR
    ELSE PVC.VL_PROJ  * DASH.VL_FATOR END AS Value
  ) AS UnpivotedData
WHERE
  PVC.DT_REF  BETWEEN @DT_INI  AND @DT_FIM
  AND DASH.ID_DASH = 21

UNION ALL

-- QUARTER
SELECT
  DATEADD(
    QUARTER,
    DATEDIFF(QUARTER, 0, PVC.DT_REF),
    0
  ) AS DT_REF,
  PVC.ID_SISTEMA,
  PVC.ID_SITE,
  PVC.ID_OPERACAO,
  PVC.ID_KPI,
  DASH.NM_KPIS_DASH AS 'NM_KPI',
  DASH.ID_ORDEM,
  CASE
    WHEN UnpivotedData.Type = 'Budget' THEN 0
    WHEN UnpivotedData.Type = 'Supply' THEN 1
    ELSE 2
  END AS 'ORDEM_GRAFICO',
  CASE
    WHEN UnpivotedData.Type = 'Budget' THEN 0
    WHEN UnpivotedData.Type = 'Supply' THEN 2
    ELSE 1
  END AS 'ID_TYPE',
  CASE
    WHEN UnpivotedData.Type = 'Budget' THEN 'Budget'
    WHEN UnpivotedData.Type = 'Supply' THEN 'Plan'
    ELSE 'Act/Fcst'
  END AS 'NM_TYPE',
  CASE
    WHEN UnpivotedData.Type = 'Budget' THEN CONCAT('Q', DATEPART(QUARTER, DT_REF), ' B')
    WHEN UnpivotedData.Type = 'Supply' THEN CONCAT('Q', DATEPART(QUARTER, DT_REF), ' P')
    WHEN UnpivotedData.Type = 'Forecast' AND PVC.DT_REF <= @DT_REF THEN CONCAT('Q', DATEPART(QUARTER, DT_REF), 'A')
    WHEN UnpivotedData.Type = 'Forecast' THEN CONCAT('Q', DATEPART(QUARTER, DT_REF), 'F')
  END AS 'Type',
  CASE WHEN UnpivotedData.Value IS NULL THEN 0 ELSE UnpivotedData.Value END AS [Value]
FROM
  IBP.PEDRAVISAOCONSOLIDADA PVC
  INNER JOIN IBP.DASHBOARD DASH
    ON PVC.ID_SISTEMA = DASH.ID_SISTEMA
    AND CONCAT(PVC.ID_SITE, PVC.ID_OPERACAO, PVC.ID_KPI) = CONCAT(DASH.ID_SITE, DASH.ID_OPERACAO, DASH.ID_KPI)
  CROSS APPLY (
    SELECT 'Budget' AS Type, PVC.VL_ORC  * DASH.VL_FATOR AS Value
    UNION ALL
    SELECT 'Supply' AS Type, PVC.VL_SUPPLY  * DASH.VL_FATOR AS Value
    UNION ALL
    SELECT 'Forecast' AS Type,
    CASE
      WHEN PVC.DT_REF <= DATEFROMPARTS(YEAR(DATEADD(MONTH, -1, @DT_REF)), MONTH(DATEADD(MONTH, -1, @DT_REF)), 1) AND PVC.VL_REAL IS NULL THEN 0
      WHEN PVC.DT_REF <= DATEFROMPARTS(YEAR(DATEADD(MONTH, -1, @DT_REF)), MONTH(DATEADD(MONTH, -1, @DT_REF)), 1) AND PVC.VL_REAL IS NOT NULL THEN PVC.VL_REAL  * DASH.VL_FATOR
      ELSE PVC.VL_PROJ  * DASH.VL_FATOR
    END AS Value
  ) AS UnpivotedData
WHERE
  PVC.DT_REF BETWEEN @DT_INI AND @DT_FIM
  AND DASH.ID_DASH = 21
ORDER BY DT_REF, ORDEM_GRAFICO`;
      return await executeQuery(chartSql);
    });

    res.json(data);
  } catch (err) {
    console.error('[api] Error fetching chart data:', err.message);
    res.status(500).json({ error: 'Failed to fetch chart data' });
  }
});

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

// Clear cache endpoint
app.post('/api/cache/clear', (req, res) => {
  cache.clear();
  res.json({ message: 'Cache cleared' });
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
