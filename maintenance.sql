-- ============================================================================
-- maintenance.sql  -  TP Unidad 6 - VoltTech
--
-- Revision de autovacuum/ANALYZE y UNA accion de mantenimiento segura,
-- justificada con la observacion previa:
--
--   1. Se leen los parametros de autovacuum y las transacciones largas que
--      podrian impedir la limpieza.
--   2. Se observan las tuplas muertas por tabla y se decide con un umbral
--      explicito (>= 5 % de tuplas muertas y >= 1.000 filas, o >= 10.000).
--   3. Solo para las tablas que superan el umbral se ejecuta
--      VACUUM (ANALYZE, VERBOSE) mediante \gexec. Nunca VACUUM FULL:
--      reescribe la tabla, toma ACCESS EXCLUSIVE y no es mantenimiento
--      rutinario (consigna de la Unidad 6).
--   4. Se actualizan estadisticas de tablas con ANALYZE viejo.
--   5. Se registra la accion y su resultado en mantenimiento.bitacora.
--
-- Ejecutar como propietario de las tablas (o superusuario):
--   psql -h localhost -U postgres -d volttech_u6 -X -f maintenance.sql
-- Requiere psql (usa \gexec). No elimina datos ni reconstruye tablas.
-- ============================================================================
\set ON_ERROR_STOP on
\pset border 2
\pset pager off

\echo '============================================================'
\echo ' MANTENIMIENTO - VoltTech'
SELECT now() AS momento,
       current_database() AS base,
       current_user AS usuario;

\echo ''
\echo '=== 1. CONTEXTO: PARAMETROS DE AUTOVACUUM ==='
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'autovacuum',
    'autovacuum_naptime',
    'autovacuum_vacuum_threshold',
    'autovacuum_vacuum_scale_factor',
    'autovacuum_analyze_threshold',
    'autovacuum_analyze_scale_factor',
    'autovacuum_max_workers',
    'maintenance_work_mem',
    'vacuum_cost_delay'
)
ORDER BY name;

\echo ''
\echo '--- Overrides por tabla (si existen) ---'
SELECT c.relname AS tabla,
       c.reloptions
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.reloptions IS NOT NULL
ORDER BY c.relname;

\echo ''
\echo '=== 2. TRANSACCIONES LARGAS QUE PUEDEN IMPEDIR LA LIMPIEZA ==='
SELECT pid,
       usename,
       state,
       round(extract(epoch FROM now() - xact_start) / 60.0, 1) AS minutos,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS consulta
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND pid <> pg_backend_pid()
  AND datname = current_database()
ORDER BY xact_start
LIMIT 10;

\echo ''
\echo '=== 3. OBSERVACION PREVIA Y DECISION ==='
SELECT relname AS tabla,
       n_live_tup AS vivas,
       n_dead_tup AS muertas,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS pct_muertas,
       last_autovacuum,
       last_autoanalyze,
       CASE
         WHEN n_dead_tup >= 10000 THEN 'VACUUM (ANALYZE)'
         WHEN n_dead_tup >= 1000
              AND 100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0) >= 5
              THEN 'VACUUM (ANALYZE)'
         ELSE 'ESPERAR AUTOVACUUM'
       END AS decision
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_dead_tup DESC, relname;

-- Conjunto de tablas que superan el umbral. Se guarda antes de limpiar para
-- poder registrar cuantas tuplas muertas se observaron.
DROP TABLE IF EXISTS tmp_mantenimiento;
CREATE TEMP TABLE tmp_mantenimiento AS
SELECT schemaname,
       relname,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS pct_muertas
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND (
        n_dead_tup >= 10000
        OR (n_dead_tup >= 1000
            AND 100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0) >= 5)
      );

\echo ''
\echo '--- Tablas seleccionadas para VACUUM (ANALYZE) ---'
SELECT * FROM tmp_mantenimiento ORDER BY n_dead_tup DESC;

\echo ''
\echo '=== 4. ACCION SEGURA: VACUUM (ANALYZE) SOLO EN LAS TABLAS SELECCIONADAS ==='
\echo 'Se ejecuta una sentencia por tabla. No se usa VACUUM FULL.'
\timing on
SELECT format('VACUUM (ANALYZE, VERBOSE) %I.%I;', schemaname, relname)
FROM tmp_mantenimiento
ORDER BY n_dead_tup DESC
\gexec
\timing off

\echo ''
\echo '=== 5. ESTADISTICAS: ANALYZE DE TABLAS CON ESTADISTICAS VIEJAS ==='
\echo 'ANALYZE es seguro: no toma bloqueo exclusivo ni reescribe la tabla.'
\timing on
SELECT format('ANALYZE %I.%I;', schemaname, relname)
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND (last_autoanalyze IS NULL OR last_autoanalyze < now() - interval '1 day')
ORDER BY relname
\gexec
\timing off

\echo ''
\echo '=== 6. REGISTRO EN LA BITACORA ==='
INSERT INTO mantenimiento.bitacora (tarea, fin, estado, filas, detalle)
SELECT 'mantenimiento_manual',
       clock_timestamp(),
       'OK',
       COALESCE(sum(n_dead_tup), 0),
       format('VACUUM (ANALYZE) en %s tabla(s): %s; umbral 5%%/1000 o 10000 tuplas muertas; VACUUM FULL descartado',
              count(*), COALESCE(string_agg(relname, ', ' ORDER BY relname), 'ninguna'))
FROM tmp_mantenimiento;

SELECT id, tarea, fin, estado, filas, detalle
FROM mantenimiento.bitacora
WHERE tarea = 'mantenimiento_manual'
ORDER BY id DESC
LIMIT 1;

\echo ''
\echo '=== 7. VERIFICACION POSTERIOR ==='
SELECT relname AS tabla,
       n_live_tup AS vivas,
       n_dead_tup AS muertas,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS pct_muertas,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_dead_tup DESC, relname;

\echo ''
\echo '--- Recomendacion (no ejecutada): para tablas de alta escritura conviene'
\echo '    bajar el scale factor de autovacuum en vez de vaciar manualmente cada semana.'
\echo '    Ejemplo, a evaluar con la historia real de la tabla:'
\echo '      ALTER TABLE public.linea_pedido SET (autovacuum_vacuum_scale_factor = 0.05,'
\echo '                                           autovacuum_analyze_scale_factor = 0.02);'
\echo ''
\echo '=== FIN MANTENIMIENTO ==='
