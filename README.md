# Azure Predictive Maintenance Data Platform

A free-tier Azure data platform demonstrating end-to-end predictive maintenance
data engineering: migrating a legacy on-prem system into the cloud, building a
Medallion (bronze/silver/gold) lakehouse, and surfacing the results in a BI
report — all backed by infrastructure-as-code and CI/CD.

Built on the Microsoft Azure Predictive Maintenance dataset (~876K hourly
telemetry rows, 100 machines, 761 failures across 4 components).

## Architecture

Dockerized "legacy" SQL Server (Machines, MaintenanceHistory)
│ Azure Data Factory + Self-Hosted Integration Runtime
▼
ADLS Gen2 "bronze" container ◄── direct upload: telemetry / errors / failures CSVs
│
▼ (Databricks, PySpark)
5x silver Delta tables — cleaned, deduplicated, correctly typed
│
▼
gold_telemetry_features — 3-day rolling sensor statistics
│ joined with error counts, maintenance recency, failure labels
▼
gold_features
│
├─► dq_check_log / data_dictionary (data quality + governance)
└─► Power BI report (DAX measures on failure rate, component
breakdown, maintenance recency)

Azure DevOps Pipelines ── deploys infra/ automatically on push to main


**Landing zone (Bicep):** resource group, virtual network (including a
reserved subnet for future hybrid connectivity), ADLS Gen2 storage with
`bronze`/`silver`/`gold` containers, Key Vault (RBAC-authorized), a
user-assigned Managed Identity, and an Azure Data Factory instance — wired
together with least-privilege role assignments defined entirely in code.

**Migration:** a Dockerized SQL Server container simulates an on-prem legacy
system, seeded with machine and maintenance history data. An ADF pipeline,
connected via a Self-Hosted Integration Runtime, migrates this into `bronze` —
a genuine migration pattern rather than a synthetic data load.

**Transform:** Databricks builds five silver tables (one per source), then a
gold layer combining rolling sensor statistics, error-precursor counts,
maintenance recency, and a next-day failure label into a single
analytics-ready table.

**Governance:** every pipeline run logs row counts and null-rate checks to an
append-only audit table, alongside a maintained data dictionary describing
every gold-layer column.

**Reporting:** a Power BI report connects directly to the Databricks SQL
Warehouse, with DAX measures covering failure rate, per-component failure
breakdown, and average days-since-maintenance for failed vs. non-failed
machine-days.

**CI/CD:** Azure DevOps Pipelines deploys the Bicep landing zone automatically
on any change to `infra/`.

## Repo structure

azure-pdm-platform-vvp/
├── azure-pipelines.yml
├── .env (not committed — local secrets)
├── .gitignore
├── README.md
├── data/raw/ (not committed — source CSVs)
├── docker/
│ ├── docker-compose.yml
│ └── init/
│ ├── init-schema.sql
│ └── verify.sql
├── infra/
│ ├── main.bicep
│ └── resources.bicep
├── notebooks/
│ └── pdm_pipeline.py (exported Databricks notebook, source format)
└── scripts/
└── seed_legacy_db.py


## Prerequisites

- Azure subscription with Azure CLI and Bicep installed
- Docker Desktop
- A Databricks workspace (Free Edition is sufficient)
- Power BI Desktop
- An Azure DevOps organization, for CI/CD

## Setup

1. **Deploy the landing zone**
```bash
   az login
   az deployment sub create \
     --location uksouth \
     --template-file infra/main.bicep \
     --parameters projectName=pdmvvp environment=dev
```

2. **Bring up the simulated legacy source**
```bash
   cd docker
   docker compose --env-file ../.env up -d
```
   Then run `scripts/seed_legacy_db.py` to load the source data into it.

3. **Migrate legacy data into the lake.** In Azure Data Factory Studio:
   install a Self-Hosted Integration Runtime, create linked services for the
   SQL Server source and the ADLS Gen2 sink, and build a Copy Data pipeline
   moving `Machines` and `MaintenanceHistory` into `bronze`.

4. **Load the remaining sources** — telemetry, errors, and failures CSVs —
   directly into `bronze` via `az storage blob upload`.

5. **Run the transform pipeline.** Open `notebooks/pdm_pipeline.py` in
   Databricks and run it top to bottom: builds all five silver tables, both
   gold-layer passes, the DQ checks, and the data dictionary.

6. **Build the report.** Connect Power BI Desktop to your Databricks SQL
   Warehouse (Server hostname + HTTP path, found under Compute → your
   warehouse → Connection details) and build DAX measures on `gold_features`.

7. **Enable CI/CD.** Connect an Azure DevOps pipeline to this repo, add an
   Azure Resource Manager service connection scoped to your subscription,
   grant that service principal both **Contributor** and **User Access
   Administrator** on the target resource group, and push to `main`.

