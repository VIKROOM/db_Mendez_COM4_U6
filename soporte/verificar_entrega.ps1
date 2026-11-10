# ============================================================================
# verificar_entrega.ps1  -  Autoevaluacion objetiva del TP Unidad 6
#
# Compara la entrega contra la consigna punto por punto: archivos, contenido
# minimo de cada script, ausencia de contrasenas/VACUUM FULL, evidencias y
# metricas RPO/RTO. Ademas consulta el motor (opcional con -SkipDb) para
# comprobar roles, privilegios, bitacora y base restaurada.
#
# Uso:
#   .\soporte\verificar_entrega.ps1
#   .\soporte\verificar_entrega.ps1 -SkipDb
#
# Sale con error (throw) si algun control falla.
# ============================================================================
[CmdletBinding()]
param([switch]$SkipDb)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Evidencias = Join-Path $Root 'evidencias'
New-Item -ItemType Directory -Force -Path $Evidencias | Out-Null
$Salida = Join-Path $Evidencias 'verificacion_entrega.txt'

$script:Ok = 0
$script:Fail = 0
$script:Lineas = [System.Collections.Generic.List[string]]::new()

function Write-Check {
    param([string]$Nombre, [bool]$Cumple, [string]$Detalle = '')
    $estado = if ($Cumple) { 'PASS' } else { 'FAIL' }
    $linea = '{0}  {1}{2}' -f $estado, $Nombre, $(if ($Detalle) { "  -> $Detalle" } else { '' })
    $script:Lineas.Add($linea)
    if ($Cumple) {
        $script:Ok++
        Write-Host $linea -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host $linea -ForegroundColor Red
    }
}

function Test-Archivo {
    param([string]$Relativo, [int]$MinBytes = 1)
    $ruta = Join-Path $Root $Relativo
    $existe = (Test-Path -LiteralPath $ruta) -and ((Get-Item -LiteralPath $ruta).Length -ge $MinBytes)
    Write-Check "Archivo: $Relativo" $existe $(if (-not $existe) { 'falta o esta vacio' } else { '' })
    return $existe
}

function Test-Contiene {
    param([string]$Relativo, [string]$Texto, [string]$Etiqueta)
    $ruta = Join-Path $Root $Relativo
    $ok = (Test-Path -LiteralPath $ruta) -and ((Get-Content -LiteralPath $ruta -Raw).Contains($Texto))
    Write-Check "$Etiqueta ($Relativo)" $ok $Texto
}

function Test-Regex {
    param([string]$Relativo, [string]$Patron, [string]$Etiqueta)
    $ruta = Join-Path $Root $Relativo
    $ok = (Test-Path -LiteralPath $ruta) -and [bool](Select-String -LiteralPath $ruta -Pattern $Patron -Quiet)
    Write-Check "$Etiqueta ($Relativo)" $ok $Patron
}

function Resolve-PgBin {
    $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($cmd) { return (Split-Path $cmd.Source -Parent) }
    $dirs = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Name -replace '\D', '') } -Descending
    foreach ($d in $dirs) {
        $bin = Join-Path $d.FullName 'bin'
        if (Test-Path (Join-Path $bin 'psql.exe')) { return $bin }
    }
    return $null
}

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' AUTOEVALUACION - TP Unidad 6 - VoltTech' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Entregables obligatorios
# ---------------------------------------------------------------------------
Write-Host "`n[1] Entregables" -ForegroundColor Yellow
$obligatorios = @(
    'SPEC_U6.md',
    'backup_volttech.ps1',
    'health_check.sql',
    'maintenance.sql',
    'restore_test.ps1',
    'informe_u6.md',
    'informe_u6.pdf',
    'BITACORA_IA.md',
    'README.md',
    'soporte\00_preparacion_entorno.sql',
    'soporte\01_roles_mantenimiento.sql',
    'soporte\02_simular_actividad.sql',
    'soporte\setup_pgpass.ps1',
    'soporte\conteos_validacion.sql',
    'soporte\validaciones_restauracion.sql'
)
foreach ($f in $obligatorios) { Test-Archivo $f 1 | Out-Null }
Test-Archivo 'informe_u6.pdf' 1000 | Out-Null

