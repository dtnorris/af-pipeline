# Library Ingest Runbook

Status: **current operator guidance plus explicitly marked future seams**

Purpose: take one newly owned adventure-bearing TTRPG book from physical or
digital source material to a safely defined, scoring-ready set of Adventure
IDs—without relying on old chat conversations.

The source/boundary stages reach a verified staged successor for canonical
staged-scoring V2, without intermediate catalog adoption. The downstream summary
distinguishes standing-directive ingestion from individually reviewed manual and
historical V1 paths; each remains governed by its owning public contracts.

Set `AF_PROJECT_ROOT` to the actual parent of the component checkouts before
using workspace-relative examples below.

## Status vocabulary

| Label | Interpretation |
| --- | --- |
| **Current** | An implemented tool or established manual operation exists |
| **Editorial/manual** | David + frontier reasoning owns the semantic decision |
| **Future deterministic seam** | A narrow software handoff should exist, but does not yet |
| **Not yet implemented** | No command in `af-data-pipeline` may be assumed |

If a step is marked future, do not invent a command for it.

## Non-negotiable rules

- Keep copyrighted source content private.
- Treat the physical edition's printed pagination as authoritative when that is
  the chosen library edition.
- Preserve PDF-page and printed-page evidence; they are different coordinate
  systems.
- Phase 1 favors high recall. Embedded material is not disqualified merely
  because it appears inside a larger authored adventure or campaign.
- Semantic judgments belong to David + frontier reasoning.
- Repetitive copying, hashing, validation, ID allocation, and workbook mutation
  belong in deterministic software.
- Do not let frontier output assign the next Adventure IDs.
- Do not mutate a source AMC in place.
- Do not fill scoring fields before they have been assessed.
- Fail closed on ambiguity, conflict, missing provenance, or mismatched hashes.
- Preserve authoritative artifacts instead of maintaining duplicate status
  lists.
- Do not infer a base AMC by filename ordering. For new, not-yet-frozen ingest
  work, resolve the shared `catalog_head` role; after an operation records an
  exact base AMC, keep using that frozen artifact for replay/resume.
- A chat table is working material, not durable pipeline state.

## At-a-glance operator checklist

1. Identify the exact owned edition and decide its pagination authority.
2. If needed, assemble photographed pages with `image-to-pdf-converter` and
   inspect every page.
3. Convert the PDF with `pdf-to-llm-md-converter` and validate page markers and
   printed-page mapping.
4. Place the validated Markdown in the private
   `md-for-llm-book-content` corpus under a stable canonical filename.
5. Ensure the source has one canonical identity and is resolvable by current
   scoring tooling.
6. Run a high-recall Phase 1 candidate-boundary harvest.
7. Run Phase 1b / Phase 2 identity, nesting, title, and pagination review.
8. For a new workstream, resolve `catalog_head`, then freeze the accepted
   decisions durably with that exact base-AMC filename and hash.
9. For canonical V2, stage an operation-bound successor AMC, deriving Adventure
   IDs from the frozen explicit base workbook and explicit version authority.
10. Verify that only approved rows/metadata changed and unassessed fields remain
    blank.
11. Verify the staged lineage; do not adopt it into `catalog_head` to enable
    scoring. The manual adoption alternative is labeled in Stage 8.
12. Use attributed staged-scoring intent and AFW qualified selection to freeze
    the workload, then the authorized local coordinator/WLO execution and AFW
    evidence binding. Apply eligible scores under the standing directive, prepare
    the final package and obtain exact final promotion approval (downstream below).

The remainder of this document makes every step's inputs and PASS condition
explicit.

## Stage 1 — owned physical source to canonical PDF

**Status:** Current deterministic transformation in `image-to-pdf-converter`,
with manual physical capture and QA.

**Start with:** The complete owned physical book, an ordered set of top-level
`.jpg` / `.jpeg` photographs of it, and a clear statement of which physical
edition is being cataloged.

**Owner:** `image-to-pdf-converter` owns deterministic photograph discovery,
natural filename ordering, EXIF orientation handling, conservative cropping,
common-canvas normalization, QA reporting, and image-only PDF assembly. David
owns physical-edition selection, capture completeness, intended page order, and
visual QA.

**Current operation or command:** Follow the `image-to-pdf-converter`
repository's current root README for setup and supported options. The ordinary
conversion entry point is:

```bash
cd "$AF_PROJECT_ROOT/image-to-pdf-converter"
source .venv/bin/activate
bin/book-photo-to-pdf /path/to/book-photos
```

The default build writes the input manifest, processed page images,
`processing-report.csv`, and the assembled PDF under the input directory's
`build/` directory. Use `--diagnostics` when page-edge/crop review needs visual
evidence. Numeric filename gaps are warnings for human review, not proof that a
page is missing or that the capture is otherwise complete.

**Semantic judgment:** Decide which edition is authoritative and whether the
physical copy's printed pagination should control AMC page references. Confirm
that the photographed set is complete, that natural filename order matches the
physical book, and that cropping preserves all content and page-number evidence.

**PASS:**

- `input-manifest.txt` matches the intended source-photo order;
- any numeric filename-gap warning is reviewed and explained;
- no physical page is missing or duplicated;
- suspicious or low-confidence crops are visually reviewed;
- every assembled PDF page is in the intended order and safely cropped;
- text, tables, maps, headings, and page numbers are readable;
- page-number evidence is preserved; and
- the PDF represents exactly one identified edition.

**Durable artifact:** The canonical owned-source PDF plus its
`input-manifest.txt` and `processing-report.csv`; retain diagnostics when they
were needed to resolve a QA question.

**If failure or ambiguity:** Stop and recapture, correct the source-photo set or
filename order, or rerun the converter with supported diagnostic/output options.
Record uncertainty about pagination instead of “fixing” it by guessing.

