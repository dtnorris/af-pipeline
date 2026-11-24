# Final release decision input v0.1

This is the pipeline-owned release-evidence contract consumed by the IG-18A3
approval/adoption handoff and IG-18B. It consumes the immutable candidate defined by
[Standing bulk score release](STANDING_BULK_SCORE_RELEASE_V0.1.md) and the exact
approved lineage defined by [Verified staged successor](VERIFIED_STAGED_SUCCESSOR_V0.1.md).
Those contracts remain authoritative for boundary approval, allocation, score
application and accepted-style finalization. This contract grants neither final
human approval nor catalog adoption, and introduces no workbook writer.

## Public interface

```bash
bin/af-final-release-package prepare --inputs INPUTS.json --output PACKAGE.json
bin/af-final-release-package validate --inputs INPUTS.json --package PACKAGE.json
```

The equivalent Ruby calls are:

```ruby
AfDataPipeline::FinalReleasePackage.prepare!(inputs_path:, output_path:)
AfDataPipeline::FinalReleasePackage.validate!(inputs_path:, package_path:)
```

Both return `Result(package:, path:, reused:)`. Preparation creates only the
requested JSON file, with no overwrite and an input-race check immediately
before publication. Validation is read-only; it recomputes the expected package
or reuses a process-local semantic proof after rehashing every referenced byte
and checking the exact catalog repository HEAD and remote. No caller-provided
PASS or serialized cache is trusted. Missing evidence is never reconstructed.

The executable prints the JSON package. Exit 0 means validated and ready for a
separate final decision; exit 2 means blocked or invalid. A valid blocked package
is inspectable and names its readiness reasons. Invalid evidence raises
`ValidationError` through Ruby and produces a structured refusal through the CLI.
No invalid optional frontier input silently selects another candidate.

`af-final-release-package-inputs/v0.1` has exactly these fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | Exact input schema above |
| `release_inputs_path` | The retained IG-17 locator document, byte-identical to its application snapshot |
| `release_manifest_path` | Exact retained `release-accounting.json` |
| `catalog_repository_root` | Explicit local catalog Git repository root |
| `current_project_state_path` | Exact current `PROJECT_STATE.yml` at that repository root |
| `frontier_result_path` | Null by default; otherwise exact optional result described below |

All locators are explicit. Component-root environment overrides remain the
caller’s responsibility; the package neither rewrites nor rediscovers them.
The release's original current-state observation must remain available at its
retained locator. Current catalog advancement is supplied separately; do not
rewrite the release inputs to substitute a later observation.

## Guarantees and limits

The single `af-final-release-package/v0.1` JSON contains a concise human summary,
exact candidate version/hash/size, original candidate identity, canonical
boundary/parent mappings, complete case and metric denominators, accepted values
and authority selectors, terminal gaps and remaining blanks, workbook
verification, compatibility limitations, current-to-proposed ID/cell delta,
readiness reasons and a provenance graph of validated artifact references.
Ledgers, source text, receipts and workbooks remain in their owning evidence
stores; the package does not copy them.

The package independently replays the IG-17 inputs and refuses rehashed count
or authority changes. Every intended case and metric must reconcile, including
both Levels siblings. Standing directive, individual human decisions, historical
mechanical classification and frontier manual supplementation remain separate.
Standing authority points to the exact policy, owner selection and immutable
application. Human authority points to the exact decision ledger and record key.
Source/HOLD/REJECT exceptions and preserved existing values remain visible even
when their workbook cells are populated. Full scoring is distinct from readiness
for a terminal release with gaps.

The current IG-16A record validator does not supply IG-16B's per-release
application and suspension/follow-up publication. IG-16B is deferred because its
evaluation/application prerequisites are absent. This version therefore requires
an explicit zero machine-accepted count and refuses record-only nonzero claims;
it does not enable or simulate that policy. A later integration must bind and
independently validate the actual public application/control contract before
this refusal can be narrowed.

The original frozen base is bound separately from current catalog HEAD, exact
manifest bytes, all three current roles and proposed `catalog_head`. Current
manifest and role artifact bytes must match that local Git HEAD. The caller must
refresh pushed authority through its connected repository API before preparing
and immediately before an eventual approval/adoption transaction. A local Git
observation does not claim a remote refresh.

