# Machine policy acceptance provenance v0.1

Status: **CONTRACT ONLY / NOT APPLIED**

`adventurefinder-machine-policy-acceptance/v0.1` is the durable pipeline-owned
record for one qualification-aware machine policy decision about one exact
scoring candidate. `AfDataPipeline::MachinePolicyAcceptance` validates this
contract offline. It does not evaluate policy, create acceptance records,
modify an editorial ledger, apply a value, promote a catalog, or claim that a
human inspected evidence.

The current `adventurefinder-scoring-acceptance-policy/v0.1` remains
`CANDIDATE_NOT_ENABLED`. Therefore current policy output can produce only a
`PROPOSED` record with `MACHINE_POLICY_PROPOSAL` authority and
`authoritative: false`. Future `ACCEPTED` records require both a policy whose
bound bytes say `ENABLED` and the later authorities listed below.

## Authority boundary

| Record or fact | Authority | Meaning here |
| --- | --- | --- |
| AFW receipt | AFW | Provenance-validated proposed scoring evidence, not acceptance |
| Workload and qualified profile | AFW | Exact scoring intent, case/profile/model identity and qualification evidence |
| Attempt metadata | WLO | Exact authoritative execution attempt and retained history |
| Prompt/schema/source/scoring artifacts | scorer | Exact scoring evidence protected by digests |
| Human `ACCEPT`, `HOLD`, `REJECT` | reviewer through pipeline | Separate authority; never written or replaced by this record |
| `source_hold` | pipeline review packaging | Unresolved source evidence; never cleared by this record |
| Candidate simulation | scoring policy evaluator | `PROPOSED`, non-authoritative, and incapable of application |
| Machine policy acceptance | future enabled pipeline application | `ACCEPTED`, machine-only authority for one bound candidate |

Historical `production-ingest-v1-mechanical-policy` audit rows with
`human_reviewed: false` retain their existing meaning. They are not human
decisions and are not qualification-aware machine policy acceptance records.

## Record states

### `PROPOSED`

- `authority.kind` is `MACHINE_POLICY_PROPOSAL`;
- `authority.authoritative` is `false`;
- policy status is `CANDIDATE_NOT_ENABLED`;
- decision is `WOULD_MACHINE_ACCEPT` or `HUMAN_REVIEW_REQUIRED`;
- no value may be applied from this record.

### `ACCEPTED`

- `authority.kind` is `MACHINE_POLICY_ACCEPTANCE`;
- `authority.authoritative` is `true`;
- policy status is `ENABLED`;
- decision is `MACHINE_ACCEPTED`;
- exact IG-12B success evidence and explicit project application authorization
  are present and digest-bound;
- every referenced artifact is revalidated against caller-supplied roots.

This contract does not enable the second state. IG-16B or later must receive
explicit project authority before it may create or consume it.

## Exact bindings

Each record binds the following as structured fields, not prose:

- candidate key, adventure ID, dimension, metric, proposed value and canonical
  candidate-content digest;
- AFW receipt contract, semantic status, receipt ID, receipt byte digest and
  root-relative reference;
- review-package and scoring-artifact references and digests;
- assessment state, exact review flags, source-hold state and any existing
  human decision, plus their canonical digest;
- AFW workload manifest ID/digest, plan ID/digest, case ID/reference/digest,
  job ID and plan-job digest;
- authoritative attempt number/status/exit state, retry/supersession/favorable-
  rerun state and exact WLO metadata reference/digest;
- final qualification state, profile ID, qualification/profile artifacts,
  AFW contract digest, model alias/manifest digest and runtime identity/digest;
- policy schema, ID, version, status and exact artifact bytes;
- decision/result/reasons and exact evaluator input/output artifacts;
- evaluator and producer IDs, versions, Git commits and code digests; and
- a software-recorded UTC timestamp.

Paths are portable root-relative references such as `afw`, `wlo`, `pipeline`
or `project`. Absolute paths and traversal are rejected. Durable identity does
not encode a workstation path.

## Candidate granularity

One record grants authority to exactly one candidate key. Scalar candidates
use the dimension as the metric. Levels requires separate `Level Start` and
`Level End` candidate keys and candidate-content digests. Those two candidates
may bind the same AFW receipt, case, job and attempt; acceptance of either does
not imply acceptance of its sibling, the receipt as a whole, another workload
case, a source hold, or any unresolved evidence.

## Identity, replay and refusal

`binding_sha256` is the canonical digest of the candidate, evidence, workload,
attempt, qualification, policy and decision sections. `record_id` is the
canonical digest of the entire authority record except `record_id` and
`recorded_at`.

Excluding `recorded_at` prevents timestamp refresh from manufacturing renewed
authority. An unchanged replay reuses byte-identical content. If an existing
record has the same `record_id` but different bytes, validation refuses an
identity collision. If it has a different `record_id`, validation refuses to
overwrite a different immutable decision.

The validator can compare a record with a current binding snapshot. Any change
to candidate/evidence, receipt/workload/case/job/attempt, qualification/profile/
model/runtime, policy bytes/version, evaluator decision or review conditions
produces a stale-record refusal. When roots are supplied, every referenced file
is read and SHA-256 revalidated. `ACCEPTED` records require all referenced roots;
structural validation alone is never production authority.

## Precedence and non-overwrite behavior

An accepting decision requires:

- no review flags;
- no source hold;
- no existing human `ACCEPT`, `HOLD` or `REJECT`;
- one authoritative successful attempt that is not a retry, superseded, or a
  favorable rerun; and
- final `LOCAL_QUALIFIED` state.

Existing human decisions remain in the human ledger unchanged. A machine
record never writes a reviewer identity or sets `human_reviewed: true`.
`HOLD`, `REJECT`, source holds and authority conflicts route to explicit human/
project judgment; they are not resolved by precedence tricks or a new machine
timestamp.

## Later application prerequisites

An authoritative future `ACCEPTED` record requires all of the following:

1. IG-12B successfully evaluates the exact bound policy against its exact
   retained population, with its result artifact digest-bound in the record.
2. The project explicitly authorizes application of that exact policy/result
   envelope, with the authorization artifact digest-bound in the record.
3. The policy artifact itself is explicitly `ENABLED` without changing its
   bound identity unnoticed.
4. Every candidate, evidence, workload, attempt, qualification, profile,
   policy and decision binding is current and every referenced artifact is
   revalidated.
5. No human decision, source hold or unresolved decision-relevant condition
   conflicts with machine acceptance.

IG-12B is intentionally not a dependency of this contract-design task. This
file and validator establish the seam for later IG-16B; they do not supply any
of these authorities.

## Validation API

```ruby
AfDataPipeline::MachinePolicyAcceptance.validate_file!(
  path: record_path,
  roots: {
    "pipeline" => pipeline_root,
    "afw" => afw_root,
    "wlo" => wlo_root,
    "project" => project_authority_root
  },
  current: current_binding_snapshot,
  existing_path: immutable_existing_record_path
)
```

`current` contains the exact seven binding sections named above. It is an
explicit current-state input, not a discovery mechanism. `existing_path`
enables immutable replay/collision checks. The validator performs no writes.
