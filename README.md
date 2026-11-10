# TP Unidad 6 — Mantenimiento, respaldo y recuperación de VoltTech

**Alumno:** Joaquin Antonio Mendez Reynoso · **Materia:** Bases de Datos II · Comisión 4
**Motor:** PostgreSQL 17.10 · **Base:** `volttech_u6` · **Repositorio:** https://github.com/VIKROOM/db_Mendez_COM4_U6.git

Mantenimiento de la base de la aplicación **VoltTech** (comercio de electrónica) del equipo: respaldo lógico
automatizable, chequeo de salud, mantenimiento justificado por métricas y simulacro de desastre con RPO/RTO
medidos. Todo lo reportado en los informes se ejecutó contra el motor real; las salidas crudas están en
`evidencias/`.

## Resultados medidos (corrida del 10-11-2026)

| Métrica | Valor |
|---|---|
| Respaldo | `volttech_u6_20261110_203628.dump`, 10,81 MB, 58 objetos, SHA-256 verificado |
| RTO observado | **7,60 s** (meta ≤ 20 min) |
| RPO observado | **58 s** (meta ≤ 24 h) |
| Validación | 7/7 conteos, invalid=0, huérfanos=0, 16 restricciones, objetos de la app OK |
| Mantenimiento | VACUUM (ANALYZE) en `producto`: 5.000 tuplas muertas → 0 |
| Autoevaluación | `soporte/verificar_entrega.ps1` → ver `evidencias/verificacion_entrega.txt` |

## Estructura

| Ruta | Contenido |
|---|---|
| `SPEC_U6.md` | Especificación y plan (Parte 1) |
| `backup_volttech.ps1` | Respaldo pg_dump -Fc con SHA-256, retención y bitácora (Parte 2) |
| `health_check.sql` | Chequeo de salud, 6 bloques (Parte 3) |
| `maintenance.sql` | Revisión de autovacuum + VACUUM (ANALYZE) justificado (Parte 3) |
| `restore_test.ps1` | Simulacro de desastre con RTO/RPO medidos (Parte 4) |
| `informe_u6.md` / `informe_u6.pdf` | Informe post-incidente de una página (Parte 5) |
| `informe_u6_actividades.pdf`, `informe_u6_tareas.pdf` | Informes extendidos por actividades y por tareas |
| `informe/` | Generadores Python (reportlab) de los tres PDF |
| `soporte/` | Roles, entorno, simulación de actividad, conteos, validaciones, pgpass y autoevaluación |
| `evidencias/` | 13 archivos de salida cruda de la corrida |
| `logs/` | Logs fechados de cada corrida (versionados como evidencia) |
| `backups/` | Dumps con su `.sha256` (regenerables, ignorados por git) |
| `BITACORA_IA.md` | Uso de OpenCode: 12 decisiones revisadas |

## Requisitos

- PostgreSQL 16+ en localhost:5432 (probado en 17.10)
- PowerShell 5.1+ y Python 3.9+ con `reportlab` (`python -m pip install reportlab`)
- Credenciales en `%APPDATA%\postgresql\pgpass.conf` (nunca en el repositorio)

## Preparación (una sola vez, como administrador)

```powershell
# 1) Cargar la app VoltTech y su volumen de datos (scripts del equipo, App/)
# 2) Roles de mantenimiento
psql -h localhost -U postgres -d volttech_u6 -X -f .\soporte\01_roles_mantenimiento.sql
# 3) Entorno: esquema mantenimiento.bitacora, vista detalle_pedido, grants
psql -h localhost -U postgres -d volttech_u6 -X -f .\soporte\00_preparacion_entorno.sql
# 4) Contraseñas de los roles en pgpass.conf (genera e instala, no imprime)
.\soporte\setup_pgpass.ps1
# 5) Simular actividad para el mantenimiento (opcional, ya aplicado)
psql -h localhost -U postgres -d volttech_u6 -X -f .\soporte\02_simular_actividad.sql
```

## Operación

```powershell
.\backup_volttech.ps1                                            # respaldo diario
psql -h localhost -U mant_monitor -d volttech_u6 -X -f .\health_check.sql   # salud
psql -h localhost -U postgres   -d volttech_u6 -X -f .\maintenance.sql      # mantenimiento
.\restore_test.ps1 -Force                                         # simulacro de desastre
.\soporte\verificar_entrega.ps1                                   # autoevaluación de la entrega
python .\informe\generar_informe.py                                # informe_u6.pdf
python .\informe\generar_informe_actividades.py                    # informe_u6_actividades.pdf
python .\informe\generar_informe_tareas.py                         # informe_u6_tareas.pdf
```

`restore_test.ps1` restaura siempre en `volttech_u6_restore_test`: aborta si el destino es la base principal o
no termina en `_restore_test`. `verificar_entrega.ps1` escribe `evidencias/verificacion_entrega.txt` con el
resumen `RESULTADO: N PASS / M FAIL` y falla si hay algún FAIL.

## Seguridad

- Ninguna contraseña en scripts, SQL, logs ni el repositorio; `pg_dump -w` + pgpass.conf.
- Roles de mínimo privilegio; nadie es superusuario.
- VACUUM FULL prohibido como mantenimiento periódico (consigna).
- `volttech_u6` nunca se elimina ni se restaura durante el simulacro.
