#!/usr/bin/env python3
"""Localhost control panel for isolated Ollama model servers."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
import asyncio
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import unquote

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "ollama-isolated.sh"
CONF = ROOT / "models.conf"
META = ROOT / "models.json"
STATIC = Path(__file__).resolve().parent / "static"
ISOLATED_LOG_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "ollama-isolated" / "logs"

app = FastAPI(title="Ollama Control Panel")


def _isolated_log_path(name: str) -> Path:
    safe = name.replace(":", "_").replace("/", "_").replace(" ", "_")
    return ISOLATED_LOG_DIR / f"{safe}.log"


def _parse_iso_ts(line: str) -> float | None:
    if not line.startswith("time="):
        return None
    raw = line.split(" ", 1)[0].removeprefix("time=")
    try:
        return datetime.fromisoformat(raw).timestamp()
    except ValueError:
        return None


def _read_log_since(path: Path, pos: int) -> str:
    """Read log bytes from pos; binary seek avoids text-mode offset bugs."""
    try:
        with path.open("rb") as fh:
            fh.seek(pos)
            return fh.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def _parse_request_phases(log_text: str) -> dict[str, float | None]:
    """Extract llama-server / sched timings from one request's log slice."""
    cache_ms = None
    prompt_ms = None
    eval_ms = None
    sched_ms = None
    eval_ts = None
    completion_ts = None
    saw_slot = False
    for line in log_text.splitlines():
        if "prompt cache update took" in line:
            m = re.search(r"prompt cache update took\s+([\d.]+)\s*ms", line)
            if m:
                cache_ms = float(m.group(1))
        if "cached n_tokens" in line or "slot print_timing" in line or "slot launch_slot_" in line:
            saw_slot = True
        if "prompt eval time =" in line:
            m = re.search(r"prompt eval time =\s+([\d.]+)\s*ms", line)
            if m:
                prompt_ms = float(m.group(1))
        if "eval time =" in line and "prompt eval" not in line:
            m = re.search(r"eval time =\s+([\d.]+)\s*ms", line)
            if m:
                eval_ms = float(m.group(1))
        if "evaluating already loaded" in line:
            eval_ts = _parse_iso_ts(line)
        if "llama-server completion request" in line:
            completion_ts = _parse_iso_ts(line)
    if eval_ts is not None and completion_ts is not None:
        sched_ms = max(0.0, (completion_ts - eval_ts) * 1000.0)
    # Cache update is skipped on pure KV hits; still report 0 so the step is visible.
    if cache_ms is None and saw_slot:
        cache_ms = 0.0
    return {
        "cache_ms": cache_ms,
        "log_prompt_ms": prompt_ms,
        "log_eval_ms": eval_ms,
        "sched_ms": sched_ms,
        "saw_slot": saw_slot,
    }


def _load_ports() -> dict[str, int]:
    ports: dict[str, int] = {}
    for line in CONF.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, port = line.split("=", 1)
        ports[name.strip()] = int(port.strip())
    return ports


def _load_meta() -> dict:
    if not META.exists():
        return {"gpu_note": "", "models": {}}
    return json.loads(META.read_text())


def _run_script(*args: str, timeout: float = 120.0) -> subprocess.CompletedProcess[str]:
    if not SCRIPT.exists():
        raise HTTPException(status_code=500, detail=f"Missing script: {SCRIPT}")
    return subprocess.run(
        [str(SCRIPT), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=str(ROOT),
    )


def _parse_list() -> dict[str, dict]:
    """Parse `ollama-isolated.sh list` into {model: {status, pid}}."""
    result = _run_script("list", timeout=30.0)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=result.stderr.strip() or result.stdout.strip() or "list failed",
        )
    status: dict[str, dict] = {}
    for line in result.stdout.splitlines():
        if not line.strip() or line.startswith("MODEL") or line.startswith("-----"):
            continue
        # MODEL PORT STATUS PID — model names can contain spaces? No, but can have :
        parts = line.split()
        if len(parts) < 3:
            continue
        # Last two fields are STATUS and PID; first is model; port is second-to-last before status
        # Format: %-30s %-8s %-10s %s  → model may be padded; split() collapses spaces
        model = parts[0]
        port = parts[1]
        st = parts[2]
        pid = parts[3] if len(parts) > 3 else "-"
        # If model name somehow had spaces this would break; ours don't.
        status[model] = {"port": int(port), "status": st, "pid": None if pid == "-" else int(pid)}
    return status


