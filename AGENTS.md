# AGENTS.md — Lakehouse + MLflow Project

## What this project is

Group 6 follow-up for paper **2310.08697** and the professor's question:

> Where does MLflow fit in a data lakehouse, and how would you build it?

The deliverable is a working demo of the exact architecture, not a production churn-prediction product. The lakehouse stores and versions the data; MLflow records which data version trained each model; Dremio and Tableau provide the BI path.

The presentation has been recorded and is complete. Treat the current demo as the archived working version unless the user explicitly asks for changes.

## Workspace

The active session runs from `C:\Theara\YEAR 3\SEMESTER 1\PP`, not from `PP\Data Lakehouse` (moved 2026-11-22). The repo is reached as `Data Lakehouse/MLflow Exact Stack V2`. Moving a session only changes its directory pointer; no files or history are copied.

## Current public repo

- Repository: <https://github.com/ThearaGithub/mlflow-exact-stack-v2>
- Visibility: public
- Branch: `main`
- The repo contains the **complete V2 folder**: 27 files, including the Dremio JDBC jar, runtime state, generated chart, deck, script, explainer, workbook, and `AGENTS.md`.
- The repo is the source of truth for the V2 demo. Clone it with:

```bash
git clone https://github.com/ThearaGithub/mlflow-exact-stack-v2.git
```

- Normal update on any machine:

```bash
git pull --ff-only
```

- Force local to match the cloud only when local edits can be discarded:

```bash
git fetch origin
git reset --hard origin/main
git clean -fd
```

The public repo includes a third-party Dremio JDBC jar. The user explicitly accepted that for easy cloning; check its license before any further redistribution.

## One-sentence mental model

MinIO stores files; Iceberg turns them into versioned tables; Nessie versions the catalog; Spark and Dremio read the same tables; Jupyter trains models; MLflow links each model to the exact data commit; Tableau visualizes the BI path.

## Layout

- `Data Lakehouse/MLflow Exact Stack V2/` — active deliverable and Git repo.
- `Data Lakehouse/MLflow PIP Only V1/` — frozen first pip-only demo. **Do not edit or sync V2 changes into it.**
- `Data Lakehouse/Paper Presentation/` — original graded deck, paper PDF, and rehearsal material. **Frozen.**
- V2 files:
  - `docker-compose.yml` — MinIO, Nessie, MLflow, Spark/Jupyter, Dremio profile.
  - `Dockerfile.spark`, `Dockerfile.mlflow` — pinned images.
  - `conf/spark-defaults.conf` — Nessie catalog and memory tuning.
  - `data/churn_batch_1.csv`, `data/churn_batch_2.csv` — synthetic source data.
  - `jobs/ingest.py` — Spark ingestion and two Nessie commits.
  - `jobs/make_data.py` — deterministic data generator.
  - `notebooks/lakehouse_mlflow.ipynb` — training, MLflow logging, registry alias.
  - `notebooks/churn_by_contract.png` — generated chart (included in repo).
  - `state/ingest_summary.json` — last-ingest commit hashes and row counts.
  - `Tableau_Churn_Dashboard.twb` — live Tableau workbook over Dremio.
  - `Tableau Driver/` — Dremio JDBC 26.0.5 jar and instructions.
  - `Start Demo.bat` — Windows-only full-stack launcher.
  - `Reset Demo.bat` — Windows-only destructive reset.
  - `START HERE.md` — short universal setup guide.
  - `Presentation_Script.md` — readable speaker script with speaker order.
  - `Lakehouse_Explainer.png` — one-image visual explainer.
  - `MLflow_Exact_Stack_V2_Presentation.pptx` — 7-slide deck; speaker notes are the original talk track.
  - `README.md` — technical reference.
  - `AGENTS.md` — this file.

## Data

The data is **synthetic**, not real customer data and not a real churn study.

