# Boundary editorial handoff v0.2 (v0.1 compatible)

`bin/af-boundary-editorial` is the deterministic seam between the pre-Phase-1 boundary dossier and the existing `af-boundary-freeze/v0.1` artifact.

It does **not** decide what counts as an adventure. David + frontier reasoning still own Phase 1, Phase 1b, Phase 2, and final approval.

The feature exists to remove three clerical/manual failure modes:

- reformatting chat/editorial conclusions into a different freeze shape;
- losing rejected/merged/split/held candidates and therefore reconstructing selection history later; and
- manually rewriting provenance when source identity or the selected base AMC changes.

## Bundle shape

Initialization creates a directory containing:

- `editorial_context.json` — software-owned provenance bound to one exact boundary dossier;
- `editorial_decisions.yml` — the only editable editorial ledger;
- `editorial_review.md` — human/frontier instructions and the candidate schema.

`editorial_decisions.yml` created by current tooling uses `af-boundary-editorial-decisions/v0.2`. Existing v0.1 ledgers remain readable. The v0.2 schema adds optional structured review evidence and a traceable `split` disposition; it does not change the downstream freeze schema.

`editorial_context.json` binds:

- the exact boundary-dossier filename, schema version, and SHA-256;
- canonical source identity;
- source-registry identity/SHA-256;
- every registered Markdown filename/SHA-256;
- segmented source ranges when present;
- the exact base-AMC filename/SHA-256; and
- controlled rebind history.

Do not edit `editorial_context.json` by hand. A changed source/base requires `rebind`.

## Initialize after boundary-dossier generation

```bash
bin/af-boundary-editorial init \
  --dossier audits/pre-scoring/example-boundary-dossier \
  --spec-root /absolute/path/to/af-specification-md \
  --output audits/pre-scoring/example-boundary-editorial
```

The command accepts either the dossier directory or its `boundary_dossier.json`.

For new public-forward review, explicitly select the public document directory
at `dtnorris/af-specification-md` revision
`394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf`. `--spec-root` verifies the pinned
`documents.json` SHA-256
`5ebb0fffcafa165a71bd3afef70e483217074d788d02ff9241ab3cedfd6bf0e6`
and exactly Editorial Rev 2.0 (Draft) and ABDS 1.4 (selected for new work).
The emitted attachments and optional `public_specifications` context binding
record repository, source revision, inventory digest, paths, versions, statuses,
file hashes and sizes. Extra higher-version files do not change selection;
missing, altered or symlinked required files refuse the forward action.
This is a content binding to that source revision, not proof of the installed
checkout's Git state or acceptance of the Draft.

Validation, render, approval, import and approved-freeze replay recheck this
binding. The existing approval covers the exact context and review bytes, so
an approval for another selection cannot transfer. Keep the selected definitions
available at their bound location. `rebind` retains the selection and still
requires a new approval under the existing policy; it cannot switch methods.

Omitting `--spec-root` retains the historical bundle contract. It is not public
adoption. Never edit an existing bundle, approval or old ABDS 1.3 operation to
add this label. Begin a new bundle and obtain a new approval for new selection.
The dossier route in `bin/af-ingest-next` requires `--spec-root ABSOLUTE_PUBLIC_DIR`
before emitting initialization or running it with `--auto`. It checks the exact
required bytes before bundle creation and carries the selection into the emitted
initializer. Without a selection it pauses at `NEEDS_EDITORIAL_SPECIFICATIONS`
and prints an explicit initializer template. AdventureFinder's read-only routing
child receives the same selection guidance. No specification environment default
is used; existing bundles retain their original bindings. Operation-bound
`af-source-progress` also pauses before creating a new bundle, while exact
existing-bundle replay and source-QA checks retain their original contracts.

Initialization creates an empty candidate ledger. Software deliberately does not turn headings, navigation anchors, signal hits, or TOC entries into adventure candidates.

## Editorial candidate ledger

Every candidate receives a stable `candidate_key` when first retained in Phase 1. That key persists through Phase 1b, Phase 2, controlled rebinds, and—if accepted—becomes the `local_key` in `af-boundary-freeze/v0.1`.

A candidate records:

- provisional title;
- optional provisional printed/PDF spans;
- optional apparent parent context;
- source-grounded playability evidence;
- open questions;
- append-only editorial `review_history`;
- current disposition; and
- when accepted, the exact canonical fields to import.

