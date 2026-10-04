# roam — the full-screen app: `roam` on a terminal. Dashboard, project (sessions, docs, git), reader.
#
# Pure bash 3.2. How it stays fast and flicker-free:
# - every frame is built as an array of screen lines S[]; only lines that changed since the last frame
#   are written, in one write, inside synchronized output (CSI ?2026) where the terminal supports it.
# - render code avoids $(…): helpers hand back results in globals (VIS, PAD, FIT, HL, REPLY).
# - keys and a 0.1 s tick arrive through one FIFO: a background reader forwards key bytes, a ticker
#   writes \001. (bash 3.2's read -t only takes whole seconds, and read -n resets the terminal's
#   VMIN/VTIME, so there's no other way to get a tick without blocking.)
# - slow data (git fetch, AI sessions, Markdown file lists) is gathered by background jobs into files
#   in $TUI_DIR; the tick notices when they're done.
# Everything that prints on its own (park, resume, doctor, fix, new, claude --resume …) runs outside
# the app: it leaves the alternate screen, runs the command as on the command line, and comes back.

# ---------------------------------------------------------------- colors
tui_palette() {  # truecolor where the terminal has it, else 256 colors; ROAM_COLOR=truecolor|256 overrides
  local tc=0 major
  case ${ROAM_COLOR:-} in
    truecolor|24bit) tc=1 ;;
    256) tc=0 ;;
    *) case ${COLORTERM:-} in truecolor|24bit) tc=1 ;; esac
       case ${TERM_PROGRAM:-} in iTerm.app|ghostty|WezTerm|vscode) tc=1 ;; esac
       # Terminal.app learned 24-bit color in macOS 26; before that it garbles those sequences
       if [ "${TERM_PROGRAM:-}" = Apple_Terminal ]; then
         major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1); [ "${major:-0}" -ge 26 ] && tc=1 || tc=0
       fi ;;
  esac
  TC=$tc
  _c() { if [ "$TC" = 1 ]; then printf -v "$1" '\033[%s;2;%d;%d;%dm' "$2" "$3" "$4" "$5"; else printf -v "$1" '\033[%s;5;%dm' "$2" "$6"; fi; }
  _c K_ACC 38 167 139 250 141;  _c K_ACC2 38 244 114 182 213; _c K_CYAN 38 103 232 249 81
  _c K_OK 38 134 239 172 114;   _c K_WARN 38 252 211 77 221;  _c K_ERR 38 248 113 113 203
  _c K_MUTED 38 139 139 167 245; _c K_LINE 38 72 72 98 239;   _c K_DIM 38 90 90 115 240
  _c K_SEL 48 46 40 72 236;     _c K_BAR 48 30 30 42 235;     _c K_PILL 48 167 139 250 141
  _c K_CLAUDE 38 217 119 87 173; _c K_CODEX 38 16 163 127 36
  K_B=$'\033[1m' K_R=$'\033[0m' K_INK=$'\033[38;5;232m'
  # the rest of roam's helpers (cell, sess_line, md) pick these up too
  C_ACCENT=$K_ACC C_ACCENT2=$K_ACC2 C_CYAN=$K_CYAN C_OK=$K_OK C_WARN=$K_WARN C_ERR=$K_ERR C_MUTED=$K_MUTED C_LINE=$K_LINE
  I_OK="${C_OK}✓${C_RESET}" I_ERR="${C_ERR}✗${C_RESET}" I_WARN="${C_WARN}•${C_RESET}" I_ARROW="${C_ACCENT}❯${C_RESET}"
}

tui_grad() {  # $1 plain text → REPLY: pink → violet → cyan across the text
  local s=$1 n=${#1} i r g b t out=""
  if [ "$TC" != 1 ]; then
    local ramp=(213 177 141 105 81)
    for ((i = 0; i < n; i++)); do out="$out"$'\033[38;5;'"${ramp[$(( i * 4 / (n > 1 ? n - 1 : 1) ))]}m${s:i:1}"; done
    REPLY="$out$K_R"; return
  fi
  for ((i = 0; i < n; i++)); do
    t=$(( i * 200 / (n > 1 ? n - 1 : 1) ))   # 0…200: first half pink→violet, second violet→cyan
    if [ $t -le 100 ]; then r=$(( 244 + (167 - 244) * t / 100 )); g=$(( 114 + (139 - 114) * t / 100 )); b=$(( 182 + (250 - 182) * t / 100 ))
    else t=$((t - 100)); r=$(( 167 + (103 - 167) * t / 100 )); g=$(( 139 + (232 - 139) * t / 100 )); b=$(( 250 + (249 - 250) * t / 100 )); fi
    out="$out"$'\033[38;2;'"$r;$g;${b}m${s:i:1}"
  done
  REPLY="$out$K_R"
}

# ---------------------------------------------------------------- text without subshells
tstrip() {  # $1 → STRIP: the text without SGR colors and OSC 8 links. Split on ESC once: pattern loops or extglob
  local IFS=$'\033' p first=1 parts   # are quadratic in bash and took 40 ms on one status line
  STRIP=""
  set -f; parts=($1); set +f
  for p in ${parts[@]+"${parts[@]}"}; do
    if [ $first = 1 ]; then STRIP=$p; first=0; continue; fi
    case $p in '['*) STRIP="$STRIP${p#*m}" ;; ']'*) ;; '\'*) STRIP="$STRIP${p#?}" ;; *) STRIP="$STRIP$p" ;; esac
  done
}
tvis() {  # $1 → VIS: visible width — counted in bytes (fast) minus UTF-8 continuation bytes
  local LC_ALL=C p
  tstrip "$1"
  p=${STRIP//[$'\x80'-$'\xbf']/}
  VIS=${#p}
}
tpad() { tvis "$1"; printf -v PAD '%s%*s' "$1" $(( $2 > VIS ? $2 - VIS : 0 )) ''; }                      # pad to $2
tfit() { if [ ${#1} -gt "$2" ]; then FIT="${1:0:$(($2 - 1))}…"; else FIT=$1; fi; }                        # plain text, cut to $2
thl() { printf -v HL '%*s' "$1" ''; HL=${HL// /${2:-─}}; }                                                  # $2 repeated $1 times
tright() { tvis "$1"; local a=$VIS; tvis "$2"; printf -v PAD '%s%*s%s' "$1" $(( $3 - a - VIS > 1 ? $3 - a - VIS : 1 )) '' "$2"; }  # $1 left, $2 right, width $3

# ---------------------------------------------------------------- screen
tui_size() {
  local s; s=$(stty size 2>/dev/null </dev/tty)
  ROWS=${ROAM_ROWS:-${s% *}} COLS=${ROAM_COLS:-${s#* }}
  [ "${ROWS:-0}" -ge 10 ] 2>/dev/null || ROWS=24
  [ "${COLS:-0}" -ge 40 ] 2>/dev/null || COLS=80
}

fb_line() {  # $1 row (0-based), $2 content — queued only when it changed
  if [ "$FULL" = 1 ] || [ "${PREV[$1]-}" != "$2" ]; then FB="$FB"$'\033['"$(($1 + 1));1H$2$K_R"$'\033[K'; PREV[$1]=$2; fi
}
fb_flush() { [ -n "$FB" ] && printf '\033[?2026h%s\033[?2026l' "$FB" >/dev/tty; FB=""; FULL=0; }

tui_enter() {
  TUI_STTY=$(stty -g </dev/tty)
  stty -echo -icanon </dev/tty
  printf '\033[?1049h\033[?25l\033[?7l\033]0;roam\007' >/dev/tty
  # mouse: wheel and clicks (hold ⌥ or ⇧ to select text as usual); ROAM_MOUSE=0 turns it off
  [ "${ROAM_MOUSE:-1}" = 0 ] || printf '\033[?1000h\033[?1006h' >/dev/tty
  tui_io_start
  FULL=1 PREV=()
}
tui_leave() {
  tui_io_stop
  printf '\033[?1000l\033[?1006l\033[0m\033[?7h\033[?25h\033[?1049l' >/dev/tty
  [ -n "${TUI_STTY:-}" ] && stty "$TUI_STTY" </dev/tty 2>/dev/null
  TUI_STTY=""
}

# keys and ticks through one FIFO on fd 7
tui_io_start() {
  [ -p "$TUI_DIR/in" ] || mkfifo "$TUI_DIR/in"
  exec 7<>"$TUI_DIR/in"
  ( trap 'exit 0' TERM
    while IFS= read -rsn1 c </dev/tty; do [ -z "$c" ] && c=$'\r'; printf '%s' "$c" >&7 || exit; done ) &   # \n would end the main loop's read: Enter travels as \r
  TUI_KR=$!
  ( trap 'exit 0' TERM; while sleep 0.2; do printf '\001' >&7 || exit; done ) &
  TUI_TK=$!
}
tui_io_stop() {
  [ -n "${TUI_KR:-}" ] && kill "$TUI_KR" "$TUI_TK" 2>/dev/null
  [ -n "${TUI_KR:-}" ] && wait "$TUI_KR" "$TUI_TK" 2>/dev/null
  TUI_KR="" TUI_TK=""
  exec 7<&-
  rm -f "$TUI_DIR/in"
}

tui_key() {  # next event → KEY: TICK, ENTER, TAB, BTAB, ESC, BS, UP DOWN LEFT RIGHT PGUP PGDN HOME END, or the character
  local c s="" ticks=0
  IFS= read -rsn1 c <&7 || { KEY=TICK; return; }
  [ -z "$c" ] && c=$'\r'
  case $c in
    $'\001') KEY=TICK ;;
    $'\n'|$'\r') KEY=ENTER ;;
    $'\t') KEY=TAB ;;
    $'\177'|$'\010') KEY=BS ;;
    $'\033')
      # the rest of an escape sequence follows at once; a tick first means a bare Esc
      while IFS= read -rsn1 -t 1 c <&7; do
        if [ "$c" = $'\001' ]; then ticks=$((ticks + 1)); [ -z "$s" ] && break; [ $ticks -gt 3 ] && break; continue; fi
        s="$s$c"
        case $s in '['|O) continue ;; '[<'*) case $c in [Mm]) break ;; *) continue ;; esac ;; esac
        case $c in [A-Za-z~]) break ;; esac
      done
      case $s in
        '[A'|OA) KEY=UP ;; '[B'|OB) KEY=DOWN ;; '[C'|OC) KEY=RIGHT ;; '[D'|OD) KEY=LEFT ;;
        '[5~') KEY=PGUP ;; '[6~') KEY=PGDN ;; '[H'|'[1~'|OH) KEY=HOME ;; '[F'|'[4~'|OF) KEY=END ;; '[Z') KEY=BTAB ;;
        '[<'*[Mm])   # SGR mouse: \e[<button;x;y M (press) or m (release)
          KEY=MOUSE; s=${s#??}; MOUSE_UP=0; case $s in *m) MOUSE_UP=1 ;; esac; s=${s%?}
          MOUSE_B=${s%%;*}; s=${s#*;}; MOUSE_X=${s%%;*}; MOUSE_Y=${s#*;} ;;
        *) KEY=ESC ;;
      esac ;;
    *) KEY=$c ;;
  esac
}

