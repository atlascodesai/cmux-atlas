# AI Session Management Analysis

This note compares how cmux currently integrates Claude Code and Codex for session lifecycle, resume behavior, and session-state reading.

It is intended to support an upstream Codex PR discussion.

## Summary

Claude and Codex expose different lifecycle signals.

- Claude gives cmux a real session lifecycle:
  - `session-start`
  - per-turn `stop`
  - `session-end`
  - notification and tool-use hooks
- Codex currently gives cmux:
  - `session-start`
  - per-turn `stop`

That difference is the root reason Claude can support direct exit-time resume behavior cleanly, while Codex needs either:

- a process-based fallback such as PID exit detection, or
- a richer upstream lifecycle event model

## Current cmux Model

cmux now treats "resume" as an explicit terminal prefill action.

- Live terminal behavior:
  - when an AI session truly exits, cmux prefills the terminal with the correct resume command
  - it does not auto-run the command
- Recovery behavior:
  - on app restore or reopen of a closed AI terminal, cmux also prefills the resume command

This is now consistent across Claude and Codex.

## Claude Integration

### Hook Contract

Claude wrapper/hooks provide a strong lifecycle contract:

- `session-start` marks the terminal panel as having an active Claude session
- `stop` means a turn ended, not that the process exited
- `session-end` means the Claude process actually exited
- `notification` and `pre-tool-use` provide richer structured state

### Session Management

cmux can do all of these directly from Claude hooks:

- persist the session ID and working directory
- associate the live session with a specific panel
- track the Claude PID
- suppress duplicate OSC notifications while Claude hooks are active
- prefill the resume command exactly when `session-end` fires

### Session Reading

Claude is the stronger case for session reading.

cmux can recover Claude session identity from multiple sources:

1. Hook state written by the Claude hook integration
2. Running-process detection in `AISessionDetector`
3. Claude transcript / project-dir inspection when needed

That means Claude session reading is resilient even if one path is missing.

## Codex Integration

### Hook Contract

Codex currently exposes only:

- `session-start`
- `stop`

In practice:

- `session-start` is useful and carries the session ID
- `stop` is a turn-level event, not a process-exit event

So `stop` cannot safely be treated as "session resumable now".

### Session Management

Because Codex does not expose a `session-end`-style hook, cmux currently has to split responsibility:

- hook layer:
  - persist session ID and session metadata on `session-start` and `stop`
  - mark the panel as having an active Codex session on `session-start`
- runtime layer:
  - track the Codex PID exported by the wrapper
  - detect actual process exit by PID sweep
  - prefill the resume command only after true process exit

This works, but it is an inferior integration contract compared to Claude because process liveness has to stand in for a missing lifecycle event.

### Session Reading

Codex session reading is thinner than Claude session reading.

Today cmux mostly depends on hook-state persistence:

1. Codex wrapper starts Codex with launch-scoped hooks
2. `session-start` and `stop` write `codex-hook-sessions.json`
3. cmux reads that state file for restore and closed-terminal reopen

What cmux does not have from Codex today:

- a dedicated session-end hook
- a richer built-in session query path
- a hook-state payload that directly says "this session is still live" vs "this session has ended"

So Codex session reading is more state-file-centric and less observable than Claude.

## Why the Difference Matters

Without a real exit event, Codex integrations have to guess session end from side effects:

- PID death
- shell returning to prompt
- timeout heuristics

Those are all weaker than an explicit lifecycle signal.

This affects:

- live resume affordances
- stale-session cleanup
- prompt/notification suppression
- multi-panel correctness
- correctness when a user starts a new session after clearing the previous one

## What Would Improve Codex Upstream

The most valuable upstream improvements would be:

### 1. Add a true session-end hook

Best improvement.

Needed semantics:

- fires once when the interactive Codex session actually exits
- distinct from per-turn completion
- carries at least:
  - `session_id`
  - `cwd`
  - ideally `pid`

This would let integrations handle Codex exactly like Claude for live resume behavior.

### 2. Include PID in hook payloads

Even with a future `session-end`, PID in the structured hook payload is still useful.

Why:

- removes wrapper-specific env export hacks
- gives integrations a stable way to correlate session metadata with the running process
- helps stale-session cleanup and multi-panel correctness

### 3. Make turn-end vs session-end explicit in naming

`stop` is easy to misread as "process stopped".

Better naming would be something like:

- `turn_end`
- `session_end`

Even if `stop` stays for compatibility, explicit semantics in docs and structured payload shape would reduce integration errors.

### 4. Expose a session-inspection command or machine-readable state query

Useful for recovery and for external tools.

Examples:

- current live session ID
- current working directory
- current transcript path
- permission mode
- whether the session is still active

This would make session reading less dependent on sidecar state files written by hook handlers.

### 5. Strengthen hook payload docs

Integrations need to know which fields are stable and what each event guarantees.

Important contract questions:

- Is `session_id` stable for the full life of the session?
- Does `stop` fire after every turn, or only some turns?
- Does it fire during `/clear`, `/new`, or resume?
- Can a new `session-start` happen for an existing session ID?
- When does transcript-path rotation happen?

## Best Upstream PR Direction

If we open a Codex PR, the cleanest ask is:

1. Add a real `session_end` hook event
2. Include `pid` in hook payloads
3. Clarify that `stop` is turn-level, not process-exit-level

That gives downstream integrations:

- Claude-equivalent lifecycle handling
- simpler live resume logic
- less wrapper-specific behavior
- fewer false positives around session exit

## cmux-Specific Takeaway

Claude is currently the better-integrated agent because it exposes a fuller session lifecycle and richer structured state.

Codex is now supported correctly in cmux, but part of that correctness comes from cmux compensating for missing upstream lifecycle signals.

That compensation layer is reasonable for the app, but it is exactly the sort of complexity that should ideally move out of downstream clients and into the upstream Codex hook contract.
