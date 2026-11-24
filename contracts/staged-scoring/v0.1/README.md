# Staged scoring-input authority v0.1

Status: pipeline producer/validator and offline conformance contract.
AdventureFinder owns intent/coordination and AFW owns its consumer implementation.
No end-to-end production scoring path is claimed. Synthetic fixtures carry
`mode: synthetic`; the default production validator refuses them.

## Authority and actions

| Fact/action | Durable owner | What this contract does |
| --- | --- | --- |
| Operator intent, attribution, operation and workload identity | AdventureFinder | Consumes the explicit versioned intent below; never derives permission from other artifacts |
| Boundary decisions and approval | Pipeline editorial artifacts | Revalidates the actual ledger, context, dossier, source, approval and exact approved freeze |
| Staged transformation, integrity, ID allocation | Pipeline | Revalidates staged evidence and reconstructs the deterministic allocation and authorized cell changes |
| Scoring-input authority | Pipeline | Issues one immutable assertion for the validated intent and exact evidence |
| Qualified selection, workload and scoring interpretation | AFW | Receives intended new IDs and exact catalog/authority; retains all qualification/page/Levels gates |
| Execution and attempts | WLO | No authority granted here |
| Catalog artifacts and shared roles | af-xlsx-data-sources | Read-only; no fourth role and no project-state v0.2 change |
| Score acceptance and promotion | Pipeline later review/adoption | Not authorized by this assertion |

`BoundaryFreezeStage.verify!` is a new read-only public seam: unlike `stage!`,
it cannot manufacture a missing staging result. It consumes the retained
historical project-state manifest used at staging. The original v0.1 staging
receipt, including `scoring_authorized: false`, remains unchanged. A separate
authority assertion grants only `scoring_input` and `workload_preparation`.
`BoundaryFreezeApply.plan!` reconstructs the allocation, changed-cell set and
Current Books updates in memory, without writing an output workbook. An
integrity report cannot authorize its own invented ID map or extra cell edits.

The legacy IngestNext `READY_FOR_CATALOG_ADOPTION`, ProjectState promotion,
AmcAdoptionReview and `bin/af-project-state adopt` remain unchanged. Do not
promote a staged workbook to work around a preparation gate. AFW's existing
explicit catalog path/hash support and scorer `files.catalog` precedence are
preserved; they were not blocked by a moving role.

## AdventureFinder producer requirement (IG-14A)

IG-14A is the natural owning implementation: its current scope already covers
durable ingest coordination, stable workload identity and zero-inference AFW
preparation, with AdventureFinder writable and pipeline/AFW read-only. No new
dependency edge or earlier implementation is required to validate IG-13A/13B
offline. IG-14A must supply this producer before claiming production readiness.

The landed IG-07B source driver stops at boundary-editorial review and exposes
the existing routing projection through `source_continuation_input`. Its v0.2
resume context authorizes source progression only; neither that context nor
`--canonical-destination` supplies scoring intent. IG-14A must preserve this
distinction when extending the normal start/resume interaction.

During the existing normal **ingest start** or **post-boundary resume**
interaction, capture the operator's explicit choice to prepare scoring for
this operation's approved new records. Persist that attributed choice once,
using an AdventureFinder-owned interface and its own durable concurrency/replay
rules. Preserve old operation v0.1 documents; never reinterpret their inert
policy field or silently migrate it into permission. The producer must:

1. Validate the durable operation and retained input/base/source declarations.
2. Record explicit intent, selector and UTC selection time, supported policy
   identity and actual definition digest/size, operation identity and frozen
   base. Select one collision-safe workload ID within AFW's existing syntax.
3. Bind `scope: operation-approved-new-records`. At start, approval and IDs do
   not exist yet; this scope explicitly means the later owner-validated
   approved freeze of this operation, never every blank row or a guessed range.
4. Export the exact immutable intent through a public interface. Repeated
   resume exports the same document and `intent_id`. New operation revisions
   may append component evidence but cannot replace this intent/base/workload.
5. Supply validated operation-routing and successor-version projections,
   pipeline approval/freeze/stage evidence, retained historical project state,
   and the current shared project-state path to the pipeline interface below.
6. Consume the resulting preparation decision. Do not prompt for a separate
   routine approval when already-recorded intent and validated approval/integrity
   satisfy the contract. Missing intent belongs in the normal start/resume
   interaction; conflicting intent requires explicit resolution.