# ---------------------------------------------------------------- widgets
# panel: $1 width, $2 height, $3 title, $4 focused (1/0), $5 right title; content in PC[] → lines in PB[]
panel() {
  local w=$1 h=$2 title=$3 foc=$4 rt=${5:-} col i inner=$(($1 - 4)) t r
  [ "$foc" = 1 ] && col=$K_ACC || col=$K_LINE
  if [ "$foc" = 1 ]; then t="${K_B}${K_ACC}$title${K_R}"; else t="${K_B}$title${K_R}"; fi
  tvis "$title"; local tl=$VIS
  if [ -n "$rt" ]; then tfit "$rt" $(( w - tl - 12 > 4 ? w - tl - 12 : 4 )); rt=$FIT   # right titles are plain text
    tvis "$rt"; r=" ${K_MUTED}$rt${K_R} ${col}─╮"; thl $(( w - 4 - tl - VIS - 4 ))
  else r="╮"; thl $(( w - 4 - tl - 1 )); fi
  PB=("${col}╭─${K_R} $t ${col}$HL${r}${K_R}")
  for ((i = 0; i < h - 2; i++)); do
    tpad "${PC[$i]-}" $inner
    PB[$((i + 1))]="${col}│${K_R} $PAD ${col}│${K_R}"
  done
  thl $((w - 2))
  PB[$((h - 1))]="${col}╰${HL}╯${K_R}"
}

sel_row() {  # $1 content, $2 width → REPLY: the row on the selection background, marker in front
  tpad "${K_ACC}❯${K_R} $1" "$2"
  REPLY="$K_SEL${PAD//$'\033[0m'/$'\033[0m'$K_SEL}$K_R"
}
plain_row() { REPLY="  $1"; }

scrollbar() {  # $1 top, $2 visible, $3 total, $4 row → REPLY: thumb or track character
  local h=$2 n=$3 a b
  if [ "$n" -le "$h" ]; then REPLY=" "; return; fi
  a=$(( $1 * h / n )); b=$(( ($1 + h) * h / n ))
  if [ "$4" -ge "$a" ] && [ "$4" -le "$b" ]; then REPLY="${K_ACC}┃${K_R}"; else REPLY="${K_LINE}│${K_R}"; fi
}

topbar() {  # $1 breadcrumb (colored), $2 right
  tui_grad "◆ roam"
  tright " $REPLY  $1" "${2:-} " "$COLS"
  S[0]=$PAD
}

