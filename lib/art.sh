# roam — a little art: the logo and the old Macs, when the app starts and a command is done.
# Only in a terminal with colors; never in scripts, pipes, the background run or with NO_COLOR.
# ROAM_NO_ART=1 turns it off. Pure bash 3.2.

ART_LOGO='██████╗  ██████╗  █████╗ ███╗   ███╗
██╔══██╗██╔═══██╗██╔══██╗████╗ ████║
██████╔╝██║   ██║███████║██╔████╔██║
██╔══██╗██║   ██║██╔══██║██║╚██╔╝██║
██║  ██║╚██████╔╝██║  ██║██║ ╚═╝ ██║
╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝'

# The old Macs, drawn in the six stripes of the old rainbow logo: the compact Mac (Happy and Sad), the
# PowerBook, the iMac G3.
# the Happy Mac: all is well
ART_HAPPY='╭──────────────╮
│ ╭──────────╮ │
│ │   ▌  ▐   │ │
│ │     ╯    │ │
│ │  ╰────╯  │ │
│ ╰──────────╯ │
│        ═══   │
│ ▪            │
╰─┬──────────┬─╯
  ╰──────────╯'

# the Sad Mac: something went wrong
ART_SAD='╭──────────────╮
│ ╭──────────╮ │
│ │   ╳  ╳   │ │
│ │     ╯    │ │
│ │  ╭────╮  │ │
│ ╰──────────╯ │
│        ═══   │
│ ▪            │
╰─┬──────────┬─╯
  ╰──────────╯'

# parking: the PowerBook's work goes up to the remote
ART_PARK='  ╭────────────╮
  │ ╭────────╮ │
  │ │ ░▒▓▒░  │ │
  │ │        │ │               .-~~~-.
  │ ╰────────╯ │    ─ ─ ─▶    (   ☁   )
  ╰────────────╯             (_________)
 ╱ ▫▫▫▫▫▫▫▫▫▫▫ ╲
╱  ▫▫▫▫▫▫▫▫▫▫▫  ╲
╲──────(◯)──────╱'

# resuming: the work comes down, the Happy Mac is ready
ART_RESUME='                       ╭──────────────╮
                       │ ╭──────────╮ │
                       │ │   ▌  ▐   │ │
  .-~~~-.              │ │     ╯    │ │
 (   ☁   )    ─ ─ ─▶   │ │  ╰────╯  │ │
(_________)            │ ╰──────────╯ │
                       │        ═══   │
                       │ ▪            │
                       ╰─┬──────────┬─╯
                         ╰──────────╯'

# in sync: the compact Mac and the iMac, the same
ART_SYNC='╭──────────────╮
│ ╭──────────╮ │                ╭──────────╮
│ │   ▌  ▐   │ │               ╱ ╭────────╮ ╲
│ │     ╯    │ │              │  │ ░▒▓▒░  │  │
│ │  ╰────╯  │ │   ◀─ ≡ ─▶    │  │        │  │
│ ╰──────────╯ │              │  ╰────────╯  │
│        ═══   │               ╲   ◖────◗   ╱
│ ▪            │                ╰──┬────┬──╯
╰─┬──────────┬─╯                  ═╧════╧═
  ╰──────────╯'

# a new project says hello
ART_NEW='╭──────────────╮
│ ╭──────────╮ │
│ │          │ │
│ │  hello   │ │
│ │       ▌  │ │
│ ╰──────────╯ │
│        ═══   │
│ ▪            │
╰─┬──────────┬─╯
  ╰──────────╯'

# setup: as every Mac once greeted you
ART_WELCOME='╭──────────────╮
│ ╭──────────╮ │
│ │   ▌  ▐   │ │    ╭─────────────────────╮
│ │     ╯    │ │    │                     │
│ │  ╰────╯  │ │    │  Welcome to roam.   │
│ ╰──────────╯ │    │                     │
│        ═══   │    ╰─────────────────────╯
│ ▪            │
╰─┬──────────┬─╯
  ╰──────────╯'

