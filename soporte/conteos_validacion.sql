-- ============================================================================
-- conteos_validacion.sql
-- Fuente unica del snapshot de conteos que usa backup_volttech.ps1 antes del
-- respaldo y restore_test.ps1 despues de restaurar. Se ejecuta con:
--   psql -X -q -A -t -F "|" -f soporte/conteos_validacion.sql
-- El orden es estable (ORDER BY 1) para comparar linea por linea.
-- ============================================================================
SELECT 'categoria' AS control, count(*)::text AS valor FROM public.categoria
UNION ALL
SELECT 'cliente', count(*)::text FROM public.cliente
UNION ALL
SELECT 'producto', count(*)::text FROM public.producto
UNION ALL
SELECT 'pedido', count(*)::text FROM public.pedido
UNION ALL
SELECT 'detalle_pedido', count(*)::text FROM public.detalle_pedido
UNION ALL
SELECT 'suma_cantidad', COALESCE(sum(cantidad), 0)::text FROM public.detalle_pedido
UNION ALL
SELECT 'suma_importe', COALESCE(round(sum(cantidad * precio_unitario), 2), 0)::text
FROM public.detalle_pedido
ORDER BY 1;