statusbar() {  # $1 mode, $2 key hints "k:label k:label …", $3 right side
  local out="" pair k l
  SB_MODE=$1 SB_KEYS=$2 SB_RIGHT=${3:-}
  local room next
  tvis "${3:-}"; room=$(( COLS - VIS - 2 ))
  out="${K_PILL}${K_INK}${K_B} $1 ${K_R} "
  for pair in $2; do   # as many hints as fit, from the left
    k=${pair%%:*}; l=${pair#*:}; next="$out ${K_B}${K_ACC}$k${K_R} ${K_MUTED}${l//_/ }${K_R} "
    tvis "$next"; [ "$VIS" -le "$room" ] || break
    out=$next
  done
  tright "$out" "${3:-} " "$COLS"
  S[$((ROWS - 1))]="$K_BAR${PAD//$'\033[0m'/$'\033[0m'$K_BAR}"
}

tago() {  # $1 unix time → REPLY "5m", "3h", "2d" (NOW is set once per frame: no date per row)
  local s=$(( NOW - $1 ))
  if [ $s -lt 120 ]; then REPLY="now"; elif [ $s -lt 3600 ]; then REPLY="$((s / 60))m"
  elif [ $s -lt 172800 ]; then REPLY="$((s / 3600))h"; else REPLY="$((s / 86400))d"; fi
}

SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
spinner() { REPLY="${K_ACC}${SPIN:$((TICKS % 10)):1}${K_R}"; }

# ---------------------------------------------------------------- data (gathered outside the render path)
tcell() {  # $1 project state (branch, dirty, ahead, parked — tabs) → REPLY, like cell() but without a subshell
  local branch dirty ahead parked rest
  IFS=$'\t' read -r branch dirty ahead parked rest <<EOF
$1
EOF
  if [ "$branch" = missing ]; then REPLY="${K_LINE}—${K_R}"; return; fi
  if [ -z "$branch" ]; then REPLY="${K_MUTED}?${K_R}"; return; fi
  tfit "$branch" 14; REPLY=$FIT
  if [ "${dirty:-0}" = 0 ] && { [ "${ahead:-0}" = 0 ] || [ "$ahead" = "?" ]; }; then REPLY="$REPLY ${K_OK}✓${K_R}"
  else
    [ "${dirty:-0}" != 0 ] && REPLY="$REPLY ${K_WARN}●$dirty${K_R}"
    [ "${ahead:-0}" != 0 ] && [ "$ahead" != "?" ] && REPLY="$REPLY ${K_CYAN}↑$ahead${K_R}"
  fi
  [ "$parked" = yes ] && REPLY="$REPLY ${K_ACC}☁${K_R}"
  return 0
}

tui_load() {  # projects and Macs from the pool's registry (fetch_everything rewrites this Mac's entry), work in flight from git
  local name dir remote extra f m i j k v l line sha time from br g applied now
  now=$(date +%s)
  NP=0 P_N=() P_D=() P_CELL=() P_PV=() NM=0 M_ID=() M_LINE=() M_LABEL=() ST=()
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    P_N[NP]=$name P_D[NP]=$dir; NP=$((NP + 1))
  done <<EOF
$(projects)
EOF
  for f in "$MACS_DIR"/*.txt; do
    [ -f "$f" ] || continue
    m=${f##*/}; m=${m%.txt}; j=$NM; M_ID[j]=$m; NM=$((NM + 1))
    local seen="" mname="" macos="" xcode="" doc=""
    while IFS= read -r l; do
      case $l in
        name=*) mname=${l#name=} ;; seen=*) seen=${l#seen=} ;; macos=*) macos=${l#macos=} ;;
        xcode=*) xcode=${l#xcode=} ;; doctor=*) doc=${l#doctor=} ;;
        project=*) l=${l#project=}; k=${l%%$'\t'*}
          for ((i = 0; i < NP; i++)); do [ "${P_N[$i]}" = "$k" ] && { ST[$((j * NP + i))]=${l#*$'\t'}; break; }; done ;;
      esac
    done < "$f"
    mname=${mname:-$m}; mname=${mname##*[’\']s }; mname=${mname%% von *}; mname=${mname%% de *}; mname=${mname%% of *}
    M_LABEL[j]=$mname
    local dot status d missing
    if [ "$m" = "$MAC" ]; then dot="${K_ACC}▸${K_R}"; status="${K_ACC}this Mac${K_R}"
    elif [ $(( now - ${seen:-0} )) -lt $(( INTERVAL * 60 + 300 )) ]; then dot="${K_OK}●${K_R}"; status="${K_OK}online${K_R}"
    else dot="${K_LINE}○${K_R}"; NOW=$now; tago "${seen:-0}"; status="${K_MUTED}$REPLY ago${K_R}"; fi
    missing=${doc#* }; missing=${missing%% *}
    if [ -z "$doc" ]; then d="${K_MUTED}not checked${K_R}"
    elif [ "${missing:-0}" -gt 0 ] 2>/dev/null; then d="${K_ERR}✗ $missing missing${K_R}"
    else d="${K_OK}✓ ready${K_R}"; fi
    tfit "$mname" 20; tpad "${K_B}$FIT${K_R}" 21; v=$PAD
    tpad "$status" 13
    M_LINE[j]="$dot $v$PAD${K_MUTED}macOS ${macos:-–}   Xcode ${xcode:-–}${K_R}   $d"
  done
  for ((i = 0; i < NP; i++)); do
    line="" P_CELL[i]="${K_MUTED}?${K_R}"
    for ((j = 0; j < NM; j++)); do
      tcell "${ST[$((j * NP + i))]-}"
      [ "${M_ID[$j]}" = "$MAC" ] && P_CELL[i]=$REPLY
      tfit "${M_LABEL[$j]}" 16
      if [ "${M_ID[$j]}" = "$MAC" ]; then tpad "${K_ACC}$FIT${K_R}" 18; else tpad "${K_MUTED}$FIT${K_R}" 18; fi
      line="$line$PAD$REPLY"$'\n'
    done
    g="$PROJECTS_DIR/${P_D[$i]}"
    if [ -d "$g/.git" ]; then
      applied=$(cat "$g/.git/roam-applied" 2>/dev/null)
      while read -r sha time from br; do
        [ -n "$sha" ] || continue
        NOW=$now; tago "$time"; v="$REPLY ago"
        for ((j = 0; j < NM; j++)); do [ "${M_ID[$j]}" = "$from" ] && break; done
        k=${M_LABEL[$j]-$from}
        if [ "$from" = "$MAC" ]; then line="$line${K_ACC}☁${K_R} parked here · $v · $br"$'\n'
        elif [ "$sha" = "$applied" ]; then line="$line${K_OK}✓${K_R} ${K_MUTED}resumed from $k · $v${K_R}"$'\n'
        else line="$line${K_WARN}☁${K_R} from $k · $v · $br  ${K_ACC}r → resume${K_R}"$'\n'; fi
      done <<EOF
$(git -C "$g" for-each-ref --sort=-committerdate --format='%(objectname) %(committerdate:unix) %(refname:lstrip=3) %(subject)' refs/remotes/roam/ 2>/dev/null | awk '{print $1, $2, $3, $6}')
EOF
    fi
    P_PV[i]=$line
  done
  [ "$SEL" -ge "$NP" ] && SEL=$((NP > 0 ? NP - 1 : 0))
  return 0
}

tui_bg_sessions() {  # background: every project's Markdown files (quick) and AI sessions → $TUI_DIR/d.N, s.N, st.N
  local i row
  for ((i = 0; i < NP; i++)); do
    [ -d "$PROJECTS_DIR/${P_D[$i]}" ] && md_files "$PROJECTS_DIR/${P_D[$i]}" > "$TUI_DIR/d.$i.tmp" 2>/dev/null && mv "$TUI_DIR/d.$i.tmp" "$TUI_DIR/d.$i"
  done
  UI_W=$(( COLS - COLS * 44 / 100 - 4 ))   # sess_show_state lays out to the preview's width
  for ((i = 0; i < NP; i++)); do
    sess_rows "${P_N[$i]}" "$PROJECTS_DIR/${P_D[$i]}" > "$TUI_DIR/s.$i.tmp" 2>/dev/null
    # where the newest session stopped, for the preview
    row=$(head -1 "$TUI_DIR/s.$i.tmp")
    [ -n "$row" ] && sess_show_state "$row" "$PROJECTS_DIR/${P_D[$i]}" "${P_N[$i]}" > "$TUI_DIR/st.$i" 2>/dev/null
    mv "$TUI_DIR/s.$i.tmp" "$TUI_DIR/s.$i"
  done
  : > "$TUI_DIR/sessions.done"
}

tui_refresh() {  # $1 "fetch": also ask the remotes (in the background)
  rm -f "$TUI_DIR"/s.* "$TUI_DIR"/d.* "$TUI_DIR/sessions.done" "$TUI_DIR/fetch.done"
  tui_load
  # background jobs never touch the terminal (a job holding it keeps the terminal busy after roam quits)
  ( tui_bg_sessions ) </dev/null >/dev/null 2>&1 &
  TUI_JOBS="${TUI_JOBS:-} $!"
  if [ "${1:-}" = fetch ]; then BUSY="checking the remotes"; ( fetch_everything; : > "$TUI_DIR/fetch.done" ) </dev/null >/dev/null 2>&1 & TUI_JOBS="$TUI_JOBS $!"
  else BUSY="reading AI sessions"; fi
  PV_KEY=""
}

tui_poll() {  # on every tick: pick up what the background jobs finished
  if [ -f "$TUI_DIR/fetch.done" ]; then
    rm -f "$TUI_DIR/fetch.done"; tui_load; PV_KEY=""; BUSY="reading AI sessions"; DIRTY=1
  fi
  if [ -f "$TUI_DIR/sessions.done" ] && [ "$BUSY" = "reading AI sessions" ]; then BUSY=""; PV_KEY=""; DIRTY=1; fi
  # a view waiting for its data: draw again once it's there
  case $VIEW in
    run) DIRTY=1 ;;
    dash) [ -n "$BUSY" ] && { [ ! -f "$TUI_DIR/s.$SEL" ] || [ ! -f "$TUI_DIR/d.$SEL" ]; } && [ $((TICKS % 3)) = 0 ] && DIRTY=1 ;;
    proj) [ "$PTAB" = 0 ] && [ ! -f "$TUI_DIR/s.$PJ" ] && DIRTY=1
          [ "$PTAB" = 1 ] && [ ! -f "$TUI_DIR/d.$PJ" ] && DIRTY=1 ;;
  esac
  return 0
}

tui_tick_status() {  # between frames only the spinner moves: redraw just the status line
  local right=$SB_RIGHT
  if [ -n "$BUSY" ]; then spinner; right="$REPLY ${K_MUTED}${BUSY}…${K_R}"; fi
  S=(); statusbar "$SB_MODE" "$SB_KEYS" "$right"
  fb_line $((ROWS - 1)) "${S[$((ROWS - 1))]}"; fb_flush
}

read_lines() {  # $1 file → LN[] (no subshell)
  LN=()
  [ -f "$1" ] || return 1
  local l n=0
  while IFS= read -r l || [ -n "$l" ]; do LN[n]=$l; n=$((n + 1)); done < "$1"
  return 0
}

# ---------------------------------------------------------------- view: dashboard
dash_preview() {  # PV[] for the selected project (cached until the selection or the data changes)
  local key="$SEL:$COLS:$([ -f "$TUI_DIR/s.$SEL" ] && echo s):$([ -f "$TUI_DIR/d.$SEL" ] && echo d)" w=$1 n=0 l i row
  [ "$key" = "$PV_KEY" ] && return
  PV_KEY=$key PV=()
  local IFS=$'\n'
  for l in ${P_PV[$SEL]-}; do PV[n]=$l; n=$((n + 1)); done
  unset IFS
  PV[n]=""; n=$((n + 1))
  PV[n]="${K_B}AI sessions${K_R}"; n=$((n + 1))
  if read_lines "$TUI_DIR/s.$SEL"; then
    [ ${#LN[@]} -eq 0 ] && { PV[n]="${K_MUTED}none yet${K_R}"; n=$((n + 1)); }
    for ((i = 0; i < ${#LN[@]} && i < 3; i++)); do PV[n]=$(sess_line "${LN[$i]}" "" $((w - 30)) short); n=$((n + 1)); done
    if read_lines "$TUI_DIR/st.$SEL"; then for ((i = 0; i < ${#LN[@]} && i < 8; i++)); do PV[n]=${LN[$i]}; n=$((n + 1)); done; fi
  else spinner; PV[n]="$REPLY ${K_MUTED}reading…${K_R}"; n=$((n + 1)); PV_KEY=""; fi
  PV[n]=""; n=$((n + 1))
  PV[n]="${K_B}Docs${K_R}"; n=$((n + 1))
  if read_lines "$TUI_DIR/d.$SEL"; then
    row=""
    for ((i = 0; i < ${#LN[@]} && i < 8; i++)); do l=${LN[$i]}; l=${l#*$'\t'}; l=${l#*$'\t'}; l=${l%%$'\t'*}; row="$row${row:+ · }$l"; done
    tfit "$row" $((w - 4)); PV[n]="${FIT:-${K_MUTED}no Markdown files${K_R}}"; n=$((n + 1))
  elif [ -d "$PROJECTS_DIR/${P_D[$SEL]-}" ]; then PV[n]="${K_MUTED}…${K_R}"; n=$((n + 1)); PV_KEY=""
  else PV[n]="${K_MUTED}not on this Mac — r resumes it${K_R}"; n=$((n + 1)); fi
}

dash_draw() {
  local lw rw ph mh i r top=1 sess
  local split=1; [ "$COLS" -lt 96 ] && split=0
  mh=$(( NM + 2 )); [ $mh -gt 7 ] && mh=7
  ph=$(( ROWS - 2 - mh ))
  if [ $split = 1 ]; then lw=$(( COLS * 44 / 100 )); rw=$(( COLS - lw )); else lw=$COLS; rw=0; fi
  # projects list (only those matching the filter)
  dash_visible
  PC=()
  local h=$((ph - 2)) off=0 pos=0 nv=${#VIDX[@]}
  for ((i = 0; i < nv; i++)); do [ "${VIDX[$i]}" = "$SEL" ] && pos=$i; done
  [ $pos -ge $h ] && off=$((pos - h + 1))
  DASH_OFF=$off DASH_LW=$lw DASH_H=$h
  for ((i = 0; i < h && i + off < nv; i++)); do
    r=${VIDX[$((i + off))]}
    tfit "${P_N[$r]}" 14; tpad "${K_B}$FIT${K_R}" 15
    local c="$PAD${P_CELL[$r]}"
    if [ -f "$TUI_DIR/s.$r" ] && read_lines "$TUI_DIR/s.$r" && [ ${#LN[@]} -gt 0 ]; then
      local _m _s tool _i upd _b _n live _rest icon
      IFS=$'\t' read -r _m _s tool _i upd _b _n live _rest <<EOF
${LN[0]}
EOF
      case $tool in claude) icon="${K_CLAUDE}✻${K_R}" ;; codex) icon="${K_CODEX}◇${K_R}" ;; *) icon="◦" ;; esac
      tago "$upd"
      tright "$c" "$icon ${K_MUTED}$REPLY${K_R}$([ "$live" = 1 ] && echo " ${K_OK}●${K_R}" || :)" $((lw - 6))
      c=$PAD
    fi
    if [ $r -eq $SEL ]; then sel_row "$c" $((lw - 4)); else plain_row "$c"; fi
    PC[$i]=$REPLY
  done
  [ $nv -eq 0 ] && [ $NP -gt 0 ] && PC[0]="${K_MUTED}nothing matches “${FILTER}” — esc clears the filter${K_R}"
  [ $NP -eq 0 ] && PC[0]="${K_MUTED}no projects yet — a adds one${K_R}"
  if [ -n "$FILTER" ]; then panel $lw $ph "Projects /$FILTER" 1 "$nv of $NP"; else panel $lw $ph "Projects" 1 "$NP"; fi
  for ((i = 0; i < ph; i++)); do S[$((top + i))]=${PB[$i]}; done
  # preview of the selected project
  if [ $split = 1 ] && [ $nv -gt 0 ]; then
    dash_preview $rw
    PC=("${PV[@]}")
    panel $rw $ph "${P_N[$SEL]}" 0 "⏎ open"
    for ((i = 0; i < ph; i++)); do S[$((top + i))]="${S[$((top + i))]}${PB[$i]}"; done
  fi
  # Macs
  PC=()
  for ((i = 0; i < NM && i < mh - 2; i++)); do PC[$i]=${M_LINE[$i]}; done
  panel $COLS $mh "Macs" 0 "pool · $(short_path "$POOL")"
  for ((i = 0; i < mh; i++)); do S[$((top + ph + i))]=${PB[$i]}; done
  topbar "${K_MUTED}v$ROAM_VERSION${K_R}" "${K_MUTED}$(date +%H:%M)${K_R}"
  local right=""; [ -n "$BUSY" ] && { spinner; right="$REPLY ${K_MUTED}${BUSY}…${K_R}"; }
  if [ -n "$PROMPT" ]; then prompt_bar "filter"
  else statusbar "ROAM" "⏎:open /:filter r:resume p:park s:sessions v:docs d:doctor ?:help q:quit" "$right"; fi
}

dash_visible() {  # VIDX[] = projects whose name matches FILTER (letters in order, any case); keeps SEL on one of them
  local i g="*" k found=0
  VIDX=()
  if [ -n "$FILTER" ]; then for ((k = 0; k < ${#FILTER}; k++)); do g="$g${FILTER:$k:1}*"; done; fi
  shopt -s nocasematch
  for ((i = 0; i < NP; i++)); do
    # shellcheck disable=SC2053
    [[ ${P_N[$i]} == $g ]] && { VIDX[${#VIDX[@]}]=$i; [ "$i" = "$SEL" ] && found=1; }
  done
  shopt -u nocasematch
  [ $found = 1 ] || [ ${#VIDX[@]} -eq 0 ] || SEL=${VIDX[0]}
}

dash_move() {  # $1 steps (negative: up) through the visible projects
  local i pos=0 nv
  dash_visible; nv=${#VIDX[@]}
  [ $nv -gt 0 ] || return
  for ((i = 0; i < nv; i++)); do [ "${VIDX[$i]}" = "$SEL" ] && pos=$i; done
  pos=$((pos + $1)); [ $pos -lt 0 ] && pos=0; [ $pos -ge $nv ] && pos=$((nv - 1))
  SEL=${VIDX[$pos]}
}

prompt_bar() {  # $1 label — the bottom line while typing a filter or a search
  tpad "$K_BAR ${K_ACC}/${K_R}$K_BAR$PROMPT_TEXT${K_ACC}▏${K_R}$K_BAR  ${K_MUTED}$1 · ⏎ keep · esc clear${K_R}" "$COLS"
  S[$((ROWS - 1))]="$K_BAR${PAD//$'\033[0m'/$'\033[0m'$K_BAR}"
}

dash_key() {
  if [ -n "$PROMPT" ]; then   # typing a filter: the list narrows with every key
    case $1 in
      ENTER) PROMPT="" ;;
      ESC) PROMPT="" FILTER="" ;;
      BS) PROMPT_TEXT=${PROMPT_TEXT%?}; FILTER=$PROMPT_TEXT ;;
      UP) dash_move -1 ;; DOWN) dash_move 1 ;;
      MOUSE|TICK|LEFT|RIGHT|TAB|BTAB|PGUP|PGDN|HOME|END) ;;
      *) PROMPT_TEXT="$PROMPT_TEXT$1"; FILTER=$PROMPT_TEXT ;;
    esac
    return
  fi
  case $1 in
    UP|k) dash_move -1 ;;
    DOWN|j) dash_move 1 ;;
    HOME|g) dash_move -9999 ;; END|G) dash_move 9999 ;;
    PGUP) dash_move -10 ;; PGDN) dash_move 10 ;;
    /) PROMPT=1 PROMPT_TEXT=$FILTER ;;
    ESC) FILTER="" ;;
    MOUSE) dash_mouse ;;
    ENTER|RIGHT|l) [ ${#VIDX[@]} -gt 0 ] && proj_open 0 ;;
    s) [ ${#VIDX[@]} -gt 0 ] && proj_open 0 ;;
    v) [ ${#VIDX[@]} -gt 0 ] && proj_open 1 ;;
    r) run_start resume ;;
    p) run_start park ;;
    d) tui_outside "Doctor" 'doctor_run; doctor_show; registry_write' ;;
    f) tui_outside "Fix" 'doctor_run; fix_run; doctor_run; registry_write' ;;
    n) tui_outside "New project" 'new_project'; tui_refresh ;;
    a) tui_outside "" 'add_cmd ""'; tui_refresh ;;
    L) log_open ;;
    u) tui_refresh fetch ;;
    c) [ ${#VIDX[@]} -gt 0 ] && tui_outside "" "continue_cmd '${P_N[$SEL]}' 1" ;;
    q|Q) QUIT=1 ;;
  esac
}