Supported dispositions:

- `pending` — not yet adjudicated;
- `hold` — explicitly unresolved;
- `accept` — canonical record to import;
- `reject` — explicitly reviewed and excluded;
- `merge` — reviewed as the same canonical identity as another accepted candidate.
- `split` — the original high-recall candidate remains traceable while naming at least two explicit candidate keys produced by later review.

`pending` and `hold` are valid while review is in progress but block complete validation and import.

Rejected, merged, and split candidates remain in the ledger permanently. They are not silently deleted after Phase 2.

## ABDS v1.4 review evidence

Phase 1 favors recall and retains nested or borderline material. Phase 1b pressure-tests those candidates. Phase 2 adjudicates canonical identity, nesting, title, established levels, and exact boundaries. David then approves the exact complete result. Software validates the shape and references of that record; it does not decide whether the evidence is editorially sufficient.

The optional `editorial_review` mapping can preserve:

- source-supported facts, explicitly labeled editorial inferences, and unresolved ambiguities;
- the four-part Survivor Play-Spine Proof: Entry, Authored middle, Resolution / exit, and Reviewer completion;
- homogeneous sibling-set calibration, including the compared candidate keys and controlling distinction;
- pairwise Incremental Playable Identity and Boundary-Before-Identity reasoning for parent/nested cases;
- relevant precedent references;
- competing canonical interpretations; and
- start/end evidence plus material page-boundary disagreements.

These fields are human/frontier working evidence. They are not numeric thresholds, overlap rules, or autonomous classification inputs. Empty or absent optional evidence is not silently treated as proof.

### Accepted candidate

```yaml
- candidate_key: source-stable-key
  provisional_title: Source-facing title
  provisional_printed_pages:
    start: 10
    end: 12
  provisional_pdf_pages:
    start: 14
    end: 16
  apparent_parent_context: Optional source-facing parent
  playability_evidence: Source-grounded reason this candidate deserved review.
  open_questions: []
  review_history:
    - phase: phase1
      status: retained
      rationale: High-recall reason for retaining it.
    - phase: phase2
      status: accepted
      rationale: Final canonical identity/boundary decision.
  editorial_review:
    evidence:
      source_supported:
        - A source-supported structural fact.
      editorial_inferences:
        - An explicitly labeled editorial interpretation.
      unresolved_ambiguities: []
    survivor_play_spine:
      entry: How play begins.
      authored_middle: What sustained authored play exists.
      resolution_exit: How play resolves or exits.
      reviewer_completion: Why this is a coherent playable unit.
  disposition: accept
  decision:
    canonical_title: Canonical adventure title
    printed_pages:
      start: 10
      end: 12
    pdf_pages:
      start: 14
      end: 16
    parent_candidate_key: optional-accepted-parent
    levels:
      start: 3
      end: 4
    editorial_rationale: Concise rationale imported into the frozen boundary artifact.
```

`pdf_pages`, parentage, and `levels` remain optional exactly as permitted by `af-boundary-freeze/v0.1`.

Use `parent_candidate_key` only for another accepted candidate in the same ledger. It becomes `parent_key` on import. Use `parent_adventure_id` only for an already-canonical AMC parent. Set at most one.

### Reject

```yaml
disposition: reject
decision_rationale: Reviewed reason this candidate is not a canonical adventure boundary.
```

### Merge

```yaml
disposition: merge
merge_into_candidate_key: accepted-target-key
decision_rationale: Reviewed reason these candidates are one canonical identity.
```

The merge target must exist and be accepted. Merge chains are intentionally not supported.

### Hold

```yaml
disposition: hold
decision_rationale: Exact unresolved question blocking final disposition.
```

### Split for further review

```yaml
disposition: split
split_into_candidate_keys:
  - source-stable-child-a
  - source-stable-child-b
decision_rationale: Why the original Phase 1 candidate resolves into these explicit candidates.
```

The original candidate and its review history remain in the ledger. Every target must exist, targets must be distinct, and split chains are rejected. The target candidates carry their own dispositions and evidence.

## Render the complete ambiguity-first workspace

```bash
bin/af-boundary-editorial render \
  audits/pre-scoring/example-boundary-editorial
```

`render` writes Markdown to standard output and does not mutate the context or ledger. Its view contains:

