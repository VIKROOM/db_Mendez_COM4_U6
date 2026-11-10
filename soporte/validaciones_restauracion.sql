-- ============================================================================
-- validaciones_restauracion.sql
-- Controles minimos del TP Unidad 6 despues de restaurar volttech_u6_restore_test.
-- Se puede ejecutar manualmente para dejar evidencia:
--   psql -h localhost -U mant_restore -d volttech_u6_restore_test -X -f validaciones_restauracion.sql
-- Resultados esperados: productos_invalidos = 0, detalles_invalidos = 0,
-- huerfanos = 0 y conteos coincidentes con el snapshot previo al respaldo.
-- ============================================================================
\set ON_ERROR_STOP on
\pset border 2
\pset pager off

\echo '=== 1. Conteos por tabla (comparar con logs/counts_*.txt) ==='
SELECT 'categoria' AS tabla, COUNT(*) AS filas FROM public.categoria
UNION ALL SELECT 'cliente', COUNT(*) FROM public.cliente
UNION ALL SELECT 'producto', COUNT(*) FROM public.producto
UNION ALL SELECT 'pedido', COUNT(*) FROM public.pedido
UNION ALL SELECT 'detalle_pedido', COUNT(*) FROM public.detalle_pedido
ORDER BY tabla;

\echo '=== 2. Productos invalidos (esperado 0) ==='
SELECT COUNT(*) AS productos_invalidos
FROM public.producto
WHERE precio < 0 OR stock < 0;

\echo '=== 3. Detalles invalidos (esperado 0) ==='
SELECT COUNT(*) AS detalles_invalidos
FROM public.detalle_pedido
WHERE cantidad <= 0 OR precio_unitario < 0;

\echo '=== 4. Huerfanos referenciales (esperado 0) ==='
SELECT 'pedido sin cliente' AS control, COUNT(*) AS filas
FROM public.pedido p
LEFT JOIN public.cliente c ON c.id = p.cliente_id
WHERE c.id IS NULL
UNION ALL
SELECT 'linea sin pedido', COUNT(*)
FROM public.linea_pedido lp
LEFT JOIN public.pedido p ON p.id = lp.pedido_id
WHERE p.id IS NULL
UNION ALL
SELECT 'linea sin producto', COUNT(*)
FROM public.linea_pedido lp
LEFT JOIN public.producto pr ON pr.id = lp.producto_id
WHERE pr.id IS NULL;

\echo '=== 5. Restricciones declarativas restauradas ==='
SELECT conrelid::regclass AS tabla, conname, contype
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
  AND contype IN ('p', 'f', 'u', 'c')
ORDER BY conrelid::regclass::text, contype, conname;

\echo '=== 6. Vista de compatibilidad detalle_pedido ==='
SELECT COUNT(*) AS filas_vista_detalle_pedido FROM public.detalle_pedido;

\echo '=== 7. Objetos de la aplicacion VoltTech restaurados ==='
SELECT c.relname AS objeto,
       CASE c.relkind WHEN 'v' THEN 'vista' WHEN 'm' THEN 'vista materializada' ELSE c.relkind::text END AS tipo
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('v_productos_vigentes', 'v_pedidos_cliente',
                    'v_detalle_pedido_producto', 'mv_facturacion_categoria_mes')
ORDER BY c.relname;

SELECT 'extensiones' AS objeto, string_agg(extname, ', ' ORDER BY extname) AS tipo
FROM pg_extension
WHERE extname NOT IN ('plpgsql');

SELECT 'procedimientos' AS objeto,
       COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), 'ninguno') AS tipo
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prokind = 'p';

\echo '=== 8. Vista materializada: definicion restaurada y repoblada ==='
\echo 'pg_dump restaura las vistas materializadas sin datos; se repuebla con REFRESH.'
REFRESH MATERIALIZED VIEW public.mv_facturacion_categoria_mes;
SELECT count(*) AS filas_mv_facturacion_categoria_mes
FROM public.mv_facturacion_categoria_mes;

\echo '=== FIN validaciones_restauracion.sql ==='
