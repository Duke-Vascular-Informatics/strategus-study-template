# When circe cannot express your cohort

Most cohorts belong in circe JSON. Some cannot be expressed there at all, and the
failure mode is dangerous: **circe will happily build a cohort that is not the one
you meant, and the run will produce plausible numbers.**

This file is the sanctioned procedure for that case. Do not invent a different
one, and do not force a definition into circe that it cannot hold.

---

## 1. First, confirm circe really can't do it

Check the criterion's attribute set by class inspection rather than by reading
docs or guessing:

```r
# List every attribute circe's VisitOccurrence criterion supports.
rJava::.jcall(
  rJava::.jnew("org.ohdsi.circe.cohortdefinition.VisitOccurrence"),
  "Ljava/lang/Class;", "getClass"
)$getDeclaredFields() |>
  vapply(function(f) f$getName(), character(1))
```

Verified 2026-08-02 against circe 1.11.3 (inside CirceR 1.3.3),
`VisitOccurrence` supports exactly: `CodesetId`, `First`,
`OccurrenceStartDate`, `OccurrenceEndDate`, `VisitType`, `VisitSourceConcept`,
`VisitLength`, `Gender`, `ProviderSpecialty`, `PlaceOfService`,
`PlaceOfServiceLocation`.

Notably **absent**: `discharged_to_concept_id`. Any discharge-disposition cohort
(non-home discharge, disposition-to-SNF, mortality-at-discharge) is therefore
outside circe.

### Known-outside-circe patterns

| Pattern | Why |
|---|---|
| Discharge disposition | No `discharged_to_concept_id` attribute (above). |
| Classification by **timing and antecedent** rather than set membership | circe classifies on `IN (<codeset>)`. A code that means "index procedure" or "re-operation" depending on what preceded it, and how long before, cannot be expressed. |
| Look-*forward* recoding | e.g. "if the next procedure is >3 weeks out **or absent**, recode this event". |
| Arithmetic on measurement values | Unit conversion, ratios, distributional filters (`within ±2 SD`). Enumerate discrete criteria instead — see conventions §7.3. |
| Dynamic vocabulary resolution at query time | e.g. a `Maps to` CTE resolving source codes to standard targets during the query. |

If your cohort is one of these, continue. If it is not, express it in circe.

---

## 2. The pattern: authoritative SQL + placeholder JSON + two guards

`CohortGenerator::getCohortDefinitionSet()` requires one JSON per manifest row, so
you cannot simply omit it. The pattern is therefore:

1. **`inst/sql/sql_server/<id>.sql` is hand-authored and AUTHORITATIVE.**
2. **`inst/cohorts/<id>.json` is a deliberate placeholder** that exists only to
   satisfy `getCohortDefinitionSet()`.
3. **`inst/Cohorts.csv`'s `logic_description` says all of this**, in full, at the
   top of that cohort's entry.
4. **Two independent guards** stop the placeholder from being mistaken for the
   definition.

### ⛔ The critical thing to understand

**Strategus never reads your `.sql` file.**

The analysis specification stores only each cohort's **JSON** —
`sharedResources$cohortDefinitions` rows carry `cohortId`, `cohortName`,
`cohortDefinition`, and no `sql`. The CohortGeneratorModule **re-renders SQL from
the JSON with CirceR at execution time**. So Strategus always generates the
**placeholder**.

That is not an oversight to be fixed by a file-level check; it is a property of
Strategus. It means:

> A file-level guard protects the *repo*. Only a **behavioural assertion**
> protects the *run*.

In `pad-amp-nhd-prog` this was found the hard way: the first full run reported
every metric as `NA`, because the placeholder made all 195 target patients
"have" the outcome.

---

## 3. Guard 1 — the sentinel, in the spec builder

Protects the file. Fails loudly if a CirceR re-render has clobbered the
hand-authored SQL. Put it in `CreateStrategusAnalysisSpecification.R`, keyed to a
string that only the real logic contains:

