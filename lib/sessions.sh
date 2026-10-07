# roam — AI coding sessions per project: Claude Code and Codex, on this Mac and on the others.
#
# This Mac's sessions are read live from the tools' own files — only the tail of a transcript, never a
# whole 200 MB file. Every Mac also leaves a small digest per project in the pool, so the others can
# see where a session stopped even while it sleeps:
#   <pool>/sessions/<Mac>/<project>.txt   key=value lines, lists use tabs:
#   session=<tool>\t<id>\t<updated>\t<branch>\t<prompts>\t<live 0|1>\t<title>
#   recap= prompt= reply=<id>\t<text>   (session_digest = 2 only, secrets masked)
#   todo=<id>\t<status>\t<text>      file=<id>\t<path relative to the project>
# session_digest in the pool settings: 0 nothing, 1 titles, todos and files, 2 also the last prompt,
# reply and recap.
#
# A row, as the functions below pass them around (tabs):
#   mac  source(local|pool|digest)  tool  id  updated  branch  prompts  live  title  file

SESS_CACHE="$CACHE/sessions"
SESS_TOOLS="claude codex"

sess_jq() { command -v jq >/dev/null 2>&1; }
# jq: collapse to one line without control characters, cut to $n characters
SESS_DEFS='def clip($n): gsub("[[:cntrl:]]+"; " ") | gsub("^ +| +$"; "") | if length > $n then .[0:$n - 1] + "…" else . end;'

sess_icon() {  # $1 tool → colored mark
  case $1 in
    claude)   printf '\033[38;5;173m✻%s' "$C_RESET" ;;
    codex)    printf '\033[38;5;36m◇%s' "$C_RESET" ;;
    gemini)   printf '\033[38;5;75m✦%s' "$C_RESET" ;;
    copilot)  printf '\033[38;5;177m◈%s' "$C_RESET" ;;
    opencode) printf '\033[38;5;250m▣%s' "$C_RESET" ;;
    *)      printf '%s◦%s' "$C_MUTED" "$C_RESET" ;;
  esac
}
[ "$UI_FANCY" = 1 ] || sess_icon() { case $1 in claude) printf '*' ;; codex) printf '>' ;; gemini) printf '+' ;; copilot) printf '@' ;; opencode) printf '#' ;; *) printf '-' ;; esac; }
sess_name() { case $1 in claude) echo "Claude" ;; codex) echo "Codex" ;; gemini) echo "Gemini" ;; copilot) echo "Copilot" ;; opencode) echo "opencode" ;; *) echo "$1" ;; esac; }

sess_redact() {  # stdin → stdout, keys and passwords masked
  sed -E 's/(sk-ant-|sk-|gh[pousr]_|github_pat_|xox[abpr]-|glpat-)[A-Za-z0-9_-]{8,}/\1…/g
    s/AKIA[0-9A-Z]{16}/AKIA…/g
    s/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/eyJ…/g
    s/-----BEGIN [A-Z ]+-----/[key]/g
    s/((password|Password|PASSWORD|passwd|secret|Secret|SECRET|token|Token|TOKEN|api_key|apiKey|API_KEY|apikey)["'"'"' ]*[:=][ "'"'"']*)[^ "'"'"',;]+/\1…/g
    s/[A-Za-z0-9+=_-]{40,}/…/g'
}

# ---------------------------------------------------------------- Claude Code
sess_claude_live() {  # ids of running Claude Code sessions, one per line
  local f
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -f "$f" ] || continue
    sess_jq && jq -r 'select(.pid and .sessionId) | "\(.pid) \(.sessionId)"' "$f" 2>/dev/null
  done | while read -r pid id; do kill -0 "$pid" 2>/dev/null && echo "$id"; done
}

sess_claude_row() {  # $1 transcript → "claude id updated branch prompts title" (tabs), cached per size and date
  local f=$1 id key c title branch prompts
  id=$(basename "$f" .jsonl)
  key="$(stat -f '%m %z' "$f")"
  c="$SESS_CACHE/claude-$id.row"
  if [ -f "$c" ] && [ "$(head -1 "$c")" = "$key" ]; then sed -n 2p "$c"; return; fi
  # title: the newest ai-title, else a summary, else the last prompt
  title=$(grep -E '^\{"type":"(ai-title|summary|last-prompt)"' "$f" 2>/dev/null |
    { if sess_jq; then jq -rR "$SESS_DEFS"' fromjson? // empty | [.type, ((.aiTitle // .summary // .lastPrompt // "") | clip(80))] | @tsv'
      else sed -E 's/^\{"type":"([a-z-]+)".*"(aiTitle|summary|lastPrompt)":"([^"]{0,80}).*/\1	\3/'; fi } |
    awk -F'\t' '$2 != "" { t[$1] = $2 } END { print (t["ai-title"] != "" ? t["ai-title"] : t["summary"] != "" ? t["summary"] : t["last-prompt"]) }')
  branch=$(tail -n 50 "$f" | grep -o '"gitBranch":"[^"]*"' | tail -1 | cut -d'"' -f4)
  prompts=$(grep -c '"message":{"role":"user","content":"' "$f")
  mkdir -p "$SESS_CACHE"
  printf '%s\nclaude\t%s\t%s\t%s\t%s\t%s\n' "$key" "$id" "$(stat -f %m "$f")" "$branch" "$prompts" "${title:-(untitled)}" > "$c"
  sed -n 2p "$c"
}

sess_claude_rows() {  # $1 transcript folder, $2 mac, $3 source, $4 live ids → rows, newest first
  local d=$1 f row
  [ -d "$d" ] || return 0
  for f in $(ls -t "$d" 2>/dev/null | grep '\.jsonl$' | head -12); do
    f="$d/$f"
    [ "$(stat -f %b "$f")" -gt 0 ] || continue   # in the cloud only, not downloaded: don't pull it now
    is_placeholder "$f" && continue
    row=$(sess_claude_row "$f")
    printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$row" "$f" | awk -F'\t' -v OFS='\t' -v live=" $4 " '
      { l = index(live, " " $4 " ") ? 1 : 0; print $1, $2, $3, $4, $5, $6, $7, l, $8, $9 }'
  done
}

# ---------------------------------------------------------------- Codex
sess_codex_db() { ls -t "$HOME"/.codex/state_*.sqlite 2>/dev/null | head -1; }