**Never guess or bypass:** Missing pages, source-photo order, unreadable page
numbers, edition identity, or crop/completeness warnings.

## Stage 2 — canonical PDF to page-addressable Markdown

**Status:** Current deterministic transformation in
`pdf-to-llm-md-converter`.

**Start with:** The canonical PDF that passed Stage 1, or an already-owned
digital PDF whose completeness and edition identity have been confirmed.

**Owner:** `pdf-to-llm-md-converter` owns conversion, page-addressability,
printed-page detection/mapping where possible, OCR/page-number fallback
behavior, and conversion validation.

**Current operation or command:** Follow that repository's current root README
for the exact invocation. This repository does not duplicate a command that may
change in the converter. The established output model is one page-addressable
Markdown section per PDF page, including markers such as:

```html
<!-- PDF Page N -->
<!-- Printed Page N -->
```

Printed-page markers may be absent or require review where detection cannot
establish them safely.

**Semantic judgment:** Frontier reasoning should investigate exceptions:
ambiguous printed-page sequences, inserts, front matter, maps, OCR failures, or
other places where deterministic detection reports uncertainty. It should not
manually reconstruct every ordinary page.

**PASS:**

- every PDF page is represented exactly once and in order;
- `<!-- PDF Page N -->` markers are complete and monotonic;
- printed-page mappings are present where supportable and checked at multiple
  locations, including transitions;
- expected headings and content are readable;
- validation reports no unexplained errors; and
- OCR fallback did not silently replace uncertainty with invented text or page
  numbers.

**Durable artifact:** One validated `*_LLM_Edition.md`-style canonical
Markdown file plus any converter validation artifact the current converter
emits.

**If failure or ambiguity:** Keep the PDF authoritative, inspect the reported
exception, correct the source/conversion through the converter's supported
workflow, and rerun validation. If mapping remains uncertain, record it
explicitly for editorial review.

**Never guess or bypass:** A missing PDF marker, a printed-page offset, OCR
content, or a validation failure.

## Stage 3 — canonical private Markdown source

**Status:** Current corpus operation with deterministic source intake and
explicit single-file source registration.

**Start with:** The validated page-addressable Markdown and its identified
physical/digital edition.

**Owner:** The private `md-for-llm-book-content` repository owns the canonical
copyright-sensitive Markdown corpus and `source_registry.yml`.
`af-data-pipeline` owns deterministic intake evidence and the fail-closed
single-file registry append. David/frontier review owns canonical library
identity.

**Current operation or command:** Give the file a stable canonical filename,
place it in the private corpus according to that repository's current
conventions, then run source intake instead of ad hoc `grep` passes:

For Markdown produced by the current `pdf-to-llm-md-converter`, pass its
ephemeral conversion receipt when it is still available:

```bash
bin/af-source-intake \
  "$AF_PROJECT_ROOT/md-for-llm-book-content/Example_LLM_Edition.md" \
  --source-root "$SOURCE_ROOT" \
  --output /tmp/adventurefinder-example-source-intake \
  --conversion-receipt /path/to/Example_LLM_Edition.conversion-receipt.json
```

When a routed ingest state has already received every required human choice,
the same existing workflow can execute its clerical PASS transitions
automatically:

```bash
bin/af-ingest-next /path/to/ARTIFACT \
  --auto \
  [the same explicit human-supplied options required by that state]
```

Auto mode is deliberately narrower than "run the whole ingest." It advances
only through the explicit deterministic allowlist documented in the root
README, emits `AUTO: running ...` / `AUTO: PASS ...` feedback for every command,
checks that the expected durable continuation artifact was actually produced,
and then re-routes that artifact through `af-ingest-next`. It stops normally at
source identity, frontier/editorial work, explicit approval, successor
publisher/version selection, catalog adoption, production batch selection, or
any other non-allowlisted state. A nonzero child command or a missing expected
artifact fails closed.

Plain `af-ingest-next` remains read-only and prints commands without executing
them. `--auto` cannot be combined with `--json`.

`--conversion-receipt` is optional for backward compatibility with older and
non-PDF-derived corpus sources. If it is omitted, source intake continues but
emits a warning and records that converter acceptance was not mechanically
verified.

If a receipt is supplied, it is binding. Source intake requires the current
`pdf-to-llm-md/conversion-receipt/v0.1` schema, verifies that the receipt's
output SHA-256 matches the canonical Markdown bytes being inspected, and
requires `downstream_ready: true` with state `ready` or
`ready_with_exceptions`. A failed, stale, corrupt, or unsupported supplied
receipt stops intake rather than degrading to a warning.

The full receipt remains converter/build workflow evidence and does not need to
be committed with the canonical source. The durable source-intake report keeps
the receipt hash, verified state, and any reviewed page-exception page/reason
summary needed to explain the accepted handoff.

The intake report binds the Markdown and registry by SHA-256 and reports
heading structure, PDF/printed marker continuity, paired marker deltas,
publication/identity evidence lines, conversion-quality flags, and existing
registry references. It does not infer a source identity or mutate either
input.

**Semantic judgment:** Decide the canonical source title/edition identity. This
is library identity, not a scoring rubric or model choice.

**PASS:**

- the canonical Markdown is in the private corpus;
- its filename and source identity are stable and unambiguous;
- the exact bytes have a SHA-256 available for downstream provenance;
- the file remains private; and
- no public artifact reproduces copyrighted source content.

**Durable artifact:** The version-controlled canonical Markdown file and its
commit/hash provenance.

**If failure or ambiguity:** Stop before boundary review if multiple files
could claim the same identity, if the edition is unclear, or if the file is not
safely private.

