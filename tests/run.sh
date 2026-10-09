#!/bin/bash
# roam test suite — two simulated Macs (A, B) with their own HOME, one pool folder, one bare remote.
#   tests/run.sh            all tests
#   tests/run.sh resume     only tests whose name contains "resume"
# Needs nothing but what roam needs. Never touches your real pool, projects or ~/.claude.
set -u
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS   # the caller's git overrides (packaging/release.sh) stay out of the simulated Macs
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ONLY=${1:-}
PASS=0 FAIL=0 T="" P=""

if [ -t 1 ]; then G=$'\033[32m' R=$'\033[31m' D=$'\033[2m' N=$'\033[0m'; else G="" R="" D="" N=""; fi

# ---------------------------------------------------------------- world
fresh() {  # a new world: remote with one commit, pool with one project "App", Macs A and B
  [ -n "$T" ] && rm -rf "$T"
  T=$(mktemp -d "${TMPDIR:-/tmp}/roam-test.XXXXXX")
  P="$T/Cloud Drive/pool"   # a space, like Mobile Documents, My Drive or "OneDrive - Company"
  mkdir -p "$P/macs" "$P/claude" "$T/A/dev" "$T/B/dev"
  git init -q --bare "$T/remote.git"
  git clone -q "$T/remote.git" "$T/seed" 2>/dev/null
  ( cd "$T/seed" && echo "hello" > a.txt && git add a.txt &&
    git -c user.name=t -c user.email=t@t commit -q -m init && git push -q origin HEAD:main 2>/dev/null )
  git -C "$T/remote.git" symbolic-ref HEAD refs/heads/main
  printf 'App  App  %s\n' "$T/remote.git" > "$P/projects.conf"
  printf 'claude_sync = 1\nclaude_history = 1\ninterval_min = 10\nmax_file_mb = 50\n' > "$P/settings"
  git clone -q "$T/remote.git" "$T/A/dev/App" 2>/dev/null
  git clone -q "$T/remote.git" "$T/B/dev/App" 2>/dev/null
}

on() {  # $1 Mac, rest: roam arguments — runs roam as that Mac, output in $OUT, exit status in $RC
  local m=$1; shift
  OUT=$(HOME="$T/$m" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/$m/dev" ROAM_MAC="$m" ROAM_HOSTNAME="$m" \
    ROAM_LOCK="$T/$m.lock" ROAM_LOG="$T/$m.log" ROAM_NO_NOTIFY=1 NO_COLOR=1 "$ROOT/roam" "$@" 2>&1 </dev/null)
  RC=$?
}

second_remote() {  # $1 name → path of another bare remote with one commit
  git init -q --bare "$T/$1.git"
  git -C "$T/seed" push -q "$T/$1.git" HEAD:main 2>/dev/null
  git -C "$T/$1.git" symbolic-ref HEAD refs/heads/main
  echo "$T/$1.git"
}

have_age() { command -v age >/dev/null || [ -x /opt/homebrew/bin/age ]; }
claude_dir() { echo "$T/$1/.claude/projects/$(printf '%s' "$T/$1/dev/App" | sed 's#[^A-Za-z0-9]#-#g')"; }

# ---------------------------------------------------------------- assertions
CUR=""
ok()   { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$G" "$N" "$CUR"; }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s — %s\n' "$R" "$N" "$CUR" "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed "s/^/      $D/; s/\$/$N/"; }
not() { ! "$@"; }
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
  check "B's edit was overwritten" grep -qx "from B" "$T/B/dev/App/a.txt" || return 1   # inside the conflict markers
  on B undo App
  check "undo didn't bring back B's file" [ "$(cat "$T/B/dev/App/a.txt")" = "from B" ]
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
  check "pool copy was overwritten by the placeholder" grep -q good "$P/claude/App/s1.jsonl"
}

t_resume_repairs_a_placeholder_transcript() {
  mkdir -p "$(claude_dir A)" "$(claude_dir B)"
  echo '{"type":"user","good":1}' > "$(claude_dir A)/s1.jsonl"
  on A park
  # B: the sync app left the same file with the same size and date, but empty
  head -c "$(stat -f %z "$(claude_dir A)/s1.jsonl")" /dev/zero > "$(claude_dir B)/s1.jsonl"
  touch -r "$P/claude/App/s1.jsonl" "$(claude_dir B)/s1.jsonl"
  on B resume
  check "placeholder was not repaired" grep -q good "$(claude_dir B)/s1.jsonl"
}

t_placeholder_memory_never_overwrites_the_pool_copy() {
  sed -i '' 's/^claude_history = 1/claude_history = 0/' "$P/settings"   # memory only: the filter must not let it through
  mkdir -p "$(claude_dir A)/memory" "$(claude_dir B)/memory"
  echo 'good note' > "$(claude_dir A)/memory/m.md"
  on A park
  head -c "$(stat -f %z "$(claude_dir A)/memory/m.md")" /dev/zero > "$(claude_dir B)/memory/m.md"
  touch -t 203001010000 "$(claude_dir B)/memory/m.md"
  on B park
  check "pool memory was overwritten by the placeholder" grep -q good "$P/claude/App/memory/m.md"
}

t_resume_repairs_placeholder_memory() {
  mkdir -p "$(claude_dir A)/memory" "$(claude_dir B)/memory"
  echo 'good note' > "$(claude_dir A)/memory/m.md"
  on A park
  head -c "$(stat -f %z "$(claude_dir A)/memory/m.md")" /dev/zero > "$(claude_dir B)/memory/m.md"
  touch -r "$P/claude/App/memory/m.md" "$(claude_dir B)/memory/m.md"
  on B resume
  check "placeholder memory was not repaired" grep -q good "$(claude_dir B)/memory/m.md"
}

t_placeholder_without_disk_blocks_is_caught_too() {
  local pf
  mkdir -p "$(claude_dir A)/memory"
  echo 'good note' > "$(claude_dir A)/memory/m.md"
  on A park
  # the pool copy turns into a sparse file: a size, no blocks, reads as NUL bytes
  pf="$P/claude/App/memory/m.md"
  rm "$pf"; dd if=/dev/zero of="$pf" bs=1 count=0 seek=10 2>/dev/null
  touch -t 203001010000 "$pf"
  on A resume
  check "local memory was overwritten by the sparse pool copy" grep -q good "$(claude_dir A)/memory/m.md" || return 1
  on A park
  check "park did not repair the pool copy" grep -q good "$pf"
}

t_binary_files_are_no_placeholders() {
  mkdir -p "$(claude_dir A)/s1/tool-results"
  printf '\377\330\377\340 jpeg' > "$(claude_dir A)/s1/tool-results/shot.jpg"      # not valid UTF-8
  printf '%511s\303\244 rest' '' | tr ' ' x > "$(claude_dir A)/s2.jsonl"                 # ä cut at byte 512
  LC_ALL=de_DE.UTF-8 on A park
  check "binary file did not travel" [ -f "$P/claude/App/s1/tool-results/shot.jpg" ] || return 1
  check "transcript with a cut-off umlaut did not travel" [ -f "$P/claude/App/s2.jsonl" ]
}

t_a_hanging_pool_ends_the_run_with_a_message() {
  local t0
  rm "$P/settings"; mkfifo "$P/settings"            # reading it blocks, like a stuck sync app
  t0=$(date +%s)
  ROAM_POOL_TIMEOUT=2 on A park
  check "park waited instead of giving up" [ $(( $(date +%s) - t0 )) -lt 10 ] || return 1
  check "park didn't fail" [ $RC != 0 ] || return 1
  case $OUT in *"didn't answer"*) ;; *) fail "no message about the pool"; return 1 ;; esac
  ROAM_POOL_TIMEOUT=2 on A auto
  check "auto should end quietly" [ $RC = 0 ] || return 1
  check "auto didn't log it" grep -q "pool unreachable" "$T/A.log"
}

t_a_hanging_claude_sync_is_reported() {
  mkdir -p "$T/bin" "$(claude_dir A)/memory"; echo note > "$(claude_dir A)/memory/m.md"
  printf '#!/bin/sh\nsleep 30\n' > "$T/bin/rsync"; chmod +x "$T/bin/rsync"
  PATH="$T/bin:$PATH" ROAM_SYNC_TIMEOUT=2 on A park
  case $OUT in *"Claude Code files: the pool didn't answer"*) ;; *) fail "hanging Claude sync not reported"; return 1 ;; esac
}

t_doctor_warns_about_online_only_pool_files() {
  dd if=/dev/zero of="$P/claude/cloud.md" bs=1 count=0 seek=100 2>/dev/null   # a size, no blocks
  [ "$(stat -f %b "$P/claude/cloud.md")" = 0 ] || { ok; return; }              # file system without sparse files
  on A doctor
  case $OUT in *"online only on this Mac"*) ;; *) fail "no warning about online-only files"; return 1 ;; esac
}

