# Checklist

Two paths. **Path A** starts a new Strategus study. **Path B** converts an
existing `synthea-omop-template` study — that is the harder one, and the one with
a real precedent (`pad-amp-ed-desc`, converted 2026-07).

Read [docs/STRATEGUS_CONVENTIONS.md](docs/STRATEGUS_CONVENTIONS.md) before either.

---

## Path A — new Strategus study

### 0. Environment
- [ ] Repo created from this template; cloned into the workspace folder as a
      sibling of the other study repos (**not** a submodule, **not** added to the
      workspace root's index)
- [ ] Working on your own branch: `BRANCH=$(gh api user --jq .login)`
- [ ] **`renv/library/<platform>/` + `renv/staging` created FIRST** — git does not
      track empty dirs, so a fresh clone has none and renv silently falls back to
      the system library. Conventions §1.0
- [ ] `renv::restore()` completed
- [ ] **Activation verified, not assumed:** `Rscript -e 'cat(.libPaths()[1])'` shows
      `renv/library/...`, not `/usr/local/lib/R/site-library`. `restore()` exits 0
      and claims success even when it installed into the wrong library
- [ ] Characterization `attr_reason` patch reapplied — conventions §1.1
- [ ] `docs/UsingThisTemplate.md` / `docs/StudyExecution.md` (upstream OHDSI) skimmed

### 1. Concept sets — Rule 1, before any cohort JSON exists
- [ ] Tier 1a: `Rscript ../phenotype_library/scripts/check_pl.R "<term>"`
- [ ] Tier 1b: `Rscript ../phenotype_library/scripts/check_dvi.R "<term>"` —
      **authoritative** for this workspace
- [ ] Tier 2: `Rscript ../phenotype_library/scripts/lookup_catalog.R "<term>"`
- [ ] Tier 3 only if 1 and 2 both miss:
      `Rscript ../scripts/concept_lookup.R "<term>" [domain]`
- [ ] Every concept ID tagged `[vocab query]` with its query date
- [ ] New concept sets registered in `../phenotype_library/catalog.yaml`; this
      study added to each entry's `used_by`
- [ ] `Rscript ../phenotype_library/scripts/check_overlap.R --concept-ids <ids>`
      run before registering anything as new

### 2. Cohorts
- [ ] Cohort ids allocated — real ATLAS id, or an id from the reserved local
      block for not-yet-in-ATLAS (conventions §6 for the bounds)
- [ ] **Range claimed in the conventions §6.1 allocation ledger** before any
      local-block cohort is authored, so the next study does not have to grep
      every repo to find what is taken
- [ ] Every cohort named `[DVI] …`, with no `\ / : * ? < > | "` in the name
- [ ] For each reused `[DVI]` cohort: **concept set actually read**, and its
      `Limit`/`EndStrategy` consequences recorded (conventions §7)
- [ ] Cohorts authored here are `Limit: All` at all three levels with
      `EndStrategy StartDate+0`
- [ ] Concept sets spanning multiple OMOP domains have **one primary criterion
      per domain** (conventions §7.2)
- [ ] Measurement thresholds have one criterion **per unit** (conventions §7.3)
- [ ] `inst/Cohorts.csv` filled in — `logic_description` per the template row
- [ ] Any cohort circe cannot express follows
      [docs/CIRCE_ESCAPE_HATCH.md](docs/CIRCE_ESCAPE_HATCH.md) **in full**,
      including the post-`execute()` behavioural assertion
- [ ] `Rscript scripts/render_cohort_sql.R`

### 3. Specification
- [ ] Every `TODO [STUDY]` in `CreateStrategusAnalysisSpecification.R` resolved
      (`grep -n "TODO \[STUDY\]" *.R`)
- [ ] Unused module blocks **deleted**, not left inert
- [ ] Exactly **one** `CharacterizationModule` specification (conventions §2.2)
- [ ] `CohortDiagnostics` scoped to analytic cohorts only, hand-authored cohorts
      excluded
- [ ] `Rscript CreateStrategusAnalysisSpecification.R` — clean

### 4. Synthetic pre-flight
- [ ] Synthetic dataset chosen: `Rscript ../synthetic_data/scripts/lookup_dataset.R "<term>"`
      — check the registry before generating anything new
- [ ] **This study registered as a consumer** of that dataset: listed in the `-synth`
      repo's `consumers.yaml` (and under `used_by` in `../synthetic_data/registry.yaml`,
      `consumes_dataset` in `../studies.yaml`). The `-synth` repo then checks this study's
      own cohorts against the Synthea module before generating data and against the final
      data (so regenerating the dataset cannot silently break this study)
- [ ] `targetId` and `outcomeIds` in `CreateStrategusAnalysisSpecification.R` are plain
      literal assignments (`targetId <- 9100011L`, `outcomeIds <- c(...)`); the `-synth`
      QC reads them from that file. If you build them programmatically, state the ids in
      the `-synth` repo's `consumers.yaml` instead
