let state = {
  models: [],
  selected: "",
  busy: new Set(),
  loading: new Set(),
  loadTimes: {},
  input: "",
  output: "",
  timing: null,
  timingHistory: [],
  streaming: false,
  think: false,
  loadStartedAt: null,
};

const TIMING_KEYS = [
  { key: "meta_ms", cls: "c-meta", label: "meta" },
  { key: "sched_ms", cls: "c-sched", label: "sched" },
  { key: "cache_ms", cls: "c-cache", label: "cache" },
  { key: "prompt_ms", cls: "c-prompt", label: "prompt" },
  { key: "gen_ms", cls: "c-gen", label: "gen" },
];

const el = {
  toast: document.getElementById("toast"),
  stopAll: document.getElementById("btn-stop-all"),
  download: document.getElementById("model-download"),
  available: document.getElementById("model-available"),
  btnDownload: document.getElementById("btn-download"),
  downloadProgressWrap: document.getElementById("download-progress-wrap"),
  downloadProgress: document.getElementById("download-progress"),
  downloadLabel: document.getElementById("download-label"),
  select: document.getElementById("model-select"),
  toggle: document.getElementById("btn-toggle"),
  pill: document.getElementById("model-pill"),
  loadTime: document.getElementById("load-time"),
  loadProgressWrap: document.getElementById("load-progress-wrap"),
  loadProgress: document.getElementById("load-progress"),
  loadLabel: document.getElementById("load-label"),
  counts: document.getElementById("counts"),
  meta: document.getElementById("model-meta"),
  best: document.getElementById("model-best"),
  form: document.getElementById("chat-form"),
  input: document.getElementById("chat-input"),
  files: document.getElementById("chat-files"),
  filesLabel: document.getElementById("chat-files-label"),
  output: document.getElementById("chat-output"),
  send: document.getElementById("chat-send"),
  timing: document.getElementById("chat-timing"),
  timingHist: document.getElementById("timing-hist"),
  think: document.getElementById("chat-think"),
};

function showToast(message, isError = false) {
  el.toast.hidden = false;
  el.toast.textContent = message;
  el.toast.classList.toggle("error", isError);
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => {
    el.toast.hidden = true;
  }, 4200);
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { Accept: "application/json" },
    ...options,
  });
  let data = null;
  try {
    data = await res.json();
  } catch {
    data = null;
  }
  if (!res.ok) {
    const detail = data?.detail || res.statusText || "Request failed";
    throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
  }
  return data;
}

function encodeModel(name) {
  return encodeURIComponent(name);
}

function formatDuration(ns) {
  if (ns == null || Number.isNaN(ns)) return null;
  const ms = ns / 1e6;
  if (ms < 1000) return `${ms.toFixed(0)} ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(s < 10 ? 2 : 1)} s`;
  const m = Math.floor(s / 60);
  const rem = s - m * 60;
  return `${m}m ${rem.toFixed(0)}s`;
}

function msToNs(ms) {
  return ms == null ? null : ms * 1e6;
}

function formatTiming(timing) {
  if (!timing) return "";
  const lines = [];
  const bd = timing.breakdown;
  const ms = (v) => formatDuration(msToNs(v));

  if (bd && bd.overhead_kind === "warm") {
    if (bd.meta_ms != null) lines.push(`meta (gguf)  ${ms(bd.meta_ms)}`);
    if (bd.sched_ms != null) lines.push(`sched        ${ms(bd.sched_ms)}`);
    if (bd.cache_ms != null) lines.push(`cache        ${ms(bd.cache_ms)}`);
  } else if (timing.load != null) {
    const label = timing.load >= 1e9 ? "cold load" : "overhead";
    lines.push(`${label.padEnd(12)} ${formatDuration(timing.load)}`);
  }

  if (timing.prompt != null) lines.push(`prompt       ${formatDuration(timing.prompt)}`);
  else if (bd?.prompt_ms != null) lines.push(`prompt       ${ms(bd.prompt_ms)}`);

  if (timing.gen != null) lines.push(`gen          ${formatDuration(timing.gen)}`);
  else if (bd?.gen_ms != null) lines.push(`gen          ${ms(bd.gen_ms)}`);
  else if (timing.query != null) lines.push(`query        ${formatDuration(timing.query)}`);

  if (timing.total != null) lines.push(`total        ${formatDuration(timing.total)}`);
  else if (bd?.total_ms != null) lines.push(`total        ${ms(bd.total_ms)}`);

  if (timing.device && timing.device !== "gpu") {
    lines.push(timing.device === "ram" ? "device       ram (slow)" : "device       mixed gpu/ram");
  }
  return lines.join("\n");
}

