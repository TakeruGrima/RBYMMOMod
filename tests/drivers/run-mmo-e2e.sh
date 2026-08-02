#!/usr/bin/env bash
#
# End-to-end test for in-game hosting: two real LOVE instances, two real
# windows, a real socket between them.
#
# This is the half of the mod the headless suites structurally cannot reach.
# tests/rby_mmo_test.lua pins the protocol logic with fake peers; nothing in
# it ever binds a socket, renders a menu, or spawns an avatar. This does.
#
#   Run from the Gen1Recomp checkout root, with this mod linked into mods/:
#
#     bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
#
# Requires a ROM to have been imported already (scripts/setup.sh --rom ...);
# the engine cannot boot without data/generated/.
#
# Two windows will open and drive themselves. Leave them alone until it
# finishes -- clicking into them steals the input the drivers are queueing.

set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 1

MOD_DIR="mods/rby_mmo"
DRIVERS="$MOD_DIR/tests/drivers"
ADDR_FILE="${MMO_ADDR_FILE:-/tmp/rby_mmo_addr.txt}"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_shots}"
LIMIT="${MMO_LIMIT:-2}"
HOST_ID="mmohost-$$"
GUEST_ID="mmoguest-$$"
HOST_LOG="/tmp/rby_mmo_host_$$.log"
GUEST_LOG="/tmp/rby_mmo_guest_$$.log"
TIMEOUT="${MMO_TIMEOUT:-420}"

# ------------------------------------------------------------------ preflight

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
[ -d "$MOD_DIR" ] || fail "$MOD_DIR is missing -- symlink the mod into mods/"
[ -d data/generated ] || fail "no data/generated -- import a ROM first:
     scripts/setup.sh --rom \"/path/to/Poke Red.gb\""

SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_sync}"
rm -f "$ADDR_FILE" "$HOST_LOG" "$GUEST_LOG"
# stale phase markers would let a rerun skip straight past every barrier
rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

# The mod ships experimental, so the loader leaves it disabled unless
# options.mods has an entry for it. Each instance gets its own LOVE identity
# (so the two do not fight over one save file), which means each needs its
# own options.lua -- and options are read at boot, before a driver can run.
#
# The save directory is asked of LOVE rather than assumed. It is
# ~/Library/Application Support/LOVE/<identity> on macOS but
# ~/.local/share/love/<identity> on Linux, and guessing it wrong fails in
# the most confusing way available: the game boots fine, the mod is simply
# absent, and every later assertion blames the wrong thing.
# Pin which other mods are on for this run, as space-separated ids:
#
#   MMO_WITH_MODS="DRAMATIC_SHAPE"     bash .../run-mmo-e2e.sh
#   MMO_WITHOUT_MODS="DRAMATIC_SHAPE"  bash .../run-mmo-e2e.sh
#
# Both are needed, and for different reasons. An *experimental* mod is off
# unless something enables it, so coexistence needs MMO_WITH_MODS. An
# ordinary one is on merely by being in mods/ -- a missing options entry
# means enabled -- so proving this mod still works on the vanilla renderer
# needs MMO_WITHOUT_MODS. Relying on what happens to be installed is how a
# run that was supposed to be "without" quietly became "with": every
# earlier voxel run had the pipeline on, including the ones meant to be
# the control.
EXTRA_MODS=""
for id in ${MMO_WITH_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = true"
done
for id in ${MMO_WITHOUT_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = false"
done
echo "  other mods: on=[${MMO_WITH_MODS:-none}] off=[${MMO_WITHOUT_MODS:-none}]"

PROBE="$(mktemp -d)"
cat > "$PROBE/conf.lua" <<'PROBE_CONF'
function love.conf(t)
  t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
  t.window = false
end
PROBE_CONF
cat > "$PROBE/main.lua" <<'PROBE_MAIN'
function love.load()
  print("SAVEDIR=" .. tostring(love.filesystem.getSaveDirectory()))
  love.event.quit()
end
PROBE_MAIN

save_dir_for() {
  POKEPORT_IDENTITY="$1" love "$PROBE" 2>/dev/null \
    | sed -n 's/^SAVEDIR=//p' | head -1
}

enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true%s } }\n' "$EXTRA_MODS" \
    > "$dir/options.lua"
  echo "$dir"
}
HOST_SAVE="$(enable_mod_for "$HOST_ID")"
GUEST_SAVE="$(enable_mod_for "$GUEST_ID")"
rm -rf "$PROBE"
echo "  enabled the mod in $(dirname "$HOST_SAVE")/{$HOST_ID,$GUEST_ID}"

