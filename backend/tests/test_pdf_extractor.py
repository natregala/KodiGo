"""Tests for KodiGo PDF text extraction and HTTP endpoints."""

from __future__ import annotations

import io
import json
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest
from pypdf import PdfWriter
from pypdf.generic import (
    DecodedStreamObject,
    DictionaryObject,
    NameObject,
    NumberObject,
)

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from pdf_extractor import (  # noqa: E402
    MAX_PDF_BYTES,
    MAX_PDF_PAGES,
    MAX_TEXT_CHARS,
    PdfExtractionError,
    extract_paragraphs,
    extract_pdf,
)
import server  # noqa: E402


SPECIAL_GLYPHS = {
    "\ufb01": 0x80,  # fi ligature
    "\ufb02": 0x81,  # fl ligature
    "\u2082": 0x82,  # subscript 2
    "\u00b2": 0x83,  # superscript 2
    "\u00f1": 0x84,  # n with tilde
    "\u00d1": 0x85,  # N with tilde
}

TO_UNICODE_CMAP = """/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Adobe-Identity-UCS def
/CMapType 2 def
1 begincodespacerange
<00> <FF>
endcodespacerange
1 beginbfrange
<20> <7E> <0020>
endbfrange
6 beginbfchar
<80> <FB01>
<81> <FB02>
<82> <2082>
<83> <00B2>
<84> <00F1>
<85> <00D1>
endbfchar
endcmap
CMapName currentdict /CMap defineresource pop
end
end"""


def _encode_pdf_bytes(text: str) -> bytes:
    buf = bytearray()
    for ch in text:
        if ch in SPECIAL_GLYPHS:
            buf.append(SPECIAL_GLYPHS[ch])
        elif ch in ("(", ")", "\\"):
            buf.extend(b"\\" + ch.encode("latin-1"))
        else:
            code = ord(ch)
            if 0x20 <= code <= 0x7E:
                buf.append(code)
            else:
                buf.append(ord("?"))
    return bytes(buf)


def build_pdf(
    pages_lines: list[list[tuple[int, int, str]]],
    *,
    metadata_title: str | None = None,
    user_password: str | None = None,
    owner_password: str | None = None,
) -> bytes:
    """Create an in-memory PDF from positioned lines: [(x, y, text), ...]."""
    writer = PdfWriter()

    cmap_stream = DecodedStreamObject()
    cmap_stream.set_data(TO_UNICODE_CMAP.encode("ascii"))
    cmap_ref = writer._add_object(cmap_stream)

    font_dict = DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Font"),
            NameObject("/Subtype"): NameObject("/Type1"),
            NameObject("/BaseFont"): NameObject("/Helvetica"),
            NameObject("/Encoding"): NameObject("/WinAnsiEncoding"),
            NameObject("/ToUnicode"): cmap_ref,
        }
    )
    font_ref = writer._add_object(font_dict)
    resources = DictionaryObject(
        {
            NameObject("/Font"): DictionaryObject({NameObject("/F1"): font_ref}),
        }
    )

    for lines in pages_lines:
        page = writer.add_blank_page(width=612, height=792)
        page[NameObject("/Resources")] = resources
        commands = [b"BT", b"/F1 12 Tf"]
        for x, y, text in lines:
            encoded = _encode_pdf_bytes(text)
            commands.append(f"1 0 0 1 {x} {y} Tm".encode("ascii"))
            commands.append(b"(" + encoded + b") Tj")
        commands.append(b"ET")
        content = DecodedStreamObject()
        content.set_data(b"\n".join(commands))
        content_ref = writer._add_object(content)
        page[NameObject("/Contents")] = content_ref

    if metadata_title is not None:
        writer.add_metadata({"/Title": metadata_title})

    if user_password is not None or owner_password is not None:
        writer.encrypt(
            user_password=user_password or "",
            owner_password=owner_password,
        )

    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()


def test_single_and_multipage_paragraph_extraction():
    pdf_bytes = build_pdf(
        [
            [
                (72, 720, "The water cycle moves water across Earth."),
                (72, 706, "Water travels between land, sea, and sky."),
                (72, 650, "Evaporation happens when the sun warms lakes."),
            ],
            [
                (72, 720, "Condensation forms clouds high in the sky."),
            ],
        ],
        metadata_title="The Water Cycle.pdf",
    )

    extracted = extract_pdf(pdf_bytes, fallback_title="ignored_name")
    assert extracted.page_count == 2
    assert extracted.title == "The Water Cycle"
    assert len(extracted.paragraphs) == 3
    assert "moves water across Earth" in extracted.paragraphs[0]
    assert "Evaporation happens" in extracted.paragraphs[1]
    assert "Condensation forms clouds" in extracted.paragraphs[2]
    assert extracted.char_count == sum(len(p) for p in extracted.paragraphs)