def _normalize_name(name: str) -> str:
    return unquote(name)


def _require_model(name: str) -> str:
    name = _normalize_name(name)
    ports = _load_ports()
    if name not in ports:
        raise HTTPException(status_code=404, detail=f"Unknown model: {name}")
    return name


def _ps_entry(port: int, name: str) -> dict[str, Any] | None:
    try:
        with httpx.Client(timeout=2.0) as client:
            resp = client.get(f"http://127.0.0.1:{port}/api/ps")
            if resp.status_code != 200:
                return None
            for item in resp.json().get("models", []):
                if item.get("name") == name or item.get("model") == name:
                    return item
    except httpx.HTTPError:
        return None
    return None


def _device_label(size: int | None, size_vram: int | None) -> str:
    if not size:
        return "unknown"
    vram = size_vram or 0
    frac = vram / size
    if frac >= 0.85:
        return "gpu"
    if frac <= 0.15:
        return "ram"
    return "mixed"


@app.get("/api/models")
def list_models():
    ports = _load_ports()
    meta = _load_meta()
    live = _parse_list()
    models = []
    for name, port in ports.items():
        info = meta.get("models", {}).get(name, {})
        live_info = live.get(name, {})
        status = live_info.get("status", "stopped")
        size_bytes = None
        size_vram = None
        device = None
        if status == "running":
            ps = _ps_entry(port, name)
            if ps:
                size_bytes = ps.get("size")
                size_vram = ps.get("size_vram")
                device = _device_label(size_bytes, size_vram)
        models.append(
            {
                "name": name,
                "port": port,
                "size": info.get("size", ""),
                "category": info.get("category", "general"),
                "best_for": info.get("best_for", ""),
                "gpu_fit": info.get("gpu_fit", ""),
                "status": status,
                "pid": live_info.get("pid"),
                "size_bytes": size_bytes,
                "size_vram": size_vram,
                "device": device,
            }
        )
    return {"gpu_note": meta.get("gpu_note", ""), "models": models}


@app.post("/api/models/{name:path}/start")
async def start_model(name: str):
    """Start the isolated server, then load the model weights into memory."""
    import time

    name = _require_model(name)
    result = _run_script("start", name, timeout=60.0)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=(result.stderr or result.stdout or "start failed").strip(),
        )

    port = _load_ports()[name]
    load_error: str | None = None
    t0 = time.perf_counter()
    device = "unknown"
    size_bytes = None
    size_vram = None
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=10.0)) as client:
            # Single generate to pull weights into VRAM and keep resident.
            resp = await client.post(
                f"http://127.0.0.1:{port}/api/generate",
                json={
                    "model": name,
                    "prompt": ".",
                    "stream": False,
                    "keep_alive": -1,
                    "options": {"num_predict": 1},
                },
            )
            if resp.status_code >= 400:
                load_error = (resp.text or f"HTTP {resp.status_code}").strip()
            else:
                try:
                    ps_resp = await client.get(f"http://127.0.0.1:{port}/api/ps", timeout=5.0)
                    if ps_resp.status_code == 200:
                        for item in ps_resp.json().get("models", []):
                            if item.get("name") == name or item.get("model") == name:
                                size_bytes = item.get("size")
                                size_vram = item.get("size_vram")
                                device = _device_label(size_bytes, size_vram)
                                break
                except httpx.HTTPError:
                    pass
    except httpx.HTTPError as exc:
        load_error = str(exc)

    load_duration_ns = int((time.perf_counter() - t0) * 1e9)

    if load_error:
        raise HTTPException(
            status_code=500,
            detail=f"Server started on port {port}, but model load failed: {load_error}",
        )

    return {
        "ok": True,
        "model": name,
        "loaded": True,
        "device": device,
        "size_bytes": size_bytes,
        "size_vram": size_vram,
        "load_duration": load_duration_ns,
        "total_duration": load_duration_ns,
        "output": result.stdout.strip(),
    }