**Never guess or bypass:** Canonical source identity, edition, filename,
privacy, or content hash.

### Canonical source registration

The principle is:

> Canonical source identity is library data, not scoring semantics.

**Current:** `md-for-llm-book-content/source_registry.yml` is the
version-controlled authority for explicit source mappings, and current
`af-scorer` consumes it directly. When a source identity has no
explicit registry entry, the scorer retains its existing unique
normalized-filename fallback.

**Current operation or command:** For a new ordinary one-file source, register
the exact editorially chosen identity explicitly:

```bash
bin/af-source-register \
  "$AF_PROJECT_ROOT/md-for-llm-book-content/Example_LLM_Edition.md" \
  --source-root "$SOURCE_ROOT" \
  --source-id "Exact Canonical Source Identity"
```

`af-source-register` preserves the existing registry text and appends one
explicit single-file mapping. For the first source, the plain top-level
`sources: {}` header is opened into a block mapping, preserving surrounding
spacing, comments and blank lines, including when the final newline is absent.
This narrow insertion does not reserialize YAML; other serialization layouts
remain subject to candidate validation and may be refused without publication.
Registration is storage, not conversion QA or editorial approval.
It refuses an existing source ID, a Markdown file
already referenced by another source, an invalid registry, an unsigned
`page_marker_offset`, or a registry that changes during the operation. It does
not infer source identity, segments, or offsets.

Only pass `--page-marker-offset +N` or `--page-marker-offset -N` when that exact
mapping is independently intended. The source-intake report's observed
printed-minus-PDF delta is evidence, not an automatic registry offset.

Segmented sources remain an explicit manual registry case in this pass: define
their segment ranges only from established source/catalog coordinates and let
the existing registry validator fail closed on invalid ranges or overlap.

### Approval-required registration and correction

Use the guarded source operation when an operator decision is required to place
converter output and register it together. Select the supported owner explicitly
with `AF_SOURCE_MD_ROOT` set to its absolute checkout path. Ordinary
pre-editorial registration continues to use the command above.

Supply an `af-source-operation-intent/v0.1` JSON object with these fields.

| Fields | Binding |
| --- | --- |
| `schema_version`, `operation_id`, `revision` | The schema above, the caller's explicit operation ID and a nonnegative integer revision. |
| `library_id`, `source_root` | The selected library and the absolute physical store directory. |
| `action`, `source_id`, `edition` | `register` or `correct` and the explicit new source identity and edition. A correction requires `prior_source_id` from the selected prior registry. |
| `candidate_path`, `conversion_receipt_path` | Absolute physical file paths. Pipeline checks the receipt's output path, exact candidate hash and downstream QA state. |
| `prior_registry`, `registry`, `destination` | Store-relative filenames for the retained v0.1 registry, the new `.yml` registry and the explicit Markdown destination. Parents must already exist. |
| `page_marker_offset` | Optional explicitly signed offset for the new single-file mapping. |
| `prior_freeze_path`, `base_amc_path` | For a correction with a selected prior freeze, supply both absolute paths. Pipeline validates that freeze against its original registry, source and base AMC. |

After reviewing the intent, QA and relevant editorial context, record the
decision at an operator-controlled path. Supply `declined` instead of
`approved` to record a refusal.

```bash
bin/af-source-register decide INTENT.json --decision DECISION.json \
  --decided-by "Reviewer Name" --disposition approved
bin/af-source-register apply-approved INTENT.json --decision DECISION.json
```

The decision binds the operator, the original intent bytes, owner code,
candidate bytes, conversion receipt and exact prior store and freeze inputs.
Operation authority comes from the selected operator-controlled decision file.
Keep decision files in a location the operator controls throughout execution and
retry. Conversion readiness and prior boundary approval are supporting context.
The source decision authorizes only the declared store operation. Continue
through the existing pipeline intake, boundary review and QA gates for the new
source as applicable.

The result supplies the owner, decision, exact Markdown and exact registry
bindings. Select the returned registry explicitly for the new generation.
Keep earlier registry and Markdown paths available to their frozen consumers.
The corrected source has its own identity and the new registry carries all
previous mappings. Keep guarded generations bound to frozen consumers out of
in-place pre-editorial registration. Evidence remains with the evidence owner.

For a cold retry, rerun the same command with the same intent, decision and
owner. The owner verifies the durable operation record and resumes any missing
publication. A completed replay returns the same bindings with `reused: true`.
Source-root serialization covers cooperating writers selecting the same
physical source root and this owner implementation. Use a store with controlled
writers, and investigate refused bindings before retrying.

**PASS today:** The source has one canonical identity, the registry has one
validated mapping to the intended Markdown file/range, and a repeat intake
reports that file as registered to exactly that source ID. After successor
Adventure IDs exist, scorer preflight remains the downstream source-resolution
check before production inference.

**On failure:** Fix the canonical source identity or registry data before
scoring. Do not substitute a similarly named book or an arbitrary filesystem
match.

## Stage 4 — Phase 1 boundary evidence and candidate harvest

**Status:** Current deterministic evidence preparation plus editorial/manual
candidate harvest.

**Start with:** The complete validated canonical Markdown, page mapping, source
identity, and enough context to see heading/nesting structure across the whole
adventure-bearing span.

**Owner:** `af-data-pipeline` owns deterministic evidence preparation. David +
frontier reasoning own candidate identification and every boundary decision.

**Current operation or command:** Generate the pre-Phase-1 dossier from the
registered source and explicit base AMC:

```bash
bin/af-boundary-dossier \
  --source-root "$SOURCE_ROOT" \
  --source-id "Exact Canonical Source Identity" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --output audits/pre-scoring/example-boundary-dossier
```