t_status_file_is_only_rewritten_when_something_changed() {
  local f="$P/macs/A.txt" seen
  on A park
  check "no status file" [ -f "$f" ] || return 1
  sed -i '' 's/^seen=\([0-9]*\)$/seen=\1/' "$f"; seen=$(grep '^seen=' "$f")
  sleep 1; on A park
  check "unchanged status was rewritten" [ "$(grep '^seen=' "$f")" = "$seen" ] || return 1
  sed -i '' 's/^seen=.*/seen=1/' "$f"                              # heartbeat long overdue
  on A park
  check "overdue heartbeat was not refreshed" not grep -qx 'seen=1' "$f" || return 1
  echo change >> "$T/A/dev/App/a.txt"
  on A park
  check "a changed project did not update the status" grep -q "^project=App	main	1	" "$f"
}

t_park_skips_push_hooks() {
  printf '#!/bin/sh\nexit 1\n' > "$T/A/dev/App/.git/hooks/pre-push"; chmod +x "$T/A/dev/App/.git/hooks/pre-push"
  echo wip >> "$T/A/dev/App/a.txt"
  on A park
  check "a pre-push hook blocked the park" git -C "$T/remote.git" rev-parse -q --verify refs/roam/A >/dev/null
}

t_a_stale_index_lock_stops_park_and_resume() {
  echo wip >> "$T/A/dev/App/a.txt"
  touch -t 202001010000 "$T/A/dev/App/.git/index.lock"
  on A park
  case $OUT in *index.lock*) ;; *) fail "park didn't mention index.lock"; return 1 ;; esac
  check "parked despite the lock" not git -C "$T/remote.git" rev-parse -q --verify refs/roam/A || return 1
  on A resume
  case $OUT in *index.lock*) ;; *) fail "resume didn't mention index.lock"; return 1 ;; esac
}

t_resume_keeps_a_backup_and_undo_restores_it() {
  echo "from A" > "$T/A/dev/App/a.txt"; echo "new on A" > "$T/A/dev/App/new.txt"; on A park
  on B resume
  check "resume did not take A's work" grep -q "from A" "$T/B/dev/App/a.txt" || return 1
  check "no backup ref" git -C "$T/B/dev/App" rev-parse -q --verify refs/roam-backup >/dev/null || return 1
  on B undo App
  check "undo failed" [ $RC = 0 ] || return 1
  check "undo left A's change" grep -qx hello "$T/B/dev/App/a.txt" || return 1
  check "undo left A's new file" [ ! -e "$T/B/dev/App/new.txt" ] || return 1
  on B undo App
  check "undoing the undo failed" grep -q "from A" "$T/B/dev/App/a.txt" || return 1
  check "undoing the undo lost the new file" [ -f "$T/B/dev/App/new.txt" ]
}

t_a_continued_transcript_is_never_cut_short() {
  mkdir -p "$(claude_dir A)"
  printf '{"n":1}\n{"n":2}\n' > "$(claude_dir A)/s1.jsonl"
  on A park; on B resume
  printf '{"n":3}\n' >> "$(claude_dir B)/s1.jsonl"; on B park
  touch -t 203001010000 "$(claude_dir A)/s1.jsonl"            # A's shorter copy looks newer
  on A park
  check "the pool lost line 3" grep -q '"n":3' "$P/claude/App/s1.jsonl"
}

t_a_session_continued_on_two_macs_is_merged() {
  mkdir -p "$(claude_dir A)"
  printf '{"n":1}\n{"n":2}\n' > "$(claude_dir A)/s1.jsonl"
  on A park; on B resume
  printf '{"a":3}\n' >> "$(claude_dir A)/s1.jsonl"; on A park
  printf '{"b":3}\n' >> "$(claude_dir B)/s1.jsonl"
  touch -t 203001010000 "$(claude_dir B)/s1.jsonl"            # same size as A's: the time must tell them apart
  on B park
  check "pool lost A's line" grep -q '"a":3' "$P/claude/App/s1.jsonl" || return 1
  check "pool lost B's line" grep -q '"b":3' "$P/claude/App/s1.jsonl" || return 1
  check "lines doubled" [ "$(grep -c '"n":1' "$P/claude/App/s1.jsonl")" = 1 ] || return 1
  on A resume
  check "A didn't get B's line" grep -q '"b":3' "$(claude_dir A)/s1.jsonl"
}

t_parallel_edits_are_merged() {
  printf 'one\ntwo\nthree\n' > "$T/A/dev/App/b.txt"; ( cd "$T/A/dev/App" && git add b.txt && git -c user.name=t -c user.email=t@t commit -qm b && git push -q origin HEAD:main 2>/dev/null )
  on B resume
  printf 'ONE\ntwo\nthree\n' > "$T/A/dev/App/b.txt"; on A park
  printf 'one\ntwo\nTHREE\n' > "$T/B/dev/App/b.txt"; echo "B new" > "$T/B/dev/App/only-b.txt"
  on B resume
  check "resume failed" [ $RC = 0 ] || return 1
  check "A's edit missing" grep -qx ONE "$T/B/dev/App/b.txt" || return 1
  check "B's edit missing" grep -qx THREE "$T/B/dev/App/b.txt" || return 1
  check "B's new file missing" [ -f "$T/B/dev/App/only-b.txt" ] || return 1
  on B park
  on A resume
  check "the merge didn't reach A" grep -qx THREE "$T/A/dev/App/b.txt"
}

t_merge_conflicts_block_park_until_resolved() {
  echo "A side" > "$T/A/dev/App/a.txt"; on A park
  echo "B side" > "$T/B/dev/App/a.txt"
  on B resume
  case $OUT in *conflict*) ;; *) fail "no conflict reported"; return 1 ;; esac
  check "no conflict markers" grep -q '^<<<<<<< ' "$T/B/dev/App/a.txt" || return 1
  on B park
  case $OUT in *"not resolved"*) ;; *) fail "park took the conflict markers along"; return 1 ;; esac
  echo "both" > "$T/B/dev/App/a.txt"
  on B park
  check "park after resolving failed" [ $RC = 0 ] || return 1
  on A resume
  check "the resolution didn't reach A" grep -qx both "$T/A/dev/App/a.txt"
}

secrets_world() {  # carry_secrets on, .env ignored on both Macs
  echo "carry_secrets = 1" >> "$P/settings"
  echo .env >> "$T/A/dev/App/.git/info/exclude"; echo .env >> "$T/B/dev/App/.git/info/exclude"
}

t_secrets_travel_encrypted() {
  have_age || { ok; return; }
  secrets_world
  on B park                                   # B gets a key and publishes it
  echo "KEY=one" > "$T/A/dev/App/.env"
  on A park
  check "no bundle in the pool" [ -f "$P/secrets/App/A.age" ] || return 1
  check "the bundle isn't encrypted" not grep -q "KEY=one" "$P/secrets/App/A.age" || return 1
  on B resume
  check ".env didn't arrive on B" grep -qx "KEY=one" "$T/B/dev/App/.env" || return 1
  echo "KEY=two" > "$T/A/dev/App/.env"; on A park
  on B resume
  check "an update didn't replace B's unchanged copy" grep -qx "KEY=two" "$T/B/dev/App/.env"
}

t_secrets_changed_on_both_macs_keep_yours() {
  have_age || { ok; return; }
  secrets_world
  on B park
  echo "KEY=one" > "$T/A/dev/App/.env"; on A park; on B resume
  echo "KEY=A" > "$T/A/dev/App/.env"; on A park
  echo "KEY=B" > "$T/B/dev/App/.env"
  on B resume
  check "B's own change was overwritten" grep -qx "KEY=B" "$T/B/dev/App/.env" || return 1
  check "A's version isn't next to it" grep -qx "KEY=A" "$T/B/dev/App/.env.from-A" || return 1
  case $OUT in *"changed here and on"*) ;; *) fail "conflict not reported"; return 1 ;; esac
}

t_secrets_stay_home_without_the_setting() {
  echo .env >> "$T/A/dev/App/.git/info/exclude"; echo "KEY=one" > "$T/A/dev/App/.env"
  on A park
  check "secrets travelled although carry_secrets is off" [ ! -e "$P/secrets" ]
}

t_secrets_switched_on_per_project() {
  have_age || { ok; return; }
  echo .env >> "$T/A/dev/App/.git/info/exclude"; echo .env >> "$T/B/dev/App/.git/info/exclude"
  sed -i '' 's#^\(App .*\)$#\1 secrets=1#' "$P/projects.conf"
  on B park
  echo "KEY=one" > "$T/A/dev/App/.env"; on A park; on B resume
  check ".env didn't travel with secrets=1" grep -qx "KEY=one" "$T/B/dev/App/.env" || return 1
  check "projects.conf lost its line" grep -q "secrets=1" "$P/projects.conf"
}

