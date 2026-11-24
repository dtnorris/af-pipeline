# AdventureFinder Result Record v0.1

Status: **draft implementation contract**

Schema identifier: `af-result-record/v0.1`.

## Required fields

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | string | `af-result-record/v0.1` |
| `adventure_id` | string | Canonical `ADV-####` ID |
| `dimension` | string | Canonical dimension name |
| `score` | integer | 1–5 score |
| `reason` | string | Complete scoring rationale |

Optional provenance may include `result_id`, `run_id`, `adventure_name`, `model`, `provider`, prompt/schema versions or hashes, producer git SHA, corpus version, raw response path, timestamp, and metadata.

Normalized records additionally receive `source_path`, `source_sha256`, and `adapter`.

The v0.1 validator intentionally covers 1–5 scored dimensions first. Different value domains (for example Levels or session-band structures) should receive explicit future schemas/adapters rather than weakening this contract.