7. Invoke the later IG-13B authority-aware AFW consumer and preserve all intended
   IDs as selected or explicitly deferred. Do not copy qualified dimensions,
   models, profiles, context/residency rules or page-eligibility logic into this
   contract. Execution, LOW readiness and paid RPOF provisioning remain separate.

The new intent does not retroactively turn successor-version authorization,
boundary approval, an inert policy selection, a PASS flag, or a staging receipt
into operator scoring permission. The attributed choice is the sole producer
input for that permission. The pipeline issuer does not ask for it again.

## Exact intent document

Schema: `adventurefinder-staged-scoring-intent/v0.1`.
`intent.schema.json` is the structural schema; the Ruby validator additionally
checks actual evidence and canonical hashes. Unknown top-level keys fail.

| Required field | Exact meaning |
| --- | --- |
| `schema_version`, `producer` | Schema above; producer exactly `adventure-finder` |
| `mode` | `production` or `synthetic`; must match validator invocation |
| `operation` | Exactly `contract_version`, `operation_id`, `created_at`; same operation identity as the verified successor-version authority; lowercase UUIDv4 and UTC timestamp |
| `base_amc` | Exactly `filename`, `sha256`, positive `bytes`; original frozen base, never current-head substitution |
| `source` | Exactly `source_id`, `edition`, `pagination_authority`, `publisher`; nonblank attributed operation declarations matching the routing projection |
| `policy` | Exactly `policy_id`, `policy_version`, `sha256`, positive `bytes`; binds actual policy-file bytes |
| `selected_by`, `selected_at` | Nonblank attributed selector and UTC timestamp from the AdventureFinder-owned interaction |
| `interaction` | `ingest_start` or `post_boundary_resume` |
| `purpose`, `scope` | Exactly `prepare_staged_scoring`, `operation-approved-new-records` |
| `workload_id` | Frozen once; `[a-z0-9][a-z0-9_-]{0,63}`; no new ID to evade a conflict |
| `intent_id` | Lowercase SHA-256 of canonical JSON for all preceding fields, excluding `intent_id` |

All these fields originate from the AdventureFinder producer, not a pipeline
guess. The policy definition in `config/staged_scoring_input_policy_v0.1.json`
has exact schema `af-staged-scoring-input-policy/v0.1`, ID
`approved-new-records`, version `1`, scope `operation-approved-new-records`,
selection `afw-qualified-default`, and the two preparation permissions above.
Pipeline checks the complete definition, not merely its claimed digest.
This is an input-use policy, not a second AFW scoring/qualification policy.

Canonical JSON recursively sorts object keys, preserves array order, uses
compact UTF-8 Ruby `JSON.generate`, and adds no newline. Duplicate JSON keys
are rejected. File bindings hash the actual full bytes, including whitespace.
These hashes provide identity and integrity, not signatures or authentication
against a malicious local writer. Production consumers must obtain intent
from the trusted AdventureFinder owner interface, not arbitrary untrusted JSON.
An operation-document digest is owner-supplied provenance under the existing
routing contract; pipeline never opens private coordinator state.

## Public issuer/validator

`AfDataPipeline::StagedScoringAuthority.new(evidence:, store_root:, mode:)`
exposes `issue!(current_state_path:)` and
`validate!(current_state_path:, frozen_workload: nil, workload_paths: nil)`.
The default mode is `production`. A consumer may call the public executable:

```bash
bin/af-staged-scoring-authority issue --inputs INPUTS.json --store AUTHORITY_ROOT --project-state CURRENT_PROJECT_STATE.yml
bin/af-staged-scoring-authority validate --inputs INPUTS.json --store AUTHORITY_ROOT --project-state CURRENT_PROJECT_STATE.yml
```

The locator envelope has exactly `schema_version` (value
`af-staged-scoring-evidence-locators/v0.1`) and `evidence`. Evidence has exactly:

```text
freeze_path operation_input_path successor_authorization_path
source_root catalog_root project_state_path approval_path bundle_dir
dossier_path intent_path policy_path
```

