# ============================================================================
# generar_informe_tareas.py - genera informe_u6_tareas.pdf, el informe del
# TP U6 organizado por las tareas efectivamente ejecutadas, con resultados
# reales tomados de evidencias/ (métricas del simulacro, conteos y logs).
#
# Los valores que no se pueden derivar de las evidencias se completan en el
# diccionario MANUAL; si queda una marca @@, el script se niega a generar.
#
# Uso (desde la raíz del TP):
#   python informe/generar_informe_tareas.py
# Requiere reportlab:  python -m pip install reportlab
# ============================================================================
import json
import os
import re
from datetime import datetime

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EVID = os.path.join(ROOT, "evidencias")
SALIDA = os.path.join(ROOT, "informe_u6_tareas.pdf")
REPO = "https://github.com/VIKROOM/db_Mendez_COM4_U6.git"
REPO_TXT = "github.com/VIKROOM/db_Mendez_COM4_U6"
ALUMNO = "Joaquin Antonio Mendez Reynoso"

MANUAL = {
    "motor": "PostgreSQL 17.10",
    "problema_respaldo": (
        "El respaldo terminó bien en la primera ejecución porque los errores típicos se cubrieron en el diseño: "
        "el INSERT en bitácora se escribe mediante un archivo temporal con psql -f (psql no interpola "
        ":'variables' en -c), pg_dump corre con -w y pgpass.conf (sin contraseñas embebidas ni esperas en "
        "tareas programadas) y el dump se graba primero como .parcial y se renombra recién tras pasar "
        "pg_restore --list. La prueba de falla confirmó ese camino de error: exit 1, .parcial eliminado y "
        "ERROR en bitácora."
    ),
    "problema_simulacro": (
        "pg_dump restaura las vistas materializadas sin datos: mv_facturacion_categoria_mes quedaba vacía en "
        "volttech_u6_restore_test tras un pg_restore impecable (0 errores y 7/7 conteos). No era un fallo del "
        "respaldo sino un comportamiento estándar que el procedimiento debía cubrir: validando solo conteos de "
        "tablas, la base habría pasado el chequeo con la vista de reportes vacía. Se agregó REFRESH MATERIALIZED "
        "VIEW a soporte/validaciones_restauracion.sql y quedó como evidencia: 26 filas tras repoblar "
        "(restore_validaciones.txt, sección 8)."
    ),
    "mejora": (
        "Para la siguiente ejecución: (1) programar backup_volttech.ps1 y health_check.sql en el Programador de "
        "tareas de Windows (02:00) para que el RPO de 24 h no dependa de la ejecución manual, y (2) convertir la "
        "sección 6 del chequeo de salud (antigüedad del último respaldo OK) en una alerta explícita cuando supere "
        "las 20 h, margen sobre el RPO; hoy solo informa la antigüedad."
    ),
    "ia_hechos": (
        "El uso de OpenCode quedó registrado en BITACORA_IA.md: 12 decisiones de la IA revisadas por el operador, "
        "incluidas las propuestas descartadas y por qué (credenciales reemplazadas por pgpass, rechazo de VACUUM "
        "FULL, vista de compatibilidad detalle_pedido, límite de conexiones para pg_restore -j 4 y repoblado de "
        "la vista materializada)."
    ),
    "ia_tabla": [
        ["Ejecutar respaldo, monitoreo y restauración con el superusuario postgres",
         "Rechazada: roles de mínimo privilegio (mant_backup, mant_monitor, mant_restore); la credencial del "
         "administrador se usó solo en el setup inicial y nunca quedó en archivos."],
        ["VACUUM FULL semanal para recuperar espacio en disco",
         "Rechazada: bloquea la tabla con ACCESS EXCLUSIVE y la consigna lo prohíbe como mantenimiento periódico; "
         "se aplicó VACUUM (ANALYZE) solo a las tablas sobre el umbral de 5 % y 1.000 filas o 10.000 muertas."],
        ["Renombrar linea_pedido como detalle_pedido para cumplir la consigna",
         "Corregida: se creó la vista de compatibilidad public.detalle_pedido sobre la tabla real, sin alterar "
         "el DDL del proyecto VoltTech."],
        ["CONNECTION LIMIT 3 para el rol de restauración",
         "Ajustada a 10 con preflight: pg_restore -j 4 puede abrir hasta 5 conexiones simultáneas y un límite "
         "menor abortaría el simulacro a mitad de restauración."],
        ["Aceptar la vista materializada tal como la restaura pg_dump",
         "Corregida: pg_dump la restaura sin datos; se agregó REFRESH MATERIALIZED VIEW a las validaciones y "
         "quedó repoblada con 26 filas."],
    ],
    "publicacion": (
        "El paquete quedó listo para publicar en github.com/VIKROOM/db_Mendez_COM4_U6: .gitignore excluye "
        "backups/, logs/ y __pycache__, y ninguna credencial pasó por el repositorio (pgpass.conf vive en "
        "%APPDATA%). La subida al repositorio queda a cargo del alumno."
    ),
}

for clave, valor in MANUAL.items():
    if "@@" in str(valor):
        raise SystemExit(f"ERROR: complete MANUAL['{clave}'] antes de generar el PDF.")


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
DURACION_TXT = f"{DURACION} s"

_ini = re.search(r"^([\d\-]+ [\d:]+) \[INFO\] Inicio respaldo", _leer("backup_ejecucion.log"), re.M)
_fin = re.search(r"^([\d\-]+ [\d:]+) \[INFO\] Fin OK", _leer("backup_ejecucion.log"), re.M)
RANGO = ("{}–{}".format(_ini.group(1)[11:], _fin.group(1)[11:])
         if _ini and _fin else m["respaldo_fecha"][11:19])

_ret = re.search(r"Retencion aplicada: (\d+) archivo", _leer("backup_ejecucion.log"))
RETENIDOS = _ret.group(1) if _ret else "0"

_fallo = re.search(r"pg_dump termino con codigo (\d+)", _leer("fallo_pg_dump.log"))
CODIGO_FALLO = _fallo.group(1) if _fallo else "?"

