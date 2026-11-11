from __future__ import annotations

import asyncio
import io
import os
from types import SimpleNamespace

import pytest

from fastapi import HTTPException, UploadFile

from delegator_core import main
from delegator_core.main import LocalCallersOnly, _find_upload_file
from delegator_core.providers.web_doors import is_foreign_request


def call_guard(path, headers, method="GET"):
    called = []
    sent = []

    async def endpoint(scope, receive, send):
        called.append(scope["path"])
        await send({"type": "http.response.start", "status": 204, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    asyncio.run(LocalCallersOnly(endpoint)(
        {"type": "http", "path": path, "method": method,
         "headers": [(key.encode(), value.encode()) for key, value in headers.items()]},
        receive, send,
    ))
    return sent[0]["status"], called


@pytest.mark.parametrize("path", ["/", "/health", "/assets/app.js", "/api/sessions", "/api/restart", "/api/uploads"])
def test_foreign_pages_cannot_reach_any_core_route(path):
    status, called = call_guard(path, {"host": "rebound.example:1380"})
    assert status == 403
    assert not called


@pytest.mark.parametrize("origin", ["https://evil.example", "http://localhost:9999", "https://localhost:1380", "null"])
def test_foreign_origins_are_blocked_without_fetch_metadata(origin):
    assert is_foreign_request("localhost:1380", origin, "")


@pytest.mark.parametrize("host,origin", [
    ("localhost:1380", "http://localhost:1380"),
    ("127.0.0.1:1380", "http://127.0.0.1:1380"),
    ("[::1]:1380", "http://[::1]:1380"),
    ("127.0.0.1:1380", "chrome-extension://abc"),
    ("127.0.0.1:1380", ""),
])
def test_local_gui_extension_and_native_clients_remain_allowed(host, origin):
    status, called = call_guard("/api/sessions", {"host": host, "origin": origin})
    assert status == 204
    assert called == ["/api/sessions"]


@pytest.mark.parametrize("upload_id", ["*", "?", "[a-z]*", "../secret", "a" * 31, "g" * 32])
def test_upload_lookup_rejects_patterns_and_invalid_ids(tmp_path, upload_id):
    (tmp_path / ("a" * 32 + "_private.txt")).write_text("private")
    assert _find_upload_file(SimpleNamespace(upload_dir=tmp_path), upload_id) is None


def test_upload_lookup_does_not_follow_symlinks(tmp_path):
    uploads = tmp_path / "uploads"
    uploads.mkdir()
    secret = tmp_path / "private.txt"
    secret.write_text("private")
    upload_id = "a" * 32
    try:
        (uploads / f"{upload_id}_public.txt").symlink_to(secret)
    except OSError:
        if os.name == "nt":
            pytest.skip("Creating symlinks requires Windows Developer Mode or an elevated token")
        raise
    assert _find_upload_file(SimpleNamespace(upload_dir=uploads), upload_id) is None


def test_oversized_upload_is_rejected_before_parsing_the_body():
    status, called = call_guard("/api/uploads", {
        "host": "127.0.0.1:1380", "content-length": str(main.MAX_UPLOAD_BYTES + 100_000),
    }, method="POST")
    assert status == 413
    assert not called


@pytest.mark.parametrize("data,accepted", [(b"12345", True), (b"123456", False)])
def test_upload_limit_and_partial_file_cleanup(tmp_path, monkeypatch, data, accepted):
    monkeypatch.setattr(main, "MAX_UPLOAD_BYTES", 5)
    app = main.create_app()
    app.state.core = SimpleNamespace(upload_dir=tmp_path)
    endpoint = next(route.endpoint for route in app.routes if route.path == "/api/uploads")
    file = UploadFile(file=io.BytesIO(data), filename="notes.txt")
    if accepted:
        record = asyncio.run(endpoint(file))
        assert record.size == 5
        assert _find_upload_file(app.state.core, record.id).read_bytes() == data
    else:
        with pytest.raises(HTTPException) as exc:
            asyncio.run(endpoint(file))
        assert exc.value.status_code == 413
        assert not list(tmp_path.iterdir())
    assert file.file.closed


def test_failed_exclusive_upload_does_not_delete_an_existing_file(tmp_path, monkeypatch):
    app = main.create_app()
    app.state.core = SimpleNamespace(upload_dir=tmp_path)
    endpoint = next(route.endpoint for route in app.routes if route.path == "/api/uploads")
    upload_id = "a" * 32
    target = tmp_path / f"{upload_id}_notes.txt"
    target.write_text("existing")
    monkeypatch.setattr(main.uuid, "uuid4", lambda: SimpleNamespace(hex=upload_id))
    file = UploadFile(file=io.BytesIO(b"new"), filename="notes.txt")
    with pytest.raises(FileExistsError):
        asyncio.run(endpoint(file))
    assert target.read_text() == "existing"
    assert file.file.closed


@pytest.mark.parametrize("size,status", [(5, 200), (200, 413)])
def test_chunked_multipart_is_bounded_and_spool_files_are_closed(tmp_path, monkeypatch, size, status):
    import starlette.formparsers as parsers

    monkeypatch.setattr(main, "MAX_UPLOAD_BYTES", 5)
    monkeypatch.setattr(main, "UPLOAD_MULTIPART_OVERHEAD", 128)
    spools = []
    original_spool = parsers.SpooledTemporaryFile

    def spool(*args, **kwargs):
        file = original_spool(*args, **kwargs)
        spools.append(file)
        return file

    monkeypatch.setattr(parsers, "SpooledTemporaryFile", spool)
    app = main.create_app()
    app.state.core = SimpleNamespace(upload_dir=tmp_path)
    prefix = b'--b\r\nContent-Disposition: form-data; name="file"; filename="notes.txt"\r\nContent-Type: text/plain\r\n\r\n'
    chunks = [prefix + b"x" * min(size, 20), b"x" * max(0, size - 20), b"\r\n--b--\r\n"]
    sent = []

    async def receive():
        body = chunks.pop(0)
        return {"type": "http.request", "body": body, "more_body": bool(chunks)}

    async def send(message):
        sent.append(message)

    asyncio.run(app({
        "type": "http", "method": "POST", "path": "/api/uploads", "raw_path": b"/api/uploads",
        "scheme": "http", "root_path": "", "query_string": b"", "http_version": "1.1",
        "headers": [(b"host", b"127.0.0.1:1380"), (b"content-type", b"multipart/form-data; boundary=b")],
        "server": ("127.0.0.1", 1380), "client": ("127.0.0.1", 12345),
    }, receive, send))
    assert sent[0]["status"] == status
    assert spools and all(file.closed for file in spools)
    assert len(list(tmp_path.iterdir())) == (1 if status == 200 else 0)