IG-13A scoring reuse and promotion preservation are independent results.
Unrelated current scores may permit workload reuse while the old-base candidate
would lose them. Such a package is blocked. Lost current IDs/updates, allocation
collisions, unprovable changes and incompatible lineage are refused; no rebase,
merge, ID regeneration, staged-byte rewrite or boundary reinterpretation occurs.
The delta retains worksheet/column, value, formula and cell attributes, including
existing-ID score changes. Independent roles are snapshots, not promotion targets.

Static workbook compatibility does not prove live AFW execution or matcher
baseline compatibility. Its actual public limitations are included in the
package. Preview request/existence is informational and missing preview bytes
do not block this contract. Required original/apply/finalized artifacts do.

Identity is the canonical SHA-256 of all package content except `package_id`.
No preparation/validation timestamp is introduced. Equal unchanged inputs replay
to the same identity and existing package bytes are preserved. Any changed
approval-relevant input requires a newly prepared decision input, never an
in-place edit to an earlier package.

## Exact approval and adoption handoff

`bin/af-final-release-adoption` is the public pipeline owner contract IG-18B
invokes. It is a five-step handoff, not a caller-managed comparison/copy/promote
sequence:

```bash
bin/af-final-release-adoption prepare \
  --inputs INPUTS.json --package PACKAGE.json --output REQUEST.json
bin/af-final-release-adoption validate \
  --inputs INPUTS.json --package PACKAGE.json --request REQUEST.json
bin/af-final-release-adoption approve \
  --inputs INPUTS.json --package PACKAGE.json --request REQUEST.json \
  --decided-by "HUMAN OWNER" --output DECISION.json
# Use `decline` with the same arguments to record a refusal.
bin/af-final-release-adoption adopt \
  --inputs INPUTS.json --package PACKAGE.json --request REQUEST.json \
  --approval DECISION.json --result RESULT.json
```

The equivalent Ruby API is `FinalReleaseAdoption.prepare!`, `validate!`,
`decide!`, and `adopt!`. The request binds the canonical package bytes and ID,
input bytes, selected candidate path/version/hash/size, evidence-graph digest,
release manifest, expected `PROJECT_STATE.yml` bytes, repository root/remote/HEAD,
all three role snapshots, compatibility result, and human-review delta. The
decision binds its human owner and `APPROVE` or `DECLINE` disposition to the
exact canonical request bytes, request ID, and package ID. It has no timestamp
or filename-only authority. There is no `--approved` adoption bypass and no
stdin confirmation path.

An approval is revalidated immediately before mutation and again while the
catalog transaction lock is held. Any changed candidate, package, referenced
evidence, manifest, repository HEAD/remote, `catalog_head`, or independent role
snapshot makes the approval stale. The transaction calls the same
`CatalogAdoption` writer as `af-project-state adopt`: cross-consumer
compatibility, exact catalog review, no-overwrite import, monotonic versioning,
role preservation, and final `ProjectState` promotion are not reimplemented by
the coordinator.

Scored adoption carries the validated package's exact release, original base,
staged workbook and optional frontier-result references into `CatalogAdoption`.
Its optional Ruby `scored_release:` argument is a mapping with required
`release_manifest`, `base`, `staged`, `package` and `package_inputs` keys and
optional `frontier`; each value
contains exactly an absolute `path`, `sha256` and `bytes`. These references
prove existing score authority; they grant neither approval nor promotion.
Absent provenance retains the ordinary unassessed-new-row compatibility rules.
Missing, mismatched or changed references fail closed. Frontier consumption of
standing-release v0.2 also carries the retained AFW/scorer owner roots and exact
selection path into staged-authority validation. Its selection, publication and
generated-workload evidence remain subject to the
[standing release contract](STANDING_BULK_SCORE_RELEASE_V0.1.md).
The owner revalidates the bound final package before scored publication and
requires its exact selected candidate and version, catalog root and reference graph. This
retains the existing concurrent-change-preservation check even for a direct
Ruby adoption caller; release cell authority alone cannot authorize replacing
an incompatible advanced catalog.

The compatibility check's optional `release_base_path:` binds the original
scored-release base independently of `base_path:`, which remains the current
catalog comparison. It requires scored-release evidence and never rebinds the
release to an advanced catalog. Existing added-ID, workbook, package readiness
and concurrent-change-preservation rules still apply; this is not a rebase.