# ---------------------------------------------------------------------------
# 2. Especificacion (Parte 1)
# ---------------------------------------------------------------------------
Write-Host "`n[2] Especificacion y plan" -ForegroundColor Yellow
foreach ($t in @('Diaria', 'Semanal', 'RPO', 'RTO', 'volttech_u6_restore_test', 'pgpass.conf', 'VACUUM FULL')) {
    Test-Contiene 'SPEC_U6.md' $t 'Plan incluye'
}
$lineasSpec = (Get-Content -LiteralPath (Join-Path $Root 'SPEC_U6.md')).Count
Write-Check 'SPEC_U6.md compacta (<= 90 lineas)' ($lineasSpec -le 90) "$lineasSpec lineas"

# ---------------------------------------------------------------------------
# 3. Respaldo (Parte 2)
# ---------------------------------------------------------------------------
Write-Host "`n[3] Respaldo automatizable" -ForegroundColor Yellow
foreach ($t in @('pg_dump', '-Fc', 'yyyyMMdd_HHmmss', 'pg_restore', '--list', 'Get-FileHash', 'SHA256', '$LASTEXITCODE', 'mant_backup', 'RetencionDias', '.parcial', 'mantenimiento.bitacora')) {
    Test-Contiene 'backup_volttech.ps1' $t 'Respaldo usa'
}
Test-Regex 'backup_volttech.ps1' '^\s*\$ErrorActionPreference\s*=\s*''Stop''' 'Respaldo aborta ante error'
$prohibidoPwd = [bool](Select-String -LiteralPath (Join-Path $Root 'backup_volttech.ps1') -Pattern 'PGPASSWORD\s*=|password\s*=\s*[''"]|postgres\s*:\s*postgres' -Quiet)
Write-Check 'Respaldo sin contrasenas embebidas' (-not $prohibidoPwd)

# ---------------------------------------------------------------------------
# 4. Monitoreo y mantenimiento (Parte 3)
# ---------------------------------------------------------------------------
Write-Host "`n[4] Monitoreo y mantenimiento" -ForegroundColor Yellow
foreach ($t in @('pg_database_size', 'pg_stat_database', 'pg_stat_user_tables', 'pg_stat_activity', 'n_dead_tup', 'last_autovacuum', 'numbackends', 'state <> ''idle''')) {
    Test-Contiene 'health_check.sql' $t 'health_check controla'
}
foreach ($t in @('autovacuum', 'n_dead_tup', 'VACUUM (ANALYZE', '\gexec', 'mantenimiento.bitacora', 'last_autoanalyze')) {
    Test-Contiene 'maintenance.sql' $t 'maintenance revisa/ejecuta'
}
$vacuumFullEjecutable = [bool](Select-String -LiteralPath (Join-Path $Root 'maintenance.sql') -Pattern '^\s*VACUUM\s+FULL\b' -Quiet)
Write-Check 'maintenance.sql NO ejecuta VACUUM FULL' (-not $vacuumFullEjecutable)

# ---------------------------------------------------------------------------
# 5. Restauracion y metricas (Parte 4)
# ---------------------------------------------------------------------------
Write-Host "`n[5] Restauracion y RPO/RTO" -ForegroundColor Yellow
foreach ($t in @('volttech_u6_restore_test', 'createdb', 'pg_restore', '--no-owner', '--no-privileges', '--exit-on-error', 'productos_invalidos', 'detalles_invalidos', 'Stopwatch', 'rto_segundos', 'rpo_segundos', 'conteos_validacion.sql', '_restore_test', 'mant_restore')) {
    Test-Contiene 'restore_test.ps1' $t 'restore_test implementa'
}
Test-Regex 'restore_test.ps1' 'BaseDestino\s*-\s*eq\s*''volttech_u6''|BaseDestino\s*-eq\s*''volttech_u6''' 'restore_test protege volttech_u6'