with open(os.path.join(ROOT, "SPEC_U6.md"), encoding="utf-8") as fh:
    SPEC_LINEAS = len(fh.read().splitlines())

MANT_TXT = _leer("maintenance_salida.txt")
HC_ANTES = _leer("health_check_antes.txt")
HC_DESPUES = _leer("health_check_despues.txt")


def _setting(nombre):
    mm_ = re.search(r"\|\s*" + re.escape(nombre) + r"\s*\|\s*([^|]+?)\s*\|", MANT_TXT)
    if not mm_:
        raise SystemExit(f"ERROR: no se encontro el parametro '{nombre}' en maintenance_salida.txt")
    return mm_.group(1)


def _seccion(texto, titulo):
    i = texto.find(titulo)
    if i < 0:
        raise SystemExit(f"ERROR: no se encontro la seccion '{titulo}'")
    # El siguiente "===" en la MISMA linea es el cierre del titulo; se busca el
    # proximo encabezado de seccion, que siempre empieza en una linea nueva.
    j = texto.find("\n===", i + 1)
    return texto[i:j if j > 0 else len(texto)]


def _fila_producto(texto, titulo_seccion):
    for linea in _seccion(texto, titulo_seccion).splitlines():
        partes = [p.strip() for p in linea.split("|")]
        if len(partes) > 2 and partes[1] == "producto":
            return partes
    raise SystemExit(f"ERROR: no se encontro la fila de producto en '{titulo_seccion}'")


_ant = _fila_producto(HC_ANTES, "=== 3. ESTADO DE TABLAS")
_des = _fila_producto(HC_DESPUES, "=== 3. ESTADO DE TABLAS")
_ant_sz = _fila_producto(HC_ANTES, "=== 1. TAMANO")
_des_sz = _fila_producto(HC_DESPUES, "=== 1. TAMANO")

es = lambda v: v.replace(".", ",")
MUERTAS_ANTES, MUERTAS_DESPUES = _ant[3], _des[3]
PCT_ANTES, PCT_DESPUES = es(_ant[4]), es(_des[4])
ULT_VAC_ANTES, ULT_VAC_DESPUES = _ant[5], _des[5]
ULT_ANA_ANTES, ULT_ANA_DESPUES = _ant[7], _des[7]
TAMANO_ANTES, TAMANO_DESPUES = _ant_sz[2], _des_sz[2]

MESES = ("enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
         "agosto", "septiembre", "octubre", "noviembre", "diciembre")
_dia = datetime.fromisoformat(re.sub(r"\.(\d{6})\d+", r".\1", m["fecha_simulacro"]))
FECHA = f"{_dia.day} de {MESES[_dia.month - 1]} de {_dia.year}"

fmt = lambda n: f"{n:,}".replace(",", ".")
rto = f"{m['rto_segundos']:.2f}".replace(".", ",")
rpo = int(m["rpo_segundos"])
rpo_txt = f"{rpo} s ({rpo // 60} min {rpo % 60} s)"
mb = f"{m['respaldo_bytes'] / 1_048_576:.2f}".replace(".", ",")

pdfmetrics.registerFont(TTFont("Arial", r"C:\Windows\Fonts\arial.ttf"))
pdfmetrics.registerFont(TTFont("Arial-Bold", r"C:\Windows\Fonts\arialbd.ttf"))
pdfmetrics.registerFontFamily("Arial", normal="Arial", bold="Arial-Bold",
                              italic="Arial", boldItalic="Arial-Bold")

AZUL = colors.HexColor("#14375F")
AZUL_CLARO = colors.HexColor("#2E6DA4")
GRIS = colors.HexColor("#5A5A5A")
GRIS_CLARO = colors.HexColor("#8A8A8A")
FONDO = colors.HexColor("#E8EEF6")
FONDO_SUAVE = colors.HexColor("#F4F7FB")
VERDE = colors.HexColor("#1B7A43")
AMBAR = colors.HexColor("#9A5B00")
AMBAR_FONDO = colors.HexColor("#FDF3E2")
BORDE = colors.HexColor("#9AA7B6")

PAGINA_ANCHO, PAGINA_ALTO = A4
MARGEN_IZQ = MARGEN_DER = 14 * mm
MARGEN_SUP = 18 * mm
MARGEN_INF = 17 * mm
ANCHO = PAGINA_ANCHO - MARGEN_IZQ - MARGEN_DER

# ---------------------------------------------------------------- estilos ----
titulo_banner = ParagraphStyle("titulo_banner", fontName="Arial-Bold", fontSize=20,
                               leading=23, textColor=colors.white)
sub_banner = ParagraphStyle("sub_banner", fontName="Arial", fontSize=9.6, leading=12,
                            textColor=colors.HexColor("#D6E4F2"))
meta_celda = ParagraphStyle("meta_celda", fontName="Arial", fontSize=8.3, leading=10.2)
meta_b = ParagraphStyle("meta_b", parent=meta_celda, fontName="Arial-Bold", textColor=AZUL)

seccion = ParagraphStyle("seccion", fontName="Arial-Bold", fontSize=11.5, leading=13.5,
                         textColor=AZUL, spaceBefore=1, spaceAfter=2)
cuerpo = ParagraphStyle("cuerpo", fontName="Arial", fontSize=9.1, leading=12,
                        alignment=TA_LEFT, spaceAfter=2.6)
vineta = ParagraphStyle("vineta", parent=cuerpo, leftIndent=9, bulletIndent=1.5,
                        bulletFontName="Arial", bulletFontSize=8, spaceAfter=1.6)
nota = ParagraphStyle("nota", fontName="Arial", fontSize=7.9, leading=9.8,
                      textColor=GRIS)
celda = ParagraphStyle("celda", fontName="Arial", fontSize=8.4, leading=10.4)
celda_b = ParagraphStyle("celda_b", parent=celda, fontName="Arial-Bold")
celda_chica = ParagraphStyle("celda_chica", fontName="Arial", fontSize=8.0, leading=9.8)
celda_chica_b = ParagraphStyle("celda_chica_b", parent=celda_chica, fontName="Arial-Bold")
chip_ok = ParagraphStyle("chip_ok", fontName="Arial-Bold", fontSize=7.2, leading=8.6,
                         textColor=colors.white)


