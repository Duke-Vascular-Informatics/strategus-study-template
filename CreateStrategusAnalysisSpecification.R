################################################################################
# CreateStrategusAnalysisSpecification.R  —  PIPELINE STEP 1
#
# PURPOSE
#   Build this study's Strategus (v1.5.0) analysis specification from the cohort
#   definitions in inst/ plus the module settings below.
#
# INPUTS
#   inst/Cohorts.csv          — cohort manifest (see docs/STRATEGUS_CONVENTIONS.md §11.1)
#   inst/cohorts/<id>.json    — circe cohort expressions
#   inst/sql/sql_server/<id>.sql — rendered by scripts/render_cohort_sql.R
#
# OUTPUT
#   inst/<studyName>AnalysisSpecification.json   — consumed by StrategusCodeToRun.R
#
# PIPELINE
#   0  scripts/render_cohort_sql.R                    -> inst/sql/sql_server/*.sql
#   1  THIS SCRIPT                                    -> inst/<studyName>...json
#   2  StrategusCodeToRun.R                           -> Strategus::execute()
#
#   Re-run step 1 after ANY change to inst/cohorts/*.json, inst/Cohorts.csv, or
#   the module settings below.
#
# PREREQUISITES
#   renv::restore(), then reapply the Characterization attr_reason patch
#   (docs/STRATEGUS_CONVENTIONS.md §1.1 — it is lost on every restore).
#
# BEFORE EDITING THIS FILE
#   Read docs/STRATEGUS_CONVENTIONS.md. Several settings below look like
#   arbitrary defaults and are not — they are workarounds for bugs that have
#   each already broken a real run. Each carries a section reference.
#
# HOW TO USE THIS TEMPLATE
#   Every study-specific decision is marked `TODO [STUDY]`. Find them with:
#     Rscript ../scripts/find_todos.R      # or: grep -n "TODO \[STUDY\]" *.R
#   Delete whole module blocks you do not need rather than leaving them inert.
################################################################################
library(dplyr)
library(Strategus)

# TODO [STUDY]: camelCase study name. Names the output spec file, nothing else.
studyName <- "myStudy"

# ==============================================================================
# 1. Cohort definitions
# ==============================================================================
# packageName = NULL because this repo is source()d, not installed as a package.
cohortDefinitionSet <- CohortGenerator::getCohortDefinitionSet(
  settingsFileName = "inst/Cohorts.csv",
  jsonFolder       = "inst/cohorts",
  sqlFolder        = "inst/sql/sql_server",
  packageName      = NULL
)

# Duplicate ids would make one definition silently shadow another.
if (any(duplicated(cohortDefinitionSet$cohortId))) stop("*** duplicate cohort IDs ***")

# TODO [STUDY]: assign the cohort roles. Ids must match inst/Cohorts.csv.
#   Use the real ATLAS id for ATLAS cohorts, or an id from the reserved local
#   block for cohorts not yet in ATLAS. Conventions §6 holds the block's bounds
#   and the allocation ledger — claim your range there before authoring.
# Keep these as plain literal assignments: the -synth repo's consumer QC (consumers.yaml)
#   reads targetId / outcomeIds from this file. If you must build them programmatically,
#   state the ids in the -synth repo's consumers.yaml instead.
targetId   <- 0L          # TODO [STUDY]
outcomeIds <- c(0L)       # TODO [STUDY]

# Everything else is treated as a covariate cohort. Covariate cohorts are
# covariate DEFINITIONS, not phenotypes — they are deliberately kept out of
# CohortDiagnostics below (conventions §3.1).
covariateIds <- setdiff(cohortDefinitionSet$cohortId, c(targetId, outcomeIds))

stopifnot(targetId %in% cohortDefinitionSet$cohortId)
stopifnot(all(outcomeIds %in% cohortDefinitionSet$cohortId))

# ==============================================================================
# 2. Sentinel guards for hand-authored SQL   [DELETE IF NOT APPLICABLE]
# ==============================================================================
# Only needed if a cohort uses the circe escape hatch — a hand-authored .sql
# with a placeholder .json. See docs/CIRCE_ESCAPE_HATCH.md for the full pattern,
# including the point that matters most: STRATEGUS NEVER READS THE .sql FILE, so
# this guard protects the repo, not the run. The run is protected only by the
# post-execute() behavioural assertion in StrategusCodeToRun.R.
#
# TODO [STUDY]: set to integer(0) if every cohort is circe-generated.
HAND_AUTHORED <- integer(0)
# TODO [STUDY]: per hand-authored id, a string that appears ONLY in the real
#   logic (a distinctive CTE name works well).
SENTINELS <- list()   # e.g. list(`9100001` = "UB04 Pt dis status")