function timingPartsFrom(timing) {
  const bd = timing?.breakdown || {};
  const meta =
    bd.meta_ms != null
      ? bd.meta_ms
      : timing?.load != null
        ? timing.load / 1e6
        : 0;
  const sched = bd.sched_ms != null ? bd.sched_ms : 0;
  const cache = bd.cache_ms != null ? bd.cache_ms : 0;
  const prompt =
    bd.prompt_ms != null
      ? bd.prompt_ms
      : timing?.prompt != null
        ? timing.prompt / 1e6
        : 0;
  const gen =
    bd.gen_ms != null ? bd.gen_ms : timing?.gen != null ? timing.gen / 1e6 : 0;
  return {
    meta_ms: Math.max(0, meta),
    sched_ms: Math.max(0, sched),
    cache_ms: Math.max(0, cache),
    prompt_ms: Math.max(0, prompt),
    gen_ms: Math.max(0, gen),
  };
}

function pushTimingHistory(timing) {
  if (!timing) return;
  const parts = timingPartsFrom(timing);
  const total =
    parts.meta_ms + parts.sched_ms + parts.cache_ms + parts.prompt_ms + parts.gen_ms;
  if (total <= 0) return;
  state.timingHistory = [parts];
}

function renderTimingHist() {
  if (!el.timingHist) return;
  el.timingHist.replaceChildren();
  const rows = state.timingHistory;
  if (!rows.length) {
    el.timingHist.textContent = "(no responses yet)";
    return;
  }
  const maxTotal = Math.max(
    ...rows.map(
      (r) => r.meta_ms + r.sched_ms + r.cache_ms + r.prompt_ms + r.gen_ms
    ),
    1
  );
  for (const row of rows) {
    const bar = document.createElement("div");
    bar.className = "hist-row";
    const total =
      row.meta_ms + row.sched_ms + row.cache_ms + row.prompt_ms + row.gen_ms;
    bar.title = TIMING_KEYS.map((k) => `${k.label} ${row[k.key].toFixed(0)}ms`).join(" · ")
      + ` · total ${total.toFixed(0)}ms`;
    bar.style.width = `${Math.max(4, (100 * total) / maxTotal)}%`;
    for (const k of TIMING_KEYS) {
      const ms = row[k.key] || 0;
      if (ms <= 0) continue;
      const seg = document.createElement("span");
      seg.className = k.cls;
      seg.style.flex = String(ms);
      seg.title = `${k.label} ${ms.toFixed(0)} ms`;
      bar.appendChild(seg);
    }
    el.timingHist.appendChild(bar);
  }
}

function updateLoadProgress() {
  const loading = state.selected && state.loading.has(state.selected);
  if (!el.loadProgressWrap) return;
  if (!loading) {
    el.loadProgressWrap.hidden = true;
    el.loadProgress.removeAttribute("value");
    el.loadLabel.textContent = "";
    return;
  }
  el.loadProgressWrap.hidden = false;
  el.loadProgress.removeAttribute("value");
  const elapsed = state.loadStartedAt
    ? (performance.now() - state.loadStartedAt) / 1000
    : 0;
  el.loadLabel.textContent = `loading… ${elapsed.toFixed(1)}s`;
}

function deviceLabel(m) {
  if (!m || m.status !== "running") return "";
  if (m.device === "gpu") return "gpu";
  if (m.device === "ram") return "ram (slow)";
  if (m.device === "mixed") return "mixed gpu/ram";
  return "";
}

function isChatModel(m) {
  return m.category !== "embeddings";
}

function chatModels() {
  return state.models.filter(isChatModel);
}

function selectedModel() {
  return state.models.find((m) => m.name === state.selected) || null;
}

function snapshotInput() {
  state.input = el.input.value;
}

