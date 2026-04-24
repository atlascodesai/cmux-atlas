# 2026-04-24

- Added Atlas Codex hook installation commands with an upstream-compatible default mode and an `--atlas-extended` mode for local Codex builds that emit `SessionEnd`.
- Updated the bundled Codex wrapper to respect OVM/PATH resolution and stand down when Codex config-installed cmux hooks are already present.
- Hardened Claude resume prefill behavior so stale background cleanup paths do not keep appending multiple `claude --resume ...` commands into the same terminal prompt.