for (cid in HAND_AUTHORED) {
  sqlPath <- file.path("inst", "sql", "sql_server", paste0(cid, ".sql"))
  if (!file.exists(sqlPath)) {
    stop("*** ", sqlPath, " is missing. Cohort ", cid, " is hand-authored SQL ",
         "and cannot be regenerated from its placeholder JSON. ",
         "Restore it from git. ***")
  }
  sqlText <- readLines(sqlPath, warn = FALSE)

  sentinel <- SENTINELS[[as.character(cid)]]
  if (!is.null(sentinel) && !any(grepl(sentinel, sqlText, fixed = TRUE))) {
    stop("*** ", sqlPath, " has lost its '", sentinel, "' logic.\n",
         "    Almost certainly overwritten by a CirceR re-render from the ",
         "placeholder JSON, which would silently redefine this cohort while ",
         "still producing plausible-looking metrics.\n",
         "    Restore from git; do not regenerate. ***")
  }

  # CohortGenerator supplies @target_cohort_id and renders with
  # warnOnMissingParameters = FALSE, so a leftover @outcome_cohort_id from a
  # synthea-omop-template port reaches SQL Server un-substituted, silently.
  if (any(grepl("@outcome_cohort_id", sqlText, fixed = TRUE))) {
    stop("*** ", sqlPath, " still references @outcome_cohort_id. ",
         "CohortGenerator supplies @target_cohort_id and will not warn. ***")
  }
  message("[spec] Sentinel guard passed for cohort ", cid, ".")
}

# ==============================================================================
# 3. Time at risk
# ==============================================================================
# TODO [STUDY]: one row per time-at-risk window.
#   Anchor deliberately. If the target cohort exits at end of observation, a
#   "cohort start" anchor means FROM ADMISSION, not from discharge — compute
#   discharge-anchored windows in a custom step instead.
timeAtRisks <- tibble(
  label           = c("1 to 90d"),
  riskWindowStart = c(1),
  startAnchor     = c("cohort start"),
  riskWindowEnd   = c(90),
  endAnchor       = c("cohort start")
)

# cleanWindow = 0 for a DESCRIPTIVE cumulative-incidence table: the denominator
# must be the full cohort. A nonzero clean window drops patients who had the
# outcome phenotype in the prior window, which is the incident/new-user framing.
# Conventions §9.
outcomeList <- cohortDefinitionSet %>%
  filter(.data$cohortId %in% outcomeIds) %>%
  transmute(outcomeCohortId = cohortId, outcomeCohortName = cohortName, cleanWindow = 0)

# ==============================================================================
# 4. Modules
# ==============================================================================

# ---- CohortGenerator ---------------------------------------------------------
cg <- CohortGeneratorModule$new()
cohortDefinitionShared <- cg$createCohortSharedResourceSpecifications(cohortDefinitionSet)
cohortGeneratorSpecs   <- cg$createModuleSpecifications(generateStats = TRUE)

# ---- CohortDiagnostics -------------------------------------------------------
# Scoped to the ANALYTIC cohorts only. Diagnosing covariate cohorts was ~88% of
# total diagnostics runtime in pad-amp-ed-desc for zero manuscript value
# (conventions §3.1). Widen deliberately for a one-off phenotype-validation
# pass, then narrow again.
#
# EXCLUDE any hand-authored cohort: its JSON is a placeholder, so concept-level
# diagnostics on it describe the placeholder and are actively misleading (§3.2).
#
# runInclusionStatistics = FALSE avoids CohortGenerator::insertInclusionRuleNames
# crashing on a results schema containing a backslash (issued by some Windows-
# domain secure environments, e.g. DOMAIN\username). Attrition still
# comes from the CohortGenerator module. Conventions §3.
diagnosticsCohortIds <- setdiff(c(targetId, outcomeIds), HAND_AUTHORED)