function renderSelect() {
  const list = chatModels();
  if (!state.selected || !list.some((m) => m.name === state.selected)) {
    const running = list.find((m) => m.status === "running");
    state.selected = (running || list[0] || {}).name || "";
  }

  const prev = el.select.value;
  el.select.innerHTML = "";
  for (const m of list) {
    const opt = document.createElement("option");
    opt.value = m.name;
    const mark =
      state.loading.has(m.name) ? "… " : m.status === "running" ? "● " : "○ ";
    const cat = (m.category || "general").toLowerCase() === "coding"
      ? "code"
      : (m.category || "general").toLowerCase();
    opt.textContent = `${mark}${m.name} (${cat})`;
    el.select.appendChild(opt);
  }
  if (state.selected) el.select.value = state.selected;
  else if (prev && list.some((m) => m.name === prev)) el.select.value = prev;
}

function renderSelected() {
  const m = selectedModel();
  const running = !!m && m.status === "running";
  const loading = !!m && state.loading.has(m.name);
  const busy = !!m && state.busy.has(m.name);
  const ready = running && !loading && !busy;

  let actionLabel = "start";
  if (!m) {
    actionLabel = "start";
  } else if (loading) {
    actionLabel = "loading…";
  } else if (busy && running) {
    actionLabel = "stopping…";
  } else if (running) {
    actionLabel = "stop";
  }

  el.toggle.textContent = actionLabel;
  el.toggle.disabled = !m || busy || loading;
  el.toggle.dataset.action = running && !loading ? "stop" : "start";

  el.pill.textContent = loading ? "loading" : running ? "running" : "stopped";

  if (m && state.loadTimes[m.name] != null) {
    el.loadTime.hidden = false;
    el.loadTime.textContent = `load ${formatDuration(state.loadTimes[m.name])}`;
  } else if (loading) {
    el.loadTime.hidden = false;
    el.loadTime.textContent = "loading…";
  } else {
    el.loadTime.hidden = true;
    el.loadTime.textContent = "";
  }
  updateLoadProgress();

  if (m) {
    const dev = deviceLabel(m);
    el.meta.textContent = [
      `port ${m.port}`,
      m.size || "—",
      m.category || "",
      m.gpu_fit || "",
      dev,
    ]
      .filter(Boolean)
      .join(" · ")
      .toLowerCase();
    el.best.textContent = (m.best_for || "").toLowerCase();
  } else {
    el.meta.textContent = "";
    el.best.textContent = "";
  }

  const runningCount = state.models.filter((x) => x.status === "running").length;
  el.counts.textContent = `${runningCount} running · ${state.models.length} total`;

  const chatDisabled = !ready || state.streaming;
  el.input.disabled = chatDisabled;
  if (el.files) el.files.disabled = chatDisabled;
  el.input.placeholder = loading
    ? "loading model into memory…"
    : ready
      ? "type a prompt…"
      : "start the model to chat";
  el.input.value = state.input;
  const hasFiles = !!(el.files && el.files.files && el.files.files.length);
  el.send.disabled = chatDisabled || (!state.input.trim() && !hasFiles);
  el.send.textContent = state.streaming ? "…" : "send";
  updateFilesLabel();

  el.output.value = state.output;
  if (state.timing) {
    el.timing.hidden = false;
    el.timing.textContent = formatTiming(state.timing);
  } else {
    el.timing.hidden = true;
    el.timing.textContent = "";
  }
  renderTimingHist();
}

function render() {
  const focused = document.activeElement === el.input;
  const pos = focused ? el.input.selectionStart : null;
  renderSelect();
  renderSelected();
  if (focused && !el.input.disabled) {
    el.input.focus();
    if (pos != null) el.input.setSelectionRange(pos, pos);
  }
}

async function refresh() {
  if (state.streaming || state.loading.size) {
    try {
      const data = await api("/api/models");
      state.models = data.models || [];
      renderSelect();
      renderSelected();
    } catch {
      /* ignore during stream/load */
    }
    return;
  }

  try {
    snapshotInput();
    const data = await api("/api/models");
    state.models = data.models || [];
    if (!state.selected || !state.models.some((m) => m.name === state.selected)) {
      const first = chatModels()[0];
      state.selected = first ? first.name : "";
    }
    render();
  } catch (err) {
    showToast(err.message, true);
  }
}

