# ============================================================================
# restore_test.ps1  -  TP Unidad 6 - VoltTech
#
# Simulacro de desastre contra reloj:
#   1. toma el ultimo respaldo (o el indicado) y verifica que sea legible,
#   2. recrea SOLO la base descartable volttech_u6_restore_test,
#   3. arranca el cronometro inmediatamente antes de createdb,
#   4. restaura con pg_restore --no-owner --no-privileges --exit-on-error,
#   5. valida conteos contra el snapshot previo al respaldo, invalid=0 y
#      huerfanos=0,
#   6. detiene el cronometro y registra RTO observado y RPO observado.
#
# NUNCA toca volttech_u6. La contrasena no esta en el script: se toma de
# %APPDATA%\postgresql\pgpass.conf (rol mant_restore, con CREATEDB).
#
# Uso:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\restore_test.ps1 -Force
#   .\restore_test.ps1 -BackupFile .\backups\volttech_u6_20261110_230000.dump -Force
# ============================================================================
[CmdletBinding()]
param(
    [string]$BackupFile,
    [string]$BaseDestino = 'volttech_u6_restore_test',
    [string]$PgHost = 'localhost',
    [int]$PgPort = 5432,
    [string]$PgUser = 'mant_restore',
    [string]$PgBin,
    [switch]$Force,
    [switch]$SkipSnapshot
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
$BackupDir = Join-Path $Root 'backups'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$Fecha = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $LogDir "restore_${Fecha}.log"
$MetricsFile = Join-Path $LogDir "restore_metrics_${Fecha}.json"
$MetricsLatest = Join-Path $LogDir 'restore_metrics.json'
$ValidacionesTxt = Join-Path $LogDir "restore_validaciones_${Fecha}.txt"
$TocTmp = Join-Path $env:TEMP "volttech_restore_toc_${Fecha}.txt"
$InicioSimulacro = Get-Date

function Write-Log {
    param([string]$Mensaje, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Nivel = 'INFO')
    $linea = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensaje
    Write-Host $linea
    Add-Content -LiteralPath $LogFile -Value $linea -Encoding UTF8
}

function Resolve-PgBin {
    param([string]$Hint)
    if ($Hint) {
        if (Test-Path (Join-Path $Hint 'pg_restore.exe')) { return (Resolve-Path $Hint).Path }
        throw "No se encontro pg_restore.exe en -PgBin '$Hint'."
    }
    $cmd = Get-Command pg_restore.exe -ErrorAction SilentlyContinue
    if ($cmd) { return (Split-Path $cmd.Source -Parent) }
    $dirs = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Name -replace '\D', '') } -Descending
    foreach ($d in $dirs) {
        $bin = Join-Path $d.FullName 'bin'
        if (Test-Path (Join-Path $bin 'pg_restore.exe')) { return $bin }
    }
    throw 'No se encontro pg_restore.exe. Instale PostgreSQL o indique -PgBin con la carpeta bin.'
}

