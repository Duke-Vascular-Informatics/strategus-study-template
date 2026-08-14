# Strategus conventions for this workspace

Every item below is a **defect that reached a real run** in one of
`pad-amp-ed-desc`, `pad-oler-aki-desc`, `pad-ler-ldl-desc` or `pad-amp-nhd-prog`,
and cost time to diagnose. None is hypothetical. The template ships with each
workaround already applied — this file explains *why*, so nobody "fixes" one
back.

Read this before changing `CreateStrategusAnalysisSpecification.R` or
`StrategusCodeToRun.R`.

> **The theme.** Almost every entry here shares one failure mode: **the run
> succeeds and produces plausible numbers that are wrong.** Strategus does not
> error on a mis-scoped cohort, a collapsed lookback window, or an outcome
> redefined as "all inpatient visits". Guard rails in this workspace are
> therefore mostly *behavioural assertions*, not type checks.

---

## 1. Package versions are pinned for a reason

| Package | Version | Why pinned |
|---|---|---|
| Strategus | **1.5.0** | 1.4.x and Characterization 3.0.1 are mutually incompatible and break the *spec build itself*. Resolved 2026-07-24 across `pad-oler-aki-desc` and `pad-ler-ldl-desc`. |
| Characterization | **3.0.1** | See the two bugs below. |
| CirceR | 1.3.3 (circe 1.11.3) | The circe capability limits in [CIRCE_ESCAPE_HATCH.md](CIRCE_ESCAPE_HATCH.md) were verified against this exact version. |

`renv.lock` in this template is the working set from `pad-amp-nhd-prog`. Run
`renv::restore()` before anything else.

### 1.0 First, create the project library directory, or renv will not activate

**In a fresh clone this must happen BEFORE `renv::restore()`:**

```bash
# Inside the dev container, from the repo root. The path is platform-specific;
# renv reports it as .libPaths()[1] once it activates.
mkdir -p renv/library/linux-ubuntu-noble/R-4.5/aarch64-unknown-linux-gnu renv/staging
```

Git does not track empty directories, so a fresh clone from this template has
`renv/activate.R` and `renv/settings.json` but **no `renv/library/`**. In this dev
container renv's bootstrap cannot create it, and the failure is quiet and
actively misleading:

```
# Bootstrapping renv 1.1.8
- Using renv 1.1.8 from global package cache
Warning: 'recursive' will be ignored as 'to' is not a single existing directory
Warning: Failed to find an renv installation: the project will not be loaded.
...
cannot rename '/usr/local/lib/R/site-library/renv' to '...renv-trash.../renv',
  reason 'Invalid cross-device link'
```

renv then falls back to the **system** library, and `renv::restore()` reports
`Successfully installed 182 packages` and **exit 0** while leaving the project
library empty. Everything afterwards silently resolves against
`/usr/local/lib/R/site-library`, whose versions are NOT the pinned ones — in
`pad-oler-ssi-prog` on 2026-08-13 that meant Characterization **4.0.0** loading
while this lockfile pins **3.0.1**.

That is worse than a hard failure, because 4.0.0 has both bugs below already
fixed upstream (`attr_reason` is already `VARCHAR(200)`, and zero shipped SQL
files contain `IFNULL`). Anyone checking the installed package in that state
would reasonably conclude §1.1 and §2 are stale and delete the workarounds — and
they are not stale, they are correct for the pinned 3.0.1, which does ship
`VARCHAR(50)` and does still have `IFNULL` in the two RiskFactor extraction
files.

**Verify activation rather than trusting restore's exit code:**

```bash
Rscript -e 'cat(.libPaths()[1], "\n")'   # must be renv/library/..., NOT site-library
```

### 1.1 The Characterization `attr_reason` patch — reapply after every `renv::restore()`

Characterization 3.0.1 declares `attr_reason VARCHAR(50)` in
`CreateTargetCohortTable.sql`; real attrition reasons overflow it. The fix is a
patch to the **installed package** in the renv cache, so it is **lost on every
`renv::restore()`** and must be reapplied. This is a still-open upstream bug, not
a local mistake.

```bash
# Widen attr_reason from VARCHAR(50) to VARCHAR(200) in the installed package.
Rscript -e 'p <- system.file("sql/sql_server/CreateTargetCohortTable.sql", package = "Characterization"); x <- readLines(p); writeLines(gsub("VARCHAR(50)", "VARCHAR(200)", x, fixed = TRUE), p); message("patched: ", p)'
```

If a run dies inside Characterization with a string-truncation error, this patch
has been reverted.

---

## 2. Characterization module settings that must not change

```r
includeRiskFactors            = FALSE
includeDechallengeRechallenge = FALSE
includeCaseSeries             = FALSE
```

