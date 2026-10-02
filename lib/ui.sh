# roam — terminal UI toolkit: colors, boxes, spinner, prompts, arrow-key menus.
# Pure bash 3.2 (the one macOS ships), no dependencies. Degrades to plain text without a TTY.

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_INV=$'\033[7m'
  C_ACCENT=$'\033[38;5;141m' C_ACCENT2=$'\033[38;5;213m' C_CYAN=$'\033[38;5;81m'
  C_OK=$'\033[38;5;114m' C_WARN=$'\033[38;5;221m' C_ERR=$'\033[38;5;203m' C_MUTED=$'\033[38;5;244m'
  C_LINE=$'\033[38;5;238m'
  UI_FANCY=1 UI_256=1
elif [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_INV=$'\033[7m'
  C_ACCENT=$'\033[35m' C_ACCENT2=$'\033[35m' C_CYAN=$'\033[36m'
  C_OK=$'\033[32m' C_WARN=$'\033[33m' C_ERR=$'\033[31m' C_MUTED=$'\033[2m' C_LINE=$'\033[2m'
  UI_FANCY=1 UI_256=0
else
  C_RESET="" C_BOLD="" C_DIM="" C_INV="" C_ACCENT="" C_ACCENT2="" C_CYAN=""
  C_OK="" C_WARN="" C_ERR="" C_MUTED="" C_LINE=""
  UI_FANCY=0 UI_256=0
fi

I_OK="${C_OK}✓${C_RESET}" I_ERR="${C_ERR}✗${C_RESET}" I_WARN="${C_WARN}•${C_RESET}" I_ARROW="${C_ACCENT}❯${C_RESET}"

UI_W=$(stty size 2>/dev/null </dev/tty | awk '{print $2}'); UI_W=${UI_W:-80}
[ "$UI_W" -gt 100 ] && UI_W=100
[ "$UI_W" -lt 64 ] && UI_W=64
UI_W=$((UI_W - 2))
ui_width() { echo "$UI_W"; }   # usable width: terminal width clamped to 64…100, measured once

strip_ansi() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[mK]//g'; }
vis_len() { local s; s=$(strip_ansi "$1"); echo ${#s}; }

pad() {  # $1 text (may contain colors), $2 width → left-aligned, counts visible characters
  local n
  n=$(vis_len "$1")
  printf '%s%*s' "$1" $(( $2 > n ? $2 - n : 0 )) ''
}

trunc() {  # $1 plain text, $2 max width
  if [ ${#1} -gt "$2" ]; then printf '%s…' "${1:0:$(($2 - 1))}"; else printf '%s' "$1"; fi
}

repeat() { local i; for ((i = 0; i < $2; i++)); do printf '%s' "$1"; done; }

logo() {  # ◆ roam, in a little gradient where the terminal can do 256 colors
  if [ "$UI_256" = 1 ]; then
    printf '%s◆%s %s\033[38;5;213mr\033[38;5;177mo\033[38;5;141ma\033[38;5;105mm%s' "$C_ACCENT2" "$C_RESET" "$C_BOLD" "$C_RESET"
  else
    printf '%s◆ roam%s' "$C_BOLD" "$C_RESET"
  fi
}

header() {  # $1 subtitle (left), $2 right-aligned info
  local w l r
  w=$(ui_width)
  l="  $(logo)  ${C_MUTED}${1:-}${C_RESET}"
  r="${C_MUTED}${2:-}${C_RESET}"
  printf '\n%s%*s%s\n' "$l" $(( w - $(vis_len "$l") - $(vis_len "$r") )) '' "$r"
}

box_top() {  # $1 title, $2 optional right title
  local w t r
  w=$(ui_width)
  t="${C_LINE}╭─${C_RESET} ${C_BOLD}$1${C_RESET} "
  r=""
  [ -n "${2:-}" ] && r=" ${C_MUTED}$2${C_RESET} ${C_LINE}─╮${C_RESET}"
  [ -z "$r" ] && r="${C_LINE}╮${C_RESET}"
  printf '  %s%s%s%s\n' "$t" "$C_LINE" "$(repeat ─ $(( w - 2 - $(vis_len "$t") - $(vis_len "$r") )))" "$C_RESET$r"
}
box_line() {  # $1 content
  local w
  w=$(ui_width)
  printf '  %s│%s %s %s│%s\n' "$C_LINE" "$C_RESET" "$(pad "$1" $((w - 6)))" "$C_LINE" "$C_RESET"
}
box_bottom() { printf '  %s╰%s╯%s\n' "$C_LINE" "$(repeat ─ $(( $(ui_width) - 4 )))" "$C_RESET"; }

rule() { printf '  %s%s%s\n' "$C_LINE" "$(repeat ─ $(( $(ui_width) - 2 )))" "$C_RESET"; }

say_ok()   { printf '  %s %s\n' "$I_OK" "$*"; }
say_err()  { printf '  %s %s\n' "$I_ERR" "$*"; }
say_warn() { printf '  %s %s\n' "$I_WARN" "$*"; }
say_info() { printf '  %s%s%s\n' "$C_MUTED" "$*" "$C_RESET"; }

# ---------------------------------------------------------------- spinner
SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
spin_while() {  # $1 pid, $2 label – animates until the process ends
  local pid=$1 label=$2 i=0
  if [ "$UI_FANCY" != 1 ]; then wait "$pid" 2>/dev/null; return; fi
  tput civis 2>/dev/null
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$C_ACCENT" "${SPIN_FRAMES:$((i % 10)):1}" "$C_RESET" "$label"
    i=$((i + 1))
    sleep 0.08
  done
  printf '\r\033[K'
  tput cnorm 2>/dev/null
  wait "$pid" 2>/dev/null
}

# ---------------------------------------------------------------- input
read_key() {  # one key; arrows come back as UP/DOWN/LEFT/RIGHT, Enter as ENTER
  local k rest
  IFS= read -rsn1 k </dev/tty
  if [ "$k" = $'\033' ]; then
    IFS= read -rsn2 -t 1 rest </dev/tty
    case $rest in '[A') k=UP ;; '[B') k=DOWN ;; '[C') k=RIGHT ;; '[D') k=LEFT ;; *) k=ESC ;; esac
  elif [ -z "$k" ]; then k=ENTER
  fi
  printf '%s' "$k"
}