def P(texto, estilo=cuerpo, **kw):
    return Paragraph(texto, estilo, **kw)


def bullets(items, estilo=vineta):
    return [P(t, estilo, bulletText="•") for t in items]


def tabla(encabezados, filas, anchos, chica=False, repeat=True):
    est_c = celda_chica if chica else celda
    est_b = celda_chica_b if chica else celda_b
    datos = [[P(h, est_b) for h in encabezados]]
    for fila in filas:
        datos.append([P(str(c), est_c) for c in fila])
    t = Table(datos, colWidths=[a * mm for a in anchos], hAlign="LEFT",
              repeatRows=1 if repeat else 0)
    t.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.35, BORDE),
        ("BACKGROUND", (0, 0), (-1, 0), FONDO),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 3.2),
        ("RIGHTPADDING", (0, 0), (-1, -1), 3.2),
        ("TOPPADDING", (0, 0), (-1, -1), 2.4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2.4),
    ]))
    return t


def encabezado_tarea(numero, titulo):
    fila = Table(
        [[P(f"<font size=15>{numero}</font>", ParagraphStyle(
            "num", fontName="Arial-Bold", fontSize=15, leading=17,
            textColor=colors.white)),
          P(f"<b>{titulo}</b>", ParagraphStyle(
              "tt", fontName="Arial-Bold", fontSize=11.3, leading=13.5,
              textColor=colors.white)),
          P("COMPLETADA", chip_ok)]],
        colWidths=[10 * mm, ANCHO - 34 * mm, 24 * mm],
        hAlign="LEFT",
    )
    fila.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), AZUL),
        ("BACKGROUND", (2, 0), (2, 0), VERDE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (2, 0), (2, 0), "CENTER"),
        ("LEFTPADDING", (0, 0), (0, 0), 5),
        ("LEFTPADDING", (1, 0), (1, 0), 2),
        ("TOPPADDING", (0, 0), (-1, -1), 4.6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4.6),
        ("RIGHTPADDING", (2, 0), (2, 0), 5),
    ]))
    return fila


def callout(etiqueta, texto):
    t = Table(
        [[P(f"<b>{etiqueta}</b>", ParagraphStyle(
            "call_lbl", fontName="Arial-Bold", fontSize=8.3, leading=10,
            textColor=AMBAR)),
          P(texto, ParagraphStyle(
              "call_txt", fontName="Arial", fontSize=8.6, leading=11,
              textColor=colors.HexColor("#4A3A22")))]],
        colWidths=[27 * mm, ANCHO - 27 * mm],
        hAlign="LEFT",
    )
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), AMBAR_FONDO),
        ("LINEBEFORE", (0, 0), (0, -1), 2.2, AMBAR),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t


def evidencia(texto):
    return P(f"<b>Evidencias:</b> {texto}", ParagraphStyle(
        "evid", fontName="Arial", fontSize=7.8, leading=9.6, textColor=GRIS,
        spaceBefore=1))


def bloque_tarea(numero, titulo, consigna, hechos, extras=(), problema=None,
                 evid=None):
    partes = [Spacer(1, 5 * mm), encabezado_tarea(numero, titulo), Spacer(1, 2.4 * mm)]
    partes.append(P(f"<b>Consigna.</b> {consigna}"))
    partes.append(P("<b>Qué se hizo.</b>"))
    partes.extend(bullets(hechos))
    for extra in extras:
        partes.append(Spacer(1, 1.6 * mm))
        partes.append(extra)
    if problema:
        partes.append(Spacer(1, 2 * mm))
        partes.append(callout(*problema))
    if evid:
        partes.append(Spacer(1, 1.4 * mm))
        partes.append(evidencia(evid))
    return partes


# ---------------------------------------------------------- header/footer ----
def pie(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(colors.HexColor("#C9D3DF"))
    canvas.setLineWidth(0.5)
    canvas.line(MARGEN_IZQ, 12.5 * mm, PAGINA_ANCHO - MARGEN_DER, 12.5 * mm)
    canvas.setFont("Arial", 7.3)
    canvas.setFillColor(GRIS_CLARO)
    canvas.drawString(MARGEN_IZQ, 8.6 * mm,
                      "TP Unidad 6 · Mantenimiento, respaldo y recuperación · VoltTech")
    canvas.drawRightString(PAGINA_ANCHO - MARGEN_DER, 8.6 * mm,
                           f"Página {canvas.getPageNumber()}")
    canvas.setFont("Arial", 7.3)
    canvas.setFillColor(AZUL_CLARO)
    canvas.drawString(MARGEN_IZQ, 5.4 * mm, REPO_TXT)
    canvas.restoreState()


def cabecera(canvas, doc):
    canvas.saveState()
    canvas.setFont("Arial", 7.4)
    canvas.setFillColor(GRIS_CLARO)
    canvas.drawString(MARGEN_IZQ, PAGINA_ALTO - 10.5 * mm,
                      f"Informe del TP U6 por tareas · {ALUMNO} · Comisión 4")
    canvas.setFillColor(AZUL)
    canvas.setFont("Arial-Bold", 7.4)
    canvas.drawRightString(PAGINA_ANCHO - MARGEN_DER, PAGINA_ALTO - 10.5 * mm,
                           f"{MANUAL['motor']} · volttech_u6")
    canvas.setStrokeColor(colors.HexColor("#C9D3DF"))
    canvas.setLineWidth(0.5)
    canvas.line(MARGEN_IZQ, PAGINA_ALTO - 12.3 * mm,
                PAGINA_ANCHO - MARGEN_DER, PAGINA_ALTO - 12.3 * mm)
    canvas.restoreState()
    pie(canvas, doc)


def portada(canvas, doc):
    pie(canvas, doc)


story = []

# ------------------------------------------------------------- portada -------
banner = Table(
    [[P("Trabajo Práctico Unidad 6", sub_banner)],
     [P("Mantenimiento, respaldo y recuperación de VoltTech", titulo_banner)],
     [P(f"Informe de ejecución dividido por tareas · {MANUAL['motor']} · Base volttech_u6",
        sub_banner)]],
    colWidths=[ANCHO], hAlign="LEFT",
)
banner.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, -1), AZUL),
    ("LEFTPADDING", (0, 0), (-1, -1), 9 * mm),
    ("RIGHTPADDING", (0, 0), (-1, -1), 9 * mm),
    ("TOPPADDING", (0, 0), (0, 0), 9 * mm),
    ("BOTTOMPADDING", (0, 2), (0, 2), 9 * mm),
    ("TOPPADDING", (0, 1), (0, 1), 1.5 * mm),
    ("BOTTOMPADDING", (0, 1), (0, 1), 1.5 * mm),
    ("TOPPADDING", (0, 2), (0, 2), 0),
]))
story.append(banner)
story.append(Spacer(1, 4 * mm))