| Column | Meaning |
|---|---|
| `customer_id` | Fake customer number |
| `tenure_months` | Customer tenure |
| `monthly_charge` | Monthly bill |
| `support_calls` | Support-call count |
| `contract` | Contract type |
| `internet_service` | Internet service type |
| `churned` | Target: 1 = churned, 0 = stayed |

- Batch 1: **2,000 rows**
- Batch 2: **500 new rows**
- Current table after both commits: **2,500 rows**
- No real people, PII, or production credentials.

The data exists to prove the storage/versioning system: two batches create two Iceberg table versions, the model trains on the older commit, and the dashboard reads the current commit.

### Bringing your own data

The demo needs no external data—both batches ship in the repo. If someone brings their own, the contract is a CSV with this header:

`customer_id,tenure_months,monthly_charge,support_calls,contract,internet_service,churned`

- `customer_id` is an ID only; it is not a model feature.
- `churned` must be numeric `0`/`1`.
- The notebook's features are fixed: `tenure_months`, `monthly_charge`, `support_calls`, `contract`, `internet_service`.
- `jobs/ingest.py` hardcodes the two filenames and asserts 2,000 then 2,500 rows. Real data requires editing those paths/assertions or keeping the same row counts.
- The existing chart groups contracts as `month-to-month`, `one-year`, `two-year`; other labels train but may leave chart groups empty.

There is no upload UI and no auth: Spark reads the CSV from `data/`. "Using" the project means running the lifecycle, not submitting data to a service.

## Architecture and flow

```text
CSV batches
   -> Spark ingestion
   -> Parquet files in MinIO (S3-compatible)
   -> Iceberg table metadata and snapshots
   -> Nessie catalog commits
        -> Dremio reads current table -> Tableau dashboard
        -> Spark reads same table -> Jupyter -> MLflow
```

- **MinIO** = S3-compatible object storage.
- **Iceberg** = table format on Parquet (schema, snapshots, ACID, time travel).
- **Nessie** = catalog with Git-style commits for the whole warehouse.
- **Spark** = ingestion and ML compute.
- **JupyterLab** = notebook environment.
- **MLflow** = run tracking, model registry, champion alias, data-version lineage.
- **Dremio** = SQL/BI engine.
- **Tableau** = dashboard frontend.

There are two reads of the **same table**, not duplicate copies for BI and ML.

### Expected data versions

- Commit A: 2,000 rows (training version).
- Commit B: 2,500 rows (current/main version).

The notebook trains `rf-100` and `rf-300`, logs `training_nessie_commit = A`, metrics, model artifacts, and sets the `champion` alias. `rf-100` is the better model in the verified run (ROC AUC about 0.799 vs 0.785) and is registry version 1; the alias points to it.

## Run on Windows

Requirements: Docker Desktop with WSL2, about 10 GB free disk for images, and free ports `5000`, `8888`, `9000`, `9001`, `19120`, `9047`, `31010`, `32010`.

1. Double-click `Start Demo.bat`.
2. It starts Docker Desktop if needed, starts the full Dremio profile, waits for services, ingests if Nessie does not match `state/ingest_summary.json`, and opens the deck/UIs.
3. On a fresh machine or after a reset, open Jupyter and click **Run All** once to create the two MLflow runs and the `v1` champion.
4. Set up Dremio and Tableau once (below).

`Reset Demo.bat` wipes the four Docker volumes: MinIO data, Nessie catalog, MLflow database, and Dremio data. It does not delete host files.

### Distribution for friends (Windows-first)

Most users are on Windows and that path is the best supported:

- They install only **Docker Desktop with WSL2**. MinIO, Nessie, Spark/Jupyter, MLflow and Dremio all run as containers.
- Clone the public repo or use GitHub's **Code -> Download ZIP**. `Start Demo.bat` resolves its own folder with `%~dp0`, so the folder name and location do not matter.
- There are no hardcoded machine paths in the launchers, compose file, jobs, or notebook; docs use `%USERPROFILE%` placeholders only.
- First run still needs notebook **Run All**, the one-time Dremio admin/source setup, and optionally Tableau.
- Requirements: ~10 GB free disk, 8 GB RAM minimum (16 GB comfortable), the ports listed above, and firewall permission for Docker.