dash_mouse() {  # wheel moves the selection; a click selects a project, a click on the selected one opens it
  case $MOUSE_B in
    64) dash_move -1 ;; 65) dash_move 1 ;;
    0) [ "$MOUSE_UP" = 1 ] && return
       local row=$((MOUSE_Y - 3 + DASH_OFF))   # screen row 1 is the top bar, 2 the panel's border
       [ "$MOUSE_X" -le "$DASH_LW" ] && [ "$MOUSE_Y" -ge 3 ] && [ "$MOUSE_Y" -lt $((3 + DASH_H)) ] || return
       dash_visible
       [ $row -lt ${#VIDX[@]} ] || return
       if [ "${VIDX[$row]}" = "$SEL" ]; then proj_open 0; else SEL=${VIDX[$row]}; fi ;;
  esac
}

# ---------------------------------------------------------------- view: project (tabs: sessions, docs, git)
TABS="Sessions Docs Git"
proj_open() {  # $1 tab
  PJ=$SEL PTAB=$1 PSEL=0 PST_KEY=""
  PJ_PATH="$PROJECTS_DIR/${P_D[$PJ]}"
  VIEW=proj
}

proj_items() {  # LN[] = the current tab's rows
  case $PTAB in
    0) read_lines "$TUI_DIR/s.$PJ" || LN=() ;;
    1) read_lines "$TUI_DIR/d.$PJ" || LN=() ;;
    2) LN=() ;;
  esac
}

