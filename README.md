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


## Azure DevOps Pipelines ── deploys infra/ automatically on push to main


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

| Area | Limitation | Why |
|---|---|---|
| Scale | No enterprise scale | Single subscription, small resource footprint, by design |
| Hybrid networking | VPN Gateway is IaC-only, never deployed | Billed resource; ADF's Self-Hosted Integration Runtime provides the actual working hybrid connection instead |
| Streaming | Simulated via folder-based replay, not a live feed | Same cost reasoning — no free tier for Event Hub/Kafka |
| Silver/gold storage | Lives in Databricks-managed tables, not the pre-provisioned ADLS containers | Databricks' free tier has limited support for writing to Azure storage directly |
| Dataset realism | Relatively clean, synthetic data | Under-represents production-grade messiness (duplicates, drift, missing chunks) |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Multi-line PowerShell command fails to parse | Used `\` for line continuation (bash syntax) | Use backtick `` ` `` instead |
| `az: command not found` after install | Stale PATH in an already-open terminal | Close every terminal window and reopen, don't just retry |
| `az login` fails with an MFA/AADSTS error | Mandatory MFA enforcement for CLI tooling | Use `az login --use-device-code` |
| Docker container not reachable despite Docker Desktop being open | The app being open ≠ containers running | Run `docker compose up -d` explicitly; add `restart: unless-stopped` for persistence across Docker Desktop restarts |
| `.env` values not taking effect | Contents typed into the terminal instead of the file | Edit the `.env` file directly in an editor, never paste its contents as shell commands |
| `sqlcmd -Q` fails with a syntax error on a valid query | PowerShell mangles nested quotes for multi-statement/parenthesised `-Q` values | Use `sqlcmd -i <file>.sql` instead |
| SQL Server connection fails with "server not found" from a Windows client | Named Pipes attempted before TCP/IP against a Dockerized/Linux SQL Server | Use `servername,port` (comma syntax) to force TCP/IP |
| ADF Self-Hosted IR throws `JreNotFound` on Parquet/ORC | No local JRE installed | Install a JRE (e.g. Microsoft OpenJDK) and restart the Integration Runtime service |
| Key Vault denies access even to the subscription owner | RBAC-authorized vaults deny by default until a role is explicitly granted | Grant yourself **Key Vault Secrets Officer** (or similar) on the vault |
| `CONFIG_NOT_AVAILABLE` writing to Azure storage from Databricks | Serverless compute blocks `spark.conf.set()` for storage keys | Use `.option()` inline for reads; write to Databricks-managed tables (`saveAsTable`) instead of external storage |
| No Azure option in Databricks Unity Catalog credentials | Credential types vary by platform tier/edition | Confirm supported credential types before assuming a given cloud is covered |
| Databricks PAT blocked mid-task by scope error | New PATs require explicit API scopes | Select the broadest scope needed for active development |
| Fabric trial won't activate | Trial availability varies by tenant type and admin policy | Power BI Desktop connecting directly to a warehouse (Databricks, Synapse, etc.) is a fully viable alternative |
| Pipeline stuck with "no agent found" | New Azure DevOps orgs get zero Microsoft-hosted parallel jobs by default | Request the free grant, or register a self-hosted agent for immediate use |
| Pipeline fails at a bash script step on a Windows agent | `AzureCLI@2` defaults to `scriptType: 'bash'`, which needs WSL | Set `scriptType: 'ps'` for Windows self-hosted agents |
| Pipeline fails deploying RBAC role assignments | CI/CD service principal's default Contributor role excludes `roleAssignments/write` | Grant it **User Access Administrator**, scoped to the target resource group |
| Unexpected loss of Azure resources/credit | Free-trial credit has a hard calendar expiry, separate from spend | Check subscription type well before any stated cutoff date |

## Dataset

Microsoft Azure Predictive Maintenance dataset. Confirm the license terms of
whichever public mirror you source it from before further redistribution.