def test_dehyphenation_ligatures_and_scientific_preservation():
    pdf_bytes = build_pdf(
        [
            [
                (72, 720, "During evapo-"),
                (72, 706, "ration, \ufb01ltered water \ufb02ows as H\u2082O across 5 m\u00b2"),
                (72, 692, "of land during El Ni\u00f1o."),
            ],
        ]
    )

    paragraphs = extract_paragraphs(pdf_bytes)
    assert len(paragraphs) == 1
    text = paragraphs[0]
    assert "evaporation" in text
    assert "filtered" in text
    assert "flows" in text
    assert "H\u2082O" in text
    assert "5 m\u00b2" in text
    assert "El Ni\u00f1o" in text


def test_strips_repeated_headers_footers_and_page_numbers():
    pages = []
    for page_num in range(1, 5):
        pages.append(
            [
                (72, 760, "Philippine Science Grade 5 - Module 2"),
                (72, 680, f"Paragraph {page_num} explains a key weather concept clearly."),
                (72, 48, f"Page {page_num} of 4"),
            ]
        )

    extracted = extract_pdf(build_pdf(pages))
    assert extracted.page_count == 4
    assert len(extracted.paragraphs) == 4
    for i, paragraph in enumerate(extracted.paragraphs, start=1):
        assert "Philippine Science Grade 5" not in paragraph
        assert f"Page {i} of 4" not in paragraph
        assert f"Paragraph {i} explains" in paragraph
    assert "stripped_repeated_headers_footers" in extracted.warnings


def test_merges_cross_page_broken_sentence():
    pdf_bytes = build_pdf(
        [
            [(72, 720, "Rainwater flows down mountains into wide")],
            [(72, 700, "rivers and back to the sea.")],
        ]
    )
    extracted = extract_pdf(pdf_bytes)
    assert extracted.paragraphs == [
        "Rainwater flows down mountains into wide rivers and back to the sea."
    ]


def test_rejects_empty_and_invalid_and_oversized_files():
    with pytest.raises(PdfExtractionError) as empty_err:
        extract_pdf(b"")
    assert empty_err.value.code == "empty_file"
    assert empty_err.value.http_status == 422

    with pytest.raises(PdfExtractionError) as big_err:
        extract_pdf(b"%PDF-1.4\n" + b"0" * MAX_PDF_BYTES)
    assert big_err.value.code == "file_too_large"
    assert big_err.value.http_status == 413

    with pytest.raises(PdfExtractionError) as not_pdf:
        extract_pdf(b"Hello world, this is plain text.")
    assert not_pdf.value.code == "invalid_pdf"

    with pytest.raises(PdfExtractionError) as corrupt_pdf:
        extract_pdf(b"%PDF-1.7\nnot actually valid pdf structure")
    assert corrupt_pdf.value.code == "invalid_pdf"


def test_encrypted_pdf_handling():
    locked_pdf = build_pdf(
        [[(72, 720, "Secret lesson text.")]],
        user_password="student-password",
    )
    with pytest.raises(PdfExtractionError) as locked_err:
        extract_pdf(locked_pdf)
    assert locked_err.value.code == "encrypted_pdf"

    owner_only_pdf = build_pdf(
        [[(72, 720, "Owner restricted printing only.")]],
        user_password="",
        owner_password="teacher-owner-password",
    )
    extracted = extract_pdf(owner_only_pdf)
    assert extracted.paragraphs == ["Owner restricted printing only."]


def test_page_limit_no_selectable_text_and_text_too_long():
    over_pages = build_pdf([[(72, 720, f"Page {i}")] for i in range(MAX_PDF_PAGES + 1)])
    with pytest.raises(PdfExtractionError) as pages_err:
        extract_pdf(over_pages)
    assert pages_err.value.code == "too_many_pages"
    assert pages_err.value.details == {
        "pageCount": MAX_PDF_PAGES + 1,
        "maxPages": MAX_PDF_PAGES,
    }

    blank_pdf = build_pdf([[]])
    with pytest.raises(PdfExtractionError) as blank_err:
        extract_pdf(blank_pdf)
    assert blank_err.value.code == "no_selectable_text"

    # Build a multi-page PDF exceeding MAX_TEXT_CHARS (35,000 chars)
    long_line = "Water evaporates and condenses into clouds. " * 22  # ~968 chars
    long_pages = [
        [(72, 740 - row * 16, long_line) for row in range(2)]
        for _ in range(20)
    ]
    long_pdf = build_pdf(long_pages)
    with pytest.raises(PdfExtractionError) as long_err:
        extract_pdf(long_pdf)
    assert long_err.value.code == "text_too_long"
    assert long_err.value.details is not None
    assert long_err.value.details["charCount"] > MAX_TEXT_CHARS


