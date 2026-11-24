# Ingest operation routing input v0.1

Status: public, read-only pipeline input contract.

Input schema: af-ingest-routing-input/v0.1

Result schema: af-ingest-routing-result/v0.1

Error schema: af-ingest-routing-error/v0.1

This contract is the narrow projection accepted by bin/af-ingest-next with
--operation-input FILE. AdventureFinder remains the owner of the durable
operation and its lifecycle. Pipeline validates the projection and component
artifacts, then computes the same route it computes for equivalent legacy
explicit inputs. It does not read AdventureFinder's persistence layout, write
an operation, or cache a route as lifecycle truth.

--operation-input cannot be combined with --auto. The seam inspects and
renders only; it never executes emitted commands.

## Input document

The JSON document has exactly these top-level members:

| Member | Meaning |
| --- | --- |
| schema_version | Exact input schema above |
| operation | Operation contract/version identity and revision |
| artifact | Exact file or editorial-bundle bytes being routed |
| source | Operation-bound source choices relevant to routing |
| base_catalog | Exact frozen base catalog and selection provenance |
| policy | Optional inert policy identity/values; never execution authority |

Unknown or missing members fail closed.

### Operation identity

operation contains exactly:

- contract_version: adventurefinder-ingest-operation/v0.1;
- operation_id: lowercase UUIDv4;
- revision: nonnegative integer; and
- document_sha256: SHA-256 of the validated canonical operation document.

The digest is a provenance reference supplied by the AdventureFinder owner. The
pipeline does not load or persist the private operation document.

### Routed artifact

A file artifact contains exactly kind: file, sha256, and positive bytes. The
positional ARTIFACT must match both byte count and digest.

An editorial bundle contains kind: editorial_bundle and exactly two
digest/size-bound members:

- editorial_context.json; and
- editorial_decisions.yml.

No path search or newest-file selection occurs.

### Source projection

source contains exactly:

- source_id: string or null;
- canonical_markdown: null or exact root-relative filename, SHA-256 and
  positive byte count;
- edition: string or null;
- pagination_authority: string or null; and
- publisher: string or null.

Canonical Markdown resolves only beneath the explicit --source-root, with
lexical and symlink containment checks. Its bytes must match. Source IDs and
publisher values map to the existing router arguments of the same names.
Equivalent independent CLI values are accepted for compatibility; conflicting
values fail. An independent value cannot fill a null operation choice. The
operation must first be revised by its owner, so a null source choice continues
to produce the existing human review gate.

Edition and pagination authority are validated and reported as bindings but
have no new pipeline routing semantics in v0.1. They are not used to guess a
source, pages, boundaries, parentage, IDs, or commands.

### Frozen base catalog

base_catalog contains exactly:

- root-relative filename;
- sha256;
- positive bytes;
- selection_method: explicit or catalog_head; and
- project_state_sha256: null for explicit selection and required for a
  catalog-head selection.

The base resolves beneath --catalog-root and its exact bytes are verified. For
source-intake transitions that would otherwise consult live catalog_head, the
current head must still equal the frozen operation base. Movement fails with
STALE_OPERATION_BASE; the router never silently rebinds.

Once a component artifact carries its own base provenance, that provenance
must match the operation base. Later unrelated head movement does not replace
the artifact-bound base. Source IDs, canonical Markdown provenance and
publisher values carried by component artifacts must likewise agree.

### Policy projection

policy is null or contains exactly policy_id, policy_version,
definition_sha256, and nonempty JSON selected_values. It is reported for
coordination provenance only. No value is interpreted as source identity,
approval, successor version, batch, execution, retry, recovery, inference, or
provider authority.

Human approval, successor_version, and batch are deliberately absent. Existing
stage-specific explicit options remain the only current route for those later
decisions.

## Output and errors

With --json, operation-aware routing returns the result schema, exact operation
identity/revision/document digest, a deterministic routing-input digest, and
the existing route fields: state, artifact_type, evidence, human_review,
commands, and warnings.

The routing-input digest is deterministic over sorted JSON object keys. No
timestamp or lifecycle state is invented.

Operation-input validation errors exit 2. With --json, stderr contains the
error schema with stable error.code and error.message. Codes include:

- UNSUPPORTED_VERSION;
- MALFORMED_OPERATION_INPUT;
- MISSING_OPERATION_INPUT;
- MISSING_BOUND_ARTIFACT;
- ARTIFACT_BINDING_MISMATCH;
- DIGEST_MISMATCH;
- CONFLICTING_INPUT;
- UNBOUND_INDEPENDENT_INPUT;
- COMPONENT_ARTIFACT_CONFLICT; and
- STALE_OPERATION_BASE.

Legacy invocations without --operation-input retain their current text/JSON
shape and explicit-input behavior.

## Ownership and replay

Identical operation input plus identical authoritative artifacts produces the
same route. The seam creates no operation store, changes no AdventureFinder
state, writes no pipeline artifact, and launches no command. Pipeline remains
the owner of artifact validation and deterministic transitions; AdventureFinder
remains the owner of operation persistence and cross-component coordination.