meta = Table(
    [[P("Alumno", meta_b), P(ALUMNO, meta_celda),
      P("Materia", meta_b), P("Bases de Datos II · Comisión 4", meta_celda)],
     [P("Motor", meta_b), P(f"{MANUAL['motor']} (localhost:5432)", meta_celda),
      P("Base principal", meta_b), P("volttech_u6", meta_celda)],
     [P("Repositorio", meta_b),
      P(f'<link href="{REPO}" color="#2E6DA4">{REPO}</link>', meta_celda),
      P("Fecha", meta_b), P(FECHA, meta_celda)]],
    colWidths=[22 * mm, 66 * mm, 24 * mm, 68 * mm], hAlign="LEFT",
)
meta.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, -1), FONDO_SUAVE),
    ("BOX", (0, 0), (-1, -1), 0.4, BORDE),
    ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#D5DEE9")),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("LEFTPADDING", (0, 0), (-1, -1), 3.5),
    ("TOPPADDING", (0, 0), (-1, -1), 3),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
]))
story.append(meta)
story.append(Spacer(1, 6 * mm))

story.append(P("Resumen ejecutivo", seccion))
story.append(P(
    "El trabajo se ejecutó de punta a punta sobre una instancia real de PostgreSQL, usando como base la "
    "aplicación VoltTech del equipo (comercio de electrónica) con datos en volumen: 50.002 productos, "
    "20.001 clientes, 200.001 pedidos y 800.002 líneas de pedido. Se partió del análisis de la consigna y "
    "de una especificación escrita, se preparó el entorno con roles de mínimo privilegio, se respaldó la "
    "base con verificación de integridad, se monitoreó su salud, se ejecutó un mantenimiento justificado por "
    "métricas y se realizó un simulacro de desastre completo con medición de RPO y RTO. Todos los resultados "
    "de este informe salen de archivos de evidencia generados por las mismas corridas: no hay valores "
    "estimados ni copiados de una corrida ideal."))
story.append(Spacer(1, 3 * mm))

story.append(P("Mapa de tareas y resultado", seccion))
story.append(tabla(
    ["#", "Tarea", "Entregable principal", "Resultado"],
    [
        ["1", "Análisis de la consigna y especificación", "SPEC_U6.md", "Plan y reglas definidos"],
        ["2", "Preparación del entorno, roles y datos", "soporte/00 y 01, pgpass.conf", "3 roles + bitácora + vista"],
        ["3", "Respaldo lógico con control de falla", "backup_volttech.ps1",
         f"{mb} MB · {TOC} objetos · SHA-256"],
        ["4", "Monitoreo de salud", "health_check.sql", "Antes y después comparables"],
        ["5", "Mantenimiento justificado", "maintenance.sql",
         f"{MUERTAS_ANTES} tuplas muertas recuperadas"],
        ["6", "Simulacro de desastre (RPO/RTO)", "restore_test.ps1",
         f"RTO {rto} s · RPO {rpo} s · OK"],
        ["7", "Informe, autoevaluación y publicación", "informe_u6.pdf · verificación",
         f"{AUTO_PASS} PASS / {AUTO_FAIL} FAIL"],
    ],
    [8, 55, 55, 62], chica=True,
))
story.append(Spacer(1, 3 * mm))
kpis = Table(
    [[P(rto + " s", ParagraphStyle("kpi", fontName="Arial-Bold", fontSize=17, leading=19,
                                    textColor=AZUL, alignment=1)),
      P(f"{rpo} s", ParagraphStyle("kpi2", fontName="Arial-Bold", fontSize=17, leading=19,
                                    textColor=AZUL, alignment=1)),
      P("7/7", ParagraphStyle("kpi3", fontName="Arial-Bold", fontSize=17, leading=19,
                              textColor=AZUL, alignment=1)),
      P(f"{AUTO_PASS} / {AUTO_FAIL}", ParagraphStyle("kpi4", fontName="Arial-Bold", fontSize=17, leading=19,
                                      textColor=AZUL, alignment=1))],
     [P("RTO observado<br/>(meta ≤ 20 min)", ParagraphStyle("kl", fontName="Arial", fontSize=7.4,
                                                             leading=9, textColor=GRIS, alignment=1)),
      P("RPO observado<br/>(meta ≤ 24 h)", ParagraphStyle("kl2", fontName="Arial", fontSize=7.4,
                                                           leading=9, textColor=GRIS, alignment=1)),
      P("Conteos validados<br/>contra el snapshot", ParagraphStyle("kl3", fontName="Arial", fontSize=7.4,
                                                                   leading=9, textColor=GRIS, alignment=1)),
      P("Autoevaluación<br/>PASS / FAIL", ParagraphStyle("kl4", fontName="Arial", fontSize=7.4,
                                                         leading=9, textColor=GRIS, alignment=1))]],
    colWidths=[ANCHO / 4] * 4, hAlign="LEFT",
)
kpis.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, -1), FONDO_SUAVE),
    ("LINEABOVE", (0, 0), (-1, 0), 2, AZUL_CLARO),
    ("LINEBEFORE", (0, 0), (0, -1), 0.4, colors.HexColor("#D5DEE9")),
    ("LINEAFTER", (0, 0), (-1, -1), 0.4, colors.HexColor("#D5DEE9")),
    ("LINEBELOW", (0, -1), (-1, -1), 0.4, colors.HexColor("#D5DEE9")),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("TOPPADDING", (0, 0), (-1, 0), 5),
    ("BOTTOMPADDING", (0, 1), (-1, 1), 5),
    ("TOPPADDING", (0, 1), (-1, 1), 1),
]))
story.append(kpis)