proj_state() {  # PST[] = details below the list for the selected item (cached)
  local key="$PTAB:$PSEL:$COLS:$([ -f "$TUI_DIR/s.$PJ" ] && echo 1)" row l n=0
  [ "$key" = "$PST_KEY" ] && return
  PST_KEY=$key PST=()
  case $PTAB in
    0) proj_items; row=${LN[$PSEL]-}
       [ -n "$row" ] || return
       UI_W=$((COLS - 4))   # sess_show_state lays out to ui_width
       while IFS= read -r l; do PST[n]=$l; n=$((n + 1)); done <<EOF
$(sess_show_state "$row" "$PJ_PATH" "${P_N[$PJ]}")
EOF
       ;;
    1) proj_items; row=${LN[$PSEL]-}; row=${row#*$'\t'}; row=${row#*$'\t'}; row=${row%%$'\t'*}
       [ -n "$row" ] && [ -f "$PJ_PATH/$row" ] || return
       while IFS= read -r l; do PST[n]=$l; n=$((n + 1)); done <<EOF
$(MD_FORCE_COLOR=1 md_render "$PJ_PATH/$row" $((COLS - 8)) 2>/dev/null | head -40)
EOF
       ;;
    2) [ -d "$PJ_PATH/.git" ] || return
       while IFS= read -r l; do PST[n]=$l; n=$((n + 1)); done <<EOF
$(git -C "$PJ_PATH" -c color.ui=always status -sb 2>/dev/null | head -12 | sed 's/^/ /'; echo; git -C "$PJ_PATH" log --color=always --format="%C(yellow)%h%Creset %s %C(dim)· %cr%Creset" -n 40 2>/dev/null | sed 's/^/ /')
EOF
       ;;
  esac
}

proj_draw() {
  local i t tabs="" lh dh n row l top=1 name=${P_N[$PJ]}
  i=0
  for t in $TABS; do
    if [ $i -eq $PTAB ]; then tabs="$tabs${K_PILL}${K_INK}${K_B} $((i + 1)) $t ${K_R} "; else tabs="$tabs${K_MUTED} $((i + 1)) $t ${K_R} "; fi
    i=$((i + 1))
  done
  proj_items; n=${#LN[@]}
  [ $PSEL -ge $n ] && PSEL=$((n > 0 ? n - 1 : 0))
  if [ $PTAB = 2 ]; then lh=0; else lh=$(( n + 2 )); [ $lh -lt 3 ] && lh=3; [ $lh -gt $(( (ROWS - 3) / 2 )) ] && lh=$(( (ROWS - 3) / 2 )); fi
  dh=$(( ROWS - 2 - lh ))
  S[$top]=" $tabs"
  top=2; dh=$((dh - 1))
  if [ $lh -gt 0 ]; then
    PC=()
    local h=$((lh - 2)) off=0
    [ $PSEL -ge $h ] && off=$((PSEL - h + 1))
    PROJ_OFF=$off PROJ_H=$h
    for ((i = 0; i < h && i + off < n; i++)); do
      row=${LN[$((i + off))]}
      if [ $PTAB = 0 ]; then l=$(sess_line "$row" "" $((COLS - 52)))
      else l=${row#*$'\t'}; local kind=${l%%$'\t'*}; l=${l#*$'\t'}; local file=${l%%$'\t'*}; l=${l#*$'\t'}; l=${l#*$'\t'}
        tpad "${K_B}$file${K_R}" 44; l="$PAD${K_MUTED}$kind · $l lines${K_R}"; fi
      if [ $((i + off)) -eq $PSEL ]; then sel_row "$l" $((COLS - 4)); else plain_row "$l"; fi
      PC[$i]=$REPLY
    done
    if [ $n -eq 0 ]; then
      if [ $PTAB = 0 ] && [ ! -f "$TUI_DIR/s.$PJ" ]; then spinner; PC[0]="$REPLY ${K_MUTED}reading sessions…${K_R}"
      elif [ $PTAB = 0 ]; then PC[0]="${K_MUTED}no Claude Code or Codex sessions for $name yet${K_R}"
      elif [ ! -f "$TUI_DIR/d.$PJ" ] && [ -d "$PJ_PATH" ]; then spinner; PC[0]="$REPLY ${K_MUTED}looking for Markdown files…${K_R}"
      else PC[0]="${K_MUTED}no Markdown files${K_R}"; fi
    fi
    panel $COLS $lh "$([ $PTAB = 0 ] && echo "AI sessions" || echo "Files")" 1 "$n"
    for ((i = 0; i < lh; i++)); do S[$((top + i))]=${PB[$i]}; done
    top=$((top + lh))
  fi
  proj_state
  PC=()
  for ((i = 0; i < dh - 2; i++)); do PC[$i]=${PST[$i]-}; done
  case $PTAB in
    0) t="Where it stopped" ;; 1) t="Preview" ;; *) t="git · $(git -C "$PJ_PATH" symbolic-ref --short -q HEAD 2>/dev/null)" ;;
  esac
  panel $COLS $dh "$t" 0 "$([ $PTAB = 2 ] || echo '⏎ read')"
  for ((i = 0; i < dh; i++)); do S[$((top + i))]=${PB[$i]}; done
  topbar "${K_LINE}›${K_R} ${K_B}$name${K_R}" "${K_MUTED}$(short_path "$PJ_PATH")${K_R}"
  case $PTAB in
    0) statusbar "SESSIONS" "⏎:read c:continue ⇥:tab ?:help esc:back" ;;
    1) statusbar "DOCS" "⏎:read o:open_in_editor ⇥:tab ?:help esc:back" ;;
    *) statusbar "GIT" "⇥:tab ?:help esc:back" ;;
  esac
}

