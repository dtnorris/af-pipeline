# AF Pipeline

AF Pipeline is the Adventure Finder operator workflow for registering Markdown
sources, approving catalog boundaries, preparing and reviewing scoring
evidence, and adopting a reviewed catalog workbook. It uses the established
`AfDataPipeline` Ruby namespace, command names, document formats and persisted
`af-data-pipeline` owner identifiers.

## Setup

Use Ruby 4.0, Bundler 4.0.17, Git, zstd and unzip. Install the locked Ruby
dependencies with `BUNDLE_FROZEN=true bundle install`. Obtain the public
components at the exact revisions in
[config/public_owners.tsv](config/public_owners.tsv). Export each selector in
the first column as the absolute path to its checkout. Run `bash bin/setup`
from this directory to check the selected revisions, clean checkouts and
dependencies.

Select an existing absolute, writable `AF_DATA_PIPELINE_DATA_ROOT` outside the
code checkout. Pipeline decisions, reviews, authority stores, release
candidates and result receipts belong there. Select the source and catalog
stores explicitly with `--source-root`, `--catalog-root` or the applicable
bound inputs. They can be separate private directories. Set `AF_PROJECT_STATE`
or pass `--manifest` for commands that resolve catalog roles. AF Workloads uses
its own explicit `--data-root` and scorer configuration. For routing through
`af-ingest-next`, set `AF_AFW_DATA_ROOT` for that AFW store. A caller selects
this code checkout with `AF_DATA_PIPELINE_ROOT`.

## Use

- Run `bin/af-source-intake` and `bin/af-source-register decide` and
  `apply-approved` for the guarded source workflow. The
  [library runbook](docs/LIBRARY_INGEST_RUNBOOK.md) describes source and
  boundary review. Its configuration examples require your selected roots.
- Use `bin/af-boundary-editorial` to record approval and freeze approved
  boundaries. Use `bin/af-data boundary-freeze-stage` with the operation
  projection and successor authorization. The
  [staging contract](docs/VERIFIED_STAGED_SUCCESSOR_V0.1.md) describes the
  workbook, apply report and receipt.
- Issue `bin/af-staged-scoring-authority` before AF Workloads compiles the
  exact staged workbook. The [AF Workloads staged-authority contract](https://github.com/dtnorris/af-workloads/blob/6b9b1fa80cd20c24851abea6e91362767c5af3f7/docs/AFW_FORWARD_WORKLOADS.md#staged-authority)
  describes what the compiler checks. After authorized execution, pass the AFW
  evidence manifest and the AFW data root to `bin/af-data prepare-workload-review`
  to build the review package. The
  [operator runbook](docs/operator-runbook.md) covers these handoffs and
  describes which artifacts must be retained for replay.
- Use `bin/af-standing-bulk-score-release` and `bin/af-final-release-package`
  to prepare an exact candidate. Record a reviewer decision with
  `bin/af-final-release-adoption` and run its `adopt` command. See the
  [final release contract](docs/FINAL_RELEASE_PACKAGE_V0.1.md) and
  [catalog roles](docs/PROJECT_STATE.md). Direct `promote catalog_head` is
  refused. Reviewed manual adoption remains available within the ordinary
  catalog-sheet review scope described in the project-state contract.

The candidate and review references remain tied to the original source,
registry, workbook, workload and evidence bytes. Exact adoption replay reports
`ALREADY_PROMOTED` when the reviewed transition already exists. Production
scoring and its provider configuration are separate operator-owned steps.

To try storing and retrieving a single evidence member independently of the
pipeline, follow the [public evidence walkthrough](https://github.com/dtnorris/af-evidence/blob/5e9e28dc981ddb670eddcaaf1e30357bbb152a0b/README.md#store-and-retrieve-your-first-member).
Use the pinned components under Setup for the pipeline workflow.

## Validate

With the pinned selections above, run `bundle exec rake test:contract` and
`bundle exec rake test:integration`. The repository Buildkite entry point
runs both against clean public owner checkouts. The
[mechanical journey test](test/integration/public_pipeline_test.rb) exercises
live public preflight, staging, workload and evidence publication, and cold
adoption replay, using invented external WLO and scoring results.

See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
