# Architecture

## Purpose

`af-data-pipeline` owns the lifecycle of **existing** AdventureFinder scoring evidence after inference has completed and before accepted data is promoted into a production catalog.

## Principles

1. **Raw evidence is immutable.** Generated indexes and normalized records are derivative artifacts and retain source-path/hash provenance.
2. **Explicit adapters, not broad guessing.** Each supported producer/layout gets a named adapter with fixtures and tests. Unrecognized files stay unrecognized.
3. **Unknown means unknown.** Do not manufacture git SHAs, model names, prompt versions, corpus versions, or other provenance.
4. **Mechanical validity is separate from editorial acceptance.** Schema/identity/range/duplicate checks are mechanical; whether reasoning justifies the numeric score remains editorial.
5. **Future production writes fail closed.** AMC mutation must require an explicit reviewed ledger and reject unexpected overwrites, ambiguous IDs/dimensions, and count mismatches.

## Current evidence-to-review boundary

AFW's public `afw-scoring-evidence-receipt/v0.1` binds proposed scoring evidence.
The pipeline's `prepare-review` consumes that receipt, validates its referenced
artifacts and creates/reuses a deterministic review package and human ledger.
It does not select WLO attempts or infer acceptance from execution success.
See the [operator runbook](operator-runbook.md). Human ACCEPT/HOLD/REJECT and
canonical apply/finalize remain separate pipeline/editorial gates.

## Historical evidence compatibility

`ProductionSnapshotV1` continues to recognize `lme-legacy-v1` and
`lme-current-v1`; `lme_run_id` is historical provenance. Preserve old paths,
schema labels, IDs and hashes. These readers do not make a retired orchestrator
part of the current production path. Add adapters only for concrete producer
contracts and representative fixtures.

RPOF is not an `af-data-pipeline` boundary. This repository consumes completed
inference evidence; it does not perform capability checks, dispatch inference,
or expose RPOF operations.

## Production-evidence storage target

The frozen successor contract for durable production-scoring evidence is
[production-evidence storage contract v0.1](EVIDENCE_STORAGE_CONTRACT_V0.1.md).
It defines immutable batch bundles plus authoritative manifests in
`llm-response-data`, with a committed but derived/rebuildable SQLite evidence
index. Deterministic build, verification, indexing, and retrieval tooling belong
in `af-data-pipeline`.

This is a target contract, not a production cutover. Existing expanded evidence
and current ingest behavior remain unchanged until later parallel validation
proves the successor representation lossless and operationally equivalent.

## Private operational data root

`AF_DATA_PIPELINE_DATA_ROOT` selects the pipeline's writable store. Every
command that publishes pipeline artifacts requires an existing absolute private
directory. `AF_DATA_PIPELINE_ROOT` selects executable code for external callers.
An operator selects the source and catalog stores independently. Pipeline data
paths resolve under the selected root; changing it does not rebind a prior
approval or receipt.

When present, the selector is authoritative. Empty/blank values, relative or
missing roots, traversal, symlink ancestors, unwritable roots, and overlap in
either direction with executable code are errors. There is no fallback.
An explicit legacy pipeline-root selector must equal the selected data root;
it cannot override it. Explicit AFDP operational outputs/stores must be beneath
the selected root. Existing symlinks, dangling links and special files in the
destination tree are rejected before publication. Relative explicit outputs
still resolve from the caller's working directory, then undergo containment
validation; they are not silently relocated. Generated defaults alone are
rebased. Keep selectors fixed for the lifetime of a service/process.

The operator must control the selected filesystem and its existing contents;
this path validation does not sandbox arbitrary Ruby code or defend against a
concurrent process replacing filesystem ancestors after validation. Temporary
work retains the existing TMPDIR contract; callers must separately bind HOME,
TMPDIR and tool caches to disposable/private locations. Temporary editorial
validation directories that pass through the durable-output guard are created
under the selected root and removed afterward.

### Active ownership and replay inventory

The table identifies durable destinations from the public `bin/af-*` entries
and their invoked services, including read/replay paths. Explicit paths mean
the existing API/CLI supplies a path, constrained by the boundary when enabled.
Content hashes, human approvals and no-overwrite/replay rules remain owned by
each existing artifact contract; selecting a root grants no content authority.

