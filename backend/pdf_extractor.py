"""PDF validation, text extraction, and paragraph normalization for KodiGo."""

from __future__ import annotations

import io
import math
import re
from collections import Counter
from dataclasses import dataclass, field

from pypdf import PdfReader

MAX_PDF_BYTES = 12 * 1024 * 1024
MAX_PDF_PAGES = 40
MAX_TEXT_CHARS = 35_000
PDF_MAGIC = b"%PDF-"

_LIGATURES = str.maketrans(
    {
        "\ufb00": "ff",
        "\ufb01": "fi",
        "\ufb02": "fl",
        "\ufb03": "ffi",
        "\ufb04": "ffl",
        "\ufb05": "ft",
        "\ufb06": "st",
        "\u00a0": " ",
    }
)
_STRIP_CHARS_RE = re.compile(r"[\x00\u200b\u200c\u200d\ufeff\u00ad]")
_PAGE_NUMBER_RE = re.compile(
    r"^(?:(?:page\s*)?\d{1,3}(?:\s*(?:of|/)\s*\d{1,3})?|-\s*\d{1,3}\s*-)$",
    re.IGNORECASE,
)
_DEHYPHENATE_RE = re.compile(r"([A-Za-zÀ-ÿ])-\s*\n\s*([a-zà-ÿ])")
_ENDS_BLOCK_CHARS = (".", "!", "?", ":", ";", '"', "”", "’", ")")
_GENERIC_TITLES = {
    "untitled",
    "document",
    "document1",
    "presentation",
    "presentation1",
    "slide 1",
    "powerpoint presentation",
}