sess_codex_rows() {  # $1 project path, $2 mac → rows, newest first (threads table in Codex's own database)
  # no empty fields: read with IFS=tab would merge them
  local db p imported="[]"
  db=$(sess_codex_db); [ -n "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  p=$(printf '%s' "$1" | sed "s/'/''/g")
  # Codex imports Claude Code sessions as threads of its own — they'd show up twice
  sess_jq && [ -f "$HOME/.codex/external_agent_session_imports.json" ] &&
    imported=$(jq -c '[.records[]?.imported_thread_id // empty]' "$HOME/.codex/external_agent_session_imports.json" 2>/dev/null | sed "s/'/''/g")
  sqlite3 -readonly -separator "$TAB" "$db" "
    select '$2', 'local', 'codex', id, updated_at, coalesce(nullif(git_branch, ''), '-'), '-', 0,
           replace(replace(substr(coalesce(nullif(name, ''), nullif(title, ''), nullif(first_user_message, ''), '(untitled)'), 1, 80), char(10), ' '), char(9), ' '),
           coalesce(nullif(rollout_path, ''), '-')
    from threads
    where cwd = '$p' and archived = 0 and source not like '{%' and agent_role is null
      and id not in (select value from json_each('${imported:-[]}'))
    order by updated_at desc limit 12" 2>/dev/null |
    while IFS="$TAB" read -r mac src tool id upd br n live title file; do
      # a rollout written to in the last two minutes: Codex is working on it
      [ -f "$file" ] && [ $(( $(date +%s) - $(stat -f %m "$file") )) -lt 120 ] && live=1
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mac" "$src" "$tool" "$id" "$upd" "$br" "$n" "$live" "$(printf '%s' "$title" | tr -d '\000-\037')" "$file"
    done
}

# ---------------------------------------------------------------- Gemini CLI, GitHub Copilot CLI, opencode
# Gemini CLI: ${GEMINI_CLI_HOME:-~}/.gemini/tmp/<slug>/.project_root holds the project's path (older versions:
#   the folder is the sha256 of the path); chats/session-*.jsonl — a header {sessionId, kind}, messages
#   {id, type user|gemini|info|error|warning, content, toolCalls[]}, written again in full under the same id
#   on every change, {"$set": …} updates (summary and memoryScratchpad arrive late, if at all; a $set of
#   messages is a checkpoint) and {"$rewindTo": id}. Older: one session-*.json, beside its .jsonl once resumed.
# Copilot CLI: ${COPILOT_HOME:-~/.copilot}/session-state/<id>/workspace.yaml (id, cwd, branch, name or summary)
#   and events.jsonl — {type user.message|assistant.message|tool.execution_start, timestamp, agentId (only
#   for sub-agents, whose events land in the same file), data}; todos in <id>/session.db, older: plan.md.
# opencode: ${XDG_DATA_HOME:-~/.local/share}/opencode/opencode.db (or $OPENCODE_DB). 2.x: session_v2
#   (directory, title or null, parent_id for subagents, time_updated in ms) and session_message (type user|
#   assistant|shell|compaction|…, data JSON; assistant content[] of {type text|reasoning|tool}). 1.x: session,
#   message, part, todo — an upgraded database keeps those next to the copies in session_v2, so they count
#   only where session_v2 is missing.

# jq: the text of a Gemini "content" (a string, a part {text} or a list of parts)
SESS_GEM_TEXT='def gtext: if type == "string" then . elif type == "array" then (map(if type == "string" then . else (.text // "") end) | join(" ")) elif type == "object" then (.text // "") else "" end;'
# jq: Gemini's records replayed the way Gemini reads them → {meta, msgs} (the last version of each message, in order)
SESS_GEM_REPLAY='def gadd($mm): (if .x[$mm.id] == null then .o += [$mm.id] else . end) | .x[$mm.id] = $mm;
def greplay: reduce .[] as $r ({m: {}, o: [], x: {}};
  if ($r | type) != "object" then .
  elif $r | has("$set") then
    (if ($r["$set"].messages | type) == "array" then .o = [] | .x = {} | reduce $r["$set"].messages[] as $mm (.; gadd($mm)) else . end)
    | .m += ($r["$set"] | del(.messages))
  elif $r | has("$rewindTo") then
    (.o | index([$r["$rewindTo"]])) as $i | .o = (if $i == null then [] else .o[:$i] end)
    | .o as $o | .x |= with_entries(select(.key | IN($o[])))
  elif ($r.id | type) == "string" then gadd($r)
  elif $r | has("sessionId") then .m += $r
  else . end) | {meta: .m, msgs: [.o[] as $k | .x[$k]]};'

sess_row_cached() {  # $1 tool, $2 cache id, $3 file, then a command that prints the row → the row, cached per size and date
  local tool=$1 id=$2 f=$3 key c
  shift 3
  key="$(stat -f '%m %z' "$f" 2>/dev/null)"
  c="$SESS_CACHE/$tool-$id.row"
  if [ -f "$c" ] && [ "$(head -1 "$c")" = "$key" ]; then sed -n 2p "$c"; return; fi
  mkdir -p "$SESS_CACHE"
  { echo "$key"; "$@"; } > "$c"
  sed -n 2p "$c"
}

sess_gemini_dirs() {  # $1 project path → Gemini's folders for it
  local d hash
  hash=$(printf '%s' "$1" | shasum -a 256 | cut -c1-64)
  # ~/.cache/.gemini: where Gemini keeps them when it runs in the macOS sandbox
  for d in "${GEMINI_CLI_HOME:-$HOME}"/.gemini/tmp/*/ "${GEMINI_CLI_HOME:-$HOME}"/.cache/.gemini/tmp/*/; do
    d=${d%/}
    if [ "$(cat "$d/.project_root" 2>/dev/null)" = "$1" ] || [ "${d##*/}" = "$hash" ]; then echo "$d"; fi
  done
}

sess_gemini_records() {  # $1 file → its records as JSON lines; an old .json becomes its messages plus a {"$set": header}
  if [ "${1%.jsonl}" != "$1" ]; then
    # whole, as Gemini reads it; a giant file: the header and the recent end
    if [ "$(stat -f %z "$1")" -lt 20000000 ]; then cat "$1"; else head -1 "$1"; tail -n 5000 "$1"; fi
  else jq -c '(.messages[]?), {"$set": del(.messages)}' "$1" 2>/dev/null; fi
}

sess_gemini_row1() {  # $1 file → "gemini id updated - prompts title" (tabs); nothing for subagents
  sess_gemini_records "$1" |
    jq -rRs "$SESS_DEFS $SESS_GEM_TEXT $SESS_GEM_REPLAY"' [split("\n")[] | fromjson? // empty] | greplay | .meta as $m |
      select(($m.kind // "main") != "subagent") |
      [.msgs[] | select(.type == "user")] as $u |
      ["gemini", ($m.sessionId // "-"), "", "-", ($u | length | tostring),
       ((($m.summary // "") | clip(80)) as $s | if $s != "" then $s else (($u | first // {}) .content | gtext | clip(80)) end)] | @tsv' 2>/dev/null
}

sess_gemini_rows() {  # $1 project path, $2 mac → rows, newest first
  local d f row now
  sess_jq || return 0
  now=$(date +%s)
  for d in $(sess_gemini_dirs "$1"); do
    for f in $(ls -t "$d/chats" 2>/dev/null | grep -E '\.jsonl?$' | head -12); do
      f="$d/chats/$f"
      [ "${f%.json}" != "$f" ] && [ -f "${f}l" ] && continue   # an old .json that was resumed: its .jsonl carries on
      row=$(sess_row_cached gemini "$(basename "$f")" "$f" sess_gemini_row1 "$f")
      [ -n "$row" ] || continue
      printf '%s\t%s\n' "$row" "$f" | awk -F'\t' -v OFS='\t' -v m="$2" -v up="$(stat -f %m "$f")" -v now="$now" \
        '{ t = $6 == "" ? "(untitled)" : $6; print m, "local", $1, $2, up, $4, $5, (now - up < 120 ? 1 : 0), t, $7 }'
    done
  done
}

sess_yaml() {  # $1 key, $2 file → its top-level value: plain, quoted, or the first line of a | or > block
  awk -v k="$1" 'index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^ +/, "", v)
    if (v ~ /^[|>]/) { getline; sub(/^ +/, ""); v = $0 } else if (v ~ /^["\047]/) { v = substr(v, 2); sub(/["\047] *$/, "", v) }
    print v; exit }' "$2" | tr -d '\000-\037'
}

sess_copilot_rows() {  # $1 project path, $2 mac → rows, newest first
  local d w f id title branch now up n
  now=$(date +%s)
  for d in $(ls -td "${COPILOT_HOME:-$HOME/.copilot}"/session-state/*/ 2>/dev/null | head -60); do
    d=${d%/}; w="$d/workspace.yaml"; f="$d/events.jsonl"
    [ -f "$w" ] && [ -f "$f" ] || continue
    [ "$(sess_yaml cwd "$w")" = "$1" ] || continue
    id=$(sess_yaml id "$w"); id=${id:-${d##*/}}
    branch=$(sess_yaml branch "$w")
    title=$(sess_yaml name "$w"); [ -n "$title" ] || title=$(sess_yaml summary "$w")
    title=$(printf '%s' "$title" | cut -c1-80)
    # prompts: the user's own — sub-agents' messages carry an agentId
    up=$(stat -f %m "$f"); n=$(grep '"type":"user.message"' "$f" | grep -v -c '"agentId":')
    printf '%s\tlocal\tcopilot\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$id" "$up" "${branch:--}" "$n" \
      "$([ $((now - up)) -lt 120 ] && echo 1 || echo 0)" "${title:-(untitled)}" "$f"
  done | sort -t"$TAB" -k5,5nr | head -12
}

sess_opencode_db() {  # → opencode's database
  local d="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
  case ${OPENCODE_DB:-} in /*) echo "$OPENCODE_DB"; return ;; ?*) echo "$d/$OPENCODE_DB"; return ;; esac
  if [ -f "$d/opencode.db" ]; then echo "$d/opencode.db"; else ls -t "$d"/opencode-*.db 2>/dev/null | head -1; fi
}

sess_opencode_v2() { [ -n "$(sqlite3 -readonly "$1" "select 1 from sqlite_master where name = 'session_v2'" 2>/dev/null)" ]; }

sess_opencode_rows() {  # $1 project path, $2 mac → rows, newest first
  local db p
  db=$(sess_opencode_db); [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  p=$(printf '%s' "$1" | sed "s/'/''/g")
  if sess_opencode_v2 "$db"; then
    # an untitled session (no model reached yet, or an old fallback title) goes by its first prompt
    sqlite3 -readonly -separator "$TAB" "$db" "
      select '$2', 'local', 'opencode', s.id, s.time_updated / 1000, '-',
             (select count(*) from session_message m where m.session_id = s.id and m.type = 'user'),
             case when (strftime('%s', 'now') - s.time_updated / 1000) < 120 then 1 else 0 end,
             replace(replace(replace(substr(coalesce(
               case when s.title glob 'New session - *' then null else nullif(s.title, '') end,
               (select nullif(trim(json_extract(m.data, '$.text')), '') from session_message m
                  where m.session_id = s.id and m.type = 'user' order by m.seq limit 1),
               '(untitled)'), 1, 80), char(10), ' '), char(13), ' '), char(9), ' '),
             '$db'
      from session_v2 s
      where (s.directory = '$p' or s.directory like '$p/%') and s.parent_id is null and s.time_archived is null
      order by s.time_updated desc limit 12" 2>/dev/null
  else
    sqlite3 -readonly -separator "$TAB" "$db" "
      select '$2', 'local', 'opencode', s.id, s.time_updated / 1000, '-',
             (select count(*) from message m where m.session_id = s.id and json_extract(m.data, '$.role') = 'user'),
             case when (strftime('%s', 'now') - s.time_updated / 1000) < 120 then 1 else 0 end,
             replace(replace(substr(coalesce(nullif(s.title, ''), '(untitled)'), 1, 80), char(10), ' '), char(9), ' '),
             '$db'
      from session s
      where s.directory = '$p' and s.parent_id is null and s.time_archived is null
      order by s.time_updated desc limit 12" 2>/dev/null
  fi
}

# last state → lines "recap|prompt|reply\t<text>", "todo\t<status>\t<text>", "file\t<path>"
sess_gemini_state() {  # $1 file, $2 project path
  sess_jq || return 0
  sess_gemini_records "$1" |
    jq -rRs "$SESS_DEFS $SESS_GEM_TEXT $SESS_GEM_REPLAY"' [split("\n")[] | fromjson? // empty] | greplay | .meta as $m | .msgs as $r |
      ([$r[] | select(.type == "gemini") | .toolCalls[]?]) as $tc |
      ([$tc[] | select(.name == "write_todos") | .args.todos] | last // []) as $todos |
      ( ($m.memoryScratchpad.workflowSummary // empty | "recap\t" + clip(300)),
        ([$r[] | select(.type == "user") | .content | gtext | select(length > 0)] | last // empty | "prompt\t" + clip(300)),
        ([$r[] | select(.type == "gemini") | .content | gtext | select(length > 0)] | last // empty | "reply\t" + clip(500)),
        ($todos[]? | "todo\t\(.status // "pending")\t\((.description // .content // "") | clip(90))"),
        (([$m.memoryScratchpad.touchedPaths[]?] +
          [$tc[] | select(.name != "write_todos" and (.name | test("write|replace|edit"; "i"))) | (.args.file_path // .args.path // empty)])
          | unique[] | "file\t" + .) )' 2>/dev/null | sed "s#	$2/#	#" | head -40
}

# jq: a Copilot tool call's arguments (an object, JSON text, or apply_patch's bare patch) → the files it changes
SESS_COP_FILES='def cargs: if type == "string" then (fromjson? // {patch: .}) elif type == "object" then . else {} end;
def cfiles: cargs | ((.path // .file_path // .filePath // empty),
  ((.patch // .input // "") | strings | scan("\\*\\*\\* (?:Add|Update|Delete) File: ([^\\n]+)") | .[0]));'

sess_copilot_state() {  # $1 events.jsonl, $2 project path
  local f=$1 d plan
  sess_jq || return 0
  d=$(dirname "$f")
  tail -n 3000 "$f" | grep -E '"type":"(user\.message|assistant\.message|tool\.execution_start)"' |
    jq -rRs "$SESS_DEFS $SESS_COP_FILES"' [split("\n")[] | fromjson? // empty] as $r |
      ( ([$r[] | select(.type == "user.message" and .agentId == null and .data.isAutopilotContinuation != true)
          | (.data.content // .data.transformedContent // "") | select(length > 0)] | last // empty | "prompt\t" + clip(300)),
        ([$r[] | select(.type == "assistant.message" and .agentId == null) | (.data.content // "") | strings | select(length > 0)] | last // empty | "reply\t" + clip(500)),
        ([$r[] | select(.type == "tool.execution_start" and ((.data.toolName // "") | test("edit|create|write|str_replace|patch"; "i")))
          | .data.arguments | cfiles] | unique[] | "file\t" + .) )' 2>/dev/null |
    sed "s#	$2/#	#"
  # todos: the session's own database; older versions kept them as checkboxes in plan.md
  if [ -f "$d/session.db" ] && command -v sqlite3 >/dev/null 2>&1 &&
     [ -n "$(sqlite3 -readonly "$d/session.db" "select 1 from sqlite_master where name = 'todos'" 2>/dev/null)" ]; then
    sqlite3 -readonly -separator "$TAB" "$d/session.db" "
      select 'todo', case status when 'done' then 'completed' else coalesce(status, 'pending') end, substr(replace(title, char(10), ' '), 1, 90)
      from todos order by created_at, rowid limit 12" 2>/dev/null
    return 0
  fi
  plan="$d/plan.md"
  [ -f "$plan" ] && sed -n -E 's/^[[:space:]]*[-*] \[([ xX])\] (.*)$/\1	\2/p' "$plan" | head -12 |
    awk -F'\t' '{ printf "todo\t%s\t%s\n", ($1 == " " ? "pending" : "completed"), substr($2, 1, 90) }'
  return 0
}

sess_opencode_state() {  # $1 db, $2 project path, $3 session id
  local db=$1 id
  id=$(printf '%s' "$3" | sed "s/'/''/g")
  command -v sqlite3 >/dev/null 2>&1 || return 0
  if sess_opencode_v2 "$db"; then
    # 2.x has no todo list any more; a session migrated from 1.x still carries its last todowrite call
    sqlite3 -readonly -separator "$TAB" "$db" "
      select 'recap', replace(replace(substr(json_extract(data, '$.summary'), 1, 300), char(10), ' '), char(9), ' ')
        from session_message where session_id = '$id' and type = 'compaction' and json_extract(data, '$.status') = 'completed'
        order by seq desc limit 1;
      select 'prompt', replace(replace(substr(json_extract(data, '$.text'), 1, 300), char(10), ' '), char(9), ' ')
        from session_message where session_id = '$id' and type = 'user' order by seq desc limit 1;
      select 'reply', replace(replace(substr(json_extract(c.value, '$.text'), 1, 500), char(10), ' '), char(9), ' ')
        from session_message m, json_each(m.data, '$.content') c
        where m.session_id = '$id' and m.type = 'assistant' and json_extract(c.value, '$.type') = 'text'
          and trim(coalesce(json_extract(c.value, '$.text'), '')) != ''
        order by m.seq desc, c.key desc limit 1;
      select 'todo', coalesce(json_extract(t.value, '$.status'), 'pending'), substr(replace(json_extract(t.value, '$.content'), char(10), ' '), 1, 90)
        from json_each((select json_extract(c.value, '$.state.input.todos') from session_message m, json_each(m.data, '$.content') c
          where m.session_id = '$id' and m.type = 'assistant' and json_extract(c.value, '$.type') = 'tool' and json_extract(c.value, '$.name') = 'todowrite'
          order by m.seq desc, c.key desc limit 1)) t limit 12;
      select 'file', f from (
        select coalesce(json_extract(c.value, '$.state.input.path'), json_extract(c.value, '$.state.input.filePath')) f
          from session_message m, json_each(m.data, '$.content') c
          where m.session_id = '$id' and m.type = 'assistant' and json_extract(c.value, '$.type') = 'tool'
            and json_extract(c.value, '$.name') in ('edit', 'write', 'multiedit')
        union
        select s.value from session_message m, json_each(m.data, '$.snapshot.files') s
          where m.session_id = '$id' and m.type = 'assistant')
        where f is not null limit 15;" 2>/dev/null | sed "s#	$2/#	#"
    return 0
  fi
  sqlite3 -readonly -separator "$TAB" "$db" "
    select 'prompt', replace(replace(substr(json_extract(p.data, '$.text'), 1, 300), char(10), ' '), char(9), ' ')
      from part p join message m on m.id = p.message_id
      where p.session_id = '$id' and json_extract(m.data, '$.role') = 'user' and json_extract(p.data, '$.type') = 'text'
        and coalesce(json_extract(p.data, '$.synthetic'), 0) = 0
      order by p.time_created desc limit 1;
    select 'reply', replace(replace(substr(json_extract(p.data, '$.text'), 1, 500), char(10), ' '), char(9), ' ')
      from part p join message m on m.id = p.message_id
      where p.session_id = '$id' and json_extract(m.data, '$.role') = 'assistant' and json_extract(p.data, '$.type') = 'text'
      order by p.time_created desc limit 1;
    select 'todo', status, substr(replace(content, char(10), ' '), 1, 90) from todo where session_id = '$id' order by position limit 12;
    select distinct 'file', json_extract(data, '$.state.input.filePath') from part
      where session_id = '$id' and json_extract(data, '$.type') = 'tool' and json_extract(data, '$.tool') in ('edit', 'write', 'patch', 'multiedit')
        and json_extract(data, '$.state.input.filePath') is not null
      limit 15;" 2>/dev/null | sed "s#	$2/#	#"
}

# transcripts as Markdown (same "\001speaker\001time" blocks as Claude and Codex)
sess_gemini_md() {  # $1 file
  sess_gemini_records "$1" |
    jq -rRs "$SESS_DEFS $SESS_GEM_TEXT $SESS_GEM_REPLAY"' [split("\n")[] | fromjson? // empty] | greplay | .msgs[] |
      select(.type == "user" or .type == "gemini") |
      (try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | localtime | strftime("%d.%m. %H:%M")) catch "") as $t |
      if .type == "user" then (.content | gtext) as $x | select($x != "") | "\u0001you\u0001\($t)\n\($x)"
      else
        ((.content | gtext) as $x | select($x != "") | "\u0001gemini\u0001\($t)\n\($x)"),
        (.toolCalls[]? | ((.args.file_path // .args.path // .args.dir_path // .args.command // .args.pattern // "") | tostring | clip(90) | gsub("`"; "'"'"'")) as $a |
          "\u0001gemini\u0001\($t)\n- ⚙ **\(.displayName // .name)**" + (if $a == "" then "" else " `\($a)`" end))
      end' 2>/dev/null | sess_md_group
}

sess_copilot_md() {  # $1 events.jsonl — the main agent's conversation; sub-agents show by their tool calls
  tail -n 3000 "$1" | grep -E '"type":"(user\.message|assistant\.message|tool\.execution_start)"' |
    jq -rR "$SESS_DEFS $SESS_COP_FILES"' fromjson? // empty |
      (try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | localtime | strftime("%d.%m. %H:%M")) catch "") as $t |
      if .type == "user.message" then select(.agentId == null) | (.data.content // .data.transformedContent // "") as $x | select($x != "") | "\u0001you\u0001\($t)\n\($x)"
      elif .type == "assistant.message" then select(.agentId == null) | (.data.content // "") | strings | select(. != "") | "\u0001copilot\u0001\($t)\n\(.)"
      else (.data.arguments | cargs | (.path // .command // .pattern // ([cfiles] | join(", ")) // "") | tostring | clip(90) | gsub("`"; "'"'"'")) as $a |
        "\u0001copilot\u0001\($t)\n- ⚙ **\(.data.toolName // "tool")**" + (if $a == "" then "" else " `\($a)`" end)
      end' 2>/dev/null | sess_md_group
}

sess_opencode_md() {  # $1 db, $2 session id
  local id
  id=$(printf '%s' "$2" | sed "s/'/''/g")
  if sess_opencode_v2 "$1"; then
    sqlite3 -readonly "$1" "
      select json_object('type', type, 'time', time_created / 1000, 'data', json(data))
      from session_message where session_id = '$id' order by seq" 2>/dev/null |
      jq -rR "$SESS_DEFS"' fromjson? // empty | (.time | localtime | strftime("%d.%m. %H:%M")) as $t | .data as $d |
        if .type == "user" then ($d.text // "") as $x | select($x != "") | "\u0001you\u0001\($t)\n\($x)"
        elif .type == "shell" then "\u0001you\u0001\($t)\n- ⚙ **shell** `\($d.command // "" | tostring | clip(90) | gsub("`"; "'"'"'"))`"
        elif .type == "assistant" then $d.content[]? |
          if .type == "text" and ((.text // "") != "") then "\u0001opencode\u0001\($t)\n\(.text)"
          elif .type == "tool" then (.state.input | if type == "object" then (.path // .filePath // .command // .pattern // .description // "") else "" end
              | tostring | clip(90) | gsub("`"; "'"'"'")) as $a |
            "\u0001opencode\u0001\($t)\n- ⚙ **\(.name)**" + (if $a == "" then "" else " `\($a)`" end)
          else empty end
        else empty end' 2>/dev/null | sess_md_group
    return
  fi
  sqlite3 -readonly "$1" "
    select json_object('role', json_extract(m.data, '$.role'), 'time', p.time_created / 1000, 'part', json(p.data))
    from part p join message m on m.id = p.message_id
    where p.session_id = '$id' order by p.time_created, p.id" 2>/dev/null |
    jq -rR "$SESS_DEFS"' fromjson? // empty | (.time | localtime | strftime("%d.%m. %H:%M")) as $t |
      (if .role == "user" then "you" else "opencode" end) as $who | .part |
      if .type == "text" and (.synthetic | not) and ((.text // "") != "") then "\u0001\($who)\u0001\($t)\n\(.text)"
      elif .type == "tool" then ((.state.input.filePath // .state.input.command // .state.input.pattern // "") | tostring | clip(90) | gsub("`"; "'"'"'")) as $a |
        "\u0001\($who)\u0001\($t)\n- ⚙ **\(.tool)**" + (if $a == "" then "" else " `\($a)`" end)
      else empty end' 2>/dev/null | sess_md_group
}

sess_other_rows() {  # $1 project path → this Mac's Gemini CLI, Copilot CLI and opencode sessions
  sess_gemini_rows "$1" "$MAC"; sess_copilot_rows "$1" "$MAC"; sess_opencode_rows "$1" "$MAC"
}

# ---------------------------------------------------------------- all sessions of a project
sess_digest_rows() {  # $1 project → rows from the other Macs' digests
  local f m
  for f in "$POOL"/sessions/*/"$1.txt"; do
    [ -f "$f" ] || continue
    m=$(basename "$(dirname "$f")")
    [ "$m" = "$MAC" ] && continue
    sed -n "s/^session=//p" "$f" | awk -F'\t' -v OFS='\t' -v m="$m" '{ print m, "digest", $1, $2, $3, $4, $5, $6, $7, "" }'
  done
}

sess_rows() {  # $1 name, $2 path → every session of the project, newest first, one row per session
  local live
  live=$(sess_claude_live | tr '\n' ' ')
  {
    sess_claude_rows "$HOME/.claude/projects/$(claude_key "$2")" "$MAC" local "$live"
    [ "$CLAUDE_HISTORY" = 1 ] && sess_claude_rows "$CLAUDE_STORE/$1" "" pool "$live"
    sess_codex_rows "$2" "$MAC"
    sess_other_rows "$2"
    sess_digest_rows "$1"
  } | sort -t"$TAB" -k5,5nr | awk -F'\t' -v OFS='\t' '
    # One session, several sources: keep the readable file (local before pool), but credit the Mac whose
    # digest lists it at least as new — a transcript that came through the pool was written there.
    { k = $3 SUBSEP $4 }
    !(k in row) { order[++n] = k; row[k] = $0; src[k] = $2; mac[k] = $1; upd[k] = $5; if ($2 == "digest") claimed[k] = 1; next }
    $2 == "digest" { if ($5 >= upd[k]) { mac[k] = $1; claimed[k] = 1 }; next }
    src[k] == "digest" { row[k] = $0; src[k] = $2; next }
    $2 == "local" && src[k] == "pool" { row[k] = $0; src[k] = "local"; if (!claimed[k]) mac[k] = $1 }
    END { for (i = 1; i <= n; i++) { k = order[i]; split(row[k], f, "\t"); f[1] = mac[k]
            for (j = 1; j <= 10; j++) if (f[j] == "") f[j] = "-"   # read with IFS=tab would merge empty fields
            print f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10] } }'
}

# ---------------------------------------------------------------- last state of one session
# → lines "recap|prompt|reply\t<text>", "todo\t<status>\t<text>", "file\t<path>"

sess_claude_state() {  # $1 transcript, $2 project path
  local f=$1 win
  sess_jq || return 0
  win=$(mktemp) || return
  tail -n 3000 "$f" > "$win"
  grep -F '"subtype":"away_summary"' "$win" | tail -1 | jq -rR "$SESS_DEFS"' fromjson? // empty | "recap\t" + (.content // "" | clip(300))'
  { grep -F '"message":{"role":"user","content":"' "$win" | grep -vF '"isMeta":true' | grep -vF '"isSidechain":true' | grep -vF '"isCompactSummary":true' |
      jq -rR "$SESS_DEFS"' fromjson? // empty | .message.content | select(type == "string" and (startswith("<") | not) and length > 0) | "prompt\t" + clip(300)'
  } | tail -1
  grep -F '"type":"assistant"' "$win" | grep -F '"type":"text"' | grep -vF '"isSidechain":true' | tail -1 |
    jq -rR "$SESS_DEFS"' fromjson? // empty | "reply\t" + ([.message.content[]? | select(.type == "text") | .text] | join(" ") | clip(500))'
  grep -F '"name":"TodoWrite"' "$win" | tail -1 |
    jq -rR "$SESS_DEFS"' fromjson? // empty | .message.content[]? | select(.type == "tool_use" and .name == "TodoWrite") | .input.todos[]? | "todo\t\(.status)\t\(.content | clip(90))"' | head -12
  grep -E '"name":"(Edit|Write|MultiEdit|NotebookEdit)"' "$win" |
    jq -rR 'fromjson? // empty | .message.content[]? | select(.type == "tool_use") | .input.file_path // .input.notebook_path // empty' |
    sed "s#^$2/##; s#^$HOME/#~/#" | awk '!seen[$0]++' | tail -15 | sed 's/^/file	/'
  rm -f "$win"
}

sess_codex_state() {  # $1 rollout, $2 project path — the last 8 MB are plenty (lines with images are huge)
  local f=$1 win
  sess_jq && [ -f "$f" ] || return 0
  win=$(mktemp) || return
  tail -c 8000000 "$f" | tail -n +2 | grep -E '"type":"(user_message|agent_message|task_complete|item_completed|function_call|patch_apply_end)"' > "$win"
  if grep -qF '"type":"user_message"' "$win"; then
    grep -F '"type":"user_message"' "$win" | tail -1 | jq -rR "$SESS_DEFS"' fromjson? // empty | "prompt\t" + (.payload.message // "" | clip(300))'
  else
    grep -F '"type":"UserMessage"' "$win" | tail -1 |
      jq -rR "$SESS_DEFS"' fromjson? // empty | "prompt\t" + ([.payload.item.content[]? | .text // empty] | join(" ") | clip(300))'
  fi
  { grep -F '"type":"task_complete"' "$win" | tail -1 | jq -rR "$SESS_DEFS"' fromjson? // empty | (.payload.last_agent_message // empty) | "reply\t" + clip(500)'
    grep -F '"type":"AgentMessage"' "$win" | tail -1 | jq -rR "$SESS_DEFS"' fromjson? // empty | "reply\t" + ([.payload.item.content[]? | .text // empty] | join(" ") | clip(500))'
  } | head -1
  grep -F '"update_plan"' "$win" | tail -1 |
    jq -rR "$SESS_DEFS"' fromjson? // empty | .payload | select(.type == "function_call") | .arguments | fromjson? // {} | .plan[]? | "todo\t\(.status)\t\(.step | clip(90))"' | head -12
  grep -E '"(FileChange|patch_apply_end)"' "$win" | jq -rR 'fromjson? // empty | .payload | (.item.changes // .changes // {}) | keys[]' 2>/dev/null |
    sed "s#^$2/##; s#^$HOME/#~/#" | awk '!seen[$0]++' | tail -15 | sed 's/^/file	/'
  rm -f "$win"
}

sess_state() {  # $1 row, $2 project path, $3 project name → state lines; another Mac's session from its digest
  local mac src tool id upd br n live title file
  IFS="$TAB" read -r mac src tool id upd br n live title file <<EOF
$1
EOF
  if [ "$file" != - ] && [ -f "$file" ]; then
    case $tool in
      claude) sess_claude_state "$file" "$2" ;; codex) sess_codex_state "$file" "$2" ;; gemini) sess_gemini_state "$file" "$2" ;;
      copilot) sess_copilot_state "$file" "$2" ;; opencode) sess_opencode_state "$file" "$2" "$id" ;;
    esac
  elif [ "$mac" != - ]; then
    grep -E "^(recap|prompt|reply|todo|file)=$id$TAB" "$POOL/sessions/$mac/$3.txt" 2>/dev/null | sed "s/=$id$TAB/$TAB/"
  fi
}

