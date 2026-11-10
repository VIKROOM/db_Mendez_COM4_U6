# ============================================================================
# generar_informe.py - genera informe_u6.pdf (1 página A4) a partir de las
# métricas reales del simulacro (evidencias/restore_metrics.json), del
# snapshot de conteos (evidencias/counts_pre_backup.txt) y de las demás
# evidencias de la corrida (logs, listado del dump, autoevaluación).
#
# Los valores que no se pueden derivar de los archivos se completan en el
# diccionario MANUAL; si algún campo queda con la marca @@, el script se
# niega a generar el PDF para evitar informar valores inventados.
#
# Uso (desde la raíz del TP):
#   python informe/generar_informe.py
# Requiere reportlab:  python -m pip install reportlab
# ============================================================================
import json
import os
import re

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EVID = os.path.join(ROOT, "evidencias")
SALIDA = os.path.join(ROOT, "informe_u6.pdf")
REPO = "https://github.com/VIKROOM/db_Mendez_COM4_U6.git"
ALUMNO = "Joaquin Antonio Mendez Reynoso"

# Valores de la corrida que se completan a mano tras revisar las evidencias.
MANUAL = {
    "motor": "PostgreSQL 17.10",
    "problema": (
        "pg_dump restaura las vistas materializadas sin datos: mv_facturacion_categoria_mes quedaba como "
        "definición vacía en la base restaurada tras un pg_restore impecable (0 errores y 7/7 conteos). No es un "
        "fallo del respaldo sino un comportamiento estándar que el procedimiento debía cubrir: un operador que "
        "valide solo conteos de tablas entregaría reportes vacíos. Se agregó REFRESH MATERIALIZED VIEW a las "
        "validaciones de restauración y quedó registrado en la evidencia: 26 filas tras repoblar "
        "(restore_validaciones.txt, sección 8)."
    ),
    "mejora": (
        "Para la siguiente ejecución: (1) programar backup_volttech.ps1 y health_check.sql en el Programador de "
        "tareas de Windows (02:00) para que el RPO de 24 h no dependa de la ejecución manual, y (2) convertir la "
        "sección 6 del chequeo de salud (antigüedad del último respaldo OK) en una alerta explícita cuando supere "
        "las 20 h, margen sobre el RPO; hoy solo informa la antigüedad."
    ),
    "ia": (
        "OpenCode generó la especificación, los scripts de respaldo, monitoreo, mantenimiento y restauración, y "
        "este informe. Nada se aceptó sin ejecutarlo contra el motor real: se cargó volttech_u6 sobre la app "
        "VoltTech del equipo (800.002 líneas de pedido), se ejecutaron los cuatro artefactos, la prueba de falla "
        "de pg_dump (exit 1, sin .dump válido) y el simulacro completo. La intervención humana revisó 12 "
        "decisiones de la IA documentadas en BITACORA_IA.md: credenciales y pgpass, rechazo de VACUUM FULL, vista "
        "de compatibilidad detalle_pedido, límite de conexiones para pg_restore -j 4, repoblado de la vista "
        "materializada y encoding de las evidencias, entre otras."
    ),
}

for clave, valor in MANUAL.items():
    if "@@" in str(valor):
        raise SystemExit(f"ERROR: complete MANUAL['{clave}'] en generar_informe.py antes de generar el PDF.")


def _leer(nombre):
    ruta = os.path.join(EVID, nombre)
    if not os.path.exists(ruta):
        raise SystemExit(f"ERROR: falta la evidencia {ruta}")
    # utf-8-sig: los logs de PowerShell pueden traer BOM.
    with open(ruta, encoding="utf-8-sig", errors="replace") as fh:
        return fh.read()


with open(os.path.join(EVID, "restore_metrics.json"), encoding="utf-8-sig") as fh:
    m = json.load(fh)

conteos = {}
for linea in _leer("counts_pre_backup.txt").splitlines():
    if "|" in linea:
        k, v = linea.strip().split("|", 1)
        conteos[k] = int(float(v))

_auto = re.search(r"RESULTADO:\s*(\d+) PASS / (\d+) FAIL", _leer("verificacion_entrega.txt"))
AUTO_PASS, AUTO_FAIL = (int(_auto.group(1)), int(_auto.group(2))) if _auto else (0, 0)

