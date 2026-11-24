# Ingestion next-action router

`bin/af-ingest-next` is the read-only operator front door for the new-book
ingestion workflow.

It exists to remove a recurring failure mode: a deterministic stage succeeds,
but the operator has to ask a chat which repository/tool comes next, recover
paths or IDs manually, or remember whether a review gate still applies.

The router never mutates project state and never makes editorial decisions.
Instead it inspects the durable artifact produced by the previous stage and
reports a common contract:

```text
STATE: <machine-readable state>
Artifact: <artifact type>

Evidence:
  - ...

Warnings:
  - ...

Human review required:
  - ...

Next command:
  1. cd ...
     ...
```

Use `--json` for the same information as structured data.

## Durable-operation input

AdventureFinder may pass its validated operation choices and frozen identities
through the versioned, read-only projection:

```bash
bin/af-ingest-next PATH_TO_ARTIFACT \\
  --operation-input PATH_TO_ROUTING_INPUT.json \\
  --json
```

See `docs/INGEST_OPERATION_ROUTING_V0.1.md` for the exact input, result and
error contracts. The projection binds exact artifact, source and base-catalog
identity without making pipeline the operation lifecycle owner. It cannot be
combined with `--auto`.

## Supported artifacts

The router recognizes:

- `pdf-to-llm-md/conversion-receipt/v0.1`;
- `af-source-intake/v0.1`;
- `af-boundary-dossier/v0.1` and `/v0.2`;
- an `af-boundary-editorial` bundle directory containing
  `editorial_context.json` and `editorial_decisions.yml`;
- `af-boundary-freeze/v0.1`; and
- `af-boundary-freeze-apply-report/v0.1`.

It also reads the shared `PROJECT_STATE.yml` to distinguish a verified proposed
successor AMC from one already adopted as `catalog_head`.

Operation-bound staging is a separate terminal preparation path documented in
`VERIFIED_STAGED_SUCCESSOR_V0.1.md`. It consumes the AdventureFinder-owned
successor-version authorization projection and stops at a verified staged successor.
It does not change this legacy router: a raw boundary-apply report still routes to
reviewed catalog adoption, while the staging receipt is not interpreted as adoption,
workload, or scoring authority.

## Basic use

After each durable stage:

```bash
bin/af-ingest-next PATH_TO_ARTIFACT
```

Examples:

```bash
bin/af-ingest-next \
  audits/pre-scoring/example-source-intake/source_intake.json
```

```bash
bin/af-ingest-next \
  audits/pre-scoring/example-boundary-dossier
```

```bash
bin/af-ingest-next \
  audits/pre-scoring/example-boundary-editorial
```

```bash
bin/af-ingest-next \
  audits/pre-scoring/example-boundary-freeze.yml \
  --publisher "Exact Publisher" \
  --successor-version 7.1
```

```bash
bin/af-ingest-next \
  audits/pre-scoring/example-boundary-freeze-apply-report-from-amc-7.0-to-7.1.json \
  --batch 037
```

## Human decisions remain explicit

When a next command depends on a semantic choice, the router does not invent a
value. It stops at a state such as:

- `NEEDS_CANONICAL_MARKDOWN_PLACEMENT`;
- `NEEDS_SOURCE_IDENTITY`;
- `NEEDS_EDITORIAL_REVIEW`;
- `NEEDS_HUMAN_APPROVAL`;
- `BLOCKED_BOUNDARY_APPROVAL`;
- `NEEDS_SUCCESSOR_METADATA`; or
- `NEEDS_PRODUCTION_BATCH_NUMBER`.

Supply the relevant reviewed value on a later invocation with options such as
`--source-id`, `--approval`, `--publisher`, `--successor-version`, or `--batch`.
Boundary approval is first issued by the explicit `af-boundary-editorial approve`
action, which records the timestamp in software and binds the exact completed
review and provenance. Loose `--approved-by` / `--approved-at` routing flags are
rejected and cannot authorize import.

## Cross-repository routing

Select the canonical source and catalog explicitly using `--source-root` and
`--catalog-root`. For a route that invokes another component, provide its code
root through the corresponding flag or documented environment variable. For
workload compilation, select the AF Workloads store through `AF_AFW_DATA_ROOT`
and bind the public scorer with `--scorer-repo` and `--scorer-config`.

After a boundary-apply report is verified, the router first requires catalog
adoption. The current adoption command is the owner of reviewed AMC import and,
when the cross-consumer compatibility feature is present, its compatibility
gate. Only after `PROJECT_STATE.yml` proves that the exact successor SHA-256 is
the accepted `catalog_head` will the router offer the forward AFW workload
compile command. The router derives a stable `production-batch-NNN` workload ID
from `--batch` and passes the exact verified successor AMC.

Before rendering `--ids`, the router uses the reviewed `printed_pages` already
bound into the verified boundary-apply report to partition newly added Adventure
IDs against the current production scoring qualification. Canonical units under
100 printed pages are passed to AFW. Units at or above 100 pages are surfaced as
explicitly deferred, with page counts and the qualification reason, and are not
included in the AFW workload. Deferred IDs remain canonical catalog records and
remain unscored; deferral is an execution-eligibility decision, not an editorial
boundary change.

`afw-build-workload` performs zero model inference. It freezes scoring intent,
renders AFSU preflight evidence, and writes a WLO `execution-plan.json`. WLO
planning/execution remains a separate, human-reviewed step with machine-local
worker configuration; `af-ingest-next` does not start WLO or model inference.

## Safety properties

- Artifacts are inspected read-only.
- Known SHA-256 bindings are verified before paths are reused.
- Moving `catalog_head` is used only for a new, not-yet-frozen source-intake
  transition.
- Once a dossier/editorial/freeze artifact records a base AMC, that exact
  filename/hash is reused rather than silently rebinding to a newer head.
- Missing human decisions stop command generation rather than producing guessed
  arguments.
- A failed conversion, source conflict, or unverified AMC apply report produces
  a blocking state.
- The router does not create a legacy production backlog and does not start WLO
  or model inference; it stops at the zero-inference AFW workload-build handoff
  so the generated WLO execution plan can be reviewed before machine time is
  committed.
- AFW eligibility is explicit at the handoff. IDs outside the currently proven
  `<100`-page production scoring envelope are reported as deferred and omitted
  from `--ids`; they are never silently dropped or treated as scored.