cd <- CohortDiagnosticsModule$new()
cohortDiagnosticsSpecs <- cd$createModuleSpecifications(
  cohortIds                         = diagnosticsCohortIds,
  runInclusionStatistics            = FALSE,   # §3  — do not flip where schemas contain a backslash
  runIncludedSourceConcepts         = TRUE,
  runOrphanConcepts                 = TRUE,
  runBreakdownIndexEvents           = TRUE,
  runVisitContext                   = TRUE,
  runIncidenceRate                  = FALSE,   # redundant with CohortIncidence
  runCohortRelationship             = TRUE,
  runTemporalCohortCharacterization = FALSE,   # §3.1 — slowest sub-analysis
  minCharacterizationMean           = 0.01
)

# ---- Characterization (Table 1) ---------------------------------------------
# EXACTLY ONE CharacterizationModule specification per pipeline. Repeated specs
# sharing target/outcome ids SILENTLY DEDUPLICATE to the last one added —
# confirmed by three real-output runs. Conventions §2.2.
#
# minPriorObservation = 0: vascular-surgery and synthetic Synthea patients
# routinely lack 365d of prior observation (§2.1).
#
# The three include* flags below MUST stay FALSE: Characterization 3.0.1 emits
# raw IFNULL(...) in those SQL paths, which is not a SQL Server built-in (§2).
ch <- CharacterizationModule$new()
characterizationSpecs <- ch$createModuleSpecifications(
  targetIds                     = targetId,
  outcomeIds                    = outcomeList$outcomeCohortId,
  minPriorObservation           = 0,
  outcomeWashoutDays            = rep(0, nrow(outcomeList)),
  riskWindowStart               = timeAtRisks$riskWindowStart,
  startAnchor                   = timeAtRisks$startAnchor,
  riskWindowEnd                 = timeAtRisks$riskWindowEnd,
  endAnchor                     = timeAtRisks$endAnchor,
  minCharacterizationMean       = 0.01,
  includeTargetBaseline         = TRUE,
  # TODO [STUDY]: FALSE if any outcome is hand-authored — time-to-event would be
  #   computed against the PLACEHOLDER cohort. Conventions §3.2.
  includeTimeToEvent            = TRUE,
  includeRiskFactors            = FALSE,       # §2 — SQL Server IFNULL bug
  includeDechallengeRechallenge = FALSE,       # §2
  includeCaseSeries             = FALSE        # §2
)

# ---- CohortIncidence   [DELETE IF NOT NEEDED] -------------------------------
# ⚠️ PERSONS_AT_RISK is the full cohort N at every TAR — this module NEVER
# censors patients lost to follow-up, so cumulative-incidence proportions are
# systematically optimistic at longer windows for a cohort with variable
# observation length. Use it for incidence RATES. For cumulative incidence with
# variable follow-up, compute Kaplan-Meier in a custom step. Conventions §8.
#
# Unstratified by default: stratification suppresses small cohorts to the
# minCellCount sentinel and CANNOT be re-aggregated to an overall rate (§8.1).
ci <- CohortIncidenceModule$new()
targetList <- list(CohortIncidence::createCohortRef(
  id   = targetId,
  name = cohortDefinitionSet$cohortName[cohortDefinitionSet$cohortId == targetId]
))
outcomeDefs <- lapply(seq_len(nrow(outcomeList)), function(i) {
  CohortIncidence::createOutcomeDef(
    id          = i,
    name        = outcomeList$outcomeCohortName[i],
    cohortId    = outcomeList$outcomeCohortId[i],
    cleanWindow = outcomeList$cleanWindow[i]
  )
})
tars <- lapply(seq_len(nrow(timeAtRisks)), function(i) {
  CohortIncidence::createTimeAtRiskDef(
    id          = i,
    startWith   = gsub("cohort ", "", timeAtRisks$startAnchor[i]),
    endWith     = gsub("cohort ", "", timeAtRisks$endAnchor[i]),
    startOffset = timeAtRisks$riskWindowStart[i],
    endOffset   = timeAtRisks$riskWindowEnd[i]
  )
})
irDesign <- CohortIncidence::createIncidenceDesign(
  targetDefs   = targetList,
  outcomeDefs  = outcomeDefs,
  tars         = tars,
  analysisList = list(CohortIncidence::createIncidenceAnalysis(
    targets  = targetId,
    outcomes = seq_len(nrow(outcomeList)),
    tars     = seq_along(tars)
  )),
  strataSettings = CohortIncidence::createStrataSettings(
    byYear = FALSE, byGender = FALSE, byAge = FALSE   # §8.1
  )
)
cohortIncidenceSpecs <- ci$createModuleSpecifications(irDesign = irDesign$toList())