These are explicit deployment paths, not semantic identities. `dossier_path`
may be the JSON file or its containing directory. `project_state_path` is the
retained **historical** staging manifest; its three referenced workbooks must
remain accessible beside it. The independently supplied `--project-state`
is the current concurrency observation. Custom registry location remains
bound by the original freeze's `registry_filename` beneath `source_root` and
is passed explicitly to the owning validators. No registry search or substitute
bytes are accepted.

The coordinator resolves `AF_PROJECT_ROOT`, `AF_ADVENTURE_FINDER_ROOT` and
supported explicit component overrides and supplies these paths. This API
introduces no implicit normal/production root switch, path search or latest-file
selection. Root/symlink containment for source and base evidence remains with
their existing public validators. Workbooks retain their original logical
filenames; relocating complete evidence trees is supported.

Output schema: `af-staged-scoring-authority-projection/v0.1`. It includes the
authority document, a fresh concurrency proof/observation, `workload_frozen`,
`preparation_allowed`, and false execution/adoption authorization flags.
Consumers must check the schema, full validation result and
`preparation_allowed`, not merely that an authority object exists. CLI exits 2
on blocked preparation or invalid evidence; structured errors use
`af-staged-scoring-error/v0.1`. A verified zero-record approval returns
`NO_SUCCESSOR_NEEDED`, null authority and no workload/store publication.

## Immutable authority and actual proof

Authority schema: `af-staged-scoring-authority/v0.1`. Required members are
`schema_version`, `issuer` (`af-data-pipeline`), `mode`, `operation`, complete
`intent`, `permissions`, `base_amc`, `staged_amc`, `approval_id`, `allocation`,
`protected_ids`, `evidence`, and `authority_id`. AMC identities contain exact
filename/digest/size. `authority_id` hashes all other members canonically.
No wall-clock issuance time or current-head identity changes this identity.

The evidence map binds actual digest/size pairs for the routing projection,
successor-version projection, intent and policy files, boundary freeze,
editorial approval, context, decisions, review instructions, dossier, original
base, historical state, registry, every frozen Markdown file, staged receipt,
integrity report and staged workbook. The issuer revalidates approved-freeze
composition, source/base bindings, staging integrity and the in-memory exact
deterministic allocation/mutation plan. The allocation preserves frozen order,
local keys, IDs, titles, printed/PDF pages, Levels, parent keys/existing IDs,
resolved parents, target sheets/rows and changed cells. Claimed PASS flags and
caller-supplied hashes cannot replace those checks.

One operation has one immutable publication beneath the explicitly configured
authority root. Exact issue replay validates and reuses it without rewriting.
Conflicting intent, authority, base, workload identity or lineage cannot replace
it. The root is owner-managed durable state; creating another empty root is not
an authorized reset or conflict-resolution mechanism. Relocate the complete
store with its evidence. A per-operation lock and exclusive file publication
prevent concurrent conflicting issuance within that root. An interrupted
publication is refused; ordinary replay never repairs or deletes it.

Inputs and all three shared role artifacts are rehashed across publication.
A race refuses success; incomplete published files remain diagnostic evidence.
Every validator call rehashes all referenced inputs. Process-local cached owner
proof is reusable only while all bytes match; it is never imported from a
caller or persisted as a substitute for evidence. New processes re-run owners.

Identical-byte regeneration or supported relocation preserves identity.
Regeneration that changes an integrity/staging timestamp or approval-relevant
provenance is different evidence even if workbook cells look identical; it
cannot inherit the old authority. Missing original base, historical evidence,
approval, source or frozen lineage fails closed. Neither a fresh human decision
nor a newer workbook can excuse corrupt/unbound evidence.

## Deterministic concurrency contract

`catalog_head` is a **checked concurrency observation**, not an equality
precondition or replacement base. The comparison inputs are the retained base,
actual current head verified against project-state v0.2, and the validated
allocation/source lineage. Filenames, version order and row-number separation
are never compatibility proofs.

Protected IDs start with every allocated ID and every existing parent ID in
the approved freeze. Repeatedly add all base records sharing the new source or
a protected record's source, and every literal `ADV-####` reference in every
cell of those records. Close transitively over those records and sources.
If any protected record has a formula, conservatively include every base
record rather than guess its dependencies. Unresolved references are unprovable.
All cells of protected records are protected, including both catalog sheets.
The exact freeze/approval/source evidence is independently immutable.

The supported changed-head proof is intentionally narrow:

- Both catalog sheets satisfy the existing schema; Adventure IDs are valid and
  unique within each sheet. The original base also passes allocation preflight.
- No current-head ID may overlap an allocated staged ID, even if its row or
  title looks identical. Concurrent max-ID allocation is a collision.
- Package member order/membership, sheet identities/order, all non-catalog
  member hashes, worksheet structure outside cells and record placement remain
  identical. Unknown package/worksheet/schema changes are unprovable.
- Every changed cell must belong to an existing unprotected record, in an
  existing assessment column, with unchanged non-type cell attributes and no
  formula before/after. Both values must be finite numbers or blank. Header,
  ID, source, publisher, title, parent/reference and page-bound changes do not
  pass. Style/shared-string/Current Books changes are outside this narrow proof.
- No record addition/removal or movement is silently accepted. This version
  supports unrelated scalar score edits, not arbitrary concurrent ingestions
  or semantic merges. Unsupported does not mean corrupt; it means no proof.

| Predicate/result | Before authority issuance | Before workload build/replay | After workload frozen |
| --- | --- | --- | --- |
| Exact evidence; unchanged head | Issue/reuse same authority | SAFE_REUSE | SAFE_REUSE of exact evidence only |
| Exact evidence; only supported unprotected scalar score edits | Same authority; retain original base | SAFE_REUSE | SAFE_REUSE; never rebuild to current head |
| Head overlaps allocated IDs | FRESH_DECISION; refuse issuance | Block preparation/reuse | Preserve workload; block further preparation/reuse |
| Protected cell/source/page/parent change | FRESH_DECISION; refuse issuance | Block preparation/reuse | Preserve workload; block further preparation/reuse |
| ID set/placement or identity/reference change | FRESH_DECISION; refuse issuance | Block preparation/reuse | Preserve workload; block further preparation/reuse |
| Missing provenance, unknown schema/package/structure/cell change | Fail closed or UNPROVABLE; no issuance | Block | Preserve workload; block |
| Changed base/staged/intent/approval/freeze/report/authority/workload identity | Integrity/conflict error, not compatibility | Refuse | Refuse without rewriting evidence |
| Valid zero-record approved result | NO_SUCCESSOR_NEEDED; no authority | No workload | Claimed workload is a conflict |

The same predicate is evaluated at issuance, every build validation, replay and
post-freeze validation. Recheck immediately before publication/consumption;
this observation is not a lease against future catalog movement. Execution and
release decisions remain outside this implementation, including when historical
input bytes are intact but further preparation is blocked.

FRESH_DECISION means a human must explicitly resolve the conflict/hold the
operation; it is not a Boolean override. This version accepts no compatibility
waiver. Restoring exact missing evidence is repair, not reapproval. Changed
semantics require separately approved lineage/contract work; never silently
renumber IDs, replace the original base, regenerate boundaries or allocate a
new workload to evade stale input. Original approved work remains retained.

## AFW-only consumer requirements (IG-13B) and independent tests (IG-13C)

AFW consumes this public projection/validator with explicit evidence, never
private pipeline or AdventureFinder lifecycle state. Recompute authority digest,
verify exact schemas, preparation decision, catalog digest/size, operation,
intent/workload identity and intended IDs. Use the authority's staged workbook
as explicit scoring input; preserve qualification, page eligibility, conditional
Levels and provider-neutral capability rules. No shared role is modified.

At freezing, embed `staged_scoring` in the AFW snapshot, with exactly:
`schema_version: af-staged-scoring-workload-binding/v0.1`, `authority_id`,
`operation_id`, `workload_id`, `staged_amc`, and ordered `intended_ids` (every
allocated record on the historical v0.1 binding; the selected-subset extension
below uses a separate v0.2 binding). The public
binding adds exactly `artifacts`, containing `plan`, `snapshot`, `index`
digest/positive-size pairs. The validator takes those three actual paths
separately and checks hashes plus the embedded snapshot binding; AFW remains
responsible for validating the actual plan/index/case coverage and selected vs
deferred accounting. This interface does not claim to implement AFW's validator.
CLI validation accepts `--workload-binding FILE --workload-paths FILE`.
Changing any retained artifact, intended IDs or workload identity is a conflict,
even when a head comparison also reports stale input. Existing workload evidence
is never rewritten. Relocated artifact paths must still resolve exact bytes.

