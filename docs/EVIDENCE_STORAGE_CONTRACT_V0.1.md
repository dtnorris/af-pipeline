# AdventureFinder production-evidence storage contract v0.1

**Status:** Frozen storage contract. The public distribution supports
deterministic manifest/bundle construction, independent verification, derived
SQLite indexing, lookup/retrieval and mechanical equivalence checks.

## Purpose

This document defines the successor storage contract for finalized
AdventureFinder production-scoring evidence. It separates three concerns that
are currently conflated when thousands of raw inference artifacts are retained
as individually tracked Git paths:

1. lossless retention of canonical raw evidence;
2. deterministic integrity/provenance metadata; and
3. fast derived lookup over that evidence.

For newly cut-over production batches, expanded evidence is frozen only as a
temporary local verification source. The durable `llm-response-data`
representation is the verified bundle + manifest together with the rebuildable
SQLite index. Historical expanded evidence remains untouched until a separate
migration/cleanup milestone.

## Repository ownership boundary

`af-evidence` is the standalone implementation owner for manifest/bundle
construction, verification, derived indexing, lookup and retrieval. Its ordinary
Ruby entry is `require "af_evidence"` with EV's `lib` on the load path.
Set `AF_EVIDENCE_ROOT` to the absolute checkout path pinned in
[`config/public_owners.tsv`](../config/public_owners.tsv). The pipeline loads
`lib/af_evidence.rb` from that checkout. An absent selection or a different
already-loaded evidence owner raises `LoadError`.

`af-data-pipeline` retains the existing `AfDataPipeline::Evidence*` entry points
as thin subclasses of the `AfEvidence::Evidence*` owners. They forward results
and map EV validation failures to `AfDataPipeline::ValidationError`, preserving
pipeline rescue and receipt contracts. Use `AfEvidence::EvidenceStore` for
verified pair reuse/publication and derived index publication. It takes
explicit absolute source, evidence and index paths. These paths are independent
of the EV code selection and `AF_DATA_PIPELINE_DATA_ROOT`. Use
`AfEvidence::EvidenceEquivalenceChecker` for the four mechanical equivalence
checks. Production shadow writing, cutover decisions and completion receipts
belong to the separate production workflow.

`bin/af-data evidence-retrieve` requires `AF_DATA_PIPELINE_DATA_ROOT` and
an explicit new output beneath it. The pipeline retrieval adapter applies
`PrivateDataRoot.destination!` before EV independently validates a new output
outside the canonical store. EV rejects
traversal, symlink destinations/ancestors, overlap, existing destinations and
missing/unwritable parents without relying on a caller authorization boolean.
The full pipeline entry still loads its workflow classes and existing
CSV/REXML/ZIP dependencies; it is not an evidence-only bootstrap. Independent
use loads the ordinary EV entry and its declared closure instead.

`llm-response-data` owns the resulting durable evidence artifacts: immutable
batch bundles, their manifests, and the committed derived evidence index.

AFIO remains the producer/orchestrator of inference evidence. This contract does
not move inference, model selection, prompt construction, or RunPod/RPOF
operations into `af-data-pipeline`.

## Canonical concepts

### Evidence batch

An **evidence batch** is one finalized, immutable production-scoring evidence
unit with a stable `batch_id` such as `example-batch`.

Before cutover, an expanded source tree may remain the current production
representation. Under the successor contract, the durable canonical
representation of a finalized batch is the pair:

```text
immutable batch bundle + batch manifest
```

Neither member of a finalized canonical pair may be modified in place.
Corrections require a new versioned artifact identity; they must not overwrite
the bytes associated with an already-finalized identity.

### Canonical evidence file

A canonical evidence file is identified by:

- its batch-relative POSIX path; and
- its exact file-content bytes.

Filesystem ownership, modification time, access time, extended attributes,
resource forks, and platform-specific metadata are not canonical evidence.
Archive construction must not allow those properties to change the logical
evidence set.

