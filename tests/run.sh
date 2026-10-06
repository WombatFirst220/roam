#!/bin/bash
# roam test suite — two simulated Macs (A, B) with their own HOME, one pool folder, one bare remote.
#   tests/run.sh            all tests
#   tests/run.sh resume     only tests whose name contains "resume"
# Needs nothing but what roam needs. Never touches your real pool, projects or ~/.claude.
set -u
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS   # the caller's git overrides (packaging/release.sh) stay out of the simulated Macs
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

second_remote() {  # $1 name → path of another bare remote with one commit
  git init -q --bare "$T/$1.git"
  git -C "$T/seed" push -q "$T/$1.git" HEAD:main 2>/dev/null
  git -C "$T/$1.git" symbolic-ref HEAD refs/heads/main
  echo "$T/$1.git"
}

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

t_placeholder_memory_never_overwrites_the_pool_copy() {
  sed -i '' 's/^claude_history = 1/claude_history = 0/' "$T/pool/settings"   # memory only: the filter must not let it through
  mkdir -p "$(claude_dir A)/memory" "$(claude_dir B)/memory"
  echo 'good note' > "$(claude_dir A)/memory/m.md"
  on A park
  head -c "$(stat -f %z "$(claude_dir A)/memory/m.md")" /dev/zero > "$(claude_dir B)/memory/m.md"
  touch -t 203001010000 "$(claude_dir B)/memory/m.md"
  on B park
  check "pool memory was overwritten by the placeholder" grep -q good "$T/pool/claude/App/memory/m.md"
}

t_resume_repairs_placeholder_memory() {
  mkdir -p "$(claude_dir A)/memory" "$(claude_dir B)/memory"
  echo 'good note' > "$(claude_dir A)/memory/m.md"
  on A park
  head -c "$(stat -f %z "$(claude_dir A)/memory/m.md")" /dev/zero > "$(claude_dir B)/memory/m.md"
  touch -r "$T/pool/claude/App/memory/m.md" "$(claude_dir B)/memory/m.md"
  on B resume
  check "placeholder memory was not repaired" grep -q good "$(claude_dir B)/memory/m.md"
}

t_placeholder_without_disk_blocks_is_caught_too() {
  local pf
  mkdir -p "$(claude_dir A)/memory"
  echo 'good note' > "$(claude_dir A)/memory/m.md"
  on A park
  # the pool copy turns into a sparse file: a size, no blocks, reads as NUL bytes
  pf="$T/pool/claude/App/memory/m.md"
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
  check "binary file did not travel" [ -f "$T/pool/claude/App/s1/tool-results/shot.jpg" ] || return 1
  check "transcript with a cut-off umlaut did not travel" [ -f "$T/pool/claude/App/s2.jsonl" ]
}

t_a_hanging_pool_ends_the_run_with_a_message() {
  local t0
  rm "$T/pool/settings"; mkfifo "$T/pool/settings"            # reading it blocks, like a stuck sync app
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
  dd if=/dev/zero of="$T/pool/claude/cloud.md" bs=1 count=0 seek=100 2>/dev/null   # a size, no blocks
  [ "$(stat -f %b "$T/pool/claude/cloud.md")" = 0 ] || { ok; return; }              # file system without sparse files
  on A doctor
  case $OUT in *"online only on this Mac"*) ;; *) fail "no warning about online-only files"; return 1 ;; esac
}

t_status_file_is_only_rewritten_when_something_changed() {
  local f="$T/pool/macs/A.txt" ino
  on A park
  check "no status file" [ -f "$f" ] || return 1
  ino=$(stat -f %i "$f")
  on A park
  check "unchanged status was rewritten" [ "$(stat -f %i "$f")" = "$ino" ] || return 1
  sed -i '' 's/^seen=.*/seen=1/' "$f"; ino=$(stat -f %i "$f")      # heartbeat long overdue
  on A park
  check "overdue heartbeat was not refreshed" [ "$(stat -f %i "$f")" != "$ino" ] || return 1
  ino=$(stat -f %i "$f")
  echo change >> "$T/A/dev/App/a.txt"
  on A park
  check "a changed project did not update the status" [ "$(stat -f %i "$f")" != "$ino" ]
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
  printf 'App  App  %s\n' "$T/does-not-exist.git" > "$T/pool/projects.conf"
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
  printf 'App  App  https://github.com/me/app\n' > "$T/pool/projects.conf"
  rm -rf "$T/B/dev/App"
  on B resume
  check "not cloned" [ -d "$T/B/dev/App/.git" ] || return 1
  check "pool entry still HTTPS" grep -q 'git@github.com:me/app.git' "$T/pool/projects.conf"
}

