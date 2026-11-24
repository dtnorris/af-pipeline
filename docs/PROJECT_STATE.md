# AdventureFinder project-state contract

`af-xlsx-data-sources/PROJECT_STATE.yml` is the machine-readable root pointer for
shared moving AMC authority. The data repository owns the manifest and referenced
workbooks. `af-xlsx-files` owns full v0.2 read validation and explicitly named
role resolution. `AfDataPipeline::ProjectState` delegates those reads to XL.
The pipeline owns catalog adoption admission and delegates guarded writes to XL.

## Catalog owner dependency

Select the public `af-xlsx-files` API 0.1 code with an absolute
`AF_XLSX_FILES_ROOT` containing `lib/af_xlsx_files.rb`, or provide that library
on Ruby's load path. An explicit empty, missing, incompatible or partly missing
owner refuses; it never falls back to an installed or sibling implementation.
The code root selects implementation, not catalog authority or a private store.
XL uses Ruby 3.2+ and the existing rubyzip/rexml dependency closure. Apply the
owner before this caller; no installation or store initialization is performed
by loading either library.

The owner also supplies both workbook parser models and XML/style/numeric
helpers. Existing PL helper constants and error classes remain compatible aliases
or inherited adapters. Accepted-value application, finalization, scored-new-ID,
release and frontier admission remain PL responsibilities. For the reviewed
adoption commands, select an owner revision with guarded catalog storage support.

## Roles

The v0.2 contract contains exactly three independent roles:

- `catalog_head`: latest accepted canonical library state. Advance this when a
  validated canonical successor AMC becomes the new head.
- `matcher_authorized_baseline`: exact catalog deliberately approved as the
  default deterministic matcher/query dataset. Advance it only through an
  intentional matcher-authorization decision.
- `production_dependency_floor`: oldest canonical AMC still required by any
  active or unresolved production-scoring workflow. It is a retention and
  coordination pointer, not a default scoring input.

Two or three roles may point at the same workbook. A promotion changes exactly
one role and never cascades to another role.

## Frozen production inputs and the production floor

A scoring batch, boundary freeze, adjudication, regression, or experiment that
has already frozen an exact AMC input continues to use that exact artifact. It
must not re-resolve a moving role during replay or resume.

`production_dependency_floor` summarizes how far back active production still
requires canonical AMC artifacts to remain readily available. Advance it only
after every workflow depending on an older AMC is fully closed, including any
required inference, QC/adjudication, and reconciliation. New production work
should normally freeze `catalog_head`; do not start or reopen work below the
floor without an explicit project-state correction.

Consumer precedence is therefore:

1. explicit caller/CLI artifact;
2. exact artifact already frozen by the operation being replayed/resumed;
3. the consumer's documented project-state role;
4. otherwise fail closed.

There is no fallback that scans filenames or chooses the numerically greatest
AMC version.

## Path and integrity semantics

`PROJECT_STATE.yml` lives beside the AMC workbooks it names. Every role records:

- `version`;
- canonical `filename` (`5e_Adventure_Master_Catalog_<version>.xlsx`);
- SHA-256;
- byte size.

Resolution validates schema, role completeness, canonical filename, file
existence, byte size, and SHA-256. `matcher_authorized_baseline` and
`production_dependency_floor` may lag but may not be newer than `catalog_head`.

## Operational commands

From `af-data-pipeline`:

```bash
bin/af-project-state validate
bin/af-project-state resolve catalog_head
bin/af-project-state resolve matcher_authorized_baseline
bin/af-project-state resolve production_dependency_floor
```

To advance `catalog_head` manually, review the workbook's compatibility and
catalog delta, then explicitly confirm the import:

```bash
bin/af-project-state adopt /path/to/5e_Adventure_Master_Catalog_5.8.xlsx
```

The CLI refuses `promote catalog_head`. Use `promote` for
`matcher_authorized_baseline` or `production_dependency_floor`. These role
promotions require an existing canonical workbook beside the manifest and
update only the named role:

```bash
bin/af-project-state promote matcher_authorized_baseline \
  --manifest "$CATALOG_ROOT/PROJECT_STATE.yml" \
  --artifact "$CATALOG_ROOT/5e_Adventure_Master_Catalog_5.8.xlsx" \
  --version 5.8
```

Select the manifest explicitly with `--manifest PATH` or `AF_PROJECT_STATE`.

`af-project-state adopt` and `af-final-release-adoption` both use
`CatalogAdoption`. The XLSX owner holds a lock on the physical catalog directory
through pipeline admission, exclusive workbook import and atomic manifest
replacement. Each reviewed path binds the exact prior manifest bytes and
preserves the independent roles. A replay of a reviewed release checks the
prior manifest at the reviewed Git HEAD and the exact live transition before
recovering the result. Both commands leave Git persistence to the operator.

This admission rule covers the public pipeline CLI. Direct Ruby calls and
filesystem writes are outside its scope. Independent XLSX owner validation
of approval proofs and any future supported owner API admission require
separate work.

`CURRENT_AMC.yml` is retired. Its single pointer could not distinguish canonical
catalog head, matcher authorization, and the oldest live production dependency.