## Run on macOS or Linux

There is no portable `.bat` launcher. Use Docker Compose directly; the stack is the same.

```bash
docker compose --profile dremio up -d --build

# Wait until these answer:
curl -f http://localhost:5000/health
curl -f http://localhost:8888/api
curl -f http://localhost:19120/api/v2/trees/main
curl -f http://localhost:9000/minio/health/live
```

If the lakehouse is empty, or the Nessie commit does not match `state/ingest_summary.json`, create the two versions:

```bash
docker compose exec -T spark spark-submit --master "local[2]" /workspace/jobs/ingest.py
```

Then open:

- JupyterLab: <http://localhost:8888/lab/tree/notebooks/lakehouse_mlflow.ipynb>
- MLflow: <http://localhost:5000>
- MinIO: <http://localhost:9001> (`minioadmin` / `minioadmin`)
- Nessie: <http://localhost:19120/api/v2/trees/main>
- Dremio: <http://localhost:9047>

On macOS use Docker Desktop. On Linux use Docker Engine plus Compose v2. Do not rely on host Python; the demo runs in containers. Tableau Desktop is available on Windows/macOS but not Linux; the Dremio web UI still works on Linux.

Reset on macOS/Linux:

```bash
docker compose --profile dremio down -v --remove-orphans
```

Then start again and run ingestion once. The notebook still needs **Run All** once for MLflow.

### Linux capability notes

- The whole Docker stack runs on Linux: MinIO, Nessie, Spark/Jupyter, MLflow and Dremio. Dremio's UI is at `http://localhost:9047`.
- **Tableau Desktop is the only hard blocker**—there is no Linux build. Opening the `.twb` needs Windows/macOS or a VM.
- Dremio's UI shows **tables and SQL results, not charts**. Visuals come from Tableau, `assets/Tableau_Churn_Dashboard.png`, or the notebook's matplotlib chart.
- PowerPoint desktop is also Windows/macOS-only; LibreOffice Impress or PowerPoint for the web can open the deck.
- `Start Demo.bat` / `Reset Demo.bat` are Windows conveniences; on Linux use the Compose commands above.
- Do not add Metabase/Superset just to replace Tableau on Linux: extra RAM and community connectors with no benefit for the class demo.

## Dremio setup

First time on a fresh machine or after a reset:

1. Open <http://localhost:9047>.
2. Create the admin user with username **`admin`** and a password of your choice. Keep the username `admin`; the Tableau workbook expects it.
3. Add **Sources -> Nessie**:
   - Name: `nessie`
   - Endpoint: `http://nessie:19120/api/v2`
   - Nessie authentication: **none**
   - Storage: **AWS**
   - AWS root path: `warehouse` (the fixed prefix already shows `s3://`; do not add a leading slash)
   - Authentication: **AWS Access Key**
   - Access key: `minioadmin`
   - Secret: `minioadmin`
   - Other properties:
     - `fs.s3a.path.style.access=true`
     - `fs.s3a.endpoint=minio:9000`
     - `dremio.s3.compat=true`
   - Uncheck **Encrypt connection**.
4. Test:

```sql
SELECT * FROM nessie.lakehouse.churn_features LIMIT 20;
```

The current table should show 2,500 rows. Dremio's schema tree has been unreliable; custom SQL is the verified path.

### Account lifecycle

- `Start Demo.bat` does **not** create a Dremio account today. It only waits for port 9047 and opens the UI; the first admin is created manually.
- The account lives in the `dremio-data` volume and survives restarts and rebuilds.
- `Reset Demo.bat` runs `down -v`, deleting the account and all Dremio data.
- Any future auto-bootstrap must be idempotent: create an admin only when none exists, never on every start.
- Password, name and email can be changed later (admin: Settings -> Users; own password in account settings). Keep the username `admin`—the Tableau workbook expects it, and changing it requires editing the Tableau connection.
- For custom credentials that survive resets, read them from an untracked `.env`.

