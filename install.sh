#!/usr/bin/env bash
# Bootstrap this machine for the local Ollama control panel.
# - Installs Ollama if missing (Linux installer or Homebrew on macOS)
# - Creates the web venv + dependencies (Python 3.11+)
# - Builds models.conf from models.json + detected GPU / unified memory
# - Ensures a private GitHub repo exists (gh)
# - Pins project semver from VERSION (starts at 0.0.0)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

VERSION_FILE="$ROOT/VERSION"
DEFAULT_VERSION="0.0.0"
OWNER="${GH_OWNER:-}"
REPO_NAME="${GH_REPO:-$(basename "$ROOT")}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Prefer Homebrew / pyenv Python 3.12+ over macOS system Python 3.9.
resolve_python() {
    local cand
    for cand in \
        "${PYTHON:-}" \
        python3.14 python3.13 python3.12 python3.11 \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3 \
        python3
    do
        [[ -n "$cand" ]] || continue
        if command -v "$cand" >/dev/null 2>&1; then
            if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
                command -v "$cand"
                return 0
            fi
        fi
    done
    die "need Python 3.11+ (macOS system python3 is too old; install via: brew install python)"
}

PYTHON3="$(resolve_python)"

read_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        tr -d '[:space:]' <"$VERSION_FILE"
    else
        printf '%s' "$DEFAULT_VERSION"
    fi
}

ensure_version_file() {
    local ver
    ver="$(read_version)"
    if [[ ! -f "$VERSION_FILE" ]]; then
        log "Writing VERSION=$DEFAULT_VERSION"
        printf '%s\n' "$DEFAULT_VERSION" >"$VERSION_FILE"
        ver="$DEFAULT_VERSION"
    fi
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].+)?$ ]] \
        || die "VERSION must be semver (got: $ver)"
    log "Project version: $ver"
}

ensure_ollama() {
    if command -v ollama >/dev/null 2>&1; then
        log "Ollama already installed: $(ollama --version 2>/dev/null | head -1)"
        return 0
    fi

    log "Ollama not found — installing"
    local os
    os="$(uname -s)"
    if [[ "$os" == "Darwin" ]]; then
        if command -v brew >/dev/null 2>&1; then
            brew install ollama
        else
            die "install Ollama from https://ollama.com/download or: brew install ollama"
        fi
    elif [[ "$os" == "Linux" ]]; then
        need_cmd curl
        # Official installer (adds binary + systemd unit when possible).
        curl -fsSL https://ollama.com/install.sh | sh
    else
        die "unsupported OS '$os'; install Ollama from https://ollama.com/download"
    fi

    command -v ollama >/dev/null 2>&1 \
        || die "Ollama install finished but 'ollama' is not on PATH"
    log "Installed: $(ollama --version 2>/dev/null | head -1)"
}

ensure_ollama_service() {
    local os
    os="$(uname -s)"
    if [[ "$os" == "Darwin" ]]; then
        if command -v brew >/dev/null 2>&1 && brew services list 2>/dev/null | grep -q '^ollama'; then
            if brew services list 2>/dev/null | awk '$1=="ollama"{print $2}' | grep -q started; then
                log "Homebrew ollama service is started"
            else
                log "Starting Homebrew ollama service"
                brew services start ollama
            fi
            return 0
        fi
        if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
            log "Ollama already responding on :11434"
            return 0
        fi
        warn "start Ollama with: brew services start ollama  (or open the Ollama app)"
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not available — start ollama manually if needed"
        return 0
    fi
    if systemctl list-unit-files ollama.service >/dev/null 2>&1; then
        if ! systemctl is-active --quiet ollama; then
            log "Starting ollama.service"
            if systemctl is-enabled --quiet ollama 2>/dev/null; then
                sudo systemctl start ollama
            else
                sudo systemctl enable --now ollama
            fi
        else
            log "ollama.service is active"
        fi
    else
        warn "ollama.service not found — run 'ollama serve' in the background if needed"
    fi
}

ensure_repo_files() {
    if [[ ! -f "$ROOT/models.json" ]]; then
        die "missing models.json (needed to populate models.conf from machine specs)"
    fi
    [[ -f "$ROOT/ollama-isolated.sh" ]] || die "missing ollama-isolated.sh"
    [[ -f "$ROOT/web/server.py" ]] || die "missing web/server.py"
    [[ -f "$ROOT/web/requirements.txt" ]] || die "missing web/requirements.txt"
    chmod +x "$ROOT/install.sh" "$ROOT/gpt" "$ROOT/bench.sh" "$ROOT/ollama-isolated.sh" 2>/dev/null || true
}