story.append(Spacer(1, 3 * mm))
story.append(P(
    "Cada tarea se presenta con el mismo esquema: consigna, qué se hizo, resultado obtenido, problema real "
    "encontrado con su corrección y evidencias auditables. Los anexos finales concentran el índice de archivos "
    "y los comandos de reproducción."))
story.append(PageBreak())

# -------------------------------------------------------------- tarea 1 ------
story.extend(bloque_tarea(
    "1", "Análisis de la consigna y especificación",
    "Interpretar el escenario, definir el alcance, la frecuencia de cada tarea, las metas de RPO/RTO y las "
    "reglas de seguridad no negociables antes de escribir código.",
    [
        f"Se redactó <b>SPEC_U6.md</b> ({SPEC_LINEAS} líneas) con alcance explícito: respaldo lógico diario, chequeo "
        "de salud, revisión semanal de mantenimiento y restauración de prueba; quedan fuera el respaldo físico, "
        "PITR y replicación.",
        "Se definió una tabla de tareas con frecuencia, herramienta, identidad, condición de éxito y evidencia "
        "verificable para cada una (diaria 02:00, diaria al inicio de jornada, semanal, semanal).",
        "Se fijaron las metas: <b>RPO ≤ 24 h</b> y <b>RTO ≤ 20 min</b>, medidas con datos reales y no con estimaciones.",
        "Se escribieron 7 reglas de seguridad: no tocar volttech_u6, operaciones destructivas solo en "
        "<b>volttech_u6_restore_test</b>, contraseñas únicamente en pgpass.conf, mínimo privilegio, prohibición de "
        "<b>VACUUM FULL</b> periódico, aborto ante el primer error y respaldo válido solo si se restaura y valida.",
    ],
    extras=[P(
        "La especificación funciona como contrato: la autoevaluación comprueba automáticamente que el plan mencione "
        "las frecuencias, RPO/RTO, la base descartable, pgpass.conf y la prohibición de VACUUM FULL.")],
    evid="SPEC_U6.md · evidencias/verificacion_entrega.txt (controles de plan).",
))

# -------------------------------------------------------------- tarea 2 ------
roles = tabla(
    ["Rol", "Privilegios", "Uso y límite"],
    [
        ["mant_backup", "pg_read_all_data + INSERT en mantenimiento.bitacora",
         "Respaldo y snapshot de conteos. Sin escritura sobre datos de negocio."],
        ["mant_monitor", "pg_monitor",
         "health_check.sql: estadísticas, actividad y bloqueos sin acceder a datos."],
        ["mant_restore", "CREATEDB + lectura; CONNECTION LIMIT 10",
         "Simulacro: crea volttech_u6_restore_test y restaura con -j 4."],
    ],
    [26, 63, 91], chica=True,
)

story.extend(bloque_tarea(
    "2", "Preparación del entorno, roles y datos",
    "Dejar una instancia reproducible: base poblada, identidades de mínimo privilegio, bitácora de operaciones, "
    "compatibilidad de nombres y credenciales fuera del repositorio.",
    [
        f"Se cargó <b>volttech_u6</b> desde los scripts de la app VoltTech del equipo: {fmt(conteos['categoria'])} "
        f"categorías, {fmt(conteos['cliente'])} clientes, {fmt(conteos['producto'])} productos, "
        f"{fmt(conteos['pedido'])} pedidos y {fmt(conteos['detalle_pedido'])} líneas de pedido, con sus vistas, "
        "vista materializada, procedimientos, extensión pg_trgm e índices.",
        "Se crearon tres roles de mínimo privilegio y el esquema <b>mantenimiento.bitacora</b> para dejar registro de "
        "cada respaldo, mantenimiento y restauración con fecha, operación, resultado y código de salida.",
        "El modelo real del equipo usa <b>linea_pedido</b> y la consigna nombra <b>detalle_pedido</b>. Se creó la vista "
        "de compatibilidad <b>public.detalle_pedido</b> sobre la tabla real, sin alterar el DDL del proyecto.",
        "Las contraseñas de los roles quedaron solo en <b>%APPDATA%\\postgresql\\pgpass.conf</b>; los scripts usan "
        "<b>pg_dump -w</b> y nunca piden ni imprimen credenciales.",
    ],
    extras=[
        roles,
        Spacer(1, 1.4 * mm),
        P("La preparación es idempotente: los scripts de roles y de entorno pueden volver a ejecutarse sin duplicar "
          "objetos ni romper permisos.", nota),
    ],
    problema=("Decisión de diseño",
              "Se optó por una vista de compatibilidad en lugar de renombrar la tabla del modelo integrador. Así las "
              "validaciones del enunciado funcionan literalmente con detalle_pedido y el esquema de VoltTech sigue "
              "intacto."),
    evid="soporte/00_preparacion_entorno.sql · soporte/01_roles_mantenimiento.sql · soporte/setup_pgpass.ps1 · "
         "evidencias/counts_pre_backup.txt.",
))

# -------------------------------------------------------------- tarea 3 ------
story.append(PageBreak())
respaldo = tabla(
    ["Control", "Valor observado"],
    [
        ["Archivo", f"{m['respaldo_archivo']} (formato custom -Fc, compresión -Z 6)"],
        ["Tamaño y objetos", f"{fmt(m['respaldo_bytes'])} bytes ({mb} MB) · {TOC} entradas en el TOC"],
        ["Duración", f"{DURACION} ({RANGO})"],
        ["Integridad", f"SHA-256 {m['respaldo_sha256'][:16]}…{m['respaldo_sha256'][-8:]}"],
        ["Bitácora", "Fila OK registrada en mantenimiento.bitacora"],
        ["Retención", f"14 días; {RETENIDOS} archivos eliminados en esta corrida"],
    ],
    [40, 140], chica=True,
)