# ==============================================================================
# 5. PatientLevelPrediction   [DELETE IF NOT NEEDED]
# ==============================================================================
# Strategus has no per-module "enabled" flag, so the spec object is built
# unconditionally and the ADD is gated. That keeps the intended design
# reviewable and diffable instead of commented out. Conventions §10.
#
# ⚠️ THE GATE IS THE ONLY THING KEEPING THIS FROM FITTING A MODEL. Passing
# modelSettings = NULL does NOT make it inert — createModelDesign() validates
# the class and rejects NULL, so a real setting must be supplied for the object
# to construct at all.
#
# NOTE: this module FITS models. To APPLY a published fixed-coefficient score,
# it is the wrong tool — run that as a custom step after Strategus::execute().
# Strategus 1.5.0 does ship PatientLevelPredictionValidationModule for applying
# an existing PLP model via validateExternal(); it will not produce a published
# score-to-risk lookup, a temporal split, ECE, or bootstrap CIs.
ENABLE_PLP <- FALSE   # TODO [STUDY]

plpSpecs <- PatientLevelPredictionModule$new()$createModuleSpecifications(
  modelDesignList = list(
    PatientLevelPrediction::createModelDesign(
      targetId  = targetId,
      outcomeId = outcomeIds[1],
      populationSettings = PatientLevelPrediction::createStudyPopulationSettings(
        binary                         = TRUE,
        riskWindowStart                = timeAtRisks$riskWindowStart[1],
        startAnchor                    = timeAtRisks$startAnchor[1],
        riskWindowEnd                  = timeAtRisks$riskWindowEnd[1],
        endAnchor                      = timeAtRisks$endAnchor[1],
        requireTimeAtRisk              = FALSE,
        removeSubjectsWithPriorOutcome = FALSE
      ),
      # Cohort-based covariates use FeatureExtraction's interval-OVERLAP
      # semantics. A custom scoring step almost certainly uses start-in-window.
      # They coincide ONLY because every covariate cohort exits at StartDate+0 —
      # changing a covariate cohort's EndStrategy silently desynchronises them.
      # Conventions §7.1.
      covariateSettings = FeatureExtraction::createCohortBasedCovariateSettings(
        analysisId       = 150,
        covariateCohorts = data.frame(
          cohortId   = covariateIds,
          cohortName = paste0("cov_", covariateIds)
        ),
        valueType = "binary",
        startDay  = -3650,   # TODO [STUDY]: lookback window
        endDay    = -1
      ),
      # TODO [STUDY]: LASSO is the conventional OHDSI starting point, used here
      #   only because createModelDesign() will not construct without a valid
      #   modelSettings object. This is a PLACEHOLDER, not a chosen model.
      modelSettings = PatientLevelPrediction::setLassoLogisticRegression(),
      splitSettings = PatientLevelPrediction::createDefaultSplitSetting(
        type = "time", testFraction = 0.25, nfold = 3
      )
    )
  ),
  skipDiagnostics = FALSE
)

# ==============================================================================
# 6. Assemble and serialise
# ==============================================================================
# TODO [STUDY]: remove the addModuleSpecifications() lines for modules you
#   deleted above.
analysisSpecifications <- Strategus::createEmptyAnalysisSpecifications() |>
  Strategus::addSharedResources(cohortDefinitionShared) |>
  Strategus::addModuleSpecifications(cohortGeneratorSpecs) |>
  Strategus::addModuleSpecifications(cohortDiagnosticsSpecs) |>
  Strategus::addModuleSpecifications(characterizationSpecs) |>
  Strategus::addModuleSpecifications(cohortIncidenceSpecs)

if (ENABLE_PLP) {
  analysisSpecifications <- analysisSpecifications |>
    Strategus::addModuleSpecifications(plpSpecs)
  message("[spec] PatientLevelPredictionModule ENABLED — a model WILL be fitted.")
} else {
  message("[spec] PatientLevelPredictionModule scaffolded but DISABLED.")
}

specPath <- file.path("inst", paste0(studyName, "AnalysisSpecification.json"))
ParallelLogger::saveSettingsToJson(analysisSpecifications, specPath)

message("[spec] Wrote ", specPath)
message("[spec]   cohorts : ", nrow(cohortDefinitionSet),
        " (target ", targetId,
        ", outcome ", paste(outcomeIds, collapse = "/"),
        ", ", length(covariateIds), " covariate)")
message("[spec] Next: StrategusCodeToRun.R (pipeline step 2), fresh R session.")
