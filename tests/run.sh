#!/bin/bash
# roam test suite — two simulated Macs (A, B) with their own HOME, one pool folder, one bare remote.
#   tests/run.sh            all tests
#   tests/run.sh resume     only tests whose name contains "resume"
# Needs nothing but what roam needs. Never touches your real pool, projects or ~/.claude.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ONLY=${1:-}
PASS=0 FAIL=0 T=""

if [ -t 1 ]; then G=$'\033[32m' R=$'\033[31m' D=$'\033[2m' N=$'\033[0m'; else G="" R="" D="" N=""; fi

# ---------------------------------------------------------------- world
fresh() {  # a new world: remote with one commit, pool with one project "App", Macs A and B
  [ -n "$T" ] && rm -rf "$T"
  T=$(mktemp -d "${TMPDIR:-/tmp}/roam-test.XXXXXX")
  mkdir -p "$T/pool/macs" "$T/pool/claude" "$T/A/dev" "$T/B/dev"
  git init -q --bare "$T/remote.git"
  git clone -q "$T/remote.git" "$T/seed" 2>/dev/null
  ( cd "$T/seed" && echo "hello" > a.txt && git add a.txt &&
    git -c user.name=t -c user.email=t@t commit -q -m init && git push -q origin HEAD:main 2>/dev/null )
  git -C "$T/remote.git" symbolic-ref HEAD refs/heads/main
  printf 'App  App  %s\n' "$T/remote.git" > "$T/pool/projects.conf"
  printf 'claude_sync = 1\nclaude_history = 1\ninterval_min = 10\nmax_file_mb = 50\n' > "$T/pool/settings"
  git clone -q "$T/remote.git" "$T/A/dev/App" 2>/dev/null
  git clone -q "$T/remote.git" "$T/B/dev/App" 2>/dev/null
}

on() {  # $1 Mac, rest: roam arguments — runs roam as that Mac, output in $OUT, exit status in $RC
  local m=$1; shift
  OUT=$(HOME="$T/$m" ROAM_POOL="$T/pool" ROAM_PROJECTS_DIR="$T/$m/dev" ROAM_MAC="$m" ROAM_HOSTNAME="$m" \
    ROAM_LOCK="$T/$m.lock" ROAM_LOG="$T/$m.log" NO_COLOR=1 "$ROOT/roam" "$@" 2>&1 </dev/null)
  RC=$?
}

claude_dir() { echo "$T/$1/.claude/projects/$(printf '%s' "$T/$1/dev/App" | sed 's#[^A-Za-z0-9]#-#g')"; }

# ---------------------------------------------------------------- assertions
CUR=""
ok()   { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$G" "$N" "$CUR"; }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s — %s\n' "$R" "$N" "$CUR" "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed "s/^/      $D/; s/\$/$N/"; }
check() {  # $1 description of what failed, rest: test command
  local why=$1; shift
  if "$@"; then return 0; fi
  fail "$why"; return 1
}
run() {  # $1 test function
  case $1 in *"$ONLY"*) ;; *) return ;; esac
  CUR=${1#t_}; CUR=$(printf '%s' "$CUR" | tr _ ' ')
  OUT=""
  fresh
  if "$1"; then ok; fi
}

# ---------------------------------------------------------------- tests
t_park_then_resume_carries_uncommitted_and_new_files() {
  echo "changed" > "$T/A/dev/App/a.txt"; echo "new" > "$T/A/dev/App/b.txt"
  on A park;   check "park failed" [ $RC = 0 ] || return 1
  on B resume; check "resume failed" [ $RC = 0 ] || return 1
  check "a.txt not taken over" [ "$(cat "$T/B/dev/App/a.txt")" = changed ] || return 1
  check "b.txt not taken over" [ -f "$T/B/dev/App/b.txt" ]
}

t_parallel_edits_are_not_overwritten() {
  echo "from A" > "$T/A/dev/App/a.txt"; on A park
  echo "from B" > "$T/B/dev/App/a.txt"
  on B resume
  check "resume should report the conflict" [ $RC != 0 ] || return 1
  check "B's edit was overwritten" [ "$(cat "$T/B/dev/App/a.txt")" = "from B" ]
}

t_clean_and_pushed_drops_the_snapshot() {
  echo "x" > "$T/A/dev/App/a.txt"; on A park
  check "snapshot missing after park" git -C "$T/remote.git" rev-parse -q --verify refs/roam/A >/dev/null || return 1
  git -C "$T/A/dev/App" checkout -q -- a.txt
  on A park
  check "snapshot still on the remote" [ -z "$(git -C "$T/remote.git" rev-parse -q --verify refs/roam/A)" ]
}

t_status_lists_the_project() {
  on A status
  check "status failed" [ $RC = 0 ] || return 1
  case $OUT in *App*) ;; *) fail "project App not in the dashboard"; return 1 ;; esac
}

t_claude_transcripts_travel_through_the_pool() {
  mkdir -p "$(claude_dir A)"; echo '{"type":"user"}' > "$(claude_dir A)/s1.jsonl"
  on A park; on B resume
  check "transcript did not arrive on B" [ "$(cat "$(claude_dir B)/s1.jsonl" 2>/dev/null)" = '{"type":"user"}' ]
}

t_placeholder_transcript_never_overwrites_the_pool_copy() {
  mkdir -p "$(claude_dir A)" "$(claude_dir B)"
  echo '{"type":"user","good":1}' > "$(claude_dir A)/s1.jsonl"
  on A park
  # B: same name, same size, newer — but only NUL bytes
  head -c "$(stat -f %z "$(claude_dir A)/s1.jsonl")" /dev/zero > "$(claude_dir B)/s1.jsonl"
  touch -t 203001010000 "$(claude_dir B)/s1.jsonl"
  on B park
  check "pool copy was overwritten by the placeholder" grep -q good "$T/pool/claude/App/s1.jsonl"
}

t_resume_repairs_a_placeholder_transcript() {
  mkdir -p "$(claude_dir A)" "$(claude_dir B)"
  echo '{"type":"user","good":1}' > "$(claude_dir A)/s1.jsonl"
  on A park
  # B: the sync app left the same file with the same size and date, but empty
  head -c "$(stat -f %z "$(claude_dir A)/s1.jsonl")" /dev/zero > "$(claude_dir B)/s1.jsonl"
  touch -r "$T/pool/claude/App/s1.jsonl" "$(claude_dir B)/s1.jsonl"
  on B resume
  check "placeholder was not repaired" grep -q good "$(claude_dir B)/s1.jsonl"
}

t_scripts_are_bash32_clean() {
  local hits
  hits=$(grep -n -E 'declare -A|mapfile|readarray|\$\{[a-zA-Z_]+(,,|\^\^)\}|local -n|coproc|\|&|&>>' "$ROOT/roam" "$ROOT"/lib/*.sh)
  check "bash 4 features: $hits" [ -z "$hits" ] || return 1
  for f in "$ROOT/roam" "$ROOT"/lib/*.sh; do /bin/bash -n "$f" || { fail "syntax error in $f"; return 1; }; done
}

# ---------------------------------------------------------------- run
printf '\n  roam tests %s(%s)%s\n\n' "$D" "$(/bin/bash -c 'echo $BASH_VERSION')" "$N"
for t in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do run "$t"; done
[ -n "$T" ] && rm -rf "$T"
printf '\n  %d passed' "$PASS"; [ $FAIL -gt 0 ] && printf ', %s%d failed%s' "$R" "$FAIL" "$N"; echo; echo
[ $FAIL -eq 0 ]
