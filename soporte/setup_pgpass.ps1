# ============================================================================
# setup_pgpass.ps1
# Configura las contrasenas de los roles de mantenimiento y el archivo
# %APPDATA%\postgresql\pgpass.conf. La contrasena se pide en consola y NUNCA
# se escribe en el repositorio, en los scripts ni en los logs.
#
# Uso:
#   .\soporte\setup_pgpass.ps1
#   .\soporte\setup_pgpass.ps1 -PgHost localhost -PgPort 5432 -PgAdmin postgres
# ============================================================================
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [int]$PgPort = 5432,
    [string]$PgAdmin = 'postgres',
    [string]$PgBin
)

$ErrorActionPreference = 'Stop'

function Resolve-PgBin {
    param([string]$Hint)
    if ($Hint) {
        if (Test-Path (Join-Path $Hint 'psql.exe')) { return (Resolve-Path $Hint).Path }
        throw "No se encontro psql.exe en -PgBin '$Hint'."
    }
    $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($cmd) { return (Split-Path $cmd.Source -Parent) }
    $dirs = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Name -replace '\D', '') } -Descending
    foreach ($d in $dirs) {
        $bin = Join-Path $d.FullName 'bin'
        if (Test-Path (Join-Path $bin 'psql.exe')) { return $bin }
    }
    throw 'No se encontro psql.exe. Indique -PgBin con la carpeta bin de PostgreSQL.'
}

function Escape-PgpassValue {
    param([string]$Value)
    return $Value.Replace('\', '\\').Replace(':', '\:')
}

$Bin      = Resolve-PgBin -Hint $PgBin
$Psql     = Join-Path $Bin 'psql.exe'
$Roles    = @('mant_backup', 'mant_monitor', 'mant_restore')
$PgpassDir = Join-Path $env:APPDATA 'postgresql'
$PgpassFile = Join-Path $PgpassDir 'pgpass.conf'

Write-Host 'Configuracion de credenciales de mantenimiento (VoltTech - U6)' -ForegroundColor Cyan
Write-Host "Servidor: $PgHost`:$PgPort | Administrador: $PgAdmin | Roles: $($Roles -join ', ')"
Write-Host 'La contrasena no se guarda en el repositorio; solo en pgpass.conf (fuera del repo).'

# Para automatizacion (por ejemplo, una sesion de laboratorio sin consola
# interactiva) se puede definir MANT_PASSWORD solo en el entorno del proceso.
# No se escribe en disco ni en el repositorio; si no esta definida, se pide
# por consola sin eco.
$plain = $env:MANT_PASSWORD
if ([string]::IsNullOrWhiteSpace($plain)) {
    $secure = Read-Host -AsSecureString 'Contrasena de laboratorio para los roles de mantenimiento'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

if ([string]::IsNullOrWhiteSpace($plain)) { throw 'La contrasena no puede estar vacia.' }
if ($plain -match '[^\x20-\x7E]') {
    throw 'Use solo caracteres ASCII imprimibles en la contrasena de laboratorio (pgpass.conf se escribe sin BOM).'
}

# 1) Asignar la contrasena a cada rol por entrada estandar (no aparece en la
#    linea de comandos). Se escapa la comilla simple duplicandola.
$sqlEscaped = $plain.Replace("'", "''")
$sqlLines = foreach ($rol in $Roles) {
    "ALTER ROLE $rol PASSWORD '$sqlEscaped';"
}
$sql = ($sqlLines -join [Environment]::NewLine) + [Environment]::NewLine

# Sin -w: si el administrador no tiene entrada en pgpass.conf, psql pedira su
# contrasena en consola (no se guarda). Tambien puede definirse PGPASSWORD
# solo para esta ejecucion.
$sql | & $Psql -h $PgHost -p $PgPort -U $PgAdmin -d postgres -X -q -v ON_ERROR_STOP=1
if ($LASTEXITCODE -ne 0) {
    throw "No se pudieron asignar las contrasenas (psql codigo $LASTEXITCODE). Verifique que $PgAdmin pueda conectarse como administrador."
}

# PGPASSWORD tiene prioridad sobre pgpass.conf: si quedo definida para la
# conexion administrativa, se elimina para que la verificacion use el archivo.
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue

# 2) Escribir pgpass.conf (formato host:puerto:base:usuario:contrasena).
#    Se usa .NET para evitar el BOM que agregaria Out-File en Windows PowerShell.
New-Item -ItemType Directory -Force -Path $PgpassDir | Out-Null
if (Test-Path -LiteralPath $PgpassFile) {
    # Una ejecucion anterior pudo dejar el archivo en solo lectura; se recupera
    # el control ANTES de reescribirlo (la rotacion de contrasena debe funcionar).
    & icacls $PgpassFile /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
}
$escaped = Escape-PgpassValue -Value $plain
$lines = foreach ($rol in $Roles) {
    "$PgHost`:$PgPort`:*`:$rol`:$escaped"
}
[IO.File]::WriteAllText($PgpassFile, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

# 3) Restringir el archivo al usuario actual (lectura/escritura solo para el
#    dueno; sin herencia de permisos). Se conserva (F) para permitir rotaciones.
try {
    & icacls $PgpassFile /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls codigo $LASTEXITCODE" }
} catch {
    Write-Warning "No se pudieron ajustar los permisos de '$PgpassFile': $($_.Exception.Message). Ajustelos manualmente."
}

# 4) Probar cada identidad con -w (sin pedir contrasena).
Write-Host ''
foreach ($rol in $Roles) {
    $who = & $Psql -h $PgHost -p $PgPort -U $rol -d volttech_u6 -X -q -A -t -w -c 'SELECT current_user;' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo la conexion de $rol usando pgpass.conf: $who"
    }
    Write-Host ("OK  {0,-13} -> {1}" -f $rol, $who.Trim()) -ForegroundColor Green
}

Write-Host ''
Write-Host "pgpass.conf actualizado: $PgpassFile" -ForegroundColor Green
Write-Host 'No copie este archivo al repositorio. Para rotar la contrasena, vuelva a ejecutar este script.'