proj_key() {
  local row
  case $1 in
    UP|k) [ $PSEL -gt 0 ] && PSEL=$((PSEL - 1)) ;;
    DOWN|j) proj_items; [ $PSEL -lt $((${#LN[@]} - 1)) ] && PSEL=$((PSEL + 1)) ;;
    TAB|RIGHT|l) PTAB=$(( (PTAB + 1) % 3 )); PSEL=0 ;;
    BTAB|LEFT|h) PTAB=$(( (PTAB + 2) % 3 )); PSEL=0 ;;
    1|2|3) PTAB=$(($1 - 1)); PSEL=0 ;;
    ENTER)
      proj_items; row=${LN[$PSEL]-}; [ -n "$row" ] || return
      case $PTAB in
        0) reader_session "$row" ;;
        1) row=${row#*$'\t'}; row=${row#*$'\t'}; row=${row%%$'\t'*}; reader_open "$PJ_PATH/$row" "${P_N[$PJ]} › $row" ;;
      esac ;;
    c) [ $PTAB = 0 ] && tui_outside "" "continue_cmd '${P_N[$PJ]}' $((PSEL + 1))" ;;
    o) if [ $PTAB = 1 ]; then proj_items; row=${LN[$PSEL]-}; row=${row#*$'\t'}; row=${row#*$'\t'}; row=${row%%$'\t'*}
         [ -n "$row" ] && tui_outside "" "${EDITOR:-open} '$PJ_PATH/$row'" nopause; fi ;;
    MOUSE) proj_mouse ;;
    ESC|q|BS) VIEW=dash ;;
    Q) QUIT=1 ;;
  esac
}

proj_mouse() {  # wheel moves through the list; click a tab, or a row (the selected row again: open it)
  local i x=2 t row
  case $MOUSE_B in
    64) [ $PSEL -gt 0 ] && PSEL=$((PSEL - 1)) ;;
    65) proj_items; [ $PSEL -lt $((${#LN[@]} - 1)) ] && PSEL=$((PSEL + 1)) ;;
    0) [ "$MOUSE_UP" = 1 ] && return
       if [ "$MOUSE_Y" = 2 ]; then   # the tab row: " 1 Sessions   2 Docs   3 Git"
         i=0; for t in $TABS; do
           [ "$MOUSE_X" -ge $x ] && [ "$MOUSE_X" -lt $((x + ${#t} + 4)) ] && { PTAB=$i; PSEL=0; return; }
           x=$((x + ${#t} + 5)); i=$((i + 1))
         done; return
       fi
       [ "$PTAB" = 2 ] && return
       row=$((MOUSE_Y - 4 + PROJ_OFF))   # rows 3 and 4: the list's border, then its first line
       [ "$MOUSE_Y" -ge 4 ] && [ "$MOUSE_Y" -lt $((4 + PROJ_H)) ] || return
       proj_items; [ $row -lt ${#LN[@]} ] || return
       if [ $row = $PSEL ]; then proj_key ENTER; else PSEL=$row; fi ;;
  esac
}

# ---------------------------------------------------------------- view: reader (Markdown files, session transcripts, the log)
reader_load() {  # $1 rendered file, $2 title, $3 back-view
  local l n=0
  RL=() RTOP=0 RHIT=-1 RQ="" RTITLE=$2 RBACK=$3
  while IFS= read -r l || [ -n "$l" ]; do RL[n]=$l; n=$((n + 1)); done < "$1"
  RN=$n
  VIEW=reader
}
reader_open() {  # $1 Markdown file, $2 title
  local tmp="$TUI_DIR/reader"
  MD_FORCE_COLOR=1 md_render "$1" $((COLS - 6)) > "$tmp" 2>/dev/null
  RSRC=$1; reader_load "$tmp" "$2" "$VIEW"
}
reader_session() {  # $1 session row
  local tool title file md="$TUI_DIR/session.md"
  tool=$(printf '%s' "$1" | cut -f3); title=$(printf '%s' "$1" | cut -f9); file=$(printf '%s' "$1" | cut -f10)
  if [ ! -f "$file" ] || ! sess_jq; then toast "this transcript is on $(sess_where "$(printf '%s' "$1" | cut -f1)") — only where it stopped is here"; return; fi
  { printf '# %s\n\n*%s · %s · %s*\n' "$title" "$(sess_name "$tool")" "$(sess_where "$(printf '%s' "$1" | cut -f1)")" "${P_N[$PJ]}"
    case $tool in claude) sess_claude_md "$file" ;; codex) sess_codex_md "$file" ;; esac
  } > "$md" 2>/dev/null
  reader_open "$md" "${P_N[$PJ]} › $(sess_name "$tool") › $title"
  RSRC=""
  RTOP=$(( RN > ROWS ? RN - ROWS + 4 : 0 ))   # a conversation: start at its end
}
log_open() {
  local tmp="$TUI_DIR/log"
  tail -n 400 "$LOG" 2>/dev/null | sed -E "s/^(\[[^]]*\]) ([a-z]+) /$K_MUTED\1$K_R $K_ACC\2$K_R /; s/ err / ${K_ERR}err$K_R /; s/ ok / ${K_OK}ok$K_R /" > "$tmp"
  RSRC=""; reader_load "$tmp" "log · $(short_path "$LOG")" "$VIEW"
  RTOP=$(( RN > ROWS ? RN - ROWS + 4 : 0 ))
}

reader_draw() {
  local h=$((ROWS - 4)) i l pct
  [ $RTOP -gt $((RN - h)) ] && RTOP=$((RN - h)); [ $RTOP -lt 0 ] && RTOP=0
  PC=()
  for ((i = 0; i < h; i++)); do
    l=${RL[$((RTOP + i))]-}
    if [ $((RTOP + i)) -eq $RHIT ]; then l="${K_SEL}${l//$'\033[0m'/$'\033[0m'$K_SEL}"; fi
    scrollbar $RTOP $h $RN $i
    tpad "$l" $((COLS - 6)); PC[$i]="$PAD$REPLY"
  done
  pct=$(( RN > 0 ? (RTOP + h > RN ? RN : RTOP + h) * 100 / RN : 100 ))
  panel $COLS $((ROWS - 2)) "$(tfit "$RTITLE" $((COLS - 30)); echo "$FIT")" 1 "$pct% · $((RTOP + 1))–$((RTOP + h > RN ? RN : RTOP + h))/$RN"
  for ((i = 0; i < ROWS - 2; i++)); do S[$((i + 1))]=${PB[$i]}; done
  tfit "$RTITLE" $((COLS - 24))
  topbar "${K_LINE}›${K_R} ${K_B}$FIT${K_R}" ""
  if [ -n "$PROMPT" ]; then prompt_bar "search"
  else statusbar "READ" "j/k:scroll space/b:page g/G:ends /:search n/N:next ]/[:heading$([ -n "$RSRC" ] && echo ' o:editor') esc:back" "${RQ:+${K_MUTED}/$RQ${K_R}}"; fi
}

reader_find() {  # $1 direction 1/-1 → RHIT, RTOP
  local i c plain
  [ -n "$RQ" ] || return
  shopt -s nocasematch
  for ((c = 1, i = RHIT + $1; c <= RN; c++, i = i + $1)); do
    [ $i -ge $RN ] && i=0; [ $i -lt 0 ] && i=$((RN - 1))
    tstrip "${RL[$i]}"
    [[ $STRIP == *"$RQ"* ]] && { RHIT=$i; RTOP=$((i - (ROWS - 4) / 3)); shopt -u nocasematch; return; }
  done
  shopt -u nocasematch
  toast "not found: $RQ"
}

reader_heading() {  # $1 direction → the next line that looks like a heading (◆, ▸, ▌ or a bold H1)
  local i plain
  for ((i = RTOP + $1; i >= 0 && i < RN; i = i + $1)); do
    tstrip "${RL[$i]}"; plain=${STRIP#"${STRIP%%[! ]*}"}
    case $plain in '◆ '*|'▸ '*|'▌ '*|'#### '*) RTOP=$i; return ;; esac
  done
}

reader_key() {
  local h=$((ROWS - 4))
  if [ -n "$PROMPT" ]; then   # typing a search
    case $1 in
      ENTER) RQ=$PROMPT_TEXT PROMPT="" RHIT=$((RTOP - 1)); reader_find 1 ;;
      ESC) PROMPT="" ;;
      BS) PROMPT_TEXT=${PROMPT_TEXT%?} ;;
      MOUSE|TICK|UP|DOWN|LEFT|RIGHT|TAB|BTAB|PGUP|PGDN|HOME|END) ;;
      *) PROMPT_TEXT="$PROMPT_TEXT$1" ;;
    esac
    return
  fi
  case $1 in
    DOWN|j) RTOP=$((RTOP + 1)) ;; UP|k) RTOP=$((RTOP - 1)) ;;
    ' '|PGDN|f) RTOP=$((RTOP + h - 1)) ;; b|PGUP) RTOP=$((RTOP - h + 1)) ;;
    d) RTOP=$((RTOP + h / 2)) ;; u) RTOP=$((RTOP - h / 2)) ;;
    g|HOME) RTOP=0 ;; G|END) RTOP=$RN ;;
    /) PROMPT=1 PROMPT_TEXT="" ;;
    n) reader_find 1 ;; N) reader_find -1 ;;
    ']') reader_heading 1 ;; '[') reader_heading -1 ;;
    MOUSE) case $MOUSE_B in 64) RTOP=$((RTOP - 3)) ;; 65) RTOP=$((RTOP + 3)) ;; esac ;;
    o) [ -n "$RSRC" ] && tui_outside "" "${EDITOR:-open} '$RSRC'" nopause ;;
    ESC|q|BS|LEFT|h) VIEW=$RBACK ;;
    Q) QUIT=1 ;;
  esac
}

