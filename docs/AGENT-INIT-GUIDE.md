# Agent guide: initializing a repo from this template

This guide is for an AI agent (Claude Code or similar) asked to "initialize a new
repository from this template." It exists because real initialization sessions
have gone wrong in avoidable ways. **Read it before touching any files.**

> **Living document — keep it accurate.** This guide is meant to grow. If you
> make a mistake while initializing a repo (or watch one happen), add it to
> [Failure log](#failure-log) below with the symptom, the root cause, and the
> rule that prevents it. Fix or sharpen existing entries when they turn out to be
> incomplete. The whole point is that the *next* agent doesn't repeat what the
> last one got wrong. See [Updating this guide](#updating-this-guide).

## TL;DR — the five rules

1. **Read before you write.** Read `TEMPLATE.md`, this file, `AGENTS.md`, and
   `CLAUDE.md` *first*. Do not generate a single file based on an assumed layout.
2. **Prefer the init script over hand-rolling.** `scripts/init.ps1` is the
   supported path for a standard single-crate init. Run it; don't recreate its
   token substitution by hand.
3. **Match the shell to the tool.** On Windows the Bash tool is POSIX (git bash);
   PowerShell cmdlets fail there with `command not found`. Use the PowerShell
   tool for `pwsh`/cmdlets, the Bash tool only for POSIX. Prefer the dedicated
   Read / Glob / Grep tools over either shell for file inspection.
4. **Make the mistake impossible, not just documented.** When you find a gap,
   prefer fixing the template/script over adding a checklist note (shipping a
   tokenized `LICENSE` beats "remember to add a license").
5. **Verify, then it's done.** `cargo build` + `cargo test` + `cargo clippy
   --all-targets -- -D warnings` + `cargo fmt --all --check`. If it publishes,
   also `cargo package`.

## What this template actually is

Confirm these facts by reading, not by assuming:

- It is a **token template**, not a ready project. Placeholder tokens
  (`__CrateName__`, `__Author__`, `__GitHubOwner__`, `__Description__`,
  `__Year__`, `__Date__`) appear in file contents (and may appear in file/folder
  names in workspace adaptations). `scripts/init.ps1` substitutes them.
- It is **single-crate** by default: a binary crate (`src/main.rs`) with an
  integration test (`tests/integration.rs`), edition 2024.
- Conventions (all enforced — see `AGENTS.md`):
  - CI is strict: `cargo fmt --all --check`, `cargo clippy --all-targets
    -- -D warnings` (warnings are errors), build + test on Linux **and** Windows.
  - Every dependency gets a "why" comment in `Cargo.toml`; `Cargo.lock` is
    committed; no fixed allow-list of crates.
  - `CHANGELOG.md` is Keep a Changelog; manual bullets win over the git-cliff
    (`cliff.toml`) auto-fill keyed on conventional-commit subjects.
  - LF line endings via `.gitattributes` (`* text=auto eol=lf`).
- It uses **jujutsu (`jj`)** colocated with git. Drive VCS through `jj`.

## The happy path (standard single-crate init)

1. **Read** `TEMPLATE.md` and this guide. Skim `AGENTS.md` / `CLAUDE.md`.
2. **Run the init script** with the values the user gave you:

   ```pwsh
   pwsh ./scripts/init.ps1 -CrateName my-tool -Author "Jane Doe" -GitHubOwner acme -Description "A small tool"
   ```

   `-CrateName` is required; the rest fall back to sensible defaults. The script
   substitutes tokens (TOML-escaped for `Cargo.toml`), renames any token-named
   files/folders, and deletes `TEMPLATE.md`, `docs/AGENT-INIT-GUIDE.md`, and
   itself (unless `-KeepScript`).
3. **Verify**:

   ```pwsh
   cargo build && cargo test
   cargo clippy --all-targets -- -D warnings
   cargo fmt --all --check
   ```
4. Replace the placeholder `main`/test with the real code (or switch to
   `src/lib.rs`), fill the `AGENTS.md` `Project` section, and confirm the
   `repository` URL matches the real remote (`git remote get-url origin`).

If the user only asks to "initialize from the template" with a crate name and
nothing structurally unusual, **this is the whole job.** Resist the urge to
redesign.

## When you must deviate — workspace / multiple crates

The init script assumes one crate. If the user wants several (e.g. three
libraries, each its own crates.io package), the single-token substitution won't
fully fit, so you adapt by hand — but still respect every convention above:

- **Root `Cargo.toml` becomes a virtual manifest:** `[workspace]` with
  `members`, `resolver = "3"`, and a `[workspace.package]` table for shared
  metadata (`edition`, `license`, `repository`, `authors`). Members inherit with
  `field.workspace = true`.
- **Decide versioning explicitly:** *independent* (each crate publishes on its
  own cadence) → keep `version` **out** of `[workspace.package]`, set it per
  crate; *shared* → put `version` in `[workspace.package]` and inherit.
- **Each member dir is self-contained:** its own `Cargo.toml`, `src/lib.rs`,
  `README.md`, `CHANGELOG.md`, **and its own `LICENSE`**. Cargo only packages a
  `LICENSE` that sits in the crate's own directory — a single root `LICENSE` is
  **not** included in members.
- **Per-crate changelog + tags:** tag releases as `<crate>-v<version>` and use
  per-crate compare links so independently-versioned crates don't share a tag
  namespace.
- **Keep CI hermetic.** If a crate shells out to an external binary (or needs
  something CI runners lack), mark those tests `#[ignore]` so `cargo test` stays
  green; document `cargo test -- --ignored` for local runs.
- **`/target` stays at the workspace root**, so the template's `/target`
  `.gitignore` entry is still correct — no change needed.

Whatever you change, update `AGENTS.md` so it describes the layout you produced.

## Tooling discipline (this is where agents slip)

- **Shell ≠ shell.** The Bash tool runs POSIX (git bash); cmdlets like
  `Get-ChildItem` fail there. Use the PowerShell tool for cmdlets.
- **Don't over-batch.** A failure in one call of a parallel batch can cancel the
  rest. Don't put exploratory calls (whose results you need) or interdependent
  calls in the same batch as file writes. Read and ask first; write once you know.
- **READMEs are plain markdown, not rustdoc.** Don't use rustdoc hidden-line `#`
  prefixes (e.g. `# Ok::<(), _>(())`) in a README — they render *literally* on
  GitHub/crates.io. Use plain ```` ```rust ```` fences.
- **VCS.** The repo is jj-colocated. Use `jj` commands; if you must use raw git,
  follow with `jj git import`.

## Updating this guide

When something goes wrong during an init — yours or one you review — do this in
the **same change set**, not as a follow-up:

1. Add an entry to [Failure log](#failure-log): the symptom (what was observed),
   the root cause (why it happened), and the rule (what to do instead).
2. If the lesson generalizes, also fold it into the TL;DR or the relevant section
   above so it's seen in the normal reading flow, not just the log.
3. If `scripts/init.ps1`, `TEMPLATE.md`, or `AGENTS.md` could be changed to make
   the mistake *impossible* (rather than merely documented), prefer that fix and
   note it in the entry.
4. **Log to the template, not the downstream copy.** The canonical guide lives in
   the **template repository**. When a *downstream* init (a separate repo)
   reveals a pitfall, update the template's copy and commit it there — that's the
   copy future initializations read (the init script deletes the downstream copy).

Keep entries short and concrete. Delete or rewrite an entry if it turns out to be
wrong or obsolete.

## Failure log

Newest first. Each entry: **Symptom → Root cause → Rule.**

### 2026-05-29 — `LICENSE` declared but never shipped
- **Symptom:** A workspace was initialized whose crates set `license = "MIT"` but
  shipped no license text; only caught in review. Publishing would have produced
  crates with no license file.
- **Root cause:** The template documented the license field but didn't ship a
  license file, so it was easy to forget.
- **Rule:** The template now ships a tokenized `LICENSE` (`__Year__`/`__Author__`)
  that the init script fills. In a workspace, **each crate needs its own
  `LICENSE`** (cargo packages only files in the crate dir). TL;DR #4.

### 2026-05-29 — README used rustdoc hidden lines
- **Symptom:** Per-crate READMEs used `# Ok::<(), std::io::Error>(())`; in plain
  markdown the `#` lines render literally on GitHub/crates.io.
- **Root cause:** Carried a doctest convention into a plain-markdown README.
- **Rule:** Plain ```` ```rust ```` fences in READMEs; no `#` hidden lines (see
  [Tooling discipline](#tooling-discipline-this-is-where-agents-slip)).

### 2026-05-29 — placeholders nearly left in (`OWNER/REPO`, `YYYY-MM-DD`)
- **Symptom:** The `repository` URL and `CHANGELOG` date/compare links carried
  literal placeholders that were almost shipped.
- **Root cause:** Hand-editing placeholders is error-prone.
- **Rule:** These are now tokens (`__GitHubOwner__`, `__CrateName__`, `__Date__`)
  that `scripts/init.ps1` substitutes; the URL default comes from `git remote`.

### 2026-05-29 — workspace built from scratch with no guidance
- **Symptom:** Converting the single-crate skeleton into a multi-crate,
  separately-published workspace was done from zero (resolver, `[workspace.package]`,
  per-crate README/CHANGELOG/LICENSE, hermetic tests), with several near-misses.
- **Root cause:** The template offered no workspace track.
- **Rule:** Follow
  [When you must deviate — workspace](#when-you-must-deviate--workspace--multiple-crates).