# ---------------------------------------------------------------- digest in the pool
sess_digest_write() {  # $1 name, $2 path — this Mac's newest sessions for the others; cheap when nothing changed
  local level=${SESSION_DIGEST:-2} dir="$POOL/sessions/$MAC" out stamp stampf rows n=0 row id
  [ "$level" = 0 ] && { rm -f "$dir/$1.txt"; return 0; }
  [ -d "$2/.git" ] || return 0
  rows=$(sess_rows_local "$1" "$2")
  stamp="$level $(printf '%s\n' "$rows" | cut -f3-6 | head -8 | cksum)"
  stampf="$SESS_CACHE/$1.stamp"
  [ -f "$dir/$1.txt" ] && [ "$(cat "$stampf" 2>/dev/null)" = "$stamp" ] && return 0
  mkdir -p "$dir" "$SESS_CACHE" || return 0
  out=$(mktemp)
  {
    echo "v=1"; echo "mac=$MAC"; echo "written=$(date +%s)"; echo "roam=$ROAM_VERSION"
    printf '%s\n' "$rows" | head -8 | awk -F'\t' -v OFS='\t' 'NF { print "session=" $3, $4, $5, $6, $7, $8, $9 }'
    printf '%s\n' "$rows" | head -3 | while IFS= read -r row; do
      [ -n "$row" ] || continue
      id=$(printf '%s' "$row" | cut -f4)
      sess_state "$row" "$2" "$1" | while IFS="$TAB" read -r k a b; do
        case $k in
          todo) printf 'todo=%s\t%s\t%s\n' "$id" "$a" "$(printf '%s' "$b" | sess_redact)" ;;
          file) printf 'file=%s\t%s\n' "$id" "$a" ;;
          recap|prompt|reply) [ "$level" = 2 ] && printf '%s=%s\t%s\n' "$k" "$id" "$(printf '%s' "$a" | sess_redact)" ;;
        esac
      done
    done
  } | head -c 8192 > "$out"
  if cmp -s "$out" "$dir/$1.txt"; then rm -f "$out"; else pool_put "$out" "$dir/$1.txt"; fi
  printf '%s\n' "$stamp" > "$stampf"
}