`concurrency-cases.json` is the shared decision oracle. The synthetic fixture
factory `test/support/staged_scoring_fixture.rb` produces real XLSX, approval,
freeze, staging, intent and policy evidence through public producers in a
disposable directory. It contains no book narrative. IG-13C can use these
artifacts against independent consumers, with both pre/post-freeze cases.
The focused tests also exercise corruption, missing provenance, mode/schema
rejection, rehashed allocation forgery, reissued authority, newer-base rebind,
workload reallocation, publication races, fresh-process CLI and relocation.

Run focused tests followed by the unchanged complete offline safety sweep:

```bash
bundle exec ruby -Ilib:test test/staged_scoring_authority_test.rb
bundle exec ruby -Ilib:test -e 'ARGV.each { |file| require_relative file }' test/boundary_freeze_apply_test.rb test/boundary_editorial_test.rb test/project_state_test.rb test/af_project_state_adopt_test.rb
bundle exec rake
git diff --check
```

No source workbook, ledger, shared role, AFW workload or execution state is
modified by validation/issuance. Only the named pipeline authority root is
written by issuance. No real inference or provider/capacity action is performed.

## Producer-owned selected subsets (IG-14C)

The authority and concurrency contracts above retain the **complete** approved
allocation and original-base lineage. AFW's public
`afw-staged-selection/v0.1` producer contract owns individual eligibility,
qualification and selected/deferred/refused dispositions. Pipeline never copies
that policy or trusts a selection document's status as independent proof.

`StagedScoringAuthority#validate!` additionally accepts `selection_path:`.
Configure `selection_afw_root:` (owner code), `selection_project_root:` (optional
explicit AFW artifact root) and `selection_scorer_root:` on the validator.
When AFW selection used an explicit input configuration, also supply
`selection_scorer_config: FILE` (`--selection-scorer-config FILE`). Pipeline
forwards it as AFW's `--scorer-config`; AFW reloads and verifies its exact
selection-bound bytes. Missing/changed files or selectors cannot reuse that
selection. Unconfigured retained contracts omit this optional selector.

The CLI equivalents are `--selection FILE --selection-afw-root DIR
--selection-project-root DIR --selection-scorer-root DIR`. These select trusted
component installations and explicit artifact roots; they are not eligibility
assertions. The owner-managed authority store and all existing complete
approval/freeze/staging, byte-integrity and concurrency rechecks still apply.

Pipeline supplies its reconstructed authority and exact staged path to
`bin/afw-staged-selection verify`. AFW re-derives the complete ledger from
actual catalog, qualification/model/runtime and source evidence, including
AFSU prepared-source file/registry bindings against the original frozen source
artifacts. For frozen
workloads it additionally validates actual coverage, conditional Levels,
models/digests, profiles, capabilities, case/runtime bytes and public AFSU
zero-inference preflight replay. Pipeline independently compares the returned
allocation, operation/authority, base/staged identities, workload identity and
ordered disposition partition with its own proof. Both owners repeat validation
across consumption to reject raced or conflicting evidence. Missing AFW owner
installations fail closed; caller-provided reduced ID lists, fabricated PASS
flags or rehashed selection JSON cannot replace the public owner verifier.

`af-staged-scoring-workload-binding/v0.2` is the existing frozen binding plus
`selection_id`, with `intended_ids` equal to AFW's verified selected IDs. Its
`artifacts` still contains exact plan/snapshot/index digest/size pairs; its path
argument additionally includes `generated`, the actual generated workload
directory. AFW anchors those artifact bindings beside its immutable selection
ledger and independently checks all expanded evidence and existing frozen
publication. The v0.1 full-allocation binding remains unchanged and requires
all allocated IDs. A v0.2 subset without verified AFW selection is refused.

A nonempty, fully deferred allocation returns `ALL_DEFERRED` with
`preparation_allowed: false`; it retains authority and the complete reasoned
AFW ledger. It cannot have a frozen workload. This is distinct from the existing
zero-allocation `NO_SUCCESSOR_NEEDED` result, which has no authority, ledger or
workload. Refused selections remain diagnostic AFW evidence and never grant
preparation. No score acceptance, catalog adoption, execution or new shared
catalog role is introduced. AdventureFinder integration and general AFW
restart-state inspection remain IG-14E and IG-14D responsibilities, respectively.