async function toggleSelected() {
  const name = state.selected;
  if (!name) return;
  const action = el.toggle.dataset.action || "start";
  state.busy.add(name);
  if (action === "start") {
    state.loading.add(name);
    delete state.loadTimes[name];
    state.loadStartedAt = performance.now();
  }
  snapshotInput();
  render();
  const wallStart = performance.now();
  const loadTick = setInterval(() => {
    if (state.loading.has(name)) updateLoadProgress();
  }, 200);
  try {
    const data = await api(`/api/models/${encodeModel(name)}/${action}`, { method: "POST" });
    if (action === "start") {
      const loadNs =
        data?.load_duration ??
        data?.total_duration ??
        (performance.now() - wallStart) * 1e6;
      state.loadTimes[name] = loadNs;
      if (el.loadProgress) {
        el.loadProgressWrap.hidden = false;
        el.loadProgress.max = 100;
        el.loadProgress.value = 100;
        el.loadLabel.textContent = `loaded in ${formatDuration(loadNs)}`;
      }
      const where = data?.device === "gpu" ? "on gpu" : data?.device === "ram" ? "on ram (slow)" : "";
      showToast(`loaded ${name} in ${formatDuration(loadNs)}${where ? " · " + where : ""}`);
      if (data?.device === "ram") {
        showToast(`${name} is mostly in system ram — inference will be slow`, true);
      }
    } else {
      delete state.loadTimes[name];
      showToast(`stopped ${name}`);
    }
  } catch (err) {
    showToast(err.message, true);
  } finally {
    clearInterval(loadTick);
    state.busy.delete(name);
    state.loading.delete(name);
    state.loadStartedAt = null;
    await refresh();
  }
}

const MAX_ATTACH_BYTES = 20 * 1024 * 1024;
const MAX_ZIP_TEXT_CHARS = 400_000;
const TEXT_EXTS = new Set([
  "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "html", "htm",
  "css", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "c", "h",
  "cpp", "hpp", "cs", "sh", "bash", "zsh", "toml", "yaml", "yml", "ini", "cfg",
  "conf", "env", "log", "sql", "r", "swift", "kt", "scala", "php", "lua",
]);
const IMAGE_EXTS = new Set(["png", "jpg", "jpeg", "gif", "webp", "bmp"]);

function updateFilesLabel() {
  if (!el.filesLabel) return;
  const files = el.files?.files ? [...el.files.files] : [];
  el.filesLabel.textContent = files.length
    ? files.map((f) => `${f.name} (${formatBytes(f.size)})`).join(", ")
    : "";
}

function fileExt(name) {
  const base = name.split("/").pop() || name;
  const i = base.lastIndexOf(".");
  return i >= 0 ? base.slice(i + 1).toLowerCase() : "";
}

function isImageName(name, mime = "") {
  if (mime && mime.startsWith("image/")) return true;
  return IMAGE_EXTS.has(fileExt(name));
}

function isTextName(name, mime = "") {
  if (
    mime &&
    (mime.startsWith("text/") ||
      mime === "application/json" ||
      mime === "application/xml" ||
      mime === "application/javascript")
  ) {
    return true;
  }
  return TEXT_EXTS.has(fileExt(name));
}

function isImageFile(file) {
  return isImageName(file.name, file.type);
}

function isTextFile(file) {
  return isTextName(file.name, file.type);
}

function isZipFile(file) {
  if (file.type === "application/zip" || file.type === "application/x-zip-compressed") {
    return true;
  }
  return fileExt(file.name) === "zip";
}

function readFileAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(new Error(`failed to read ${file.name}`));
    reader.readAsDataURL(file);
  });
}

function readFileAsText(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(new Error(`failed to read ${file.name}`));
    reader.readAsText(file);
  });
}

function readFileAsArrayBuffer(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error(`failed to read ${file.name}`));
    reader.readAsArrayBuffer(file);
  });
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function inflateRaw(bytes) {
  if (typeof DecompressionStream !== "function") {
    throw new Error("zip deflate requires a modern browser (DecompressionStream)");
  }
  const ds = new DecompressionStream("deflate-raw");
  const stream = new Blob([bytes]).stream().pipeThrough(ds);
  const buf = await new Response(stream).arrayBuffer();
  return new Uint8Array(buf);
}

function decodeUtf8(bytes) {
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
}