@app.post("/api/models/{name:path}/stop")
def stop_model(name: str):
    name = _require_model(name)
    result = _run_script("stop", name, timeout=30.0)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=(result.stderr or result.stdout or "stop failed").strip(),
        )
    return {"ok": True, "model": name, "output": result.stdout.strip()}


def _ensure_model_in_conf(name: str) -> int:
    """Return port for model, appending a new models.conf entry if needed."""
    ports = _load_ports()
    if name in ports:
        return ports[name]
    used = set(ports.values())
    port = 11435
    while port in used or port == 11434:
        port += 1
    text = CONF.read_text(encoding="utf-8") if CONF.exists() else ""
    prefix = "" if not text or text.endswith("\n") else "\n"
    with CONF.open("a", encoding="utf-8") as fh:
        fh.write(f"{prefix}{name}={port}\n")
    return port


# Library scrape cache: {key: (expires_at, payload)}
_available_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_AVAILABLE_CACHE_TTL = 3600.0
_PARAM_CHIP_RE = re.compile(r"^(\d+(?:\.\d+)?)([mb])$", re.IGNORECASE)
_LIBRARY_ITEM_RE = re.compile(r"<li\s+x-test-model[\s\S]*?</li>", re.IGNORECASE)
_LIBRARY_TITLE_RE = re.compile(r'title="([^"]+)"')
_LIBRARY_SIZE_RE = re.compile(r"x-test-size[^>]*>\s*([^<]+)", re.IGNORECASE)
_LIBRARY_CAP_RE = re.compile(r"x-test-capability[^>]*>\s*([^<]+)", re.IGNORECASE)
_LIBRARY_DESC_RE = re.compile(
    r'<p class="max-w-lg[^"]*"[^>]*>(.*?)</p>',
    re.IGNORECASE | re.DOTALL,
)
_HTML_TAG_RE = re.compile(r"<[^>]+>")


def _strip_html(text: str) -> str:
    text = _HTML_TAG_RE.sub("", text or "")
    text = text.replace("&#39;", "'").replace("&amp;", "&").replace("&quot;", '"')
    text = text.replace("&lt;", "<").replace("&gt;", ">")
    return re.sub(r"\s+", " ", text).strip()


def _classify_library_model(family: str, caps: set[str], desc: str) -> str:
    """Short category label for download dropdown options."""
    family_l = family.lower()
    blob = f"{family_l} {desc.lower()}"

    def has(*words: str) -> bool:
        return any(re.search(rf"(?<![a-z0-9]){re.escape(w)}(?![a-z0-9])", blob) for w in words)

    # Prefer code over reasoning when both appear (e.g. "code reasoning").
    if (
        "coder" in family_l
        or family_l.startswith("code")
        or has("code", "coder", "coding", "sqlcoder", "starcoder", "devstral", "codellama")
    ):
        return "code"
    if "thinking" in caps or has("reasoning", "reasoner") or "r1" in family_l:
        return "reasoning"
    if has("math", "stem", "gsm8k"):
        return "math"
    if "vision" in caps or has("vision", "image", "multimodal", "visual"):
        return "vision"
    return "general"


def _gpu_vram_mib() -> float:
    """Total GPU VRAM in MiB via nvidia-smi; fall back to RTX 5080 16GB."""
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=memory.total",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=5.0,
            check=False,
        )
        if result.returncode == 0:
            total = 0.0
            for line in result.stdout.splitlines():
                line = line.strip()
                if line:
                    total += float(line)
            if total > 0:
                return total
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return 16303.0


