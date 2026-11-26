# Work Plan

Prioritized roadmap derived from current GitHub label state. Regenerated automatically by the Guide role whenever labels change — see [WORK_LOG.md](WORK_LOG.md) for completed work.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

- **#325**: feat: add in-app update check and one-click self-install for macOS

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#338**: Per-account scope (personal | work): push/export skip personal accounts; popover marks them

## In Progress

Issues currently being built (`loom:building`).

- **#210**: Remove Claude Monitor → LLM Monitor compatibility shims (~/.claude-monitor symlink, claude-monitor alias)
- **#285**: Show each account's available usage-limit resets (weekly and per-model) alongside utilization
- **#320**: Codex accounts show "usage unknown" on a host that no longer runs Codex, though other hosts hold fresh readings
- **#323**: Offer an in-app "Update now" when a newer release is available
- **#367**: accounts list counts Codex seats at 100% weekly as usable while the popover counts them exhausted
- **#368**: Register new Loom Codex profiles on a poll tick, not only at launch or by codex list

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#366**: refactor!: remove the Claude Monitor compatibility shims

## Approved (Awaiting Merge)

PRs that passed review (`loom:pr`). Unheld PRs are queued for Champion auto-merge; held PRs require a human merge decision.

- **#325**: feat: add in-app update check and one-click self-install for macOS *(held)*
- **#370**: fix: classify stored windows at their cap as spent in the export status path

## Proposed

Issues carrying `loom:curated`.

- **#249**: Opt in to selected Z.ai shared-pool seats and show sub-1% quota usage *(curated)* *(held)*
- **#285**: Show each account's available usage-limit resets (weekly and per-model) alongside utilization *(curated)*
- **#320**: Codex accounts show "usage unknown" on a host that no longer runs Codex, though other hosts hold fresh readings *(curated)*
- **#323**: Offer an in-app "Update now" when a newer release is available *(curated)*
- **#338**: Per-account scope (personal | work): push/export skip personal accounts; popover marks them *(curated)*
- **#367**: accounts list counts Codex seats at 100% weekly as usable while the popover counts them exhausted *(curated)*
- **#368**: Register new Loom Codex profiles on a poll tick, not only at launch or by codex list *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 1 |
| Very important | 0 |
| Important | 0 |
| Ready (`loom:issue`) | 1 |
| In Progress (`loom:building`) | 6 |
| PRs awaiting review | 1 |
| Approved PRs awaiting merge | 2 |
| Curated | 7 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
