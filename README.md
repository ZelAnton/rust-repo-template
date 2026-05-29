# Rust repository template

A depersonalized baseline for new Rust repositories. It ships the tooling,
conventions, and AI-agent guidance shared across projects — minus any
project-specific code, names, or dependency lists.

## What's included

- **`Cargo.toml`** — a binary crate skeleton (edition 2024) with an empty,
  documented `[dependencies]` section. No crates are pre-fixed.
- **`AGENTS.md`** + **`CLAUDE.md`** — guidance for AI coding agents: build/test
  commands, code-style and dependency conventions, the changelog process, and
  the jujutsu (`jj`) version-control workflow.
- **`.claude/`** — a `UserPromptSubmit` hook that injects the `jj` change-scope
  checklist into the agent's context each turn.
- **`.gitattributes`** — LF line-ending normalization (keeps git and colocated
  `jj` agreeing on the working copy, especially on Windows).
- **`.gitignore`** — `/target`, per-user scratch files, and the `.claude/`
  carve-out (ships hook config, excludes the per-user `settings.local.json`).
- **`cliff.toml`** + **`CHANGELOG.md`** — Keep a Changelog + git-cliff auto-fill
  from conventional commits.
- **`.github/workflows/ci.yml`** — build, test, clippy, and `fmt --check` on
  push / pull request.

## Starting a new project from this template

1. **Rename the crate** in `Cargo.toml` (`name`) and fill in `description`,
   `license`, and `repository`.
2. **Fill in the `Project` section** of `AGENTS.md`.
3. **Set your repo URL** in `CHANGELOG.md`'s compare links (replace `OWNER/REPO`)
   and set the real `0.1.0` date.
4. **Replace `src/main.rs`** (and `tests/integration.rs`) with your code — or
   switch to a library crate (`src/lib.rs`) if that's what you're building.
5. Run `cargo build && cargo test` to confirm a clean baseline.

## Conventions

See [AGENTS.md](AGENTS.md) for the full set: code style, dependency management
(every dependency gets a "why" comment; no fixed allow-list), the changelog
process, and the `jj` version-control workflow.
