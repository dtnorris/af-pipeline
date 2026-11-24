# Standing bulk score release v0.1

The af-standing-bulk-score-release executable composes the existing
staged-scoring, complete-workload review, AMC apply, AMC finalization and
integrity seams. It publishes a verified release candidate and accounting
package but never adopts the workbook into catalog_head or another shared role.

## Authority

The durable policy contract is
adventurefinder-standing-bulk-score-ingestion-policy/v0.1. The checked-in v1
policy is active because its separately versioned owner-selection record binds
the project, policy ID/version and the IG-17 project-owner directive. Neither
record fabricates a historical approval time. Both carry canonical content
identities, and every application binds their exact artifact hashes.

The directive authorizes application of every otherwise supported proposed
numeric value in the exact frozen workload. It is application authority, not a
human review or a semantic-accuracy verdict. Candidate authority is classified
in this precedence order:

1. source-defined holds;
2. individual human HOLD, REJECT or ACCEPT;
3. an independently valid authoritative IG-16B machine record, when supplied;
4. the standing directive for an eligible pending candidate.

A valid non-authoritative machine proposal, including one without the later
IG-12B/application prerequisites, does not disable standing ingestion. Invalid
or stale machine evidence fails closed. Historical mechanical acceptance is
always reported separately and is zero for this path.

The policy enumerates exact permitted profiles, model aliases, models and
metric identities. Its source scope is the operation-bound exact source, and
its page scope is the authority-bound frozen qualified workload. Advisory flags
remain eligible only when explicitly classified as advisory. Hard-refusal and
unknown-severity flags stop publication.

## Inputs and validation

The locator document uses
af-standing-bulk-score-release-inputs/v0.1. It provides:

- staged-scoring evidence locators, authority store, current project-state
  observation, frozen workload binding and exact plan/snapshot/index paths;
- the AFW workload-evidence manifest, AFW root and existing review/audit paths;
- the standing-policy and owner-selection paths; and
- an optional map of independently authorized machine records and their
  revalidation roots.

For an AFW qualified selection and
`af-staged-scoring-workload-binding/v0.2`, use
`af-standing-bulk-score-release-inputs/v0.2`. Its `staged_scoring` object
retains the v0.1 fields and additionally requires `selection_path`,
`selection_afw_root` (AFW executable repository),
`selection_project_root` (the same AFW project as `workload_review.afw_root`),
and `selection_scorer_root` (scorer repository). Configured selections also carry
`selection_scorer_config` (the exact AFW roots-only YAML file). It is forwarded
through standing release and frontier replay to the AFW owner verifier, which
refuses missing or changed configuration. `workload_paths` also requires
`generated`, the AFW generated-case directory, alongside `plan`, `snapshot`
and `index`. The selection, frozen binding and generated paths must be the
canonical paths for the same workload under the AFW project. The selection
publication and each generated file join the immutable release input snapshot.
The release and final package invoke AFW's public selection verifier through
`StagedScoringAuthority`, including on replay. The v0.1 locator remains valid
only for its original v0.1 frozen workload; adding a selection locator to that
version or omitting one for v0.2 fails closed. This input upgrade does not
change the standing-policy directive or authorize catalog adoption.

The release re-runs StagedScoringAuthority, including exact approved
freeze/base/staged lineage and current-role concurrency. It then re-runs
WorkloadScoringReviewPackage, independently reconciles the frozen
plan/snapshot/index identities, and validates the durable editorial ledger.
Missing, failed, ambiguous or nonterminal execution/evidence cases block.
Human/source terminal decisions and explicit unsupported-scope candidates
remain named residuals.

## Output

    bin/af-standing-bulk-score-release \
      --inputs RELEASE_INPUTS.json \
      --output RELEASE_DIRECTORY

The normal release contains:

- release-candidate.xlsx, with newly written cells finalized to the accepted
  style;
- immutable apply/finalize reports and an internal verified apply intermediate;
- release-authorization.json; and
- release-accounting.json, written last as the completion proof.

Accounting reconciles intended cases, execution/evidence cases, metric
candidates, each authority class, writes, exact already-present cells, terminal
gaps, conflicts and boundary-created IDs. It publishes residual candidate,
source/evidence and workbook bindings suitable for a later optional frontier
supplement. Release completeness does not claim every intended score is
present.