```r
# TODO [STUDY]: set these to your hand-authored cohort's id and a string that
# appears ONLY in the real logic (a distinctive CTE name works well).
handAuthoredId <- 9100001L
sentinel       <- "UB04 Pt dis status"

sqlPath <- file.path("inst", "sql", "sql_server", paste0(handAuthoredId, ".sql"))
if (!file.exists(sqlPath)) {
  stop("*** ", sqlPath, " is missing. This cohort is hand-authored SQL and ",
       "cannot be regenerated from its placeholder JSON. Restore it from git. ***")
}
sqlText <- readLines(sqlPath, warn = FALSE)
if (!any(grepl(sentinel, sqlText, fixed = TRUE))) {
  stop("*** ", sqlPath, " has lost its '", sentinel, "' logic.\n",
       "    Almost certainly overwritten by a CirceR re-render from the ",
       "placeholder JSON, which would silently redefine this cohort.\n",
       "    Restore from git; do not regenerate. ***")
}
message("[spec] Sentinel guard passed for cohort ", handAuthoredId, ".")
```

### 3.1 Also check for stale parameter names

CohortGenerator supplies `@target_cohort_id` and renders with
`warnOnMissingParameters = FALSE` — so a leftover `@outcome_cohort_id` reaches
SQL Server **un-substituted**, with no warning. If your SQL was ported from a
`synthea-omop-template` study, check for it:

```r
if (any(grepl("@outcome_cohort_id", sqlText, fixed = TRUE))) {
  stop("*** ", sqlPath, " still references @outcome_cohort_id. CohortGenerator ",
       "supplies @target_cohort_id and will not warn. ***")
}
```

## 4. Guard 2 — the behavioural assertion, after `execute()`

This is the one that actually protects the study. Immediately after
`Strategus::execute()`, replace the placeholder-generated cohort with the real
definition, then **assert something that would be false if the placeholder had
survived**:

```r
# R/generate_<name>_cohort.R — run AFTER Strategus::execute().
# Replaces the placeholder-generated cohort with the hand-authored definition.
generateCohort <- function(connectionDetails, cdmDatabaseSchema,
                           workDatabaseSchema, cohortTable, cohortId) {
  # ... execute inst/sql/sql_server/<cohortId>.sql, DELETE then INSERT ...

  # BEHAVIOURAL ASSERTION — the real protection.
  # The placeholder entered as ALL inpatient visits, so it produced an event for
  # essentially every target patient. A real outcome must be a strict subset.
  nEvents <- <count rows for cohortId>
  nUpper  <- <count all inpatient visits>
  if (nEvents >= nUpper) {
    stop("*** Cohort ", cohortId, " has ", nEvents, " events against an upper ",
         "bound of ", nUpper, ". The placeholder definition appears to still be ",
         "in the cohort table — the hand-authored SQL did not take effect. ***")
  }
  message("[cohort ", cohortId, "] ", nEvents, " events (bound ", nUpper, ") - OK")
}
```

Pick an assertion that the placeholder would *fail*. "Row count > 0" is not one —
the placeholder produces plenty of rows.

## 5. Guard 3 — teach the renderer to skip it

`scripts/render_cohort_sql.R` ships with a `HAND_AUTHORED` vector. Add your
cohort id:

```r
HAND_AUTHORED <- c(9100001L)   # never regenerate these from JSON
```

## 6. Exclude it from concept-level diagnostics

Its JSON does not describe its logic, so any concept-level diagnostic reports the
**placeholder**. Leave it out of `CohortDiagnostics`' `cohortIds`, and disable
outcome-dependent Characterization sub-analyses that would read it
(`includeTimeToEvent = FALSE` if it is the only outcome). See conventions §3.2.

---

## 7. Checklist

- [ ] Confirmed circe cannot express it, by class inspection — recorded the
      circe/CirceR version and the date
- [ ] `inst/sql/sql_server/<id>.sql` hand-authored; header states it is
      authoritative and must never be regenerated
- [ ] `inst/cohorts/<id>.json` placeholder; header states what it degenerates to
- [ ] `inst/Cohorts.csv` `logic_description` records all of the above
- [ ] Guard 1: sentinel check in the spec builder
- [ ] Guard 1.1: no stale `@outcome_cohort_id`
- [ ] Guard 2: post-`execute()` replacement **with a behavioural assertion**
- [ ] Guard 3: id added to `HAND_AUTHORED` in `scripts/render_cohort_sql.R`
- [ ] Excluded from `CohortDiagnostics$cohortIds`
- [ ] Outcome-dependent Characterization sub-analyses that would read it disabled
