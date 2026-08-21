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

## TL;DR — the six rules

1. **Read before you write.** Read `TEMPLATE.md`, this file, `AGENTS.md`, and
   `CLAUDE.md` *first*. Do not generate a single file based on an assumed layout.
2. **Check the toolchain first.** Run `scripts/check-env.ps1` (or
   `scripts/check-env.sh`). If it reports a missing tool, STOP and offer the user
   the install commands it prints — don't run init against an environment that
   can't build or test.
3. **Prefer the init script over hand-rolling.** `scripts/init.ps1` (PowerShell)
   and `scripts/init.sh` (POSIX) are the supported path for a standard
   single-crate init — run whichever fits your shell. Don't recreate their token
   substitution by hand.
4. **Match the shell to the tool.** On Windows the Bash tool is POSIX (git bash);
   PowerShell cmdlets fail there with `command not found`. Use the PowerShell
   tool for `pwsh`/cmdlets, the Bash tool only for POSIX. Prefer the dedicated
   Read / Glob / Grep tools over either shell for file inspection.
5. **Make the mistake impossible, not just documented.** When you find a gap,
   prefer fixing the template/script over adding a checklist note (shipping a
   tokenized `LICENSE` beats "remember to add a license").
6. **Verify, then it's done.** `cargo build` + `cargo test` + `cargo clippy
   --all-targets -- -D warnings` + `cargo fmt --all --check`. If it publishes,
   also `cargo package`.

## What this template actually is

Confirm these facts by reading, not by assuming:

- It is a **token template**, not a ready project. Placeholder tokens
  (`__ProjectName__`, `__Author__`, `__AuthorEmail__`, `__GitHubOwner__`,
  `__Description__`, `__Year__`) appear in file contents (and may appear in file/folder
  names in workspace adaptations). `scripts/init.ps1` (or the POSIX
  `scripts/init.sh`) substitutes them.
- It is **single-crate** by default: a binary crate (`src/main.rs`) with an
  integration test (`tests/integration.rs`), edition 2024.
- Conventions (all enforced — see `AGENTS.md`):
  - CI is strict: `cargo fmt --all --check`, `cargo clippy --all-targets
    -- -D warnings` (warnings are errors), build + test on Linux, Windows **and** macOS,
    a `cargo-deny` supply-chain scan (`deny.toml`), and an MSRV check.
  - Every dependency gets a "why" comment in `Cargo.toml`; `Cargo.lock` is
    committed; no fixed allow-list of crates.
  - MSRV is `Cargo.toml` `rust-version` (verified by the `msrv` CI job);
    `rust-toolchain.toml` pins everyday builds to `stable` + rustfmt/clippy.
  - `CHANGELOG.md` is Keep a Changelog; manual bullets win over the git-cliff
    (`cliff.toml`) auto-fill keyed on conventional-commit subjects. Releases run
    via `.github/workflows/release.yml` (manual `workflow_dispatch`; needs the
    `CRATES_IO_TOKEN` secret).
  - LF line endings via `.gitattributes` (`* text=auto eol=lf`); `.editorconfig`
    covers editor defaults for non-Rust files.
- It uses **jujutsu (`jj`)** colocated with git. Drive VCS through `jj`.

## The happy path (standard single-crate init)

1. **Read** `TEMPLATE.md` and this guide. Skim `AGENTS.md` / `CLAUDE.md`.
2. **Check the environment.** Run `scripts/check-env.ps1` (or `check-env.sh`). If
   it flags a missing tool, stop and offer the user the install commands it prints
   before continuing — don't init against an environment that can't build or test.
3. **Run the init script** with the values the user gave you:

   ```pwsh
   pwsh ./scripts/init.ps1 -ProjectName my-tool -Author "Jane Doe" -GitHubOwner acme -Description "A small tool"
   ```

   On a POSIX shell, run `scripts/init.sh` instead (same behavior, flag syntax):

   ```bash
   bash ./scripts/init.sh --project-name my-tool --author "Jane Doe" --github-owner acme --description "A small tool"
   ```

   The crate name is required; the rest fall back to sensible defaults. The
   script substitutes tokens (TOML-escaped for `Cargo.toml`), renames any
   token-named files/folders, refuses all path/settings collisions before its
   first write, and deletes `TEMPLATE.md`,
   `docs/AGENT-INIT-GUIDE.md`, the template-only initializer security harness
   and its CI step, and both initializers (unless `-KeepScript` /
   `--keep-script`). Run **one** initializer, not both.
4. **Verify**:

   ```pwsh
   cargo build && cargo test
   cargo clippy --all-targets -- -D warnings
   cargo fmt --all --check
   ```
5. Replace the placeholder `main`/test with the real code (or switch to
   `src/lib.rs`), fill the `AGENTS.md` `Project` section, replace `README.md`
   (the shipped one documents *the template*, not the new crate), and confirm the
   `repository` URL matches the real remote (`git remote get-url origin`).
6. **Make the agent instructions local-only.** The template ships its agent
   instructions (`AGENTS.md`, `CLAUDE.md`, `.claude/`) *tracked* so template
   contributors share one config — but a repo *generated* from the template
   should keep them local: they're your private working notes for this project,
   not artifacts to publish. So in the new repo, stop tracking them and ignore
   them (this does **not** apply to the template repo itself, which keeps them
   tracked):
   1. In `.gitignore`, delete the `!.claude/` and `!.claude/**` lines (they exist
      to *force* `.claude/` to be committed — the opposite of what you now want),
      along with their explanatory comment and the now-redundant
      `.claude/settings.local.json` line, then add the instruction files:

      ```gitignore
      # Agent instructions — local-only to this repo, never committed.
      /AGENTS.md
      /CLAUDE.md
      /.claude/
      ```

      Add any other agent-instruction files you introduce later (e.g.
      `.cursorrules`, `.github/copilot-instructions.md`) to that same list.
   2. Stop tracking the copies the template committed — an ignore rule alone
      won't drop files git already tracks, so remove them from the index too
      (the files stay on disk):

      ```bash
      git rm -r --cached AGENTS.md CLAUDE.md .claude/
      git add .gitignore   # stage the .gitignore edits above, or they won't be committed
      git commit -m "chore: keep agent instructions local-only"
      ```

      In a **jj-colocated** repo, use `jj file untrack AGENTS.md CLAUDE.md
      .claude` instead of the `git` commands (it folds into the working-copy
      commit). Order matters: `jj file untrack` only drops paths already matched
      by an ignore rule, so do step 1 first.

   From then on, edits to these files are neither staged nor pushed. **Do this
   before the first push:** a repo created via GitHub's *Use this template*
   already carries these files in its initial commit, so untracking keeps them
   out of *later* commits only — anything already pushed stays in history.

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

### 2026-08-21 — initializer collisions could overwrite or partially mutate a checkout
- **Symptom:** A token-named file could replace an existing file on POSIX, a
  token-named directory could be moved *inside* an existing directory, and an
  existing `.claude/settings.json` was overwritten. PowerShell often failed on
  the same collisions only after content replacement had already started.
- **Root cause:** Renames and shared-settings activation were executed without a
  checked, filesystem-aware destination plan; collision discovery was delegated
  to differing shell move semantics after earlier mutations. The POSIX traversal
  could also return a partial plan without propagating `find` failure.
- **Rule:** Both initializers preflight every token-path rename and settings
  activation before the first template write, reject incomplete traversals,
  compare destinations using the repo filesystem's actual case semantics, and
  report all conflicting source→destination mappings together. Execute content,
  path, and settings mutations as one rollback domain with non-overwriting moves:
  a destination that appears after preflight must remain untouched, while the
  initializer restores the original file bytes, names, and directories. The
  template security harness verifies both the late-race rollback and that
  case-distinct targets remain valid on case-sensitive filesystems.

### 2026-08-20 — template-only initializer checks leaked downstream
- **Symptom:** An initialized repo retained the initializer security CI step and
  verifier even though a standard init deleted both init scripts. Author names
  containing quotes were also substituted into the verifier's Python literals,
  making that retained test syntactically invalid.
- **Root cause:** The global token pass treated template regression fixtures as
  downstream source, while cleanup removed neither the harness nor its CI entry.
- **Rule:** Exclude template-only fixtures from token substitution and remove
  them together with a marked CI block on every initialization. Exercise both
  PowerShell and POSIX generated copies without the keep flag so dangling
  template-only entrypoints cannot pass template-side tests.

### 2026-06-04 — init.sh emitted an unbuildable Cargo.toml on a backslash
- **Symptom:** `scripts/init.sh --description 'runs on C:\Windows'` wrote
  `description = "runs on C:\Windows"` to `Cargo.toml`; `cargo build` then failed
  with `error: missing escaped value`. `\t`/`\n` in a value silently corrupted to
  a tab/newline instead. `init.ps1` was unaffected.
- **Root cause:** `toml_escape` correctly doubled `\`→`\\`, but the substitution
  used bash `${content//token/$value}`, whose replacement string drops a level of
  backslash (`\\`→`\` on bash ≥4.3; bash 3.2 leaves it — also version-dependent),
  re-corrupting the escaping. PowerShell's `.Replace()` is literal, so the two
  initializers diverged.
- **Rule:** init.sh substitutes via `awk` (literal `index`/`substr`, source +
  values passed through `ENVIRON`, which does no escape processing) instead of
  bash `${//}`. Keep the two initializers byte-for-byte equivalent — a `\` or `"`
  in `--author`/`--description` must round-trip identically through both.

### 2026-05-31 — second initializer corrupted by the first
- **Symptom:** When a POSIX `scripts/init.sh` was added next to `init.ps1`, running
  either initializer rewrote the *other's* literal token strings (`__ProjectName__`
  etc. are the search keys both scripts contain), leaving a broken sibling script
  behind in the downstream repo.
- **Root cause:** The content-substitution pass excluded only the running script,
  not the other initializer.
- **Rule:** Both initializers skip **both** init scripts during content
  replacement, and (unless `-KeepScript` / `--keep-script`) delete both on
  completion. A downstream repo keeps zero initializers. If you add a third
  scaffolding script that embeds these tokens, exclude it the same way.

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
- **Rule:** These are now tokens (`__GitHubOwner__`, `__ProjectName__`) that
  `scripts/init.ps1` substitutes; the URL default comes from `git remote`. The
  `CHANGELOG.md` release date and compare links are filled by the release
  workflow on release, not by init.

### 2026-05-29 — workspace built from scratch with no guidance
- **Symptom:** Converting the single-crate skeleton into a multi-crate,
  separately-published workspace was done from zero (resolver, `[workspace.package]`,
  per-crate README/CHANGELOG/LICENSE, hermetic tests), with several near-misses.
- **Root cause:** The template offered no workspace track.
- **Rule:** Follow
  [When you must deviate — workspace](#when-you-must-deviate--workspace--multiple-crates).
