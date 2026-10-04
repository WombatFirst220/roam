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