# letter by letter only where bash counts characters: in a C locale a letter is several bytes, and
# a color between them breaks it
ART_UTF8=0; _a='█'; [ ${#_a} = 1 ] && ART_UTF8=1; unset _a

art_on() { [ "$UI_FANCY" = 1 ] && [ -z "${ROAM_NO_ART:-}" ] && [ -t 1 ]; }

art_paint() {  # $1 art (lines), $2 indent, $3 rainbow → painted; every column (or row) the same color in every line
  # default: the logo's pink → violet → cyan, column by column; rainbow: green, yellow, orange, red, purple,
  # blue, row by row — the old Macs
  local art=$1 ind=${2:-2} l w=0 i c out lines=() n=0 ramp=(213 177 141 105 81) bow=(77 220 214 203 135 75)
  while IFS= read -r l; do lines[n]=$l; n=$((n + 1)); [ ${#l} -gt $w ] && w=${#l}; done <<EOF
$art
EOF
  [ $w -gt 1 ] || w=2
  for ((n = 0; n < ${#lines[@]}; n++)); do
    l=${lines[$n]} out=""
    if [ "$UI_256" != 1 ]; then out="$C_ACCENT$l"
    elif [ "${3:-}" = rainbow ]; then out=$'\033[38;5;'"${bow[$(( n * 6 / ${#lines[@]} ))]}m$l"
    elif [ "$ART_UTF8" = 1 ]; then
      for ((i = 0; i < ${#l}; i++)); do
        c=${l:i:1}
        if [ "$c" = " " ]; then out="$out "; else out="$out"$'\033[38;5;'"${ramp[$(( i * 4 / (w - 1) ))]}m$c"; fi
      done
    else out="$C_ACCENT$l"; fi
    printf '%*s%s%s\n' "$ind" '' "$out" "$C_RESET"
  done
}

art() {  # $1 art, $2 indent, $3 "lead": a blank line before it — an old Mac in rainbow stripes, a blank line
  art_on || return 0   # after it; only where art_on says so and it fits
  local l w=0
  while IFS= read -r l; do [ ${#l} -gt $w ] && w=${#l}; done <<EOF
$1
EOF
  [ $(( w + ${2:-2} )) -le "$(ui_width)" ] || return 0
  [ "${3:-}" = lead ] && echo
  art_paint "$1" "${2:-2}" rainbow; echo
}

banner() {  # $1 subtitle, $2 right — the big logo where there's art, else the one-line header
  local sub=${1:-v$ROAM_VERSION} r=${2:-}
  art_on || { header "$sub" "$r"; return 0; }
  echo; art_paint "$ART_LOGO" 2
  # under the logo, as wide as it: what roam is for on the left, the subtitle on the right
  r="$sub${r:+ · $r}"
  printf '  %ssame work · every Mac%*s%s%s\n' "$C_MUTED" $(( 36 - 21 - ${#r} > 1 ? 36 - 21 - ${#r} : 2 )) '' "$r" "$C_RESET"
}

greeting() {  # good morning / afternoon / evening, by this Mac's clock
  local h; h=$(date +%H); h=${h#0}
  if [ "$h" -lt 5 ]; then echo "working late"
  elif [ "$h" -lt 12 ]; then echo "good morning"
  elif [ "$h" -lt 18 ]; then echo "good afternoon"
  else echo "good evening"; fi
}

about_info() {  # → ABOUT[]: what About This Mac shows; "label<TAB>value", or plain lines (the first is the name)
  local f n=0 on=0 np=0 ns=0 npk=0 name dir remote extra now
  now=$(date +%s)
  while IFS= read -r f; do [ -n "$f" ] || continue
    n=$((n + 1)); [ $(( now - $(t=$(val seen "$f"); echo "${t:-0}") )) -lt "$ONLINE_SECS" ] && on=$((on + 1))
  done <<EOT
$(mac_files)
EOT
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    np=$((np + 1))
    [ "$(sync_state "$name")" = sync ] && ns=$((ns + 1))
    [ -d "$PROJECTS_DIR/$dir/.git" ] && git -C "$PROJECTS_DIR/$dir" rev-parse -q --verify "refs/remotes/roam/$MAC" >/dev/null && npk=$((npk + 1))
  done <<EOT
$(projects)
EOT
  ABOUT=("roam $ROAM_VERSION" "same work · every Mac" ""
         "This Mac$TAB$(short_name "$(scutil --get ComputerName)") · macOS $(sw_vers -productVersion)"
         "Pool$TAB$(short_path "$POOL")"
         "Macs$TAB$n in the pool · $on online"
         "Projects$TAB$np · $ns ≡ in sync · $npk parked here"
         "" "bash, git and a folder your Macs share")
}

about_cmd() {  # About This Mac, roam style: the Happy Mac, the version, this Mac, the pool at a glance
  local info=() l i k=0 w arts=() bow=(77 220 214 203 135 75)
  about_info
  for ((i = 0; i < ${#ABOUT[@]}; i++)); do
    l=${ABOUT[$i]}
    case $l in
      *"$TAB"*) info[i]="$C_MUTED$(pad "${l%%"$TAB"*}" 11)$C_RESET$(trunc "${l#*"$TAB"}" $(( $(ui_width) - 35 )))" ;;
      *) if [ $i = 0 ]; then info[i]="$C_BOLD$l$C_RESET"; else info[i]="$C_MUTED$l$C_RESET"; fi ;;
    esac
  done
  echo
  if art_on && [ "$ART_UTF8" = 1 ]; then
    while IFS= read -r l; do arts[k]=$l; k=$((k + 1)); done <<EOT
$ART_HAPPY
EOT
    for ((i = 0; i < k || i < ${#info[@]}; i++)); do
      l=${arts[$i]-} w=0
      [ -n "$l" ] && { w=${#l}; l=$'\033[38;5;'"${bow[$(( i * 6 / k ))]}m$l$C_RESET"; }
      printf '  %s%*s    %s\n' "$l" $(( 16 - w )) '' "${info[$i]-}"
    done
  else
    for l in "${info[@]}"; do printf '  %s\n' "$l"; done
  fi
  echo
}