For a brand-new workstream with no base already frozen, obtain the exact path
first with `bin/af-project-state resolve catalog_head` and pass that returned path
to `--amc`. Once the dossier or boundary-freeze artifact records the base AMC,
that exact artifact outranks the moving role for replay/resume even if
`catalog_head` later advances.

Then use the complete dossier plus canonical source for the high-recall
candidate harvest. The dossier replaces repetitive source navigation and
AMC-precedent gathering; it does not output accepted candidates.

At minimum, working notes should give each candidate a stable temporary key,
provisional title, printed-page span, optional PDF-page span, apparent parent
context, evidence for playability, and open questions.

**Semantic judgment:** Determine whether each section is plausibly a playable
unit. The standard at this phase is “plausible enough to inspect,” not “already
proved canonical.”

> Phase 1 should identify plausible playable units with high recall. It should
> not prematurely collapse embedded material merely because it sits inside a
> larger authored adventure or campaign.

Signals may include adventure/scenario/mission/quest language, actionable
premise, playable situation, level guidance, start/conclusion signals, or a
coherent runnable sequence. None is individually dispositive.

**PASS:**

- the entire relevant source span was reviewed;
- obvious parent material and plausible embedded children are represented;
- borderline scenario/location/framework candidates are retained and labeled
  for Phase 1b;
- page evidence is recorded; and
- exclusions are not based only on embedding or short length.

**Durable artifact:** `boundary_dossier.json` plus `boundary_dossier.md`, bound
to exact source-registry/Markdown/base-AMC bytes, together with the editorial
candidate-boundary working set that proceeds into Phase 1b / Phase 2. The
accepted result later crosses into the structured freeze artifact.

**If failure or ambiguity:** Increase recall, add the candidate, and carry the
question forward. If page addressing is unclear, return to Stage 2 instead of
approximating.

**Never guess or bypass:** Completeness of the review span, page boundaries, or
whether a borderline unit was actually inspected.

### Evidence preparation, not boundary automation

The current deterministic dossier extracts:

- literal Markdown heading hierarchy plus observed-only navigation signals from source contents tables and plain-text structural labels;
- explicit PDF/printed-page mapping evidence, leaving unmapped pages unknown rather than carrying a prior printed page forward;
- adventure/scenario/mission/quest language;
- level guidance;
- start and conclusion signals; and
- AMC short-adventure precedent and deterministic title collisions.

Its output is evidence for frontier review. Contents entries and plain-text
structural labels are navigation signals, not synthesized Markdown headings.
Source TOC page targets remain source claims, not verified page mappings. The
dossier must not declare what counts as an adventure, infer parent/child
identity, fill missing pagination, or assign Adventure IDs.

## Stage 5 — Phase 1b / Phase 2 identity and nesting review

**Status:** Editorial/manual.

**Start with:** The complete Phase 1 candidate set, canonical source, page
mapping, and all boundary questions. Do not silently begin from a pruned chat
summary.

**Owner:** David + frontier reasoning.

**Current operation or command:** Review every candidate and freeze the accepted
identity/nesting set. There is no `af-data` Phase 2 command.

The normal routed `af-boundary-editorial init` handoff makes the frontier step
operator-visible rather than leaving it implicit. It prints the exact canonical
Markdown, boundary dossier, editorial review, and decision-ledger files to
attach to a normal ChatGPT conversation; emits the source-grounded Phase
1 / Phase 1b / Phase 2 prompt; identifies the exact ledger to review/save; and
prints the `af-ingest-next` resume command to run only after that reviewed
ledger is in place. The same prompt is embedded durably in
`editorial_review.md`.

**Semantic judgment:** Resolve questions such as:

- genuine standalone adventure?
- embedded but independently runnable adventure?
- reusable location or campaign-support framework rather than adventure?
- larger campaign parent?
- child/parent relationship?
- canonical title?
- canonical printed-page boundaries?
- Level Start / Level End explicitly established by the source?

This stage may collapse, split, accept, or reject Phase 1 candidates, but each
decision should remain traceable to evidence.

**PASS:**

- every Phase 1 candidate has an explicit disposition;
- accepted records have canonical titles and printed-page boundaries;
- parent/child relationships are restrained and internally consistent;
- locations/support frameworks are not mislabeled merely because they are rich;
- independently runnable embedded units are not lost merely because they have a
  parent;
- levels are included only when editorially established; and
- unresolved questions are held, not papered over.

**Durable artifact:** Populate the `records` section of an initialized
`af-boundary-freeze/v0.1` handoff with the reviewed accepted set and rationales.
Do not alter the software-owned source/base provenance or promote the artifact
to `state: frozen` until David approves the complete Phase 2 result.

**If failure or ambiguity:** Hold the candidate, revisit the source evidence,
or leave the relevant optional field unset. Do not allocate an Adventure ID to
force closure.

**Never guess or bypass:** Standalone status, parentage, canonical title,
printed-page boundaries, or levels.

## Stage 6 — freeze the editorial boundary decision

**Status:** Current deterministic frontier-review handoff.

**Start with:** The canonical Markdown corpus, its `source_registry.yml`, one
exact canonical source identity, and the explicitly selected base AMC that a
future successor would extend.

**Owner:** `af-data-pipeline` owns deterministic initialization and validation.
David + frontier reasoning own every semantic boundary/identity decision, and
David owns final approval.

**Current operation or command:** Initialize a draft handoff before frontier
review:

```bash
bin/af-data boundary-freeze-init \
  --source-root "$SOURCE_ROOT" \
  --source-id "Example Source" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --output audits/pre-scoring/example-boundary-freeze.yml
```

The initializer computes and records the source-registry SHA-256, every Markdown
file referenced by that canonical source identity plus its SHA-256, and the
explicit base-AMC filename/SHA-256. It refuses to overwrite an existing handoff
and emits `state: draft`, blank approval, and an empty record set. It never
assigns an Adventure ID.