t_clone_falls_back_to_https_where_ssh_has_no_access() {
  # the other way round: only HTTPS gets in (like a Mac whose SSH key belongs to another account)
  printf '[url "%s"]\n\tinsteadOf = https://github.com/me/app.git\n' "$T/remote.git" > "$T/B/.gitconfig"
  printf 'App  App  git@github.com:me/app.git\n' > "$T/pool/projects.conf"
  rm -rf "$T/B/dev/App"
  on B resume
  check "not cloned over HTTPS" [ -d "$T/B/dev/App/.git" ] || return 1
  case $OUT in *"over HTTPS"*) ;; *) fail "no note that HTTPS was used"; return 1 ;; esac
  check "pool entry changed" grep -q 'git@github.com:me/app.git' "$T/pool/projects.conf"
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
  check "folder not added" grep -q '^Other ' "$T/pool/projects.conf"
}

t_add_moves_a_folder_from_elsewhere_with_its_claude_history() {
  local old_key new_key
  mkdir -p "$T/A/elsewhere"; git clone -q "$(second_remote side)" "$T/A/elsewhere/Side" 2>/dev/null
  old_key=$(printf '%s' "$(cd "$T/A/elsewhere/Side" && pwd)" | sed 's#[^A-Za-z0-9]#-#g')
  mkdir -p "$T/A/.claude/projects/$old_key/memory"; echo note > "$T/A/.claude/projects/$old_key/memory/m.md"
  on A add "$T/A/elsewhere/Side"   # no terminal: confirm takes its default (yes)
  check "not moved into the projects folder" [ -d "$T/A/dev/Side/.git" ] || return 1
  check "not added" grep -q '^Side ' "$T/pool/projects.conf" || return 1
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
  check "no digest written" [ -f "$T/pool/sessions/A/App.txt" ] || return 1
  check "secret reached the pool" not grep -q 'abcdefghijklmnop' "$T/pool/sessions/A/App.txt" || return 1
  check "prompt missing in digest" grep -q '^prompt=s-two' "$T/pool/sessions/A/App.txt" || return 1
  on B sessions App
  case $OUT in *"Fix the login"*) ;; *) fail "B doesn't see A's session"; return 1 ;; esac
  case $OUT in *"this Mac"*) fail "A's session credited to B"; return 1 ;; esac
}

t_digest_level_0_shares_nothing() {
  claude_fixture A s-three
  printf 'session_digest = 0\n' >> "$T/pool/settings"
  on A park
  check "digest written despite session_digest = 0" [ ! -f "$T/pool/sessions/A/App.txt" ]
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
  for w in 80 120; do
    OUT=$(HOME="$T/A" ROAM_POOL="$T/pool" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" \
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

t_app_starts_and_quits_cleanly() {
  local p
  ( sleep 2; printf 'j'; sleep 0.5; printf '?'; sleep 0.5; printf 'x'; sleep 0.5; printf 'Q'; sleep 2 ) |
    HOME="$T/A" ROAM_POOL="$T/pool" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" ROAM_NO_ANIM=1 \
    script -q "$T/pty" "$ROOT/roam" >/dev/null 2>&1 &
  p=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 1; kill -0 $p 2>/dev/null || break; done
  if kill -0 $p 2>/dev/null; then kill $p; fail "roam didn't quit on Q"; return 1; fi
  OUT=$(LC_ALL=C grep -a -c $'\033\\[?1049l' "$T/pty")
  check "terminal not restored (alternate screen still on)" [ "$OUT" -ge 1 ] || return 1
  OUT=$(LC_ALL=C grep -a -o 'unbound variable\|syntax error\|command not found' "$T/pty" | head -3)
  check "errors on screen: $OUT" [ -z "$OUT" ]
}

t_app_parks_live_and_comes_back() {
  local p
  echo "changed in the app" > "$T/A/dev/App/a.txt"
  ( sleep 2; printf 'p'; sleep 6; printf '\r'; sleep 1; printf 'Q'; sleep 2 ) |
    HOME="$T/A" ROAM_POOL="$T/pool" ROAM_PROJECTS_DIR="$T/A/dev" ROAM_MAC=A ROAM_HOSTNAME=A ROAM_LOG="$T/A.log" ROAM_LOCK="$T/A.lock" \
    ROAM_NO_ANIM=1 script -q "$T/pty" "$ROOT/roam" >/dev/null 2>&1 &
  p=$!
  for _ in $(seq 20); do sleep 1; kill -0 $p 2>/dev/null || break; done
  if kill -0 $p 2>/dev/null; then kill $p; fail "roam didn't quit after parking"; return 1; fi
  check "nothing parked on the remote" git -C "$T/remote.git" rev-parse -q --verify refs/roam/A >/dev/null || return 1
  OUT=$(LC_ALL=C grep -a -c 'All parked' "$T/pty")
  check "no 'All parked' in the app" [ "$OUT" -ge 1 ]
}

# ---------------------------------------------------------------- run
printf '\n  roam tests %s(%s)%s\n\n' "$D" "$(/bin/bash -c 'echo $BASH_VERSION')" "$N"
for t in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do run "$t"; done
[ -n "$T" ] && [ -z "${KEEP:-}" ] && rm -rf "$T"
printf '\n  %d passed' "$PASS"; [ $FAIL -gt 0 ] && printf ', %s%d failed%s' "$R" "$FAIL" "$N"; echo; echo
[ $FAIL -eq 0 ]