| Active producer / entry | AFDP operational writes and retained reads | Resolution in dual-root mode |
| --- | --- | --- |
| `af-source-progress` / `SourceProgression` | Intake JSON/Markdown, dossier JSON/Markdown, editorial context/decisions/review; exact-output replay | Selected root's `audits/pre-scoring/`; returned locator root remains `pipeline`, now mapped to the data root |
| `af-ingest-next` / `IngestNext` | Router itself reads only; `--auto` invokes intake, registration, dossier, editorial and freeze commands; searches bound dossiers and freeze drafts/finals | Audit generation **and dossier search** use selected root; executable paths and cwd remain code-root based; rendered commands carry the selector |
| `af-source-intake`, `af-boundary-dossier` | Intake/dossier companions and immutable evidence | Explicit output directory beneath private root |
| `af-boundary-editorial`, `boundary-freeze-init` | Context/decisions/review bundles, approval record, draft/frozen YAML, rebind/import/freeze-approved output; replay preserves ledger/approval bytes | Explicit outputs; default approval stays beside its bundle; approved-freeze validates both draft and final destinations before creating either |
| `af-data scan/normalize/horizontal-review/production-review` and three review writers | Inventory, normalized records, candidate/hold/error JSONL, review Markdown and integrity reports | Default `output/{scan,review,horizontal-review,production-review}` under private root; explicit outputs are validated |
| `prepare-review`, `prepare-workload-review` / review-package services | Deterministic package/manifests/unresolved cases plus existing editorial ledger; reads validate exact package and ledger binding | Both review and audit destinations must be inside private root before either is published |
| `editorial-audit-init/validate` / `EditorialAudit` | Ledger, manifest, instructions, validation JSON/JSONL/Markdown | Explicit audit/validation output; existing source-review references remain evidence inputs |
| `af-staged-scoring-authority issue/validate` | Operation lock, immutable `authority.json` and `publication.json`; exact cold replay | Existing `store_root` / required `--store` must be beneath private root, including replay; no default authority store is invented |
| `af-standing-bulk-score-release` | Release candidate workbook/intermediate, apply/finalize reports, authority, manifest and optional preview; immutable replay | Explicit private release directory; synthetic intent never grants real authorization |
| `af-frontier-residual-scoring` | Packet, return/result metadata, intermediate/candidate workbooks and reports; exact packet/result verification | Explicit private output; existing protected-input checks remain |
| `af-final-release-package`, `af-final-release-adoption` | Package, adoption request and explicit human decision documents; read-only validation/observation | Explicit private output; catalog adoption remains a separate canonical operation |
| `af-data evidence-retrieve` | Verified extracted member/run files (derived copies, not canonical evidence) | Explicit private output, still outside canonical evidence root |

### External stores and legacy exclusions

Canonical Markdown and its registry remain source-owner data (`af-source-place`
and `af-source-register`). Catalog workbooks, co-located boundary apply/stage
reports/receipts and `PROJECT_STATE.yml` remain catalog-owner artifacts
(`boundary-freeze-apply/stage`, AMC apply/finalize and project-state adoption).
The generic AMC writers also compose private release workbooks; their caller's
owning service establishes that private destination before invoking them.
Canonical bundles/manifests/indexes, equivalence reports, historical expanded
archives, ingestion provenance copies and duplicate-recovery evidence remain
`llm-response-data`-owned. The evidence builders/verifiers/shadow writer do not
reinterpret those roots as AFDP operational storage. None of these external
stores is relocated, discovered beneath the data root, or authorized by it.

The source registry, catalog, AFW workload store, evidence archives and
approved policy documents retain their owners and must be selected explicitly.
Temporary ZIP and decompression files follow the host TMPDIR contract.

### Downstream invocation and cutover boundary

The following are examples, not real owner authorization. All variables name
independently prepared disposable roots/artifacts. The data root must already
exist. Code executes from `CODE`; `DATA` supplies the `pipeline` locator map.

```sh
cd "$CODE"
export AF_DATA_PIPELINE_DATA_ROOT="$DATA"
bin/af-source-progress "$RECEIPT" --operation-input "$ROUTING_INPUT" \
  --source-root "$SOURCE" --catalog-root "$CATALOG" \
  --canonical-destination "$SOURCE/invented.md" --json
bin/af-ingest-next "$DATA/audits/pre-scoring/invented-source-intake/source_intake.json" \
  --source-root "$SOURCE" --catalog-root "$CATALOG" --json
bin/af-staged-scoring-authority validate --inputs "$LOCATORS" \
  --store "$DATA/authorities" --project-state "$CATALOG/PROJECT_STATE.yml" --synthetic
```

DPS-06/07/08 may pass the same variable through subprocesses while retaining
their separately selected code root. No additional flag, root discovery or
repository alias is required. `--pipeline-root "$DATA"` is optional for source
progression; a different explicit value fails. Staged authority still requires
its independently validated inputs and an existing publication for validation.

A future cutover must separately authorize and preserve exact data/evidence,
reconcile prepared absolute root bindings and coordinator locator maps, and
verify restart/replay before use. Merely changing the variable cannot rebind an
old production preparation. Rollback means restoring the prior authorized
configuration and its unchanged data, not copying or overwriting state. This
patch performs no cutover, migration, catalog-role change or publication.

## Modules

- `SourceWorkspace` — safely opens directories, ZIPs, or files.
- `Scanner` — inventories artifacts and computes hashes.
- `Adapters::*` — converts known producer formats to canonical records.
- `Normalizer` — applies adapters and validates records.
- `ReviewPacketWriter` — emits review-oriented Markdown.
- `CLI` — thin command interface.

## Future adapters

- additional concrete producer layouts, only with versioned contracts and representative fixtures
- legacy manually organized `llm-response-data` trees

Adapters should be driven by real fixtures rather than assumptions.