_toc = [l for l in _leer("backup_listado.txt").splitlines()
        if l.strip() and not l.lstrip().startswith(";")]
TOC = len(_toc)

_dur = re.search(r"Fin OK en ([\d]+(?:[.,]\d+)?) s", _leer("backup_ejecucion.log"))
DURACION = _dur.group(1).replace(".", ",") if _dur else "?"

_ini = re.search(r"^([\d\-]+ [\d:]+) \[INFO\] Inicio respaldo", _leer("backup_ejecucion.log"), re.M)
_fin = re.search(r"^([\d\-]+ [\d:]+) \[INFO\] Fin OK", _leer("backup_ejecucion.log"), re.M)
RANGO = ("{}–{}".format(_ini.group(1)[11:], _fin.group(1)[11:])
         if _ini and _fin else m["respaldo_fecha"][11:19])

MESES = ("enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
         "agosto", "septiembre", "octubre", "noviembre", "diciembre")
from datetime import datetime  # noqa: E402
_dia = datetime.fromisoformat(re.sub(r"\.(\d{6})\d+", r".\1", m["fecha_simulacro"]))
FECHA = f"{_dia.day} de {MESES[_dia.month - 1]} de {_dia.year}"

fmt = lambda n: f"{n:,}".replace(",", ".")
rto = f"{m['rto_segundos']:.2f}".replace(".", ",")
rpo = int(m["rpo_segundos"])
rpo_txt = f"{rpo} s ({rpo // 60} min {rpo % 60} s)"
mb = f"{m['respaldo_bytes'] / 1_048_576:.2f}".replace(".", ",")

pdfmetrics.registerFont(TTFont("Arial", r"C:\Windows\Fonts\arial.ttf"))
pdfmetrics.registerFont(TTFont("Arial-Bold", r"C:\Windows\Fonts\arialbd.ttf"))

AZUL = colors.HexColor("#14375F")
GRIS = colors.HexColor("#5A5A5A")
FONDO = colors.HexColor("#E8EEF6")

titulo_doc = ParagraphStyle("titulo_doc", fontName="Arial-Bold", fontSize=13, leading=15,
                            textColor=AZUL, spaceAfter=1)
subtitulo = ParagraphStyle("subtitulo", fontName="Arial", fontSize=8.2, leading=10,
                           textColor=GRIS, spaceAfter=3)
seccion = ParagraphStyle("seccion", fontName="Arial-Bold", fontSize=9.6, leading=11.5,
                         textColor=AZUL, spaceBefore=3, spaceAfter=2)
cuerpo = ParagraphStyle("cuerpo", fontName="Arial", fontSize=8.6, leading=10.4,
                        alignment=TA_LEFT, spaceAfter=2)
vineta = ParagraphStyle("vineta", parent=cuerpo, leftIndent=8, bulletIndent=1,
                        bulletFontName="Arial", bulletFontSize=8.6, spaceAfter=0.6)
celda = ParagraphStyle("celda", fontName="Arial", fontSize=8.2, leading=9.6)
celda_b = ParagraphStyle("celda_b", parent=celda, fontName="Arial-Bold")

story = []


def P(texto, estilo=cuerpo, **kw):
    return Paragraph(texto, estilo, **kw)


def tabla(encabezados, filas, anchos):
    datos = [[P(h, celda_b) for h in encabezados]]
    for fila in filas:
        datos.append([P(c, celda) for c in fila])
    t = Table(datos, colWidths=[a * mm for a in anchos], hAlign="LEFT")
    t.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#9AA7B6")),
        ("BACKGROUND", (0, 0), (-1, 0), FONDO),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 3),
        ("RIGHTPADDING", (0, 0), (-1, -1), 3),
        ("TOPPADDING", (0, 0), (-1, -1), 2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
    ]))
    story.append(t)
    story.append(Spacer(1, 2.2 * mm))


story.append(P("Informe post-incidente - Mantenimiento de VoltTech", titulo_doc))
story.append(P(f"Bases de Datos II · Comisión 4 · {ALUMNO} · {MANUAL['motor']} · Base: volttech_u6 · {FECHA}", subtitulo))
story.append(P(f'Repositorio: <link href="{REPO}" color="#2E6DA4">{REPO}</link>', ParagraphStyle(
    "repo", fontName="Arial", fontSize=7.8, leading=9.4, textColor=GRIS, spaceAfter=3)))

