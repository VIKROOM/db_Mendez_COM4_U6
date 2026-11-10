# ============================================================================
# backup_volttech.ps1  -  TP Unidad 6 - VoltTech
#
# Respaldo logico diario en formato custom (-Fc), con:
#   - nombre de archivo con fecha y hora,
#   - log separado en logs/,
#   - snapshot de conteos previo al respaldo (para validar la restauracion),
#   - verificacion con pg_restore --list,
#   - huella SHA-256,
#   - retencion acotada al patron propio,
#   - registro OK/ERROR en mantenimiento.bitacora,
#   - error de salida si pg_dump falla.
#
# La contrasena NO esta en el script: libpq la toma de
# %APPDATA%\postgresql\pgpass.conf. Se usa el rol de minimo privilegio
# mant_backup (solo lectura + INSERT en la bitacora).
#
# Uso:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\backup_volttech.ps1
#   .\backup_volttech.ps1 -Destino D:\Respaldos\volttech -RetencionDias 14
#   .\backup_volttech.ps1 -PgDumpExtra '--exclude-table=public.auditoria'
#     (PgDumpExtra permite excluir tablas u opciones propias de pg_dump.)
# ============================================================================
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [int]$PgPort = 5432,
    [string]$PgUser = 'mant_backup',
    [string]$Base = 'volttech_u6',
    [string]$Destino,
    [string]$LogDir,
    [int]$RetencionDias = 14,
    [string]$PgBin,
    [string[]]$PgDumpExtra = @()
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
if (-not $Destino) { $Destino = Join-Path $Root 'backups' }
if (-not $LogDir)  { $LogDir  = Join-Path $Root 'logs' }
$Destino = [IO.Path]::GetFullPath($Destino)
$LogDir  = [IO.Path]::GetFullPath($LogDir)

# ---------------------------------------------------------------------------
# Protecciones previas: nunca operar sobre la raiz ni sobre la base de prueba.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Destino) -or $Destino -match '^[A-Za-z]:\\?$' -or $Destino -eq '\' -or $Destino -eq '/') {
    throw "Destino invalido o demasiado amplio: '$Destino'. Se niega a escribir/borrar alli."
}
if ($Base -notmatch '^[A-Za-z0-9_]+$') {
    throw "Nombre de base invalido: '$Base'."
}
if ($Base -eq 'volttech_u6_restore_test') {
    throw 'Este script respalda la base principal; no se ejecuta contra la base de restauracion.'
}
if ($RetencionDias -lt 1 -or $RetencionDias -gt 3650) {
    throw "RetencionDias fuera de rango razonable: $RetencionDias."
}

New-Item -ItemType Directory -Force -Path $Destino, $LogDir | Out-Null

$Fecha    = Get-Date -Format 'yyyyMMdd_HHmmss'
$Inicio   = (Get-Date).ToString('o')
$InicioDt = Get-Date
$Archivo  = Join-Path $Destino "${Base}_${Fecha}.dump"
$Parcial  = "$Archivo.parcial"
$ShaFile  = "$Archivo.sha256"
$LogFile  = Join-Path $LogDir "backup_${Base}_${Fecha}.log"
$Historial = Join-Path $LogDir 'backup_historial.log'
$Snapshot = Join-Path $LogDir "counts_${Base}_${Fecha}.txt"
$Listado  = Join-Path $env:TEMP "volttech_toc_${Fecha}.txt"

function Write-Log {
    param([string]$Mensaje, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Nivel = 'INFO')
    $linea = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensaje
    Write-Host $linea
    Add-Content -LiteralPath $LogFile -Value $linea -Encoding UTF8
}

function Resolve-PgBin {
    param([string]$Hint)
    if ($Hint) {
        if (Test-Path (Join-Path $Hint 'pg_dump.exe')) { return (Resolve-Path $Hint).Path }
        throw "No se encontro pg_dump.exe en -PgBin '$Hint'."
    }
    $cmd = Get-Command pg_dump.exe -ErrorAction SilentlyContinue
    if ($cmd) { return (Split-Path $cmd.Source -Parent) }
    $dirs = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Name -replace '\D', '') } -Descending
    foreach ($d in $dirs) {
        $bin = Join-Path $d.FullName 'bin'
        if (Test-Path (Join-Path $bin 'pg_dump.exe')) { return $bin }
    }
    throw 'No se encontro pg_dump.exe. Instale PostgreSQL o indique -PgBin con la carpeta bin.'
}

