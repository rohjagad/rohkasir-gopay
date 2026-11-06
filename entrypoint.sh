#!/usr/bin/env bash
# =====================================================================
# RohKasir GoPay Gateway - Installer + Service Starter (PID 1)
#
# Fetched and executed by the bootstrap inside docker-stack.yml.
# Cached at /app/.docker-entrypoint.sh (named volume) so the container
# keeps working even after the repo goes private.
#
# Flow:
#   - service NOT installed  -> install (deps, clone, API key, npm ci) + start
#   - service installed      -> try update (best effort) + start
#   - repo unreachable       -> warn, start existing install
# =====================================================================
set -eu

export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0

APP_DIR="/app"
REPO_URL="${REPO_URL:-https://github.com/rohjagad/rohkasir-gopay.git}"
GIT_TOKEN="${GIT_TOKEN:-}"
BRANCH="main"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------------------------------------------------------------------
# 1. Runtime dependencies (container filesystem is ephemeral)
#    Debian 12 repos provide Node.js 18.x (the recommended version).
# ---------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 \
   || ! command -v git >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    log "Installing git + rsync + nodejs + npm + ca-certificates ..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates git rsync nodejs npm >/dev/null
fi
log "Using $(node -v) / npm v$(npm -v)"

# ---------------------------------------------------------------------
# 2. Install / repair / update (idempotent & crash-safe against outages)
# ---------------------------------------------------------------------
# --- code: clone only when actually missing (partial states self-heal) ---
if [ ! -f "$APP_DIR/server.js" ] || [ ! -f "$APP_DIR/package.json" ]; then
    log "Service not installed - cloning $REPO_URL ..."

    CLONE_URL="$REPO_URL"
    [ -n "$GIT_TOKEN" ] && CLONE_URL="https://x-access-token:${GIT_TOKEN}@${REPO_URL#https://}"

    SRC="$(mktemp -d)"
    n=0
    until git clone -q --branch "$BRANCH" "$CLONE_URL" "$SRC"; do
        n=$((n + 1))
        if [ "$n" -ge 10 ]; then
            log "ERROR: repository unreachable after $n attempts."
            log "Make the repo public (or set GIT_TOKEN) - swarm will restart me."
            exit 1
        fi
        log "Clone failed (attempt $n/10) - retrying in 30s ..."
        sleep 30
    done

    # Merge into /app (volume may already hold cached entrypoint etc.)
    rsync -a "$SRC"/ "$APP_DIR"/
    rm -rf "$SRC"
    log "Code ready."
else
    log "Service already installed - checking for updates ..."
    if timeout 25 git -C "$APP_DIR" pull --ff-only -q origin "$BRANCH" 2>/dev/null; then
        log "Repository reachable - up to date."
    else
        log "WARN: repository unreachable (private?) - starting existing install."
    fi
fi

# --- deps: (re)install when lockfile changed OR previous run was cut off ---
cd "$APP_DIR"
DEP_STAMP="$(md5sum package.json package-lock.json 2>/dev/null | md5sum | cut -d' ' -f1)"
if [ "$(cat "$APP_DIR/node_modules/.install_ok" 2>/dev/null)" != "$DEP_STAMP" ]; then
    log "Installing npm dependencies (--omit=dev) ..."
    npm ci --omit=dev --no-audit --no-fund
    echo "$DEP_STAMP" >"$APP_DIR/node_modules/.install_ok"
    log "Dependencies ready."
fi

# ---------------------------------------------------------------------
# 2b. Unique API key - generated once, stored OUTSIDE git-tracked .env
#     (/app/.api_key lives in the named volume; .env stays pristine
#      so future `git pull` updates never conflict)
# ---------------------------------------------------------------------
GENERATED=0
if [ ! -s "$APP_DIR/.api_key" ]; then
    node -e "console.log(require('crypto').randomBytes(24).toString('hex'))" >"$APP_DIR/.api_key"
    chmod 600 "$APP_DIR/.api_key"
    GENERATED=1
fi
API_KEY="$(cat "$APP_DIR/.api_key")"
if [ "$GENERATED" -eq 1 ]; then
    log "==============================================================="
    log "  NEW UNIQUE API KEY GENERATED:"
    log "  ${API_KEY}"
    log "  Copy it now! Always retrievable via: cat /app/.api_key"
    log "==============================================================="
fi
export API_KEY

# ---------------------------------------------------------------------
# 3. Start the service
# ---------------------------------------------------------------------
cd "$APP_DIR"
log "Starting gateway on port ${PORT:-3000} ..."
exec node server.js
