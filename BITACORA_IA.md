# BITÁCORA IA — Uso de OpenCode en el TP Unidad 6

**Alumno:** Joaquin Antonio Mendez Reynoso · **Materia:** Bases de Datos II · Comisión 4
**Asistente:** OpenCode (agente de código con LLM) · **Motor real:** PostgreSQL 17.10 · **Base:** `volttech_u6`

Este archivo registra cómo se usó la IA durante el trabajo, qué propuso, qué se rechazó y qué quedó
finalmente en la entrega. Regla del TP: **ningún resultado se aceptó sin ejecutarlo contra el motor real**;
los valores de los informes salen de los archivos de `evidencias/`, no de la memoria de la IA.

---

## 1. Análisis de la consigna y adaptación del ejemplo de la cátedra

**Propuesta de la IA:** replicar la estructura del TP de referencia (FoodStore) adaptando nombres y volúmenes a VoltTech.
**Revisión humana:** se verificaron los nombres reales del modelo del equipo contra los scripts de la app antes de escribir nada: `linea_pedido` (no `detalle_pedido`), vistas `v_productos_vigentes`, `v_pedidos_cliente`, `v_detalle_pedido_producto`, vista materializada `mv_facturacion_categoria_mes`, procedimientos `registrar_pedido` y `ajustar_stock`, extensión `pg_trgm` con índice gin sobre `producto.nombre`. Nada se copió sin contrastar.

## 2. Recuperación de la credencial del administrador

**Situación real:** el entorno no tenía documentada la contraseña de `postgres`, y sin ella no había setup posible.
**Propuesta de la IA:** recuperarla localmente desencriptando el almacén de credenciales de DBeaver (`credentials-config.json`, AES-128-CBC con clave derivada del `connection-config.json` del mismo DBeaver, todo en la propia máquina del alumno).
**Revisión humana y corrección:** se usó **solo para el setup inicial** (crear roles, esquema y grants). De inmediato se pasó todo el procedimiento a roles propios con contraseña aleatoria en `pgpass.conf`; los cuatro artefactos corren sin la credencial del administrador y ninguna contraseña quedó en el repositorio.

## 3. Roles de mínimo privilegio en lugar del superusuario

**Propuesta inicial de la IA:** correr respaldo y restauración con `postgres` "para simplificar".
**Rechazo humano:** se crearon `mant_backup` (pg_read_all_data + INSERT en bitácora), `mant_monitor` (pg_monitor) y `mant_restore` (CREATEDB + lectura). Verificado en el motor: `rolsuper=f`, sin INSERT sobre datos de negocio.

## 4. Límite de conexiones del rol de restauración

**Lección aplicada:** en el trabajo de referencia, `pg_restore -j 4` fallaba porque el rol tenía `CONNECTION LIMIT` insuficiente (el paralelismo abre hasta 5 conexiones).
**Decisión:** `mant_restore` se creó con `CONNECTION LIMIT 10` y `restore_test.ps1` ejecuta un **preflight** que aborta si `rolconnlimit < 7`. En la corrida real: preflight OK con límite 10.

## 5. VACUUM FULL descartado desde el diseño

**Propuesta descartada:** "VACUUM FULL semanal para recuperar espacio".
**Rechazo:** bloquea la tabla con ACCESS EXCLUSIVE y la consigna lo prohíbe como mantenimiento periódico. Se implementó `VACUUM (ANALYZE, VERBOSE)` vía `\gexec`, condicionado al umbral documentado (≥ 5 % de muertas y ≥ 1.000 filas, o ≥ 10.000 muertas). En la corrida solo `producto` calificó: 5.000 muertas (9,09 %), quedaron 0.

## 6. Vista de compatibilidad `detalle_pedido`

**Conflicto:** la consigna nombra `detalle_pedido`; el modelo real del equipo usa `linea_pedido`.
**Propuesta de la IA (descartada):** renombrar la tabla.
**Corrección humana:** vista de compatibilidad `public.detalle_pedido` sobre la tabla real; el DDL de VoltTech quedó intacto y las validaciones del enunciado funcionan literalmente.

## 7. Umbral de intervención del mantenimiento

**Propuesta de la IA:** intervenir al 20 % (igual que autovacuum).
**Ajuste humano:** umbral propio más bajo (5 % / 1.000 filas / 10.000 muertas) para que el mantenimiento manual tenga sentido real sin duplicar lo que autovacuum ya haría por sí solo; documentado en `maintenance.sql`.

## 8. Snapshot de conteos antes del respaldo

**Decisión de la IA revisada y aceptada:** capturar conteos (7 controles: 5 tablas, suma de cantidades e importe) en `counts_pre_backup.txt` **antes** de pg_dump, como referencia objetiva del RPO lógico y de la validación 7/7 posterior. En el simulacro coincidió 7/7.

## 9. Bitácora vía archivo temporal + `psql -f`

**Lección aplicada:** psql no interpola `:'variables'` en `-c`; el INSERT en bitácora se escribe en un archivo temporal y se ejecuta con `-f` y `ON_ERROR_STOP=1`. El respaldo registró OK en la primera ejecución.

## 10. Credenciales en `pgpass.conf` con permisos restrictivos

**Decisión:** contraseñas aleatorias generadas en runtime (nunca impresas), guardadas en `%APPDATA%\postgresql\pgpass.conf`; `icacls` otorga control solo al usuario dueño, sin herencia, para permitir rotaciones futuras. Los scripts usan `pg_dump -w` / `psql -w`.

## 11. Prueba de falla de pg_dump

**Decisión:** forzar un error real (`--table=public.tabla_que_no_existe`) para validar el camino de error. Resultado medido: exit 1, log en ERROR, `.parcial` eliminado, fila ERROR en bitácora y ningún `.dump` válido nuevo.

## 12. REFRESH de la vista materializada tras restaurar

**Problema cubierto:** `pg_dump` restaura vistas materializadas **sin datos**; `mv_facturacion_categoria_mes` quedaba vacía tras un restore impecable. Validando solo conteos de tablas, la base habría "pasado" el chequeo con la vista de reportes vacía.
**Corrección:** se agregó `REFRESH MATERIALIZED VIEW` a `soporte/validaciones_restauracion.sql` antes de la corrida; evidencia: 26 filas tras repoblar (`restore_validaciones.txt`, sección 8). Es el "problema real" documentado en la sección 4 del informe.

---

## Declaración

OpenCode generó la especificación, los scripts (`backup_volttech.ps1`, `health_check.sql`, `maintenance.sql`,
`restore_test.ps1`), el material de `soporte/` y los generadores de los tres PDF. El operador revisó y corrigió
las 12 decisiones listadas arriba, ejecutó todo contra PostgreSQL 17.10 real (carga de datos, respaldo, prueba de
fallo, mantenimiento, monitoreo y simulacro completo con RTO 7,60 s y RPO 58 s) y completó a mano los valores
narrativos de los informes contrastándolos con los archivos de `evidencias/`. Ningún valor de los informes fue
inventado por la IA.
