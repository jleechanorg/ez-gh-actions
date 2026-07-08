WorldArchitect requirements snapshots for the ezgha runner image wheelhouse.

These files are copied from the local WorldArchitect checkout paths named in the
Phase 1 cold-start plan:

- `/tmp/worldai-check/mvp_site/requirements.txt`
- `/tmp/worldai-check/automation/requirements.txt`
- `/tmp/worldai-check/testing_mcp/infra/requirements-infra.txt`
- `/tmp/worldai-check/text_processor/requirements.txt`

Docker builds cannot `COPY` files from outside their build context on a real CI
runner, so this directory is the committed build-context snapshot. Refresh it
whenever the WorldArchitect requirements change, then rebuild
`ezgha-runner:latest`.

`automation/requirements.txt` contains `-e ./automation`; the adjacent
`automation/pyproject.toml` snapshot lets `pip wheel` resolve that editable
package's declared dependencies while building the offline wheelhouse.
