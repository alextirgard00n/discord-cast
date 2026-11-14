#!/bin/bash
# Double-click in Finder: casts a Discord stream window to your TV.
# First run installs what's missing (ffmpeg, Python, pychromecast) and builds the capture helper.

set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1

say()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m%s\033[0m\n" "$*"; read -r -p "Press Return to close."; exit 1; }

# --- Homebrew, ffmpeg, Python ---------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
fi
command -v brew >/dev/null 2>&1 || fail "Homebrew isn't installed. Install it from https://brew.sh, then run this again."
export HOMEBREW_NO_ENV_HINTS=1

if ! command -v ffmpeg >/dev/null 2>&1; then
  say "Installing ffmpeg (one time)..."
  brew install ffmpeg || fail "brew install ffmpeg failed."
fi
PY="$(brew --prefix)/bin/python3"
if ! { [ -x "$PY" ] && "$PY" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; }; then
  say "Installing Python (one time)..."
  brew install python || fail "brew install python failed."
fi

if [ ! -x app/.venv/bin/python ]; then
  say "Setting up Python environment (one time)..."
  "$PY" -m venv app/.venv || fail "Couldn't create the Python environment."
  app/.venv/bin/pip install -q --upgrade pip
fi
app/.venv/bin/pip install -q -r app/requirements.txt || fail "pip install failed."

# --- Build the capture helper -----------------------------------------------------
if ! command -v swift >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null
  fail "Swift isn't available. Install the Command Line Tools from the dialog that just opened (or Xcode), then run this again."
fi
say "Building the capture helper..."
LOG="$(mktemp -t dc-build)"
# Debug build while we're testing: crashes print a readable reason instead of a bare trap.
if ! swift build -c debug --package-path mac/dc-capture >"$LOG" 2>&1; then
  grep -E "error|warning: unre" "$LOG" | head -40
  echo "(full log: $LOG)"
  fail "The capture helper didn't build. Send me the errors above."
fi
CAP="mac/dc-capture/.build/debug/dc-capture"
[ -x "$CAP" ] || fail "The capture helper didn't build (no binary)."

RUN="app/.venv/bin/python app/discord_cast.py --capture-bin $CAP"

# --- TV ------------------------------------------------------------------------------
DEVFILE="app/.device"
[ ! -s "$DEVFILE" ] && [ -s spike/.device ] && cp spike/.device "$DEVFILE"
DEVICE=""
[ -s "$DEVFILE" ] && DEVICE="$(cat "$DEVFILE")"

pick_tv() {
  say "Looking for TVs (allow Local Network access if macOS asks)..."
  local names=()
  while IFS= read -r line; do [ -n "$line" ] && names+=("$line"); done < <($RUN --tvs)
  [ ${#names[@]} -eq 0 ] && fail "No Cast devices found. Is the TV on and on the same network?"
  echo "Which TV?"
  select n in "${names[@]}"; do
    [ -n "${n:-}" ] && DEVICE="$n" && printf "%s" "$n" > "$DEVFILE" && break
  done
}
[ -z "$DEVICE" ] && pick_tv

# --- Main menu -------------------------------------------------------------------------
while true; do
  say "TV: $DEVICE"
  echo "Pop out the Discord stream (the pop-out button on the stream), then pick its window."
  echo "Tip: you can cover the window with others, just don't minimize it."
  echo

  IDS=(); LABELS=()
  while IFS=$'\t' read -r id label; do
    [ -n "$id" ] && IDS+=("$id") && LABELS+=("$label")
  done < <("$CAP" list)
  # dc-capture exits with 3 when Screen Recording permission is missing.
  if [ ${#IDS[@]} -eq 0 ]; then
    echo "No Discord windows found."
    echo "  - Is Discord open, with the stream popped out?"
    echo "  - Screen Recording: System Settings > Privacy & Security > Screen & System Audio Recording > Terminal on,"
    echo "    then quit and reopen Terminal."
  else
    for i in "${!LABELS[@]}"; do printf "  %d) %s\n" $((i + 1)) "${LABELS[$i]}"; done
  fi
  echo "  r) Rescan    t) Pick a different TV    q) Quit"
  read -r -p "Choose: " c
  case "$c" in
    r|R|"") continue ;;
    t|T) pick_tv; continue ;;
    q|Q) exit 0 ;;
  esac
  if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt ${#IDS[@]} ]; then continue; fi

  WID="${IDS[$((c - 1))]}"
  echo
  echo "  1) Cast to TV"
  echo "  2) Cast to TV, lower delay (1 s segments; may stutter)"
  echo "  3) Preview in Safari on this Mac (checks the capture side, no TV)"
  read -r -p "Choose [1]: " m
  case "${m:-1}" in
    2) MODE=(--device "$DEVICE" --segment 1 --buffer 4) ;;
    3) MODE=(--preview) ;;
    *) MODE=(--device "$DEVICE") ;;
  esac
  say "Running. Press Ctrl+C to stop and come back to this menu."
  trap ':' INT
  $RUN --window "$WID" "${MODE[@]}"
  trap - INT
done
