-- ============================================================================
-- 02_simular_actividad.sql
-- Genera actividad de escritura NO destructiva para que el chequeo de salud y
-- la revision de mantenimiento tengan algo que observar.
--
-- Se actualiza el 10 % de producto (~5.000 filas sobre 50.002). Queda por
-- debajo del umbral por defecto de autovacuum (20 %), por lo que las tuplas
-- muertas permanecen visibles y justifican la revision manual posterior.
-- Ejecutar como propietario/superusuario sobre volttech_u6.
-- ============================================================================
\set ON_ERROR_STOP on

\echo 'Antes de simular actividad:'
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE schemaname = 'public' AND relname = 'producto';

-- UPDATE sin cambio de negocio (stock + 1) para generar versiones obsoletas.
UPDATE public.producto
SET stock = stock + 1
WHERE id % 10 = 0;

\echo 'Despues del UPDATE (las estadisticas pueden tardar unos segundos):'
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS pct_muertas
FROM pg_stat_user_tables
WHERE schemaname = 'public' AND relname = 'producto';

\echo 'Actividad simulada. Ejecute health_check.sql para observar el estado.'