def test_generic_metadata_title_falls_back_to_filename():
    pdf_bytes = build_pdf(
        [[(72, 720, "Lesson content on ecosystems.")]],
        metadata_title="Untitled",
    )
    extracted = extract_pdf(pdf_bytes, fallback_title="science_ecosystems_week_3.pdf")
    payload = extracted.to_dict(fallback_title="science_ecosystems_week_3")
    assert payload["title"] == "science ecosystems week 3"


@pytest.fixture()
def live_server():
    httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        httpd.shutdown()
        httpd.server_close()


def _http_call(
    url: str,
    *,
    method: str = "GET",
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
):
    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read()


def test_http_health_cors_and_extract_without_openai_key(live_server, monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("KODIGO_MODEL", raising=False)

    status, headers, body = _http_call(f"{live_server}/health")
    assert status == 200
    assert json.loads(body) == {"status": "ok"}
    assert headers.get("Access-Control-Allow-Origin") == "*"

    opt_status, opt_headers, _ = _http_call(
        f"{live_server}/extract",
        method="OPTIONS",
    )
    assert opt_status == 204
    assert "POST" in opt_headers.get("Access-Control-Allow-Methods", "")

    pdf_bytes = build_pdf(
        [[(72, 720, "Photosynthesis converts sunlight into chemical energy.")]]
    )
    ext_status, _, ext_body = _http_call(
        f"{live_server}/extract",
        method="POST",
        body=pdf_bytes,
        headers={
            "Content-Type": "application/pdf",
            "X-Lesson-Title": "Biology%20Lesson%201",
        },
    )
    assert ext_status == 200
    data = json.loads(ext_body)
    assert data["title"] == "Biology Lesson 1"
    assert data["pageCount"] == 1
    assert data["paragraphCount"] == 1
    assert data["paragraphs"] == [
        "Photosynthesis converts sunlight into chemical energy."
    ]

    bad_status, _, bad_body = _http_call(
        f"{live_server}/extract",
        method="POST",
        body=b"not a pdf",
        headers={"Content-Type": "application/pdf"},
    )
    assert bad_status == 422
    assert json.loads(bad_body)["error"] == "invalid_pdf"


def test_http_generate_backwards_compat_and_json_mode(live_server, monkeypatch):
    pdf_bytes = build_pdf([[(72, 720, "Force equals mass times acceleration.")]])

    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("KODIGO_MODEL", raising=False)
    unconf_status, _, unconf_body = _http_call(
        f"{live_server}/generate",
        method="POST",
        body=pdf_bytes,
        headers={"Content-Type": "application/pdf"},
    )
    assert unconf_status == 503
    assert json.loads(unconf_body)["error"] == "generator_unconfigured"

    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    monkeypatch.setenv("KODIGO_MODEL", "gpt-4.1-mini")
    calls: list[tuple[str, list[str]]] = []

    def fake_generate_pack(title, paragraphs, key, model):
        calls.append((title, paragraphs))
        return {
            "version": 1,
            "id": "pack-1",
            "title": title,
            "paragraphs": paragraphs,
            "summaries": [],
            "questions": [],
            "cards": [],
        }

    monkeypatch.setattr(server, "generate_pack", fake_generate_pack)

    pdf_status, _, pdf_body = _http_call(
        f"{live_server}/generate",
        method="POST",
        body=pdf_bytes,
        headers={
            "Content-Type": "application/pdf",
            "X-Lesson-Title": "Physics%20101",
        },
    )
    assert pdf_status == 200
    assert json.loads(pdf_body)["title"] == "Physics 101"

    json_status, _, json_body = _http_call(
        f"{live_server}/generate",
        method="POST",
        body=json.dumps(
            {
                "title": "Edited Title",
                "paragraphs": ["Paragraph one.", "Paragraph two."],
            }
        ).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    assert json_status == 200
    assert json.loads(json_body)["title"] == "Edited Title"
    assert calls == [
        ("Physics 101", ["Force equals mass times acceleration."]),
        ("Edited Title", ["Paragraph one.", "Paragraph two."]),
    ]