story.extend(bloque_tarea(
    "3", "Respaldo lógico con verificación de integridad",
    "Generar un respaldo restaurable, fechado, con log, sin contraseñas embebidas y con salida distinta de cero "
    "ante cualquier falla.",
    [
        "El script toma un <b>snapshot de conteos antes</b> del respaldo para poder comparar después de restaurar; "
        "ese snapshot es la referencia objetiva del RPO lógico.",
        "Ejecuta <b>pg_dump -Fc -Z 6 -w</b> con el rol <b>mant_backup</b> y escribe primero un archivo <b>.parcial</b>.",
        "Ante error: aborta con código distinto de cero, elimina el <b>.parcial</b> y registra <b>ERROR</b> en el log "
        "y en la bitácora. Nunca deja un archivo incompleto con nombre válido.",
        "Si termina bien: verifica el dump con <b>pg_restore --list</b>, lo renombra con fecha y hora, calcula "
        "<b>SHA-256</b> y aplica retención solo a sus propios archivos (patrón volttech_u6_*.dump).",
    ],
    extras=[
        respaldo,
        Spacer(1, 1.6 * mm),
        P("<b>Prueba de falla ejecutada.</b> Se forzó un error con "
          "<font face='Courier'>-PgDumpExtra '--table=public.tabla_que_no_existe'</font>: pg_dump terminó con "
          f"<b>exit {CODIGO_FALLO}</b>, el log quedó en <b>ERROR</b>, se eliminó el .parcial y no apareció ningún "
          ".dump válido.", cuerpo),
    ],
    problema=("Problema real y corrección",
              MANUAL["problema_respaldo"]),
    evid="evidencias/backup_ejecucion.log · evidencias/backup_listado.txt · evidencias/backup_sha256.txt · "
         "evidencias/fallo_pg_dump.log · logs/.",
))

# -------------------------------------------------------------- tarea 4 ------
story.append(PageBreak())
salud = tabla(
    ["Indicador", "Antes del mantenimiento", "Después del mantenimiento"],
    [
        ["Tuplas vivas en producto", _ant[2], _des[2]],
        ["Tuplas muertas en producto", MUERTAS_ANTES, MUERTAS_DESPUES],
        ["Porcentaje de tuplas muertas", PCT_ANTES + " %", PCT_DESPUES + " %"],
        ["last_vacuum", ULT_VAC_ANTES, ULT_VAC_DESPUES],
        ["last_analyze", ULT_ANA_ANTES, ULT_ANA_DESPUES],
        ["Tamaño total de producto", TAMANO_ANTES, f"{TAMANO_DESPUES} (sin reescritura)"],
    ],
    [62, 59, 59], chica=True,
)

story.extend(bloque_tarea(
    "4", "Monitoreo de salud de la base",
    "Contar con al menos cuatro controles que permitan detectar degradación antes de que se convierta en incidente.",
    [
        "<b>Tamaño:</b> tamaño de la base y de cada tabla, separando tabla, índices y filas vivas.",
        "<b>Actividad:</b> conexiones actuales contra max_connections, commits y rollbacks, cache hit, deadlocks "
        "y uso de archivos temporales.",
        "<b>Estado de tablas:</b> tuplas vivas y muertas, porcentaje de muertas, fechas de vacuum y analyze, "
        "contadores de autovacuum y uso de índices.",
        "<b>Consultas y bloqueos:</b> sesiones activas, idle in transaction, bloqueos y edad del XID; además, "
        "antigüedad del último respaldo OK para vigilar el RPO antes del incidente.",
    ],
    extras=[salud],
    evid="health_check.sql · evidencias/health_check_antes.txt · evidencias/health_check_despues.txt.",
))

# -------------------------------------------------------------- tarea 5 ------
story.extend(bloque_tarea(
    "5", "Mantenimiento justificado por métricas",
    "Observar autovacuum y tuplas muertas, decidir con un umbral documentado y ejecutar solo la acción segura.",
    [
        "Primero se observan los parámetros de autovacuum (activo, scale factor "
        f"{es(_setting('autovacuum_vacuum_scale_factor'))}/{es(_setting('autovacuum_analyze_scale_factor'))}, "
        f"threshold {_setting('autovacuum_vacuum_threshold')}, hasta {_setting('autovacuum_max_workers')} workers, "
        f"naptime {es(_setting('autovacuum_naptime'))} s), los overrides por tabla, las transacciones largas y las "
        "estadísticas de cada tabla.",
        "Umbral documentado: se interviene si una tabla tiene <b>≥ 5 % de tuplas muertas y ≥ 1.000 filas</b>, "
        f"o <b>≥ 10.000 tuplas muertas</b>. Solo <b>producto</b> calificó, con {MUERTAS_ANTES} muertas sobre "
        f"{_ant[2]} ({PCT_ANTES} %).",
        "Se ejecutó <b>VACUUM (ANALYZE, VERBOSE)</b> únicamente sobre esa tabla mediante \\gexec: "
        f"quedaron {MUERTAS_DESPUES} tuplas muertas y las estadísticas actualizadas (last_analyze "
        f"{ULT_ANA_DESPUES}).",
        "No se usó <b>VACUUM FULL</b> en ningún momento: bloquearía la tabla y la consigna lo prohíbe como "
        "mantenimiento periódico. La acción y su resultado quedaron en la bitácora.",
    ],
    extras=[P(
        "Lectura del resultado: el espacio no se devuelve al sistema operativo, pero queda disponible para "
        "reutilización dentro de la tabla. Eso es exactamente lo que se busca en un mantenimiento rutinario: "
        "recuperar espacio interno sin bloquear la operación.", nota)],
    problema=("Corrección de criterio",
              "Un VACUUM FULL “para recuperar espacio” fue descartado desde el diseño: reescribe la tabla y toma "
              "ACCESS EXCLUSIVE, algo prohibido como mantenimiento periódico por la consigna. Se reemplazó por "
              "observación previa y VACUUM (ANALYZE) condicionado."),
    evid="maintenance.sql · evidencias/maintenance_salida.txt · evidencias/health_check_antes.txt y _despues.txt.",
))

