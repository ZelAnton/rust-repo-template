# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project

> **TODO:** Describe this crate — what it does, the binary/library name, and any
> high-level context an agent needs before touching the code. Keep it to a few
> sentences; deep design notes belong in a dedicated `ARCHITECTURE.md`.

## Build, test, run

```bash
cargo build                 # debug build
cargo build --release       # optimized build
cargo run                   # build + run the binary
cargo test                  # all unit + integration tests
cargo test <name>           # run tests matching a substring
cargo clippy --all-targets  # lint (CI treats warnings as errors)
cargo fmt                   # format (CI checks `cargo fmt --check`)
```

Integration tests live in `tests/` — each file is compiled as its own crate.
Prefer shared fixtures/helpers in a `tests/common/mod.rs` module over rolling
your own per file.

## Code style

- **Comment the *why*, not the *what*.** The code already says what it does;
  comments explain the non-obvious reason it does it that way — a workaround, a
  wire contract, a performance trade-off. Don't narrate obvious lines.
- **Match the surrounding code.** Follow the existing module's naming, idioms,
  error-handling style, and comment density. New code should read like it was
  always there.
- **Reuse before you add.** Search for an existing helper/utility before writing
  a new one; avoid duplicating logic.
- **Conventional-commit subjects.** Write commit subjects as
  `type(scope): summary` — `feat`, `fix`, `refactor`, `perf`, `docs`, `test`,
  `chore`, `ci`, etc. These feed the changelog (`cliff.toml`); see "Releasing
  and the changelog".
- **Keep it formatted and lint-clean.** Run `cargo fmt` and
  `cargo clippy --all-targets` before considering work done.

## Dependency management

This repository fixes **no** allow-list of crates — add whatever the project
genuinely needs. The convention is about *how* you add dependencies, not *which*:

- **Document every dependency.** Each entry in `Cargo.toml` gets an inline
  comment explaining *why* it's there and what it's used for. A future reader
  (human or agent) should never have to guess why a crate is in the tree.
- **Pin major versions** (`"1"`, `"0.22"`) and enable only the features you use.
- **Commit `Cargo.lock`.** Reproducible builds — it's tracked, not ignored.
- **Platform-specific deps** go under a cfg target table, e.g.
  `[target.'cfg(windows)'.dependencies]`, with the same "why" comment.
- Prefer well-maintained, widely-used crates; be deliberate about pulling in
  large dependency trees for small gains.

## Local-only files

`.gitignore` carves out `*.local.md`, `task_plan.md`, `findings.md`,
`progress.md` — use those names freely for scratch notes; they won't be
committed.

## Releasing and the changelog

- **`Cargo.toml` `version` is the single source of truth.** Bump it with the
  release, tag as `v<version>`, and never let the manifest, the tag, and the
  published artifact drift apart.
- **`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/) and
  [Semantic Versioning](https://semver.org/).** Curate the `[Unreleased]`
  section as you work — add bullets under `Added` / `Changed` / `Fixed`.
  **Manual bullets always win.** If `[Unreleased]` is empty at release time,
  `git-cliff` (config: `cliff.toml`) auto-fills it from commit subjects,
  bucketing by prefix (`feat`→Added, `fix`→Fixed, `remove`→Removed,
  `perf`/`refactor`/`ci`/…→Changed, `docs`/`chore`/`test`→skipped). Clean
  conventional-commit subjects are what make that fallback useful.
- This lean template ships **no** release workflow. Add one (e.g. a
  `workflow_dispatch` GitHub Action that bumps the version, promotes
  `[Unreleased]`, tags, and publishes) when the project needs automated releases.

## Version control workflow

This repo uses [jujutsu (`jj`)](https://jj-vcs.github.io/jj/) colocated with
git. Use `jj` commands; the canonical workflow:

- **Per-prompt evaluation (mandatory).** Before any edits, run `jj st` and
  classify the incoming prompt against the current change description:

	| Signal in prompt | Category | Action |
	|---|---|---|
	| Same topic, refinement, follow-up of in-progress work | **Continuation** | Just work. jj auto-folds edits into the current change. |
	| Same change but goal has been refined or expanded | **Scope shift** | `jj describe -m "<refined summary>"`. **Don't** start a new change. |
	| Orthogonal topic, different area, "теперь сделай X" | **New work** | If current change is finished → `jj new -m "<summary>"` (descendant). If still in progress → `jj new @- -m "..."` (parallel sibling). |

	Reliable signals: word changes like "теперь" / "now" / "next" / "также сделай" / "and also" usually mean **new work** or **scope shift**. Imperative follow-ups inside the same scope ("исправь это", "fix this", "продолжи") mean **continuation**. When in doubt, ask the user.

	A `UserPromptSubmit` hook (`.claude/hooks/jj-prompt-reminder.sh`) injects this same checklist into context each turn — the hook is the reminder, this table is the rulebook.

- **Describe early.** When starting a new piece of work, immediately set the change description:
	```
	jj describe -m "Concise summary"
	```
	The description should reflect intent *before* the work — not be backfilled at commit time. Keep extending the same `jj` change for follow-ups; don't spawn one per edit.
- **Sync on the user's trigger.** When the user says `pull` (or `push`/`sync`), run the full handshake:
	1. `jj git fetch` first — picks up any remote movement.
	2. Rebase if `main@origin` advanced: `jj rebase -r @- -d main@origin`.
	3. `jj bookmark set main -r <rev>` then `jj git push --bookmark main`.

	Never push without an explicit signal from the user.
- **Undoing dropped work.** When the user decides to abandon something already done, reach for `jj`'s safety net rather than hand-cleanup:
	- `jj undo` (alias of `jj op undo`) reverses the last operation — describe, edit, squash, rebase, abandon, push, all of it. Repeatable.
	- `jj abandon <rev>` drops a specific change entirely; descendants auto-rebase.
	- `jj restore` discards working-copy edits back to the parent's tree.
	- `jj op log` is the full reflog if you need to go further back via `jj op restore <op-id>`.
- **No new bookmarks** unless the user explicitly asks. Work lives on `main`; that is the publish target.

## Windows / line endings

The working tree may carry CRLF line endings on Windows despite `.gitattributes`
mandating LF — that's stat-cache state from a pre-attributes checkout, not actual
file divergence. The committed blobs are LF; pushed commits are clean. Colocated
`jj st` may show phantom modifications for files that haven't been re-extracted
since `.gitattributes` was added. `.gitattributes` (`* text=auto eol=lf`) is what
keeps git and jj agreeing on the working copy.