Give that initialized YAML and the relevant canonical source content to the
frontier-model session. Phase 1 / Phase 1b / Phase 2 populate only the editorial
record set; do not edit software-owned provenance fields. After David approves
the complete set, fill approval, set every accepted record to `state: frozen`,
and set the top-level state to `frozen`.

Then validate the returned handoff:

```bash
bin/af-data boundary-freeze-validate \
  audits/pre-scoring/example-boundary-freeze.yml \
  --source-root "$SOURCE_ROOT" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx"
```

See [BOUNDARY_FREEZE_V0.1.md](BOUNDARY_FREEZE_V0.1.md) for the exact frontier
handoff contract and record shape.

**Semantic judgment:** Approval, canonical titles, page bounds, restrained
nesting, optional established levels, and concise rationales remain David +
frontier responsibilities. Software only binds and validates them.

**PASS:** The top-level and record states are frozen; approval is explicit;
required fields are complete; keys are unique; spans, local parent references,
and optional levels are coherent; segmented-source spans resolve within one
registered segment; source-registry/Markdown/base-AMC hashes match exact files;
and no new Adventure ID appears in a record.

**Durable artifact:** A validated `af-boundary-freeze/v0.1` YAML file whose
software-owned provenance is bound to exact source and base-AMC bytes.

**If failure or ambiguity:** Refuse the freeze. Return to source QA or Phase 2.
Do not repair a failed hash by hand or add an Adventure ID to force closure.

**Never guess or bypass:** Hashes, approval state, base AMC, parent references,
page spans, or Adventure IDs.

### Implemented `af-boundary-freeze/v0.1` contract

The initialized source section binds the actual registry plus every Markdown
artifact referenced by the selected canonical source identity. This supports
both ordinary one-file sources and real segmented sources:

```yaml
schema_version: af-boundary-freeze/v0.1
state: frozen
source:
  canonical_source_id: Example Source
  registry_filename: source_registry.yml
  registry_sha256: "<64 lowercase hex characters>"
  markdown_files:
    - filename: example-source.md
      sha256: "<64 lowercase hex characters>"
base_amc:
  filename: 5e_Adventure_Master_Catalog_X.Y.xlsx
  sha256: "<64 lowercase hex characters>"
approval:
  approved_by: Example reviewer
  approved_at: "2026-01-01"
records:
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
    editorial_rationale: Short provenance for the accepted decision.
    state: frozen
```

The v0.1 validator requires a concrete positive printed-page span for every
frozen record. `pdf_pages` and `levels` are optional. Parentage is represented
only by an optional `parent_key` or `parent_adventure_id`; a record may set at
most one. Local parent keys must resolve to another frozen record, self-parenting
and cycles are rejected, and nesting depth is otherwise unrestricted. Parent,
child, and root status are derived from those edges rather than stored
separately. Existing `parent_adventure_id` values are syntax-checked here;
canonical AMC row/ID reconciliation remains the responsibility of the later
freeze-to-successor-AMC applicator.

The records do **not** contain newly assigned Adventure IDs:

> Frontier GPT must not assign the next Adventure IDs.

## Stage 7 — frozen boundaries to a staged or manual successor AMC

**Status:** Current.

**Start with:** A validated frozen boundary artifact, the exact canonical
Markdown, and one explicit base AMC whose identity and SHA-256 match the freeze.

**Owner:** `af-data-pipeline` software owns validation, ID derivation,
row creation, workbook integrity, and reporting. David owns acceptance of the
new workbook.

### Canonical V2 — operation-bound staging

Use [verified staged successor](VERIFIED_STAGED_SUCCESSOR_V0.1.md) after exact
boundary approval and AdventureFinder's explicit successor-version authorization:

```bash
bin/af-data boundary-freeze-stage APPROVED_FREEZE.yml \
  --operation-input OPERATION_ROUTING_INPUT.json \
  --successor-authority SUCCESSOR_VERSION_AUTHORIZATION.json \
  --source-root "$SOURCE_ROOT" \
  --catalog-root "$AF_PROJECT_ROOT/af-xlsx-data-sources"
```

Both JSON inputs are AdventureFinder-owned public projections, binding the
operation, source/publisher, original base and explicit successor version. Do not
invent them from private operation state or infer a version. Pipeline revalidates
the approved freeze and deterministic transformation, then retains the exact
`staged-5e_Adventure_Master_Catalog_VERSION.xlsx`, apply report and staging receipt.
`VERIFIED_STAGED_SUCCESSOR` changes no shared role and does not itself authorize
scoring. Preserve its authoritative filename and historical project-state evidence;
later scoring authority consumes these exact bytes. A verified zero-record freeze
returns `NO_SUCCESSOR_NEEDED`, without a successor or scoring workload.

### Empty mechanical workbook representation

The existing Stage 7 allocator also supports a genuinely empty split catalog.
This is a representation/construction contract for fixtures and future XL/AF
initialization, not library setup, a real Git baseline or an adoption procedure.
Approval and operation/version projections remain required for staged successors
under [the staged-successor contract](VERIFIED_STAGED_SUCCESSOR_V0.1.md).
`BoundaryFreezeApply` is the sole allocator; `AmcApply` only applies accepted
values to known IDs. No scoring or matcher qualification follows from emptiness.

`test/support/empty_catalog_fixture.rb` constructs a readable XLSX from the
existing compatibility helpers without any private workbook, identities,
assessments or calibration references. Its reusable bounded shape is:

