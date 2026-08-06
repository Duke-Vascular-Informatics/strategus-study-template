#!/usr/bin/env Rscript
# =============================================================================
# scripts/render_cohort_sql.R  —  PIPELINE STEP 0
#
# PURPOSE
#   Render inst/cohorts/<id>.json -> inst/sql/sql_server/<id>.sql with CirceR,
#   for every cohort in inst/Cohorts.csv except those excluded below.
#
#   CohortGenerator::getCohortDefinitionSet() needs a .sql alongside each .json,
#   so this must run before CreateStrategusAnalysisSpecification.R. Cohorts
#   exported from ATLAS already ship with SQL; cohorts authored directly as
#   circe JSON in this repo do not.
#
# INPUTS   inst/Cohorts.csv, inst/cohorts/<id>.json
# OUTPUT   inst/sql/sql_server/<id>.sql
#
# USAGE (inside the dev container, from the repo root)
#   Rscript scripts/render_cohort_sql.R
#   Rscript scripts/render_cohort_sql.R --force   # re-render existing SQL too
#
#   Re-run after editing any cohort JSON.
#
# WHY THERE IS A SKIP LIST
#   A cohort using the circe escape hatch (docs/CIRCE_ESCAPE_HATCH.md) has
#   hand-authored, AUTHORITATIVE SQL and a deliberately under-specified
#   placeholder JSON. Rendering that placeholder would overwrite the real logic
#   with something far broader that still produces plausible-looking metrics.
#   This script refuses to touch those files, and the spec builder carries an
#   independent sentinel guard in case they are rendered by other means.
# =============================================================================
suppressPackageStartupMessages(library(CirceR))

# TODO [STUDY]: cohort ids whose SQL is hand-authored and must NEVER be
#   regenerated from JSON. Keep in sync with HAND_AUTHORED in
#   CreateStrategusAnalysisSpecification.R.
HAND_AUTHORED <- integer(0)

force <- "--force" %in% commandArgs(trailingOnly = TRUE)

manifestPath <- "inst/Cohorts.csv"
if (!file.exists(manifestPath)) stop("Missing ", manifestPath)
manifest <- read.csv(manifestPath, stringsAsFactors = FALSE)
if (any(duplicated(manifest$cohort_id))) stop("*** duplicate cohort_id in ", manifestPath, " ***")

sqlDir <- file.path("inst", "sql", "sql_server")
dir.create(sqlDir, recursive = TRUE, showWarnings = FALSE)

rendered <- 0L
skipped  <- character(0)

for (i in seq_len(nrow(manifest))) {
  cid      <- as.integer(manifest$cohort_id[i])
  jsonPath <- file.path("inst", "cohorts", paste0(cid, ".json"))
  sqlPath  <- file.path(sqlDir, paste0(cid, ".sql"))

  if (cid %in% HAND_AUTHORED) {
    skipped <- c(skipped, sprintf("%d (hand-authored SQL — never regenerate)", cid))
    next
  }
  if (!file.exists(jsonPath)) {
    stop("Missing cohort JSON for id ", cid, ": ", jsonPath,
         "\n  Every row in ", manifestPath, " needs a JSON, even a placeholder.")
  }

  # Cohorts exported from ATLAS arrive with CirceR-rendered SQL already.
  # Re-rendering is harmless but pointless, and a CirceR-version diff shows up as
  # repo noise. Only render when absent, unless --force.
  if (file.exists(sqlPath) && !force) {
    skipped <- c(skipped, sprintf("%d (SQL already present)", cid))
    next
  }

  json <- paste(readLines(jsonPath, warn = FALSE), collapse = "\n")
  sql  <- CirceR::buildCohortQuery(
    CirceR::cohortExpressionFromJson(json),
    # generateStats must match createModuleSpecifications(generateStats = ...) in
    # the spec builder, or inclusion-rule tables will not line up.
    options = CirceR::createGenerateOptions(generateStats = TRUE)
  )
  writeLines(sql, sqlPath)
  rendered <- rendered + 1L
  cat(sprintf("  rendered %s -> %s (%d lines)\n",
              jsonPath, sqlPath, length(strsplit(sql, "\n")[[1]])))
}

cat("\nRendered:", rendered, "cohort(s).\n")
if (length(skipped)) cat("Skipped :", paste(skipped, collapse = "\n          "), "\n")
cat("\nNext: Rscript CreateStrategusAnalysisSpecification.R\n")