function Invoke-PsqlScalar {
    param([string]$Database, [string]$Query)
    $salida = & $script:Psql -h $PgHost -p $PgPort -U $PgUser -d $Database -X -q -w -v ON_ERROR_STOP=1 -A -t -c $Query 2>> $LogFile
    if ($LASTEXITCODE -ne 0) { throw "psql fallo con codigo $LASTEXITCODE al ejecutar: $Query" }
    $valor = @($salida | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    if ($valor.Count -eq 0) { return '' }
    return $valor[0].Trim()
}

function Write-Metrics {
    param([System.Collections.IDictionary]$Datos)
    $json = $Datos | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($MetricsFile, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($MetricsLatest, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

$backupTime = $null
$cronometro = $null
$metricas = [ordered]@{
    fecha_simulacro      = $InicioSimulacro.ToString('o')
    respaldo_archivo     = ''
    respaldo_fecha       = ''
    respaldo_bytes       = 0
    respaldo_sha256      = ''
    base_destino         = $BaseDestino
    rto_segundos         = $null
    rto_previsto_seg     = 20 * 60
    rto_cumple           = $false
    rpo_segundos         = $null
    rpo_previsto_seg     = 24 * 3600
    rpo_cumple           = $false
    conteos_coinciden    = $false
    productos_invalidos  = $null
    detalles_invalidos   = $null
    huerfanos            = $null
    restricciones        = $null
    validaciones         = ''
    resultado            = 'EN_CURSO'
    error                = ''
    base_conservada      = $true
}

try {
    # -----------------------------------------------------------------------
    # Protecciones: el destino debe ser una base descartable.
    # -----------------------------------------------------------------------
    if ($BaseDestino -eq 'volttech_u6' -or $BaseDestino -notmatch '_restore_test$') {
        throw "Destino no permitido: '$BaseDestino'. Solo se restaura en una base cuyo nombre termine en _restore_test."
    }

    $script:Bin = Resolve-PgBin -Hint $PgBin
    $script:PgRestore = Join-Path $script:Bin 'pg_restore.exe'
    $script:Createdb  = Join-Path $script:Bin 'createdb.exe'
    $script:Dropdb    = Join-Path $script:Bin 'dropdb.exe'
    $script:Psql      = Join-Path $script:Bin 'psql.exe'

    Write-Log '============================================================'
    Write-Log "Inicio simulacro | destino=$BaseDestino | usuario=$PgUser | host=${PgHost}:${PgPort}"

    # -----------------------------------------------------------------------
    # 0) Preflight: pg_restore -j 4 necesita el proceso principal + hasta
    #    4 trabajadores. Si el rol tiene un limite menor, se aborta con un
    #    mensaje claro en vez de fallar a mitad de la restauracion.
    # -----------------------------------------------------------------------
    $limiteConex = [int](Invoke-PsqlScalar -Database 'postgres' -Query 'SELECT rolconnlimit FROM pg_roles WHERE rolname = current_user;')
    if ($limiteConex -ge 0 -and $limiteConex -lt 7) {
        throw "El rol '$PgUser' tiene CONNECTION LIMIT $limiteConex y pg_restore -j 4 requiere al menos 7 (5 conexiones + margen). Ejecute: ALTER ROLE $PgUser CONNECTION LIMIT 10;"
    }
    Write-Log "Preflight de conexiones OK: rolconnlimit=$limiteConex (pg_restore -j 4 requiere >= 5)."

    # -----------------------------------------------------------------------
    # 1) Identificar y verificar el respaldo ANTES de arrancar el cronometro.
    # -----------------------------------------------------------------------
    if (-not $BackupFile) {
        $ultimo = Get-ChildItem -LiteralPath $BackupDir -File -Filter 'volttech_u6_*.dump' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $ultimo) { throw "No hay respaldos en $BackupDir. Ejecute backup_volttech.ps1 primero." }
        $BackupFile = $ultimo.FullName
    }
    if (-not (Test-Path -LiteralPath $BackupFile)) { throw "No existe el respaldo indicado: $BackupFile" }
    $dump = Get-Item -LiteralPath $BackupFile
    if ($dump.Length -le 0) { throw 'El respaldo esta vacio.' }
    $archivoNombre = $dump.Name
    $backupTime = $dump.LastWriteTime
    $metricas.respaldo_archivo = $archivoNombre
    $metricas.respaldo_fecha = $backupTime.ToString('yyyy-MM-dd HH:mm:ss')
    $metricas.respaldo_bytes = $dump.Length
    Write-Log ("Respaldo a probar: {0} ({1:N0} bytes, {2})" -f $dump.FullName, $dump.Length, $backupTime.ToString('yyyy-MM-dd HH:mm:ss'))

    # Verificar SHA-256 si existe el sidecar.
    $shaFile = "$($dump.FullName).sha256"
    if (Test-Path -LiteralPath $shaFile) {
        $esperado = (Get-Content -LiteralPath $shaFile -Raw).Trim().Split(' ')[0]
        $obtenido = (Get-FileHash -LiteralPath $dump.FullName -Algorithm SHA256).Hash
        if ($esperado -ne $obtenido) { throw "SHA-256 no coincide. Esperado=$esperado Obtenido=$obtenido" }
        $metricas.respaldo_sha256 = $obtenido
        Write-Log "SHA-256 verificado: $obtenido"
    } else {
        Write-Log "ADVERTENCIA: no existe $shaFile; se continua sin verificar integridad." 'WARN'
    }

    # Verificar que pg_restore pueda leer el indice del respaldo.
    & $script:PgRestore --list $dump.FullName 2>> $LogFile | Set-Content -LiteralPath $TocTmp -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "pg_restore --list fallo con codigo $LASTEXITCODE. El respaldo no es legible." }
    $entradas = @(Get-Content -LiteralPath $TocTmp | Where-Object { $_ -match '\S' -and $_ -notmatch '^;' }).Count
    if ($entradas -lt 1) { throw 'El respaldo no contiene objetos legibles.' }
    Write-Log "pg_restore --list OK ($entradas entradas)."

    # -----------------------------------------------------------------------
    # 2) Snapshot de conteos previo al respaldo (mismo archivo que usa backup).
    # -----------------------------------------------------------------------
    $conteosSql = Join-Path $Root 'soporte\conteos_validacion.sql'
    if (-not (Test-Path -LiteralPath $conteosSql)) { throw "No se encontro $conteosSql" }

    $snapshot = $null
    if ($archivoNombre -match '^volttech_u6_(\d{8}_\d{6})\.dump$') {
        $candidato = Join-Path $LogDir ("counts_volttech_u6_{0}.txt" -f $Matches[1])
        if (Test-Path -LiteralPath $candidato) { $snapshot = $candidato }
    }
    if (-not $snapshot) {
        $snapshot = Get-ChildItem -LiteralPath $LogDir -File -Filter 'counts_volttech_u6_*.txt' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($snapshot) { $snapshot = $snapshot.FullName }
    }

    $esperadoConteos = @()
    if ($snapshot) {
        $esperadoConteos = @(Get-Content -LiteralPath $snapshot | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
        Write-Log "Snapshot de conteos: $snapshot ($($esperadoConteos.Count) controles)"
    } elseif ($SkipSnapshot) {
        Write-Log 'Snapshot no encontrado; -SkipSnapshot activo: se usara el estado actual de volttech_u6 solo como referencia.' 'WARN'
        $esperadoConteos = @(& $script:Psql -h $PgHost -p $PgPort -U $PgUser -d volttech_u6 -X -q -w -A -t -F '|' -f $conteosSql 2>> $LogFile |
                             Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
        $metricas.validaciones = 'SNAPSHOT_OMITIDO'
    } else {
        throw "No se encontro el snapshot de conteos para '$archivoNombre'. Se requiere para comparar antes/despues; use -SkipSnapshot solo para una prueba manual."
    }

    # -----------------------------------------------------------------------
    # 3) Recrear la base descartable. El cronometro arranca justo antes de createdb.
    # -----------------------------------------------------------------------
    $existe = Invoke-PsqlScalar -Database 'postgres' -Query "SELECT 1 FROM pg_database WHERE datname = '$BaseDestino';"
    if ($existe -eq '1') {
        if (-not $Force) {
            throw "La base '$BaseDestino' ya existe. Use -Force para recrearla (operacion destructiva limitada a la base descartable)."
        }
        Write-Log "Eliminando base descartable existente '$BaseDestino' (-Force)..."
        & $script:Dropdb -h $PgHost -p $PgPort -U $PgUser -w --if-exists --force $BaseDestino 2>> $LogFile
        if ($LASTEXITCODE -ne 0) { throw "dropdb fallo con codigo $LASTEXITCODE." }
    }

    $cronometro = [Diagnostics.Stopwatch]::StartNew()
    Write-Log "Cronometro iniciado. Creando '$BaseDestino'..."
    & $script:Createdb -h $PgHost -p $PgPort -U $PgUser -w $BaseDestino 2>> $LogFile
    if ($LASTEXITCODE -ne 0) { throw "createdb fallo con codigo $LASTEXITCODE." }

    Write-Log "Restaurando '$archivoNombre' en '$BaseDestino'..."
    & $script:PgRestore -h $PgHost -p $PgPort -U $PgUser -d $BaseDestino -w --no-owner --no-privileges --exit-on-error -j 4 $dump.FullName 2>> $LogFile
    if ($LASTEXITCODE -ne 0) { throw "pg_restore fallo con codigo $LASTEXITCODE." }
    Write-Log 'pg_restore finalizo sin errores.'

    # -----------------------------------------------------------------------
    # 4) Validaciones minimas del TP.
    # -----------------------------------------------------------------------
    $actualConteos = @(& $script:Psql -h $PgHost -p $PgPort -U $PgUser -d $BaseDestino -X -q -w -v ON_ERROR_STOP=1 -A -t -F '|' -f $conteosSql 2>> $LogFile |
                       Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron leer los conteos restaurados (psql codigo $LASTEXITCODE)." }
    if ($actualConteos.Count -lt 7) { throw "Conteos restaurados incompletos: $($actualConteos.Count) lineas." }

    $diferencias = @()
    if ($esperadoConteos.Count -gt 0) {
        $diferencias = @(Compare-Object -ReferenceObject $esperadoConteos -DifferenceObject $actualConteos -SyncWindow 0)
        if ($diferencias.Count -gt 0) {
            $detalle = ($diferencias | ForEach-Object { "{0} {1}" -f $_.SideIndicator, $_.InputObject }) -join '; '
            throw "Los conteos restaurados NO coinciden con el snapshot previo al respaldo: $detalle"
        }
        $metricas.conteos_coinciden = $true
        Write-Log "Conteos coincidentes con el snapshot ($($actualConteos.Count) controles)."
    }

    $prodInvalidos = [int](Invoke-PsqlScalar -Database $BaseDestino -Query 'SELECT COUNT(*) FROM public.producto WHERE precio < 0 OR stock < 0;')
    $detInvalidos  = [int](Invoke-PsqlScalar -Database $BaseDestino -Query 'SELECT COUNT(*) FROM public.detalle_pedido WHERE cantidad <= 0 OR precio_unitario < 0;')
    $huerfanos = 0
    foreach ($q in @(
        'SELECT COUNT(*) FROM public.pedido p LEFT JOIN public.cliente c ON c.id = p.cliente_id WHERE c.id IS NULL;',
        'SELECT COUNT(*) FROM public.linea_pedido lp LEFT JOIN public.pedido p ON p.id = lp.pedido_id WHERE p.id IS NULL;',
        'SELECT COUNT(*) FROM public.linea_pedido lp LEFT JOIN public.producto pr ON pr.id = lp.producto_id WHERE pr.id IS NULL;'
    )) {
        $huerfanos += [int](Invoke-PsqlScalar -Database $BaseDestino -Query $q)
    }
    $restricciones = [int](Invoke-PsqlScalar -Database $BaseDestino -Query "SELECT COUNT(*) FROM pg_constraint WHERE connamespace = 'public'::regnamespace AND contype IN ('p','f','u','c');")
    $vistaCompat = Invoke-PsqlScalar -Database $BaseDestino -Query "SELECT COALESCE(to_regclass('public.detalle_pedido')::text, '');"

    $metricas.productos_invalidos = $prodInvalidos
    $metricas.detalles_invalidos = $detInvalidos
    $metricas.huerfanos = $huerfanos
    $metricas.restricciones = $restricciones

    Write-Log "Validaciones: productos_invalidos=$prodInvalidos detalles_invalidos=$detInvalidos huerfanos=$huerfanos restricciones=$restricciones vista_detalle_pedido=$vistaCompat"

    if ($prodInvalidos -ne 0) { throw "productos_invalidos = $prodInvalidos (se esperaba 0)." }
    if ($detInvalidos -ne 0) { throw "detalles_invalidos = $detInvalidos (se esperaba 0)." }
    if ($huerfanos -ne 0) { throw "huerfanos = $huerfanos (se esperaba 0)." }
    if ($restricciones -lt 1) { throw 'No se encontraron restricciones declarativas en la base restaurada.' }
    if ([string]::IsNullOrWhiteSpace($vistaCompat)) { throw 'No existe public.detalle_pedido en la base restaurada.' }

    # Evidencia legible de las validaciones.
    & $script:Psql -h $PgHost -p $PgPort -U $PgUser -d $BaseDestino -X -q -w -v ON_ERROR_STOP=1 -f (Join-Path $Root 'soporte\validaciones_restauracion.sql') 2>> $LogFile |
        Set-Content -LiteralPath $ValidacionesTxt -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "Fallo la salida de validaciones_restauracion.sql (codigo $LASTEXITCODE)." }
    Write-Log "Evidencia de validaciones: $ValidacionesTxt"

    $cronometro.Stop()

    # -----------------------------------------------------------------------
    # 5) Metricas: RTO medido y RPO observado (antiguedad del respaldo).
    # -----------------------------------------------------------------------
    $rto = [math]::Round($cronometro.Elapsed.TotalSeconds, 2)
    $rpo = [math]::Round(($InicioSimulacro - $backupTime).TotalSeconds, 0)
    $metricas.rto_segundos = $rto
    $metricas.rto_cumple = ($rto -le $metricas.rto_previsto_seg)
    $metricas.rpo_segundos = $rpo
    $metricas.rpo_cumple = ($rpo -le $metricas.rpo_previsto_seg)
    $metricas.validaciones = 'OK: conteos, invalid=0, huerfanos=0, restricciones y vista'
    $metricas.resultado = 'OK'
    Write-Metrics -Datos $metricas

    Write-Log ("RTO observado: {0:N2} s (objetivo <= {1} s) -> {2}" -f $rto, $metricas.rto_previsto_seg, $(if ($metricas.rto_cumple) { 'CUMPLE' } else { 'NO CUMPLE' }))
    Write-Log ("RPO observado: {0:N0} s (~{1:N1} h) (objetivo <= {2:N0} s) -> {3}" -f $rpo, ($rpo / 3600), $metricas.rpo_previsto_seg, $(if ($metricas.rpo_cumple) { 'CUMPLE' } else { 'NO CUMPLE' }))
    Write-Log "Base '$BaseDestino' conservada para inspeccion. Limpieza manual: dropdb -h $PgHost -U postgres --if-exists $BaseDestino"
    Write-Log "Metricas: $MetricsFile"
    Write-Log 'RESULTADO: SIMULACRO VALIDADO'
    Write-Log '============================================================'
}
catch {
    $mensaje = $_.Exception.Message
    Write-Log "ERROR: $mensaje" 'ERROR'
    if ($null -ne $cronometro) { try { $cronometro.Stop() } catch {} ; $metricas.rto_segundos = [math]::Round($cronometro.Elapsed.TotalSeconds, 2) }
    if ($null -ne $backupTime) {
        $metricas.rpo_segundos = [math]::Round(($InicioSimulacro - $backupTime).TotalSeconds, 0)
    }
    $metricas.resultado = 'ERROR'
    $metricas.error = $mensaje
    try { Write-Metrics -Datos $metricas } catch { Write-Log "No se pudo escribir metricas: $($_.Exception.Message)" 'WARN' }
    Write-Log 'RESULTADO: SIMULACRO FALLIDO'
    Write-Log '============================================================'
    throw $mensaje
}
finally {
    if (Test-Path -LiteralPath $TocTmp) { Remove-Item -LiteralPath $TocTmp -Force -ErrorAction SilentlyContinue }
}
