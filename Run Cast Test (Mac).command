#!/bin/bash
# Double-click in Finder to run the Phase 0 Cast receiver test on macOS.
# First run installs what's missing (ffmpeg, Python, pychromecast) and remembers the TV.

set -u
cd "$(dirname "$0")/spike" || exit 1

say()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m%s\033[0m\n" "$*"; read -r -p "Press Return to close."; exit 1; }

# --- Homebrew ---------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
fi
command -v brew >/dev/null 2>&1 || fail "Homebrew isn't installed. Install it from https://brew.sh, then run this again."

# --- ffmpeg + Python ----------------------------------------------------------
if ! command -v ffmpeg >/dev/null 2>&1; then
  say "Installing ffmpeg (one time)..."
  brew install ffmpeg || fail "brew install ffmpeg failed."
fi
PY="$(brew --prefix)/bin/python3"
if ! { [ -x "$PY" ] && "$PY" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; }; then
  say "Installing Python (one time)..."
  brew install python || fail "brew install python failed."
fi
[ -x "$PY" ] || fail "Couldn't find Homebrew's python3."

# --- venv + pychromecast ------------------------------------------------------
if [ ! -x .venv/bin/python ]; then
  say "Setting up Python environment (one time)..."
  "$PY" -m venv .venv || fail "Couldn't create the Python environment."
  .venv/bin/pip install -q --upgrade pip
fi
.venv/bin/pip install -q -r requirements.txt || fail "pip install failed."
RUN=".venv/bin/python cast_test.py"

# --- pick the TV ----------------------------------------------------------------
DEVFILE=".device"
DEVICE=""
[ -s "$DEVFILE" ] && DEVICE="$(cat "$DEVFILE")"

pick_device() {
  say "Looking for Cast devices (allow Local Network access if macOS asks)..."
  NAMES=()
  while IFS= read -r line; do [ -n "$line" ] && NAMES+=("$line"); done < <($RUN --list-names)
  if [ ${#NAMES[@]} -eq 0 ]; then
    fail "No Cast devices found. Is the TV on and on the same Wi-Fi? Check System Settings → Privacy & Security → Local Network → Terminal."
  fi
  echo "Which TV?"
  select n in "${NAMES[@]}"; do
    [ -n "${n:-}" ] && DEVICE="$n" && printf "%s" "$n" > "$DEVFILE" && break
  done
}
[ -z "$DEVICE" ] && pick_device

# Display index for screen capture ("Capture screen 0").
screen_index() {
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -nE 's/.*\[([0-9]+)\] Capture screen 0.*/\1/p' | head -1
}

# --- menu ---------------------------------------------------------------------
while true; do
  say "Casting to: $DEVICE"
  cat <<'EOF'
  1) H.264 1080p 30fps    test pattern
  2) H.264 1080p 60fps    test pattern
  3) HEVC  1080p 60fps    test pattern
  4) HEVC  4K    60fps    test pattern   <- the important one
  5) H.264 4K    60fps    test pattern
  6) HEVC  4K    60fps    0.5 s segments (lower delay?)
  7) HEVC  4K    60fps    your screen (for measuring delay)
  t) Pick a different TV
  q) Quit
EOF
  read -r -p "Choose: " c
  ARGS=()
  case "$c" in
    1) ARGS=(--codec h264 --res 1080p --fps 30) ;;
    2) ARGS=(--codec h264 --res 1080p --fps 60) ;;
    3) ARGS=(--codec hevc --res 1080p --fps 60) ;;
    4) ARGS=(--codec hevc --res 4k --fps 60) ;;
    5) ARGS=(--codec h264 --res 4k --fps 60) ;;
    6) ARGS=(--codec hevc --res 4k --fps 60 --segment 0.5) ;;
    7) idx="$(screen_index)"
       [ -z "$idx" ] && { echo "Couldn't find the screen. Give Terminal Screen Recording permission (Privacy & Security), reopen it, and retry."; continue; }
       echo "Tip: open a stopwatch with milliseconds on screen, then photograph the Mac and the TV together."
       ARGS=(--codec hevc --res 4k --fps 60 --source screen --mac-screen "$idx") ;;
    t|T) pick_device; continue ;;
    q|Q) exit 0 ;;
    *) continue ;;
  esac
  say "Running test $c. Press Ctrl+C to stop and come back to this menu."
  trap ':' INT
  $RUN --device "$DEVICE" "${ARGS[@]}"
  trap - INT
done