# ---------------------------------------------------------------------------
# 6. Informe (Parte 5)
# ---------------------------------------------------------------------------
Write-Host "`n[6] Informe post-incidente" -ForegroundColor Yellow
foreach ($t in @('RPO', 'RTO', 'OpenCode', 'mejora', 'respaldo', 'valid', 'volttech_u6_restore_test', 'problema')) {
    Test-Contiene 'informe_u6.md' $t 'Informe incluye'
}

# ---------------------------------------------------------------------------
# 7. Evidencias
# ---------------------------------------------------------------------------
Write-Host "`n[7] Evidencias" -ForegroundColor Yellow
foreach ($f in @(
    'evidencias\backup_ejecucion.log',
    'evidencias\backup_listado.txt',
    'evidencias\backup_sha256.txt',
    'evidencias\health_check_antes.txt',
    'evidencias\health_check_despues.txt',
    'evidencias\maintenance_salida.txt',
    'evidencias\restore_ejecucion.log',
    'evidencias\restore_validaciones.txt',
    'evidencias\restore_metrics.json',
    'evidencias\fallo_pg_dump.log'
)) {
    Test-Archivo $f 1 | Out-Null
}

# ---------------------------------------------------------------------------
# 8. Verificacion contra el motor (opcional)
# ---------------------------------------------------------------------------
if (-not $SkipDb) {
    Write-Host "`n[8] Verificacion en PostgreSQL" -ForegroundColor Yellow
    $bin = Resolve-PgBin
    if (-not $bin) {
        Write-Check 'psql disponible para verificacion' $false 'no se encontro psql.exe'
    } else {
        $psql = Join-Path $bin 'psql.exe'
        $pgRestore = Join-Path $bin 'pg_restore.exe'
        $pgUser = 'mant_backup'
        function DbScalar {
            param([string]$Db, [string]$Sql)
            $v = & $psql -h localhost -p 5432 -U $pgUser -d $Db -X -q -w -v ON_ERROR_STOP=1 -A -t -c $Sql 2>&1
            if ($LASTEXITCODE -ne 0) { throw "psql fallo: $($v -join ' ')" }
            $r = @($v | Where-Object { $_ -match '\S' } | Select-Object -First 1)
            if ($r.Count -eq 0) { return '' }
            return $r[0].Trim()
        }

        try {
            $prod = [int](DbScalar 'volttech_u6' 'SELECT count(*) FROM public.producto;')
            Write-Check 'volttech_u6 poblada (producto > 0)' ($prod -gt 0) "$prod filas"
            $vista = DbScalar 'volttech_u6' "SELECT COALESCE(to_regclass('public.detalle_pedido')::text, '');"
            Write-Check 'Vista public.detalle_pedido existe' ($vista -ne '') $vista
            $backupOk = [int](DbScalar 'volttech_u6' "SELECT count(*) FROM mantenimiento.bitacora WHERE tarea='respaldo_logico' AND estado='OK';")
            Write-Check 'Bitacora con respaldo OK' ($backupOk -gt 0) "$backupOk filas"
            $mantOk = [int](DbScalar 'volttech_u6' "SELECT count(*) FROM mantenimiento.bitacora WHERE tarea='mantenimiento_manual' AND estado='OK';")
            Write-Check 'Bitacora con mantenimiento OK' ($mantOk -gt 0) "$mantOk filas"
            $superBackup = DbScalar 'volttech_u6' "SELECT rolsuper FROM pg_roles WHERE rolname='mant_backup';"
            Write-Check 'mant_backup no es superusuario' ($superBackup -eq 'f') "rolsuper=$superBackup"
            $insertProd = DbScalar 'volttech_u6' "SELECT has_table_privilege('mant_backup','public.producto','INSERT');"
            Write-Check 'mant_backup no puede INSERT en producto' ($insertProd -eq 'f') "insert=$insertProd"
            $insertBit = DbScalar 'volttech_u6' "SELECT has_table_privilege('mant_backup','mantenimiento.bitacora','INSERT');"
            Write-Check 'mant_backup puede INSERT en bitacora' ($insertBit -eq 't') "insert=$insertBit"
            $createdb = DbScalar 'volttech_u6' "SELECT rolcreatedb FROM pg_roles WHERE rolname='mant_restore';"
            Write-Check 'mant_restore tiene CREATEDB' ($createdb -eq 't') "createdb=$createdb"
            $testDb = DbScalar 'volttech_u6' "SELECT count(*) FROM pg_database WHERE datname='volttech_u6_restore_test';"
            Write-Check 'volttech_u6_restore_test existe' ($testDb -eq '1') "$testDb"
            $testRows = [int](DbScalar 'volttech_u6_restore_test' 'SELECT count(*) FROM public.producto;')
            Write-Check 'volttech_u6_restore_test poblada' ($testRows -gt 0) "$testRows filas"
        } catch {
            Write-Check 'Consultas de verificacion en el motor' $false $_.Exception.Message
        }

        # Los .dump deben ser legibles por pg_restore --list (sin conectarse a la base).
        $dumps = @(Get-ChildItem -LiteralPath (Join-Path $Root 'backups') -File -Filter 'volttech_u6_*.dump' -ErrorAction SilentlyContinue)
        if ($dumps.Count -gt 0) {
            & $pgRestore --list $dumps[0].FullName 2>$null | Out-Null
            Write-Check 'El .dump mas reciente es legible' ($LASTEXITCODE -eq 0) $dumps[0].Name
        } else {
            Write-Check 'Existe al menos un .dump' $false 'backups/ vacio'
        }
    }
}