The explicit --preview option additionally retains red-cell-preview.xlsx. Its
manifest entry states authority_effect: none; generating or opening it creates
no approval checkpoint and cannot promote it as catalog_head. A future
AdventureFinder front door may expose this exact explicit option without
changing the pipeline contract.

Output publication is no-overwrite. Exact replay revalidates current inputs and
every retained apply/finalize artifact without rewriting bytes. A conflicting
or partial existing directory is refused. Failures before the accounting
manifest remove the incomplete attempt and never announce a release candidate.

## Scored boundary-created ID compatibility

`AmcScoredNewIdAuthorization.validate!` is the read-only public authority seam
for a later release-evidence package. It takes the exact release-accounting
manifest, finalized candidate, staged AMC and original base AMC. It verifies
all retained release artifact bindings and canonical identities, requires the
same boundary/workload lineage in the release and application authorization,
and independently re-runs both workbook transitions:

- staged AMC to the internal apply intermediate, permitting only the apply
  report's exact authorized cells and append-only style addition; and
- apply intermediate to the accepted-style candidate, permitting only the
  corresponding fill transition.

The result grants no general compatibility exception. It names only scored
cells whose sheet, cell reference, Adventure ID, dimension and numeric value
match an apply record for a declared boundary-created ID. The result is bound
to the exact base, staged and candidate bytes and to the release/manifest
identities. Missing or changed artifacts, authority, lineage or ID accounting
fail closed.

`AmcCompatibilityCheck.check` and `.validate!` accept that proof through the
paired `release_manifest_path:` and `staged_path:` keywords when an exact
`base_path:` is also supplied. Without the complete tuple, the existing rule
that new-ID production score fields must be blank remains in force. With a
valid proof, only the exact named score cells may be populated; formula, style,
unrelated-cell and package integrity remain governed by the independently
replayed writer checks. The check also recognizes the canonical split layout
when an empty `AMC >100pg` sheet is referenced by the `Current Books` special
rows. A formula cache preserved from the staged workbook is not treated as a
new write when the exact scored-cell transition has been proven.

Metric identities and AMC header bindings come from the existing pipeline-owned
`AmcApply::DIMENSION_HEADERS` mapping. The scorer defines assessment metric
identities; AFW retains qualified case/result identities, including the two
independent `Level Start` and `Level End` results. This seam does not expand
their qualification or the writer's supported mappings. The sessions aliases
resolve to the same `Number of Sessions` column, but conflicting cell targets
are refused. Every accepted application record must have a supported identity,
exact candidate key, writer action, numeric value and independently resolved
Adventure ID row, sheet part and mapped column. Unsupported accepted records
fail closed; explicit release residuals grant no cell permission.

Levels writes are checked independently at their respective mapped cells.
The existing compatibility rule still permits staged populated Levels and a
blank pair, and refuses asymmetric, nonintegral, reversed or out-of-range pairs.

The compatibility report proves pipeline AMC structure/integrity, static
scorer/catalog column requirements and, when supplied, exact retained IG-17
application evidence. It does not validate live AFW execution. The historical
`AFIO_SCORE_HEADERS` constant remains only as a backward-compatible alias for
the unchanged required AMC assessment columns, never as scoring authority.
The seam does not prepare the
complete release-evidence package, approve adoption, mutate `catalog_head`, or
add another workbook/catalog writer. Final approval and transaction-boundary
adoption remain downstream responsibilities.

No inference, execution, provider/capacity action, Git mutation, qualification
change, shared-role adoption or catalog promotion occurs.

## Final decision input

[Final release package v0.1](FINAL_RELEASE_PACKAGE_V0.1.md) is the downstream
pipeline-owned prepare/validate contract. `StandingBulkScoreRelease#validate_existing!`
reconciles the entire retained accounting manifest against the complete inputs
and writer evidence without reconstructing missing artifacts. It returns the
verified release plus a separately refreshed scoring-concurrency projection
when `current_project_state_path:` is supplied. Optional preview bytes are not
required by this read-only consumer; ordinary release replay retains its strict
artifact-set behavior. The final package neither grants human approval nor
changes any shared catalog role.

`af-ingest-next --scorer-config FILE` (or explicit `AF_SCORER_CONFIG`) retains
that selector in rendered continuations, AF front-door handoffs and AFW build
commands. This selection does not grant allocation, approval or qualification.
