<p align="center"><img src="docs/appicon-preview.png" width="128" alt="Quotch"></p>
<h1 align="center">Quotch</h1>
<p align="center">Your AI quotas, living in the notch. Several accounts per provider, stacked like cards.<br>macOS only · Swift · no Xcode required</p>

<p align="center"><img src="docs/screenshots/quotch-demo.gif" width="760" alt="Closed, hovering to open, flipping an account stack, the settings button"></p>

## Install
1. Download `Quotch.dmg` from [Releases](../../releases/latest), open it, and drag **Quotch** onto **Applications**.
2. **First launch only** — the release isn't notarised by Apple, so Gatekeeper blocks a plain double-click the first time. Instead: **Control-click (or right-click) Quotch in Applications → Open → Open** in the dialog that appears. If macOS shows no "Open" button at all, go to **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to Quotch. You only do this once — every launch after that works normally.
3. Quotch lives outside the Dock. Look for a thin black strip at the edge of your screen, or reopen it from Applications to bring up Settings.
4. Add an account from **Settings → +** for each provider. Quotch guides each connection: Flow signs in inside its own window, Grokbot reads the installed Grok Bot app, and browser profiles may ask for **Full Disk Access** once.

## What it does
A thin black strip hugs the edge of your screen. Hover it and it opens into rings — one per AI provider — with the
percentage of your quota used. **Providers with more than one account show as a stack of cards**: scroll over the
ring to bring the next account to the front, or tap the dots. It reads the dominant axis, so a sideways flick works
too — a two-finger swipe on the trackpad, or the side thumbwheel on a mouse like the MX Master. Hover a ring for the
full breakdown: every quota window, when it resets, who the account belongs to.

| Collapsed | Expanded | Hover card | Stack flipped | Settings button |
|---|---|---|---|---|
| ![](docs/screenshots/01-pill.png) | ![](docs/screenshots/02-expanded.png) | ![](docs/screenshots/03-hover-card.png) | ![](docs/screenshots/04-stack-flipped.png) | ![](docs/screenshots/05-gear.png) |

## Providers
| | Reads | How |
|---|---|---|
| **Claude** | session + weekly rings, including Fable | private web session, browser session, or Claude Code's Keychain login |
| **Codex** (ChatGPT) | weekly limit | local CLI rollout files — no network |
| **Cursor** | Cursor Models + Other Models rings | browser session → `cursor.com/api/usage-summary` |
| **Grokbot** | weekly limit | installed Grok Bot app → `GetSandUsageStatus` |
| **Antigravity** | daily quota | local bridge to the running Antigravity app |
| **Google Flow** | monthly credits left | signed-in browser session; remaining subscription credits are measured against the plan's monthly allowance |

Every connected account is refreshed **in the background**. Flow uses a normal browser session because Google blocks embedded sign-in.
Its ring starts full and shrinks with the remaining monthly subscription credits; placeholder credit numbers are never shown as real usage.

Quotch never asks for a password. It reads logins the tools already keep on your Mac, and shows the account's
name, e-mail (can be hidden) and plan so you always know which account a ring is.

## Design
A notch strip rebuilt from careful measurement (two-arc silhouette, 44 pt rings, 102.5 pt rhythm, tuned springs), then extended with:
account stacks, identity, a round settings button that emerges from the tip on hover, click-to-refresh.
Everything is clipped to the silhouette, so nothing ever bleeds past the black.

<p align="center"><img src="docs/screenshots/06-settings.png" width="420" alt="Settings"></p>

## Build & run
```bash
bash build.sh          # swiftc → /Applications/Quotch.app
open -g -a Quotch      # lives outside the Dock; appears in the Dock only while Settings is open
```
Right-click the strip for the menu (Keep open · Refresh now · Settings… · Open <site> · Quit).

## Docs
`docs/HANDOFF.md` (start here) · `docs/TASKS.md` (what's done / next) · `docs/spec.md` · `docs/design-tokens.md` · `docs/backlog.md`.


## Reading accounts from your browser

For providers connected through a browser profile, Quotch reads the session already saved there and paints the ring without opening a tab. Add an account from **Settings → +**, pick the browser and profile, and it starts reading.

**One-time setup: Full Disk Access.** macOS keeps every browser's cookies in a protected folder, so a background reader needs Full Disk Access. Grant it once and every browser-profile account reads silently from then on:

1. System Settings → Privacy & Security → Full Disk Access.
2. Add **Quotch** with the **+** and switch it on.
3. Reopen Quotch.

Chrome profiles are read per profile (Pedro, Letícia, …). Safari is read from its cookie store. No Automation permission, no tabs, no windows.

**A second, separate prompt for Chrome only:** the first time Quotch reads a Chrome profile, macOS asks *"Quotch wants to access the key 'Chrome Safe Storage' in your keychain"* — that's the login keychain password, and it's how Chrome itself encrypts your cookies. Choose **Always Allow** so it only asks once. This is unrelated to your Chrome password or your Google account; Quotch never sees either.

Sources that read from the desktop tool instead of a browser need no Full Disk Access: **Claude Code** (Keychain login), **Codex** (local CLI files), **Antigravity** (a local bridge to the running app), and **Grok Bot** (its own Keychain login). Flow keeps a separate web session inside Quotch.

> The release build is signed with a stable local identity, so the Full Disk Access grant survives app updates — you grant it once, not on every new version.

## Credits
Designed and developed by [matheusbgodoi](https://www.linkedin.com/in/matheusgodoi-engbio/). Provider marks belong to their owners.