function Register-Bitacora {
    param(
        [string]$Estado,
        [string]$Detalle,
        [string]$NombreArchivo = '',
        [long]$Bytes = 0,
        [string]$Hash = ''
    )
    $tmpSql = Join-Path $env:TEMP ("volttech_bitacora_{0}.sql" -f [guid]::NewGuid().ToString('N'))
    try {
        $sql = @"
INSERT INTO mantenimiento.bitacora
    (tarea, inicio, fin, estado, filas, archivo, tamano_bytes, sha256, detalle)
VALUES
    ('respaldo_logico', :'ini'::timestamptz, clock_timestamp(), :'est',
     NULL, :'arch', :'bytes'::bigint, :'hash', :'det');
"@
        # psql no interpola variables en -c, solo al leer un archivo con -f.
        [IO.File]::WriteAllText($tmpSql, $sql, [Text.UTF8Encoding]::new($false))
        $psqlArgs = @(
            '-h', $PgHost, '-p', "$PgPort", '-U', $PgUser, '-d', $Base,
            '-X', '-q', '-w', '-v', 'ON_ERROR_STOP=1',
            '-v', "ini=$Inicio",
            '-v', "est=$Estado",
            '-v', "arch=$NombreArchivo",
            '-v', "bytes=$Bytes",
            '-v', "hash=$Hash",
            '-v', "det=$Detalle",
            '-f', $tmpSql
        )
        $salida = & $script:Psql @psqlArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($salida -join ' ') }
        Write-Log "Bitacora: $Estado registrado en mantenimiento.bitacora"
    } catch {
        # La bitacora es evidencia de monitoreo: su falla no invalida el .dump,
        # pero queda registrada en el log local para que sea visible.
        Write-Log "No se pudo registrar en bitacora: $($_.Exception.Message)" 'WARN'
    } finally {
        if (Test-Path -LiteralPath $tmpSql) { Remove-Item -LiteralPath $tmpSql -Force -ErrorAction SilentlyContinue }
    }
}