def _parse_param_chip(chip: str) -> float | None:
    """Parse library size chips like '1.5b' / '270m' into billions of params."""
    chip = chip.strip().lower()
    if not chip or "x" in chip:
        return None
    m = _PARAM_CHIP_RE.match(chip)
    if not m:
        return None
    value = float(m.group(1))
    unit = m.group(2)
    if unit == "m":
        return value / 1000.0
    return value


def _local_model_names() -> set[str]:
    """Names present on the main Ollama service (already downloaded)."""
    names: set[str] = set()
    try:
        with httpx.Client(timeout=5.0) as client:
            resp = client.get("http://127.0.0.1:11434/api/tags")
            if resp.status_code != 200:
                return names
            for item in resp.json().get("models", []):
                for key in ("name", "model"):
                    n = item.get(key)
                    if isinstance(n, str) and n:
                        names.add(n)
                        if ":" not in n:
                            names.add(f"{n}:latest")
    except (httpx.HTTPError, json.JSONDecodeError, TypeError):
        pass
    return names


def _scrape_library_candidates(max_param_b: float) -> list[dict[str, Any]]:
    """Fetch ollama.com/library and return fitting {name,param_b,family} entries."""
    with httpx.Client(
        timeout=httpx.Timeout(20.0, connect=10.0),
        headers={"User-Agent": "gpt-ollama-panel/1.0"},
        follow_redirects=True,
    ) as client:
        resp = client.get("https://ollama.com/library")
        if resp.status_code != 200:
            raise HTTPException(
                status_code=503,
                detail=f"ollama.com/library returned HTTP {resp.status_code}",
            )
        html = resp.text

    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for block in _LIBRARY_ITEM_RE.findall(html):
        title_m = _LIBRARY_TITLE_RE.search(block)
        if not title_m:
            continue
        family = title_m.group(1).strip()
        if not family or "/" in family:
            continue
        caps = {c.strip().lower() for c in _LIBRARY_CAP_RE.findall(block)}
        # Embedding-only models cannot chat; everything else on the library can.
        if "embedding" in caps or "embed" in family.lower():
            continue
        desc_m = _LIBRARY_DESC_RE.search(block)
        desc = _strip_html(desc_m.group(1)) if desc_m else ""
        category = _classify_library_model(family, caps, desc)
        for raw_chip in _LIBRARY_SIZE_RE.findall(block):
            chip = raw_chip.strip()
            param_b = _parse_param_chip(chip)
            if param_b is None or param_b > max_param_b:
                continue
            name = f"{family}:{chip}"
            if name in seen:
                continue
            seen.add(name)
            out.append(
                {
                    "name": name,
                    "param_b": param_b,
                    "family": family,
                    "category": category,
                }
            )
    out.sort(key=lambda m: (m["param_b"], m["name"]))
    return out


@app.get("/api/models/available")
def list_available_models():
    """Library models that fit fully on GPU and are not already downloaded."""
    vram_mib = _gpu_vram_mib()
    # Round to whole GB for the fit formula so 16303 MiB → 16GB → 14B threshold
    # (matches models.json: ~14B Q4 fully on a 16GB card).
    vram_gb = round(vram_mib / 1024.0)
    max_param_b = round(vram_gb * (14.0 / 16.0), 2)
    cache_key = f"chat-cat2:{max_param_b:.2f}"
    now = time.time()

    cached = _available_cache.get(cache_key)
    if cached and cached[0] > now:
        catalog = cached[1]["catalog"]
    else:
        try:
            catalog = _scrape_library_candidates(max_param_b)
        except HTTPException:
            raise
        except httpx.HTTPError as exc:
            raise HTTPException(
                status_code=503,
                detail=f"failed to fetch ollama.com/library: {exc}",
            ) from exc
        _available_cache.clear()
        _available_cache[cache_key] = (
            now + _AVAILABLE_CACHE_TTL,
            {"catalog": catalog},
        )

    local = _local_model_names()
    models = [m for m in catalog if m["name"] not in local]
    return {
        "vram_gb": vram_gb,
        "max_param_b": max_param_b,
        "models": models,
    }