Characterization 3.0.1 emits raw `IFNULL(...)` in those three SQL paths. `IFNULL`
is MySQL/SQLite, **not** a SQL Server built-in, so the run dies with:

```
'IFNULL' is not a recognized built-in function name
```

No study in this workspace has needed any of the three. If you genuinely need
one, you are fixing an upstream SQL-dialect bug first, not flipping a flag.

### 2.1 `minPriorObservation = 0`

The default 365 days silently drops patients. Vascular-surgery cohorts routinely
lack a year of prior observation, and synthetic Synthea patients almost always
do. Every study here sets `0`.

### 2.2 One `CharacterizationModule` specification per pipeline — never N

Adding **repeated** `CharacterizationModule` specifications that share the same
target/outcome IDs **silently deduplicates to whichever was added last**,
regardless of differing `covariateSettings` or `limitToFirstInNDays`. Confirmed
by three separate real-output runs in `pad-ler-ldl-desc` (2026-07-24); root cause
not isolated.

Nothing errors. You get one window's results labelled as if they were N windows.

If you need several characterization windows, the two plausible routes — neither
yet tested here — are N fully separate `Strategus::execute()` calls, or
hand-constructing `Characterization::createCharacterizationSettings()`. Do not
re-attempt the repeated-specification approach.

---

## 3. `runInclusionStatistics = FALSE` on CohortDiagnostics

`CohortGenerator::insertInclusionRuleNames` crashes on a results schema
containing a backslash — which is exactly what Duke PRCC issues
(`dhe\netid`). Inclusion attrition is still produced by the CohortGenerator
module, so nothing is lost.

### 3.1 Scope CohortDiagnostics to analytic cohorts only

Pass `cohortIds = c(targetId, outcomeIds)` — **not**
`cohortDefinitionSet$cohortId`.

Covariate cohorts are covariate *definitions*, not phenotypes to diagnose.
Running seven sub-analyses across each of `pad-amp-ed-desc`'s 30 VA-FI deficit
cohorts was **~88% of total diagnostics runtime for zero manuscript value**.
`runTemporalCohortCharacterization = FALSE` removes the single slowest
sub-analysis (~6 min on 32 cohorts).

Widen it deliberately for a one-off phenotype-validation pass, then narrow it
again.

### 3.2 Exclude any cohort whose JSON is a placeholder

If a cohort uses the [circe escape hatch](CIRCE_ESCAPE_HATCH.md), its JSON does
not describe its real logic. Concept-level diagnostics on it are not merely
useless, they are **actively misleading** — they describe the placeholder.

---

## 4. Schema names must be two-part `database.schema`

```r
cdmDatabaseSchema <- paste0(Sys.getenv("OMOP_DATABASE"), ".", "<schema>")
```

Given a bare schema name, CohortGenerator misreads it as the *database* name on
this SQL Server instance.

## 5. Strategus cannot take a separate vocabulary schema — use a view overlay

`Strategus::createCdmExecutionSettings()` has **no vocabulary-schema parameter**.
It expects clinical *and* vocabulary tables in one `cdmDatabaseSchema`. Our
synthetic CDMs keep vocabulary in the shared `omop_vocab`.

The fix is a read-only view-overlay schema that unions the two, built by
`synthetic_data/scripts/generate_overlay_schema.R`:

```bash
Rscript ../synthetic_data/scripts/generate_overlay_schema.R --dataset <registry_id> --schema <study>_cdm_shared
```

Point Strategus at the overlay. Query the **physical** schema directly from any
custom step or report — the overlay exists for Strategus's benefit, not yours.

Vocabulary tables are never redistributed through the registry; see
`docs/SETUP.md` step 7 in the workspace root.

---

## 6. Cohort ID allocation

| Range | Meaning |
|---|---|
| `179xxxx`–`189xxxx` | Assigned by the ATLAS demo instance. Use the real ATLAS id as the `cohort_id`. The observed span across this workspace runs 1,791,885 (`pad-oler-aki-desc`) to 1,890,979 (the 2026-07-22 `[DVI]` sweep) and grows over time — treat it as "whatever ATLAS hands you", not a fixed window. |
| **`9100001`–`9100999`** | **Local block.** Cohorts authored in-repo and **not yet in ATLAS**. Deliberately outside the ATLAS range so a future ATLAS assignment cannot collide. |

**This table is the only place the local block's literal bounds are written down.**
Everywhere else — this repo's other files, and every study repo's
`logic_description` provenance text — refers to it as "the reserved local id
block (see `STRATEGUS_CONVENTIONS.md` §6)". That indirection is deliberate:
the block was widened from `9100001`–`9100029` on 2026-08-13 and the old bound
had been copied verbatim into ~10 `logic_description` fields in
`pad-amp-nhd-prog/inst/Cohorts.csv`, plus four files here, all of which went
stale at once. Do not reintroduce a hard-coded range outside this table.