- [ ] If the analysis depends on **discharge disposition**: `discharge_disposition_check: true`
      on this study in `consumers.yaml` (its cohort is hand-authored SQL that Strategus
      never runs, so the cohort check cannot see whether the dataset carries dispositions)
- [ ] Cohorts that Synthea cannot generate are declared `expected_empty` there; anything
      else that comes back empty is a gap in the module to fix, not to hide
- [ ] View-overlay schema built (conventions §5)
- [ ] Every `TODO [STUDY]` in `StrategusCodeToRun.R` resolved; `cohortTableName`
      unique across studies sharing the results schema
- [ ] Run inside the dev container, fresh R session
- [ ] **Cohort counts sanity-checked against expectations, not just non-zero.**
      A count of 0, or one suspiciously close to the full cohort N, is the
      signature of a domain-span bug or a surviving placeholder

### 5. Real run
- [ ] IRB scope confirmed
- [ ] Deployment bundle built and pushed by your institution's **site-deploy repo**
      (bucket 4) — not from this repo. Any bundle remote is created by a human
- [ ] Never `git subtree push` the bundle, never a bare `git push` of it to the
      site's GitLab

### 6. Register the study
- [ ] Added to `../studies.yaml`
- [ ] Added to the layout table in the workspace root `CLAUDE.md`
- [ ] `CLAUDE.md` written as a **local wrapper** — first line points at
      `../CLAUDE.md` as the shared baseline, then local overrides only
- [ ] OSF protocol project created if the study has one (**private**;
      `Rscript ../osf/osf_sync.R`)

---

## Path B — converting a `synthea-omop-template` study

The conversion moves cohort logic from imperative R + `cohorts/*.sql` into
declarative circe JSON. Budget for the fact that **some of it will not translate**
— that is expected, not failure.

### B1. Before touching anything: find what circe cannot express
This is the step that determines how hard the conversion is, so do it first.
- [ ] Every cohort and covariate definition inventoried
- [ ] Each one triaged against
      [docs/CIRCE_ESCAPE_HATCH.md](docs/CIRCE_ESCAPE_HATCH.md) §1
- [ ] Anything that classifies on **timing and antecedent** rather than set
      membership flagged — a code meaning "index procedure" or "re-operation"
      depending on what preceded it, and how long before, **cannot** be
      expressed in circe
- [ ] Any look-**forward** rule flagged (e.g. "if the next procedure is >3 weeks
      out *or absent*, recode")
- [ ] Any arithmetic on measurement values flagged (unit conversion, ratios,
      `within ±2 SD`)
- [ ] Any `domain = 'auto'` covariate flagged — it becomes one primary criterion
      per domain (conventions §7.2), and this is the highest-risk translation in
      the conversion. In `pad-amp-nhd-val` a single-domain query returned
      **0 of 225 patients**
- [ ] Decision recorded per definition: **circe** or **escape hatch**

### B2. Port
- [ ] `covariates/covariate_concepts.csv` rows → concept sets inside cohort JSON
- [ ] Concept sets cross-checked against `../phenotype_library/catalog.yaml`;
      catalog updated where this study measured something new about a **shared**
      set (its true descendant count, an overlap, a scope mismatch)
- [ ] **Exclusions checked.** `covariate_concepts.csv` is additive-only, so a
      definition needing "X without Y" was previously approximated. circe *can*
      express exclusions — so the conversion is the moment to fix it, and to
      record the prevalence change it causes
- [ ] `@outcome_cohort_id` renamed to `@target_cohort_id` in any ported SQL —
      CohortGenerator renders with `warnOnMissingParameters = FALSE`, so a
      leftover reaches SQL Server un-substituted with no warning
      (escape hatch §3.1)
- [ ] Study dates dropped from ported cohort SQL — CohortGenerator supplies none

### B3. Retire the old scaffold
- [ ] `workflow/01–08` removed
- [ ] `cohorts/*.sql` removed (or moved under the escape hatch)
- [ ] `synthea/`, `external/synthea` removed — synthetic data comes from a
      companion `-synth` repo via `../synthetic_data/registry.yaml`
- [ ] Old template docs moved to `template_docs/` for reference, and
      `CLAUDE.md` + `README.md` declared the operational source of truth
- [ ] `config.R` / `study_params.yaml` either deleted or **reduced to a minimal
      layer** — keep them only to hand a custom step or report the schema names,
      cohort ids and narrative metadata Strategus does not need (conventions §11)
- [ ] Any bundle-building step removed from the study repo — deployment belongs
      to your institution's site-deploy repo (bucket 4)

### B4. Prove the conversion didn't change the science
This is the part that is easy to skip and expensive to skip.
- [ ] Per-cohort counts compared **old pipeline vs new**, on the same synthetic
      dataset
- [ ] Every difference explained, not merely noted. Expected sources: a fixed
      exclusion, a domain-span fix, a `Limit: First` window collapse
- [ ] Any covariate whose count moved materially recorded in the study's decision
      log with its direction of bias
- [ ] A regression test kept for the highest-risk translation (see
      `pad-amp-nhd-prog/tests/regression/test_cohort_vs_domain_covariates.R`)

### B5. Then Path A steps 3–6.
