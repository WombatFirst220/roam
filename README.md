<h1 align="center">◆ roam</h1>

<p align="center">
  <b>Work on the same projects from every Mac — and pick up exactly where you left off.</b><br>
  Uncommitted changes, new files, unpushed commits, even your Claude Code memory. Two commands, no server.
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Homebrew" src="https://img.shields.io/badge/brew-wombatfirst220%2Ftap-orange?logo=homebrew">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="Dependencies" src="https://img.shields.io/badge/dependencies-none-brightgreen">
</p>

---

You start a feature on the Mac mini at your desk. In the evening you grab the MacBook.
Normally that means: commit half-finished work, push, pull, hope you didn't forget a file.

With roam:

```console
mac-mini $ roam park
  ✓ MyApp         parked · feature/login · 4 files +120 −8

macbook  $ roam resume
  ✓ MyApp         resumed from Mac mini · 2 min ago · feature/login · 4 files +120 −8
  ✓ Ready. Open Xcode and Claude Code now.
```

Same branch, same uncommitted changes, same new files. And if you forget `roam park` —
a background job already did it for you a few minutes ago.

## Install

```bash
brew install wombatfirst220/tap/roam
roam setup
```

That's it — on every Mac. Updates: `brew update && brew upgrade wombatfirst220/tap/roam`
(always with the full name — Homebrew also has an unrelated cask called `roam`). The setup wizard walks you through everything:

| | Step | What happens |
|---|---|---|
| 1 | **Pool** | finds an existing pool in iCloud Drive, Dropbox, kDrive, Nextcloud or `~/Library/CloudStorage` — or creates one |
| 2 | **Projects folder** | `~/Developer` by default, the same path on every Mac |
| 3 | **Git access** | checks your remotes; creates an SSH key, copies it and opens GitHub's key page if needed |
| 4 | **Projects** | picks up repos you already have, offers your GitHub repos (with `gh`), or takes any git URL |
| 5 | **Auto-park** | a tiny LaunchAgent parks unfinished work every 10 minutes |
| 6 | **Bring everything here** | clones what's missing, resumes work from your other Macs |
| 7 | **Prerequisites** | checks Xcode, SDKs, signing, Node, … and offers to fix what it can |

Run `roam setup` again any time — it confirms what's fine and repairs what isn't.

## Start a new project

```bash
roam new MyApp
```

One command instead of ten: roam asks what you're building (iOS/macOS app, Swift package, web, other)
and who may see it, then creates the folder, a fitting `.gitignore` and README, the GitHub repo,
the first push — and adds it to the pool. Your other Macs get it with their next `roam resume`.

Already made the folder, say in Xcode? Run `roam new` inside it, or `roam new ~/Developer/MyApp`.
Public repos can be committed under your GitHub username and its private noreply address, so
your real name and email stay off the internet.

## The app

Just type `roam`:

```
 ◆ roam  v1.3.1                                                                               14:02
╭─ Projects ─────────────────────────── 3 ─╮╭─ MyApp ───────────────────────────────────── ⏎ open ─╮
│ ❯ MyApp          feature/lo… ●4 ☁ ✻ 2m ● ││ Mac mini          feature/login ●4 ☁                 │
│   Website        main ✓            ◇ 3h  ││ MacBook Pro       main ✓                             │
│   Backend        main ↑2                 ││ ☁ parked here · 2m ago · feature/login               │
│                                          ││                                                      │
│                                          ││ AI sessions                                          │
│                                          ││ ✻ Fix the login               this Mac · 2m ●        │
│                                          ││ ◇ Add dark mode               MacBook Pro · 1 h      │
│                                          ││     recap   Login works again, README still open.    │
│                                          ││     you     also cover the expired token case        │
│                                          ││                                                      │
│                                          ││ Docs                                                 │
│                                          ││ README.md · CLAUDE.md · CHANGELOG.md · docs/api.md   │
╰──────────────────────────────────────────╯╰──────────────────────────────────────────────────────╯
╭─ Macs ──────────────────────────────────────────────────────────────── pool · iCloud Drive/roam ─╮
│ ▸ Mac mini             this Mac     macOS 26.1   Xcode 26.1   ✓ ready                            │
│ ● MacBook Pro          online       macOS 26.1   Xcode 26.1   ✗ 1 missing                        │
╰──────────────────────────────────────────────────────────────────────────────────────────────────╯
 ROAM   ⏎ open  / filter  r resume  p park  s sessions  v docs  ? help  q quit    ⠹ checking the remotes…
```

Every Mac reports its state to the pool, so you see your other Macs even while they sleep. The app
opens at once with what the pool knows and asks the remotes in the background.