Scored adoption bypasses the ordinary catalog compatibility proof cache and
revalidates the real release/workbook evidence during preparation, while the
transaction lock is held, before publication and on already-promoted replay.
Snapshots bind the exact reference bytes. Already-promoted replay reconstructs
the reviewed catalog observation from `PROJECT_STATE.yml` at the exact reviewed
Git HEAD. Its SHA-256/size and all three historical roles must equal the package
and adoption snapshot. The live manifest must be byte-identical to the existing
`ProjectState` owner's single approved `catalog_head` promotion; the imported
artifact, independent roles, Git HEAD and remote must still match. Additional
manifest edits or catalog advancement require a fresh review and cannot replay.

This historical observation is read-only and applies only to that exact manifest
locator. Every immutable release/frontier reference is rehashed at its original
locator, including original package, rubric, source, selection and application
evidence. The complete final package and V2 frontier handoff are independently
reconstructed against that observation. Process-local semantic proof reuse still
rehashes every reference and checks the exact repository and live promotion;
serialized PASS is never authority. Historical references retain their original bytes, identities and
lineage; they are neither rewritten to the promoted manifest nor exempted by
reference-name prefix. Original scored-row authority still uses the frozen base,
while compatibility compares against the reviewed pre-promotion catalog. The
ordinary package/packet preparation interfaces continue to observe live state;
replay cannot prepare an approval, renew a decision or publish another candidate.
The canonical package/request/decision contracts and explicit Git-persistence
boundary remain unchanged.

New stages retain their authoritative `staged-5e_Adventure_Master_Catalog_VERSION.xlsx`
basename through workload selection, scoring and package evidence. The approved
scored candidate is imported as `5e_Adventure_Master_Catalog_VERSION.xlsx` in the
same catalog root. The exact staged workbook remains immutable and available;
the authorized numeric version is shared, not incremented to evade a collision.
Retained canonical-name stages remain valid evidence at their original locators
but still cannot be overwritten by a differently hashed candidate.

When the release's original current-state locator is this same catalog manifest,
read-only standing-release replay applies the existing `CatalogReplayObservation`
from its initial authority/input-snapshot reconstruction onward. This is necessary
after the approved role promotion, including without process-local proof caches.
The observation maps only the exact manifest to reviewed historical bytes and
rechecks the exact live promotion; every other input remains live-hashed.
Ordinary release creation observes live state and accepts no historical override.

Missing approval returns `NO_APPROVAL`; an exact decline produces a durable
`DECLINED` result without catalog mutation. Successful adoption produces a
canonical result binding the actually promoted workbook and post-mutation
project state. Interruption before manifest mutation removes an imported
candidate. Interruption after manifest mutation is recoverable: an identical
retry verifies the exact already-promoted package and either reconstructs the
missing result or reuses the existing result without a second mutation. Git
commit and push remain separate operator authority.

When a retry reuses an original durable `PROMOTED` result, the Ruby and CLI
invocation response reports `ALREADY_PROMOTED`. This response is marked
`durable: false`, has its own content-derived `result_id`, and binds the
unchanged durable result by path, historical status and ID, SHA-256 and size.
The result path still names the retained canonical record. If that record is
missing, the retry writes a canonical `ALREADY_PROMOTED` result instead.

## Optional frontier consumer contract

IG-17F is optional. The V2 producer below uses this existing consumer envelope
and the independent workbook proofs. An absent result selects the original
IG-17 candidate. Historical V0.1 synthetic consumer evidence retains its own
versioned meaning; it does not claim that a V2 packet was produced.

`af-frontier-derived-release-evidence/v0.1` contains exactly `schema_version`,
`result_id`, `disposition`, `original_manifest`, `original_candidate`, `artifacts`,
`version` and `counts`. Content IDs are canonical SHA-256 of the object excluding
its ID field. Original bindings contain SHA-256/bytes and must match the exact
IG-17 artifacts. Artifact bindings contain local basename `filename`, SHA-256
and bytes. All files must already exist; the consumer never produces them.

`DECLINED` has only a `handoff` artifact, null version, zero writes and one
no-write per target. It preserves the original candidate and only the terminal
gap authorization already present in IG-17. `APPLIED` has `handoff`, `return`,
`authorization`, `intermediate`, `apply_report`, `finalize_report` and `candidate`
artifacts, an exact newer candidate version, and independently reconciled
`writes`/`no_writes` counts.

