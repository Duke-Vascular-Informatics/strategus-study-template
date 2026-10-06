# strategus-study-template

GitHub template repository for **Strategus-based** observational studies on an
OMOP CDM v5.4 SQL Server database in a
[charon](https://github.com/Duke-Vascular-Informatics/charon)-based workspace.

Use this when cohort logic belongs in **declarative circe cohort definitions**
(`inst/cohorts/*.json`) executed by the OHDSI HADES
[Strategus](https://ohdsi.github.io/Strategus/) framework.

This is the template for every analysis repo. If the study needs a synthetic
dataset to develop against, generate it in a separate `-synth` repo created from
[`synthea-omop-template`](https://github.com/Duke-Vascular-Informatics/synthea-omop-template)
(Synthea generation, ETL, QC only — no analysis).

---

## Lineage

This template layers on the upstream OHDSI
[`ohdsi-studies/StrategusStudyRepoTemplate`](https://github.com/ohdsi-studies/StrategusStudyRepoTemplate)
rather than replacing it. Its guides are vendored unchanged in `docs/`:

| File | From | Read it for |
|---|---|---|
| `docs/UsingThisTemplate.md` | upstream OHDSI | Network-study roles, ATLAS cohort download, results data model, EvidenceSynthesis |
| `docs/StudyExecution.md` | upstream OHDSI | What a participating **site** runs |
| **`docs/STRATEGUS_CONVENTIONS.md`** | **this workspace** | **The workspace layer. Read this first.** |
| **`docs/CIRCE_ESCAPE_HATCH.md`** | **this workspace** | What to do when circe cannot express a cohort |

`STRATEGUS_CONVENTIONS.md` is the reason this template exists. Every item in it is
a defect that reached a real run in one of four studies, with the workaround
already applied here and the rationale recorded so nobody reverts it. Reading it
takes ten minutes; rediscovering it took months.

## What this template ships

```
CreateStrategusAnalysisSpecification.R   step 1 — build the analysis spec
StrategusCodeToRun.R                     step 2 — devcontainer synthetic pre-flight
scripts/render_cohort_sql.R              step 0 — circe JSON -> OHDSI SQL
inst/Cohorts.csv                         cohort manifest + rationale
inst/cohorts/                            circe cohort expressions
inst/sql/sql_server/                     rendered SQL (CohortGenerator artifact)
docs/                                    upstream OHDSI guides + workspace conventions
CHECKLIST.md                             new study (Path A) / conversion (Path B)
renv.lock                                Strategus 1.5.0, pinned — 209 packages
```

Module settings arrive with the known-good configuration already applied:
Characterization's three SQL-Server-incompatible sub-analyses disabled,
`runInclusionStatistics = FALSE` for Duke PRCC's backslash schema,
`minPriorObservation = 0`, CohortDiagnostics scoped to analytic cohorts,
CohortIncidence unstratified. Each carries a comment and a conventions
cross-reference. **They are workarounds, not preferences — do not flip them
without reading why.**

## The report is a separate repo

A repo created from this template is the **analysis core only** (bucket 2 of
[charon's "Multi-Repo Analysis Pipeline" section](https://github.com/Duke-Vascular-Informatics/charon#multi-repo-analysis-pipeline)) and must stay
Strategus-faithful: no `ggplot2`, `officer`, or `flextable` import for
reporting purposes, ever, and no Word document built from it directly. The
manuscript report — which tables, which figures, the clinical narrative —
belongs in a sibling repo, `<study>-report`, created from
[`omop-report-template`](https://github.com/Duke-Vascular-Informatics/omop-report-template)
and cloned next to this one. It renders from this repo's result artifacts
only (no database, no VPN, no credentials) via that repo's
`R/extract_report_inputs.R`-equivalent writing `output/report_inputs/`.

Create both repos together when starting a new study — see Path A in this
repo's `CHECKLIST.md` and `omop-report-template`'s own `CHECKLIST.md`.

## Quick start

```bash
# 1. Create your repo from this template, then clone it as a sibling of the
#    other study repos in the workspace folder.
BRANCH=$(gh api user --jq .login)
git checkout -b "$BRANCH"

# 2. Create the project library FIRST. Git does not track empty directories, so a
#    fresh clone has no renv/library/ — and without it renv silently falls back to
#    the system library, where the package versions are NOT the pinned ones.
#    restore() still exits 0 and reports success. Conventions §1.0.
mkdir -p renv/library/linux-ubuntu-noble/R-4.5/aarch64-unknown-linux-gnu renv/staging

# 3. Restore the pinned environment, then CHECK WHICH LIBRARY IT USED before
#    trusting it. Must print renv/library/..., not /usr/local/lib/R/site-library.
Rscript -e 'renv::restore()'
Rscript -e 'cat(.libPaths()[1], "\n")'

# 4. Reapply the Characterization patch (conventions §1.1 — lost on every
#    renv::restore). Confirm it landed in the PROJECT library, not the system one.
Rscript -e 'p <- system.file("sql/sql_server/CreateTargetCohortTable.sql", package = "Characterization"); x <- readLines(p); writeLines(gsub("VARCHAR(50)", "VARCHAR(200)", x, fixed = TRUE), p); message("patched: ", p)'

# 5. Work through CHECKLIST.md — Path A for a new study, Path B to convert an
#    existing synthea-omop-template study.

# 6. Then the pipeline, inside the dev container:
Rscript scripts/render_cohort_sql.R
Rscript CreateStrategusAnalysisSpecification.R
docker exec -e IN_DEV_CONTAINER=true -w /workspace/<study> \
  omop_dev-devcontainer-1 Rscript StrategusCodeToRun.R
```

Find everything that needs a decision:

```bash
grep -rn "TODO \[STUDY\]" . --include="*.R" --include="*.csv"
```

## Reference implementations

Read a real one alongside the template. They differ deliberately:

| Repo | Shape | Read it for |
|---|---|---|
| `pad-oler-aki-desc` | Pure Strategus, no `config.R` | The minimal case |
| `pad-ler-ldl-desc` | Pure Strategus, circe-authored cohorts | Circe JSON authored in-repo rather than exported from ATLAS |
| `pad-amp-ed-desc` | **Hybrid** — Strategus + custom step + Word report | The `synthea-omop-template` → Strategus **conversion** precedent, and a custom Kaplan-Meier step replacing CohortIncidence |
| `pad-amp-nhd-prog` | Hybrid, integer risk scores | The **circe escape hatch** (cohort `9100001`), the local cohort-id block, and the reference standard for `inst/Cohorts.csv` rationale |

## Non-negotiables

- **No reporting imports in this repo, ever.** `ggplot2`, `officer`, and
  `flextable` belong in the sibling `<study>-report` repo (see above), not
  here — an analysis-core repo importing any of them for reporting purposes
  is the thing to notice and undo, not a style preference to skip.
- **Rule 1 applies unchanged.** Every concept ID entering a cohort JSON passes the
  three-tier lookup and carries `[vocab query]`. Check
  `../phenotype_library/catalog.yaml` first.
- **Run everything in the dev container**, never on the host.
- **Push to your own branch**, then open a PR into `main`. Never push to `main`,
  never to another collaborator's branch.
- **No PHI on disk.** Outputs are aggregate only; `results/` is gitignored.
- **Never make an OSF project public** or mint a DOI — manual, post-approval,
  human-only steps.
- **The `[DVI]` tooling is read-only.** Creating an ATLAS cohort is a separate,
  explicit, user-initiated action.

## License

Copyright 2026 Duke University. All Rights Reserved. The software is hereby licensed under the GNU GPL License v2 (see [LICENSE](LICENSE)).