t_pool_set_extra_keeps_the_other_extras() {
  sed -i '' 's#^\(App .*\)$#\1 local=Local.xcconfig#' "$P/projects.conf"
  ( POOL="$P" PROJECTS_CONF="$P/projects.conf"; . "$ROOT/lib/pool.sh"; . "$ROOT/lib/secrets.sh"
    pool_set_extra App secrets 1; pool_set_extra App secrets 1; pool_set_extra App secrets "" ; pool_set_extra App secrets 1 )
  check "secrets=1 not set exactly once" [ "$(grep -o 'secrets=1' "$P/projects.conf" | wc -l | tr -d ' ')" = 1 ] || return 1
  check "local= got lost" grep -q 'local=Local.xcconfig' "$P/projects.conf"
}

t_app_shows_where_work_is_going_on() {
  echo "wip" >> "$T/A/dev/App/a.txt"; on A park           # writes A's status with the open change
  OUT=$(HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
    ROAM_TUI_SNAPSHOT=dash ROAM_COLS=100 ROAM_ROWS=30 LC_ALL=en_US.UTF-8 "$ROOT/roam" 2>&1 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
  case $OUT in *"Now"*) ;; *) fail "no Now panel"; return 1 ;; esac
  printf '%s\n' "$OUT" | grep -q -E '◐ .+ +App +●1 changed' || { fail "A's open change in App isn't listed"; return 1; }
}

