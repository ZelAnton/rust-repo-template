# Rust repository template

A depersonalized baseline for new Rust repositories. It ships the tooling,
conventions, and AI-agent guidance shared across projects — minus any
project-specific code, names, or dependency lists. It is a **token template**:
`scripts/init.ps1` stamps your crate name and metadata in.

> **AI agents:** before initializing a repo from this template, read
> [docs/AGENT-INIT-GUIDE.md](docs/AGENT-INIT-GUIDE.md) — a living guide that
> captures mistakes past initializations made, and that you are expected to
> extend.

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
- **`LICENSE`** — tokenized MIT (`__Year__`/`__Author__`) matching the `license`
  field; filled in by the init script.
- **`scripts/init.ps1`** — one-shot initializer: substitutes the `__…__` tokens,
  renames token-named files/folders, and removes the template-only docs.
- **`TEMPLATE.md`** — human usage guide (token table, post-setup checklist);
  removed on init.
- **`docs/AGENT-INIT-GUIDE.md`** — agent init guide + a living failure log of
  mistakes to avoid; removed on init (pitfalls are logged back to the template).

## Starting a new project from this template

Run the init script, then verify:

```pwsh
pwsh ./scripts/init.ps1 -CrateName my-tool -Author "Jane Doe" -GitHubOwner acme -Description "A small tool"
cargo build && cargo test
```

See **[TEMPLATE.md](TEMPLATE.md)** for the token table, optional pieces, and the
post-setup checklist; **[docs/AGENT-INIT-GUIDE.md](docs/AGENT-INIT-GUIDE.md)** for
the agent playbook (including the workspace/multi-crate track).

After initializing, if you hit anything the guide didn't catch, add it to the
failure log in `docs/AGENT-INIT-GUIDE.md` (in the template) so the next project
doesn't repeat it.

## Conventions

See [AGENTS.md](AGENTS.md) for the full set: code style, dependency management
(every dependency gets a "why" comment; no fixed allow-list), the changelog
process, and the `jj` version-control workflow.