story.append(P("1. Respaldo utilizado", seccion))
tabla(
    ["Dato", "Valor"],
    [
        ["Archivo", f"{m['respaldo_archivo']} (formato custom -Fc, compresión -Z 6)"],
        ["Fecha y hora", f"{m['respaldo_fecha'][:10]}, ejecución {RANGO} ({DURACION} s)"],
        ["Tamaño e integridad", f"{fmt(m['respaldo_bytes'])} bytes ({mb} MB), {TOC} objetos; SHA-256 {m['respaldo_sha256'][:16]}…{m['respaldo_sha256'][-8:]}"],
        ["Identidad", "mant_backup (solo lectura + INSERT en bitácora), sin contraseña en el script"],
    ],
    [36, 150],
)

story.append(P("2. RPO y RTO: previsto vs. observado", seccion))
tabla(
    ["Métrica", "Previsto", "Observado", "Cumple"],
    [
        ["RPO (pérdida máxima de datos)", "≤ 24 h (respaldo diario)", rpo_txt + " de antigüedad",
         "Sí" if m["rpo_cumple"] else "No"],
        ["RTO (tiempo de recuperación)", "≤ 20 min", f"{rto} s (createdb + pg_restore + validaciones)",
         "Sí" if m["rto_cumple"] else "No"],
    ],
    [58, 46, 62, 20],
)
story.append(P("El RTO se midió con cronómetro desde el instante anterior a createdb hasta completar la última validación. El RPO se calculó como la diferencia entre el inicio del simulacro y la fecha del .dump."))

story.append(P("3. Resultados de la validación", seccion))
story.append(P("Restauración en volttech_u6_restore_test con mant_restore (CREATEDB, sin superusuario), pg_restore --no-owner --no-privileges --exit-on-error -j 4:"))
story.append(P(
    f"Conteos coincidentes 7/7 contra el snapshot previo: {fmt(conteos['categoria'])} categorías, "
    f"{fmt(conteos['cliente'])} clientes, {fmt(conteos['producto'])} productos, {fmt(conteos['pedido'])} pedidos, "
    f"{fmt(conteos['detalle_pedido'])} líneas, suma de cantidades {fmt(conteos['suma_cantidad'])} e importe "
    f"{fmt(int(conteos['suma_importe']))},00.", vineta, bulletText="•"))
for texto in (
    f"productos_invalidos = 0 y detalles_invalidos = 0 (precio, stock y cantidad dentro de rango).",
    "Huérfanos referenciales = 0 en pedido→cliente y línea→pedido/producto.",
    f"{m['restricciones']} restricciones declarativas restauradas y vista de compatibilidad public.detalle_pedido presente.",
    "Objetos de la app VoltTech verificados: vistas v_productos_vigentes, v_pedidos_cliente y "
    "v_detalle_pedido_producto, vista materializada mv_facturacion_categoria_mes (repoblada con REFRESH), "
    "procedimientos registrar_pedido y ajustar_stock, y extensión pg_trgm.",
    "volttech_u6 no se tocó: el script aborta si el destino no termina en _restore_test.",
):
    story.append(P(texto, vineta, bulletText="•"))

story.append(P("4. Problema real encontrado", seccion))
story.append(P(MANUAL["problema"]))

story.append(P("5. Mejora concreta", seccion))
story.append(P(MANUAL["mejora"]))

story.append(P("6. Uso de IA (OpenCode) y verificación", seccion))
story.append(P(MANUAL["ia"] + f" La autoevaluación soporte/verificar_entrega.ps1 terminó con "
                f"{AUTO_PASS} PASS / {AUTO_FAIL} FAIL, y las salidas crudas quedaron en evidencias/ "
                "(restore_metrics.json, logs, health checks y listado del dump)."))

doc = SimpleDocTemplate(
    SALIDA,
    pagesize=A4,
    leftMargin=12 * mm,
    rightMargin=12 * mm,
    topMargin=9 * mm,
    bottomMargin=9 * mm,
    title="Informe U6 - Mantenimiento VoltTech",
    author=ALUMNO,
)
doc.build(story)
print(f"PDF generado: {SALIDA}")
print(f"Páginas: {doc.page}")