# ---------------------------------------------------------------------------
# 9. Metricas del simulacro
# ---------------------------------------------------------------------------
Write-Host "`n[9] Metricas del simulacro" -ForegroundColor Yellow
$metricsPath = Join-Path $Root 'evidencias\restore_metrics.json'
if (Test-Path -LiteralPath $metricsPath) {
    try {
        $m = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
        Write-Check 'Resultado del simulacro OK' ($m.resultado -eq 'OK') "resultado=$($m.resultado)"
        Write-Check 'RTO observado presente y > 0' (($null -ne $m.rto_segundos) -and ([double]$m.rto_segundos -gt 0)) "$($m.rto_segundos) s"
        Write-Check 'RPO observado presente' ($null -ne $m.rpo_segundos) "$($m.rpo_segundos) s"
        Write-Check 'Conteos coinciden' ($m.conteos_coinciden -eq $true) "$($m.conteos_coinciden)"
        Write-Check 'Invalidos en cero' (([int]$m.productos_invalidos -eq 0) -and ([int]$m.detalles_invalidos -eq 0)) "prod=$($m.productos_invalidos) det=$($m.detalles_invalidos)"
    } catch {
        Write-Check 'Metricas legibles' $false $_.Exception.Message
    }
} else {
    Write-Check 'Metricas del simulacro' $false 'falta evidencias/restore_metrics.json'
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
$resumen = @(
    '',
    '============================================================',
    ("RESULTADO: {0} PASS / {1} FAIL" -f $script:Ok, $script:Fail),
    ("Fecha: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    '============================================================'
)
$script:Lineas.AddRange([string[]]$resumen)

[IO.File]::WriteAllLines($Salida, $script:Lineas, [Text.UTF8Encoding]::new($false))
Write-Host ''
Write-Host ("RESULTADO: {0} PASS / {1} FAIL" -f $script:Ok, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "Evidencia: $Salida"

if ($script:Fail -gt 0) {
    throw "Autoevaluacion incompleta: $($script:Fail) control(es) fallaron. Revise $Salida."
}