Headroom, so the next person does not have to re-derive it: ATLAS-demo's highest
assigned id as of the 2026-07-22 `[DVI]` sweep is 1,890,979, so the local block
sits ~7.2M clear of it, and `cohort_definition_id` is `INT` (max 2,147,483,647).
Widening further is cheap; there is no technical reason 999 slots is the limit.

### 6.1 Allocation ledger

One row per repo that has claimed part of the local block. **Add a row before
authoring your first local-block cohort.** This exists so allocation does not
require grepping every study repo to discover what is already taken — which is
how the near-collision that prompted the 2026-08-13 widening was found.

| Range | Repo | Notes |
|---|---|---|
| `9100001`–`9100011` | `pad-amp-nhd-prog` | NHD outcome (`9100001`, circe escape hatch) + 10 risk-score item cohorts |
| `9100101`–`9100199` | `pad-oler-ssi-prog` | Anderson SSI score items + wound-complication outcome subtypes |

Leave a gap between claims rather than packing them — a study that grows by one
cohort should not have to interleave into another study's range.

Rules:

- **Name every cohort `[DVI] …` from the start**, including local-block ones, so
  pushing one upstream later is not a rename exercise.
- Record `alignment_status: LOCAL ONLY -- NOT YET IN ATLAS` in the cohort's
  `logic_description`.
- ATLAS names cannot contain `\ / : * ? < > | "` — those characters break export.
- Creating a cohort in ATLAS is a **separate, explicit, user-initiated action**.
  The workspace `[DVI]` tooling is read-only, and its one guarded writer
  (`phenotype_library/scripts/push_dvi_concept_sets.R`) handles **concept sets,
  not cohorts**.

---

## 7. Reusing `[DVI]` cohorts: read the concept set first

Two traps, both hit in `pad-amp-nhd-prog`:

**`Limit: First` cannot be windowed.** The reused `[DVI]` VA-FI cohorts emit one
row per person at their *first-ever* record, so a lookback window cannot bind and
the covariate is effectively *ever prior to index*. Its sharpest consequence:
mFI-5's published **30-day** CHF window collapsed into sVQI-FS's **10-year** one,
so the two scores stopped differing on that item. Nothing errored.

**Every cohort you author here should be `Limit: All` at all three levels with
`EndStrategy StartDate+0`**, so it can answer a lookback-window question and
`cohort_end_date == cohort_start_date`.

**VA-FI deficits are deliberately broad organ-system categories.** VA-FI's
"Chronic lung disease" spans asthma, ILD and bronchiectasis; its "Peripheral
vascular disease" spans aortic aneurysm and venous thrombosis. Correct for
VA-FI — wrong for a COPD or PAD *score item*. A patient scoring an sVQI-FS PAD
point on a DVT is not what the instrument measures. That is why `pad-amp-nhd-prog`
authored cohorts `9100002`/`9100003` instead of reusing `1797958`/`1797955`.

### 7.1 `EndStrategy StartDate+0` is load-bearing

`FeatureExtraction::createCohortBasedCovariateSettings()` uses interval-**overlap**
semantics. A hand-written scoring step almost certainly uses **start-in-window**
semantics. The two coincide *only for point events*. Changing a covariate
cohort's EndStrategy silently desynchronises the two.

### 7.2 One concept set can span multiple OMOP domains

A single-domain criterion silently captures half the definition. Real cases:

- `pad-amp-nhd-prog` cohort `9100005`: Frailty `4086506` is **Condition**,
  Impaired mobility `4306934` is **Observation** → two primary criteria.
- Cohort `9100006` (ambulatory deficit): Observation + Procedure + Device →
  three primary criteria. Querying one domain returned **0 of 225 patients**,
  because Wheelchair `4240470` is Device-domain.

In circe, express this as one primary criterion **per domain**, OR'd. That is the
declarative replacement for a pipeline's `domain = 'auto'` union.

### 7.3 Unit variants need their own criterion

circe cannot do arithmetic, so a measurement threshold needs one criterion per
unit. `pad-amp-nhd-prog` cohort `9100008` carries `< 10 g/dL` **and**
`< 100 g/L`; omitting the second silently drops any site reporting haemoglobin in
g/L. Sex-specific thresholds multiply out the same way (cohort `9100009`: 4
criteria = {male, female} × {g/dL, g/L}).

---

## 8. CohortIncidenceModule does not censor

`PERSONS_AT_RISK` is the **full cohort N at every time-at-risk**, regardless of
follow-up length — it never censors patients lost to follow-up. For a cohort with
variable observation length, cumulative-incidence proportions are therefore
**systematically optimistic at longer windows**.