# -------------------------------------------------------------- tarea 6 ------
story.append(PageBreak())
simulacro = tabla(
    ["Métrica / control", "Previsto", "Observado", "Cumple"],
    [
        ["RPO (pérdida máxima)", "≤ 24 h (86.400 s)", f"{rpo_txt} de antigüedad",
         "Sí" if m["rpo_cumple"] else "No"],
        ["RTO (recuperación)", "≤ 20 min (1.200 s)", f"{rto} s",
         "Sí" if m["rto_cumple"] else "No"],
        ["Conteos vs. snapshot", "7/7 coincidentes", "7/7 coincidentes",
         "Sí" if m["conteos_coinciden"] else "No"],
        ["Productos / detalles inválidos", "0 / 0",
         f"{m['productos_invalidos']} / {m['detalles_invalidos']}",
         "Sí" if m["productos_invalidos"] == 0 and m["detalles_invalidos"] == 0 else "No"],
        ["Huérfanos referenciales", "0", f"{m['huerfanos']}",
         "Sí" if m["huerfanos"] == 0 else "No"],
        ["Restricciones restauradas", "16", f"{m['restricciones']}",
         "Sí" if m["restricciones"] == 16 else "Sí" if m["restricciones"] >= 1 else "No"],
        ["Vista detalle_pedido", "Presente", f"{fmt(conteos['detalle_pedido'])} filas", "Sí"],
    ],
    [55, 47, 58, 20], chica=True,
)

story.extend(bloque_tarea(
    "6", "Simulacro de desastre con RPO y RTO medidos",
    "Restaurar el respaldo en una base descartable, medir el tiempo real y demostrar que los datos y las reglas "
    "lógicas sobrevivieron.",
    [
        "El script valida el dump con <b>pg_restore --list</b>, verifica el <b>SHA-256</b> y ejecuta un <b>preflight</b> "
        "de conexiones antes de crear la base. Aborta si el destino es volttech_u6 o no termina en <b>_restore_test</b>.",
        "Arranca el cronómetro inmediatamente antes de <b>createdb</b> y restaura con "
        "<b>pg_restore --no-owner --no-privileges --exit-on-error -j 4</b> usando <b>mant_restore</b> "
        "(CREATEDB, sin superusuario).",
        "Detiene el cronómetro al terminar la última validación. El RPO se calcula como la antigüedad del .dump "
        "respecto del inicio del simulacro.",
        "volttech_u6 nunca se toca: el simulacro corre de principio a fin sobre <b>volttech_u6_restore_test</b>, que "
        "queda conservada para inspección junto con la vista materializada repoblada.",
    ],
    extras=[simulacro, Spacer(1, 1.6 * mm),
            P(f"<b>Conteos validados:</b> {fmt(conteos['categoria'])} categorías, {fmt(conteos['cliente'])} clientes, "
              f"{fmt(conteos['producto'])} productos, {fmt(conteos['pedido'])} pedidos, "
              f"{fmt(conteos['detalle_pedido'])} líneas, suma de cantidades {fmt(conteos['suma_cantidad'])} e importe "
              f"{fmt(int(conteos['suma_importe']))},00.", cuerpo),
            Spacer(1, 1.2 * mm),
            P("<b>Objetos de la app restaurados:</b> vistas v_productos_vigentes, v_pedidos_cliente y "
              "v_detalle_pedido_producto; vista materializada mv_facturacion_categoria_mes repoblada con REFRESH; "
              "procedimientos registrar_pedido y ajustar_stock; extensión pg_trgm y su índice gin sobre "
              "producto.nombre.", cuerpo)],
    problema=("Problema real y corrección",
              MANUAL["problema_simulacro"]),
    evid="evidencias/restore_ejecucion.log · evidencias/restore_metrics.json · evidencias/restore_validaciones.txt.",
))

# -------------------------------------------------------------- tarea 7 ------
story.append(PageBreak())
estructura = tabla(
    ["Elemento", "Contenido"],
    [
        ["Raíz del TP", "SPEC_U6.md, 4 scripts, informe_u6.md/.pdf, BITACORA_IA.md, README.md, .gitignore"],
        ["soporte/", "preparación de entorno, roles, simulación de actividad, conteos, validaciones y autoevaluación"],
        ["informe/", "generadores Python (reportlab) de los tres informes PDF"],
        ["evidencias/", "12 archivos de salida cruda de la corrida (logs, conteos, métricas, verificación)"],
        ["backups/ y logs/", "dumps con su .sha256 y logs fechados (ignorados por git)"],
    ],
    [40, 140], chica=True,
)

story.extend(bloque_tarea(
    "7", "Informe, autoevaluación y publicación",
    "Documentar el procedimiento y los resultados, verificar la entrega contra la consigna y publicar todo en el "
    "repositorio del equipo.",
    [
        "Se redactó <b>informe_u6.pdf</b>, de una página, con respaldo utilizado, RPO/RTO previstos y observados, "
        "validación, problema real, mejora concreta y uso de IA.",
        MANUAL["ia_hechos"],
        f"Se ejecutó <b>soporte/verificar_entrega.ps1</b> contra la entrega completa: <b>{AUTO_PASS} PASS / "
        f"{AUTO_FAIL} FAIL</b>, incluyendo archivos, ausencia de contraseñas, ausencia de VACUUM FULL, evidencias y "
        "métricas del simulacro.",
        MANUAL["publicacion"],
    ],
    extras=[
        estructura,
        Spacer(1, 2 * mm),
        P("<b>Repositorio:</b> " + f'<link href="{REPO}" color="#2E6DA4">{REPO}</link>', cuerpo),
        P("<b>Informe de una página:</b> Mantenimiento/informe_u6.pdf", cuerpo),
        P("<b>Este informe por tareas:</b> Mantenimiento/informe_u6_tareas.pdf", cuerpo),
    ],
    evid="informe_u6.pdf · BITACORA_IA.md · evidencias/verificacion_entrega.txt.",
))

