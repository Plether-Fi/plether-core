#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0
"""Render the Plether Perps Markdown white paper as a publication PDF.

Pandoc is used only as a Markdown parser. ReportLab performs layout so the
result is deterministic, self-contained, and does not require a TeX runtime.
SVG charts are rasterized at publication resolution with rsvg-convert.
"""

from __future__ import annotations

import argparse
import html
import json
import math
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any, Iterable

from PIL import Image as PILImage
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch, mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Flowable,
    Frame,
    Image,
    KeepTogether,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus.tableofcontents import TableOfContents


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "WHITEPAPER.md"
DEFAULT_OUTPUT = ROOT.parents[1] / "output" / "pdf" / (
    "plether-perps-bounded-credit-whitepaper.pdf"
)
DEFAULT_TEMP = ROOT.parents[1] / "tmp" / "pdfs" / "plether-whitepaper"

PAGE_WIDTH, PAGE_HEIGHT = A4
LEFT_MARGIN = 20 * mm
RIGHT_MARGIN = 18 * mm
TOP_MARGIN = 20 * mm
BOTTOM_MARGIN = 19 * mm
CONTENT_WIDTH = PAGE_WIDTH - LEFT_MARGIN - RIGHT_MARGIN

INK = colors.black

PAPER_AUTHOR = "Stanisław Wasiutyński"
PAPER_ORGANIZATION = "Plether Labs"

Inline = dict[str, Any]
Block = dict[str, Any]


def register_fonts() -> None:
    font_dir = Path("/System/Library/Fonts/Supplemental")
    font_files = {
        "PaperSerif": font_dir / "Times New Roman.ttf",
        "PaperSerif-Bold": font_dir / "Times New Roman Bold.ttf",
        "PaperSerif-Italic": font_dir / "Times New Roman Italic.ttf",
        "PaperSerif-BoldItalic": font_dir / "Times New Roman Bold Italic.ttf",
    }
    for name, path in font_files.items():
        if not path.exists():
            raise FileNotFoundError(f"required publication font not found: {path}")
        pdfmetrics.registerFont(TTFont(name, str(path)))
    pdfmetrics.registerFontFamily(
        "PaperSerif",
        normal="PaperSerif",
        bold="PaperSerif-Bold",
        italic="PaperSerif-Italic",
        boldItalic="PaperSerif-BoldItalic",
    )


