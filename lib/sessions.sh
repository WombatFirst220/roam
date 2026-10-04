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
    claude) printf '\033[38;5;173m✻%s' "$C_RESET" ;;
    codex)  printf '\033[38;5;36m◇%s' "$C_RESET" ;;
    *)      printf '%s◦%s' "$C_MUTED" "$C_RESET" ;;
  esac
}
[ "$UI_FANCY" = 1 ] || sess_icon() { case $1 in claude) printf '*' ;; codex) printf '>' ;; *) printf '-' ;; esac; }
sess_name() { case $1 in claude) echo "Claude" ;; codex) echo "Codex" ;; *) echo "$1" ;; esac; }

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
    case $tool in claude) sess_claude_state "$file" "$2" ;; codex) sess_codex_state "$file" "$2" ;; esac
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
  out="$dir/.$1.$$.tmp"
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
  if cmp -s "$out" "$dir/$1.txt"; then rm -f "$out"; else mv "$out" "$dir/$1.txt"; fi
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
    { sess_claude_rows "$HOME/.claude/projects/$(claude_key "$2")" "$MAC" local "$live"; sess_codex_rows "$2" "$MAC"; } |
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
    case $tool in claude) sess_claude_md "$file" ;; codex) sess_codex_md "$file" ;; esac
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
  if [ "$tool" = codex ] && [ ! -f "$file" ]; then say_err "Codex sessions stay on their Mac — continue it on $(sess_where "$(printf '%s' "$row" | cut -f1)")"; return 1; fi
  [ -d "$P_PATH" ] || { say_err "$P_NAME isn't on this Mac — roam resume"; return 1; }
  printf '\n  %s %s · %s\n\n' "$(sess_icon "$tool")" "$(sess_name "$tool")" "$(short_path "$P_PATH")"
  cd "$P_PATH" || return 1
  case $tool in
    claude) command -v claude >/dev/null 2>&1 && exec claude --resume "$id" ;;
    codex)  command -v codex >/dev/null 2>&1 && exec codex resume "$id" ;;
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
