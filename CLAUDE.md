# strategus-study-template — CLAUDE Instructions (Local Wrapper)

Shared baseline (applies first):

- `../CLAUDE.md`

> **This file is itself a template.** When a study is created from this repo,
> rewrite the "Local Overrides" section below to describe *that* study. Keep the
> wrapper shape: point at `../CLAUDE.md` as the shared baseline first, then record
> local overrides only. Never restate the shared baseline here.

## Local Overrides

- **This repo is a GitHub template, not a study.** It has no cohorts, no concept
  IDs, and no analysis. Do not add real concept IDs, cohort JSON, or study
  content to it — those belong in a repo created *from* it.
- **Layout is Strategus, not `synthea-omop-template`.** Root-level spec builder
  and runner, `inst/` for cohorts, `R/` is `source()`d rather than installed.
  There is **no `workflow/01–08`** and **no `synthea/`**.
- `config.R` / `study_params.yaml` are **optional and minimal**. Two of the four
  reference studies have neither. Add them only when a custom step or report
  needs schema names, cohort ids, or narrative metadata that Strategus itself
  does not — see `docs/STRATEGUS_CONVENTIONS.md` §11.
- **Strategus produces no manuscript figures.** Results are tables in a results
  schema, browsed via the OHDSI Shiny viewer — not the journal submission path.
  Manuscript figures only exist if the study adds a custom step / Word report
  (the `pad-amp-ed-desc` hybrid pattern). When it does, every figure must draw
  its series styling from `R/figure_style.R`: colour, linetype **and** shape,
  never colour alone, because journals print greyscale and equal-luminance hues
  collapse to one grey. See `docs/FIGURES.md`. If the study has no report step,
  nothing sources that file and it costs nothing.

### Before changing any module setting

Read `docs/STRATEGUS_CONVENTIONS.md`. The settings in
`CreateStrategusAnalysisSpecification.R` look like arbitrary defaults and are not
— each is a workaround for a bug that already broke a real run, and each carries
a conventions cross-reference in a comment. The recurring failure mode across all
of them is that **the run succeeds and produces plausible numbers that are
wrong**, so a passing run is not evidence a setting was safe to change.

The short list, in the order they bite:

| Setting | Never change without reading |
|---|---|
| `includeRiskFactors` / `includeDechallengeRechallenge` / `includeCaseSeries` = `FALSE` | §2 — Characterization 3.0.1 emits `IFNULL()`, not a SQL Server built-in |
| One `CharacterizationModule` spec per pipeline | §2.2 — repeated specs silently dedupe to the last one added |
| `runInclusionStatistics = FALSE` | §3 — crashes on a results schema containing a backslash (`DOMAIN\username`) |
| `CohortDiagnostics` scoped to analytic cohorts | §3.1 — diagnosing covariate cohorts was ~88% of runtime |
| `minPriorObservation = 0` | §2.1 — the 365d default silently drops patients |
| Two-part `database.schema` | §4 — a bare name is read as the database name |
| `EndStrategy StartDate+0` on covariate cohorts | §7.1 — load-bearing for FeatureExtraction/custom-step agreement |

### Pipeline

| Step | File | What it does |
|------|------|--------------|
| 0 | `scripts/render_cohort_sql.R` | circe JSON → `inst/sql/sql_server/*.sql`. Skips hand-authored SQL. |
| 1 | `CreateStrategusAnalysisSpecification.R` | Builds `inst/<studyName>AnalysisSpecification.json`. Re-run after any change to `inst/` or module settings. |
| 2 | `StrategusCodeToRun.R` | `Strategus::execute()` against the synthetic CDM overlay, then any post-execute repair and custom step. Fresh R session required. |

### Things that will bite you

- **Strategus never reads `inst/sql/sql_server/*.sql`.** The specification stores
  only each cohort's JSON, and CohortGeneratorModule re-renders SQL from that JSON
  with CirceR at execution time. For any cohort using the circe escape hatch,
  Strategus therefore generates the **placeholder**. A file-level sentinel guard
  protects the repo; only a post-`execute()` **behavioural assertion** protects
  the run. See `docs/CIRCE_ESCAPE_HATCH.md`.
- **`Strategus::createCdmExecutionSettings()` has no vocabulary-schema
  parameter.** Point it at a view-overlay schema that unions the clinical CDM with
  `omop_vocab`; query the physical schema from custom steps. Conventions §5.
- **A concept set can span OMOP domains.** A single-domain criterion silently
  captures half the definition — a real case returned **0 of 225 patients**
  because Wheelchair `4240470` is Device-domain. One primary criterion per domain.
  Conventions §7.2.
- **Reused `[DVI]` cohorts with `Limit: First` cannot be windowed** — the covariate
  becomes *ever prior to index*, which once collapsed a published 30-day window
  into a 10-year one with nothing erroring. Conventions §7.
- **VA-FI deficits are broad organ-system categories** — correct for VA-FI, wrong
  for a specific score item. Read the concept set before reusing.
- **The Characterization `attr_reason` patch is lost on every `renv::restore()`**
  and must be reapplied. Conventions §1.1.
- **Cohort ids:** real ATLAS id, or an id from the reserved local block for
  not-yet-in-ATLAS. Name everything `[DVI] …` from the start. Conventions §6
  holds the bounds and the §6.1 allocation ledger — claim a range there first,
  and never hard-code the bounds anywhere else (that is what went stale in
  2026-08-13's widening).

### Version Control Routing

Independent repository inside the workspace folder; **not** a submodule, and not
added to the workspace root's index.

| Remote | URL | What to push |
|--------|-----|-------------|
| `origin` | `git@github.com:Duke-Vascular-Informatics/strategus-study-template.git` | Full repository |

```bash
BRANCH=$(gh api user --jq .login)
git push origin "$BRANCH"   # then open a PR into main
```

Deployment to an institution's secure analytic environment is not part of this
repo — it is handled by that institution's own site-deploy repo (bucket 4). Never
`git subtree push` a bundle or do a bare `git push` of it to the site's GitLab.