def make_styles() -> dict[str, ParagraphStyle]:
    sample = getSampleStyleSheet()
    body = ParagraphStyle(
        "Body",
        parent=sample["BodyText"],
        fontName="PaperSerif",
        fontSize=9.5,
        leading=12.5,
        textColor=INK,
        alignment=TA_JUSTIFY,
        spaceAfter=6,
        allowWidows=0,
        allowOrphans=0,
    )
    return {
        "body": body,
        "body_left": ParagraphStyle(
            "BodyLeft", parent=body, alignment=TA_LEFT
        ),
        "abstract": ParagraphStyle(
            "AbstractBody",
            parent=body,
            fontSize=9.25,
            leading=12.5,
            leftIndent=12 * mm,
            rightIndent=12 * mm,
            spaceAfter=7,
        ),
        "title_kicker": ParagraphStyle(
            "TitleKicker",
            fontName="PaperSerif",
            fontSize=10,
            leading=12,
            textColor=INK,
            alignment=TA_CENTER,
            spaceAfter=12,
        ),
        "title": ParagraphStyle(
            "Title",
            fontName="PaperSerif-Bold",
            fontSize=28,
            leading=33,
            textColor=INK,
            alignment=TA_CENTER,
            spaceAfter=14,
        ),
        "subtitle": ParagraphStyle(
            "Subtitle",
            fontName="PaperSerif",
            fontSize=14,
            leading=18,
            textColor=INK,
            alignment=TA_CENTER,
            leftIndent=18 * mm,
            rightIndent=18 * mm,
            spaceAfter=18,
        ),
        "thesis": ParagraphStyle(
            "Thesis",
            fontName="PaperSerif-Italic",
            fontSize=10.5,
            leading=14,
            textColor=INK,
            alignment=TA_CENTER,
            leftIndent=24 * mm,
            rightIndent=24 * mm,
            spaceBefore=18,
            spaceAfter=24,
        ),
        "title_meta": ParagraphStyle(
            "TitleMeta",
            fontName="PaperSerif",
            fontSize=9,
            leading=12,
            textColor=INK,
            alignment=TA_CENTER,
        ),
        "h1": ParagraphStyle(
            "WPHeading1",
            fontName="PaperSerif-Bold",
            fontSize=17,
            leading=21,
            textColor=INK,
            spaceBefore=4,
            spaceAfter=10,
            keepWithNext=True,
        ),
        "h2": ParagraphStyle(
            "WPHeading2",
            fontName="PaperSerif-Bold",
            fontSize=12,
            leading=15,
            textColor=INK,
            spaceBefore=13,
            spaceAfter=6,
            keepWithNext=True,
        ),
        "h3": ParagraphStyle(
            "WPHeading3",
            fontName="PaperSerif-Bold",
            fontSize=10.5,
            leading=13,
            textColor=INK,
            spaceBefore=10,
            spaceAfter=5,
            keepWithNext=True,
        ),
        "proposition": ParagraphStyle(
            "WPProposition",
            fontName="PaperSerif-Bold",
            fontSize=10.5,
            leading=13,
            textColor=INK,
            spaceBefore=11,
            spaceAfter=5,
            keepWithNext=True,
        ),
        "equation": ParagraphStyle(
            "Equation",
            fontName="PaperSerif-Italic",
            fontSize=10,
            leading=14,
            alignment=TA_CENTER,
            textColor=INK,
            spaceBefore=4,
            spaceAfter=7,
        ),
        "quote": ParagraphStyle(
            "Quote",
            fontName="PaperSerif-Italic",
            fontSize=10,
            leading=14,
            textColor=INK,
            leftIndent=12 * mm,
            rightIndent=12 * mm,
            spaceBefore=5,
            spaceAfter=10,
        ),
        "bullet": ParagraphStyle(
            "Bullet",
            parent=body,
            alignment=TA_LEFT,
            leftIndent=14,
            firstLineIndent=-9,
            bulletIndent=2,
            spaceAfter=3.2,
        ),
        "code": ParagraphStyle(
            "CodeBlock",
            fontName="Courier",
            fontSize=7.3,
            leading=10.2,
            textColor=INK,
            leftIndent=6 * mm,
            rightIndent=6 * mm,
            spaceBefore=5,
            spaceAfter=9,
        ),
        "table_header": ParagraphStyle(
            "TableHeader",
            fontName="PaperSerif-Bold",
            fontSize=7.2,
            leading=9,
            textColor=INK,
            alignment=TA_LEFT,
        ),
        "table_cell": ParagraphStyle(
            "TableCell",
            fontName="PaperSerif",
            fontSize=7.1,
            leading=9.1,
            textColor=INK,
            alignment=TA_LEFT,
        ),
        "table_cell_small": ParagraphStyle(
            "TableCellSmall",
            fontName="PaperSerif",
            fontSize=6.4,
            leading=8.1,
            textColor=INK,
            alignment=TA_LEFT,
        ),
        "caption": ParagraphStyle(
            "Caption",
            fontName="PaperSerif-Italic",
            fontSize=7.8,
            leading=10.4,
            textColor=INK,
            alignment=TA_CENTER,
            spaceBefore=4,
            spaceAfter=9,
        ),
        "toc_title": ParagraphStyle(
            "TOCTitle",
            fontName="PaperSerif-Bold",
            fontSize=17,
            leading=21,
            textColor=INK,
            spaceAfter=16,
        ),
    }


def _brace_group(source: str, start: int) -> tuple[str, int]:
    """Return a balanced brace group's contents and the first following index."""

    if start >= len(source) or source[start] != "{":
        raise ValueError("expected LaTeX brace group")
    depth = 0
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : index], index + 1
    raise ValueError("unterminated LaTeX brace group")


