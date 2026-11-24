# Pre-Phase-1 boundary dossier

`bin/af-boundary-dossier` prepares deterministic evidence for AdventureFinder's editorial Phase 1 boundary review.

It is intentionally **not** a boundary classifier. It does not create candidate records, accept or reject boundaries, infer nesting, assign Adventure IDs, or modify the Adventure Master Catalog.

## Inputs

The command requires:

- a canonical Markdown source already represented in `source_registry.yml`;
- the exact canonical source identity from that registry;
- an explicit base AMC workbook; and
- a new output directory.

Example:

```bash
bin/af-boundary-dossier \
  --source-root "$SOURCE_ROOT" \
  --source-id "Example Source" \
  --amc $CATALOG_ROOT/5e_Adventure_Master_Catalog_X.Y.xlsx \
  --output audits/pre-scoring/example-boundary-dossier
```

Use `--registry PATH` only when the registry is not `source_registry.yml` beneath the source root.

## Outputs

The command writes two equivalent evidence artifacts:

- `boundary_dossier.json` — structured machine-readable evidence;
- `boundary_dossier.md` — a compact frontier/human review packet.

The dossier binds the source registry, every registered Markdown file, and the explicit base AMC by SHA-256. It then reports:

- Markdown heading hierarchy with line numbers and mechanically derived page spans;
- an observed-only navigation index that keeps literal Markdown headings, source contents-table entries, and literal plain-text structural labels distinct;
- PDF and printed-page marker counts plus gaps, duplicates, and non-increasing transitions;
- explicit PDF-to-printed-page mapping evidence where each PDF page is `observed`, `unknown`, or `ambiguous`;
- conversion-quality flags for the replacement character (`�`) or standalone `ERROR`;
- source-language lines containing adventure/scenario/mission/quest, dungeon, hook, encounter, resolution/development, or level terms;
- mechanically parsed level mentions;
- signal-bearing Markdown tables, including TOC/overview-like `Name`/`Title` + `Page` tables;
- the base AMC record count and counts of adventures at ≤1, ≤2, ≤3, and ≤5 pages;
- a small set of the shortest current AMC records as precedent context;
- existing rows from the exact same source identity; and
- exact or punctuation/whitespace-normalized AMC title matches for source headings.

The generator verifies that the source registry, Markdown files, and AMC did not change while the dossier was being built. It refuses to overwrite an existing dossier artifact.

## Structural and pagination evidence contract

Navigation evidence is deliberately weaker than editorial structure:

- only literal Markdown headings are emitted as headings;
- a plain OCR line such as `Chapter 4: ...` may be surfaced as a `structural_label_signal`, but is never promoted into the heading hierarchy;
- a source contents-table row may be surfaced as a `contents_entry`; its page value is retained as a source TOC claim, not treated as an independently verified page mapping;
- a printed-page mapping exists only when an explicit `<!-- Printed Page N -->` marker occurs after the current `<!-- PDF Page M -->` marker and before the next PDF-page marker;
- entering a new PDF page clears printed-page context, so a previous printed page can never leak forward onto an unmapped page; and
- multiple different printed-page markers on one PDF page are reported as ambiguous rather than reconciled or guessed.

These anchors exist to make a flat or weakly headed OCR document navigable without inventing headings, pagination, parent/child relationships, or adventure classifications.

## Editorial boundary

The dossier exists to remove clerical source navigation from Phase 1. David + frontier review still decide:

- whether a structural unit is independently runnable;
- whether a named hook/quest is merely an entry point into another adventure;
- whether an embedded unit deserves a canonical identity;
- parent/child nesting;
- canonical title and page span; and
- whether source level language is appropriate for AMC `Level Start` / `Level End`.

Shortness and embedding are evidence, not automatic exclusion criteria. Signal hits are evidence, not candidates.
