# roam — start a project: `roam new [name|folder]`.
# Creates (or adopts) a folder, writes a fitting .gitignore and README, creates the GitHub repo,
# pushes, and adds it to the pool — every other Mac gets it with its next `roam resume`.

gitignore_for() {  # $1 kind: xcode | swiftpm | node | other
  printf '# macOS\n.DS_Store\n._*\n\n'
  case $1 in
    xcode)
      printf '# Xcode\nxcuserdata/\n*.xcuserstate\n*.xcuserdatad\nDerivedData/\nbuild/\n*.ipa\n*.dSYM\n*.dSYM.zip\n*.hmap\n\n'
      printf '# Swift Package Manager\n.build/\n.swiftpm/\nPackages/\n\n'
      printf '# local configuration (keep a Local.xcconfig.example in git instead)\nLocal.xcconfig\n\n' ;;
    swiftpm)
      printf '# Swift Package Manager\n.build/\n.swiftpm/\nPackages/\nxcuserdata/\nDerivedData/\n\n' ;;
    node)
      printf '# Node\nnode_modules/\ndist/\nbuild/\n.next/\ncoverage/\n*.log\n\n' ;;
  esac
  printf '# secrets — never in git\n.env\n.env.*\n!.env.example\n*.pem\n*.p8\n*.p12\n*.key\n\n'
  printf '# Claude Code — personal overrides stay local\n.claude/settings.local.json\n'
}

kind_label() {  # $1 kind → words (a function: bash 3.2 mis-parses case inside $( ))
  case $1 in
    xcode) echo "an Xcode project" ;;
    swiftpm) echo "a Swift package" ;;
    node) echo "a Node project" ;;
    *) echo "a project" ;;
  esac
}

detect_kind() {  # $1 folder → xcode | swiftpm | node | other
  if [ -n "$(find "$1" -maxdepth 3 -name '*.xcodeproj' 2>/dev/null | head -1)" ]; then echo xcode
  elif [ -f "$1/Package.swift" ]; then echo swiftpm
  elif [ -f "$1/package.json" ]; then echo node
  else echo other; fi
}

