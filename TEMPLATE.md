# Using this template

A starting point for Rust repositories: edition-2024 crate skeleton, strict CI
(build, test, clippy `-D warnings`, `fmt --check`), Keep a Changelog + git-cliff,
an MIT `LICENSE`, and conventions for agents in [CLAUDE.md](CLAUDE.md) /
[AGENTS.md](AGENTS.md).

> **AI agents:** before initializing a repo from this template, read
> [docs/AGENT-INIT-GUIDE.md](docs/AGENT-INIT-GUIDE.md). It captures the mistakes
> past initialization sessions made and is a living document you are expected to
> extend when new mistakes happen.

## Steps

1. Create a new repository from this one (GitHub: **Use this template**), or copy
   the files into a fresh repo.
2. Run the init script once to stamp your crate name in:

   ```pwsh
   pwsh ./scripts/init.ps1 -CrateName my-tool -Author "Jane Doe" -GitHubOwner acme -Description "A small tool"
   ```

   `-CrateName` is required; the rest are optional and fall back to sensible
   defaults (`git config user.name`, `your-org`, a TODO description, the current
   year, today's date). The script:
   - replaces the placeholder tokens in every file's contents (TOML values are
     escaped for `Cargo.toml`);
   - renames any token-named files/folders (none in the single-crate skeleton,
     but it supports `crates/__CrateName__`-style workspace adaptations);
   - activates `.claude/settings.json` from a `.template` if one is shipped
     (the default settings is an active, hook-only file — nothing to activate);
   - deletes this `TEMPLATE.md` and `docs/AGENT-INIT-GUIDE.md`, and (unless
     `-KeepScript`) itself.
3. Verify:

   ```pwsh
   cargo build && cargo test
   cargo clippy --all-targets -- -D warnings
   cargo fmt --all --check
   ```

4. Replace `src/main.rs` (and `tests/integration.rs`) with your real code — or
   switch to a library crate (`src/lib.rs`) — and fill the `Project` section of
   `AGENTS.md`.

## Placeholder tokens

| Token | Meaning |
|---|---|
| `__CrateName__` | crate name + repository name (and any token-named files/folders) |
| `__Author__` | author (LICENSE copyright holder) |
| `__GitHubOwner__` | GitHub owner/org in repository URLs |
| `__Description__` | crate description (`Cargo.toml`) |
| `__Year__` | copyright year (LICENSE) |
| `__Date__` | `CHANGELOG.md` `0.1.0` release date |

## Multi-crate / workspace projects

The init script assumes a single crate. If you want a workspace of several crates
(e.g. each its own published library), you adapt by hand — see the **workspace
track** in [docs/AGENT-INIT-GUIDE.md](docs/AGENT-INIT-GUIDE.md) for the full
checklist (`[workspace.package]`, independent vs shared versioning, per-crate
`README`/`CHANGELOG`/`LICENSE`, hermetic tests, per-crate tags).

## Post-setup checklist

- [ ] `LICENSE` author/year and license choice reviewed.
- [ ] `Cargo.toml` metadata (`description`, `repository`) filled in / correct.
- [ ] `repository` URL matches the real remote (`git remote get-url origin`).
- [ ] `CHANGELOG.md` `0.1.0` date and compare links correct.
- [ ] `AGENTS.md` `Project` section written for your crate.
- [ ] Branch protection / required checks configured for `main` (CI).