1. exact bound source/dossier/base provenance and a complete disposition count;
2. an ambiguity-first section ordered only from explicit ledger state and recorded concerns;
3. the complete proposed canonical set; and
4. the full Phase 1 candidate inventory, including ordinary low-risk candidates and every non-accepted disposition.

The ambiguity-first section foregrounds holds, pending work, split/merge questions, reviewed rejections, parent/child questions, precedent-sensitive decisions, competing interpretations, and page disagreements. It is a presentation order, not a semantic classifier. A complete, traceable result containing zero accepted adventures is valid.

## Validate during review

```bash
bin/af-boundary-editorial validate \
  audits/pre-scoring/example-boundary-editorial
```

This validates the ledger while allowing `pending` and `hold`.

Before import:

```bash
bin/af-boundary-editorial validate \
  audits/pre-scoring/example-boundary-editorial \
  --complete
```

`--complete` fails closed unless every candidate has a terminal `accept`, `reject`, `merge`, or `split` disposition. It also validates candidate-key uniqueness, page spans, optional levels, accepted parent references/cycles, merge/split targets, structured evidence references, and allowed fields. `pending` and `hold` continue to block import.

## Decision import into the existing freeze contract

Initialize a fresh draft freeze using the same exact source and base AMC bound by the current dossier:

```bash
bin/af-data boundary-freeze-init \
  --source-root "$SOURCE_ROOT" \
  --source-id "Exact Canonical Source Identity" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --output audits/pre-scoring/example-boundary-freeze-draft.yml
```

Then, after David has reviewed the complete editorial result, issue approval as
its own explicit action. Software records the timestamp; the operator does not
type one:

```bash
bin/af-boundary-editorial approve \
  audits/pre-scoring/example-boundary-editorial \
  --dossier audits/pre-scoring/example-boundary-dossier \
  --source-root "$SOURCE_ROOT" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --approved-by David \
  --output audits/pre-scoring/example-boundary-editorial/editorial_approval.json
```

The versioned `af-boundary-editorial-approval/v0.1` record binds exact SHA-256
identities for the context, complete decisions (including rejected, merged, and
split rows), editorial instructions, deterministic rendered review, dossier,
registry, ordered source files, optional registered segments, and frozen base
AMC. It also records reconciled disposition counts, the approver, a stable
approval identity, and the software-supplied UTC timestamp. The rendered view
is bound as a deterministic derivation of the validated context and ledger; it
is not a second editable truth store.

Identical replay against the same output validates and reuses the exact record
bytes without timestamp churn. Any changed bound input makes the record stale.
Preserve that immutable record and issue a new approval to a new path only after
re-review. `rebind` never carries an approval forward.

The composed public operation consumes that record, initializes the clean draft
when it does not yet exist, imports the accepted records, and performs the final
approval-to-freeze validation:

```bash
bin/af-boundary-editorial freeze-approved \
  audits/pre-scoring/example-boundary-editorial \
  --approval audits/pre-scoring/example-boundary-editorial/editorial_approval.json \
  --dossier audits/pre-scoring/example-boundary-dossier \
  --freeze audits/pre-scoring/example-boundary-freeze-draft.yml \
  --source-root "$SOURCE_ROOT" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --output audits/pre-scoring/example-boundary-freeze.yml
```

It terminates at `VALIDATED_FROZEN_BOUNDARIES`. It does not apply the frozen
records to an AMC, allocate Adventure IDs, promote a catalog, start scoring, or
invoke inference. The lower-level `init`, `import`, and `validate` commands
remain available for inspection and recovery, but do not add another approval
gate.

Import:

1. requires a complete editorial ledger;
2. verifies the exact boundary dossier still matches `editorial_context.json`;
3. requires a clean, empty `state: draft` `af-boundary-freeze/v0.1`;
4. verifies dossier and draft-freeze source/base provenance agree exactly;
5. imports **only** accepted candidates;
6. preserves rejected, merged, and split candidates in `editorial_decisions.yml`;
7. uses stable `candidate_key` values as freeze `local_key` values;
8. validates the exact immutable approval record before and during publication;
9. copies its approver and software-recorded timestamp into the historical
   `af-boundary-freeze/v0.1` approval fields;
10. writes a new freeze file without mutating the draft; and
11. runs the existing `BoundaryFreeze.validate!` against the produced artifact before making it visible at the output path.