- The package contains content types, package/workbook relationships, workbook,
  styles and three worksheets in order: `Adventure Catalog`, `AMC >100pg`,
  `Current Books`. Catalog row 1 contains the unique identity and assessment
  headers in `CompatibilityAmcFixture::HEADERS`; the large sheet also has
  `>99 pgs`. Existing sheet identities and all unrelated parts remain intact.
- Ordinary capacity is rows 2–5; split-large capacity is rows 3–6. Each slot has
  explicit blank cells for every header. Large row 2 is reserved: B2 retains
  `COUNTA(A3:A1000)` with numeric zero cache. Allocation starts after the last
  canonical record, or at these starting rows when empty; occupied/formula
  targets and exhausted capacity refuse rather than scanning ahead or growing.
- Current Books B2/G2 are numeric zero totals, C2/H2 numeric zero identity
  counts. C4/H4 each hold exactly one `>100 page Adventures` summary label;
  B4/G4 reference `'AMC >100pg'!B2`, and E4/I4 reference `$B$2`/`$G$2`.
  Ordinary source/publisher identities and D4 are blank. Rows 5–6 provide two
  source blocks A:E and publisher blocks F:I. Each block must be entirely blank
  before insertion; formulas with blank or zero caches are still occupied.
- First insertion uses its own explicit blank target cells as the style
  template when no ordinary source/publisher row exists. Every cell in that
  block must name a valid `cellXfs` index. The helper declares text style 3
  (number format 49), integer style 1 (format 1), and ratio style 2 (format 10),
  all based on style 0. No special-summary style or fabricated identity is
  borrowed. Existing styles, base styles and number formats are preserved.
- A4/F4 use `IF($B$2=0,0,B4/$B$2)` and
  `IF($G$2=0,0,G4/$G$2)`. New source/publisher ratios use the equivalent exact
  guard at their row. Empty catalogs require this guard; populated catalogs
  accept the legacy literal ratio or this exact guard (under existing formula
  normalization), checking the cache against zero or the actual nonzero ratio.
  Historical populated ratio formulas are
  retained without a rewrite. This static check does not recalculate Excel.
  Split totals sum ordinary counts plus the large summary once; the helper
  binds A2/B2/F2/G2 to rows 3:6. Identity counts exclude the special label.

For a disposable fixture only, from the pipeline root, choose an absent path:

```bash
bundle exec ruby -Ilib:test -rjson \
  -raf_data_pipeline/amc_compatibility_check -rsupport/empty_catalog_fixture \
  -e 'path = Object.new.extend(EmptyCatalogFixture).write_empty_catalog(ARGV.fetch(0)); puts JSON.pretty_generate(AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: path))' \
  /ABSOLUTE/DISPOSABLE/5e_Adventure_Master_Catalog_0.1.xlsx
```

Measure the resulting filename, numeric version, SHA-256 and positive byte size
when binding `PROJECT_STATE` v0.2. All three independent roles may deliberately
point at that same empty artifact; the closed role schema is unchanged. Explicit
and frozen inputs retain precedence. Construction/staging never changes those
roles or original bytes. A second explicit approved input can construct from a
version-named mechanical successor without treating it as accepted; stage replay
verifies exact retained evidence and refuses partial/conflicting publications.
Live adoption still requires its existing Git/provenance and approval gates.

Public owner extraction, closure of the weaker raw promotion route, initial real
Git baseline, AF composition, migration and release remain separate decisions.

### Manual compatibility — raw successor application

The existing direct apply path remains valid for an explicitly chosen manual
workflow. It is not the operation-bound V2 stage:

```bash
bin/af-data boundary-freeze-apply FREEZE.yml \
  --source-root "$SOURCE_ROOT" \
  --amc "$CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx" \
  --publisher "Exact Book Publisher" \
  --successor-version X.Z \
  --amc-dir "$AF_PROJECT_ROOT/af-xlsx-data-sources"
```

`--publisher` is required because `Book Publisher` is a canonical AMC column but
is not part of `af-boundary-freeze/v0.1` or the source registry. For a source
already present in the base AMC, the supplied value must match the existing
publisher. The command also maintains the derived `Current Books` source and
publisher summaries. Current `amc-apply` remains a separate downstream command
for accepted **scoring values in existing Adventure-ID rows**.

The successor version remains an explicit human/editorial choice. The command
derives the workbook filename under `--amc-dir` and the standard integrity
report filename beside the freeze artifact under `audits/pre-scoring/`. It
refuses to overwrite either destination and never modifies the base AMC.
Existing `--output NEW.xlsx [--report REPORT.json]` invocations remain supported;
`--report` may also override the derived report path in successor mode.

**Semantic judgment:** None during the transformation. If a new semantic
decision is needed, stop and revise/refreeze the input.

**Deterministic transformation:**

```text
frozen boundary artifact
        ↓
validate against canonical source + explicit base AMC
        ↓
derive next available ADV IDs
        ↓
write NEW AMC workbook
        ↓
integrity report
```

**PASS:**

- input source and base-AMC hashes match;
- every frozen record maps to exactly one new row;
- next Adventure IDs are derived deterministically and are unique;
- established identity, pagination, relationship, and optional level metadata
  are copied exactly;
- all unassessed scoring fields are blank;
- formulas, styles, workbook structure, and unrelated cells are preserved;
- the base AMC bytes are unchanged;
- the successor filename/version is new; and
- an integrity report proves the exact row/cell changes.

**Durable artifacts:** A new successor AMC workbook in `af-xlsx-data-sources`
plus the frozen handoff and machine-readable integrity report under
`af-data-pipeline/audits/pre-scoring/`. The report binds the freeze, source,
base workbook, output workbook, assigned IDs, and exact changes by SHA-256.

**If failure or ambiguity:** Produce no successor workbook. Resolve conflicts in
the source artifact or against the explicit base AMC and rerun from unchanged
inputs.

