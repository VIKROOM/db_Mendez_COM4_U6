-- ============================================================================
-- health_check.sql  -  TP Unidad 6 - VoltTech
--
-- Chequeo de salud reproducible. Controles minimos exigidos:
--   1. Tamano de la base (y de sus tablas).
--   2. Actividad de conexiones y transacciones.
--   3. Estado de tablas: tuplas vivas/muertas, autovacuum y estadisticas.
--   4. Consultas activas y bloqueos.
-- Complementos: sesiones idle in transaction, edad de XID y antiguedad del
-- ultimo respaldo OK registrado en la bitacora.
--
-- Se ejecuta sobre la base actual (sirve para volttech_u6 y para
-- volttech_u6_restore_test) con un rol de monitoreo:
--   psql -h localhost -U mant_monitor -d volttech_u6 -X -f health_check.sql
-- No modifica datos.
-- ============================================================================
\set ON_ERROR_STOP on
\pset border 2
\pset pager off
\pset null '(null)'

\echo '============================================================'
\echo ' HEALTH CHECK - VoltTech'
SELECT now() AS momento,
       current_database() AS base,
       current_user AS usuario,
       version() AS motor;

\echo ''
\echo '=== 1. TAMANO DE LA BASE Y DE LAS TABLAS ==='
SELECT pg_size_pretty(pg_database_size(current_database())) AS tamano_base,
       pg_size_pretty(pg_database_size(current_database()) -
                      pg_database_size('postgres')) AS diferencia_vs_postgres;

SELECT relname AS tabla,
       pg_size_pretty(pg_total_relation_size(relid)) AS tamano_total,
       pg_size_pretty(pg_relation_size(relid))       AS solo_tabla,
       pg_size_pretty(pg_indexes_size(relid))        AS indices,
       n_live_tup AS filas_vivas
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 10;

\echo ''
\echo '=== 2. CONEXIONES Y ACTIVIDAD ==='
SELECT numbackends AS conexiones_actuales,
       current_setting('max_connections')::int AS max_conexiones,
       round(100.0 * numbackends / current_setting('max_connections')::int, 2) AS pct_conexiones,
       xact_commit,
       xact_rollback,
       round(100.0 * xact_rollback / NULLIF(xact_commit + xact_rollback, 0), 2) AS pct_rollback,
       blks_read,
       blks_hit,
       round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
       deadlocks,
       pg_size_pretty(temp_bytes) AS temp_usado
FROM pg_stat_database
WHERE datname = current_database();

SELECT COALESCE(state, '(sin estado)') AS estado,
       count(*) AS sesiones,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state
ORDER BY sesiones DESC;

SELECT pid,
       usename,
       state,
       round(extract(epoch FROM now() - xact_start) / 60.0, 1) AS minutos_transaccion,
       wait_event_type,
       wait_event
FROM pg_stat_activity
WHERE datname = current_database()
  AND xact_start IS NOT NULL
  AND pid <> pg_backend_pid()
ORDER BY xact_start
LIMIT 5;

\echo ''
\echo '=== 3. ESTADO DE TABLAS, AUTOVACUUM Y ESTADISTICAS ==='
SELECT relname AS tabla,
       n_live_tup AS vivas,
       n_dead_tup AS muertas,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS pct_muertas,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze,
       vacuum_count,
       autovacuum_count,
       seq_scan,
       idx_scan
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_dead_tup DESC, relname;

\echo ''
\echo '=== 4. CONSULTAS ACTIVAS ==='
SELECT pid,
       usename,
       state,
       wait_event_type,
       wait_event,
       round(extract(epoch FROM now() - query_start), 1) AS segundos,
       left(regexp_replace(query, '\s+', ' ', 'g'), 140) AS consulta
FROM pg_stat_activity
WHERE datname = current_database()
  AND state <> 'idle'
  AND pid <> pg_backend_pid()
ORDER BY query_start;

\echo ''
\echo '--- Sesiones idle in transaction (riesgo de bloquear VACUUM) ---'
SELECT pid, usename,
       round(extract(epoch FROM now() - state_change), 1) AS segundos_inactiva,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS ultima_consulta
FROM pg_stat_activity
WHERE datname = current_database()
  AND state = 'idle in transaction'
ORDER BY state_change;

\echo ''
\echo '--- Bloqueos: sesiones que esperan por otra ---'
SELECT a.pid AS bloqueada,
       a.usename,
       a.state,
       a.wait_event_type,
       a.wait_event,
       pg_blocking_pids(a.pid) AS pids_bloqueantes,
       left(regexp_replace(a.query, '\s+', ' ', 'g'), 120) AS consulta
FROM pg_stat_activity a
WHERE a.datname = current_database()
  AND cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY a.pid;

\echo ''
\echo '=== 5. EDAD DE XID (WRAPAROUND) ==='
SELECT datname AS base,
       age(datfrozenxid) AS edad_xid,
       current_setting('autovacuum_freeze_max_age')::bigint AS limite_freeze,
       round(100.0 * age(datfrozenxid) /
             current_setting('autovacuum_freeze_max_age')::bigint, 2) AS pct_consumido
FROM pg_database
WHERE datname = current_database();

\echo ''
\echo '=== 6. ANTIGUEDAD DEL ULTIMO RESPALDO OK ==='
DO $$
DECLARE
    v_fin   TIMESTAMPTZ;
    v_horas NUMERIC;
BEGIN
    IF to_regclass('mantenimiento.bitacora') IS NULL THEN
        RAISE NOTICE 'Esquema mantenimiento no instalado: sin dato de respaldo.';
        RETURN;
    END IF;
    EXECUTE $q$
        SELECT max(fin) FROM mantenimiento.bitacora
        WHERE tarea = 'respaldo_logico' AND estado = 'OK'
    $q$ INTO v_fin;
    IF v_fin IS NULL THEN
        RAISE NOTICE 'No hay respaldos OK registrados en la bitacora.';
    ELSE
        v_horas := round(extract(epoch FROM now() - v_fin) / 3600.0, 2);
        RAISE NOTICE 'Ultimo respaldo OK: % (% horas de antiguedad)', v_fin, v_horas;
    END IF;
END $$;

\echo ''
\echo '=== FIN HEALTH CHECK ==='
