# Pipeline scoring ingestion and review operator runbook

The canonical staged-scoring V2 workflow uses the standing directive to apply
eligible proposed scores and finalize accepted styling before one exact final
promotion decision. Pending eligible scores do not require individual ACCEPT,
and the staged workbook need not become `catalog_head` before scoring.
The individually reviewed workflow below remains valid when explicitly chosen;
historical V1 packaged-evidence paths retain their original contracts.

Pipeline owns score-application authority, the human ACCEPT/HOLD/REJECT ledger,
workbook validation, apply/finalize and catalog adoption. AFW owns qualified
scoring intent and evidence binding; WLO owns execution and attempt selection.
Pipeline performs no inference or retry decision. This guidance changes no
production policy.

## Canonical V2 — staged scoring under the standing directive

The clean-local target has three operator decisions: admit the exact source/base
and declared scoring intent, approve the exact boundaries, then approve the exact
final release. Explicit source identity, edition, pagination, publisher,
destination and successor version must be supplied through the owning
[AdventureFinder start/resume interface](https://github.com/dtnorris/adventure-finder/blob/main/docs/CATALOG_INGEST_FRONT_DOOR_V0.1.md).
Exceptions and recovery can require further choices. Optional preview or frontier
supplementation adds no mandatory score-review gate; Git persistence remains an
explicit later operator action.

### Approve boundaries, stage, and freeze qualified intent

Use the [library ingest runbook](LIBRARY_INGEST_RUNBOOK.md) through source and
boundary approval, then the [verified staged-successor contract](VERIFIED_STAGED_SUCCESSOR_V0.1.md).
The operation-bound stage retains the exact approved source, original base,
allocation and explicitly authorized successor version without intermediate
catalog promotion. A staging receipt alone grants no scoring permission.

[Staged-scoring authority and binding](../contracts/staged-scoring/v0.1/README.md)
revalidate that lineage and AdventureFinder's attributed scoring choice.
AFW's [qualified selection and frozen workload](https://github.com/dtnorris/af-workloads/blob/main/docs/AFW_FORWARD_WORKLOADS.md#operation-owned-staged-selection-v01)
bind selected/deferred/refused IDs, qualified profiles, models/digests,
source/page eligibility, conditional Levels, preflight and capability requirements.
V2 uses `af-staged-scoring-workload-binding/v0.2` with the exact AFW selection;
do not substitute a reduced ID list or rebuild against a newer catalog.
`ALL_DEFERRED` has no runnable workload; `NO_SUCCESSOR_NEEDED` is the distinct
approved zero-allocation case. Refused inputs are not successful deferrals.

With explicit local execution authority, AdventureFinder's
[local coordinator](https://github.com/dtnorris/adventure-finder/blob/main/docs/LOCAL_INGEST_EXECUTION_V0.1.md)
automatically establishes eligible exact LOW capabilities and drives the same
frozen WLO execution. It grants no retry, breaker acknowledgement, remote fallback
or paid capacity. WLO completion alone is not complete scoring evidence.
AFW binds authoritative successful attempts and publishes the complete workload
evidence manifest; retain its returned locator and exact AFW root. Missing,
failed, interrupted, pending, running, ambiguous or unsafe execution/evidence
blocks release; do not relabel it as a terminal supported gap.

### Apply standing authority and finalize the candidate

Use the retained `af-standing-bulk-score-release-inputs/v0.2` locator document
described by [standing bulk score release](STANDING_BULK_SCORE_RELEASE_V0.1.md#inputs-and-validation).
It binds the exact staged authority, selection and owner roots, frozen
plan/snapshot/index/generated paths, AFW evidence manifest, stable review/audit
destinations, and active policy/owner-selection artifacts. Use explicit public
locators, never latest-file discovery or private coordinator state.

```bash
bin/af-standing-bulk-score-release --inputs RELEASE_INPUTS.json --output RELEASE_DIR
```

This prepares/validates the complete workload review and existing ledger itself,
applies authorized values, verifies the workbook transitions and finalizes accepted
styling. Do not run the manual workflow's complete individual-decision gate first.
Authority precedence remains: source holds; individual human HOLD/REJECT/ACCEPT;
independently valid authoritative IG-16B records when supplied; then the eligible
standing directive. Human/source terminal decisions and explicit
`unsupported_scope` residuals remain accounted exceptions. Only explicitly
classified advisory flags are eligible; hard-refusal or unknown-severity flags
block publication. Never edit immutable provenance or numeric values in the ledger.

Standing acceptance is application authority, not a semantic-quality verdict or
human review. [IG-16B machine-quality acceptance](MACHINE_POLICY_ACCEPTANCE_V0.1.md#later-application-prerequisites)
separately requires exact passing IG-12B evidence and explicit application
authority. A valid non-authoritative proposal does not disable standing ingestion;
stale/invalid machine evidence fails
closed. The current final-package contract requires zero IG-16B acceptances until
its separate application and suspension/follow-up publication is available;
record-only machine acceptance cannot pass that gate. Historical mechanical
acceptance remains separately classified and is zero in this standing path.

The release publishes `RELEASE_DIR/release-candidate.xlsx` and completion proof
`RELEASE_DIR/release-accounting.json`, plus authorization and apply/finalize
reports. Accounting distinguishes authority, writes, existing values and terminal
gaps; readiness does not imply full scoring. Optional `--preview` retains
`red-cell-preview.xlsx` with no authority effect or additional approval checkpoint.
No shared catalog role is promoted here.

### Prepare the original final package and make the exact final decision

Create an explicit `af-final-release-package-inputs/v0.1` document as specified by
[final release decision input](FINAL_RELEASE_PACKAGE_V0.1.md#public-interface):
retain `release_inputs_path`, `release_manifest_path`, `catalog_repository_root`,
`current_project_state_path`, and `frontier_result_path: null` for the original
candidate. Preserve the release's original current-state observation separately
from a later current catalog observation; never rewrite retained release inputs.

```bash
bin/af-final-release-package prepare --inputs PACKAGE_INPUTS.json --output PACKAGE.json
bin/af-final-release-package validate --inputs PACKAGE_INPUTS.json --package PACKAGE.json
```

The package independently validates evidence, original lineage, candidate bytes,
authority accounting, terminal gaps, compatibility and current-to-proposed delta.
Scoring reuse and promotion preservation are separate: safe workload reuse cannot
authorize losing newer catalog changes. A blocked package is not approval.
Refresh pushed authority through the connected repository API before preparation
and immediately before approval/adoption; a local Git observation is insufficient.

Review the exact ready package through AdventureFinder's final-promotion interface
or the pipeline's [exact approval/adoption handoff](FINAL_RELEASE_PACKAGE_V0.1.md#exact-approval-and-adoption-handoff).
The latter requires prepare/validate, an attributed approve or decline decision,
and adopt with that exact request and approval. Any changed package, candidate,
evidence, catalog HEAD, manifest or role snapshot makes approval stale. Adoption
revalidates at the transaction boundary and promotes only the approved candidate
to `catalog_head`; independent roles remain governed by their owners. Neither
preparation nor standing acceptance authorizes adoption, commit or push.

### Optional frontier residual supplement

Retain the original package with `frontier_result_path: null` first. The existing
[frontier producer v0.2](FINAL_RELEASE_PACKAGE_V0.1.md#optional-frontier-producer-v02)
accepts an explicit request binding the original package/input paths, frozen
rubric identity/path/hash/size and a newer successor version. Its `prepare`,
`apply` (or `decline`) and `verify` interfaces use the structured packet and
return contract. Only blank original terminal `unsupported_scope` targets are
writable; source holds, human HOLD/REJECT and unresolved execution/evidence are
not supplement targets. `NO_GAPS` needs no frontier question.

The return supplies one reasoned, source-referenced value or explicit no-write
per target. The independently validated derived candidate and accounting retain
`frontier_manual` attribution separately from local/standing/human authority;
mechanical validation is not semantic-quality approval. Use the producer's public
`RESULT_DIR/package-inputs.json` to prepare a new final package. No original
approval carries over: final promotion requires explicit approval of those exact
selected bytes. Declining preserves the original candidate and validated gaps;
supplementation is optional and never a prerequisite to original-candidate review.

## Manual individual review — explicit compatible workflow

Run from the chosen pipeline checkout with its installed Ruby bundle. Set
`AF_PROJECT_ROOT` to the parent of your checkouts. Use an exact `AFW_ROOT` and
the `RECEIPT` returned by AFW's public evidence-binding command; see the
[AFW runbook](https://github.com/dtnorris/af-workloads/blob/main/docs/operator-runbook.md).
Set `REVIEW_DIR` to a generated package destination and `AUDIT_DIR` to the durable
human ledger destination. Keep these same destinations when repeating preparation.

### Prepare — local preparation, no canonical mutation

```bash
bin/af-data prepare-review "$RECEIPT" --afw-root "$AFW_ROOT" \
  --review-dir "$REVIEW_DIR" --audit-dir "$AUDIT_DIR"
```

The input is `afw-scoring-evidence-receipt/v0.1`, with semantic status
`provenance_validated_proposed_scoring_evidence`. Preparation validates the
receipt identity and referenced artifacts, then creates or verifies a stable
review package and initializes or validates the existing editorial ledger.
The printed package ID, reuse flag, ledger path, state and pending/accepted/held/
rejected counts describe this preparation only. Exit 0 is not accepted scoring.
Repeated identical preparation preserves existing decisions. Conflicting package
bytes, receipt provenance or ledger state fail closed; do not delete the old
package to overwrite the conflict.

#### Public package contracts

`af-scoring-review-package/v0.1` is the package identity/provenance document.
`af-scoring-review-integrity-report/v0.1` reports mechanical integrity.
The package contains `review_package.json`, `candidates.jsonl`, `holds.jsonl`,
`integrity_report.json`. These are public review
outputs, not execution-control state. The authoritative human decision surface
is the `editorial_decisions.csv` path printed by the CLI.

### Decide — human editorial mutation

Read the prepared candidate/hold records and underlying supplied evidence. Edit only the ledger's
`editorial_decision` and `editorial_note` columns. Choose ACCEPT, HOLD or REJECT
for each pending numeric candidate; HOLD/REJECT require a note. Source holds
remain HOLD until supported upstream evidence resolves them. Do not edit numeric
values or immutable provenance columns. The [editorial audit guidance](../README.md#editorial-audit)
defines the production sanity gate.

**Local validation/report preparation:**

```bash
bin/af-data editorial-audit-validate "$AUDIT_DIR" --output "$AUDIT_REPORT_DIR"
```

Set `AUDIT_REPORT_DIR` to a separate report destination. Pending decisions or
integrity errors return nonzero. The validator reports progress and emits
promotion-ready outputs only when the complete audit validates. This step
does not mutate AMC.

### Promote — canonical apply/finalize, separate explicit gate

Only after human review and a clean complete audit, select the exact base
workbook as `BASE_AMC` and a new, unoccupied destination as `SUCCESSOR_AMC`:

```bash
bin/af-data amc-apply "$AUDIT_DIR" --amc "$BASE_AMC" --output "$SUCCESSOR_AMC"
```

Apply revalidates the audit and writes only clean accepted values to a new
workbook, preserving the source. Existing conflicting cells or outputs stop
promotion. A prepared package or successful scoring command cannot authorize
apply. Review the generated integrity report before any separate adoption or
finalize step. See [AMC apply](../README.md#amc-apply) and the
[project-state contract](PROJECT_STATE.md) for the public promotion/adoption
boundary; `prepare-review` does not implicitly enter historical batch finalize.

### Troubleshooting for individual review

| Failure | Public next action / owner |
| --- | --- |
| Receipt/artifact identity mismatch | Stop. Return to AFW evidence binding; pipeline never selects another WLO attempt. |
| Existing package or ledger conflict | Preserve both evidence and decisions; rerun the same `prepare-review` for its diagnostic. Do not reset the ledger. |
| Pending decisions / audit failure | Run `editorial-audit-validate`; resolve only permitted human fields or upstream evidence. |
| Canonical target conflict | Stop at `amc-apply`'s report; review the exact base/target with the human editor. |

`bin/af-data help` lists current public commands. The
[library ingest runbook](LIBRARY_INGEST_RUNBOOK.md) covers source/boundary work
and labels the staged and manual continuations. Never edit retained provenance
to make a failed gate pass.

### Retain workload evidence with the public split-root install

Select the AFW data store with `--data-root` when compiling, verifying or
publishing a workload. The pinned AFW receipt binder resolves a frozen case's
relative qualification path beneath that data root. If compilation selected
that file from the AFW code checkout, retain a byte-identical copy at the
recorded relative path in the AFW store before publishing evidence. Compare
its SHA-256 with the case's `qualification_sha256`. A mismatch blocks
publication. Keep the original compiled case, preflight and plan bytes.
