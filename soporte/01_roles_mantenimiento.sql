-- ============================================================================
-- 01_roles_mantenimiento.sql
-- Roles de minimo privilegio para el plan de mantenimiento (Unidad 6).
-- NO contiene contrasenas. Las credenciales se configuran fuera del repositorio
-- con soporte/setup_pgpass.ps1 (o psql \password).
-- Ejecutar como superusuario sobre la base volttech_u6:
--   psql -h localhost -U postgres -d volttech_u6 -v ON_ERROR_STOP=1 -f 01_roles_mantenimiento.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- Roles de grupo (sin login): agrupan privilegios predefinidos.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_respaldo') THEN
        CREATE ROLE rol_respaldo NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_monitoreo') THEN
        CREATE ROLE rol_monitoreo NOLOGIN;
    END IF;
END $$;

-- Lectura de todos los datos y USAGE sobre todos los esquemas: lo necesario
-- para que pg_dump pueda leer la base sin permisos de escritura.
GRANT pg_read_all_data TO rol_respaldo;

-- Metricas del motor sin acceso a los datos de negocio.
GRANT pg_monitor TO rol_monitoreo;

-- Identidades de login. La contrasena se asigna aparte (setup_pgpass.ps1).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mant_backup') THEN
        CREATE ROLE mant_backup LOGIN CONNECTION LIMIT 2;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mant_monitor') THEN
        CREATE ROLE mant_monitor LOGIN CONNECTION LIMIT 2;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mant_restore') THEN
        -- pg_restore -j 4 abre un proceso principal y hasta 4 trabajadores:
        -- el limite debe permitir esas conexiones simultaneas.
        CREATE ROLE mant_restore LOGIN CONNECTION LIMIT 10;
    END IF;
END $$;

-- Idempotente: asegura el limite aunque el rol ya existiera con otro valor.
ALTER ROLE mant_restore CONNECTION LIMIT 10;

GRANT rol_respaldo  TO mant_backup;
GRANT rol_monitoreo TO mant_monitor;
GRANT rol_respaldo  TO mant_restore;

-- mant_restore necesita crear y eliminar SOLO bases descartables.
-- CREATEDB no otorga superusuario ni acceso a volttech_u6_restore_test de otros.
ALTER ROLE mant_restore CREATEDB;

-- Verificacion: ninguno debe ser superusuario.
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb
FROM pg_roles
WHERE rolname IN ('rol_respaldo', 'rol_monitoreo', 'mant_backup', 'mant_monitor', 'mant_restore')
ORDER BY rolname;