## Tableau setup

The Dremio JDBC jar is included at:

```text
Tableau Driver/dremio-jdbc-driver-26.0.5.jar
```

Copy it to the Tableau driver folder:

- Windows: `%USERPROFILE%\Documents\My Tableau Repository\Drivers`
- macOS: `~/Documents/My Tableau Repository/Drivers`

Restart Tableau, open `Tableau_Churn_Dashboard.twb`, enter the Dremio `admin` password, and show the **Churn Dashboard** tab. It has three charts: churn by contract, tenure group, and internet service.

## Presentation

- Deck: `MLflow_Exact_Stack_V2_Presentation.pptx` — 7 slides.
- Original talk track: speaker notes on all 7 slides.
- Readable script: `Presentation_Script.md`.
- Visual explainer: `Lakehouse_Explainer.png`.
- Slide 7 is the Q&A prep.

Speaker order and timings:

| Speaker | Slides | Section | Target |
|---|---|---|---|
| Khon Sotheara | 1–2 | Opening + architecture | 1:15 |
| Khann Udomvirak | 3–4 | Six pieces + running proof | 1:30 |
| Chea Sela | 5 | The MLflow layer | 1:00 |
| Theng Sivchheng | 6–7 | Demo + Q&A lead | 1:15 |

All four can join Q&A; Theng leads the close.

Do not hardcode commit hashes in the deck: slide 5 uses `<training-hash>` and `<current-hash>` slots. Read live hashes from the notebook/MLflow.

Plain-language answer if asked what the project is:

> We are building a versioned storage system. The churn data is only the test load: it proves the same table can serve a dashboard and train a model, and MLflow can trace the model back to the exact data version.

## Cross-OS rules

- Use relative paths in docs; the repo is self-contained.
- Keep directory and file names exact, including `Tableau Driver` (space) and `MLflow Exact Stack V2`.
- The core stack is Docker Compose; `.bat` files are Windows conveniences only.
- The `.bat` files must stay **CRLF + ASCII**. Do not rewrite them with LF.
- On macOS/Linux, use `bash` commands shown above; do not assume PowerShell.
- Docker on macOS/Windows uses Docker Desktop; Linux uses Docker Engine with Compose v2.
- Tableau is desktop-only; the core lakehouse, MLflow, Dremio, and notebook run on any Docker host.
- Ports and service names are identical across operating systems.
- The demo credentials are local only: `minioadmin` / `minioadmin`.
- No real secrets belong in this repo.

## Invariants and gotchas

- Versions are pinned deliberately: Spark 3.5.9, Iceberg 1.11.0, Nessie 0.109.0, MLflow 3.17.2, Dremio 26.0.5, plus MinIO/aws-cli digests. Do not bump casually.
- `Start Demo.bat` skips ingestion only when Nessie's `main` commit matches `state/ingest_summary.json`. This preserves an existing demo.
- The launcher does **not** execute the notebook.
- On a preserved stack, do not click **Run All** unless a live run is intentional; it adds model versions and may move `champion`.
- After a reset, click **Run All** once to recreate the two runs and the `v1` champion.
- MLflow default tracking store is `sqlite:///mlflow.db` in the process CWD. In this stack it is the container's `/mlflow/mlflow.db`; artifacts go to MinIO.
- V2 logs `training_nessie_commit`. V1 logs `training_snapshot_id`. Never cross-copy parameter names.
- Loading the champion uses `models:/churn_classifier@champion`.
- The Dremio first-user/source setup and Tableau driver copy are manual.
- Dremio requires a 4 GB heap minimum. Spark driver 768 MB, Nessie 512 MB heap, and MLflow `--workers=1` are deliberate; do not raise them casually.
- On the 8 GB laptop keep WSL at 6 GB (`memory=6GB`, `swap=4GB`) and do not run the Spark notebook and Dremio/Tableau at the same time. On 16 GB, 10 GB is a safe WSL cap; bigger-machine setup is still untested.
- Full stack measured about 3.3 GB of containers, with roughly 0.5–0.7 GB host RAM free on the 8 GB laptop.
- The public repo includes the generated chart, runtime state, AGENTS.md, and the third-party Dremio jar because the user explicitly wants a complete clone. Do not silently remove them.
- `Start Demo.bat` does not create a Dremio user; the first admin is manual and persists in `dremio-data`.
- Jupyter and MLflow have no authentication in this stack; keep it local-only and never expose the ports publicly.
- Dremio's UI is a SQL/table tool, not a chart/dashboard tool.

