#!/usr/bin/env bash
# Wyltek Studio — Smart installer
# Checks prerequisites, installs dependencies, creates config, sets up systemd service.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/toastmanAu/wyltek-studio/master/install.sh | bash
#   or: ./install.sh

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "${RED}[x]${NC} $1"; }
step()  { echo -e "\n${BOLD}=== $1 ===${NC}"; }

INSTALL_DIR="${OPEN_PALETTE_DIR:-$(pwd)}"

# --- Header ---
echo -e "${BOLD}"
echo " __        __    _ _       _      ____  _             _ _       "
echo " \ \      / /   | | |_ ___| | __ / ___|| |_ _   _  __| (_) ___  "
echo "  \ \ /\ / / | | | | __/ _ \ |/ / \___ \| __| | | |/ _\` | |/ _ \ "
echo "   \ V  V /| |_| | | ||  __/   <   ___) | |_| |_| | (_| | | (_) |"
echo "    \_/\_/  \__, |_|\__\___|_|\_\ |____/ \__|\__,_|\__,_|_|\___/ "
echo "            |___/                                                "
echo -e "${NC}"
echo "Local-first AI creative studio — by Wyltek Industries"
echo ""

# --- Check Python ---
step "Checking prerequisites"

PYTHON=""
for cmd in python3 python; do
  if command -v "$cmd" &>/dev/null; then
    ver=$("$cmd" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    major=$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null)
    minor=$("$cmd" -c "import sys; print(sys.version_info.minor)" 2>/dev/null)
    if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
      PYTHON="$cmd"
      info "Python $ver found ($cmd)"
      break
    fi
  fi
done

if [ -z "$PYTHON" ]; then
  fail "Python 3.10+ is required but not found."
  echo "  Install it:"
  echo "    Ubuntu/Debian: sudo apt install python3 python3-pip python3-venv"
  echo "    macOS:         brew install python@3.12"
  echo "    Fedora:        sudo dnf install python3 python3-pip"
  exit 1
fi

# Check pip
if ! "$PYTHON" -m pip --version &>/dev/null; then
  warn "pip not found. Attempting to install..."
  "$PYTHON" -m ensurepip --default-pip 2>/dev/null || {
    fail "pip is required. Install it:"
    echo "  sudo apt install python3-pip   (Ubuntu/Debian)"
    echo "  sudo dnf install python3-pip   (Fedora)"
    exit 1
  }
fi
info "pip available"

# Check git
if command -v git &>/dev/null; then
  info "git found"
else
  warn "git not found — you'll need it for updates"
fi

# --- Clone or detect existing install ---
step "Setting up Wyltek Studio"

if [ -f "$INSTALL_DIR/server.py" ] && [ -f "$INSTALL_DIR/scoring.py" ]; then
  info "Existing installation found at $INSTALL_DIR"
else
  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Git repo detected, pulling latest..."
    git -C "$INSTALL_DIR" pull origin master 2>/dev/null || true
  elif command -v git &>/dev/null; then
    echo "Clone into: $INSTALL_DIR? [Y/n] "
    read -r answer
    if [ "${answer:-Y}" != "n" ] && [ "${answer:-Y}" != "N" ]; then
      git clone https://github.com/toastmanAu/wyltek-studio.git "$INSTALL_DIR"
      cd "$INSTALL_DIR"
    fi
  fi
fi

cd "$INSTALL_DIR"

# --- Virtual environment ---
step "Python environment"

if [ -d "venv" ]; then
  info "Virtual environment exists"
else
  info "Creating virtual environment..."
  "$PYTHON" -m venv venv
fi

source venv/bin/activate
info "Activated venv"

# --- Install dependencies ---
step "Installing dependencies"

pip install --upgrade pip -q
pip install -r requirements.txt -q
info "All Python dependencies installed"

# Verify critical imports
"$PYTHON" -c "import fastapi, uvicorn, cv2, numpy, PIL, yaml, httpx, aiohttp" 2>/dev/null && \
  info "All imports verified" || \
  warn "Some imports failed — check the output above"

# --- Config ---
step "Configuration"

if [ -f "config.yaml" ]; then
  info "config.yaml already exists (not overwriting)"