`pad-amp-ed-desc` moved its Table 2a to a custom Kaplan-Meier analysis
(`survival::survfit`) for exactly this reason (2026-07-29) and left
CohortIncidenceModule running only for its own QA value.

Use it for incidence *rates*. Do not use it for cumulative incidence unless
follow-up is fixed by construction.

### 8.1 Stratification suppresses small cohorts to nothing

With 361 target patients, `byYear × byGender × byAge` suppressed nearly every
cell to the `minCellCount` sentinel — and stratified output **cannot be
re-aggregated** to an overall rate (`byYear` also splits person-time across
calendar years, so `PERSONS_AT_RISK` stops counting distinct persons). Default to
`createStrataSettings(byYear = FALSE, byGender = FALSE, byAge = FALSE)`.

---

## 9. `cleanWindow = 0` for descriptive cumulative incidence

A nonzero clean window drops patients who had the outcome *phenotype* in the
prior window from "at risk" — the incident/new-user framing. A descriptive
"what proportion of this cohort experienced X" table needs the **full cohort** as
denominator. Set `cleanWindow = 0` and say so in a comment, because the default
is not obviously wrong.

## 10. Modules have no enabled flag — gate the `add`, not the object

Strategus has no per-module `enabled` switch: a module either is or is not in the
specification. To scaffold an arm without running it, construct the spec
unconditionally and gate `addModuleSpecifications()` behind a constant. That
keeps the intended design reviewable, type-checked and diffable instead of
commented out.

Do **not** try to neutralise a PLP arm by passing `modelSettings = NULL` —
`PatientLevelPrediction::createModelDesign()` validates the class and rejects
`NULL` outright. A real setting must be supplied for the object to construct, so
**the gate is the only thing keeping it from fitting a model.**

---

## 11. Where things live

| Question | Authority |
|---|---|
| Cohort logic | `inst/cohorts/<id>.json` (circe), rendered to `inst/sql/sql_server/<id>.sql` |
| Cohort manifest + per-cohort rationale | `inst/Cohorts.csv` → `logic_description` |
| Module settings | `CreateStrategusAnalysisSpecification.R` |
| Verified concept sets, shared across studies | `../phenotype_library/catalog.yaml` |
| Synthetic CDM datasets | `../synthetic_data/registry.yaml` |
| Study-specific narrative metadata for a custom step/report | `config.R` + `study_params.yaml` (optional — see below) |

There is **no `workflow/01–08`** and no `synthea/` in a Strategus study. Cohort
logic lives in `inst/`, not in `cohorts/*.sql`.

`config.R` / `study_params.yaml` are **optional and minimal**. `pad-oler-aki-desc`
and `pad-ler-ldl-desc` have neither. `pad-amp-ed-desc` and `pad-amp-nhd-prog` have
both, purely to hand a custom step and Word report the schema names, `[DVI]`
cohort ids and narrative metadata that Strategus itself does not need.
`StrategusCodeToRun.R` builds its own `connectionDetails` independently either
way. Add them only when a custom step needs them.

### 11.1 `inst/Cohorts.csv` — the manifest

```
atlas_id,cohort_id,cohort_name,logic_description,generate_stats
```

`logic_description` is not a label — it is the **durable rationale**, and in this
workspace it is expected to be long. Record: what role the cohort plays
(TARGET / OUTCOME / COVARIATE), whether it was reused or authored and *why*,
which concept IDs with their Rule 1 provenance, any `Limit`/`EndStrategy`
consequence, `alignment_status`, and what would falsify the choice. See
`pad-amp-nhd-prog/inst/Cohorts.csv` for the reference standard.

### 11.2 Never resolve study identity from a file path

An inherited pipeline selected an anemia threshold with `grepl("vqifs", <path>)`,
which also matched an *output folder*. Key on an explicit config field that
defaults to `NULL` so a forgotten assignment fails loudly.

Where one covariate name means two different things — `anemia` at two thresholds,
`chf` at two windows — key the mapping on the **pair** `(score_id, item_id)`,
never on the covariate name alone.

---

## 12. Rule 1 still applies, unchanged

Cohorts and concept sets do not exempt you from the workspace's concept-ID rules.
Every concept ID entering a cohort JSON must pass the three-tier lookup and carry
a `[vocab query]` tag. Check `../phenotype_library/catalog.yaml` **first** — a
`status: verified` entry is copied, not re-queried — and add the study to that
entry's `used_by`.

A measured fact about a *shared* concept set (its true descendant count, an
overlap with another set, a scope mismatch against a published definition)
belongs in `catalog.yaml`, not only in your study's docs. The next study to reuse
that entry reads the catalog, not your repo.