sess_rows_local() {  # $1 name, $2 path → the sessions this Mac worked on (what its digest reports)
  local live f
  live=$(sess_claude_live | tr '\n' ' ')
  # Transcripts reach every Mac through the pool. One that another Mac's digest lists at least as new
  # was written there, not here.
  {
    for f in "$POOL"/sessions/*/"$1.txt"; do
      [ -f "$f" ] && [ "$f" != "$POOL/sessions/$MAC/$1.txt" ] && sed -n "s/^session=/O$TAB/p" "$f"
    done
    { sess_claude_rows "$HOME/.claude/projects/$(claude_key "$2")" "$MAC" local "$live"; sess_codex_rows "$2" "$MAC"; sess_other_rows "$2"; } |
      sort -t"$TAB" -k5,5nr | sed "s/^/R$TAB/"
  } | awk -F'\t' '
    $1 == "O" { if ($4 > other[$2 SUBSEP $3]) other[$2 SUBSEP $3] = $4; next }
    { k = $4 SUBSEP $5; if (!(k in other) || other[k] < $6) { $0 = substr($0, 3); for (j = 1; j <= 10; j++) if ($j == "") $j = "-"; print } }' OFS='\t'
}

# ---------------------------------------------------------------- transcript as Markdown
# One "\001speaker\001time" line before each block; awk turns speaker changes into headings.
sess_md_group() {
  awk '
    /^\001/ { split($0, a, "\001")
              if (a[2] == "-") { print "\n---\n*context compacted*\n"; prev = ""; next }
              if (a[2] != prev) { printf "\n#### ▌ %s · %s\n\n", a[2], a[3]; prev = a[2]; gap = 0; lasttool = 0 } else gap = 1
              next }
    { tool = ($0 ~ /^- ⚙/); if (gap && !(tool && lasttool)) print ""; gap = 0; print; if (NF) lasttool = tool }'
}

sess_claude_md() {  # $1 transcript → its last ~2500 lines as Markdown (tool calls one line each, no output)
  tail -n 2500 "$1" | grep -E '"type":"(user|assistant|system)"' | grep -vF '"isSidechain":true' |
    jq -rR "$SESS_DEFS"' fromjson? // empty |
      (try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | localtime | strftime("%d.%m. %H:%M")) catch "") as $t |
      if .type == "user" then
        .message.content | select(type == "string" and (startswith("<") | not)) | "\u0001you\u0001\($t)\n\(.)"
      elif .type == "assistant" then
        .message.content[]? |
        if .type == "text" then "\u0001claude\u0001\($t)\n\(.text)"
        elif .type == "tool_use" then
          ((.input.file_path // .input.command // .input.pattern // .input.description // .input.url // "") | tostring | clip(90) | gsub("`"; "'"'"'")) as $a |
          "\u0001claude\u0001\($t)\n- ⚙ **\(.name)**" + (if $a == "" then "" else " `\($a)`" end)
        else empty end
      elif .subtype == "compact_boundary" then "\u0001-\u0001\($t)"
      else empty end' 2>/dev/null | sess_md_group
}

sess_codex_md() {  # $1 rollout → the last ~20 MB as Markdown
  local flavor=item
  tail -c 20000000 "$1" | tail -n +2 | grep -qF '"type":"user_message"' && flavor=event
  tail -c 20000000 "$1" | tail -n +2 | grep -E '"type":"(user_message|agent_message|item_completed|function_call|custom_tool_call)"' |
    jq -rR --arg fl "$flavor" "$SESS_DEFS"' fromjson? // empty |
      (try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | localtime | strftime("%d.%m. %H:%M")) catch "") as $t | .payload as $p |
      if $fl == "event" and $p.type == "user_message" then "\u0001you\u0001\($t)\n\($p.message)"
      elif $fl == "event" and $p.type == "agent_message" then "\u0001codex\u0001\($t)\n\($p.message)"
      elif $fl == "item" and $p.type == "item_completed" and $p.item.type == "UserMessage" then
        "\u0001you\u0001\($t)\n" + ([$p.item.content[]? | .text // empty] | join("\n"))
      elif $fl == "item" and $p.type == "item_completed" and $p.item.type == "AgentMessage" then
        "\u0001codex\u0001\($t)\n" + ([$p.item.content[]? | .text // empty] | join("\n"))
      elif $p.type == "function_call" or $p.type == "custom_tool_call" then "\u0001codex\u0001\($t)\n- ⚙ **\($p.name)**"
      else empty end' 2>/dev/null | sess_md_group
}

sess_md() {  # $1 tool, $2 file, $3 id → the transcript as Markdown
  case $1 in
    claude) sess_claude_md "$2" ;; codex) sess_codex_md "$2" ;; gemini) sess_gemini_md "$2" ;;
    copilot) sess_copilot_md "$2" ;; opencode) sess_opencode_md "$2" "$3" ;;
  esac
}

# ---------------------------------------------------------------- commands
find_project() {  # $1 name or folder (any case, a unique prefix will do); empty: the project around $PWD → "name<TAB>dir"
  local q here root name dir remote extra hits
  q=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  here=$(pwd -P); root=$(cd "$PROJECTS_DIR" 2>/dev/null && pwd -P)
  if [ -z "$q" ]; then
    projects | while read -r name dir remote extra; do
      case "$here/" in "$root/$dir/"*) printf '%s\t%s\n' "$name" "$dir"; break ;; esac
    done
    return
  fi
  hits=$(projects | awk -v q="$q" '{ n = tolower($1); d = tolower($2) } n == q || d == q { print $1 "\t" $2; exit }')
  [ -n "$hits" ] || hits=$(projects | awk -v q="$q" '{ n = tolower($1); d = tolower($2) } index(n, q) == 1 || index(d, q) == 1 { print $1 "\t" $2 }')
  [ "$(printf '%s\n' "$hits" | grep -c .)" = 1 ] && printf '%s\n' "$hits"
}

pick_project() {  # $1 query, $2 prompt → sets P_NAME, P_DIR, P_PATH; asks on a terminal when it can't tell
  local hit n
  hit=$(find_project "$1")
  if [ -z "$hit" ] && [ -n "$1" ]; then say_err "no project matches '$1'"; return 1; fi
  if [ -z "$hit" ]; then
    [ -t 0 ] && [ -t 1 ] || { say_err "which project? roam ${CMD:-sessions} <project>"; return 1; }
    printf '\n  %s\n' "${2:-Which project?}"
    n=$(projects | awk '{print $1}' | choose) || return 1
    hit=$(projects | sed -n "${n}p" | awk '{print $1 "\t" $2}')
  fi
  P_NAME=$(printf '%s' "$hit" | cut -f1); P_DIR=$(printf '%s' "$hit" | cut -f2); P_PATH="$PROJECTS_DIR/$P_DIR"
}

sess_where() {  # $1 mac → "this Mac" / its name
  if [ "$1" = "$MAC" ]; then echo "this Mac"; elif [ -z "$1" ] || [ "$1" = - ]; then echo "another Mac"; else mac_label "$1"; fi
}

sess_line() {  # $1 row, $2 number (optional), $3 title width, $4 "short": only where and when → one line for a list
  local mac src tool id upd br n live title file meta
  IFS="$TAB" read -r mac src tool id upd br n live title file <<EOF
$1
EOF
  [ "$br" = - ] && br=""
  meta="$(sess_where "$mac") · $(ago "$upd")"
  if [ "${4:-}" = short ]; then
    [ "$live" = 1 ] && meta="$meta ${C_OK}●${C_RESET}"
  else
    meta="$meta${br:+ · $br}"
    [ "$n" != - ] && [ "$n" != 0 ] && meta="$meta · $n prompt$([ "$n" = 1 ] || echo s)"
    [ "$live" = 1 ] && meta="$meta · ${C_OK}● running${C_RESET}${C_MUTED}"
  fi
  printf '%s%s %s %s' "${2:+${C_MUTED}$(pad "$2" 3)${C_RESET}}" "$(sess_icon "$tool")" \
    "$(pad "${C_BOLD}$(trunc "$title" $(( ${3:-50} - 1 )))${C_RESET}" "${3:-50}")" "${C_MUTED}$meta${C_RESET}"
}

sess_show_state() {  # $1 row, $2 project path, $3 name → where the session stopped, indented
  local k a b todos="" files="" w icon tmp
  w=$(( $(ui_width) - 14 ))
  tmp=$(mktemp) || return
  sess_state "$1" "$2" "$3" > "$tmp" 2>/dev/null
  if [ ! -s "$tmp" ]; then
    case $(printf '%s' "$1" | cut -f2) in
      digest) say_info "    no details — that Mac shares titles only (session_digest = 1), or runs roam < 1.2" ;;
      *) sess_jq || say_info "    details need jq — macOS 15 has it, or: brew install jq" ;;
    esac
    rm -f "$tmp"; return
  fi
  while IFS="$TAB" read -r k a b; do
    case $k in
      recap)  printf '    %s %s\n' "$(pad "${C_ACCENT}recap${C_RESET}" 7)" "$(trunc "$a" $w)" ;;
      prompt) printf '    %s %s\n' "$(pad "${C_CYAN}you${C_RESET}" 7)" "$(trunc "$a" $w)" ;;
      reply)  printf '    %s %s\n' "$(pad "$(sess_icon "$(printf '%s' "$1" | cut -f3)") ${C_MUTED}ai${C_RESET}" 7)" \
                "$(printf '%s\n' "$a" | fold -s -w $w | head -4 | sed '2,$s/^/            /')" ;;
      todo)   case $a in completed) icon="${C_OK}✓${C_RESET}" ;; in_progress) icon="${C_WARN}◐${C_RESET}" ;; *) icon="${C_MUTED}○${C_RESET}" ;; esac
              todos="$todos$(printf '            %s %s' "$icon" "$(trunc "$b" $w)")
" ;;
      file)   files="$files${files:+ · }$a" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  [ -n "$todos" ] && printf '    %s\n%s' "${C_WARN}todos${C_RESET}" "$todos"
  [ -n "$files" ] && printf '    %s %s\n' "$(pad "${C_MUTED}files${C_RESET}" 7)" "${C_MUTED}$(trunc "$files" $w)${C_RESET}"
  return 0
}

sess_pick() {  # $1 rows, $2 number or the start of an id → that row (default: the newest)
  case $2 in
    '') printf '%s\n' "$1" | head -1 ;;
    *[!0-9]*) printf '%s\n' "$1" | awk -F'\t' -v q="$2" 'index($4, q) == 1 { print; exit }' ;;
    *) printf '%s\n' "$1" | sed -n "${2}p" ;;
  esac
}

sessions_overview() {  # every project's newest session
  local name dir remote extra row w
  w=$(( $(ui_width) - 46 ))
  header "sessions" "newest AI session per project"; echo
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    row=$(sess_rows "$name" "$PROJECTS_DIR/$dir" | head -1)
    if [ -n "$row" ]; then printf '  %s %s\n' "$(pad "${C_BOLD}$(trunc "$name" 13)${C_RESET}" 14)" "$(sess_line "$row" "" $w)"
    else printf '  %s %s—%s\n' "$(pad "${C_BOLD}$(trunc "$name" 13)${C_RESET}" 14)" "$C_LINE" "$C_RESET"; fi
  done <<EOF
$(projects)
EOF
  printf '\n  %sone project: %sroam sessions <project>%s%s · read one: %sroam session <project> [n]%s\n' "$C_MUTED" "$C_ACCENT" "$C_RESET" "$C_MUTED" "$C_ACCENT" "$C_RESET"
}

sessions_cmd() {  # [project] [n] — the project's sessions, newest first, and where the chosen one stopped
  local rows row i=0 w
  if [ -z "${1:-}" ] && [ -z "$(find_project "")" ]; then sessions_overview; return; fi
  pick_project "${1:-}" || return 1
  w=$(( $(ui_width) - 46 ))
  rows=$(sess_rows "$P_NAME" "$P_PATH")
  header "sessions" "$P_NAME"; echo
  if [ -z "$rows" ]; then say_info "no Claude Code or Codex sessions for $P_NAME yet"; return; fi
  while IFS= read -r row; do i=$((i + 1)); printf '  %s\n' "$(sess_line "$row" "$i" $w)"; done <<EOF
$(printf '%s\n' "$rows" | head -15)
EOF
  row=$(sess_pick "$rows" "${2:-}")
  [ -n "$row" ] || { say_err "no session ${2:-}"; return 1; }
  echo; rule; echo
  printf '  %s\n' "$(sess_line "$row" "" $w)"
  sess_show_state "$row" "$P_PATH" "$P_NAME"
  printf '\n  %sread it: %sroam session %s %s%s%s · continue: %sroam continue %s %s%s\n' "$C_MUTED" "$C_ACCENT" "$P_NAME" "${2:-1}" "$C_RESET" "$C_MUTED" "$C_ACCENT" "$P_NAME" "${2:-1}" "$C_RESET"
}

session_cmd() {  # [project] [n] — read a session's transcript
  local rows row tool file md title
  pick_project "${1:-}" || return 1
  rows=$(sess_rows "$P_NAME" "$P_PATH")
  row=$(sess_pick "$rows" "${2:-}")
  [ -n "$row" ] || { say_err "no session ${2:-} for $P_NAME"; return 1; }
  tool=$(printf '%s' "$row" | cut -f3); title=$(printf '%s' "$row" | cut -f9); file=$(printf '%s' "$row" | cut -f10)
  if [ ! -f "$file" ]; then
    echo; say_info "This session is on $(sess_where "$(printf '%s' "$row" | cut -f1)") — its transcript isn't here, only where it stopped:"
    echo; printf '  %s\n' "$(sess_line "$row" "" 50)"; sess_show_state "$row" "$P_PATH" "$P_NAME"
    return
  fi
  sess_jq || { say_err "reading transcripts needs jq — macOS 15 has it, or: brew install jq"; return 1; }
  md=$(mktemp -t roam-session) || return 1
  { printf '# %s\n\n*%s · %s · %s*\n' "$title" "$(sess_name "$tool")" "$(sess_where "$(printf '%s' "$row" | cut -f1)")" "$P_NAME"
    sess_md "$tool" "$file" "$(printf '%s' "$row" | cut -f4)"
  } > "$md"
  if [ -t 1 ]; then md_view "$md" "$(sess_name "$tool") · $(trunc "$title" 50)"; else cat "$md"; fi
  rm -f "$md"
}

continue_cmd() {  # [project] [n] — pick the session up again: claude --resume / codex resume, in the project
  local rows row tool id file
  pick_project "${1:-}" || return 1
  rows=$(sess_rows "$P_NAME" "$P_PATH")
  row=$(sess_pick "$rows" "${2:-}")
  [ -n "$row" ] || { say_err "no session ${2:-} for $P_NAME"; return 1; }
  tool=$(printf '%s' "$row" | cut -f3); id=$(printf '%s' "$row" | cut -f4); file=$(printf '%s' "$row" | cut -f10)
  if [ "$tool" = claude ] && [ ! -f "$HOME/.claude/projects/$(claude_key "$P_PATH")/$id.jsonl" ]; then
    say_err "that session is on $(sess_where "$(printf '%s' "$row" | cut -f1)") — 'roam resume' brings its transcript here (with claude_history = 1)"; return 1
  fi
  if [ "$tool" != claude ] && [ ! -f "$file" ]; then say_err "$(sess_name "$tool") sessions stay on their Mac — continue it on $(sess_where "$(printf '%s' "$row" | cut -f1)")"; return 1; fi
  [ -d "$P_PATH" ] || { say_err "$P_NAME isn't on this Mac — roam resume"; return 1; }
  printf '\n  %s %s · %s\n\n' "$(sess_icon "$tool")" "$(sess_name "$tool")" "$(short_path "$P_PATH")"
  cd "$P_PATH" || return 1
  case $tool in
    claude)   command -v claude >/dev/null 2>&1 && exec claude --resume "$id" ;;
    codex)    command -v codex >/dev/null 2>&1 && exec codex resume "$id" ;;
    gemini)   command -v gemini >/dev/null 2>&1 && exec gemini --resume "$id" ;;
    copilot)  command -v copilot >/dev/null 2>&1 && exec copilot --resume="$id" ;;
    opencode) command -v opencode >/dev/null 2>&1 && exec opencode --session "$id" ;;
  esac
  say_err "$(sess_name "$tool") isn't installed on this Mac"; return 1
}

read_cmd() {  # [project] [file] — the project's important Markdown files in the reader
  local files f n count
  pick_project "${1:-}" "Read which project's files?" || return 1
  [ -d "$P_PATH" ] || { say_err "$P_NAME isn't on this Mac — roam resume"; return 1; }
  if [ -n "${2:-}" ]; then
    f=$2; [ -f "$P_PATH/$f" ] || f=$(md_files "$P_PATH" | cut -f3 | grep -i -m1 -F "$2")
    [ -n "$f" ] && [ -f "$P_PATH/$f" ] || { say_err "no file '$2' in $P_NAME"; return 1; }
    if [ -t 1 ]; then md_view "$P_PATH/$f" "$P_NAME · $f"; else cat "$P_PATH/$f"; fi
    return
  fi
  files=$(md_files "$P_PATH")
  [ -n "$files" ] || { say_info "no Markdown files in $P_NAME"; return; }
  if [ ! -t 1 ] || [ ! -t 0 ]; then printf '%s\n' "$files" | cut -f3; return; fi
  count=$(printf '%s\n' "$files" | grep -c .)
  while :; do
    clear; header "read" "$P_NAME"; echo
    n=$( { printf '%s\n' "$files" | awk -F'\t' '{ printf "%-34s %s · %s lines\n", $3, $2, $5 }'; echo "Done"; } | choose) || return
    [ "$n" -gt "$count" ] && return
    f=$(printf '%s\n' "$files" | sed -n "${n}p" | cut -f3)
    md_view "$P_PATH/$f" "$P_NAME · $f"
  done
}

sessions_menu() {  # the dashboard's Sessions action: pick a project, look at its sessions, read or continue one
  local n=1 total c
  cd / && pick_project "" "Whose AI sessions?" || return   # from / the picker always asks
  total=$(sess_rows "$P_NAME" "$P_PATH" | grep -c .)
  [ "$total" -gt 0 ] || { clear; sessions_cmd "$P_NAME"; pause; return; }
  while :; do
    clear; sessions_cmd "$P_NAME" "$n" | sed '$d'   # without the hint line: the menu replaces it
    echo
    c=$(printf '%s\n' "Read the transcript" "Continue it here" "Another session" "Back" | choose) || return
    case $c in
      1) session_cmd "$P_NAME" "$n"; [ -t 1 ] || pause ;;
      2) clear; continue_cmd "$P_NAME" "$n"; pause ;;
      3) printf '\n'; n=$(ask "Which one (1–$total)?" "$n"); case $n in ''|*[!0-9]*) n=1 ;; esac
         [ "$n" -ge 1 ] && [ "$n" -le "$total" ] || n=1 ;;
      *) return ;;
    esac
  done
}