async function extractZipEntries(buffer, zipName) {
  const u8 = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  const view = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  const entries = [];
  let i = 0;
  while (i + 30 <= u8.length) {
    if (view.getUint32(i, true) !== 0x04034b50) break;
    const method = view.getUint16(i + 8, true);
    const compSize = view.getUint32(i + 18, true);
    const uncompSize = view.getUint32(i + 22, true);
    const nameLen = view.getUint16(i + 26, true);
    const extraLen = view.getUint16(i + 28, true);
    const nameStart = i + 30;
    const dataStart = nameStart + nameLen + extraLen;
    if (dataStart + compSize > u8.length) {
      throw new Error(`${zipName}: truncated zip entry`);
    }
    const name = decodeUtf8(u8.subarray(nameStart, nameStart + nameLen));
    const compressed = u8.subarray(dataStart, dataStart + compSize);
    i = dataStart + compSize;
    if (!name || name.endsWith("/")) continue;
    const base = name.split("/").pop() || name;
    if (base.startsWith(".") || name.includes("__MACOSX/")) continue;
    entries.push({ name, method, compressed, uncompSize });
  }
  if (!entries.length) throw new Error(`${zipName}: no files found in zip`);

  const out = [];
  for (const ent of entries) {
    let data;
    if (ent.method === 0) {
      data = ent.compressed;
    } else if (ent.method === 8) {
      data = await inflateRaw(ent.compressed);
    } else {
      continue; // unsupported compression
    }
    if (ent.uncompSize && data.length !== ent.uncompSize && ent.method === 0) {
      data = data.subarray(0, ent.uncompSize);
    }
    out.push({ name: ent.name, data });
  }
  return out;
}

async function prepareAttachments(fileList) {
  const files = fileList ? [...fileList] : [];
  const images = [];
  const textParts = [];
  let textChars = 0;

  const addText = (label, body) => {
    if (textChars >= MAX_ZIP_TEXT_CHARS) return false;
    let content = body;
    if (textChars + content.length > MAX_ZIP_TEXT_CHARS) {
      content = content.slice(0, MAX_ZIP_TEXT_CHARS - textChars) + "\n…[truncated]";
    }
    textParts.push(`--- file: ${label} ---\n${content}`);
    textChars += content.length;
    return true;
  };

  const addImage = (bytes) => {
    images.push(bytesToBase64(bytes));
    return true;
  };

  for (const file of files) {
    if (file.size > MAX_ATTACH_BYTES) {
      throw new Error(`${file.name} is larger than 20 MB`);
    }
    if (isImageFile(file)) {
      const dataUrl = await readFileAsDataURL(file);
      const b64 = dataUrl.includes(",") ? dataUrl.split(",")[1] : dataUrl;
      if (!b64) throw new Error(`failed to encode ${file.name}`);
      images.push(b64);
    } else if (isTextFile(file)) {
      const body = await readFileAsText(file);
      if (!addText(file.name, body) && !textParts.length) {
        throw new Error("attached text exceeds size limit");
      }
    } else if (isZipFile(file)) {
      const buf = await readFileAsArrayBuffer(file);
      const entries = await extractZipEntries(buf, file.name);
      let used = 0;
      for (const ent of entries) {
        const label = `${file.name}:${ent.name}`;
        if (isImageName(ent.name)) {
          if (addImage(ent.data)) used += 1;
        } else if (isTextName(ent.name)) {
          if (addText(label, decodeUtf8(ent.data))) used += 1;
        }
      }
      if (!used) {
        throw new Error(`${file.name}: no text or image files inside zip`);
      }
    } else {
      throw new Error(`${file.name}: only images, text, and zip files are supported`);
    }
  }
  return { images, textParts };
}

function chatReady() {
  const m = selectedModel();
  return !!(
    m &&
    m.status === "running" &&
    !state.loading.has(m.name) &&
    !state.busy.has(m.name) &&
    !state.streaming
  );
}

function updateSendEnabled() {
  const hasFiles = !!(el.files && el.files.files && el.files.files.length);
  el.send.disabled = !chatReady() || (!state.input.trim() && !hasFiles);
}