The handoff schema is `af-frontier-residual-handoff/v0.1`, with `handoff_id`, exact
`release_id`, `manifest_id`, original `lineage`, `original_candidate`, `targets`
and `references`. Targets are sorted, unique and exactly the blank original terminal
`unsupported_scope` residuals; each has `candidate_key`, `adventure_id`,
`dimension`, and null `original_value`. Existing values, source holds and human
HOLD/REJECT are never writable. References include the frozen rubric, every
immutable application input except its moving current-state observation, and
every original staged-authority evidence binding. They may use explicit absolute
`path`/SHA-256/bytes to existing immutable evidence, or a local artifact binding;
copying source/evidence stores is unnecessary.

The return schema is `af-frontier-residual-return/v0.1`, with `handoff_id`,
`return_id` and exactly one record per target. Each record contains
`candidate_key`, `proposed_value`, `reason` and `source_references` naming handoff
references. A finite numeric value requests a write; null plus an explicit
reason records a no-write. Supported metric/cell identities and effective Levels
constraints are independently checked by the established workbook/compatibility
seams. This is provenance/integrity validation, not semantic-quality approval.

The application authorization schema is
`af-frontier-application-authorization/v0.1`, with `authorization_id`,
`release_id`, `handoff_id`, `return_id`, `authority: frontier_manual` and the exact
non-null `accepted_candidates` (key, Adventure ID, dimension, proposed value).
It must equal the authorization retained by the apply report. Both writer
transitions are independently replayed and only blank authorized residual cells
may change. Original and derived identities and separate frontier write/no-write
and remaining-gap counts appear in the final package. The original release's
authority counts remain unchanged.

`FrontierReleaseEvidence.validate!` exposes this read-only result proof.
`AmcScoredNewIdAuthorization.validate!` and `AmcCompatibilityCheck.check` accept
the optional `frontier_result_path:` only alongside the original exact
release/base/staged tuple. The proof never becomes a free-standing bypass.

Presentation and coordination remain AdventureFinder responsibilities. Approval
binding, mutation-time validation, catalog adoption, and replay proof remain
pipeline responsibilities. Final Git persistence remains a separate operator
authority.

## Optional frontier producer v0.2

`FrontierResidualScoring` owns the public V2 handoff lifecycle. It reuses the
original package above as the public provenance input; it neither reconstructs
private coordinator paths nor invokes legacy production-batch commands.
Prepare and retain the original package with `frontier_result_path: null`
first. A blocked promotion package can still provide verified terminal scoring
evidence; supplementing it does not waive any final promotion readiness check.

The caller supplies one `af-frontier-residual-request/v0.2` JSON object with
exactly these fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | `af-frontier-residual-request/v0.2` |
| `original_package_inputs_path` | Absolute path of the original package input document |
| `original_package_path` | Absolute path of its already prepared, verified package |
| `rubric` | Object with explicit nonblank `id`, absolute `path`, lowercase `sha256`, and exact `bytes` |
| `successor_version` | Explicit candidate version newer than the original staged version |

The rubric selection is explicit operator input, frozen when the packet is
prepared. No latest-AFAO lookup, fallback or implicit reinterpretation of a
local score occurs. Existing local evidence remains attributed to its own
retained execution. With no writable gaps, rubric and successor version may be
null: preparation returns `NO_GAPS`, creates no directory and asks no frontier
question. Nonterminal execution, invalid evidence or ambiguous lineage never
qualifies for this branch.

For new public-method work, explicitly bind
`AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md` from
`dtnorris/af-specification-md` revision
`394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf`:
`id` = `af-specification-md@394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf/AFAO/1.6.1`,
`sha256` = `dcfad224ab9517272504a508f935a804032d04a7c812ede10498921ce4585fa1`,
`bytes` = `339101`, and `path` = its selected absolute path.
Verify the selected checkout and its `documents.json` inventory before preparing
the request; do not resolve a moving branch or numeric maximum. AFAO 1.6.1
remains Candidate pending targeted GM Preparation Burden 4/5 revalidation.
This example uses the existing explicit rubric contract; it does not change
historical packets or imply scorer/profile qualification.