class PullRequest(BaseModel):
    name: str = Field(min_length=1)


def _friendly_pull_error(name: str, raw: str) -> str:
    """Map opaque Ollama pull errors to actionable messages."""
    low = (raw or "").lower()
    if "file does not exist" in low or "not found" in low:
        return (
            f"model '{name}' not found on the ollama registry "
            f"(no such tag). try a real tag, e.g. llama3.1:8b or llama3.2:1b"
        )
    return raw


@app.post("/api/models/pull")
async def pull_model(body: PullRequest):
    """Download a model via the main Ollama service, then register it in models.conf."""
    name = body.name.strip()
    if not name or any(c in name for c in " \t\n\r;|&`$"):
        raise HTTPException(status_code=400, detail="Invalid model name")

    async def stream():
        status = "starting"
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(None, connect=10.0)) as client:
                async with client.stream(
                    "POST",
                    "http://127.0.0.1:11434/api/pull",
                    json={"name": name, "stream": True},
                ) as resp:
                    if resp.status_code >= 400:
                        detail = (await resp.aread()).decode("utf-8", errors="replace")
                        yield json.dumps(
                            {"error": _friendly_pull_error(name, detail or f"Ollama HTTP {resp.status_code}")}
                        ) + "\n"
                        return
                    async for line in resp.aiter_lines():
                        if not line:
                            continue
                        try:
                            chunk = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if chunk.get("error"):
                            yield json.dumps(
                                {"error": _friendly_pull_error(name, str(chunk["error"]))}
                            ) + "\n"
                            return
                        status = chunk.get("status") or status
                        out: dict[str, Any] = {"status": status}
                        if "completed" in chunk and "total" in chunk:
                            out["completed"] = chunk["completed"]
                            out["total"] = chunk["total"]
                        if chunk.get("digest"):
                            out["digest"] = chunk["digest"]
                        yield json.dumps(out) + "\n"
            port = _ensure_model_in_conf(name)
            yield json.dumps({"done": True, "model": name, "port": port}) + "\n"
        except httpx.HTTPError as exc:
            yield json.dumps({"error": str(exc)}) + "\n"

    return StreamingResponse(stream(), media_type="application/x-ndjson")


@app.post("/api/stop-all")
def stop_all():
    result = _run_script("stop-all", timeout=60.0)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=(result.stderr or result.stdout or "stop-all failed").strip(),
        )
    return {"ok": True, "output": result.stdout.strip()}


class ChatRequest(BaseModel):
    message: str = Field(default="")
    history: list[dict[str, Any]] = Field(default_factory=list)
    think: bool = False
    images: list[str] = Field(default_factory=list)