- **⏎** opens a project: **Sessions** (where each AI session stopped, `⏎` reads it, `c` continues it),
  **Docs** (README, CLAUDE.md, … with a preview, `⏎` reads it, `o` opens your editor) and **Git**.
  `⇥` or `1`–`3` switch tabs, `esc` goes back.
- **r** resume and **p** park right in the app: one row per project, a spinner while it runs, ✓ or ✗ with
  the details when it's done — and a progress bar, in the tab too where the terminal shows one (Ghostty,
  iTerm2). **d** doctor, **f** fix, **n** new, **a** add run in the terminal as usual and bring you back.
  **L** log, **u** refresh, **?** shows every key.
- **/** filters the projects as you type (`wi` finds WIMM), `esc` clears it.
- The mouse works too: the wheel scrolls, a click selects, a click on the selected project opens it, a click
  on a tab switches to it. To select text, hold ⌥ or ⇧ while dragging (which one depends on the terminal),
  or turn the mouse off with `ROAM_MOUSE=0`.
- The reader scrolls with `j`/`k`, `space`/`b`, `g`/`G`; `/` searches, `n`/`N` jump, `]`/`[` go to the
  next or previous heading — or the next prompt in a session.
- Truecolor in iTerm2, Ghostty, WezTerm, VS Code and Terminal on macOS 26 and later, 256 colors elsewhere
  (`ROAM_COLOR=256` forces it). `roam classic` — or `ROAM_PLAIN=1` — gives you the previous menu,
  `roam status` the dashboard as plain text.

## Where did the AI leave off?

Claude Code on the Mac mini, Codex on the MacBook — and on the next Mac you want to know where each
session stopped. `roam sessions` shows the AI sessions of every project, from every Mac:

```console
$ roam sessions MyApp
  1  ✻ Fix the login                 MacBook Pro · 2 min ago · feature/login · 12 prompts · ● running
  2  ◇ Add dark mode                 this Mac · 1 h ago · main
  3  ✻ App Store review checklist    Mac mini · 3 days ago · main · 8 prompts

  ✻ Fix the login                    MacBook Pro · 2 min ago · feature/login · 12 prompts · ● running
    recap   Login works again, README still open.
    you     also cover the expired token case
    ✻ ai    Done — expired tokens now send you back to the login screen …
    todos
            ✓ Write the test
            ◐ Update README
    files   Sources/Auth/Login.swift · Tests/LoginTests.swift
```

| | |
|---|---|
| `roam sessions` | inside a project: its sessions; elsewhere: the newest session of every project |
| `roam session MyApp 2` | read session 2 — prompts, replies, one line per tool call — in a scrollable reader |
| `roam continue MyApp` | `claude --resume` / `codex resume` that session, in the project folder |
| `roam read MyApp` | README, CLAUDE.md, AGENTS.md, TODO, CHANGELOG, docs … rendered in the same reader |

The app shows them too: each project's newest session in the preview, all of them under ⏎ › Sessions.

- **This Mac** is read live from Claude Code (`~/.claude/projects`) and Codex (its own database,
  read-only) — only the end of a transcript, so even 200 MB sessions open instantly.
- **Other Macs** leave a digest per project in the pool (`sessions/<Mac>/<project>.txt`, at most 8 KB):
  title, branch, todos, changed files and — with `session_digest = 2`, the default — the last prompt,
  reply and recap, with API keys, tokens and passwords masked. `session_digest = 1` leaves out the
  texts, `0` shares nothing.
- Details and transcripts use `jq`, which macOS 15 and later ship. On older macOS: `brew install jq`.
- The reader: `j`/`k` or arrows, `space`/`b` page, `g`/`G` start/end, `/` search, `n`/`N` next/previous, `q` back.

## Commands

| Command | When |
|---|---|
| `roam` | the app: projects on every Mac, AI sessions, docs (`roam classic`: the previous menu) |
| `roam resume` | when you sit down at a Mac — **before** opening Xcode or Claude Code |
| `roam park` | before you walk away (optional — auto-park runs every 10 min) |
| `roam doctor` | does this Mac have everything your projects need? |
| `roam fix` | fixes what doctor found, asking before every step |
| `roam new [name]` | starts a project: folder, `.gitignore`, GitHub repo, pool — in one go |
| `roam add <git-url>` | adds an existing repo; every Mac gets it on its next `roam resume` |
| `roam sessions [project]` | AI sessions on every Mac and where they stopped |
| `roam session <project> [n]` | read a session |
| `roam continue <project> [n]` | pick a session up again in Claude Code or Codex |
| `roam read [project] [file]` | the project's Markdown files in the reader |
| `roam status` | the dashboard without the menu |
| `roam setup` | set up or repair this Mac |
| `roam leave` | take this Mac out of the pool |

## How it works

roam has no server. It uses two things you already have: your **git remote** and a **folder your
Macs sync** (iCloud Drive, Dropbox, kDrive, a network share — any will do).

```
                 git remote (GitHub, GitLab, …)
                 refs/roam/<Mac> — snapshot of unfinished work
                    ▲                                │
          roam park │                                │ roam resume
                    │                                ▼
              ┌───────────┐                    ┌─────────────┐
              │ Mac mini  │                    │ MacBook Pro │
              └───────────┘                    └─────────────┘
                    │                                ▲
                    └────────► pool folder ──────────┘
                     project list · Mac status · Claude Code memory
```

- **Snapshots, not branches.** `roam park` turns your whole working directory — uncommitted
  and untracked files included, `.gitignore` respected — into a commit under `refs/roam/<Mac>`.
  Your branch, index and files are never touched, and roam **never pushes branches**: a push to
  `main` might deploy, and that stays your call.
- **Only what's in flight.** Once everything is committed and pushed, the snapshot disappears.
- **Ancestry, not clocks.** `roam resume` only replaces local changes when they're safely parked
  *and* the other Mac's snapshot builds on them. Worked on two Macs in parallel? roam takes
  nothing over and shows you how to compare. No surprises, no lost work.
- **Auto-park never touches your files.** The background job only parks and reports — it never
  resumes behind an open Xcode.
- **Secrets stay home.** Untracked `*.pem`, `*.p12`, `*.p8`, `*.key`, `.env*`, `id_rsa` … block a
  snapshot until they're in `.gitignore`. Files over 50 MB too.
- **Claude Code comes along.** Memory (and optionally session transcripts, for
  `claude --resume`) lives in `~/.claude/projects/<path>/`. roam mirrors it through the pool —
  which is why a project has to live at the same path on every Mac. A transcript your sync app left
  as an empty placeholder never overwrites a good copy, and `roam resume` restores it from the pool.

## What `roam doctor` checks

Without any configuration, by looking at your projects:

| Found in a project | Checked |
|---|---|
| always | git, remote reachable, pool writable, auto-park running, Homebrew, Claude Code, jq, Claude Code sessions the sync app left empty |
| `*.xcodeproj` | full Xcode, first-launch setup, iOS Simulator, iOS SDK ≥ highest `IPHONEOS_DEPLOYMENT_TARGET`, a signing certificate for every `DEVELOPMENT_TEAM` |
| `package.json` | Node, installed packages (`npm ci` / `pnpm` / `yarn` by lockfile) |
| `supabase/config.toml` · `deno.json` · `docker-compose.yml` | Supabase CLI · Deno · Docker |
| `X.example` | whether `X` exists locally |
| an ignored file another Mac has | whether it's missing here (names only — contents never leave a Mac) |

`✗ missing` blocks your work, `• hint` only matters for some parts (backend, deployment, devices),
`ⓘ info` is just worth knowing and never counts as a problem — optional templates and files that only
another Mac has, summarized in one line per project.

## Configuration

Everything lives in the pool folder, so it's the same on every Mac.

**`projects.conf`** — one project per line:

```
# name       folder       git remote                            extras
MyApp        MyApp        git@github.com:you/my-app.git         local=ios/Config/Local.xcconfig
Website      Website      git@github.com:you/website.git        needs=hugo
```

- `local=a,b` — ignored files a project can't run without (missing → ✗)
- `needs=x,y` — extra command line tools (missing → ✗, `roam fix` tries `brew install`)

**`settings`** — `claude_sync`, `claude_history` (0 = memory only, no transcripts),
`session_digest` (0/1/2, see above), `interval_min`, `max_file_mb`.

Per Mac, `roam setup` writes `~/.config/roam/config` (`pool`, `projects_dir`).

## Good to know

- What was **staged** isn't preserved — changes come back as unstaged.
- **Ignored files** (credentials, `Local.xcconfig`) deliberately don't travel. `roam doctor` tells
  you where they're missing.
- A **running** Claude Code session doesn't move. End it, `roam resume` on the other Mac, then
  `claude --resume`.
- Session transcripts contain everything a session saw. Don't want them in your sync folder?
  `claude_history = 0`.
- The session digests are written on every park, resume and background run — but only rewritten
  when a session changed.
- Plain bash, git and rsync — what macOS ships. Nothing to compile, nothing running but a
  LaunchAgent every few minutes.

## Development

```bash
tests/run.sh            # two simulated Macs, a pool and a remote in a temp folder
tests/run.sh resume     # only tests whose name contains "resume"
```

`packaging/release.sh` runs the tests before it tags a release.

## Without Homebrew

```bash
git clone https://github.com/WombatFirst220/roam.git ~/Developer/roam
~/Developer/roam/roam setup     # links roam into ~/.local/bin
```

## Uninstall

```bash
roam leave
brew uninstall wombatfirst220/tap/roam
```

## License

MIT