**Never guess or bypass:** The next ID, a duplicate title's identity, base AMC,
parent resolution, workbook target row, blank-field expectation, or any hash.

## Stage 8 — choose the staged-scoring or manual continuation

### Canonical V2 — authorize scoring against the immutable stage

Continue from the verified Stage 7 receipt through
[staged-scoring authority and binding](../contracts/staged-scoring/v0.1/README.md)
and AdventureFinder's
[start/resume contract](https://github.com/dtnorris/adventure-finder/blob/main/docs/CATALOG_INGEST_FRONT_DOOR_V0.1.md).
The attributed scoring choice, exact approved source/base/boundary lineage and
AFW's qualified selection authorize workload preparation against the staged
workbook. No intermediate `af-project-state adopt` or per-score ACCEPT is required.

AFW owns selected/deferred/refused accounting, qualified profiles/models/digests,
page/source eligibility, conditional Levels and zero-inference preflight. The
`af-staged-scoring-workload-binding/v0.2` binds the exact selected subset and AFW
selection, plus frozen plan/snapshot/index/generated artifacts. `ALL_DEFERRED`
retains reasoned selection evidence but no runnable workload; refused inputs do
not count as legitimate deferrals. Do not change a frozen base or regenerate IDs
to evade a concurrency refusal.

**PASS:** Exact approved lineage and staging evidence validate, AFW verifies the
qualified selection and frozen binding, and the owning authority permits reuse.
The stage remains immutable; unassessed fields remain blank until authorized
assessment/application. Shared catalog adoption belongs only to the later exact
final decision. See the canonical downstream sequence below.

### Manual compatibility — accept an unscored successor before scoring

**Status:** Current editorial acceptance; source-resolution check uses current
scoring tooling.

**Start with:** The proposed successor AMC and integrity evidence from Stage 7,
plus the canonical registered source.

**Owner:** David accepts the catalog mutation. Deterministic checks support the
decision.

**Current operation or command:** Inspect the Stage 7 integrity evidence, then
run the reviewed catalog-head adoption seam:

```bash
cd "$AF_PROJECT_ROOT/af-data-pipeline"
bin/af-project-state adopt /path/to/5e_Adventure_Master_Catalog_X.Z.xlsx
```

The command accepts an explicitly selected workbook outside the catalog
repository as well as one already inside it. A canonical filename supplies the
version; for an arbitrarily named `.xlsx`, provide `--version X.Z`. Before
asking for approval it shows the selected path, SHA-256, byte size, current and
candidate `catalog_head`, unchanged independent roles, and a deterministic
primary-`Adventure Catalog` review of added, removed, and changed Adventure IDs
and reviewed fields.

On approval it copies external bytes to the canonical versioned filename only
if doing so cannot overwrite a different existing artifact, then promotes only
`catalog_head`. It rechecks the selected bytes, manifest, repository HEAD, and
previous catalog-head identity after review so stale approval fails closed.
The command creates no Git commit and performs no push. Cross-consumer workbook
compatibility remains a separate gate rather than being implied by this
adoption review.

After adoption, verify source resolution without model inference:

```bash
bin/af-score --preflight ADV-XXXX
```

Run the preflight from a current `af-scorer` checkout configured
for the intended AMC and corpus.

**Semantic judgment:** Confirm that the frozen editorial decisions are the ones
intended, that the displayed catalog delta is expected, and that the successor
should become the shared `catalog_head`.

**PASS — scoring-ready means all are true:**

- canonical Adventure IDs exist;
- canonical source resolution is valid;
- accepted boundaries and IDs match the frozen decisions;
- the successor AMC is accepted;
- unassessed production fields are intentionally blank; and
- source/base/output provenance is intact.

**Durable artifact:** The accepted versioned AMC in
`af-xlsx-data-sources`, with its supporting frozen boundary handoff and
integrity report in `af-data-pipeline/audits/pre-scoring/`.

**If failure or ambiguity:** Do not create a production backlog. Return to the
responsible upstream stage.

**Never guess or bypass:** Source resolution, acceptance, a missing ID, or
whether blank scoring fields are intentional.

This is the end of the pre-scoring runbook.

---

## Downstream handoff — scoring and production-data promotion

### Production scoring — ownership for both workflows

**Status:** Current, outside this repository.

AFW owns frozen scoring intent and scoring-evidence receipts. WLO owns generic
execution; LOW owns local readiness. Remote capacity remains separately authorized
through its owner; canonical local ingestion implies no paid/provider execution
or fallback. The scoring utility owns prompts and scoring behavior. Follow each
owner's public runbook. No inference or execution control belongs in the pipeline.

### Canonical V2 — standing ingestion, final package, exact promotion

Follow the [canonical pipeline sequence](operator-runbook.md#canonical-v2--staged-scoring-under-the-standing-directive).
The clean-local three-decision target is admission of exact source/base and
scoring intent, exact boundary approval, then exact final promotion. Once local
execution is authorized, the existing coordinator automatically establishes exact
LOW capabilities and drives the frozen WLO workload. AFW then binds authoritative
successful evidence and publishes its complete workload manifest. Execution
failures, missing/ambiguous receipts and other unresolved evidence block release;
they are not terminal supported gaps.

Use the exact v0.2 release inputs with
`af-standing-bulk-score-release`, which validates the workload/ledger, applies
eligible standing-authorized values and finalizes accepted styling. Pending
eligible candidates need no individual ACCEPT. Authority precedence remains source
holds, individual human HOLD/REJECT/ACCEPT, independently valid authoritative
IG-16B records when supplied, then the standing directive. Explicit unsupported
scope and human/source terminal exceptions remain accounted gaps. Advisory-only
flags follow the active policy; hard or unknown-severity flags fail closed.

Standing authority is permission to apply, not human review or semantic-quality
acceptance. IG-16B separately requires exact passing IG-12B evidence and explicit
application authority. The current final package refuses nonzero IG-16B acceptance
without the separate application/control contract. Historical mechanical
acceptance is a separate category, zero for this path.

Prepare and validate the original final package with `frontier_result_path: null`
using [final release decision input](FINAL_RELEASE_PACKAGE_V0.1.md). Review its
exact candidate, accounting, terminal gaps and current-to-proposed catalog delta;
full scoring and promotion readiness are distinct. Optional `--preview` on the
standing release has no authority effect and introduces no mandatory review gate.
Only exact final approval and transaction-time revalidation may promote the
candidate to `catalog_head`. Git commit/push remain explicit operator actions.

Optional residual supplementation uses the existing
[frontier producer v0.2](FINAL_RELEASE_PACKAGE_V0.1.md#optional-frontier-producer-v02)
after retaining that original package. Supply explicit original package/input
locators, frozen rubric identity/path/hash/size and a newer successor version.
The structured packet/return addresses only blank original terminal
`unsupported_scope` targets, with source-linked reasons and explicit no-writes
for uncertainty. Independently validate its separately attributed
`frontier_manual` derived candidate/accounting and prepare a new package from
`RESULT_DIR/package-inputs.json`. No approval is inherited; explicit final
promotion is still required. Decline preserves the original candidate and
authorized gaps. This branch is optional, not another mandatory score decision.

### Manual individual review — local preparation

Use the AFW receipt returned by its public evidence-binding command:

```bash
bin/af-data prepare-review "$RECEIPT" --afw-root "$AFW_ROOT" \
  --review-dir "$REVIEW_DIR" --audit-dir "$AUDIT_DIR"
```

Set these variables to the exact receipt, selected AFW root and chosen stable
review/audit destinations. This verifies evidence and prepares/reuses a review
package with the existing human ledger. It does not accept a score or mutate
canonical data. Follow the [scoring-review operator runbook](operator-runbook.md)
for the explicitly labeled manual pending-decision and apply boundary.

The `production-review` command can inspect existing compatible packaged runs.

### Manual individual review — complete the durable scoring audit

**Status:** Current in `af-data-pipeline`.

```bash
bin/af-data editorial-audit-init \
  output/production-review \
  --audit-dir audits/production-batch
```

Edit only `editorial_decision` and `editorial_note` in the generated ledger.
Then validate:

```bash
bin/af-data editorial-audit-validate \
  audits/production-batch \
  --output output/production-batch-editorial-audit
```

PASS: every numeric candidate has an allowed decision, notes exist where
required, hashes and immutable fields match, no candidate remains pending, and
validation reports `Complete: true`.

### Manual individual review — apply accepted values to a new AMC

**Status:** Current in `af-data-pipeline`.

```bash
bin/af-data amc-apply \
  audits/production-batch \
  --amc /path/to/BASE.xlsx \
  --output /path/to/SUCCESSOR-applied.xlsx
```

PASS: the command exits zero, source bytes remain unchanged, the output and
report are new, conflicts/errors are zero, and post-write verification passes.

### Manual individual review — finalize accepted cell styling

**Status:** Current in `af-data-pipeline`.

```bash
bin/af-data amc-finalize \
  --amc /path/to/SUCCESSOR-applied.xlsx \
  --apply-report /path/to/SUCCESSOR-applied.amc-apply-report.json \
  --output /path/to/SUCCESSOR.xlsx \
  --expect-cells N
```

PASS: the exact applied-workbook hash matches the apply report; only authorized
red cells transition to the existing accepted light-blue style; the final
workbook/report are new; values, formulas, unrelated cells, and workbook
structure are unchanged.

For complete downstream semantics, return to the root README and current CLI
help.

## Failure routing

| Symptom | Return to |
| --- | --- |
| Missing/duplicate/unreadable photographed page | Stage 1 |
| Broken PDF markers, OCR, or printed-page mapping | Stage 2 |
| Ambiguous source filename/edition or privacy problem | Stage 3 |
| Plausible embedded unit omitted without review | Stage 4 |
| Unresolved adventure/location/framework or nesting question | Stage 5 |
| Missing approval, hash, key, or coherent parent reference | Stage 6 |
| ID collision, workbook conflict, unexpected cell/formula/style change | Stage 7 |
| Source does not resolve or staged/manual authority is invalid | Stage 8's chosen workflow |
| V2 execution/evidence is unresolved, incomplete, duplicated, or contradictory | WLO/AFW owner diagnostics; preserve the frozen workload and evidence |
| Historical packaged scoring evidence is malformed | `production-review` |
| Manual individual-review ledger is pending or stale | `editorial-audit-validate`; eligible V2 pending candidates use standing authority |
| Existing AMC value conflicts with an accepted score | `amc-apply`; do not overwrite |

## Six-month-returnability self-check

Before calling the new book scoring-ready, answer each question from durable
artifacts rather than memory:

- Which exact edition and source bytes did I ingest?
- Where is its canonical private Markdown?
- Do PDF and printed-page mappings validate?
- Can current scoring tooling resolve this exact source?
- What did Phase 1 retain, including embedded and borderline units?
- What did Phase 2 accept, reject, merge, split, or nest—and why?
- Where is the frozen approved decision?
- Which exact base AMC did ID allocation use?
- Which software-derived IDs were assigned?
- What changed in the successor workbook?
- Are all formulas, styles, unrelated cells, and unassessed fields accounted
  for?
- Which workflow is selected: verified V2 staging with later exact final approval,
  or manual unscored-successor adoption followed by individual score review?
- Which repository owns the next action?

If any answer depends only on an old conversation, the workflow is not yet
durable.
