# Verified staged successor v0.1

`AfDataPipeline::BoundaryFreezeStage` is the operation-bound preparation seam for
creating a successor Adventure Master Catalog without promoting any shared catalog
role. Its durable receipt uses schema
`af-boundary-freeze-staged-successor/v0.1`.

```bash
bin/af-data boundary-freeze-stage APPROVED_FREEZE.yml \
  --operation-input OPERATION_ROUTING_INPUT.json \
  --successor-authority SUCCESSOR_VERSION_AUTHORIZATION.json \
  --source-root "$AF_PROJECT_ROOT/md-for-llm-book-content" \
  --catalog-root "$AF_PROJECT_ROOT/af-xlsx-data-sources"
```

The command consumes two AdventureFinder-owned public projections. The existing
`af-ingest-routing-input/v0.1` projection binds the exact operation, routed freeze,
source, publisher, and frozen base catalog. The separate
`adventurefinder-successor-version-authorization-projection/v0.1` projection binds
the explicitly selected successor version. Pipeline independently recomputes the
authorization digest and requires its operation ID, operation contract, and frozen
base SHA-256/byte count to match the routing input. It never reads AdventureFinder's
private operation or authorization stores, never interprets `policy.selected_values`
as version authority, and never infers an increment.

Pipeline then validates the boundary freeze and all referenced source/base bytes.
Its `BoundaryFreezeApply` adapter supplies the actual admitted artifact and exact
freeze/base hashes to the selected `af-xlsx-files` owner (see
[dependency selection](PROJECT_STATE.md#catalog-owner-dependency)). XL owns the
single deterministic allocator and workbook write/integrity kernel. XL checks
those byte bindings, representation, finite capacity and exact cells/formulas/styles
independently; PL retains source/editorial, operation, version authority and replay
admission. A self-digest or attribution string never replaces those PL validators.

Before publishing or reusing the receipt, PL compares the saved plan with a
reconstruction from actual bound inputs, and XL verifies the resulting workbook
against that reconstruction. The unchanged receipt schema binds:
receipt binds:

- operation revision/document/routing-input identity;
- successor-version authorization identity, selector, timestamp, and projection
  digest;
- freeze digest, approval attribution, source provenance, and exact frozen base;
- output workbook and apply-report digests;
- allocated IDs, frozen record order, resolved parent relationships, changed cells,
  and workbook verification;
- an exact snapshot of `catalog_head`, `matcher_authorized_baseline`, and
  `production_dependency_floor`; and
- `catalog_head_promoted: false` and `scoring_authorized: false`.

The base workbook and `PROJECT_STATE.yml` must remain byte-identical throughout the
operation. No adopt command, workload build, scoring command, Git action, or external
execution is launched. A failure after workbook application removes only the newly
created successor and apply report; a later invocation refuses a partial publication
or any conflicting pre-existing path.

Identical replay validates the existing workbook, apply report, staging receipt, and
current inputs without rewriting or allocating IDs again. Changed freeze, operation,
authorization, base, source, publisher, output, apply report, project state, or
receipt bytes fail closed. A valid zero-record freeze writes only a trace receipt with
`NO_SUCCESSOR_NEEDED`; it does not manufacture an empty successor version.

## Staging and publication filenames

New operation-bound stages use
`staged-5e_Adventure_Master_Catalog_VERSION.xlsx` beside the catalog manifest.
`VERSION` remains the explicitly authorized numeric successor version. The
canonical `5e_Adventure_Master_Catalog_VERSION.xlsx` filename is reserved for
reviewed publication through `FinalReleaseAdoption` and `CatalogAdoption`.
The prefix changes neither version authority nor the unscored workbook's role.
Raw `BoundaryFreezeApply` successor paths and ordinary adoption are unchanged.

The v0.1 receipt shape is unchanged: `successor.filename` records the actual
immutable staged basename. Staged authority, AFW selection/workload inputs,
standing release and final-package evidence consume that authoritative filename;
they must not reconstruct a canonical publication name for a staged input.
Final approval still binds exact scored bytes and the canonical destination.
No overwrite exception, relocation authority or additional catalog role exists.

A retained v0.1 receipt selecting the original canonical basename replays at
that exact original path, with all receipt, source, base, report and workbook
checks intact. A retained new-style receipt similarly selects its staged name.
Only these two deterministic basenames are supported; a caller-supplied path
or alias is not accepted. No receipt or artifact is rewritten or moved, and a
missing/partial legacy publication is refused rather than recreated under the
new name. Legacy scored releases whose immutable stage occupies their canonical
destination remain blocked by the existing no-overwrite adoption contract.
Use a fresh operation for the separated forward lifecycle; this is not migration.

## Ownership and continuation

The terminal state is `VERIFIED_STAGED_SUCCESSOR`, explicitly not shared
`catalog_head`. The staged workbook remains an af-xlsx-data-sources artifact candidate
referenced by pipeline-owned provenance; no new `PROJECT_STATE.yml` role is added.
Later IG-13A+ work may consume the receipt under its own scoring-authority contract.
This command does not grant that authority or implement promotion.

The legacy `boundary-freeze-apply` and `af-ingest-next` paths are unchanged. A raw
apply report still routes through the existing reviewed catalog-adoption path. The new
staging command stops before that route, and `af-ingest-next` does not treat the staged
receipt as an adoption or scoring instruction.