new_project() {  # $1 optional: name, or path of an existing folder
  local arg=${1:-} dir name kind kind_n vis login gid remote adopt=0 msg
  [ -t 0 ] || { echo "roam new needs a terminal — it asks a few questions."; return 1; }
  header "new" "$(short_name "$(scutil --get ComputerName)")"
  printf '\n  %sStart a project — on every Mac in one go.%s\n' "$C_BOLD" "$C_RESET"

  if ! have gh || ! gh auth status >/dev/null 2>&1; then
    say_err "roam new creates the repo with the GitHub CLI."
    say_info "Install it: brew install gh — then sign in: gh auth login"
    say_info "Other git hosts: create the repo there, then  roam add <git remote>"
    return 1
  fi
  login=$(gh api user --jq '.login + " " + (.id|tostring)' 2>/dev/null)
  gid=${login#* }; login=${login%% *}

  # ------------------------------------------------------------ which folder?
  if [ -z "$arg" ] && [ "$(dirname "$PWD")" = "$PROJECTS_DIR" ] && [ ! -d "$PWD/.git/refs/remotes/origin" ]; then
    confirm "Publish this folder, $(basename "$PWD")?" y && arg=$PWD
  fi
  if [ -n "$arg" ] && [ -d "$arg" ]; then
    dir=$(cd "$arg" && pwd -P); adopt=1
  else
    name=${arg:-$(ask "Project name" "")}
    [ -n "$name" ] || return 1
    case $name in */*) [ -d "$name" ] && { dir=$(cd "$name" && pwd -P); adopt=1; } ;; esac
    [ $adopt = 1 ] || dir="$PROJECTS_DIR/$name"
    [ -d "$dir" ] && adopt=1
  fi
  name=$(basename "$dir")
  case $name in *[!A-Za-z0-9._-]*) say_err "use letters, digits, . _ - for the name"; return 1 ;; esac
  if projects | awk '{print $1}' | grep -q -x "$name"; then say_err "$name is already in the pool"; return 1; fi
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    say_info "$name already has a remote — adding it to the pool instead."
    add_project "$(git -C "$dir" remote get-url origin)" "$name"
    return
  fi
  if [ "$(dirname "$dir")" != "$PROJECTS_DIR" ]; then
    say_warn "$(short_path "$dir") is outside $(short_path "$PROJECTS_DIR") — other Macs will put it at $(short_path "$PROJECTS_DIR/$name")."
    confirm "Continue anyway?" n || return 1
  fi
  if gh repo view "$login/$name" >/dev/null 2>&1; then
    say_err "github.com/$login/$name exists already — clone it with: roam add git@github.com:$login/$name.git"; return 1
  fi

  # ------------------------------------------------------------ what kind?
  echo
  if [ $adopt = 1 ]; then kind=$(detect_kind "$dir"); else kind=""; fi
  if [ -z "$kind" ] || [ "$kind" = other ]; then
    say_info "What are you building?"
    kind_n=$(printf '%s\n' "iOS / macOS app (Xcode)" "Swift package" "Web / Node" "Something else" | choose)
    kind=$(echo "xcode swiftpm node other" | cut -d' ' -f"$kind_n")
  else
    say_ok "looks like $(kind_label "$kind")"
  fi

  say_info "Who can see it on GitHub?"
  vis=$(printf '%s\n' "Private — only you" "Public — everyone" | choose)
  [ "$vis" = 2 ] && vis=public || vis=private   # only an explicit choice makes it public

  # ------------------------------------------------------------ build it
  echo
  mkdir -p "$dir" || return 1
  cd "$dir" || return 1
  if [ ! -d .git ]; then git init -q -b main && say_ok "git repository"; fi
  if [ "$vis" = public ] && [ -n "$login" ]; then
    say_info "Public repos show the commit author. Your git identity here: $(git config user.name) <$(git config user.email)>"
    if confirm "Commit as $login (GitHub's private noreply address) instead?" y; then
      git config user.name "$login"
      git config user.email "$gid+$login@users.noreply.github.com"
      say_ok "commits in this repo: $login"
    fi
  fi
  [ -f .gitignore ] || { gitignore_for "$kind" > .gitignore; say_ok ".gitignore for $(echo "$kind" | sed 's/xcode/Xcode/; s/swiftpm/Swift packages/; s/node/Node/; s/other/general use/')"; }
  [ -f README.md ] || { printf '# %s\n' "$name" > README.md; say_ok "README.md"; }

  # nothing secret may slip into the first commit
  if [ -n "$(git ls-files --others --exclude-standard | grep -E "$SECRET_PATTERN")" ]; then
    say_err "secret-looking files would be committed: $(git ls-files --others --exclude-standard | grep -E "$SECRET_PATTERN" | head -3 | tr '\n' ' ')"
    say_info "add them to .gitignore and run roam new again"
    return 1
  fi
  # the exported fallback identity is meant for snapshots only — here the repo's own identity counts
  [ -n "$(git config user.name)" ] && unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  git add -A
  if git rev-parse -q --verify HEAD >/dev/null; then msg=""; else msg="Start $name"; fi
  [ -n "$msg" ] && git commit -q -m "$msg" && say_ok "first commit"

  remote=$(printf "${ROAM_NEW_REMOTE:-git@github.com:%s/%s.git}" "$login" "$name")
  ( gh repo create "$login/$name" "--$vis" >/dev/null 2>&1 ) & spin_while $! "${C_MUTED}creating github.com/$login/${name}…${C_RESET}"
  gh repo view "$login/$name" >/dev/null 2>&1 || { say_err "couldn't create the repo on GitHub"; return 1; }
  say_ok "github.com/$login/$name ${C_MUTED}($vis)${C_RESET}"
  git remote add origin "$remote" 2>/dev/null || git remote set-url origin "$remote"
  git push -q -u origin main 2>/dev/null || { say_err "push failed — check SSH access (roam setup)"; return 1; }
  say_ok "pushed"

  printf '%-12s %-12s %s\n' "$name" "$name" "$(ssh_remote "$remote")" >> "$PROJECTS_CONF"
  registry_write
  say_ok "in the pool — your other Macs get it with ${C_ACCENT}roam resume${C_RESET}"

  if [ "$kind" = xcode ] && [ -z "$(find "$dir" -maxdepth 3 -name '*.xcodeproj' 2>/dev/null | head -1)" ]; then
    echo
    say_info "Next: in Xcode › File › New › Project…, save it into $(short_path "$dir")"
    say_info "and untick “Create Git repository” — the folder already is one."
    confirm "Open Xcode now?" y && open -a Xcode
  fi
  echo
  printf '  %s %s%s is ready.%s %s%s%s\n' "$I_OK" "$C_BOLD" "$name" "$C_RESET" "$C_MUTED" "$(short_path "$dir")" "$C_RESET"
}
