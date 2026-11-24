# `af-boundary-freeze/v0.1`

`af-boundary-freeze/v0.1` is the structured handoff between deterministic AdventureFinder source/catalog state and a deliberately human-engaged frontier-model editorial review.

It is not an Adventure-ID allocator and it does not mutate an Adventure Master Catalog (AMC).

## Lifecycle

```text
canonical Markdown + source_registry.yml + explicit base AMC
                         ↓
bin/af-data boundary-freeze-init
                         ↓
             draft handoff YAML
                         ↓
        David + frontier ChatGPT
   Phase 1 → Phase 1b → Phase 2 review
                         ↓
       populated + approved YAML
                         ↓
bin/af-data boundary-freeze-validate
                         ↓
          validated frozen handoff
                         ↓
 future deterministic ADV ingestion
```

The software-owned provenance in `source` and `base_amc` is initialized from bytes on disk. Do not rewrite those values during frontier review. If they no longer match, rerun initialization or deliberately reconcile the changed source/base artifact; do not repair hashes by hand.

## Initialize

```bash
bin/af-data boundary-freeze-init \
  --source-root "$SOURCE_ROOT" \
  --source-id "Example Source" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --output audits/pre-scoring/example-boundary-freeze.yml
```

Optional `--registry PATH` overrides `source_registry.yml`; a relative override is resolved beneath `--source-root`. The registry itself must live beneath the source root.

Initialization fails closed if the source root, registry, registered Markdown files, or base AMC cannot be established. It refuses to overwrite an existing handoff.

The initialized artifact is `state: draft`, has blank approval values and `records: []`, and contains no newly assigned Adventure IDs.

For segmented registry entries, all Markdown files referenced by that canonical source identity are bound into the handoff with SHA-256 values. This avoids assuming that one source-book identity always corresponds to one Markdown file.

### Preferred editorial import path

The normal library-ingest workflow no longer requires frontier review to
hand-edit this YAML. `bin/af-boundary-editorial` maintains the complete Phase
1/1b/2 candidate ledger separately, preserves rejected/merged candidates and
selection history, and deterministically imports only accepted records into a
fresh draft `af-boundary-freeze/v0.1` after David's explicit approval.

The record semantics below remain the normative freeze contract and a valid
manual fallback. The preferred path is documented in
[BOUNDARY_EDITORIAL_HANDOFF_V0.1.md](BOUNDARY_EDITORIAL_HANDOFF_V0.1.md).

## Frontier review responsibilities

Use the initialized YAML together with the canonical Markdown source content. Phase 1 should maximize recall; Phase 1b / Phase 2 should decide canonical identity and restrained nesting. David is the approval gate.

During review:

- do not change `schema_version`, `source`, or `base_amc`;
- do not assign a new `ADV-XXXX` value to any record;
- populate only accepted canonical records in `records`;
- use stable source-local `local_key` values;
- for a newly accepted nested record, set `parent_key` to its local parent's `local_key`;
- for a record nested under an already-canonical AMC parent, set `parent_adventure_id` instead;
- leave both parent fields absent for a root record; a record may itself have a parent and also have local children;
- include Levels only when editorially established by the source;
- keep a concise `editorial_rationale` describing why the boundary/identity was accepted;
- set every accepted record's `state` to `frozen`;
- after David approves the complete set, fill `approval.approved_by`, fill quoted ISO-8601 `approval.approved_at`, and set the top-level `state` to `frozen`.

A normal accepted record is shaped like:

```yaml
- local_key: source-local-stable-key
  canonical_title: Canonical adventure title
  printed_pages:
    start: 10
    end: 24
  pdf_pages:
    start: 12
    end: 26
  parent_key: source-local-parent-key
  levels:
    start: 3
    end: 5
  editorial_rationale: Concise source-grounded reason this is a canonical adventure boundary.
  state: frozen
```

`pdf_pages` and `levels` are optional. Parentage is represented only by the
optional `parent_key` / `parent_adventure_id` edge: set at most one. A local
`parent_key` must resolve to another frozen record in the handoff, self-parenting
and cycles are rejected, and nesting depth is otherwise unrestricted. Parent,
child, and root status are derived from those edges rather than stored as a
separate relationship taxonomy.

### v0.1 pagination constraint

A frozen v0.1 record requires a concrete positive `printed_pages.start` / `printed_pages.end` span. That is intentionally narrower than every theoretically possible source. If a real source cannot be represented faithfully in this coordinate, stop and extend the contract rather than inventing a page span.

For a segmented source, the frozen printed-page span must be fully contained by exactly one registered segment. Crossing a segment boundary or falling in a registry gap fails validation.

## Validate

```bash
bin/af-data boundary-freeze-validate \
  audits/pre-scoring/example-boundary-freeze.yml \
  --source-root "$SOURCE_ROOT" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx"
```

Use the same optional `--registry PATH` convention as initialization.

Validation recomputes and checks the registry SHA-256, every bound Markdown SHA-256, and the explicit base-AMC SHA-256. It also validates the contract version, frozen approval state, record keys, page ranges, parent-edge structure and cycles, optional Levels, and absence of unsupported fields such as a newly assigned `adventure_id`.

Validation is read-only. It never assigns IDs, changes the YAML, or mutates the AMC.

An existing `parent_adventure_id` is syntax-checked in this pass but is not looked up inside the XLSX. Canonical AMC ID/row reconciliation belongs to the later deterministic freeze-to-successor-AMC applicator, which must read the workbook anyway.

## Failure rule

A validation failure means the artifact is not eligible for deterministic ADV ingestion. Return to source QA or Phase 2 review and fix the semantic or provenance mismatch. Do not bypass a failed hash, fabricate a parent, guess a page span, or edit an Adventure ID into the freeze.