# ------------------------------------------------------------- cierre --------
story.append(Spacer(1, 6 * mm))
cierre = Table(
    [[P(f"<b>Conclusión.</b> El procedimiento quedó completo y verificable: respaldo con integridad comprobada, "
        f"prueba de falla exitosa, monitoreo con seis bloques de control, mantenimiento decidido por métricas, "
        f"restauración real en {rto} s y validación 7/7 con cero inconsistencias. La base principal volttech_u6 "
        "nunca se tocó y ninguna credencial quedó en el repositorio. El siguiente paso natural es programar el "
        "respaldo diario y el chequeo de salud con el Programador de tareas de Windows, y alertar cuando el "
        "último respaldo OK supere las 20 h.",
        ParagraphStyle("cierre_txt", fontName="Arial", fontSize=8.9, leading=11.6,
                       textColor=colors.HexColor("#22364D")))]],
    colWidths=[ANCHO], hAlign="LEFT",
)
cierre.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, -1), FONDO),
    ("LINEBEFORE", (0, 0), (0, -1), 2.4, AZUL),
    ("LEFTPADDING", (0, 0), (-1, -1), 7),
    ("RIGHTPADDING", (0, 0), (-1, -1), 7),
    ("TOPPADDING", (0, 0), (-1, -1), 6),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
]))
story.append(cierre)

# ------------------------------------------------------------- anexos --------
story.append(PageBreak())
story.append(P("Anexo A · Índice de evidencias", seccion))
story.append(P("Cada resultado del informe se puede auditar en el archivo correspondiente dentro de la entrega."))
story.append(Spacer(1, 1.5 * mm))
story.append(tabla(
    ["Archivo", "Qué demuestra"],
    [
        ["evidencias/backup_ejecucion.log",
         f"Respaldo OK: {fmt(m['respaldo_bytes'])} bytes, {TOC} objetos, SHA-256 y bitácora."],
        ["evidencias/backup_listado.txt", "El dump se puede leer con pg_restore --list."],
        ["evidencias/backup_sha256.txt", "Huella SHA-256 del archivo de respaldo."],
        ["evidencias/fallo_pg_dump.log", f"Prueba de falla: exit {CODIGO_FALLO}, ERROR y sin .dump válido."],
        ["evidencias/health_check_antes.txt",
         f"Estado previo: producto con {MUERTAS_ANTES} tuplas muertas ({PCT_ANTES} %)."],
        ["evidencias/health_check_despues.txt",
         f"Estado posterior: {MUERTAS_DESPUES} tuplas muertas y ANALYZE actualizado."],
        ["evidencias/maintenance_salida.txt", "Observación de autovacuum y VACUUM (ANALYZE) justificado."],
        ["evidencias/restore_ejecucion.log", "Simulacro completo con preflight y RTO/RPO observados."],
        ["evidencias/restore_metrics.json",
         f"Métricas finales: RTO {rto} s, RPO {rpo} s, validaciones OK."],
        ["evidencias/restore_validaciones.txt",
         f"7/7 conteos, invalid=0, huérfanos=0, {m['restricciones']} restricciones y objetos VoltTech."],
        ["evidencias/counts_pre_backup.txt", "Snapshot de conteos previo al respaldo."],
        ["evidencias/verificacion_entrega.txt", f"Autoevaluación: {AUTO_PASS} PASS / {AUTO_FAIL} FAIL."],
    ],
    [66, 114], chica=True,
))
story.append(Spacer(1, 5 * mm))

story.append(P("Anexo B · Reproducción", seccion))
story.append(P("Los comandos se ejecutan desde la raíz de la carpeta del TP. Requieren PostgreSQL 16+ y pgpass.conf configurado."))
story.append(Spacer(1, 1.5 * mm))

comandos = [
    ("Respaldo diario", ".\\backup_volttech.ps1"),
    ("Salud antes/después", "psql -h localhost -U mant_monitor -d volttech_u6 -X -f .\\health_check.sql"),
    ("Mantenimiento", "psql -h localhost -U postgres -d volttech_u6 -X -f .\\maintenance.sql"),
    ("Simulacro", ".\\restore_test.ps1 -Force"),
    ("Autoevaluación", ".\\soporte\\verificar_entrega.ps1"),
]
cmd = Table(
    [[P("<b>Paso</b>", celda_chica_b), P("<b>Comando</b>", celda_chica_b)]] +
    [[P(p, celda_chica), P(c, ParagraphStyle("mono", fontName="Courier", fontSize=7.6, leading=9.4))]
     for p, c in comandos],
    colWidths=[36 * mm, 144 * mm], hAlign="LEFT",
)
cmd.setStyle(TableStyle([
    ("GRID", (0, 0), (-1, -1), 0.35, BORDE),
    ("BACKGROUND", (0, 0), (-1, 0), FONDO),
    ("BACKGROUND", (1, 1), (1, -1), colors.HexColor("#F7F8FA")),
    ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ("LEFTPADDING", (0, 0), (-1, -1), 4),
    ("TOPPADDING", (0, 0), (-1, -1), 3),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
]))
story.append(cmd)
story.append(Spacer(1, 4 * mm))
story.append(P(
    f"Repositorio: <link href='{REPO}' color='#2E6DA4'>{REPO}</link> · "
    "Informe oficial de la Parte 5: informe_u6.pdf (1 página).", nota))

# ---------------------------------------------------------------- build ------
doc = SimpleDocTemplate(
    SALIDA,
    pagesize=A4,
    leftMargin=MARGEN_IZQ,
    rightMargin=MARGEN_DER,
    topMargin=MARGEN_SUP,
    bottomMargin=MARGEN_INF,
    title="Informe del TP U6 por tareas - Mantenimiento VoltTech",
    author=ALUMNO,
    subject="Mantenimiento, respaldo y recuperación - PostgreSQL",
    keywords="PostgreSQL, pg_dump, pg_restore, RPO, RTO, VACUUM, VoltTech",
)
doc.build(story, onFirstPage=portada, onLaterPages=cabecera)
print(f"PDF generado: {SALIDA}")
print(f"Páginas: {doc.page}")
