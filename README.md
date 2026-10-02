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

That's it — on every Mac. Updates: `brew upgrade wombatfirst220/tap/roam`
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

## The dashboard

Just type `roam`:

```
  ◆ roam  v1.1.0                                            pool · iCloud Drive/roam

  ╭─ Macs ───────────────────────────────────────────────────────────────────────╮
  │ ▸ Mac mini            this Mac     macOS 26.1    Xcode 26.1   ✓ ready        │
  │ ● MacBook Pro         online       macOS 26.1    Xcode 26.1   ✗ 1 missing    │
  ╰──────────────────────────────────────────────────────────────────────────────╯
  ╭─ Projects ───────────────────────────────────────────────────────────────────╮
  │               Mac mini                  MacBook Pro                          │
  │ MyApp         feature/login ●4 ☁        main ✓                               │
  │ Website       main ✓                    main ✓                               │
  │ Backend       main ↑2                   —                                    │
  │ ✓ clean · ●n uncommitted · ↑n unpushed · ☁ parked · — not cloned             │
  ╰──────────────────────────────────────────────────────────────────────────────╯
  ╭─ In flight ────────────────────────────────────── work parked on the remote ─╮
  │ MyApp         ☁ from this Mac · 2 min ago · feature/login                    │
  ╰──────────────────────────────────────────────────────────────────────────────╯

   Resume   Park   New   Doctor   Fix   Add   Log   Quit   ←→ ⏎  or a letter
```

Every Mac reports its state to the pool, so you see your other Macs even while they sleep.

## Commands

| Command | When |
|---|---|
| `roam` | the dashboard, with a menu (←→ ⏎ or the first letter) |
| `roam resume` | when you sit down at a Mac — **before** opening Xcode or Claude Code |
| `roam park` | before you walk away (optional — auto-park runs every 10 min) |
| `roam doctor` | does this Mac have everything your projects need? |
| `roam fix` | fixes what doctor found, asking before every step |
| `roam new [name]` | starts a project: folder, `.gitignore`, GitHub repo, pool — in one go |
| `roam add <git-url>` | adds an existing repo; every Mac gets it on its next `roam resume` |
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
  which is why a project has to live at the same path on every Mac.

## What `roam doctor` checks

Without any configuration, by looking at your projects:

| Found in a project | Checked |
|---|---|
| always | git, remote reachable, pool writable, auto-park running, Homebrew, Claude Code |
| `*.xcodeproj` | full Xcode, first-launch setup, iOS Simulator, iOS SDK ≥ highest `IPHONEOS_DEPLOYMENT_TARGET`, a signing certificate for every `DEVELOPMENT_TEAM` |
| `package.json` | Node, installed packages (`npm ci` / `pnpm` / `yarn` by lockfile) |
| `supabase/config.toml` · `deno.json` · `docker-compose.yml` | Supabase CLI · Deno · Docker |
| `X.example` | whether `X` exists locally |
| an ignored file another Mac has | whether it's missing here (names only — contents never leave a Mac) |

`✗ missing` blocks your work, `• hint` only matters for some parts (backend, deployment, devices).

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
`interval_min`, `max_file_mb`.

Per Mac, `roam setup` writes `~/.config/roam/config` (`pool`, `projects_dir`).

## Good to know

- What was **staged** isn't preserved — changes come back as unstaged.
- **Ignored files** (credentials, `Local.xcconfig`) deliberately don't travel. `roam doctor` tells
  you where they're missing.
- A **running** Claude Code session doesn't move. End it, `roam resume` on the other Mac, then
  `claude --resume`.
- Session transcripts contain everything a session saw. Don't want them in your sync folder?
  `claude_history = 0`.
- Plain bash, git and rsync — what macOS ships. Nothing to compile, nothing running but a
  LaunchAgent every few minutes.

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
