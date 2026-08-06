################################################################################
# StrategusCodeToRun.R  —  PIPELINE STEP 2 (DEVCONTAINER, synthetic pre-flight)
#
# PURPOSE
#   Run this study's analysis specification against a SYNTHETIC OMOP CDM in the
#   omop-dev workspace dev container.
#
#   This is the MECHANICAL-VALIDATION step, not the real study run. It confirms
#   the pipeline generates cohorts and executes every Strategus module end to
#   end. Row counts here are proof-of-signal on synthetic data only — they are
#   NOT study results and must never be reported as such.
#
#   Real Duke patient data is not reachable from this dev container. The real run
#   happens on Duke PRCC via the portable/ bundle built by
#   workflow/09_build_portable_analysis_bundle.sh.
#
# INPUTS
#   inst/<studyName>AnalysisSpecification.json   — from pipeline step 1
#   A synthetic CDM view-overlay schema           — see PREREQUISITES
#
# OUTPUT
#   results/<databaseName>/strategusOutput/       — gitignored
#
# PREREQUISITES
#   1. Run INSIDE the dev container. Never on the host.
#   2. renv::restore(), then reapply the Characterization attr_reason patch
#      (docs/STRATEGUS_CONVENTIONS.md §1.1 — lost on every restore).
#   3. A VIEW-OVERLAY schema must exist. Strategus::createCdmExecutionSettings()
#      has NO vocabulary-schema parameter — it expects clinical AND vocabulary
#      tables in ONE cdmDatabaseSchema, but our synthetic CDMs keep vocabulary in
#      the shared omop_vocab. Build the overlay first (conventions §5):
#        Rscript ../synthetic_data/scripts/generate_overlay_schema.R \
#          --dataset <registry_id> --schema <study>_cdm_shared
#   4. Regenerate upstream artifacts if cohorts or settings changed:
#        Rscript scripts/render_cohort_sql.R
#        Rscript CreateStrategusAnalysisSpecification.R
#   5. Fresh R session — Strategus does not tolerate a dirty one.
#
# USAGE (from the workspace root, on the host)
#   docker exec -e IN_DEV_CONTAINER=true -w /workspace/<study> \
#     omop_dev-devcontainer-1 Rscript StrategusCodeToRun.R
################################################################################

# TODO [STUDY]: must match `studyName` in CreateStrategusAnalysisSpecification.R.
studyName <- "myStudy"

# FeatureExtraction / Andromeda need heap headroom; VROOM_THREADS=1 avoids a
# readr threading crash inside the container.
Sys.setenv("_JAVA_OPTIONS" = "-Xmx4g")
Sys.setenv("VROOM_THREADS" = 1)

# Reuse the workspace-shared SQL Server JDBC driver bundle rather than
# downloading one per study.
Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = "/workspace/synthea-omop-template/drivers/jdbc-runtime")

# ========== START OF SITE INPUTS ==============================================

# Two-part "database.schema" form is REQUIRED. Given a bare schema name,
# CohortGenerator misreads it as the database name on this SQL Server instance.
# Conventions §4.
#
# TODO [STUDY]: replace the two schema defaults.
#   cdm    -> the view-overlay schema from prerequisite 3, NOT the physical CDM
#   work   -> this study's own results schema
cdmDatabaseSchema <- paste0(
  Sys.getenv("OMOP_DATABASE"), ".",
  Sys.getenv("OMOP_CDM_SCHEMA_OVERRIDE", unset = "my_study_cdm_shared")
)
workDatabaseSchema <- paste0(
  Sys.getenv("OMOP_DATABASE"), ".",
  Sys.getenv("OMOP_RESULTS_SCHEMA_OVERRIDE", unset = "my_study_results")
)

# TODO [STUDY]: cohortTableName must be unique across studies sharing a results
#   schema, or two studies will overwrite each other's cohort tables.
databaseName    <- Sys.getenv("OMOP_CDM_DATABASE_NAME", unset = "DevContainerSynthea")
cohortTableName <- "my_study"
outputLocation  <- file.path(getwd(), "results")   # gitignored
minCellCount    <- 5

connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms     = "sql server",
  server   = Sys.getenv("OMOP_SERVER", unset = Sys.getenv("MSSQL_HOST", unset = "mssql_dev")),
  user     = Sys.getenv("MSSQL_USER", unset = "sa"),
  password = Sys.getenv("MSSQL_SA_PASSWORD"),
  extraSettings = paste0(
    "database=", Sys.getenv("OMOP_DATABASE"),
    ";trustServerCertificate=true",
    ";portNumber=", Sys.getenv("MSSQL_PORT", unset = "1433"),
    # A long Strategus run will otherwise be killed by a socket or query timeout.
    ";socketTimeout=0",
    ";queryTimeout=0"
  )
)

# Fail fast with a clear message before Strategus starts — a connection problem
# surfaced 40 minutes into a run is far more expensive to diagnose.
conn <- DatabaseConnector::connect(connectionDetails)
DatabaseConnector::querySql(conn, "SELECT 1 AS ok;")
DatabaseConnector::disconnect(conn)
message("[run] Connection preflight passed: ", databaseName)

# ========== END OF SITE INPUTS ================================================

specPath <- file.path("inst", paste0(studyName, "AnalysisSpecification.json"))
if (!file.exists(specPath)) {
  stop("*** ", specPath, " not found. Run pipeline step 1 first:\n",
       "      Rscript CreateStrategusAnalysisSpecification.R ***")
}
analysisSpecifications <- ParallelLogger::loadSettingsFromJson(fileName = specPath)

executionSettings <- Strategus::createCdmExecutionSettings(
  workDatabaseSchema = workDatabaseSchema,
  cdmDatabaseSchema  = cdmDatabaseSchema,
  cohortTableNames   = CohortGenerator::getCohortTableNames(cohortTable = cohortTableName),
  workFolder         = file.path(outputLocation, databaseName, "strategusWork"),
  resultsFolder      = file.path(outputLocation, databaseName, "strategusOutput"),
  minCellCount       = minCellCount
)

if (!dir.exists(file.path(outputLocation, databaseName))) {
  dir.create(file.path(outputLocation, databaseName), recursive = TRUE)
}

# Persisted so a failed run can be reproduced exactly, and so the PRCC bundle can
# diff its own execution settings against the devcontainer's.
ParallelLogger::saveSettingsToJson(
  object   = executionSettings,
  fileName = file.path(outputLocation, databaseName, "executionSettings.json")
)

Strategus::execute(
  analysisSpecifications = analysisSpecifications,
  executionSettings      = executionSettings,
  connectionDetails      = connectionDetails
)

# ==============================================================================
# POST-EXECUTE: repair hand-authored cohorts   [DELETE IF NOT APPLICABLE]
# ==============================================================================
# ⛔ READ docs/CIRCE_ESCAPE_HATCH.md §2 BEFORE DELETING THIS BLOCK.
#
# Strategus NEVER reads inst/sql/sql_server/*.sql. Its specification stores only
# each cohort's JSON, and the CohortGeneratorModule re-renders SQL from that JSON
# with CirceR at execution time. So for any cohort using the escape hatch,
# Strategus has just generated the PLACEHOLDER.
#
# The sentinel guard in step 1 protects the FILE. Only the behavioural assertion
# inside the function below protects the RUN. In pad-amp-nhd-prog this was found
# the hard way: the first full run reported every metric as NA because the
# placeholder gave all 195 target patients an "outcome".
#
# TODO [STUDY]: uncomment and implement R/generate_<name>_cohort.R, whose
#   assertion must be one the PLACEHOLDER would FAIL. "Row count > 0" is not
#   such an assertion — the placeholder produces plenty of rows.
#
# source("R/generate_my_cohort.R")
# generateCohort(
#   connectionDetails  = connectionDetails,
#   cdmDatabaseSchema  = cdmDatabaseSchema,
#   workDatabaseSchema = workDatabaseSchema,
#   cohortTable        = cohortTableName,
#   cohortId           = 9100001L
# )

# ==============================================================================
# POST-EXECUTE: custom analysis step   [DELETE IF NOT APPLICABLE]
# ==============================================================================
# For anything no stock module produces — applying a published fixed-coefficient
# risk score, a curated Table 1, Kaplan-Meier cumulative incidence (conventions
# §8), a Word manuscript report. Query the PHYSICAL CDM schema here, not the
# view overlay: the overlay exists for Strategus's benefit only.
#
# source("scripts/analysis/my_analysis.R")

message("[run] Complete. Results: ",
        file.path(outputLocation, databaseName, "strategusOutput"))