try {
    $script:Bin = Resolve-PgBin -Hint $PgBin
    $script:PgDump = Join-Path $script:Bin 'pg_dump.exe'
    $script:PgRestore = Join-Path $script:Bin 'pg_restore.exe'
    $script:Psql = Join-Path $script:Bin 'psql.exe'

    Write-Log '============================================================'
    Write-Log "Inicio respaldo | base=$Base | usuario=$PgUser | host=${PgHost}:${PgPort}"
    Write-Log "Destino=$Destino | retencion=${RetencionDias}d | PostgreSQL bin=$($script:Bin)"
    Write-Log "Archivo objetivo: $Archivo"

    # -----------------------------------------------------------------------
    # 1) Snapshot de conteos ANTES del respaldo.
    #    Se usa el mismo archivo SQL que restore_test.ps1 para comparar.
    # -----------------------------------------------------------------------
    $conteosSql = Join-Path $Root 'soporte\conteos_validacion.sql'
    if (-not (Test-Path -LiteralPath $conteosSql)) {
        throw "No se encontro el archivo de conteos: $conteosSql"
    }
    $conteos = & $script:Psql -h $PgHost -p $PgPort -U $PgUser -d $Base -X -q -w -v ON_ERROR_STOP=1 -A -t -F '|' -f $conteosSql 2>> $LogFile
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron leer los conteos previos (psql codigo $LASTEXITCODE)." }
    $conteos = @($conteos | Where-Object { $_ -match '\S' })
    if ($conteos.Count -lt 7) { throw "Snapshot de conteos incompleto: se esperaban 7 lineas y se obtuvieron $($conteos.Count)." }
    [IO.File]::WriteAllLines($Snapshot, $conteos, [Text.UTF8Encoding]::new($false))
    Write-Log "Snapshot de conteos: $Snapshot ($($conteos.Count) controles)"

    # -----------------------------------------------------------------------
    # 2) pg_dump en formato custom hacia un archivo .parcial.
    #    -w (--no-password) evita que una tarea programada quede esperando.
    # -----------------------------------------------------------------------
    Write-Log "Ejecutando pg_dump -Fc -Z 6 sobre '$Base'..."
    $dumpArgs = @('-h', $PgHost, '-p', "$PgPort", '-U', $PgUser, '-d', $Base, '-Fc', '-Z', '6', '-w', '-f', $Parcial) + $PgDumpExtra
    & $script:PgDump @dumpArgs 2>> $LogFile
    $codigoDump = $LASTEXITCODE
    if ($codigoDump -ne 0) {
        throw "pg_dump termino con codigo $codigoDump. El respaldo NO es valido."
    }
    if (-not (Test-Path -LiteralPath $Parcial)) {
        throw 'pg_dump termino en 0 pero no genero el archivo esperado.'
    }
    $info = Get-Item -LiteralPath $Parcial
    if ($info.Length -le 0) { throw 'El archivo generado esta vacio.' }
    Write-Log ("pg_dump OK: {0:N0} bytes ({1:N2} MB)" -f $info.Length, ($info.Length / 1MB))

    # -----------------------------------------------------------------------
    # 3) Verificacion minima: pg_restore debe poder leer el indice (TOC).
    # -----------------------------------------------------------------------
    & $script:PgRestore --list $Parcial 2>> $LogFile | Set-Content -LiteralPath $Listado -Encoding UTF8
    $codigoList = $LASTEXITCODE
    if ($codigoList -ne 0) {
        throw "pg_restore --list fallo con codigo $codigoList. El respaldo no es legible."
    }
    $entradas = @(Get-Content -LiteralPath $Listado | Where-Object { $_ -match '\S' -and $_ -notmatch '^;' }).Count
    if ($entradas -lt 1) { throw 'pg_restore --list no devolvio objetos: el archivo esta vacio o corrupto.' }
    Write-Log "Verificacion pg_restore --list OK ($entradas entradas en el TOC)"

    # -----------------------------------------------------------------------
    # 4) Huella SHA-256, renombrado atomico y archivo .sha256.
    # -----------------------------------------------------------------------
    $hash = (Get-FileHash -LiteralPath $Parcial -Algorithm SHA256).Hash
    Move-Item -LiteralPath $Parcial -Destination $Archivo -Force
    $shaLinea = "$hash  $([IO.Path]::GetFileName($Archivo))"
    [IO.File]::WriteAllText($ShaFile, $shaLinea + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Log "SHA-256: $hash"
    Write-Log "Respaldo valido: $Archivo"

    # -----------------------------------------------------------------------
    # 5) Retencion: SOLO archivos del patron propio y mas antiguos que N dias.
    # -----------------------------------------------------------------------
    $limite = (Get-Date).AddDays(-$RetencionDias)
    $patronDump = "^{0}_\d{{8}}_\d{{6}}\.dump(\.sha256)?$" -f [regex]::Escape($Base)
    $patronCounts = "^counts_{0}_\d{{8}}_\d{{6}}\.txt$" -f [regex]::Escape($Base)
    $borrados = 0
    Get-ChildItem -LiteralPath $Destino -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $patronDump -and $_.LastWriteTime -lt $limite } |
        ForEach-Object {
            Write-Log "Retencion: eliminando $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Force
            $borrados++
        }
    Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $patronCounts -and $_.LastWriteTime -lt $limite } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    Write-Log "Retencion aplicada: $borrados archivo(s) .dump/.sha256 eliminados (limite $($limite.ToString('yyyy-MM-dd HH:mm')))"

    # -----------------------------------------------------------------------
    # 6) Registro en la bitacora y cierre.
    # -----------------------------------------------------------------------
    $nombre = [IO.Path]::GetFileName($Archivo)
    Register-Bitacora -Estado 'OK' -Detalle "$nombre $([math]::Round($info.Length / 1MB, 2)) MB ($entradas objetos TOC)" -NombreArchivo $nombre -Bytes $info.Length -Hash $hash

    $duracion = [math]::Round(((Get-Date) - $InicioDt).TotalSeconds, 1)
    Add-Content -LiteralPath $Historial -Encoding UTF8 -Value ("{0}|{1}|{2}|{3}|{4}|OK|{5}s" -f $Inicio, $Base, $nombre, $info.Length, $hash, $duracion)
    Write-Log "Fin OK en $duracion s. Archivo: $Archivo"
    Write-Log '============================================================'
}
catch {
    $mensaje = $_.Exception.Message
    Write-Log "ERROR: $mensaje" 'ERROR'
    if (Test-Path -LiteralPath $Parcial) {
        Remove-Item -LiteralPath $Parcial -Force -ErrorAction SilentlyContinue
        Write-Log 'Se elimino el archivo .parcial incompleto.' 'WARN'
    }
    # Si se alcanzo a renombrar pero no se escribio el .sha256, no se deja un
    # archivo con nombre de respaldo valido sin su huella.
    if ((Test-Path -LiteralPath $Archivo) -and -not (Test-Path -LiteralPath $ShaFile)) {
        Remove-Item -LiteralPath $Archivo -Force -ErrorAction SilentlyContinue
        Write-Log 'Se elimino el .dump sin SHA-256 para no dejar evidencia enganiosa.' 'WARN'
    }
    Register-Bitacora -Estado 'ERROR' -Detalle $mensaje
    Add-Content -LiteralPath $Historial -Encoding UTF8 -Value ("{0}|{1}|{2}|ERROR|{3}" -f $Inicio, $Base, '', $mensaje)
    Write-Log '============================================================'
    # Terminacion con error: powershell -File devuelve codigo 1 ante la excepcion.
    throw $mensaje
}
finally {
    if (Test-Path -LiteralPath $Listado) { Remove-Item -LiteralPath $Listado -Force -ErrorAction SilentlyContinue }
}