answer_requests() {  # $1 Mac: plays its background run as soon as a request for it lands in the pool
  local i
  for i in $(seq 1 40); do
    ls "$P/requests/$1"/*.req >/dev/null 2>&1 && { on "$1" auto; return; }
    sleep 0.5
  done
}

t_sync_brings_the_other_mac_along() {
  on B status                                         # B announces itself: online, roam 1.8+
  echo "from A" > "$T/A/dev/App/a.txt"; echo "new" > "$T/A/dev/App/new.txt"
  answer_requests B &
  ROAM_SYNC_WAIT=30 on A sync App
  wait
  check "sync failed" [ $RC = 0 ] || return 1
  check "B didn't get A's change" grep -qx "from A" "$T/B/dev/App/a.txt" || return 1
  check "B didn't get A's new file" [ -f "$T/B/dev/App/new.txt" ] || return 1
  case $OUT in *"in sync"*) ;; *) fail "not reported as in sync"; return 1 ;; esac
  on A status
  case $OUT in *"≡ in sync"*) ;; *) fail "status doesn't mark App as in sync"; return 1 ;; esac
}


t_a_request_that_arrives_during_the_run_is_answered_too() {
  # launchd doesn't start the run again for a request that lands while it runs: the run itself looks again
  local req="$P/requests/B" h="$T/B/dev/App/.git/hooks/reference-transaction"
  mkdir -p "$req"
  printf 'from=A\nproject=App\naction=sync\ntime=%s\n' "$(date +%s)" > "$req/1-A-first.req"
  printf '#!/bin/sh\n[ -f "%s" ] || { touch "%s"; printf "from=A\\nproject=App\\naction=sync\\ntime=%%s\\n" "$(date +%%s)" > "%s/2-A-second.req"; }\nexit 0\n' \
    "$T/hook.done" "$T/hook.done" "$req" > "$h"; chmod +x "$h"
  echo "from B" > "$T/B/dev/App/a.txt"
  on B auto
  check "the hook didn't run — the test proves nothing" [ -f "$T/hook.done" ] || return 1
  check "the first request wasn't answered" [ -f "$P/answers/A/1-A-first.ans" ] || return 1
  check "the request that came during the run waits for the next one" [ -f "$P/answers/A/2-A-second.ans" ] || return 1
  check "a request is left" not ls "$req"/*.req
}
t_sync_merges_work_from_both_macs() {
  on B status
  printf 'one\ntwo\nthree\n' > "$T/A/dev/App/b.txt"; ( cd "$T/A/dev/App" && git add b.txt && git -c user.name=t -c user.email=t@t commit -qm b && git push -q origin HEAD:main 2>/dev/null )
  on B resume
  printf 'ONE\ntwo\nthree\n' > "$T/A/dev/App/b.txt"
  printf 'one\ntwo\nTHREE\n' > "$T/B/dev/App/b.txt"
  answer_requests B &
  ROAM_SYNC_WAIT=30 on A sync App
  wait
  check "A lacks B's edit" grep -qx THREE "$T/A/dev/App/b.txt" || return 1
  check "B lacks A's edit" grep -qx ONE "$T/B/dev/App/b.txt" || return 1
  case $OUT in *"in sync"*) ;; *) fail "not in sync after merging"; return 1 ;; esac
}

t_projects_that_differ_are_not_in_sync() {
  on B status
  echo "only A" > "$T/A/dev/App/a.txt"
  on A status
  case $OUT in *"≠"*) ;; *) fail "a difference isn't marked"; return 1 ;; esac
}

t_an_old_request_is_dropped() {
  mkdir -p "$P/requests/B"
  printf 'from=A\nproject=App\naction=sync\ntime=1\n' > "$P/requests/B/old.req"
  echo "from A" > "$T/A/dev/App/a.txt"; on A park
  on B auto
  check "the request is still there" [ ! -f "$P/requests/B/old.req" ] || return 1
  check "an expired request was answered" [ ! -f "$P/answers/A/old.ans" ] || return 1
  check "an expired request touched B's files" grep -qx hello "$T/B/dev/App/a.txt"
}

t_scripts_are_bash32_clean() {
  local hits
  hits=$(grep -n -E 'declare -A|mapfile|readarray|\$\{[a-zA-Z_]+(,,|\^\^)\}|local -n|coproc|\|&|&>>' "$ROOT/roam" "$ROOT"/lib/*.sh)
  check "bash 4 features: $hits" [ -z "$hits" ] || return 1
  # bash 3.2 reads the first byte of "…" or "╯" as part of a name: \$name… must be \${name}…
  hits=$(LC_ALL=C grep -n -E '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' "$ROOT/roam" "$ROOT"/lib/*.sh)
  check "unbraced variable before a non-ASCII character: $hits" [ -z "$hits" ] || return 1
  for f in "$ROOT/roam" "$ROOT"/lib/*.sh; do /bin/bash -n "$f" || { fail "syntax error in $f"; return 1; }; done
}

t_clone_failure_says_why() {
  rm -rf "$T/B/dev/App"
  printf 'App  App  %s\n' "$T/does-not-exist.git" > "$P/projects.conf"
  on B resume
  case $OUT in *"clone failed: "?*) ;; *) fail "no reason given"; return 1 ;; esac
}

t_pool_keeps_ssh_addresses() {
  local f
  f=$(/bin/bash -c ". '$ROOT/lib/doctor.sh'; ssh_remote https://github.com/me/app; echo; ssh_remote https://github.com/me/app.git/; echo
    ssh_remote https://user@gitlab.com/g/x.git; echo; ssh_remote git@github.com:me/app.git; echo; ssh_remote https://example.com/a/b; echo
    https_remote git@github.com:me/app.git")
  check "conversions wrong: $f" [ "$f" = "git@github.com:me/app.git
git@github.com:me/app.git
git@gitlab.com:g/x.git
git@github.com:me/app.git
https://example.com/a/b
https://github.com/me/app.git" ]
}

t_clone_uses_ssh_and_fixes_an_https_pool_entry() {
  # this "Mac" reaches the repo only over SSH: git maps that address to the test remote, HTTPS goes nowhere
  printf '[url "%s"]\n\tinsteadOf = git@github.com:me/app.git\n' "$T/remote.git" > "$T/B/.gitconfig"
  printf 'App  App  https://github.com/me/app\n' > "$P/projects.conf"
  rm -rf "$T/B/dev/App"
  on B resume
  check "not cloned" [ -d "$T/B/dev/App/.git" ] || return 1
  check "pool entry still HTTPS" grep -q 'git@github.com:me/app.git' "$P/projects.conf"
}

t_clone_falls_back_to_https_where_ssh_has_no_access() {
  # the other way round: only HTTPS gets in (like a Mac whose SSH key belongs to another account)
  printf '[url "%s"]\n\tinsteadOf = https://github.com/me/app.git\n' "$T/remote.git" > "$T/B/.gitconfig"
  printf 'App  App  git@github.com:me/app.git\n' > "$P/projects.conf"
  rm -rf "$T/B/dev/App"
  on B resume
  check "not cloned over HTTPS" [ -d "$T/B/dev/App/.git" ] || return 1
  case $OUT in *"over HTTPS"*) ;; *) fail "no note that HTTPS was used"; return 1 ;; esac
  check "pool entry changed" grep -q 'git@github.com:me/app.git' "$P/projects.conf"
}

t_park_falls_back_to_https_where_ssh_has_no_access() {
  # the SSH key on this Mac belongs to another account: SSH fails, the same repo over HTTPS gets in
  printf '[url "%s"]\n\tinsteadOf = https://github.com/me/app.git\n' "$T/remote.git" > "$T/A/.gitconfig"
  git -C "$T/A/dev/App" remote set-url origin git@github.com:me/app.git
  echo wip > "$T/A/dev/App/new.txt"
  GIT_SSH_COMMAND=false on A park
  check "not parked over HTTPS" git -C "$T/remote.git" rev-parse -q --verify refs/roam/A >/dev/null
}

t_park_names_the_reason_a_push_failed() {
  git -C "$T/A/dev/App" remote set-url origin git@github.com:me/app.git
  printf '[url "%s"]\n\tinsteadOf = https://github.com/me/app.git\n' "$T/nowhere.git" > "$T/A/.gitconfig"
  echo wip > "$T/A/dev/App/new.txt"
  GIT_SSH_COMMAND=false on A park
  case $OUT in *"push to the remote failed: "*) ;; *) fail "no push error"; return 1 ;; esac
  case $OUT in *"offline?"*) fail "blames the network for a missing access"; return 1 ;; esac
}

t_clone_never_touches_an_existing_folder() {
  rm -rf "$T/B/dev/App"; mkdir -p "$T/B/dev/App"; echo mine > "$T/B/dev/App/notes.txt"
  on B resume
  check "existing folder was touched" [ "$(cat "$T/B/dev/App/notes.txt" 2>/dev/null)" = mine ]
}

t_add_takes_a_folder() {
  git clone -q "$(second_remote other)" "$T/A/dev/Other" 2>/dev/null
  on A add "$T/A/dev/Other"
  check "folder not added" grep -q '^Other ' "$P/projects.conf"
}

t_add_moves_a_folder_from_elsewhere_with_its_claude_history() {
  local old_key new_key
  mkdir -p "$T/A/elsewhere"; git clone -q "$(second_remote side)" "$T/A/elsewhere/Side" 2>/dev/null
  old_key=$(printf '%s' "$(cd "$T/A/elsewhere/Side" && pwd)" | sed 's#[^A-Za-z0-9]#-#g')
  mkdir -p "$T/A/.claude/projects/$old_key/memory"; echo note > "$T/A/.claude/projects/$old_key/memory/m.md"
  on A add "$T/A/elsewhere/Side"   # no terminal: confirm takes its default (yes)
  check "not moved into the projects folder" [ -d "$T/A/dev/Side/.git" ] || return 1
  check "not added" grep -q '^Side ' "$P/projects.conf" || return 1
  new_key=$(printf '%s' "$T/A/dev/Side" | sed 's#[^A-Za-z0-9]#-#g')   # roam's own spelling: projects folder + name
  check "Claude memory didn't move along" [ -f "$T/A/.claude/projects/$new_key/memory/m.md" ]
}

# ---------------------------------------------------------------- AI sessions
claude_fixture() {  # $1 Mac, $2 session id — a small transcript with a title, a prompt (and a fake key), a reply, todos, an edit
  local d p
  d=$(claude_dir "$1"); p="$T/$1/dev/App"
  mkdir -p "$d"
  cat > "$d/$2.jsonl" <<EOF
{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"fix the login, key sk-ant-api03-abcdefghijklmnop"},"timestamp":"2026-10-01T10:00:00.000Z","cwd":"$p","gitBranch":"feature/login","sessionId":"$2"}
{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"$p/a.txt","old_string":"a","new_string":"b"}}]},"timestamp":"2026-10-01T10:00:05.000Z","gitBranch":"feature/login","sessionId":"$2"}
{"parentUuid":"u2","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"Write the test","status":"completed","activeForm":"x"},{"content":"Update README","status":"in_progress","activeForm":"y"}]}}]},"timestamp":"2026-10-01T10:00:06.000Z","gitBranch":"feature/login","sessionId":"$2"}
{"parentUuid":"u3","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The login works again."}]},"timestamp":"2026-10-01T10:00:09.000Z","gitBranch":"feature/login","sessionId":"$2"}
{"type":"system","subtype":"away_summary","content":"Login fixed, README still open.","timestamp":"2026-10-01T10:01:00.000Z","sessionId":"$2"}
{"type":"ai-title","aiTitle":"Fix the login","sessionId":"$2"}
EOF
}

t_sessions_show_title_and_last_state() {
  command -v jq >/dev/null || { fail "jq missing"; return 1; }
  claude_fixture A s-one
  on A sessions App
  case $OUT in *"Fix the login"*) ;; *) fail "title missing"; return 1 ;; esac
  case $OUT in *"README still open"*) ;; *) fail "recap missing"; return 1 ;; esac
  case $OUT in *"Update README"*) ;; *) fail "todo missing"; return 1 ;; esac
  case $OUT in *"a.txt"*) ;; *) fail "edited file missing"; return 1 ;; esac
}

t_digest_tells_the_other_mac_with_secrets_masked() {
  command -v jq >/dev/null || { fail "jq missing"; return 1; }
  claude_fixture A s-two
  on A park
  check "no digest written" [ -f "$P/sessions/A/App.txt" ] || return 1
  check "secret reached the pool" not grep -q 'abcdefghijklmnop' "$P/sessions/A/App.txt" || return 1
  check "prompt missing in digest" grep -q '^prompt=s-two' "$P/sessions/A/App.txt" || return 1
  on B sessions App
  case $OUT in *"Fix the login"*) ;; *) fail "B doesn't see A's session"; return 1 ;; esac
  case $OUT in *"this Mac"*) fail "A's session credited to B"; return 1 ;; esac
}

t_digest_level_0_shares_nothing() {
  claude_fixture A s-three
  printf 'session_digest = 0\n' >> "$P/settings"
  on A park
  check "digest written despite session_digest = 0" [ ! -f "$P/sessions/A/App.txt" ]
}

t_codex_sessions_come_from_codex_database() {
  command -v jq >/dev/null && command -v sqlite3 >/dev/null || { fail "jq or sqlite3 missing"; return 1; }
  local r="$T/A/.codex/sessions/2026/10/01/rollout-x.jsonl"
  mkdir -p "$(dirname "$r")"
  cat > "$r" <<EOF
{"timestamp":"2026-10-01T09:00:00.000Z","type":"session_meta","payload":{"id":"c-1","cwd":"$T/A/dev/App"}}
{"timestamp":"2026-10-01T09:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"add dark mode"}}
{"timestamp":"2026-10-01T09:00:09.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Dark mode is in."}}
EOF
  sqlite3 "$T/A/.codex/state_5.sqlite" "create table threads (id text, rollout_path text, created_at int, updated_at int, cwd text, title text, name text,
    first_user_message text, git_branch text, source text, agent_role text, archived int);
    insert into threads values ('c-1', '$r', 1790000000, 1790000100, '$T/A/dev/App', 'Dark mode', '', 'add dark mode', 'main', 'cli', null, 0);"
  on A sessions App
  case $OUT in *"Dark mode is in."*) ;; *) fail "Codex reply missing"; return 1 ;; esac
}

t_session_transcript_reads_as_markdown() {
  command -v jq >/dev/null || { fail "jq missing"; return 1; }
  claude_fixture A s-four
  on A session App 1
  case $OUT in *"#### ▌ you"*"#### ▌ claude"*"The login works again."*) ;; *) fail "transcript not rendered as Markdown"; return 1 ;; esac
}

t_gemini_sessions() {
  command -v jq >/dev/null || { fail "jq missing"; return 1; }
  local d="$T/A/.gemini/tmp/app" p="$T/A/dev/App"
  mkdir -p "$d/chats"; printf '%s' "$p" > "$d/.project_root"
  cat > "$d/chats/session-2026-10-01T10-00-abc12345.jsonl" <<EOF
{"sessionId":"g-1","projectHash":"x","startTime":"2026-10-01T10:00:00.000Z","lastUpdated":"2026-10-01T10:01:00.000Z","kind":"main"}
{"id":"m1","timestamp":"2026-10-01T10:00:01.000Z","type":"user","content":[{"text":"add a search box"}]}
{"id":"m2","timestamp":"2026-10-01T10:00:09.000Z","type":"gemini","content":"The search box is in.","toolCalls":[{"id":"t1","name":"write_file","args":{"file_path":"$p/search.txt"},"status":"success","timestamp":"2026-10-01T10:00:05.000Z"},{"id":"t2","name":"write_todos","args":{"todos":[{"description":"Style it","status":"in_progress"}]},"status":"success","timestamp":"2026-10-01T10:00:06.000Z"}]}
{"\$set":{"summary":"Search box","lastUpdated":"2026-10-01T10:01:00.000Z"}}
EOF
  on A sessions App
  for want in "Search box" "add a search box" "The search box is in." "Style it" "search.txt"; do
    case $OUT in *"$want"*) ;; *) fail "missing: $want"; return 1 ;; esac
  done
  on A session App g-1
  case $OUT in *"#### ▌ you"*"add a search box"*"#### ▌ gemini"*"write_file"*) ;; *) fail "transcript"; return 1 ;; esac
}

t_gemini_replays_rewrites_and_rewinds() {
  # Gemini writes a message again in full on every change, and /rewind drops what came after
  command -v jq >/dev/null || { fail "jq missing"; return 1; }
  local d="$T/A/.gemini/tmp/app" p="$T/A/dev/App" n
  mkdir -p "$d/chats"; printf '%s' "$p" > "$d/.project_root"
  cat > "$d/chats/session-2026-10-02T10-00-def67890.jsonl" <<EOF
{"sessionId":"g-2","projectHash":"x","startTime":"2026-10-02T10:00:00.000Z","lastUpdated":"2026-10-02T10:00:00.000Z","kind":"main"}
{"id":"u1","timestamp":"2026-10-02T10:00:01.000Z","type":"user","content":"make the header sticky"}
{"\$set":{"lastUpdated":"2026-10-02T10:00:01.000Z"}}
{"id":"g1","timestamp":"2026-10-02T10:00:02.000Z","type":"gemini","content":"Working on it."}
{"id":"g1","timestamp":"2026-10-02T10:00:02.000Z","type":"gemini","content":"Working on it.","toolCalls":[{"id":"t1","name":"replace","args":{"file_path":"$p/header.css"},"status":"success","timestamp":"2026-10-02T10:00:03.000Z"},{"id":"t2","name":"write_todos","args":{"todos":[{"description":"Test on mobile","status":"pending"}]},"status":"success","timestamp":"2026-10-02T10:00:04.000Z"}]}
{"id":"i1","timestamp":"2026-10-02T10:00:05.000Z","type":"info","content":"Request cancelled."}
{"id":"u2","timestamp":"2026-10-02T10:00:06.000Z","type":"user","content":"also make it blue"}
{"id":"g2","timestamp":"2026-10-02T10:00:07.000Z","type":"gemini","content":"It is blue now."}
{"\$rewindTo":"u2"}
EOF
  cp "$d/chats/session-2026-10-02T10-00-def67890.jsonl" "$d/chats/session-2026-10-02T10-00-def67890.json"
  on A sessions App
  for want in "make the header sticky" "Working on it." "Test on mobile" "header.css" "1 prompt"; do
    case $OUT in *"$want"*) ;; *) fail "missing: $want"; return 1 ;; esac
  done
  for bad in "also make it blue" "It is blue now." "Request cancelled." "write_todos"; do
    case $OUT in *"$bad"*) fail "shown: $bad"; return 1 ;; esac
  done
  n=$(printf '%s\n' "$OUT" | grep -c -E "^ +[0-9]+ +. make the header sticky")
  check "the .json beside its .jsonl listed too" [ "$n" = 1 ] || return 1
  on A session App g-2
  n=$(printf '%s\n' "$OUT" | grep -c "Working on it.")
  check "a rewritten message shown twice" [ "$n" = 1 ] || return 1
  case $OUT in *"Edit"*|*"replace"*) ;; *) fail "tool call of the rewritten message missing"; return 1 ;; esac
}

t_gemini_legacy_json_sessions() {
  command -v jq >/dev/null || { fail "jq missing"; return 1; }
  local p="$T/A/dev/App" d
  d="$T/A/.gemini/tmp/$(printf '%s' "$p" | shasum -a 256 | cut -c1-64)"
  mkdir -p "$d/chats"
  cat > "$d/chats/session-2026-09-01T10-00-old.json" <<EOF
{"sessionId":"g-old","projectHash":"x","startTime":"2026-09-01T10:00:00.000Z","lastUpdated":"2026-09-01T10:05:00.000Z",
 "messages":[{"id":"a","timestamp":"2026-09-01T10:00:01.000Z","type":"user","content":"rename the app"},
             {"id":"b","timestamp":"2026-09-01T10:00:09.000Z","type":"gemini","content":[{"text":"Renamed everywhere."}]}]}
EOF
  on A sessions App
  for want in "rename the app" "Renamed everywhere."; do
    case $OUT in *"$want"*) ;; *) fail "missing: $want"; return 1 ;; esac
  done
}

t_copilot_sessions() {
  command -v jq >/dev/null || { fail "jq missing"; return 1; }
  local d="$T/A/.copilot/session-state/c-1" p="$T/A/dev/App"
  mkdir -p "$d"
  printf 'id: c-1\ncwd: %s\nbranch: main\nsummary: |\n  Fix the footer\ncreated_at: 2026-10-01T09:00:00Z\nupdated_at: 2026-10-01T09:05:00Z\n' "$p" > "$d/workspace.yaml"
  cat > "$d/events.jsonl" <<EOF
{"type":"session.start","id":"e0","timestamp":"2026-10-01T09:00:00.000Z","data":{"sessionId":"c-1"}}
{"type":"user.message","id":"e1","timestamp":"2026-10-01T09:00:01.000Z","data":{"content":"fix the footer"}}
{"type":"tool.execution_start","id":"e2","parentId":"e1","timestamp":"2026-10-01T09:00:02.000Z","data":{"toolName":"edit","arguments":{"path":"$p/footer.txt"}}}
{"type":"assistant.message","id":"e3","timestamp":"2026-10-01T09:00:05.000Z","data":{"content":"Footer fixed.","toolRequests":[]}}
EOF
  printf -- '- [x] Find the footer\n- [ ] Test it\n' > "$d/plan.md"
  on A sessions App
  for want in "Fix the footer" "fix the footer" "Footer fixed." "Test it" "footer.txt"; do
    case $OUT in *"$want"*) ;; *) fail "missing: $want"; return 1 ;; esac
  done
  on A session App c-1
  case $OUT in *"#### ▌ you"*"fix the footer"*"#### ▌ copilot"*"edit"*"Footer fixed."*) ;; *) fail "transcript"; return 1 ;; esac
}

t_copilot_current_format() {
  # Copilot 1.x: title in name, todos in session.db, apply_patch edits, sub-agents in the same events.jsonl
  command -v jq >/dev/null && command -v sqlite3 >/dev/null || { fail "jq or sqlite3 missing"; return 1; }
  local d="$T/A/.copilot/session-state/c-2" p="$T/A/dev/App"
  mkdir -p "$d"
  printf 'id: c-2\ncwd: "%s"\nbranch: feature/menu\nsummary: an older summary\nname: "Burger menu"\n' "$p" > "$d/workspace.yaml"
  cat > "$d/events.jsonl" <<EOF
{"id":"e0","timestamp":"2026-10-02T09:00:00.000Z","parentId":null,"type":"session.start","data":{"sessionId":"c-2"}}
{"id":"e1","timestamp":"2026-10-02T09:00:01.000Z","parentId":"e0","type":"user.message","data":{"content":"add a burger menu"}}
{"id":"e2","timestamp":"2026-10-02T09:00:02.000Z","parentId":"e1","agentId":"sub-1","type":"user.message","data":{"content":"explore the nav code","parentToolCallId":"t0"}}
{"id":"e3","timestamp":"2026-10-02T09:00:03.000Z","parentId":"e2","agentId":"sub-1","type":"assistant.message","data":{"messageId":"m1","content":"sub-agent findings"}}
{"id":"e4","timestamp":"2026-10-02T09:00:04.000Z","parentId":"e3","type":"tool.execution_start","data":{"toolCallId":"t1","toolName":"apply_patch","arguments":"*** Begin Patch\n*** Update File: $p/nav.txt\n@@\n-old\n+new\n*** End Patch"}}
{"id":"e5","timestamp":"2026-10-02T09:00:05.000Z","parentId":"e4","type":"assistant.message","data":{"messageId":"m2","content":"The menu folds up on phones."}}
EOF
  sqlite3 "$d/session.db" "create table todos (id text primary key, title text not null, description text, status text default 'pending', created_at text, updated_at text);
    insert into todos values ('a', 'Animate the menu', null, 'in_progress', '1', '1'); insert into todos values ('b', 'Find the nav', null, 'done', '0', '0');"
  on A sessions App
  for want in "Burger menu" "feature/menu" "add a burger menu" "The menu folds up on phones." "Animate the menu" "nav.txt" "1 prompt"; do
    case $OUT in *"$want"*) ;; *) fail "missing: $want"; return 1 ;; esac
  done
  for bad in "an older summary" "explore the nav code" "sub-agent findings"; do
    case $OUT in *"$bad"*) fail "shown: $bad"; return 1 ;; esac
  done
  on A session App c-2
  case $OUT in *"add a burger menu"*"apply_patch"*"nav.txt"*"folds up"*) ;; *) fail "transcript"; return 1 ;; esac
  case $OUT in *"sub-agent findings"*) fail "sub-agent reply in the transcript"; return 1 ;; esac
}

t_opencode_sessions() {
  command -v jq >/dev/null && command -v sqlite3 >/dev/null || { fail "jq or sqlite3 missing"; return 1; }
  local db="$T/A/.local/share/opencode/opencode.db" p="$T/A/dev/App"
  mkdir -p "$(dirname "$db")"
  sqlite3 "$db" "create table session (id text, directory text, title text, parent_id text, time_created int, time_updated int, time_archived int);
    create table message (id text, session_id text, time_created int, time_updated int, data text);
    create table part (id text, message_id text, session_id text, time_created int, time_updated int, data text);
    create table todo (session_id text, content text, status text, priority text, position int, time_created int, time_updated int);
    insert into session values ('o-1', '$p', 'Dark mode toggle', null, 1790000000000, 1790000100000, null);
    insert into session values ('o-sub', '$p', 'a subagent', 'o-1', 1790000000000, 1790000200000, null);
    insert into message values ('m1', 'o-1', 1790000001000, 1790000001000, '{\"role\":\"user\"}');
    insert into message values ('m2', 'o-1', 1790000005000, 1790000005000, '{\"role\":\"assistant\"}');
    insert into part values ('p1', 'm1', 'o-1', 1790000001000, 1790000001000, '{\"type\":\"text\",\"text\":\"add a dark mode toggle\"}');
    insert into part values ('p2', 'm2', 'o-1', 1790000003000, 1790000003000, '{\"type\":\"tool\",\"tool\":\"edit\",\"state\":{\"status\":\"completed\",\"input\":{\"filePath\":\"$p/theme.txt\"}}}');
    insert into part values ('p3', 'm2', 'o-1', 1790000005000, 1790000005000, '{\"type\":\"text\",\"text\":\"The toggle is in the settings.\"}');
    insert into todo values ('o-1', 'Remember the choice', 'pending', 'medium', 0, 1790000005000, 1790000005000);"
  on A sessions App
  for want in "Dark mode toggle" "add a dark mode toggle" "The toggle is in the settings." "Remember the choice" "theme.txt"; do
    case $OUT in *"$want"*) ;; *) fail "missing: $want"; return 1 ;; esac
  done
  case $OUT in *"a subagent"*) fail "subagent session listed"; return 1 ;; esac
  on A session App o-1
  case $OUT in *"#### ▌ you"*"dark mode"*"#### ▌ opencode"*"edit"*"settings."*) ;; *) fail "transcript"; return 1 ;; esac
}

t_opencode_2_sessions() {
  # opencode 2.x: session_v2 + session_message; an upgraded database still has the 1.x tables (never counted twice)
  command -v jq >/dev/null && command -v sqlite3 >/dev/null || { fail "jq or sqlite3 missing"; return 1; }
  local db="$T/A/.local/share/opencode/opencode.db" p="$T/A/dev/App" n
  mkdir -p "$(dirname "$db")"
  sqlite3 "$db" "create table session (id text, directory text, title text, parent_id text, time_created int, time_updated int, time_archived int);
    insert into session values ('o-1', '$p', 'Dark mode toggle', null, 1790000000000, 1790000100000, null);
    create table session_v2 (id text, project_id text, parent_id text, directory text, path text, title text, time_created int, time_updated int, time_archived int);
    create table session_message (id text, session_id text, type text, seq int, time_created int, time_updated int, data text);
    insert into session_v2 values ('o-1', 'pr', null, '$p', '', 'Dark mode toggle', 1790000000000, 1790000100000, null);
    insert into session_v2 values ('o-2', 'pr', null, '$p/web', 'web', null, 1790000000000, 1790000050000, null);
    insert into session_v2 values ('o-sub', 'pr', 'o-1', '$p', '', 'a subagent', 1790000000000, 1790000200000, null);
    insert into session_message values ('m1', 'o-1', 'user', 1, 1790000001000, 1790000001000, '{\"time\":{\"created\":1790000001000},\"text\":\"add a dark mode toggle\",\"files\":[]}');
    insert into session_message values ('m2', 'o-1', 'assistant', 2, 1790000003000, 1790000005000, '{\"time\":{\"created\":1790000003000},\"agent\":\"build\",\"content\":[{\"type\":\"reasoning\",\"text\":\"secret thoughts\"},{\"type\":\"tool\",\"id\":\"t1\",\"name\":\"edit\",\"state\":{\"status\":\"completed\",\"input\":{\"path\":\"$p/theme.txt\",\"oldString\":\"a\",\"newString\":\"b\"},\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]},\"time\":{\"created\":1790000003000}},{\"type\":\"tool\",\"id\":\"t2\",\"name\":\"todowrite\",\"state\":{\"status\":\"completed\",\"input\":{\"todos\":[{\"content\":\"Remember the choice\",\"status\":\"pending\"}]},\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]},\"time\":{\"created\":1790000004000}},{\"type\":\"text\",\"text\":\"The toggle is in the settings.\"}],\"snapshot\":{\"files\":[\"$p/settings.txt\"]}}');
    insert into session_message values ('m3', 'o-1', 'idle', 3, 1790000005000, 1790000005000, '{\"time\":{\"created\":1790000005000},\"outcome\":\"succeeded\"}');
    insert into session_message values ('m4', 'o-2', 'user', 1, 1790000006000, 1790000006000, '{\"time\":{\"created\":1790000006000},\"text\":\"fix the footer\"}');"
  on A sessions App
  for want in "Dark mode toggle" "add a dark mode toggle" "The toggle is in the settings." "Remember the choice" "theme.txt" "settings.txt" "fix the footer"; do
    case $OUT in *"$want"*) ;; *) fail "missing: $want"; return 1 ;; esac
  done
  case $OUT in *"a subagent"*) fail "subagent session listed"; return 1 ;; esac
  n=$(printf '%s\n' "$OUT" | grep -c -E "^ +[0-9]+ +. Dark mode toggle")
  check "1.x copy counted too" [ "$n" -le 1 ] || return 1
  on A session App o-1
  case $OUT in *"#### ▌ you"*"dark mode"*"#### ▌ opencode"*"edit"*"theme.txt"*"settings."*) ;; *) fail "transcript"; return 1 ;; esac
  case $OUT in *"secret thoughts"*) fail "reasoning shown"; return 1 ;; esac
}

# ---------------------------------------------------------------- Markdown reader
t_markdown_never_wider_than_asked() {
  local w line bad=0
  for w in 50 80; do
    while IFS= read -r line; do [ ${#line} -le $w ] || { bad=1; OUT="$w: $line"; }; done <<EOF
$(LC_ALL=en_US.UTF-8 /bin/bash -c ". '$ROOT/lib/md.sh'; md_render '$ROOT/README.md' $w")
EOF
  done
  check "a rendered line is too wide" [ $bad = 0 ]
}

t_markdown_strips_escape_sequences() {
  printf '# Title\n\nevil \033]0;pwned\007 text \033[31mred\n' > "$T/evil.md"
  OUT=$(/bin/bash -c ". '$ROOT/lib/md.sh'; md_render '$T/evil.md' 60")
  case $OUT in *$'\033'*) fail "escape sequence got through"; return 1 ;; esac
}

t_markdown_files_ranked_readme_first() {
  local p="$T/A/dev/App"
  echo "# r" > "$p/README.md"; echo "# c" > "$p/CLAUDE.md"; echo "# ch" > "$p/CHANGELOG.md"
  mkdir -p "$p/docs"; echo "# d" > "$p/docs/guide.md"; ln -s CLAUDE.md "$p/AGENTS.md"
  OUT=$(/bin/bash -c ". '$ROOT/lib/md.sh'; md_files '$p'" | cut -f3 | tr '\n' ' ')
  check "wrong order or duplicate: $OUT" [ "$OUT" = "README.md CLAUDE.md CHANGELOG.md docs/guide.md " ]
}

# ---------------------------------------------------------------- the app
t_app_frame_fits_the_terminal() {
  local w line bad=""
  for w in 64 80 120; do
    OUT=$(HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
      ROAM_TUI_SNAPSHOT=dash ROAM_COLS=$w ROAM_ROWS=24 LC_ALL=en_US.UTF-8 "$ROOT/roam" 2>&1)
    case $OUT in *App*) ;; *) fail "project missing at $w columns"; return 1 ;; esac
    while IFS= read -r line; do
      line=$(printf '%s' "$line" | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
      [ "$(printf '%s' "$line" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')" -le $w ] || bad="$w: $line"
    done <<EOF
$OUT
EOF
  done
  check "a line is wider than the terminal: $bad" [ -z "$bad" ]
}

in_a_terminal() {  # roam as A, in a pseudo-terminal → $T/pty
  HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" ROAM_LOCK="$T/A.lock" \
    TERM=xterm-256color script -q "$T/pty" "$ROOT/roam" "$@" >/dev/null 2>&1 </dev/null
}
pty_has() { LC_ALL=C sed $'s/\033\\[[0-9;]*m//g' "$T/pty" | grep -a -q "$1"; }   # $1 in the terminal's output (art comes colored letter by letter)

t_app_clips_long_lines_in_a_narrow_terminal() {
  local v line bad="" d="$T/A/dev/App/a-folder-with-a-rather-long-name/and-another-one-below-it"
  mkdir -p "$d"; touch "$d/x"; echo 'a-folder-with-a-rather-long-name/' > "$T/A/dev/App/.gitignore"
  printf 'mac=B\nname=MacBook Pro with a very long name indeed\nseen=%s\nversion=1.9.0\nmacos=27.0.1\nxcode=27.0.1 (build 27A1234567)\n' "$(date +%s)" > "$P/macs/B.txt"
  for v in dash repo; do
    OUT=$(HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
      ROAM_TUI_SNAPSHOT=$v ROAM_COLS=64 ROAM_ROWS=24 LC_ALL=en_US.UTF-8 "$ROOT/roam" 2>&1 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
    while IFS= read -r line; do
      [ "$(printf '%s' "$line" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')" -le 64 ] || bad="$v: $line"
    done <<EOF
$OUT
EOF
  done
  check "a line is wider than the terminal: $bad" [ -z "$bad" ] || return 1
  case $OUT in *"− a-folder-with-a-rather-long-name/"*"…"*) ;; *) fail "the long row isn't cut with …"; return 1 ;; esac
}

t_app_shows_about_this_mac() {
  local w line bad=""
  for w in 64 100; do
    OUT=$(HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
      ROAM_TUI_SNAPSHOT=about ROAM_COLS=$w ROAM_ROWS=24 LC_ALL=en_US.UTF-8 "$ROOT/roam" 2>&1 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
    case $OUT in *"About This Mac"*"roam $(sed -n 's/^ROAM_VERSION=//p' "$ROOT/roam")"*"│   ▌  ▐   │"*"Projects   1 "*) ;;
      *) fail "no About This Mac at $w columns"; return 1 ;; esac
    while IFS= read -r line; do
      [ "$(printf '%s' "$line" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')" -le $w ] || bad="$w: $line"
    done <<EOF
$OUT
EOF
  done
  check "a line is wider than the terminal: $bad" [ -z "$bad" ]
}

t_app_starts_and_quits_cleanly() {
  local p
  ( sleep 2; printf 'j'; sleep 0.5; printf '?'; sleep 0.5; printf 'x'; for _ in $(seq 15); do sleep 1; printf 'Q'; done ) |   # Q until it's read
    HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" ROAM_NO_ANIM=1 \
    script -q "$T/pty" "$ROOT/roam" >/dev/null 2>&1 &
  p=$!
  for _ in $(seq 18); do sleep 1; kill -0 $p 2>/dev/null || break; done
  if kill -0 $p 2>/dev/null; then kill $p; fail "roam didn't quit on Q"; return 1; fi
  OUT=$(LC_ALL=C grep -a -c $'\033\\[?1049l' "$T/pty")
  check "terminal not restored (alternate screen still on)" [ "$OUT" -ge 1 ] || return 1
  OUT=$(LC_ALL=C grep -a -o 'unbound variable\|syntax error\|command not found' "$T/pty" | head -3)
  check "errors on screen: $OUT" [ -z "$OUT" ] || return 1
  check "no goodbye after Q" pty_has '◆ roam'
}

t_app_parks_live_and_comes_back() {
  local p
  echo "changed in the app" > "$T/A/dev/App/a.txt"
  ( sleep 2; printf 'p'; sleep 6; printf '\r'; for _ in $(seq 12); do sleep 1; printf 'Q'; done ) |   # Q until it's read
    HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" ROAM_LOCK="$T/A.lock" \
    ROAM_NO_ANIM=1 script -q "$T/pty" "$ROOT/roam" >/dev/null 2>&1 &
  p=$!
  for _ in $(seq 20); do sleep 1; kill -0 $p 2>/dev/null || break; done
  if kill -0 $p 2>/dev/null; then kill $p; fail "roam didn't quit after parking"; return 1; fi
  check "nothing parked on the remote" git -C "$T/remote.git" rev-parse -q --verify refs/roam/A >/dev/null || return 1
  OUT=$(LC_ALL=C grep -a -c 'All parked' "$T/pty")
  check "no 'All parked' in the app" [ "$OUT" -ge 1 ] || return 1
  check "no picture of the parked work going up" pty_has '─ ─ ─▶'
}

t_art_only_in_a_terminal() {
  in_a_terminal help
  check "no logo in roam help" pty_has '██████╗' || return 1
  ROAM_NO_ART=1 in_a_terminal help
  check "ROAM_NO_ART=1 still shows the logo" not pty_has '██████╗' || return 1
  echo x > "$T/A/dev/App/a.txt"
  in_a_terminal park
  check "no picture after park in a terminal" pty_has '─ ─ ─▶' || return 1
  on A help
  case $OUT in *"██"*) fail "the logo lands in a pipe"; return 1 ;; esac
  echo y > "$T/A/dev/App/a.txt"; on A park
  case $OUT in *"─ ─ ─▶"*) fail "a picture lands in a pipe"; return 1 ;; esac
}

t_old_macs_for_fans() {
  in_a_terminal about
  check "about doesn't show the Happy Mac" pty_has '│ │   ▌  ▐   │ │' || return 1
  check "about doesn't show the version" pty_has "roam $(sed -n 's/^ROAM_VERSION=//p' "$ROOT/roam")" || return 1
  check "about doesn't count the projects" pty_has 'Projects   1 ' || return 1
  git -C "$T/A/dev/App" remote set-url origin git@github.com:me/app.git
  printf '[url "%s"]\n\tinsteadOf = https://github.com/me/app.git\n' "$T/nowhere.git" > "$T/A/.gitconfig"
  echo wip > "$T/A/dev/App/new.txt"
  GIT_SSH_COMMAND=false in_a_terminal park
  check "a failed park doesn't show the Sad Mac" pty_has '│ │   ╳  ╳   │ │' || return 1
  check "a failed park shows the PowerBook going up" not pty_has '(◯)'
}

t_app_says_its_safe_when_nothing_is_open() {
  local p
  ( for _ in $(seq 15); do sleep 1; printf 'Q'; done ) |   # Q until it's read: the app may take a while to start
    HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" ROAM_NO_ANIM=1 \
    script -q "$T/pty" "$ROOT/roam" >/dev/null 2>&1 &
  p=$!
  for _ in $(seq 15); do sleep 1; kill -0 $p 2>/dev/null || break; done
  if kill -0 $p 2>/dev/null; then kill $p; fail "roam didn't quit on Q"; return 1; fi
  check "no Macintosh goodbye on a clean Mac" pty_has "It's now safe to turn off your Macintosh." || return 1
  echo open > "$T/A/dev/App/a.txt"
  ( for _ in $(seq 15); do sleep 1; printf 'Q'; done ) |   # Q until it's read: the app may take a while to start
    HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" ROAM_NO_ANIM=1 \
    script -q "$T/pty" "$ROOT/roam" >/dev/null 2>&1 &
  p=$!
  for _ in $(seq 15); do sleep 1; kill -0 $p 2>/dev/null || break; done
  if kill -0 $p 2>/dev/null; then kill $p; fail "roam didn't quit on Q"; return 1; fi
  check "says it's safe with open work" not pty_has "safe to turn off" || return 1
  check "no reminder to park" pty_has 'park before you walk away'
}

# ---------------------------------------------------------------- what macOS and sync apps leave behind, new files
t_finder_files_are_no_work() {
  touch "$T/A/dev/App/.DS_Store" "$T/A/dev/App/._a.txt"; mkdir -p "$T/A/dev/App/docs"; touch "$T/A/dev/App/docs/.DS_Store"
  on A park
  check "park failed" [ $RC = 0 ] || return 1
  check ".DS_Store was parked as work" not git -C "$T/remote.git" rev-parse -q --verify refs/roam/A || return 1
  check "status counts .DS_Store" grep -q "^project=App	main	0	" "$P/macs/A.txt"
}

t_finder_files_dont_break_in_sync() {
  on B status
  touch "$T/A/dev/App/.DS_Store"
  on A status
  case $OUT in *"≡ in sync"*) ;; *) fail "a .DS_Store on one Mac broke in sync"; return 1 ;; esac
}

t_new_files_are_counted_apart() {
  echo changed > "$T/A/dev/App/a.txt"; echo new > "$T/A/dev/App/b.txt"; mkdir "$T/A/dev/App/docs"; echo x > "$T/A/dev/App/docs/c.md"
  on A status
  check "registry lacks the new count" grep -q "^project=App	main	3	.*	2$" "$P/macs/A.txt" || return 1
  case $OUT in *"●1 +2"*) ;; *) fail "status doesn't show ●1 +2"; return 1 ;; esac
}

t_an_older_mac_still_shows_its_changes() {
  printf 'mac=B\nname=B\nseen=%s\nversion=1.8.0\nproject=App\tmain\t2\t0\tno\tabc\tdef\n' "$(date +%s)" > "$P/macs/B.txt"
  on A status
  case $OUT in *"main ●2"*) ;; *) fail "B's two changes aren't shown"; return 1 ;; esac
}

t_sync_app_copies_are_no_macs() {
  on A status; on B status
  cp "$P/macs/B.txt" "$P/macs/B 2.txt"                                        # iCloud Drive
  cp "$P/macs/B.txt" "$P/macs/B (Mac's conflicted copy 2026-10-07).txt"      # Dropbox
  cp "$P/macs/B.txt" "$P/macs/B-MacBook.txt"                                 # OneDrive
  cp "$P/macs/A.txt" "$P/macs/A (1).txt"                                     # Google Drive, A's own
  on A status
  check "a copy shows up as a Mac: $(printf '%s\n' "$OUT" | grep -c 'macOS') Macs" [ "$(printf '%s\n' "$OUT" | grep -c 'macOS')" = 2 ] || return 1
  check "A's own copy is still there" [ ! -f "$P/macs/A (1).txt" ] || return 1
  check "B's copies are A's business" [ -f "$P/macs/B 2.txt" ] || return 1
  on A doctor
  case $OUT in *"set aside"*) fail "status copies are roam's to handle, not a doctor hint"; return 1 ;; esac
}

t_claude_conflict_copies_stay_in_the_pool() {
  mkdir -p "$P/claude/App/memory"
  echo '{"type":"user"}' > "$P/claude/App/s1.jsonl"
  echo '{"type":"user"}' > "$P/claude/App/s1 2.jsonl"
  echo 'theirs' > "$P/claude/App/memory/MEMORY (conflicted copy 2026-10-07).md"
  on B resume
  check "the real transcript didn't come" [ -f "$(claude_dir B)/s1.jsonl" ] || return 1
  check "the iCloud copy became a session" [ ! -f "$(claude_dir B)/s1 2.jsonl" ] || return 1
  check "the Dropbox copy came along" [ ! -f "$(claude_dir B)/memory/MEMORY (conflicted copy 2026-10-07).md" ] || return 1
  on B doctor
  case $OUT in *"set aside in the pool"*) ;; *) fail "doctor doesn't mention the copies"; return 1 ;; esac
}

t_ignore_keeps_a_new_file_out_and_takes_it_back() {
  local d="$T/A/dev/App"
  echo x > "$d/notes.txt"
  on A ignore App
  case $OUT in *"notes.txt"*"goes in"*) ;; *) fail "notes.txt isn't listed as new"; return 1 ;; esac
  on A ignore App notes.txt
  check "toggle failed" [ $RC = 0 ] || return 1
  check "not in .gitignore" grep -qx '/notes.txt' "$d/.gitignore" || return 1
  check "git still takes it" git -C "$d" check-ignore -q notes.txt || return 1
  on A ignore App notes.txt
  check "taking it back failed" [ $RC = 0 ] || return 1
  check "the rule is still there" not grep -q 'notes' "$d/.gitignore" || return 1
  check "still ignored" not git -C "$d" check-ignore -q notes.txt
}

t_ignore_makes_an_exception_from_a_broad_rule() {
  local d="$T/A/dev/App"
  printf '*.log' > "$d/.gitignore"                                           # no newline at the end
  echo x > "$d/keep.log"; echo y > "$d/other.log"
  on A ignore App keep.log
  check "toggle failed" [ $RC = 0 ] || return 1
  check "keep.log still ignored" not git -C "$d" check-ignore -q keep.log || return 1
  check "the broad rule went away" git -C "$d" check-ignore -q other.log || return 1
  check "rule glued to the last line" grep -qx '!/keep.log' "$d/.gitignore"
}

t_ignore_keeps_finder_files_out_by_name() {
  local d="$T/A/dev/App"
  mkdir "$d/docs"; touch "$d/docs/.DS_Store"
  on A ignore App docs/.DS_Store
  check "toggle failed" [ $RC = 0 ] || return 1
  check "not ignored by name" grep -qx '.DS_Store' "$d/.gitignore" || return 1
  touch "$d/.DS_Store"
  check "another .DS_Store isn't covered" git -C "$d" check-ignore -q .DS_Store
}

t_app_lists_what_isnt_in_the_repo() {
  echo x > "$T/A/dev/App/notes.txt"; echo 'build/' > "$T/A/dev/App/.gitignore"; mkdir "$T/A/dev/App/build"; touch "$T/A/dev/App/build/o"
  OUT=$(HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
    ROAM_TUI_SNAPSHOT=repo ROAM_COLS=100 ROAM_ROWS=30 LC_ALL=en_US.UTF-8 "$ROOT/roam" 2>&1 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
  printf '%s\n' "$OUT" | grep -q -E '\+ notes\.txt +goes in' || { fail "notes.txt isn't listed as new"; return 1; }
  printf '%s\n' "$OUT" | grep -q -E '− build/ +stays out · \.gitignore: build/' || { fail "build/ isn't listed as staying out"; return 1; }
}

t_help_explains_the_symbols() {
  OUT=$(HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
    ROAM_TUI_SNAPSHOT=help ROAM_COLS=100 ROAM_ROWS=40 LC_ALL=en_US.UTF-8 "$ROOT/roam" 2>&1 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
  case $OUT in *Symbols*"new, never committed"*"parked on the remote"*) ;; *) fail "no symbols in the help"; return 1 ;; esac
}

# ---------------------------------------------------------------- a Mac that is behind
commit_on() {  # $1 Mac, $2 file — a commit there, pushed
  ( cd "$T/$1/dev/App" && echo "$2" > "$2" && git add "$2" && git -c user.name=t -c user.email=t@t commit -qm "$2" && git push -q origin HEAD:main 2>/dev/null )
}

t_open_work_of_a_mac_behind_goes_on_top() {
  commit_on A c2.txt
  echo "from B" > "$T/B/dev/App/notes.txt"; on B park           # B is still at the first commit
  on A resume
  check "resume failed" [ $RC = 0 ] || return 1
  check "B's new file isn't here" grep -qx "from B" "$T/A/dev/App/notes.txt" || return 1
  check "A lost its commit" [ -f "$T/A/dev/App/c2.txt" ] || return 1
  case $OUT in *"1 commit behind"*) ;; *) fail "doesn't say B is behind"; return 1 ;; esac
}

t_open_work_of_a_mac_behind_that_is_here_already() {
  commit_on A c2.txt
  echo same > "$T/A/dev/App/notes.txt"; echo same > "$T/B/dev/App/notes.txt"; on B park
  on A resume
  check "resume failed" [ $RC = 0 ] || return 1
  case $OUT in *"here already"*) ;; *) fail "doesn't say it's here already"; return 1 ;; esac
}

t_sync_from_the_mac_behind() {
  on A status; on B status
  commit_on A c2.txt
  echo same > "$T/A/dev/App/notes.txt"; echo same > "$T/B/dev/App/notes.txt"
  on A park
  answer_requests A &
  ROAM_SYNC_WAIT=30 on B sync App
  wait
  check "sync failed" [ $RC = 0 ] || return 1
  check "B didn't catch up" [ "$(git -C "$T/B/dev/App" rev-parse HEAD)" = "$(git -C "$T/A/dev/App" rev-parse HEAD)" ] || return 1
  case $OUT in *"is in sync"*) ;; *) fail "not in sync afterwards"; return 1 ;; esac
}

t_app_names_the_mac_behind() {
  on B status
  commit_on A c2.txt; on A status
  OUT=$(HOME="$T/A" ROAM_POOL="$P" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
    ROAM_TUI_SNAPSHOT=dash ROAM_COLS=120 ROAM_ROWS=30 LC_ALL=en_US.UTF-8 "$ROOT/roam" 2>&1 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
  printf '%s\n' "$OUT" | grep -q -E '❯ App .* ≠' || { fail "the list doesn't mark App with ≠"; return 1; }
  case $OUT in *"is 1 commit behind"*) ;; *) fail "the preview doesn't name the Mac behind"; return 1 ;; esac
}

# ---------------------------------------------------------------- run
printf '\n  roam tests %s(%s)%s\n\n' "$D" "$(/bin/bash -c 'echo $BASH_VERSION')" "$N"
for t in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do run "$t"; done
[ -n "$T" ] && [ -z "${KEEP:-}" ] && rm -rf "$T"
printf '\n  %d passed' "$PASS"; [ $FAIL -gt 0 ] && printf ', %s%d failed%s' "$R" "$FAIL" "$N"; echo; echo
[ $FAIL -eq 0 ]
