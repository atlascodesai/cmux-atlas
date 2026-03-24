<h1 align="center">cmux Atlas</h1>
<p align="center">A personal fork of <a href="https://github.com/manaflow-ai/cmux">manaflow-ai/cmux</a> — adding AI workflow features we want in our terminal</p>

> **Note:** This fork exists to explore changes that may not align with the main cmux product vision but reflect our personal workflow preferences. If the Manaflow team finds any of these features useful for upstream, we're happy to open PRs. This fork is created and maintained with the help of [Claude](https://claude.ai) and [Codex](https://openai.com/codex).

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux Atlas screenshot" width="900" />
</p>

## What's different from upstream cmux

This fork builds on top of cmux to add features focused on AI coding agent workflows:

- **AI session auto-resume** — Detects AI coding agent sessions (Claude Code, Codex, etc.) and offers to auto-resume them on app restart
- **Editor sync** — Auto-opens the workspace directory in your configured editor (VS Code, Cursor, Zed, etc.) when the terminal's working directory changes
- **Markdown link interception** — Intercepts markdown file links in the terminal and renders them in the native panel
- **AI quick launch buttons** — Titlebar buttons with Claude and Codex logos for one-click agent launch, with right-click permissive mode toggle
- **Session ID resolver** — PID-correlated scoring to reliably identify and restore AI agent sessions

We sync regularly with upstream cmux and aim to contribute features back where it makes sense.

---

*Everything below is from the upstream cmux README.*

---

## Features

<table>
<tr>
<td width="40%" valign="middle">
<h3>Notification rings</h3>
Panes get a blue ring and tabs light up when coding agents need your attention
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Notification rings" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Notification panel</h3>
See all pending notifications in one place, jump to the most recent unread
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Sidebar notification badge" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>In-app browser</h3>
Split a browser alongside your terminal with a scriptable API ported from <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Built-in browser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Vertical + horizontal tabs</h3>
Sidebar shows git branch, linked PR status/number, working directory, listening ports, and latest notification text. Split horizontally and vertically.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertical tabs and split panes" width="100%" />
</td>
</tr>
</table>

- **Scriptable** — CLI and socket API to create workspaces, split panes, send keystrokes, and automate the browser
- **Native macOS app** — Built with Swift and AppKit, not Electron. Fast startup, low memory.
- **Ghostty compatible** — Reads your existing `~/.config/ghostty/config` for themes, fonts, and colors
- **GPU-accelerated** — Powered by libghostty for smooth rendering

## Install

### DMG (recommended)

<a href="https://github.com/atlascodesai/cmux-atlas/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Download cmux for macOS" width="180" />
</a>

Open the `.dmg` and drag cmux Atlas to your Applications folder. Fork releases auto-update via Sparkle using this fork's GitHub Releases feed, so install from the link above if you want Atlas updates.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Homebrew currently tracks the upstream stable app, not this fork. To use the Atlas fork and its Sparkle auto-update channel, install from the DMG above.

To update the upstream cask later:

```bash
brew upgrade --cask cmux
```

On first launch, macOS may ask you to confirm opening an app from an identified developer. Click **Open** to proceed.

## Why cmux?

I run a lot of Claude Code and Codex sessions in parallel. I was using Ghostty with a bunch of split panes, and relying on native macOS notifications to know when an agent needed me. But Claude Code's notification body is always just "Claude is waiting for your input" with no context, and with enough tabs open I couldn't even read the titles anymore.

I tried a few coding orchestrators but most of them were Electron/Tauri apps and the performance bugged me. I also just prefer the terminal since GUI orchestrators lock you into their workflow. So I built cmux as a native macOS app in Swift/AppKit. It uses libghostty for terminal rendering and reads your existing Ghostty config for themes, fonts, and colors.

The main additions are the sidebar and notification system. The sidebar has vertical tabs that show git branch, linked PR status/number, working directory, listening ports, and the latest notification text for each workspace. The notification system picks up terminal sequences (OSC 9/99/777) and has a CLI (`cmux notify`) you can wire into agent hooks for Claude Code, OpenCode, etc. When an agent is waiting, its pane gets a blue ring and the tab lights up in the sidebar, so I can tell which one needs me across splits and tabs. Cmd+Shift+U jumps to the most recent unread.