gpu_vram_mib() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        local total=0 line
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            total=$((total + ${line%%.*}))
        done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)
        if [[ "$total" -gt 0 ]]; then
            printf '%s' "$total"
            return 0
        fi
    fi
    # Apple Silicon: unified memory (treat system RAM as the GPU budget).
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local bytes mib
        bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
        if [[ -n "$bytes" && "$bytes" -gt 0 ]]; then
            mib=$((bytes / 1024 / 1024))
            printf '%s' "$mib"
            return 0
        fi
    fi
    # Fallback: 16GB-class card (matches historical default for this project).
    printf '%s' "16303"
}

ensure_models_conf() {
    local vram_mib vram_gb max_gb
    log "Using Python: $PYTHON3 ($("$PYTHON3" -c 'import sys; print(sys.version.split()[0])'))"
    vram_mib="$(gpu_vram_mib)"
    # Whole-GB rounding so 16303 MiB → 16GB → 14GB weight budget (same rule as the UI).
    vram_gb="$("$PYTHON3" -c "print(round(float('$vram_mib') / 1024))")"
    max_gb="$("$PYTHON3" -c "print(round(float('$vram_gb') * 14 / 16, 2))")"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        log "Apple Silicon unified memory ${vram_gb}GB — models.conf weights ≤ ${max_gb}GB"
    else
        log "GPU VRAM ${vram_gb}GB — populating models.conf with weights ≤ ${max_gb}GB (full GPU fit)"
    fi

    if [[ -f "$ROOT/models.conf" ]]; then
        cp -a "$ROOT/models.conf" "$ROOT/models.conf.bak"
    fi

    MODELS_JSON="$ROOT/models.json" \
    MODELS_CONF="$ROOT/models.conf" \
    VRAM_GB="$vram_gb" \
    MAX_GB="$max_gb" \
    "$PYTHON3" <<'PY'
import json, os, re
from pathlib import Path

models_json = Path(os.environ["MODELS_JSON"])
conf_path = Path(os.environ["MODELS_CONF"])
vram_gb = float(os.environ["VRAM_GB"])
max_gb = float(os.environ["MAX_GB"])

meta = json.loads(models_json.read_text(encoding="utf-8"))
catalog = meta.get("models") or {}

# Preserve ports for models we keep.
old_ports = {}
if conf_path.exists():
    for line in conf_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, port = line.split("=", 1)
        try:
            old_ports[name.strip()] = int(port.strip())
        except ValueError:
            pass

size_re = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(GB|MB|TB)\s*$", re.I)

def size_to_gb(text: str) -> float | None:
    m = size_re.match(text or "")
    if not m:
        return None
    n = float(m.group(1))
    unit = m.group(2).upper()
    if unit == "MB":
        return n / 1024.0
    if unit == "TB":
        return n * 1024.0
    return n

chosen = []
for name, info in catalog.items():
    if (info.get("category") or "").lower() == "embeddings":
        continue
    gb = size_to_gb(info.get("size") or "")
    if gb is None:
        # Fall back to curated label when size string is missing.
        if (info.get("gpu_fit") or "").lower() != "full":
            continue
        gb = 0.0
    if gb > max_gb:
        continue
    chosen.append((name, gb, info.get("gpu_fit") or "", info.get("category") or "general"))

chosen.sort(key=lambda t: (t[1], t[0]))

used = set(old_ports.values())
used.add(11434)
next_port = 11435

def alloc(name: str) -> int:
    global next_port
    if name in old_ports and old_ports[name] != 11434:
        return old_ports[name]
    while next_port in used:
        next_port += 1
    port = next_port
    used.add(port)
    next_port += 1
    return port

lines = [
    "# model=port",
    "# Port 11434 is reserved for the main systemd ollama service",
    f"# Auto-generated by install.sh for ~{vram_gb:g}GB VRAM "
    f"(include weights ≤ {max_gb:g}GB; embeddings excluded)",
]
for name, gb, fit, cat in chosen:
    port = alloc(name)
    lines.append(f"{name}={port}")

conf_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

# Refresh gpu_note to match this machine.
meta["gpu_note"] = (
    f"~{vram_gb:g}GB VRAM. Models up to ~{max_gb:g}GB (Q4-class) are treated as full GPU fit. "
    f"Larger weights spill to system RAM."
)
models_json.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
print(f"wrote {len(chosen)} models to {conf_path}")
PY

    log "models.conf ready ($(grep -c '^[a-zA-Z0-9]' "$ROOT/models.conf" || true) entries)"
}