Loose legacy `--approved-by` / `--approved-at` import or routing flags cannot
authorize import. Existing historical `af-boundary-freeze/v0.1` files remain
readable and retain their original approval fields, but they are not retroactively
declared provenance-bound approvals.

No Adventure ID is accepted from the editorial ledger or created by this command.

### Exact replay and public verification

`freeze-approved` validates the IG-09A approval before doing any work. If the
draft is absent, it publishes a clean draft atomically from the exact registered
source and base AMC; an existing draft must already be clean and match the
dossier. A first successful run publishes the frozen YAML only after the
existing freeze validator passes.

If the output already exists, the operation never overwrites it. It validates
the existing bytes and reuses them only when their complete artifact is the
exact deterministic projection of the current approved ledger: source/base
provenance, approver and software timestamp, accepted records, stable
`candidate_key`/`local_key` mapping, page spans, parent edges, and optional
levels must all match. Any conflict is an error and preserves the existing
file. Rejected, merged, and split history remains in the approval-bound ledger;
it is not copied into the freeze's accepted-record list.

Independent consumers can verify the same linkage without trusting prior CLI
output:

```bash
bin/af-boundary-editorial validate-approved-freeze \
  audits/pre-scoring/example-boundary-editorial \
  --approval audits/pre-scoring/example-boundary-editorial/editorial_approval.json \
  --dossier audits/pre-scoring/example-boundary-dossier \
  --source-root "$SOURCE_ROOT" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --output audits/pre-scoring/example-boundary-freeze.yml
```

That validator rechecks the approval-relevant current bytes, validates the
freeze contract, reconstructs the only permitted frozen artifact from the
approved ledger, and requires exact equality. The result reports the approval
ID, approval SHA-256, and freeze SHA-256 together. A fully reviewed
zero-accepted ledger produces a valid frozen artifact with `records: []`; it
does not fabricate an adventure or successor.

## Controlled rebind

If the selected base AMC or source provenance changes before import, first generate a fresh boundary dossier against the new authoritative state.

Then:

```bash
bin/af-boundary-editorial rebind \
  audits/pre-scoring/example-boundary-editorial \
  --dossier audits/pre-scoring/example-boundary-dossier-new \
  --output audits/pre-scoring/example-boundary-editorial-rebound \
  --reason "Rebind to newly adopted catalog head"
```

Rebind creates a **new** bundle and never edits the old one.

It preserves `editorial_decisions.yml` byte-for-byte only when:

- the ordered registered Markdown SHA-256 set is unchanged; and
- segmented source page ranges, when present, are unchanged.

The registry SHA may change because unrelated registry state changed; the new exact registry provenance is recorded in the new context.

A canonical source-ID correction additionally requires:

```bash
--allow-source-id-change
```

Even with that flag, the Markdown content/range fingerprint must still match.

Every rebind appends an audit entry recording the reason and the old/new dossier, source, registry, and base-AMC bindings. Rebind never carries human approval. The rebound ledger must be reviewed again before import.

If the registered Markdown bytes or segmented page ranges changed, automatic rebind is refused. Re-run editorial review against the changed source instead of assuming old decisions remain valid.

## Ownership boundary

Software owns:

- exact dossier/source/base provenance;
- stable ledger structure and validation;
- completeness checks;
- parent/merge referential integrity;
- split and structured review-evidence referential integrity;
- deterministic, read-only ambiguity-first and complete-set rendering;
- rebind safety;
- deterministic translation of accepted candidates into the existing freeze schema; and
- final mechanical freeze validation.

David + frontier reasoning own:

- candidate discovery;
- adventure/non-adventure judgment;
- canonical title;
- printed-page boundaries;
- parent/child identity;
- optional source-established levels;
- acceptance/rejection/merge/split/hold rationale; and
- final human approval.

This preserves the existing AdventureFinder architecture: the new handoff is an editorial ledger in front of `af-boundary-freeze/v0.1`, not a replacement for that downstream contract.

## Approval-to-freeze consumer contract

`BoundaryEditorial.freeze_approved!` consumes
`af-boundary-editorial-approval/v0.1` through
`BoundaryEditorial.validate_approval!`, then composes the independently
validated draft/import/freeze seams. `validate_approved_freeze!` is the public
verification boundary for later consumers. Neither method trusts cached
approval fields, treats frontier recommendation as approval, or assigns review
authority to deterministic code. An untouched empty ledger, pending/held row,
stale record, incompatible artifact, or malformed/unknown schema fails closed.