ask() {  # $1 label, $2 default → answer on stdout
  local a
  printf '  %s %s%s%s ' "$I_ARROW" "$1" "${2:+ ${C_MUTED}($2)${C_RESET}}" "${C_ACCENT}" >/dev/tty
  IFS= read -r a </dev/tty
  printf '%s' "$C_RESET" >/dev/tty
  printf '%s' "${a:-${2:-}}"
}

confirm() {  # $1 question, $2 default y|n
  local a hint
  [ "${2:-n}" = y ] && hint="Y/n" || hint="y/N"
  printf '  %s %s %s[%s]%s ' "$I_ARROW" "$1" "$C_MUTED" "$hint" "$C_RESET" >/dev/tty
  IFS= read -r a </dev/tty
  a=${a:-${2:-n}}
  case $a in y|Y|yes|Yes|j|J) return 0 ;; *) return 1 ;; esac
}

choose() {  # options on stdin, one per line → number of the chosen one (1…n) on stdout. ↑↓ + Enter, or digits.
  local opts=() o n sel=0 i k
  while IFS= read -r o; do opts+=("$o"); done
  n=${#opts[@]}
  [ "$n" -gt 0 ] || return 1
  if [ "$UI_FANCY" != 1 ]; then
    for ((i = 0; i < n; i++)); do printf '   %d) %s\n' $((i + 1)) "${opts[$i]}" >/dev/tty; done
    while :; do k=$(ask "Choice" 1); case $k in *[!0-9]*|"") ;; *) [ "$k" -ge 1 ] && [ "$k" -le "$n" ] && { echo "$k"; return; } ;; esac; done
  fi
  tput civis 2>/dev/null >/dev/tty
  while :; do
    for ((i = 0; i < n; i++)); do
      if [ $i -eq $sel ]; then printf '\033[K   %s❯ %s%s\n' "$C_ACCENT" "${opts[$i]}" "$C_RESET" >/dev/tty
      else printf '\033[K     %s%s%s\n' "$C_MUTED" "${opts[$i]}" "$C_RESET" >/dev/tty; fi
    done
    printf '     %s↑↓ move · ⏎ select%s' "$C_LINE" "$C_RESET" >/dev/tty
    k=$(read_key)
    case $k in
      UP|k) sel=$(( (sel - 1 + n) % n )) ;;
      DOWN|j) sel=$(( (sel + 1) % n )) ;;
      [1-9]) [ "$k" -le "$n" ] && { sel=$((k - 1)); k=ENTER; } ;;
    esac
    printf '\r\033[K\033[%dA' "$n" >/dev/tty
    if [ "$k" = ENTER ]; then
      for ((i = 0; i < n; i++)); do printf '\033[K\n' >/dev/tty; done
      printf '\033[%dA' "$n" >/dev/tty
      printf '   %s❯%s %s\n' "$C_ACCENT" "$C_RESET" "${opts[$sel]}" >/dev/tty
      tput cnorm 2>/dev/null >/dev/tty
      echo $((sel + 1))
      return
    fi
  done
}