## Known limitations and design trade-offs

- No enterprise scale — single subscription, small resource footprint, by
  design.
- Hybrid on-prem↔cloud networking (VPN Gateway) is designed as IaC but not
  deployed, since it's a billed resource; the ADF Self-Hosted Integration
  Runtime provides the actual working hybrid connection instead.
- Event streaming is simulated via folder-based replay rather than a live
  Event Hub/Kafka feed, for the same cost reason.
- Silver and gold Delta tables live in Databricks-managed storage rather than
  back in the pre-provisioned ADLS `silver`/`gold` containers — Databricks'
  free tier has limited support for writing to Azure storage directly (see
  Troubleshooting), so bronze is the only layer that lives in Azure Data Lake.
- The dataset is synthetic and relatively clean, so it under-represents the
  messiness (duplicates, drift, missing chunks) of real production data.

## Troubleshooting

- **PowerShell line continuation** uses a backtick (`` ` ``), not a backslash
  — a common source of silently broken multi-line commands.
- **`az` not recognized after install** is almost always a stale PATH in an
  already-open terminal. Close every window and reopen rather than retrying
  in place.
- **Azure CLI sign-in requiring MFA** is expected under Microsoft's current
  enforcement policy for CLI/PowerShell tooling. Use
  `az login --use-device-code` if the default browser flow doesn't prompt
  for it correctly.
- **Docker Desktop being open doesn't mean containers are running** — start
  them explicitly with `docker compose up -d`, and add
  `restart: unless-stopped` if you want them to survive a Docker Desktop
  restart automatically.
- **`.env` file values must be edited in the file itself**, never pasted into
  a terminal — they're not shell commands.
- **`sqlcmd -Q` with multi-statement or parenthesised queries** can break
  under PowerShell's argument quoting. Use `sqlcmd -i <file>.sql` instead —
  far more reliable for anything beyond a trivial one-liner.
- **Connecting to a Dockerized/Linux SQL Server from a Windows client**
  requires `servername,port` (comma syntax) to force TCP/IP — plain
  `localhost` tries Named Pipes first and fails with a misleading "server not
  found" error.
- **ADF's Self-Hosted Integration Runtime needs a local JRE** to read/write
  Parquet or ORC files — install one (e.g. Microsoft's OpenJDK build) and
  restart the Integration Runtime service if you see `JreNotFound`.
- **An RBAC-authorized Key Vault denies access by default, even to the
  subscription owner** — explicitly grant yourself a role (e.g. **Key Vault
  Secrets Officer**) before attempting to read or write secrets.
- **Databricks serverless compute blocks `spark.conf.set()` for storage
  keys** (`CONFIG_NOT_AVAILABLE`). The same key passed inline via `.option()`
  works for reads but is unreliable for writes — write to Databricks-managed
  tables (`saveAsTable`) instead of back to external cloud storage.
- **Databricks Unity Catalog credential types vary by platform tier** — check
  what's actually supported before assuming a given cloud is covered.
- **Databricks personal access tokens require API scopes** in current
  versions — select the broadest scope your use case needs to avoid being
  blocked mid-build by an overly narrow token.
- **Microsoft Fabric trial availability varies by tenant** and isn't
  guaranteed on every account type. Power BI Desktop connecting directly to
  a data warehouse (Databricks, Synapse, etc.) is a fully viable alternative
  if a Fabric trial isn't available to you.
- **New Azure DevOps organizations have zero Microsoft-hosted parallel jobs
  by default.** Either request the free grant (can take a few business days)
  or register a self-hosted agent for immediate use.
- **The `AzureCLI@2` pipeline task defaults to a `bash` scriptType**, which
  needs WSL on a Windows agent. Set `scriptType: 'ps'` for Windows
  self-hosted agents to avoid an unnecessary WSL dependency.
- **A CI/CD service principal's default Contributor role excludes RBAC
  management** (`Microsoft.Authorization/roleAssignments/write`). Grant it an
  additional, narrowly-scoped **User Access Administrator** role on the
  target resource group if your IaC includes role assignments.
- **Azure free-trial credit has a hard calendar expiry**, separate from how
  much you've actually spent — check your subscription type well before any
  stated cutoff date.

## Dataset

Microsoft Azure Predictive Maintenance dataset. Confirm the license terms of
whichever public mirror you source it from before further redistribution.

## Roadmap

- Star-schema ERD, UML class diagram, and BPMN process map for the full
  pipeline.
- Optional: Synapse serverless SQL view over the gold layer.
- Optional: a lightweight RAG layer over the pipeline's own documentation.