### Batch bundle

A **batch bundle** is one compressed regular file containing every canonical
evidence file in the batch exactly once.

The bundle format and compression profile are explicit and versioned. The v0.1
profile is:

```text
format:          tar+zstd
profile_version: af-evidence-bundle/tar-zstd-v0.1
extension:       .tar.zst
tar member mode: 0644
tar uid/gid:     0 / 0
tar uname/gname: empty
tar mtime:       Unix epoch 0
zstd level:      9
zstd workers:    1
zstd checksum:   disabled
```

Only regular canonical evidence files are emitted as tar members. Directory
entries, symlinks, filesystem modes, ownership, timestamps, xattrs, resource
forks, AppleDouble files, and other platform metadata are not retained. Members
are emitted in lexicographic batch-relative POSIX-path order.

The builder invokes the `zstd` executable directly. `AF_EVIDENCE_ZSTD` may name
an alternate executable path; absence or failure of the compressor is a
fail-closed validation error.

This profile choice was pressure-tested against the measured Batch 29 corpus.
The same deterministic 44,908,032-byte tar stream compressed to 13,411,123
bytes with gzip level 6 in about 1.91 seconds and to 2,730,037 bytes with zstd
level 9 in about 0.28 seconds in the benchmark environment. The benchmark is
decision evidence, not part of the logical evidence contract.

A bundle builder must:

- consume a complete deterministic evidence inventory;
- emit members in a deterministic order;
- normalize non-evidence archive metadata so it cannot introduce accidental
  platform variance;
- exclude AppleDouble entries (`._*`) and other resource-fork sidecars created
  by macOS archiving behavior;
- include every manifest-declared evidence file exactly once;
- include no undeclared evidence member; and
- compute SHA-256 over the exact final bundle bytes.

### Batch manifest

A **batch manifest** is the authoritative machine-readable inventory and
provenance record for one bundle.

At minimum it must identify:

- manifest schema version;
- batch identity;
- bundle filename/path;
- bundle format/profile version;
- bundle byte size;
- bundle SHA-256;
- canonical member count; and
- for every canonical evidence file:
  - batch-relative POSIX path;
  - byte size; and
  - SHA-256 of the exact file bytes.

The machine-readable v0.1 contract is
`schemas/af-evidence-manifest-v0.1.schema.json` in the EV package, available as
`AfEvidence::MANIFEST_SCHEMA_PATH` after its ordinary require.
The test suite constructs content-free manifests and exercises both the owner
schema and the pipeline's historical format adapters.

Portable JSON Schema cannot express every cross-field invariant required by
this contract. Deterministic manifest validation must additionally require
`member_count == members.length` and unique `members[].path` values.

Later schema work may add producer/run metadata, but no required provenance may
be guessed. Unknown remains unknown.

SHA-256 values are lowercase hexadecimal encodings of the 32-byte SHA-256
digest. Individual-file hashes are computed over raw file-content bytes only.
Bundle hashes are computed over the exact stored bundle bytes.

### Evidence index

The **evidence index** is a committed SQLite database that provides deterministic
lookup into the canonical evidence corpus.

The index is **derived, not authoritative**. It must be deletable and logically
rebuildable from canonical manifests/bundles by deterministic
`af-evidence` tooling. A stale or inconsistent index is a validation
failure; it does not override bundle or manifest evidence.

The v0.1 table/index contract is executable SQL at
`schemas/af-evidence-index-v0.1.sql` in the EV package, available as
`AfEvidence::EvidenceIndexBuilder::SCHEMA_PATH`.
It separates canonical batch/member inventory from AFIO job metadata and native
scorer-run metadata in `batches`, `members`, `jobs`, and `runs` tables. The
index stores canonical bundle/member locators and hashes, never absolute local
source paths. `PRAGMA user_version = 1` identifies this first SQLite schema.
AFIO `job_id` values are query fields but are not assumed to be batch-unique;
`jobs.job_key` uses the canonical `<experiment>/runs/<job_id>` member prefix as
the batch-local job identity.