def _linearize_fractions(source: str) -> str:
    """Render nested ``\\frac`` expressions as unambiguous inline divisions."""

    output = source
    search_from = 0
    while True:
        marker = output.find(r"\frac", search_from)
        if marker < 0:
            return output
        cursor = marker + len(r"\frac")
        while cursor < len(output) and output[cursor].isspace():
            cursor += 1
        if cursor >= len(output) or output[cursor] != "{":
            search_from = cursor
            continue
        numerator, after_numerator = _brace_group(output, cursor)
        cursor = after_numerator
        while cursor < len(output) and output[cursor].isspace():
            cursor += 1
        if cursor >= len(output) or output[cursor] != "{":
            search_from = cursor
            continue
        denominator, after_denominator = _brace_group(output, cursor)
        replacement = (
            f"({_linearize_fractions(numerator)})"
            f"/({_linearize_fractions(denominator)})"
        )
        output = output[:marker] + replacement + output[after_denominator:]
        search_from = marker + len(replacement)


def _latex_normalized(source: str) -> str:
    """Convert the paper's compact LaTeX subset to readable linear notation."""

    text = _linearize_fractions(source.strip())
    text = re.sub(r"\\tilde\s+([A-Za-z])", lambda match: match.group(1) + "\u0303", text)
    replacements = {
        r"\mathrm": "",
        r"\text": "",
        r"\mathcal": "",
        r"\operatorname": "",
        r"\left": "",
        r"\right": "",
        r"\qquad": "   ",
        r"\quad": "  ",
        r"\,": " ",
        r"\;": " ",
        r"\!": "",
        r"\ ": " ",
        r"\sum": "Σ",
        r"\max": "max",
        r"\min": "min",
        r"\ge": "≥",
        r"\le": "≤",
        r"\in": " in ",
        r"\Delta": "Δ",
        r"\Pi": "Π",
        r"\square": "QED",
        r"\$": "$",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    text = text.replace("\\", "")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", " ", text)
    return text.strip()


def _subscript_markup(source: str) -> str:
    """Translate LaTeX sub/superscripts and grouping to ReportLab markup."""

    parts: list[str] = []
    index = 0
    while index < len(source):
        char = source[index]
        if char in {"_", "^"}:
            tag = "sub" if char == "_" else "super"
            index += 1
            if index < len(source) and source[index] == "{":
                value, index = _brace_group(source, index)
            elif index < len(source):
                value, index = source[index], index + 1
            else:
                parts.append(html.escape(char, quote=False))
                continue
            parts.append(f"<{tag}>{_subscript_markup(value)}</{tag}>")
        elif char == "{":
            value, index = _brace_group(source, index)
            parts.append(_subscript_markup(value))
        elif char == "}":
            index += 1
        else:
            parts.append(html.escape(char, quote=False))
            index += 1
    return "".join(parts)


def latex_to_markup(source: str) -> str:
    return _subscript_markup(_latex_normalized(source))


def latex_to_text(source: str) -> str:
    markup = latex_to_markup(source)
    return re.sub(r"<[^>]+>", "", html.unescape(markup))


def inlines_to_markup(inlines: Iterable[Inline]) -> str:
    parts: list[str] = []
    for inline in inlines:
        kind = inline["t"]
        value = inline.get("c")
        if kind == "Str":
            parts.append(html.escape(str(value), quote=False))
        elif kind == "Space":
            parts.append(" ")
        elif kind in {"SoftBreak", "LineBreak"}:
            parts.append("<br/>" if kind == "LineBreak" else " ")
        elif kind == "Strong":
            parts.append(f"<b>{inlines_to_markup(value)}</b>")
        elif kind == "Emph":
            parts.append(f"<i>{inlines_to_markup(value)}</i>")
        elif kind == "Strikeout":
            parts.append(f"<strike>{inlines_to_markup(value)}</strike>")
        elif kind == "Code":
            parts.append(
                f'<font name="Courier">{html.escape(value[1])}</font>'
            )
        elif kind == "Math":
            math_kind, formula = value
            rendered = latex_to_markup(formula)
            parts.append(f'<font name="PaperSerif-Italic">{rendered}</font>')
        elif kind == "Link":
            _, label, target = value
            url = html.escape(target[0], quote=True)
            parts.append(
                f'<link href="{url}" color="#000000">'
                f"{inlines_to_markup(label)}</link>"
            )
        elif kind == "Quoted":
            quote_type, quoted = value
            left, right = ('"', '"') if quote_type["t"] == "DoubleQuote" else ("'", "'")
            parts.append(left + inlines_to_markup(quoted) + right)
        elif kind == "Superscript":
            parts.append(f"<super>{inlines_to_markup(value)}</super>")
        elif kind == "Subscript":
            parts.append(f"<sub>{inlines_to_markup(value)}</sub>")
        elif kind == "SmallCaps":
            parts.append(inlines_to_markup(value).upper())
        elif kind == "Span":
            parts.append(inlines_to_markup(value[1]))
        elif kind == "Cite":
            parts.append(inlines_to_markup(value[1]))
        elif kind == "RawInline":
            parts.append(html.escape(value[1], quote=False))
        elif kind == "Note":
            parts.append(" [note]")
        elif kind == "Image":
            parts.append(inlines_to_markup(value[1]))
        else:
            raise ValueError(f"unsupported Pandoc inline: {kind}")
    return "".join(parts)


def inlines_to_plain(inlines: Iterable[Inline]) -> str:
    markup = inlines_to_markup(inlines)
    return re.sub(r"<[^>]+>", "", html.unescape(markup))


def block_plain(block: Block) -> str:
    kind = block["t"]
    value = block.get("c")
    if kind in {"Para", "Plain"}:
        return inlines_to_plain(value)
    if kind == "Header":
        return inlines_to_plain(value[2])
    if kind == "CodeBlock":
        return value[1]
    if kind in {"BulletList", "OrderedList"}:
        items = value if kind == "BulletList" else value[1]
        return " ".join(
            " ".join(block_plain(item_block) for item_block in item)
            for item in items
        )
    return ""


def cell_blocks(cell: list[Any]) -> list[Block]:
    return cell[4]


def row_cells(row: list[Any]) -> list[list[Any]]:
    return row[1]


def cell_markup(cell: list[Any]) -> str:
    chunks: list[str] = []
    for block in cell_blocks(cell):
        kind = block["t"]
        if kind in {"Para", "Plain"}:
            chunks.append(inlines_to_markup(block["c"]))
        elif kind in {"BulletList", "OrderedList"}:
            items = block["c"] if kind == "BulletList" else block["c"][1]
            for index, item in enumerate(items, 1):
                prefix = "• " if kind == "BulletList" else f"{index}. "
                chunks.append(prefix + " ".join(block_plain(part) for part in item))
        else:
            chunks.append(html.escape(block_plain(block), quote=False))
    return "<br/>".join(chunks)


def table_rows(table: Block) -> tuple[list[list[Any]], list[list[Any]], list[str]]:
    _, _, colspecs, head, bodies, foot = table["c"]
    header_rows = head[1]
    body_rows: list[list[Any]] = []
    for body in bodies:
        body_rows.extend(body[3])
    body_rows.extend(foot[1])
    aligns = [spec[0]["t"] for spec in colspecs]
    return header_rows, body_rows, aligns


def choose_column_widths(rows: list[list[str]], total_width: float) -> list[float]:
    count = len(rows[0])
    headers = [text.lower() for text in rows[0]]
    if count == 2:
        if any(word in headers[1] for word in ("result", "definition", "meaning")):
            fractions = [0.34, 0.66]
        else:
            fractions = [0.42, 0.58]
    elif count == 3:
        fractions = [0.32, 0.24, 0.44]
    elif count == 4:
        fractions = [0.30, 0.23, 0.23, 0.24]
    elif count == 5:
        if all(len(cell) < 32 for row in rows for cell in row):
            fractions = [0.20] * 5
        else:
            fractions = [0.16, 0.21, 0.21, 0.21, 0.21]
    elif count == 6:
        fractions = [0.25, 0.15, 0.15, 0.15, 0.15, 0.15]
    else:
        # Content-weighted fallback with a floor for every column.
        maxima = [
            max(len(row[index]) for row in rows)
            for index in range(count)
        ]
        weights = [max(8.0, min(math.sqrt(length + 1) * 3, 25.0)) for length in maxima]
        total = sum(weights)
        fractions = [weight / total for weight in weights]
    return [fraction * total_width for fraction in fractions]


class WhitePaperDocTemplate(BaseDocTemplate):
    def __init__(self, filename: str, **kwargs: Any) -> None:
        super().__init__(filename, **kwargs)
        frame = Frame(
            LEFT_MARGIN,
            BOTTOM_MARGIN,
            CONTENT_WIDTH,
            PAGE_HEIGHT - TOP_MARGIN - BOTTOM_MARGIN,
            leftPadding=0,
            rightPadding=0,
            topPadding=0,
            bottomPadding=0,
            id="content",
        )
        self.addPageTemplates(
            [PageTemplate(id="whitepaper", frames=[frame], onPage=self._on_page)]
        )

    def _on_page(self, canvas: Any, doc: Any) -> None:
        canvas.saveState()
        if doc.page > 1:
            canvas.setFont("PaperSerif", 8)
            canvas.setFillColor(INK)
            canvas.drawCentredString(PAGE_WIDTH / 2, 10 * mm, str(doc.page))
        canvas.restoreState()

    def afterFlowable(self, flowable: Flowable) -> None:
        if not isinstance(flowable, Paragraph):
            return
        level = getattr(flowable, "_toc_level", None)
        if level is None:
            return
        text = flowable.getPlainText()
        key = getattr(flowable, "_bookmark_name")
        self.canv.bookmarkPage(key)
        self.canv.addOutlineEntry(text, key, level=level, closed=False)
        self.notify("TOCEntry", (level, text, self.page, key))


class Renderer:
    def __init__(
        self,
        source: Path,
        output: Path,
        temp_dir: Path,
        styles: dict[str, ParagraphStyle],
    ) -> None:
        self.source = source.resolve()
        self.output = output.resolve()
        self.temp_dir = temp_dir.resolve()
        self.styles = styles
        self.heading_index = 0

    def parse(self) -> dict[str, Any]:
        pandoc = shutil.which("pandoc")
        if not pandoc:
            raise RuntimeError("pandoc is required to parse WHITEPAPER.md")
        result = subprocess.run(
            [
                pandoc,
                "-f",
                (
                    "markdown+yaml_metadata_block+tex_math_dollars"
                    "+tex_math_single_backslash"
                ),
                "-t",
                "json",
                str(self.source),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def title_page(self) -> list[Flowable]:
        return [
            Spacer(1, 42 * mm),
            Paragraph(
                "TECHNICAL WHITE PAPER",
                self.styles["title_kicker"],
            ),
            Spacer(1, 7 * mm),
            Paragraph("Bounded Perpetuals", self.styles["title"]),
            Paragraph(
                "Physical-First Solvency and Tranched Risk Capital "
                "for Oracle-Settled Markets",
                self.styles["subtitle"],
            ),
            Spacer(1, 10 * mm),
            Paragraph(
                f"<b>{PAPER_AUTHOR}</b><br/>{PAPER_ORGANIZATION}<br/>"
                "28 July 2026",
                self.styles["title_meta"],
            ),
            Paragraph(
                "How bounding an oracle-settled perpetual's payoff converts "
                "open-ended market risk into reservable credit risk - and "
                "enables physical-first solvency, tranched liquidity, and "
                "fail-soft settlement.",
                self.styles["thesis"],
            ),
            Spacer(1, 20 * mm),
            Paragraph(
                "Version 1.0<br/>"
                "Code revision 06d0ab451ad9bb42f4e9869fc94b0eeb1e88efe5",
                self.styles["title_meta"],
            ),
            PageBreak(),
        ]

    def make_heading(
        self, source_level: int, inlines: list[Inline], preliminary: bool = False
    ) -> Paragraph:
        text = inlines_to_markup(inlines)
        plain = inlines_to_plain(inlines)
        if preliminary:
            style = self.styles["h1"] if plain == "Abstract" else self.styles["h2"]
            toc_level = None
        elif source_level == 2:
            style = self.styles["h1"]
            toc_level = 0
        elif plain.startswith("Proposition "):
            style = self.styles["proposition"]
            toc_level = 1
        else:
            style = self.styles["h2"] if source_level == 3 else self.styles["h3"]
            toc_level = 1 if source_level == 3 else 2
        paragraph = Paragraph(text, style)
        if toc_level is not None:
            paragraph._toc_level = toc_level  # type: ignore[attr-defined]
            paragraph._bookmark_name = (  # type: ignore[attr-defined]
                f"section-{self.heading_index}"
            )
            self.heading_index += 1
        return paragraph

    def paragraph(
        self,
        inlines: list[Inline],
        abstract: bool = False,
        preliminary: bool = False,
    ) -> Flowable:
        if (
            len(inlines) == 1
            and inlines[0]["t"] == "Math"
            and inlines[0]["c"][0]["t"] == "DisplayMath"
        ):
            formula = latex_to_markup(inlines[0]["c"][1])
            return Paragraph(formula, self.styles["equation"])
        if abstract:
            style = self.styles["abstract"]
        elif preliminary:
            style = self.styles["body_left"]
        else:
            style = self.styles["body"]
        return Paragraph(inlines_to_markup(inlines), style)

    @staticmethod
    def is_display_math_block(block: Block) -> bool:
        return (
            block["t"] in {"Para", "Plain"}
            and len(block["c"]) == 1
            and block["c"][0]["t"] == "Math"
            and block["c"][0]["c"][0]["t"] == "DisplayMath"
        )

    def render_list(
        self, block: Block, abstract: bool = False
    ) -> list[Flowable]:
        ordered = block["t"] == "OrderedList"
        items = block["c"][1] if ordered else block["c"]
        output: list[Flowable] = []
        for index, item in enumerate(items, 1):
            prefix = f"{index}." if ordered else "•"
            first = True
            for nested in item:
                if nested["t"] in {"Plain", "Para"}:
                    marker = prefix if first else ""
                    output.append(
                        Paragraph(
                            inlines_to_markup(nested["c"]),
                            self.styles["bullet"],
                            bulletText=marker,
                        )
                    )
                    first = False
                else:
                    output.extend(self.render_block(nested, abstract=abstract))
        return output

    def render_quote(self, block: Block) -> list[Flowable]:
        text = "<br/>".join(
            inlines_to_markup(nested["c"])
            for nested in block["c"]
            if nested["t"] in {"Plain", "Para"}
        )
        return [Paragraph(text, self.styles["quote"])]

    def render_table(self, block: Block) -> list[Flowable]:
        header_rows, body_rows, aligns = table_rows(block)
        all_rows = header_rows + body_rows
        if not all_rows:
            return []
        markup_rows = [
            [cell_markup(cell) for cell in row_cells(row)]
            for row in all_rows
        ]
        plain_rows = [
            [re.sub(r"<[^>]+>", "", html.unescape(cell)) for cell in row]
            for row in markup_rows
        ]
        small = len(markup_rows[0]) >= 5
        cell_style = (
            self.styles["table_cell_small"]
            if small
            else self.styles["table_cell"]
        )
        data: list[list[Paragraph]] = []
        for row_index, row in enumerate(markup_rows):
            style = self.styles["table_header"] if row_index < len(header_rows) else cell_style
            data.append([Paragraph(cell, style) for cell in row])
        widths = choose_column_widths(plain_rows, CONTENT_WIDTH)
        table = Table(
            data,
            colWidths=widths,
            repeatRows=max(len(header_rows), 1),
            hAlign="LEFT",
            splitByRow=1,
            spaceBefore=5,
            spaceAfter=10,
        )
        commands: list[tuple[Any, ...]] = [
            ("TEXTCOLOR", (0, 0), (-1, -1), INK),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LINEABOVE", (0, 0), (-1, 0), 0.7, INK),
            (
                "LINEBELOW",
                (0, len(header_rows) - 1),
                (-1, len(header_rows) - 1),
                0.5,
                INK,
            ),
            ("LINEBELOW", (0, -1), (-1, -1), 0.7, INK),
            ("LEFTPADDING", (0, 0), (-1, -1), 5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 5),
            ("TOPPADDING", (0, 0), (-1, -1), 4.5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4.5),
        ]
        for col_index, align in enumerate(aligns):
            if align == "AlignRight":
                commands.append(
                    ("ALIGN", (col_index, 1), (col_index, -1), "RIGHT")
                )
        table.setStyle(TableStyle(commands))
        return [table]

    def rasterize_svg(self, source: Path) -> Path:
        target = self.temp_dir / f"{source.stem}.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        converter = shutil.which("rsvg-convert")
        if not converter:
            raise RuntimeError("rsvg-convert is required to render SVG figures")
        subprocess.run(
            [
                converter,
                "-w",
                "1800",
                "-b",
                "white",
                str(source),
                "-o",
                str(target),
            ],
            check=True,
        )
        return target

    def render_figure(self, block: Block) -> list[Flowable]:
        _, caption, body = block["c"]
        image_inline: Inline | None = None
        for nested in body:
            if nested["t"] not in {"Plain", "Para"}:
                continue
            for inline in nested["c"]:
                if inline["t"] == "Image":
                    image_inline = inline
                    break
        if image_inline is None:
            return []
        _, alt, target = image_inline["c"]
        source = (self.source.parent / target[0]).resolve()
        if source.suffix.lower() == ".svg":
            image_path = self.rasterize_svg(source)
        else:
            image_path = source
        with PILImage.open(image_path) as raster:
            width_px, height_px = raster.size
        max_width = CONTENT_WIDTH
        max_height = 142 * mm
        scale = min(max_width / width_px, max_height / height_px)
        figure = Image(
            str(image_path),
            width=width_px * scale,
            height=height_px * scale,
        )
        figure.hAlign = "CENTER"
        caption_inlines: list[Inline] = []
        if caption[1]:
            for caption_block in caption[1]:
                if caption_block["t"] in {"Plain", "Para"}:
                    caption_inlines.extend(caption_block["c"])
        if not caption_inlines:
            caption_inlines = alt
        return [
            Spacer(1, 4),
            figure,
            Paragraph(inlines_to_markup(caption_inlines), self.styles["caption"]),
        ]

    def render_block(
        self,
        block: Block,
        *,
        abstract: bool = False,
        preliminary: bool = False,
    ) -> list[Flowable]:
        kind = block["t"]
        if kind == "Header":
            level, _, inlines = block["c"]
            return [self.make_heading(level, inlines, preliminary=preliminary)]
        if kind in {"Para", "Plain"}:
            return [
                self.paragraph(
                    block["c"],
                    abstract=abstract,
                    preliminary=preliminary,
                )
            ]
        if kind in {"BulletList", "OrderedList"}:
            return self.render_list(block, abstract=abstract)
        if kind == "BlockQuote":
            return self.render_quote(block)
        if kind == "Table":
            return self.render_table(block)
        if kind == "Figure":
            return self.render_figure(block)
        if kind == "CodeBlock":
            code = html.escape(block["c"][1], quote=False).replace("\n", "<br/>")
            return [Paragraph(code, self.styles["code"])]
        if kind == "HorizontalRule":
            return []
        if kind in {"Div", "Section"}:
            output: list[Flowable] = []
            for nested in block["c"][-1]:
                output.extend(
                    self.render_block(
                        nested,
                        abstract=abstract,
                        preliminary=preliminary,
                    )
                )
            return output
        raise ValueError(f"unsupported Pandoc block: {kind}")

    def build_story(self, document: dict[str, Any]) -> list[Flowable]:
        blocks: list[Block] = document["blocks"]
        # The first source H1/H2/version line duplicate the designed title page.
        start = next(
            index
            for index, block in enumerate(blocks)
            if block["t"] == "Header"
            and inlines_to_plain(block["c"][2]) == "Abstract"
        )
        main = next(
            index
            for index, block in enumerate(blocks)
            if block["t"] == "Header"
            and inlines_to_plain(block["c"][2]).startswith("1. ")
        )

        story: list[Flowable] = self.title_page()
        abstract_mode = False
        for block in blocks[start:main]:
            if block["t"] == "Header":
                heading = inlines_to_plain(block["c"][2])
                abstract_mode = heading == "Abstract"
            story.extend(
                self.render_block(
                    block,
                    abstract=abstract_mode and block["t"] != "Header",
                    preliminary=True,
                )
            )
        story.extend([PageBreak(), Paragraph("Contents", self.styles["toc_title"])])
        toc = TableOfContents()
        toc.levelStyles = [
            ParagraphStyle(
                "TOC1",
                fontName="PaperSerif-Bold",
                fontSize=9.3,
                leading=13,
                leftIndent=0,
                firstLineIndent=0,
                textColor=INK,
                spaceBefore=3,
            ),
            ParagraphStyle(
                "TOC2",
                fontName="PaperSerif",
                fontSize=8.3,
                leading=11.2,
                leftIndent=14,
                firstLineIndent=0,
                textColor=INK,
            ),
        ]
        story.extend([toc, PageBreak()])

        main_blocks = blocks[main:]
        index = 0
        while index < len(main_blocks):
            block = main_blocks[index]
            if (
                block["t"] == "Header"
                and index + 2 < len(main_blocks)
                and main_blocks[index + 1]["t"] in {"Para", "Plain"}
                and self.is_display_math_block(main_blocks[index + 2])
            ):
                grouped = self.render_block(block)
                grouped.extend(self.render_block(main_blocks[index + 1]))
                grouped.extend(self.render_block(main_blocks[index + 2]))
                story.append(KeepTogether(grouped))
                index += 3
                continue
            if (
                block["t"] in {"Para", "Plain"}
                and index + 1 < len(main_blocks)
                and self.is_display_math_block(main_blocks[index + 1])
            ):
                grouped = self.render_block(block)
                grouped.extend(self.render_block(main_blocks[index + 1]))
                story.append(KeepTogether(grouped))
                index += 2
                continue
            story.extend(self.render_block(block))
            index += 1
        return story

    def render(self) -> None:
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        document = self.parse()
        story = self.build_story(document)
        pdf = WhitePaperDocTemplate(
            str(self.output),
            pagesize=A4,
            leftMargin=LEFT_MARGIN,
            rightMargin=RIGHT_MARGIN,
            topMargin=TOP_MARGIN,
            bottomMargin=BOTTOM_MARGIN,
            title="Bounded Perpetuals",
            author=PAPER_AUTHOR,
            subject=(
                "Physical-First Solvency and Tranched Risk Capital "
                "for Oracle-Settled Markets"
            ),
            creator=f"{PAPER_ORGANIZATION} reproducible publication pipeline",
            keywords=f"{PAPER_ORGANIZATION}; Plether Perps; bounded perpetuals",
            pageCompression=1,
        )
        pdf.multiBuild(story)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--temp-dir", type=Path, default=DEFAULT_TEMP)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    register_fonts()
    renderer = Renderer(
        source=args.source,
        output=args.output,
        temp_dir=args.temp_dir,
        styles=make_styles(),
    )
    renderer.render()
    print(args.output.resolve())


if __name__ == "__main__":
    main()
