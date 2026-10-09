# SymbiOS Documentation Index (DOCS.md)

Start here, then follow the ownership table. Each document owns its topic;
do not duplicate content across files - link instead.

## Start paths

- **Install and use**: README.md (overview) -> INSTALL.md (install
  steps) -> FEATURES.md (what each settings page does).
- **Operate and debug**: SCRIPTS.md (every `scripts/` entry with usage)
  -> `scripts/<name>.sh --help` on the host (authoritative detail).
- **Develop playbooks**: playbooks.md (the `# docs:` contract) ->
  services.md (service concept) -> mediapaths.md (media rules).
- **Develop the WebUI/CLI**: AGENTS.md (untracked local working
  document: architecture, conventions, CLI-first rules, roadmap).

## Ownership

| Document | Audience | Owns | Must not duplicate |
|----------|----------|------|--------------------|
| README.md | Everyone | Project overview, architecture summary, install summary, layout | Install details (INSTALL.md), playbook authoring (playbooks.md) |
| INSTALL.md | New installers | Step-by-step installation | Install summary (README §8 stays a summary + pointer) |
| FEATURES.md | Users/admins | What each settings page and feature does, with inventory vars | Script usage (SCRIPTS.md), playbook internals |
| SECURITY.md | Auditors/admins | Threat model, accepted risks, security posture | - |
| services.md | Service authors | Service concept (base vs user vs custom playbooks) | `# docs:` contract (playbooks.md) |
| playbooks.md | Playbook authors | Service playbook authoring, `# docs:` reference | Service concept (services.md) |
| mediapaths.md | Service authors | Media locations and mount semantics (single source of truth) | Per-service media vars (use the globals) |
| SCRIPTS.md | Admins/developers | Every `scripts/` entry: purpose, arguments, conventions | Feature behavior (FEATURES.md), per-script `--help` detail |
| settings-fields.md | Admins/developers | GENERATED field tables per settings script (do not edit; run `symbios-settings-docs.sh --write`, gate with `--check`) | Hand-written prose (FEATURES.md) |
| AGENTS.md | Developers/AI | Architecture, coding standards, CLI-first contract, roadmap | Untracked by design (local working doc, never committed) |

## Rules

- Summaries may live in two places (e.g. README §8 vs INSTALL.md) only
  as summary + pointer, never as two full copies.
- Catalog tables (scripts, settings, services) are generated from
  `--help`/`schema`/`# docs:` sources where tooling exists
  (`symbios-settings-check.sh`, catalog parsers) instead of maintained
  by hand. Until then, changed behavior updates its owner doc first.
- New settings domains update FEATURES.md (user view) and rely on
  `--help`/`schema` for the admin view (no SCRIPTS.md prose needed
  beyond the catalog row).