## Teacher feedback: autologin and Vault

Two separate asks; do not merge them into one feature.

### Autologin (reduce typing)

Agreed plan, **not implemented yet** (decision pending as of 2026-11-22):

1. Auto-provision Dremio on first start: create the `admin` user through the bootstrap REST endpoint, then add the Nessie source through the catalog API with the settings above. Idempotent: skip when already present.
2. Auto-run the notebook only when MLflow has no runs: `jupyter nbconvert --execute --inplace notebooks/lakehouse_mlflow.ipynb`. Never auto-run on a preserved stack.
3. Optional: generate a random local Dremio password into an untracked `.env` so the public repo holds no fixed secret; print it once for Tableau.
4. Optional: one launcher/landing page that opens Jupyter, MLflow, Dremio and MinIO.

Jupyter and MLflow already have no login. Tableau's Dremio password prompt and any Tableau account sign-in cannot be reliably automated; treat them as the only manual step.

### Vault and service-to-service auth

The teacher also mentioned service-to-service identity and HashiCorp Vault. Project position:

- **Do not implement full Vault/S2S in the demo.** Vault manages machine secrets; it does not remove human UI logins. mTLS, per-service identities, policies and rotation are days of work and another failure point on an 8 GB laptop.
- Production story for Q&A/a slide: each service gets its own identity, Vault issues short-lived least-privilege credentials, secrets rotate and are audited. The demo keeps fixed local credentials for simplicity.
- Only if explicitly graded: add a minimal Vault dev container holding MinIO creds in KV, with one init script reading them. Do not attempt dynamic secrets or mTLS for the class demo.

Do not start either implementation until the user says `go`.

## Verification and change discipline

Verification means running the demo, not just reading files.

Before claiming a change works:

1. `docker compose config` passes.
2. Core endpoints return 200.
3. Nessie main matches `state/ingest_summary.json` after ingestion.
4. Dremio returns the expected 2,500 rows.
5. MLflow has the expected runs, models, and champion alias.
6. Tableau workbook opens against Dremio.
7. Docs, deck notes, `Presentation_Script.md`, `START HERE.md`, and README remain consistent.
8. If autologin is added: a second start does not duplicate the Dremio user or re-run the notebook, and a reset recreates exactly one admin.

Any V2 behavior change must update the synced artifacts: V2 README, `START HERE.md`, deck speaker notes, `Presentation_Script.md`, and this AGENTS.md when instructions change. V1 and the original paper presentation remain frozen.

Do not claim a fresh 16 GB machine or a clean-machine end-to-end run is verified; only the 8 GB laptop path has been tested. Do not claim the demo is one-click from zero: the Dremio user/source and Tableau driver/password steps are still manual.

## Current state

- Presentation: recorded and done.
- Working directory: session moved to `C:\Theara\YEAR 3\SEMESTER 1\PP`; repo at `Data Lakehouse\MLflow Exact Stack V2`.
- Local repo: clean, synced with `origin/main` (check `git log -1` for the current commit); 27 tracked files.
- Repo: public.
- Stack: intentionally reset; no containers or volumes should be assumed running until `Start Demo.bat` or Compose is run.
- ZIP: not present; the public repo is the complete clone source.
- Autologin and Vault: discussed and scoped, **not implemented**; awaiting the user's `go`.