cleanup() {
  [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null
  [ -n "${GUEST_PID:-}" ] && kill "$GUEST_PID" 2>/dev/null
  # the throwaway identities, resolved by the probe above
  [ -n "${HOST_SAVE:-}" ] && rm -rf "$HOST_SAVE"
  [ -n "${GUEST_SAVE:-}" ] && rm -rf "$GUEST_SAVE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------- run

echo "  host limit: $LIMIT   shots: $SHOT_DIR"
echo "  starting host..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" MMO_LIMIT="$LIMIT" MMO_SYNC_DIR="$SYNC_DIR" \
  POKEPORT_IDENTITY="$HOST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_host.lua" \
  love . >"$HOST_LOG" 2>&1 &
HOST_PID=$!

# wait for the listener rather than sleeping a guessed interval
for _ in $(seq 1 "$TIMEOUT"); do
  [ -f "$ADDR_FILE" ] && break
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 1
done
[ -f "$ADDR_FILE" ] || {
  echo "  !! the host never started listening. Its log:" >&2
  tail -30 "$HOST_LOG" >&2
  exit 1
}
echo "  host is up at $(cat "$ADDR_FILE")"

echo "  starting guest..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" \
  POKEPORT_IDENTITY="$GUEST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_join.lua" \
  love . >"$GUEST_LOG" 2>&1 &
GUEST_PID=$!

# Wait for BOTH sides to print DONE. Breaking as soon as the guest process
# ended killed the host mid-run: the guest finishes its script first by
# design, so its exit says nothing about whether the host is done.
for _ in $(seq 1 "$TIMEOUT"); do
  if grep -q "DONE" "$HOST_LOG" 2>/dev/null \
     && grep -q "DONE" "$GUEST_LOG" 2>/dev/null; then
    break
  fi
  # only give up early if neither side is still alive to make progress
  if ! kill -0 "$HOST_PID" 2>/dev/null && ! kill -0 "$GUEST_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

kill "$HOST_PID" "$GUEST_PID" 2>/dev/null
wait 2>/dev/null

# ------------------------------------------------------------------- verdict

echo
echo "  ---- host ----"
grep -E 'MMO_HOST:|TIMEOUT' "$HOST_LOG" | sed 's/^/  /'
echo "  ---- guest ----"
grep -E 'MMO_JOIN:|TIMEOUT' "$GUEST_LOG" | sed 's/^/  /'

# `grep -c` exits 1 on zero matches, so a `|| echo 0` appends a SECOND zero
# and the variable becomes "0\n0" -- which makes every [ -gt ] below fail as
# a non-integer and silently fall through to the success line. A harness
# that reports a false pass is worse than no harness, so count this way.
count() { grep -c "$1" "$2" 2>/dev/null | head -1 || true; }

# `.*` between the tag and the word on purpose: U.log prints its arguments
# TAB-separated, so a pattern written with a space matches nothing at all --
# which is how run 1 reported a false pass (FAIL lines uncounted) and run 2
# a false incomplete (DONE uncounted). Never assume the separator.
host_fail=$(count 'MMO_HOST:.*FAIL' "$HOST_LOG"); host_fail=${host_fail:-0}
guest_fail=$(count 'MMO_JOIN:.*FAIL' "$GUEST_LOG"); guest_fail=${guest_fail:-0}
host_done=$(count 'MMO_HOST:.*DONE' "$HOST_LOG"); host_done=${host_done:-0}
guest_done=$(count 'MMO_JOIN:.*DONE' "$GUEST_LOG"); guest_done=${guest_done:-0}

dump_logs() {
  echo
  echo "  ---- host log (tail) ----"
  tail -25 "$HOST_LOG" | sed 's/^/  /'
  echo "  ---- guest log (tail) ----"
  tail -25 "$GUEST_LOG" | sed 's/^/  /'
  echo
  echo "  full logs kept: $HOST_LOG  $GUEST_LOG"
}

echo
if [ "$host_done" -ne 1 ] || [ "$guest_done" -ne 1 ]; then
  echo "  RESULT: incomplete -- one side never reached DONE."
  dump_logs
  exit 1
fi
if [ "$host_fail" -ne 0 ] || [ "$guest_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $host_fail host + $guest_fail guest failure(s)."
  dump_logs
  exit 1
fi
echo "  RESULT: end-to-end passed. Screenshots in $SHOT_DIR"
rm -f "$HOST_LOG" "$GUEST_LOG"
