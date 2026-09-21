-- ╔═══════════════════════════════════════════════════════════════════════════╗
-- ║ QUARTELY DATABASE SCHEMA                                                  ║
-- ║ Database: BDIBPBMSA_PRD                                                   ║
-- ║ Purpose: Financial dashboard data structure                               ║
-- ╚═══════════════════════════════════════════════════════════════════════════╝

-- This file documents the expected database schema structure
-- All queries reference tables from IBP schema

-- Expected tables:
-- ─────────────────────────────────────────────────────────────────────────

-- 1. IBP.PEDRAVISAOCONSOLIDADA
--    Contains consolidated financial data (Budget, Supply, Real, Forecast)
--    Columns: DT_REF, ID_SISTEMA, ID_SITE, ID_OPERACAO, ID_KPI, 
--             VL_ORC, VL_SUPPLY, VL_REAL, VL_PROJ

-- 2. IBP.DASHBOARD
--    Dashboard configuration and KPI metadata
--    Columns: ID_DASH, ID_SISTEMA, ID_SITE, ID_OPERACAO, ID_KPI,
--             NM_KPIS_DASH, ID_ORDEM, VL_FATOR

-- 3. IBP.CONTROLE_PROCESSOS
--    Process control and date references
--    Columns: ID_PROCESSO, DT_INI, etc.

-- For more information, refer to the project documentation
-- in README.md and INTEGRATION.md