class PdfExtractionError(ValueError):
    """Structured validation or extraction error for uploaded PDFs."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        details: dict[str, int] | None = None,
        http_status: int = 422,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.http_status = http_status

    def to_payload(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "error": self.code,
            "message": self.message,
        }
        if self.details:
            payload.update(self.details)
        return payload


@dataclass
class ExtractedPdf:
    """Normalized text and metadata extracted from a lesson PDF."""

    title: str | None
    page_count: int
    paragraphs: list[str]
    char_count: int
    warnings: list[str] = field(default_factory=list)

    def to_dict(self, fallback_title: str = "Lesson") -> dict[str, object]:
        resolved_title = self.title or clean_title(fallback_title) or "Lesson"
        return {
            "title": resolved_title,
            "pageCount": self.page_count,
            "paragraphCount": len(self.paragraphs),
            "charCount": self.char_count,
            "paragraphs": self.paragraphs,
            "warnings": self.warnings,
        }


def clean_title(raw: str | None, *, replace_separators: bool = True) -> str | None:
    """Normalize a lesson title from PDF metadata or a filename."""
    if not raw:
        return None
    text = raw.strip()
    text = re.sub(r"\.pdf$", "", text, flags=re.IGNORECASE).strip()
    if replace_separators:
        text = re.sub(r"[_-]+", " ", text)
    text = " ".join(text.split())
    if not text or text.lower() in _GENERIC_TITLES:
        return None
    return text[:150]


def _clean_raw_text(text: str) -> str:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    normalized = _STRIP_CHARS_RE.sub("", normalized)
    return normalized.translate(_LIGATURES)


def _header_footer_key(block: str) -> str:
    collapsed = " ".join(block.split()).lower()
    return re.sub(r"\d+", "#", collapsed)


def _normalize_block(block: str) -> str:
    dehyphenated = _DEHYPHENATE_RE.sub(r"\1\2", block)
    return " ".join(dehyphenated.split())


def _add_warning(warnings: list[str], code: str) -> None:
    if code not in warnings:
        warnings.append(code)


def _extract_page_raw_text(page, warnings: list[str]) -> str:
    text = ""
    try:
        text = (page.extract_text(extraction_mode="layout") or "").strip()
    except Exception:
        text = ""
    if not text:
        try:
            fallback = (page.extract_text() or "").strip()
            if fallback:
                _add_warning(warnings, "used_plain_fallback")
                text = fallback
        except Exception:
            text = ""
    return _clean_raw_text(text)


def extract_pdf(contents: bytes, fallback_title: str | None = None) -> ExtractedPdf:
    """Validate and extract clean, numbered paragraphs from a PDF byte payload."""
    if not contents:
        raise PdfExtractionError("empty_file", "The uploaded PDF file is empty.")
    if len(contents) > MAX_PDF_BYTES:
        raise PdfExtractionError(
            "file_too_large",
            "PDF exceeds the 12 MB size limit.",
            http_status=413,
        )
    if PDF_MAGIC not in contents[:1024]:
        raise PdfExtractionError(
            "invalid_pdf",
            "File is not a valid PDF document.",
        )

    try:
        reader = PdfReader(io.BytesIO(contents))
    except Exception as exc:
        raise PdfExtractionError(
            "invalid_pdf",
            "Could not open the PDF file.",
        ) from exc

    if reader.is_encrypted:
        try:
            decrypted = reader.decrypt("")
        except Exception as exc:
            raise PdfExtractionError(
                "encrypted_pdf",
                "Password-protected PDFs cannot be read.",
            ) from exc
        if not decrypted:
            raise PdfExtractionError(
                "encrypted_pdf",
                "Password-protected PDFs cannot be read.",
            )

    page_count = len(reader.pages)
    if page_count == 0:
        raise PdfExtractionError(
            "no_selectable_text",
            "The PDF has no pages with selectable text.",
        )
    if page_count > MAX_PDF_PAGES:
        raise PdfExtractionError(
            "too_many_pages",
            f"PDF has {page_count} pages; the limit is {MAX_PDF_PAGES}.",
            details={"pageCount": page_count, "maxPages": MAX_PDF_PAGES},
        )

    warnings: list[str] = []
    page_blocks: list[list[str]] = []
    for page in reader.pages:
        raw = _extract_page_raw_text(page, warnings)
        blocks = [
            part.strip()
            for part in re.split(r"\n[ \t]*\n+", raw)
            if part.strip()
        ]
        page_blocks.append(blocks)

    if page_count >= 3:
        threshold = max(3, math.ceil(page_count * 0.6))
        top_counts: Counter[str] = Counter()
        bottom_counts: Counter[str] = Counter()
        for blocks in page_blocks:
            if not blocks:
                continue
            first_norm = " ".join(blocks[0].split())
            if len(first_norm) <= 120:
                top_counts[_header_footer_key(first_norm)] += 1
            if len(blocks) > 1:
                last_norm = " ".join(blocks[-1].split())
                if len(last_norm) <= 120:
                    bottom_counts[_header_footer_key(last_norm)] += 1

        repeated_tops = {k for k, v in top_counts.items() if v >= threshold}
        repeated_bottoms = {k for k, v in bottom_counts.items() if v >= threshold}
        if repeated_tops or repeated_bottoms:
            stripped_any = False
            for blocks in page_blocks:
                if not blocks:
                    continue
                if len(blocks) > 1:
                    last_norm = " ".join(blocks[-1].split())
                    if (
                        len(last_norm) <= 120
                        and _header_footer_key(last_norm) in repeated_bottoms
                    ):
                        blocks.pop()
                        stripped_any = True
                if blocks:
                    first_norm = " ".join(blocks[0].split())
                    if (
                        len(first_norm) <= 120
                        and _header_footer_key(first_norm) in repeated_tops
                    ):
                        blocks.pop(0)
                        stripped_any = True
            if stripped_any:
                _add_warning(warnings, "stripped_repeated_headers_footers")

    paragraphs: list[str] = []
    for blocks in page_blocks:
        page_paragraphs: list[str] = []
        for block in blocks:
            normalized = _normalize_block(block)
            if not normalized or _PAGE_NUMBER_RE.match(normalized):
                continue
            page_paragraphs.append(normalized)
        if not page_paragraphs:
            continue
        if (
            paragraphs
            and not paragraphs[-1].endswith(_ENDS_BLOCK_CHARS)
            and re.match(r"^[a-zà-ÿ]", page_paragraphs[0])
        ):
            paragraphs[-1] = f"{paragraphs[-1]} {page_paragraphs[0]}"
            paragraphs.extend(page_paragraphs[1:])
        else:
            paragraphs.extend(page_paragraphs)

    if not paragraphs:
        raise PdfExtractionError(
            "no_selectable_text",
            "No selectable text was found in this PDF.",
        )

    char_count = sum(len(paragraph) for paragraph in paragraphs)
    if char_count > MAX_TEXT_CHARS:
        raise PdfExtractionError(
            "text_too_long",
            f"Extracted text is {char_count} characters; the limit is {MAX_TEXT_CHARS}.",
            details={"charCount": char_count, "maxChars": MAX_TEXT_CHARS},
        )

    meta_title: str | None = None
    try:
        raw_meta = reader.metadata.title if reader.metadata else None
        meta_title = clean_title(
            str(raw_meta) if raw_meta is not None else None,
            replace_separators=False,
        )
    except Exception:
        meta_title = None

    resolved_title = meta_title or clean_title(fallback_title)

    return ExtractedPdf(
        title=resolved_title,
        page_count=page_count,
        paragraphs=paragraphs,
        char_count=char_count,
        warnings=warnings,
    )


def extract_paragraphs(contents: bytes) -> list[str]:
    """Return normalized paragraphs from PDF bytes (legacy helper)."""
    return extract_pdf(contents).paragraphs