ensure_web_venv() {
    log "Setting up web virtualenv with $PYTHON3"
    cd "$ROOT/web"
    if [[ ! -d .venv ]]; then
        "$PYTHON3" -m venv .venv
    fi
    # Avoid inherited corporate index (e.g. CodeArtifact) for this local panel.
    export PIP_INDEX_URL="https://pypi.org/simple"
    export PIP_TRUSTED_HOST="pypi.org files.pythonhosted.org"
    unset PIP_EXTRA_INDEX_URL PIP_FIND_LINKS || true
    .venv/bin/pip install -q --upgrade pip
    .venv/bin/pip install -q -r requirements.txt
    cd "$ROOT"
    log "Python deps ready"
}

ensure_git() {
    need_cmd git
    if [[ ! -d "$ROOT/.git" ]]; then
        log "Initializing git repository"
        git init -b main
    fi
    if [[ -z "$(git config --get user.email || true)" ]]; then
        warn "git user.email is not set (commits will need it later)"
    fi
}

resolve_owner() {
    if [[ -n "$OWNER" ]]; then
        printf '%s' "$OWNER"
        return 0
    fi
    local url
    url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$url" =~ github.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    need_cmd gh
    gh api user -q .login
}

ensure_private_github_repo() {
    need_cmd gh
    if ! gh auth status >/dev/null 2>&1; then
        die "GitHub CLI is not authenticated — run: gh auth login"
    fi

    local owner remote_url full
    owner="$(resolve_owner)"
    full="${owner}/${REPO_NAME}"

    if git remote get-url origin >/dev/null 2>&1; then
        remote_url="$(git remote get-url origin)"
        log "Git remote origin: $remote_url"
        if gh repo view "$full" >/dev/null 2>&1; then
            local vis
            vis="$(gh repo view "$full" --json isPrivate -q .isPrivate)"
            if [[ "$vis" == "true" ]]; then
                log "GitHub repo $full exists and is private"
            else
                warn "GitHub repo $full exists but is public"
            fi
            return 0
        fi
        log "Remote origin set but GitHub repo missing — creating private $full"
        gh repo create "$full" --private --source="$ROOT" --remote=origin --push=false
        return 0
    fi

    if gh repo view "$full" >/dev/null 2>&1; then
        log "GitHub repo $full already exists — adding origin"
        gh repo view "$full" --json url -q .url | sed 's|https://github.com/|https://github.com/|' >/dev/null
        git remote add origin "https://github.com/${full}.git"
        return 0
    fi

    log "Creating private GitHub repo $full"
    gh repo create "$full" --private --source="$ROOT" --remote=origin --push=false
    log "Created https://github.com/${full} (private)"
}

ensure_semver_tag() {
    local ver tag
    ver="$(read_version)"
    tag="v${ver}"
    if git rev-parse "$tag" >/dev/null 2>&1; then
        log "Git tag $tag already exists"
        return 0
    fi
    if git rev-parse HEAD >/dev/null 2>&1; then
        log "Creating local git tag $tag"
        git tag -a "$tag" -m "Release $tag"
    else
        warn "No commits yet — skip tag $tag (create after first commit)"
    fi
}

print_next_steps() {
    local ver
    ver="$(read_version)"
    cat <<EOF

Setup complete (version $ver).

  Start control panel:  ./gpt panel
  Or detached:          ./gpt panel --daemon
  Open UI:              http://127.0.0.1:8080
  Isolated models:      ./gpt list
  Benchmark:            ./gpt bench

  Push when ready:      git push -u origin HEAD
                        git push origin v${ver}

EOF
}

main() {
    ensure_version_file
    ensure_repo_files
    ensure_models_conf
    ensure_ollama
    ensure_ollama_service
    ensure_web_venv
    ensure_git
    ensure_private_github_repo
    ensure_semver_tag
    print_next_steps
}

main "$@"