The in-app browser has a scriptable API ported from [agent-browser](https://github.com/vercel-labs/agent-browser). Agents can snapshot the accessibility tree, get element refs, click, fill forms, and evaluate JS. You can split a browser pane next to your terminal and have Claude Code interact with your dev server directly.

Everything is scriptable through the CLI and socket API — create workspaces/tabs, split panes, send keystrokes, open URLs in the browser.

## The Zen of cmux

cmux is not prescriptive about how developers hold their tools. It's a terminal and browser with a CLI, and the rest is up to you.

cmux is a primitive, not a solution. It gives you a terminal, a browser, notifications, workspaces, splits, tabs, and a CLI to control all of it. cmux doesn't force you into an opinionated way to use coding agents. What you build with the primitives is yours.

The best developers have always built their own tools. Nobody has figured out the best way to work with agents yet, and the teams building closed products definitely haven't either. The developers closest to their own codebases will figure it out first.

Give a million developers composable primitives and they'll collectively find the most efficient workflows faster than any product team could design top-down.

## Documentation

For more info on how to configure cmux, [head over to our docs](https://cmux.com/docs/getting-started?utm_source=readme).

## Keyboard Shortcuts

### Workspaces

| Shortcut | Action |
|----------|--------|
| ⌘ N | New workspace |
| ⌘ 1–8 | Jump to workspace 1–8 |
| ⌘ 9 | Jump to last workspace |
| ⌃ ⌘ ] | Next workspace |
| ⌃ ⌘ [ | Previous workspace |
| ⌘ ⇧ W | Close workspace |
| ⌘ ⇧ R | Rename workspace |
| ⌘ B | Toggle sidebar |

### Surfaces

| Shortcut | Action |
|----------|--------|
| ⌘ T | New surface |
| ⌘ ⇧ ] | Next surface |
| ⌘ ⇧ [ | Previous surface |
| ⌃ Tab | Next surface |
| ⌃ ⇧ Tab | Previous surface |
| ⌃ 1–8 | Jump to surface 1–8 |
| ⌃ 9 | Jump to last surface |
| ⌘ W | Close surface |

### Split Panes

| Shortcut | Action |
|----------|--------|
| ⌘ D | Split right |
| ⌘ ⇧ D | Split down |
| ⌥ ⌘ ← → ↑ ↓ | Focus pane directionally |
| ⌘ ⇧ H | Flash focused panel |

### Browser

Browser developer-tool shortcuts follow Safari defaults and are customizable in `Settings → Keyboard Shortcuts`.

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ L | Open browser in split |
| ⌘ L | Focus address bar |
| ⌘ [ | Back |
| ⌘ ] | Forward |
| ⌘ R | Reload page |
| ⌥ ⌘ I | Toggle Developer Tools (Safari default) |
| ⌥ ⌘ C | Show JavaScript Console (Safari default) |

### Notifications

| Shortcut | Action |
|----------|--------|
| ⌘ I | Show notifications panel |
| ⌘ ⇧ U | Jump to latest unread |

### Find

| Shortcut | Action |
|----------|--------|
| ⌘ F | Find |
| ⌘ G / ⌘ ⇧ G | Find next / previous |
| ⌘ ⇧ F | Hide find bar |
| ⌘ E | Use selection for find |

### Terminal

| Shortcut | Action |
|----------|--------|
| ⌘ K | Clear scrollback |
| ⌘ C | Copy (with selection) |
| ⌘ V | Paste |
| ⌘ + / ⌘ - | Increase / decrease font size |
| ⌘ 0 | Reset font size |

### Window

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ N | New window |
| ⌘ , | Settings |
| ⌘ ⇧ , | Reload configuration |
| ⌘ Q | Quit |

## Nightly Builds

[Download cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY is a separate app with its own bundle ID, so it runs alongside the stable version. Built automatically from the latest `main` commit and auto-updates via its own Sparkle feed.

Report nightly bugs on [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) or in [#nightly-bugs on Discord](https://discord.gg/xsgFEVrWCZ).

## Session restore (current behavior)

On relaunch, cmux currently restores app layout and metadata only:
- Window/workspace/pane layout
- Working directories
- Terminal scrollback (best effort)
- Browser URL and navigation history

cmux does **not** restore live process state inside terminal apps. For example, active Claude Code/tmux/vim sessions are not resumed after restart yet.

## Star History

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Contributing

Ways to get involved:

- Follow us on X for updates [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), and [@austinywang](https://x.com/austinywang)
- Join the conversation on [Discord](https://discord.gg/xsgFEVrWCZ)
- Create and participate in [GitHub issues](https://github.com/manaflow-ai/cmux/issues) and [discussions](https://github.com/manaflow-ai/cmux/discussions)
- Let us know what you're building with cmux

## Community

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux is free, open source, and always will be. If you'd like to support development and get early access to what's coming next:

**[Get Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Prioritized feature requests/bug fixes**
- **Early access: cmux AI that gives you context on every workspace, tab and panel**
- **Early access: iOS app with terminals synced between desktop and phone**
- **Early access: Cloud VMs**
- **Early access: Voice mode**
- **My personal iMessage/WhatsApp**

## License

cmux is open source under [AGPL-3.0-or-later](LICENSE).

If your organization cannot comply with AGPL, a commercial license is available. Contact [founders@manaflow.com](mailto:founders@manaflow.com) for details.
