-- ============================================================================
-- 00_preparacion_entorno.sql
-- Prepara la base volttech_u6 para el plan de mantenimiento de la Unidad 6.
-- Ejecutar como propietario/superusuario DESPUES de 01_roles_mantenimiento.sql:
--   psql -h localhost -U postgres -d volttech_u6 -v ON_ERROR_STOP=1 -f 00_preparacion_entorno.sql
-- No elimina ni reemplaza datos de negocio.
-- ============================================================================
\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS mantenimiento;

-- Bitacora de tareas: una fila por ejecucion, con resultado y evidencia.
CREATE TABLE IF NOT EXISTS mantenimiento.bitacora (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tarea         VARCHAR(60)  NOT NULL,
    inicio        TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),
    fin           TIMESTAMPTZ,
    estado        VARCHAR(10)  NOT NULL DEFAULT 'EN_CURSO'
                  CHECK (estado IN ('EN_CURSO', 'OK', 'ERROR', 'ADVERTENCIA')),
    filas         BIGINT,
    archivo       VARCHAR(200),
    tamano_bytes  BIGINT,
    sha256        CHAR(64),
    detalle       TEXT,
    ejecutado_por NAME         NOT NULL DEFAULT current_user
);

CREATE INDEX IF NOT EXISTS idx_bitacora_tarea_estado_fin
    ON mantenimiento.bitacora (tarea, estado, fin DESC);

-- El modelo integrador llama linea_pedido a la tabla que el enunciado del TP
-- denomina detalle_pedido. Se crea una vista de compatibilidad (no se altera
-- el DDL) para que las validaciones del TP funcionen con el nombre literal.
DO $$
BEGIN
    IF to_regclass('public.detalle_pedido') IS NULL
       AND to_regclass('public.linea_pedido') IS NOT NULL THEN
        EXECUTE 'CREATE VIEW public.detalle_pedido AS
                 SELECT pedido_id, producto_id, cantidad, precio_unitario
                 FROM public.linea_pedido';
        RAISE NOTICE 'Vista de compatibilidad public.detalle_pedido creada sobre public.linea_pedido';
    ELSE
        RAISE NOTICE 'No se creo la vista: detalle_pedido ya existe o falta linea_pedido';
    END IF;
END $$;

-- Permisos de minimo privilegio para las tareas de mantenimiento.
-- rol_respaldo: lectura de datos (pg_read_all_data) + INSERT/SELECT en la bitacora.
GRANT USAGE ON SCHEMA mantenimiento TO rol_respaldo, rol_monitoreo;
GRANT INSERT, SELECT ON mantenimiento.bitacora TO rol_respaldo;
GRANT USAGE ON SEQUENCE mantenimiento.bitacora_id_seq TO rol_respaldo;
-- rol_monitoreo: solo lectura de la bitacora (las metricas del motor las da pg_monitor).
GRANT SELECT ON mantenimiento.bitacora TO rol_monitoreo;

-- Verificacion de la preparacion.
SELECT current_database() AS base,
       current_user AS ejecutado_por,
       to_regclass('mantenimiento.bitacora') AS bitacora,
       to_regclass('public.detalle_pedido')  AS vista_compatibilidad;