else
  cp config.example.yaml config.yaml
  info "Created config.yaml from template"
  echo ""
  warn "Edit config.yaml to set up your backends:"
  echo "  - ComfyUI URL (if running locally)"
  echo "  - API keys for cloud backends (Gemini, etc.)"
fi

# Create data directory
mkdir -p data outputs uploads
info "Data directories ready"

# --- Check optional services ---
step "Optional services"

# ComfyUI
echo -n "  ComfyUI: "
COMFY_URL=$(grep -oP 'url:\s*"?\K[^"]+' config.yaml 2>/dev/null | head -1)
if [ -n "$COMFY_URL" ]; then
  if curl -s --connect-timeout 3 "$COMFY_URL" &>/dev/null; then
    echo -e "${GREEN}connected${NC} ($COMFY_URL)"
  else
    echo -e "${YELLOW}configured but not reachable${NC} ($COMFY_URL)"
  fi
else
  echo -e "${DIM}not configured${NC}"
fi

# Ollama
echo -n "  Ollama:  "
if command -v ollama &>/dev/null; then
  OLLAMA_URL="http://[::1]:11434"
  if curl -s --connect-timeout 3 "$OLLAMA_URL/api/tags" &>/dev/null; then
    MODEL_COUNT=$(curl -s "$OLLAMA_URL/api/tags" 2>/dev/null | "$PYTHON" -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo "0")
    echo -e "${GREEN}running${NC} ($MODEL_COUNT models installed)"
    # Auto-configure if not already set
    if ! grep -q "prompt_optimizer" config.yaml 2>/dev/null; then
      cat >> config.yaml << 'YAML'

prompt_optimizer:
  enabled: true
  ollama_url: "http://[::1]:11434"
  model: "qwen2.5:14b"
YAML
      info "Auto-configured prompt optimizer in config.yaml"
    fi
  else
    echo -e "${YELLOW}installed but not running${NC}"
    echo "    Start it: ollama serve (or: sudo systemctl start ollama)"
  fi
else
  echo -e "${DIM}not installed${NC} (optional — enables 'OP my prompt')"
  echo "    Install: curl -fsSL https://ollama.com/install.sh | sh"
  echo "    Then:    ollama pull qwen2.5:14b"
fi

# GPU
echo -n "  GPU:     "
if command -v nvidia-smi &>/dev/null; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
  echo -e "${GREEN}$GPU_NAME${NC} ($GPU_MEM)"
else
  echo -e "${DIM}no NVIDIA GPU detected${NC} (cloud backends still work)"
fi

# --- Systemd service (optional) ---
step "System service (optional)"

SERVICE_PATH="$HOME/.config/systemd/user/wyltek-studio.service"
if [ -f "$SERVICE_PATH" ]; then
  info "Systemd service already exists"
  echo "    Status:  systemctl --user status wyltek-studio"
  echo "    Restart: systemctl --user restart wyltek-studio"
else
  echo "Install as a systemd user service? (auto-starts on login) [y/N] "
  read -r answer
  if [ "${answer}" = "y" ] || [ "${answer}" = "Y" ]; then
    mkdir -p "$(dirname "$SERVICE_PATH")"
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Wyltek Studio — local AI image generation studio
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python server.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable wyltek-studio
    systemctl --user start wyltek-studio
    info "Service installed and started"
  else
    info "Skipped — run manually with: python server.py"
  fi
fi

# --- Done ---
step "Setup complete"

PORT=$(grep -oP 'port:\s*\K[0-9]+' config.yaml 2>/dev/null | head -1)
PORT="${PORT:-7860}"

echo ""
echo -e "  ${BOLD}Wyltek Studio is ready!${NC}"
echo ""
echo -e "  Start:   ${GREEN}cd $INSTALL_DIR && source venv/bin/activate && python server.py${NC}"
echo -e "  Open:    ${GREEN}http://localhost:$PORT${NC}"
echo ""
echo "  Next steps:"
echo "    1. Edit config.yaml with your ComfyUI URL or cloud API keys"
echo "    2. Open the Settings page to configure backends"
echo "    3. Try 'OP my prompt' to enhance prompts with AI (requires Ollama)"
echo ""