The builder discovers canonical `<evidence-root>/<batch_id>/manifest.json`
pairs, independently verifies each manifest/bundle before indexing it, and
reads only canonical metadata from the verified bundle. It creates a new index
file and refuses in-place editing or overwrite of an existing committed index.

The initial index must support deterministic lookup by at least:

- batch;
- Adventure ID;
- dimension;
- model/model alias;
- run ID and/or job ID when present; and
- run status.

A lookup result must resolve back to canonical evidence through stable bundle
and member-path identity and retain hashes sufficient for verification.

SQLite schema versions must be explicit. Logical rebuild equivalence is
required; byte-for-byte SQLite-file equivalence is not required unless a later
builder profile explicitly freezes the SQLite implementation details necessary
to guarantee it.

## Authority hierarchy

For production-evidence storage under this contract, authority is:

```text
canonical evidence file bytes + canonical member paths
                    ↓ represented by
          immutable bundle + manifest
                    ↓ indexed by
          derived SQLite evidence index
```

The index may accelerate discovery and retrieval but must never invent,
normalize away, or override canonical evidence.

Git history protects the committed manifest, bundle, and index as repository
artifacts, but Git object identity is not a substitute for the SHA-256 fields
required by this contract.

## Target repository layout

The first implementation should use a small, explicit layout in
`llm-response-data`:

```text
prod-evidence/
  <batch_id>/
    manifest.json
    <batch_id>.<bundle-extension>
    equivalence-report.json

indexes/
  evidence-index.sqlite
```

The exact bundle extension follows the later frozen bundle profile. A future
external artifact store may replace repository-local bundle placement only
through an explicit contract revision or versioned locator scheme; hosted
infrastructure is not required by v0.1.

## Immutability and corrections

After finalization:

- a bundle's bytes must not change;
- its manifest's canonical inventory/provenance must not change;
- an existing finalized identity must not be silently repointed at different
  evidence; and
- index regeneration must not mutate canonical evidence.

If evidence must be corrected, the correction is a new versioned evidence
artifact that preserves the prior finalized artifact for auditability.

## Rebuildability and verification

The implementation must be able to prove all of the following without trusting
the SQLite index:

1. every manifest-declared file exists in the bundle exactly once;
2. no undeclared canonical evidence file exists in the bundle;
3. every member byte size and SHA-256 matches the manifest;
4. the bundle byte size and SHA-256 match the manifest;
5. selected evidence can be extracted and verified against its manifest hash;
   and
6. the committed SQLite index corresponds to the canonical manifests/bundles
   represented by the checkout.

Deleting the derived SQLite database and rebuilding it must preserve the same
logical indexed records for the same canonical corpus.

## Transition safety

For production workflows using compact ingest, preserve a temporary expanded
archive outside `llm-response-data` for scanning, editorial review, and
deterministic equivalence validation. The compact pair and derived index are
the durable Git representation.

For cut-over batches:

- do not write the expanded batch tree under `llm-response-data/prod-imports-all`;
- require bundle + manifest construction and the production equivalence gate to
  pass before AMC finalization may complete;
- rebuild and verify the derived SQLite index from the canonical corpus;
- retain the local expanded verification archive until the compact artifacts
  have been reviewed/committed/pushed successfully; and
- fail closed on compact-representation errors without deleting or mutating the
  local expanded evidence.

## v0.1 non-goals

This contract does not yet:

- migrate historical `llm-response-data` trees;
- rewrite Git history;
- move bundles to hosted/object storage; or
- alter inference, scoring, editorial adjudication, or AMC mutation semantics.

Those are later implementation or migration decisions. They must preserve the
authority, immutability, provenance, and rebuildability rules frozen here.
