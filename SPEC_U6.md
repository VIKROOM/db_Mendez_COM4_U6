# SPEC_U6.md - Plan de mantenimiento de VoltTech

**Proyecto:** VoltTech (comercio de electrónica) · **Motor:** PostgreSQL 16+ (laboratorio: 17.10)
**Base principal:** `volttech_u6` · **Base descartable:** `volttech_u6_restore_test`
**Objetivo:** respaldar, observar, mantener y recuperar `volttech_u6` con un procedimiento repetible, seguro y medible (RPO/RTO).

## 1. Alcance

Se automatiza el respaldo lógico diario, el chequeo de salud, la revisión semanal de mantenimiento y la restauración de prueba. No se automatizan las decisiones de intervención: se observan métricas y recién después se ejecuta la acción justificada. Quedan fuera de alcance el respaldo físico, PITR y replicación.

## 2. Tareas, frecuencia y condición de éxito

| Tarea | Frecuencia | Herramienta | Identidad | Condición que confirma el éxito | Evidencia |
|---|---|---|---|---|---|
| Respaldo de `volttech_u6` | Diaria, 02:00 | `backup_volttech.ps1` + `pg_dump -Fc` | `mant_backup` | `pg_dump` termina en 0, el `.dump` se lista con `pg_restore --list`, se calcula SHA-256 y se registra en bitácora | `.dump` fechado + log + `.sha256` |
| Chequeo de salud | Diaria, inicio de jornada | `health_check.sql` | `mant_monitor` | Devuelve tamaño, conexiones/actividad, estado de tablas y consultas activas | Salida de `health_check.sql` |
| Revisión de mantenimiento | Semanal | `maintenance.sql` | dueño de las tablas | Se observan tuplas muertas, autovacuum y estadísticas; solo se ejecuta `VACUUM (ANALYZE)` si se supera el umbral documentado | Salida antes/después + fila en bitácora |
| Restauración de prueba | Semanal | `restore_test.ps1` | `mant_restore` | `volttech_u6_restore_test` se crea, restaura y supera conteos e invalid=0 | Log de restauración + métricas RTO/RPO |

## 3. RPO y RTO

- **RPO previsto:** ≤ 24 h (respaldo diario). **RPO observado:** antigüedad del último `.dump` al inicio del simulacro.
- **RTO previsto:** ≤ 20 min. **RTO observado:** cronómetro desde `createdb` hasta que todas las validaciones terminan correctamente.

## 4. Reglas de seguridad (no negociables)

1. `volttech_u6` no se elimina, reemplaza ni se restaura durante el simulacro.
2. Toda operación destructiva se limita a `volttech_u6_restore_test`; el script aborta si el destino no termina en `_restore_test`.
3. Ninguna contraseña se escribe en scripts, SQL, logs ni repositorio. La autenticación se resuelve con `%APPDATA%\postgresql\pgpass.conf`.
4. Roles de mínimo privilegio: `mant_backup` (solo lectura), `mant_monitor` (`pg_monitor`), `mant_restore` (`CREATEDB` + lectura).
5. `VACUUM FULL` queda prohibido como mantenimiento periódico. Solo se admite `VACUUM (ANALYZE)` condicionado a la observación previa.
6. Todo script aborta ante el primer error y deja un log con fecha, operación, resultado y código de salida.
7. Un respaldo no se considera válido hasta que se restaura y se validan cantidades y reglas lógicas.

## 5. Criterios de aceptación

Respaldo restaurable y legible; monitoreo con al menos cuatro controles; mantenimiento justificado con observación previa; restauración en `volttech_u6_restore_test` con conteos coincidentes e invalid=0; informe con RPO y RTO previstos y observados, problema real y mejora concreta.