# ---------------------------------------------------------------- view: park / resume, live
# The same run_project as on the command line, one project after another in a background job; each
# project's report lands in run.N, the tick turns its spinner into ✓ / ✗.
run_start() {  # $1 park|resume
  RUN_MODE=$1 RUN_BACK=$VIEW RUN_T0=$SECONDS
  rm -f "$TUI_DIR"/run.*
  ( lock
    : > "$TUI_DIR/run.locked"
    for ((i = 0; i < NP; i++)); do
      echo "$i" > "$TUI_DIR/run.cur"
      ( REPORT_OUT="$TUI_DIR/run.$i.tmp"; : > "$REPORT_OUT"; run_project "$RUN_MODE" "${P_N[$i]}" "${P_D[$i]}" "$(projects | awk -v n="${P_N[$i]}" '$1 == n {print $3; exit}')" )
      mv "$TUI_DIR/run.$i.tmp" "$TUI_DIR/run.$i"
    done
    registry_write
    : > "$TUI_DIR/run.done" ) </dev/null >/dev/null 2>&1 &
  RUN_PID=$!
  TUI_JOBS="${TUI_JOBS:-} $RUN_PID"
  VIEW=run
}

run_draw() {
  local i l lvl name msg icon errs=0 done=0 cur=-1 verb pct
  [ -f "$TUI_DIR/run.cur" ] && read -r cur < "$TUI_DIR/run.cur"
  [ "$RUN_MODE" = park ] && verb="parking" || verb="resuming"
  PC=()
  local n=0
  for ((i = 0; i < NP; i++)); do
    tfit "${P_N[$i]}" 14; tpad "${K_B}$FIT${K_R}" 15; name=$PAD
    if [ -f "$TUI_DIR/run.$i" ]; then
      done=$((done + 1))
      local any=0
      while IFS=$'\t' read -r lvl _ msg; do
        any=1
        case $lvl in ok) icon=$I_OK ;; err) icon=$I_ERR; errs=$((errs + 1)) ;; *) icon="${K_MUTED}·${K_R}"; msg="${K_MUTED}$msg${K_R}" ;; esac
        PC[n]="$icon $name$msg"; n=$((n + 1)); name="               "
      done < "$TUI_DIR/run.$i"
      [ $any = 0 ] && { PC[n]="${K_MUTED}·${K_R} $name${K_MUTED}not on this Mac${K_R}"; n=$((n + 1)); }
    elif [ "$i" = "$cur" ]; then spinner; PC[n]="$REPLY $name${K_MUTED}${verb}…${K_R}"; n=$((n + 1))
    else PC[n]="${K_LINE}○${K_R} $name"; n=$((n + 1)); fi
  done
  PC[n]=""; n=$((n + 1))
  if [ -f "$TUI_DIR/run.done" ]; then
    if [ $errs -eq 0 ] && [ "$RUN_MODE" = park ]; then PC[n]="$I_OK ${K_B}All parked.${K_R} On your next Mac: ${K_ACC}roam resume${K_R}"
    elif [ $errs -eq 0 ]; then PC[n]="$I_OK ${K_B}Ready.${K_R} Open Xcode and Claude Code now."
    else PC[n]="$I_ERR $errs problem$([ $errs = 1 ] || echo s) — see above"; fi
  elif [ ! -f "$TUI_DIR/run.locked" ] && ! kill -0 "$RUN_PID" 2>/dev/null; then
    PC[n]="${K_WARN}•${K_R} roam is busy (a background run?) — try again in a moment"
  fi
  pct=$(( NP > 0 ? done * 100 / NP : 100 ))
  # progress in the tab or dock where the terminal shows it (OSC 9;4: Ghostty, iTerm2, Windows Terminal)
  if [ -f "$TUI_DIR/run.done" ]; then printf '\033]9;4;0\033\\' >/dev/tty; else printf '\033]9;4;1;%d\033\\' "$pct" >/dev/tty; fi
  thl $(( (COLS - 30) * pct / 100 )) "━"; local bar="${K_ACC}$HL${K_R}"; thl $(( (COLS - 30) - (COLS - 30) * pct / 100 )) "─"
  panel $COLS $((ROWS - 2)) "$([ "$RUN_MODE" = park ] && echo Park || echo Resume)" 1 "$done of $NP · $((SECONDS - RUN_T0)) s"
  for ((i = 0; i < ROWS - 2; i++)); do S[$((i + 1))]=${PB[$i]}; done
  S[$((ROWS - 3))]="${K_ACC}│${K_R} $bar${K_LINE}$HL${K_R} ${K_MUTED}$pct%${K_R}"; tpad "${S[$((ROWS - 3))]}" $((COLS - 1)); S[$((ROWS - 3))]="$PAD${K_ACC}│${K_R}"
  topbar "${K_LINE}›${K_R} ${K_B}$([ "$RUN_MODE" = park ] && echo park || echo resume)${K_R}" ""
  if [ -f "$TUI_DIR/run.done" ] || { [ ! -f "$TUI_DIR/run.locked" ] && ! kill -0 "$RUN_PID" 2>/dev/null; }; then
    statusbar "DONE" "⏎:back"
  else statusbar "$(echo "$RUN_MODE" | tr a-z A-Z)" "" "${K_MUTED}$verb — the app stays open${K_R}"; fi
}

run_key() {
  if [ -f "$TUI_DIR/run.done" ] || { [ ! -f "$TUI_DIR/run.locked" ] && ! kill -0 "$RUN_PID" 2>/dev/null; }; then
    case $1 in MOUSE|TICK) ;; Q) QUIT=1 ;; *) VIEW=$RUN_BACK; tui_refresh ;; esac
  fi
}