@app.post("/api/models/{name:path}/chat")
async def chat_model(name: str, body: ChatRequest):
    """Proxy a chat turn to the model's isolated Ollama server (NDJSON stream)."""
    name = _require_model(name)
    ports = _load_ports()
    port = ports[name]
    live = _parse_list()
    if live.get(name, {}).get("status") != "running":
        raise HTTPException(status_code=400, detail=f"{name} is not running — start it first")

    message = (body.message or "").strip()
    images = [img for img in body.images if isinstance(img, str) and img.strip()]
    if not message and not images:
        raise HTTPException(status_code=400, detail="message or images required")

    messages: list[dict[str, Any]] = []
    for item in body.history:
        role = item.get("role")
        content = item.get("content")
        if role in ("user", "assistant", "system") and isinstance(content, str) and content:
            msg: dict[str, Any] = {"role": role, "content": content}
            hist_images = item.get("images")
            if isinstance(hist_images, list) and hist_images:
                msg["images"] = [i for i in hist_images if isinstance(i, str) and i]
            messages.append(msg)
    user_msg: dict[str, Any] = {
        "role": "user",
        "content": message or ("describe the attached image(s)." if images else ""),
    }
    if images:
        user_msg["images"] = images
    messages.append(user_msg)

    url = f"http://127.0.0.1:{port}/api/chat"
    payload = {
        "model": name,
        "messages": messages,
        "stream": True,
        "keep_alive": -1,
        "think": body.think,
    }
    log_path = _isolated_log_path(name)

    async def stream():
        t0 = time.perf_counter()
        log_pos = 0
        try:
            if log_path.exists():
                log_pos = log_path.stat().st_size
        except OSError:
            log_pos = 0
        first_byte_ms = None
        headers_ms = None
        last_meta: dict[str, Any] = {}
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=10.0)) as client:
                async with client.stream("POST", url, json=payload) as resp:
                    headers_ms = (time.perf_counter() - t0) * 1000.0
                    if resp.status_code >= 400:
                        detail = (await resp.aread()).decode("utf-8", errors="replace")
                        yield json.dumps({"error": detail or f"Ollama HTTP {resp.status_code}"}) + "\n"
                        return
                    async for line in resp.aiter_lines():
                        if not line:
                            continue
                        if first_byte_ms is None:
                            first_byte_ms = (time.perf_counter() - t0) * 1000.0
                        try:
                            chunk = json.loads(line)
                            if chunk.get("done") or "load_duration" in chunk:
                                last_meta = chunk
                        except json.JSONDecodeError:
                            pass
                        yield line + "\n"
            wall_ms = (time.perf_counter() - t0) * 1000.0
            if headers_ms is None:
                headers_ms = wall_ms
            # llama-server may flush slot timings slightly after the HTTP response.
            phases: dict[str, Any] = {}
            for _ in range(4):
                if log_path.exists():
                    phases = _parse_request_phases(_read_log_since(log_path, log_pos))
                if phases.get("saw_slot") or phases.get("cache_ms") is not None:
                    break
                await asyncio.sleep(0.05)
            load_ms = (last_meta.get("load_duration") or 0) / 1e6
            prompt_ms = (last_meta.get("prompt_eval_duration") or 0) / 1e6
            gen_ms = (last_meta.get("eval_duration") or 0) / 1e6
            total_ms = (last_meta.get("total_duration") or 0) / 1e6
            sched_ms = phases.get("sched_ms")
            cache_ms = phases.get("cache_ms")
            # Warm load_duration is almost entirely GGUF metadata (GetModel/Capabilities)
            # before scheduler attach; sched is typically 1–2 ms when DEBUG timestamps exist.
            if load_ms >= 1000:
                meta_ms = load_ms
                overhead_kind = "cold"
            else:
                overhead_kind = "warm"
                if sched_ms is None:
                    # Without DEBUG logs, warm attach is still a real step (~1 ms).
                    sched_ms = 1.0
                meta_ms = max(0.0, load_ms - sched_ms)
            if overhead_kind == "warm" and cache_ms is None:
                cache_ms = 0.0
            breakdown = {
                "overhead_kind": overhead_kind,
                "load_ms": round(load_ms, 1),
                "meta_ms": round(meta_ms, 1),
                "sched_ms": None if sched_ms is None else round(float(sched_ms), 1),
                "cache_ms": None if cache_ms is None else round(float(cache_ms), 1),
                "prompt_ms": round(prompt_ms, 1),
                "gen_ms": round(gen_ms, 1),
                "total_ms": round(total_ms, 1),
                "proxy_headers_ms": round(headers_ms, 1),
                "proxy_first_byte_ms": None if first_byte_ms is None else round(first_byte_ms, 1),
                "proxy_wall_ms": round(wall_ms, 1),
            }
            yield json.dumps({"overhead_breakdown": breakdown}) + "\n"
        except httpx.HTTPError as exc:
            yield json.dumps({"error": str(exc)}) + "\n"

    return StreamingResponse(stream(), media_type="application/x-ndjson")


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")


app.mount("/static", StaticFiles(directory=str(STATIC)), name="static")