async function sendChat() {
  const name = state.selected;
  const text = el.input.value.trim();
  const fileList = el.files?.files;
  const hasFiles = !!(fileList && fileList.length);
  if (!name || state.streaming) return;
  if (!text && !hasFiles) return;

  const model = selectedModel();
  if (!model || model.status !== "running" || state.loading.has(name)) {
    showToast(`start ${name} before chatting`, true);
    return;
  }

  let images = [];
  let message = text;
  try {
    if (hasFiles) {
      const prepared = await prepareAttachments(fileList);
      images = prepared.images;
      if (prepared.textParts.length) {
        message = [text, ...prepared.textParts].filter(Boolean).join("\n\n");
      }
    }
  } catch (err) {
    showToast(err.message, true);
    return;
  }

  state.input = text;
  state.output = "";
  state.timing = null;
  state.streaming = true;
  render();

  const wallStart = performance.now();
  let firstTokenAt = null;

  try {
    const res = await fetch(`/api/models/${encodeModel(name)}/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/x-ndjson" },
      body: JSON.stringify({
        message,
        history: [],
        think: !!el.think?.checked,
        images,
      }),
    });

    if (!res.ok) {
      let detail = res.statusText;
      try {
        const err = await res.json();
        detail = err.detail || detail;
      } catch {
        /* ignore */
      }
      throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let lastMeta = null;
    let breakdown = null;

    const handleLine = (line) => {
      if (!line.trim()) return;
      let chunk;
      try {
        chunk = JSON.parse(line);
      } catch {
        return;
      }
      if (chunk.error) throw new Error(chunk.error);
      if (chunk.overhead_breakdown) {
        breakdown = chunk.overhead_breakdown;
        return;
      }
      const thinkOn = !!el.think?.checked;
      const piece = thinkOn
        ? (chunk.message?.content ?? chunk.message?.thinking ?? "")
        : (chunk.message?.content ?? "");
      if (piece) {
        if (firstTokenAt == null) firstTokenAt = performance.now();
        state.output += piece;
        el.output.value = state.output;
        el.output.scrollTop = el.output.scrollHeight;
      }
      if (chunk.done || chunk.total_duration != null || chunk.load_duration != null) {
        lastMeta = chunk;
      }
    };

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      for (const line of lines) handleLine(line);
    }
    buffer += decoder.decode();
    if (buffer.trim()) handleLine(buffer);

    if (!state.output.trim()) state.output = "(empty response)";

    const wallTotalNs = (performance.now() - wallStart) * 1e6;
    const loadNs = lastMeta?.load_duration ?? msToNs(breakdown?.load_ms) ?? null;
    const promptNs = lastMeta?.prompt_eval_duration ?? msToNs(breakdown?.prompt_ms) ?? null;
    const genNs = lastMeta?.eval_duration ?? msToNs(breakdown?.gen_ms) ?? null;
    const queryNs =
      promptNs != null || genNs != null
        ? (promptNs || 0) + (genNs || 0)
        : firstTokenAt != null
          ? (performance.now() - firstTokenAt) * 1e6
          : null;

    const m = selectedModel();
    state.timing = {
      load: loadNs,
      prompt: promptNs,
      gen: genNs,
      query: queryNs,
      total: lastMeta?.total_duration ?? msToNs(breakdown?.total_ms) ?? wallTotalNs,
      cold: (loadNs || 0) >= 1e9,
      device: m?.device || null,
      breakdown,
    };
    pushTimingHistory(state.timing);
    if (el.files) {
      el.files.value = "";
      updateFilesLabel();
    }
  } catch (err) {
    state.output = state.output || `error: ${err.message}`;
    state.timing = {
      load: null,
      query: null,
      total: (performance.now() - wallStart) * 1e6,
    };
    showToast(err.message, true);
  } finally {
    state.streaming = false;
    snapshotInput();
    render();
  }
}

el.select.addEventListener("change", () => {
  snapshotInput();
  state.selected = el.select.value;
  renderSelected();
});

el.toggle.addEventListener("click", () => toggleSelected());

el.input.addEventListener("input", () => {
  state.input = el.input.value;
  updateSendEnabled();
});

el.files?.addEventListener("change", () => {
  updateFilesLabel();
  updateSendEnabled();
});

el.form.addEventListener("submit", (e) => {
  e.preventDefault();
  sendChat();
});

el.stopAll.addEventListener("click", async () => {
  el.stopAll.disabled = true;
  try {
    await api("/api/stop-all", { method: "POST" });
    state.loadTimes = {};
    showToast("all isolated servers stopped");
  } catch (err) {
    showToast(err.message, true);
  } finally {
    el.stopAll.disabled = false;
    await refresh();
  }
});

function formatBytes(n) {
  if (n == null || Number.isNaN(n)) return "";
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

function formatParamB(n) {
  if (n == null || Number.isNaN(n)) return "";
  if (n < 1) return `${Math.round(n * 1000)}m`;
  if (Number.isInteger(n)) return `${n}b`;
  return `${n}b`;
}

async function refreshAvailable() {
  if (!el.available) return;
  const prev = el.available.value;
  try {
    const data = await api("/api/models/available");
    const models = data.models || [];
    el.available.replaceChildren();
    if (!models.length) {
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "no fitting models to download";
      el.available.appendChild(opt);
      return;
    }
    const placeholder = document.createElement("option");
    placeholder.value = "";
    placeholder.textContent = `select model (≤${data.max_param_b}b on ${data.vram_gb}gb)`;
    el.available.appendChild(placeholder);
    for (const m of models) {
      const opt = document.createElement("option");
      opt.value = m.name;
      opt.textContent = `${m.name} (${formatParamB(m.param_b)} · ${m.category || "general"})`;
      el.available.appendChild(opt);
    }
    if (prev && [...el.available.options].some((o) => o.value === prev)) {
      el.available.value = prev;
    }
  } catch (err) {
    el.available.replaceChildren();
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "failed to load catalog";
    el.available.appendChild(opt);
    showToast(err.message || "failed to load available models", true);
  }
}

async function downloadModel() {
  const custom = (el.download?.value || "").trim();
  const selected = (el.available?.value || "").trim();
  const name = custom || selected;
  if (!name || !el.btnDownload) return;

  const wallStart = performance.now();
  const elapsedLabel = () => formatDuration((performance.now() - wallStart) * 1e6);

  el.btnDownload.disabled = true;
  if (el.download) el.download.disabled = true;
  if (el.available) el.available.disabled = true;
  el.downloadProgressWrap.hidden = false;
  el.downloadProgress.removeAttribute("value");
  el.downloadLabel.textContent = `pulling ${name}…`;

  try {
    const res = await fetch("/api/models/pull", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/x-ndjson" },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) {
      let detail = res.statusText;
      try {
        const err = await res.json();
        detail = err.detail || detail;
      } catch {
        /* ignore */
      }
      throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let doneInfo = null;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      for (const line of lines) {
        if (!line.trim()) continue;
        let chunk;
        try {
          chunk = JSON.parse(line);
        } catch {
          continue;
        }
        if (chunk.error) {
          throw new Error(chunk.error);
        }
        if (chunk.done) {
          doneInfo = chunk;
          continue;
        }
        const status = (chunk.status || "").toLowerCase();
        const t = elapsedLabel();
        if (chunk.completed != null && chunk.total) {
          const pct = (100 * chunk.completed) / chunk.total;
          el.downloadProgress.max = 100;
          el.downloadProgress.value = pct;
          el.downloadLabel.textContent = `${status} ${pct.toFixed(0)}% (${formatBytes(chunk.completed)} / ${formatBytes(chunk.total)}) · ${t}`;
        } else {
          el.downloadProgress.removeAttribute("value");
          el.downloadLabel.textContent = `${status || `pulling ${name}…`} · ${t}`;
        }
      }
    }
    if (buffer.trim()) {
      try {
        const chunk = JSON.parse(buffer);
        if (chunk.error) throw new Error(chunk.error);
        if (chunk.done) doneInfo = chunk;
      } catch (err) {
        if (err.message && !String(err.message).includes("JSON")) throw err;
      }
    }

    const model = doneInfo?.model || name;
    const took = formatDuration((performance.now() - wallStart) * 1e6);
    el.downloadProgress.value = 100;
    el.downloadLabel.textContent = `done in ${took} · port ${doneInfo?.port ?? "?"}`;
    showToast(`downloaded ${model} in ${took}`);
    if (el.download) el.download.value = "";
    if (el.available) el.available.value = "";
    state.selected = model;
    await refresh();
    await refreshAvailable();
  } catch (err) {
    const took = formatDuration((performance.now() - wallStart) * 1e6);
    el.downloadLabel.textContent = `error after ${took}: ${err.message}`;
    el.downloadProgress.removeAttribute("value");
    showToast(err.message, true);
  } finally {
    el.btnDownload.disabled = false;
    if (el.download) el.download.disabled = false;
    if (el.available) el.available.disabled = false;
  }
}

el.btnDownload?.addEventListener("click", () => downloadModel());
el.download?.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    downloadModel();
  }
});

refreshAvailable();
refresh();
setInterval(refresh, 4000);