# ---------------------------------------------------------------- overlays
toast() { TOAST=$1; TOAST_T=15; }
toast_draw() {
  [ "${TOAST_T:-0}" -gt 0 ] || return 0
  local w r
  tfit "$TOAST" $((COLS - 10)); tvis "$FIT"; w=$((VIS + 4))
  r=$((ROWS - 3))
  S[$r]="${S[$r]-}"
  S[$r]="  ${K_ACC}╭$(thl $((w - 2)); echo "$HL")╮${K_R}"
  S[$((r + 1))]="  ${K_ACC}│${K_R} $FIT ${K_ACC}│${K_R}"
}

HELP="Everywhere
  ?        this help                 Q        quit roam
  esc / q  back                      u        refresh, ask the remotes
Lists
  ↑↓ j k   move                      ⏎        open
  ⇥ / 1-3  switch tab                g / G    first / last
  /        filter projects           mouse    wheel scrolls, click selects
Dashboard
  r        resume all projects       p        park all projects
  s        AI sessions               v        docs
  c        continue newest session   d / f    doctor / fix
  n        new project               a / L    add a project / log
Reader
  space b  page down / up            / n N    search, next, previous
  ] [      next / previous heading   o        open in your editor"

help_draw() {
  local w=80 h i l y x n=0 lines=()
  local IFS=$'\n'; for l in $HELP; do lines[n]=$l; n=$((n + 1)); done; unset IFS
  h=$((n + 2)); [ $w -gt $((COLS - 4)) ] && w=$((COLS - 4))
  y=$(( (ROWS - h) / 2 )); x=$(( (COLS - w) / 2 ))
  for ((i = 1; i < ROWS - 1; i++)); do tstrip "${S[$i]-}"; S[$i]="$K_DIM$STRIP"; done
  PC=()
  for ((i = 0; i < n; i++)); do
    l=${lines[$i]}
    case $l in ' '*) PC[$i]="${K_ACC}${l:0:11}${K_R}${l:11:26}${K_ACC}${l:37:9}${K_R}${l:46}" ;; *) PC[$i]="${K_B}$l${K_R}" ;; esac
  done
  panel $w $h "Keys" 1 "esc closes"
  for ((i = 0; i < h; i++)); do
    tstrip "${S[$((y + i))]-}"; tpad "$STRIP" "$COLS"; l=$PAD   # printf %-*s would pad bytes, not characters
    S[$((y + i))]="$K_DIM${l:0:$x}$K_R${PB[$i]}$K_DIM${l:$((x + w))}"
  done
}

# ---------------------------------------------------------------- running things outside the app
tui_outside() {  # $1 title (empty: none), $2 shell code, $3 "nopause"
  tui_leave
  clear
  [ -n "$1" ] && printf '\n  %s%s%s\n\n' "$C_BOLD" "$1" "$C_RESET"
  ( eval "$2" )
  [ "${3:-}" = nopause ] || { printf '\n  %spress any key to go back%s' "$C_MUTED" "$C_RESET"; IFS= read -rsn1 _ </dev/tty; }
  tui_enter
}

# ---------------------------------------------------------------- main loop
tui_frame() {
  NOW=$(date +%s)
  S=()
  case $VIEW in dash) dash_draw ;; proj) proj_draw ;; reader) reader_draw ;; run) run_draw ;; esac
  toast_draw
  [ "$HELP_ON" = 1 ] && help_draw
  local i
  for ((i = 0; i < ROWS; i++)); do fb_line $i "${S[$i]-}"; done
  fb_flush
}

tui_snapshot() {  # ROAM_TUI_SNAPSHOT=dash|proj|help: one frame on stdout, no terminal needed (tests, docs)
  FILTER="${ROAM_TUI_FILTER:-}" VIDX=() DASH_OFF=0 DASH_LW=0 DASH_H=0 PROJ_OFF=0 PROJ_H=0
  TUI_DIR=$(mktemp -d -t roam-tui); SEL=0 BUSY="" TICKS=0 HELP_ON=0 TOAST_T=0 PROMPT="" PV_KEY="" FULL=1 PREV=() FB=""
  tui_palette; tui_size
  tui_load
  [ "$ROAM_TUI_SNAPSHOT" = load ] && { rm -rf "$TUI_DIR"; return; }
  tui_bg_sessions
  VIEW=dash NOW=$(date +%s)
  case $ROAM_TUI_SNAPSHOT in proj) proj_open 0 ;; help) HELP_ON=1 ;;
    esac
  S=()
  case $VIEW in dash) dash_draw ;; proj) proj_draw ;; esac
  [ "$HELP_ON" = 1 ] && help_draw
  local i; for ((i = 0; i < ROWS; i++)); do printf '%s%s\n' "${S[$i]-}" "$K_R"; done
  rm -rf "$TUI_DIR"
}

tui_intro() {  # the logo, centered, with its gradient sweeping in — 6 frames, about a quarter second
  [ -z "${ROAM_NO_ANIM:-}" ] || return 0
  local i t="◆  r o a m" y=$((ROWS / 2 - 1)) x
  x=$(( (COLS - ${#t}) / 2 ))
  for i in 1 2 3 4 5 6; do
    tui_grad "${t:0:$(( ${#t} * i / 6 ))}"
    printf '\033[%d;%dH%s' $((y + 1)) $((x + 1)) "$REPLY" >/dev/tty
    sleep 0.04
  done
  printf '\033[%d;%dH%s%s' $((y + 3)) $(( (COLS - 23) / 2 + 1 )) "$K_MUTED" "same work · every Mac$K_R" >/dev/tty
  sleep 0.15
}

tui_main() {
  local i
  export LC_ALL=${LC_ALL:-${LC_CTYPE:-en_US.UTF-8}}   # ${#s} counts characters only in a UTF-8 locale
  TUI_DIR=$(mktemp -d -t roam-tui)
  FILTER="" VIDX=() DASH_OFF=0 DASH_LW=0 DASH_H=0 PROJ_OFF=0 PROJ_H=0 MOUSE_B=0 MOUSE_X=0 MOUSE_Y=0 MOUSE_UP=0
  SEL=0 VIEW=dash BUSY="" TICKS=0 HELP_ON=0 QUIT=0 TOAST="" TOAST_T=0 PROMPT="" PROMPT_TEXT="" PV_KEY="" FB="" RESIZED=0 DIRTY=1
  tui_palette; tui_size
  trap 'tui_leave; [ -n "${TUI_JOBS:-}" ] && kill $TUI_JOBS 2>/dev/null; rm -rf "$TUI_DIR"' EXIT
  trap 'exit 130' INT TERM HUP
  trap 'RESIZED=1' WINCH
  tui_enter
  tui_intro
  # the cached picture first, the remotes after: usable at once
  tui_refresh fetch
  while [ "$QUIT" = 0 ]; do
    if [ "$DIRTY" = 1 ]; then tui_frame; DIRTY=0; [ -n "${ROAM_TUI_DEBUG:-}" ] && echo "$SECONDS frame view=$VIEW" >> "$ROAM_TUI_DEBUG"; fi
    tui_key
    [ -n "${ROAM_TUI_DEBUG:-}" ] && [ "$KEY" != TICK ] && echo "$SECONDS key=$KEY view=$VIEW" >> "$ROAM_TUI_DEBUG"
    if [ "$KEY" = TICK ]; then
      TICKS=$((TICKS + 1))
      [ "$RESIZED" = 1 ] && { RESIZED=0; tui_size; UI_W=$((COLS - 2)); FULL=1; PV_KEY=""; PST_KEY=""; DIRTY=1; }
      [ "${TOAST_T:-0}" -gt 0 ] && { TOAST_T=$((TOAST_T - 1)); [ $TOAST_T = 0 ] && FULL=1; DIRTY=1; }
      [ $((TICKS % 150)) = 0 ] && DIRTY=1   # the clock and "n min ago", every 30 s
      tui_poll
      [ "$DIRTY" = 0 ] && [ -n "$BUSY" ] && [ "$VIEW" = dash ] && tui_tick_status
      continue
    fi
    DIRTY=1
    if [ "$HELP_ON" = 1 ]; then HELP_ON=0; FULL=1; continue; fi
    case $KEY in
      '?') HELP_ON=1; continue ;;
    esac
    case $VIEW in dash) dash_key "$KEY" ;; proj) proj_key "$KEY" ;; reader) reader_key "$KEY" ;; run) run_key "$KEY" ;; esac
    [ "$VIEW" != "${LAST_VIEW:-}" ] && { FULL=1; LAST_VIEW=$VIEW; }
  done
}
