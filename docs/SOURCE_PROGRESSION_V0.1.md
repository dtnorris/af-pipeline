# Source progression v0.1

`bin/af-source-progress` is the pipeline-owned deterministic continuation seam
between an accepted conversion receipt and the durable boundary-editorial
handoff. AdventureFinder continues to own the ingest operation, its lifecycle,
and all operator choices. Pipeline neither reads AdventureFinder's private
store nor persists a second operation state.

## Public call

Source identity, registry/path/hash validation and registration mechanics load
from the standalone `af-source-md` API `af-source-md/v0.1` (Ruby 3.2+).
Select its reviewed tree with the absolute `AF_SOURCE_MD_ROOT`, or make
`af_source_md` available on Ruby's load path when that variable is absent.
Explicit blank, missing, invalid or unsupported selections refuse without
using ambient or historical code. Keep the selection fixed for the process.
The adapter preserves pipeline results, ValidationError, CLI output and stronger
validation policy; MD has no dependency on pipeline/private-data-root classes.
Registration still requires an existing registry and grants no editorial approval.

Set `AF_DATA_PIPELINE_DATA_ROOT` to an existing authorized private directory
for the public executable. Omit `--pipeline-root`, or supply that
same data directory. The executable checkout and subprocess cwd remain the
code root; the `pipeline` locator below resolves against the data root. See the
[private-root contract and ownership inventory](architecture.md#private-operational-data-root)
for precedence, failure behavior and downstream invocations.

```sh
bin/af-source-progress ARTIFACT \
  --operation-input OPERATION_ROUTING_INPUT.json \
  --source-root MD_FOR_LLM_BOOK_CONTENT \
  --catalog-root AF_XLSX_DATA_SOURCES \
  --pipeline-root AF_DATA_PIPELINE \
  [--registry SOURCE_REGISTRY.yml] \
  [--canonical-destination EXPLICIT_OPERATOR_CHOICE.md] \
  --json
```

The canonical destination is required only for an accepted conversion receipt.
It is an explicit operator choice: pipeline never chooses an edition or
filename. `af-source-place` copies only the receipt-bound bytes beneath the
configured source root, verifies their SHA-256, reuses an exact existing file,
and refuses a conflicting overwrite or unsafe path.

## One-transition contract

Each call performs no more than the transition selected by the bound input:

| Bound input | Validated PASS output | State |
| --- | --- | --- |
| accepted conversion receipt | canonical bytes plus source-intake report | `SOURCE_INTAKE_READY` |
| source-intake report | exact single-file registration plus boundary dossier | `BOUNDARY_DOSSIER_READY` |
| boundary dossier | clean editorial context and decisions ledger | `BOUNDARY_EDITORIAL_HANDOFF_READY` |

The JSON result has schema `af-source-progression-result/v0.1`. Every
`operation_artifact` includes its public contract version and a component-root
relative locator, byte length, and SHA-256. Companion evidence and canonical
source bytes are listed separately. Machine-specific absolute paths are not
durable identity.

The coordinator must bind the returned operation artifact, persist its own
lifecycle transition, and provide a fresh `af-ingest-routing-input/v0.1`
projection before the next call. A successful process exit is never sufficient:
pipeline independently validates the expected files, schemas, identities,
digests, source registry, canonical Markdown, frozen catalog, and deterministic
companions before returning PASS.

## Replay and interruption

Compatible completed output is validated and reused without overwrite. The
editable editorial decisions ledger is validated and preserved on replay;
existing candidates, dispositions, and notes are never reset. Partial bundles,
conflicting bytes, changed provenance, wrong schemas or identities, and a zero
exit with missing output fail closed. An exact single-file registration left by
an interrupted prior call may be resumed; segmented and offset mappings remain
manual registration gates.

## Human boundary

The terminal PASS is `BOUNDARY_EDITORIAL_HANDOFF_READY`. It initializes an
empty ledger only. It does not identify boundary candidates, assign Adventure
IDs, make Phase 1/1b/2 decisions, approve a freeze, run inference or scoring,
write an AMC, or change `catalog_head`, `matcher_authorized_baseline`, or
`production_dependency_floor`. Unknown or ambiguous page mappings and source
quality flags stop at `NEEDS_SOURCE_QA_REVIEW`.

A conversion receipt awaiting page review returns `NEEDS_PAGE_REVIEW` without
running a continuation. The router adds optional page-review and front-door
commands when their respective component roots have been selected.

The wider legacy `af-ingest-next --auto` router remains compatible and retains
its existing allowlist. Operation coordinators use this source-only seam so an
automatic source progression cannot cross into post-editorial freeze or
successor application.

### Explicit public editorial selection

`af-source-progress ... --spec-root /absolute/public/root` forwards the explicit
selection to the read-only router and the editorial initializer. New bundles
require the pinned `EditorialSpecifications` inventory, Editorial 2.0 Draft and
ABDS 1.4 bytes. With no selection, progression retains
`NEEDS_EDITORIAL_SPECIFICATIONS` and creates no bundle. Source QA still runs
before initialization. Existing compatible bundles replay without rewriting;
selecting over a historical or differently bound bundle refuses. The operation
projection remains unchanged; the coordinator owns durable selection and must
revalidate its exact binding on every resume.
