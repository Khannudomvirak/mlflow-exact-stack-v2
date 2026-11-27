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
- The repo contains the **complete V2 folder**: 30 files, including the Dremio JDBC jar, runtime state, generated chart, deck, script, explainer, workbook, and `AGENTS.md`. The 2026-11-27 Vault work adds `setup/vault_init.sh` (31 files once committed).
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

Vault holds the storage credentials; MinIO stores files; Iceberg turns them into versioned tables; Nessie versions the catalog; Spark and Dremio read the same tables; Jupyter trains models; MLflow links each model to the exact data commit; Tableau visualizes the BI path.

## Layout

- `Data Lakehouse/MLflow Exact Stack V2/` — active deliverable and Git repo.
- `Data Lakehouse/MLflow PIP Only V1/` — frozen first pip-only demo. **Do not edit or sync V2 changes into it.**
- `Data Lakehouse/Paper Presentation/` — original graded deck, paper PDF, and rehearsal material. **Frozen.**
- V2 files:
  - `docker-compose.yml` — Vault, MinIO, Nessie, MLflow, Spark/Jupyter, Dremio profile.
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
  - `setup/dremio_bootstrap.ps1` — idempotent Dremio provisioning (the admin123 user + Nessie source); called by the launcher. Not required on macOS/Linux.
  - `setup/enable_mlflow_assistant.py` — build-time patch for MLflow's beta AI Assistant (see "Invariants and gotchas").
  - `setup/vault_init.sh` — one-shot `vault-init` script: writes the MinIO keys to Vault KV, writes the read-only policy, renders `vault-creds/minio.env`.
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

- **Vault** = secret storage (dev mode) for the MinIO credentials.
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

Requirements: Docker Desktop with WSL2, about 10 GB free disk for images, and free ports `5000`, `8200`, `8888`, `9000`, `9001`, `19120`, `9047`, `31010`, `32010`.

1. Double-click `Start Demo.bat`.
2. It starts Docker Desktop if needed, starts the full Dremio profile, waits for services, ingests if Nessie does not match `state/ingest_summary.json`, and opens the UIs. It no longer opens the deck; that is a manual double-click.
   Its Ollama step is a 2-second HTTP probe of `http://127.0.0.1:11434/api/tags` and never runs `ollama serve`; a foreground server there once blocked the script before `[5/5]`, so a run could end with no tabs open (fixed 2026-11-25). Ollama is optional and stays manual, as in README.
3. On a fresh machine or after a reset, open Jupyter and click **Run All** once to create the two MLflow runs and the `v1` champion.
4. Dremio provisions itself on start (below); set up Tableau once.

`Reset Demo.bat` wipes the five Docker volumes: MinIO data, Nessie catalog, MLflow database, Dremio data, and the rendered `vault-creds` file. Vault itself is in-memory, so it starts empty anyway. It does not delete host files.

### Distribution for friends (Windows-first)

Most users are on Windows and that path is the best supported:

- They install only **Docker Desktop with WSL2**. Vault, MinIO, Nessie, Spark/Jupyter, MLflow and Dremio all run as containers.
- Clone the public repo or use GitHub's **Code -> Download ZIP**. `Start Demo.bat` resolves its own folder with `%~dp0`, so the folder name and location do not matter.
- There are no hardcoded machine paths in the launchers, compose file, jobs, or notebook; docs use `%USERPROFILE%` placeholders only.
- First run still needs notebook **Run All** and optionally Tableau; Dremio provisions itself on start.
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
curl -f http://localhost:8200/v1/sys/health
```

If the lakehouse is empty, or the Nessie commit does not match `state/ingest_summary.json`, create the two versions:

```bash
docker compose exec -T spark spark-submit --master "local[2]" /workspace/jobs/ingest.py
```

Then open:

- JupyterLab: <http://localhost:8888/lab/tree/notebooks/lakehouse_mlflow.ipynb>
- MLflow: <http://localhost:5000>
- MinIO: <http://localhost:9001> (`minioadmin` / `minioadmin`)
- Vault: <http://localhost:8200> (token `lakehouse-dev-root`; dev mode)
- Nessie: <http://localhost:19120/api/v2/trees/main>
- Dremio: <http://localhost:9047>

On macOS use Docker Desktop. On Linux use Docker Engine plus Compose v2. Do not rely on host Python; the demo runs in containers. Tableau Desktop is available on Windows/macOS but not Linux; the Dremio web UI still works on Linux.

Reset on macOS/Linux:

```bash
docker compose --profile dremio down -v --remove-orphans
```

Then start again and run ingestion once. The notebook still needs **Run All** once for MLflow.

### Linux capability notes

- The whole Docker stack runs on Linux: Vault, MinIO, Nessie, Spark/Jupyter, MLflow and Dremio. Dremio's UI is at `http://localhost:9047`.
- **Tableau Desktop is the only hard blocker**—there is no Linux build. Opening the `.twb` needs Windows/macOS or a VM.
- Dremio's UI shows **tables and SQL results, not charts**. Visuals come from Tableau, `assets/Tableau_Churn_Dashboard.png`, or the notebook's matplotlib chart.
- PowerPoint desktop is also Windows/macOS-only; LibreOffice Impress or PowerPoint for the web can open the deck.
- `Start Demo.bat` / `Reset Demo.bat` are Windows conveniences; on Linux use the Compose commands above.
- Do not add Metabase/Superset just to replace Tableau on Linux: extra RAM and community connectors with no benefit for the class demo.

## Dremio setup

On Windows `Start Demo.bat` provisions Dremio: `setup/dremio_bootstrap.ps1` creates the `admin123` user and the `nessie` source through the REST API (launcher step `[3b/5]`) before the browser tabs open, so no first-user screen and no source form appear. Credentials are the same word for both: `admin123` / `admin123`. Dremio's rule is 8+ characters with a digit, so `admin` alone is rejected. A `DREMIO_PASSWORD` already in `.env` overrides it, which is how an older machine keeps its password without a reset.

The manual steps below are the fallback only: macOS/Linux, a `Provisioning skipped` line in the console, or an existing `admin123` whose password differs from `.env`.

First time on a fresh machine or after a reset:

1. Open <http://localhost:9047>.
2. Create the admin user with username **`admin123`** and a password of your choice. Keep the username `admin123`; the Tableau workbook stores it.
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

- `Start Demo.bat` creates the Dremio account when none exists (`PUT /apiv2/bootstrap/firstuser`). It never modifies an existing account.
- The account lives in the `dremio-data` volume and survives restarts and rebuilds.
- `Reset Demo.bat` runs `down -v`, deleting the account and all Dremio data.
- The bootstrap is idempotent: it logs in first and creates a user only when none exists, so a second start changes nothing.
- Password, name and email can be changed later (admin: Settings -> Users; own password in account settings). The username is `admin123`, and `Tableau_Churn_Dashboard.twb` stores it in its connection, so changing it means editing that file too.
- For custom credentials that survive resets, read them from an untracked `.env`.
- A `dremio-data` volume created before 2026-11-23 predates the bootstrap and can hold an `admin123` whose password is not the one in `.env`; the bootstrap then refuses to change anything. Fix by resetting Dremio only, not the whole stack (verified 2026-11-25).

## Tableau setup

The Dremio JDBC jar is included at:

```text
Tableau Driver/dremio-jdbc-driver-26.0.5.jar
```

Copy it to the Tableau driver folder:

- Windows: `%USERPROFILE%\Documents\My Tableau Repository\Drivers`
- macOS: `~/Documents/My Tableau Repository/Drivers`

Restart Tableau, open `Tableau_Churn_Dashboard.twb`, enter the Dremio `admin123` password, and show the **Churn Dashboard** tab. It has three charts: churn by contract, tenure group, and internet service.

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
- The Tableau driver copy, the Tableau password prompt and notebook **Run All** are manual. Dremio's user and Nessie source are provisioned by `Start Demo.bat`.
- Dremio requires a 4 GB heap minimum. Spark driver 768 MB, Nessie 512 MB heap, and MLflow `--workers=1` are deliberate; do not raise them casually.
- On the 8 GB laptop keep WSL at 6 GB (`memory=6GB`, `swap=4GB`) and do not run the Spark notebook and Dremio/Tableau at the same time. On 16 GB, 10 GB is a safe WSL cap; bigger-machine setup is still untested.
- Full stack measured about 3.3 GB of containers, with roughly 0.5–0.7 GB host RAM free on the 8 GB laptop.
- The public repo includes the generated chart, runtime state, AGENTS.md, and the third-party Dremio jar because the user explicitly wants a complete clone. Do not silently remove them.
- `Start Demo.bat` creates the Dremio user and Nessie source only when missing; both persist in `dremio-data` and survive restarts and rebuilds.
- Jupyter and MLflow have no authentication in this stack; keep it local-only and never expose the ports publicly.
- The AI Assistant panel is loopback-only upstream (Ollama's provider hardcodes `allows_remote_access = False`) and `PUT /assistant/config` is a DENY route, so the browser cannot enable or configure it. `Dockerfile.mlflow` runs `setup/enable_mlflow_assistant.py` to flag the provider and seed `~/.mlflow/assistant/config.json`, and compose sets `MLFLOW_ENABLE_REMOTE_ASSISTANT=true`. Both are pinned to MLflow 3.17.2 and fail the build if upstream moves. Host Ollama must run with `OLLAMA_HOST=0.0.0.0:11434`, the seeded model must be pulled, and the Assistant's Bash tool runs inside the MLflow container. If the seeded model is not pulled, point the build at an installed tag with `MLFLOW_ASSISTANT_MODEL=<tag>` in the untracked `.env` and rebuild rather than downloading another model (verified 2026-11-25 with `qwen3.5:4b`). Optional: never make the demo depend on it.
- Dremio's UI is a SQL/table tool, not a chart/dashboard tool.

## Teacher feedback: autologin and Vault

Two separate asks; do not merge them into one feature.

### Autologin (reduce typing)

**Decision 2026-11-23: build the Dremio part only.** The user approved a narrow scope and rejected the rest.

| Item | Decision |
|---|---|
| Auto-provision the Dremio `admin123` user (bootstrap REST) | **Build** |
| Auto-add the Dremio `nessie` source (catalog API) | **Build** |
| Generated Dremio password in an untracked `.env` | **Build** |
| Auto-run the notebook (`nbconvert --execute`) | **Rejected** — a manual `Run All` is safer; an auto-run can add runs and move `champion` |
| Landing page for the four UIs | **Rejected** — out of scope; the launcher already opens the tabs |

Why only one service needs this: of the eight Compose services, only Dremio has an account anyone creates. MinIO's root login is a single `.env` bootstrap value read by `minio`, while `minio-init`, `nessie` and `mlflow` take their S3 keys from Vault KV (see below); Nessie, MLflow and Jupyter have no auth at all. So "autologin" here is two API calls, not an identity system.

Accepted behaviour:

- `Start Demo.bat` calls the bootstrap after Dremio answers on 9047 and **before** the browser tabs open, so the UI never races the API.
- The bootstrap logs in first; if `admin123` already answers, nothing is created. If no user exists, it calls the first-user endpoint once.
- The Nessie source is created only when `catalog/by-path/nessie` returns 404, so a second start never duplicates it.
- Credentials are `admin123` / `admin123`, mirrored into `.env` (`DREMIO_USER`, `DREMIO_PASSWORD`) so one file answers both Dremio and Tableau. `.env` stays untracked; values already in it win.
- If `admin123` exists with a different password than `.env` holds, the bootstrap prints a warning and exits without changing anything. Recovery is setting `DREMIO_PASSWORD` or running `Reset Demo.bat`.

Implementation notes, verified live against Dremio 26.0.5 on 2026-11-23:

- `PUT /apiv2/bootstrap/firstuser` creates the first user; `POST` answers 405 with `Allow: OPTIONS,PUT`.
- Readiness is a **401** on an unauthenticated `GET /api/v3/catalog`. The port opens and the server answers HTTP about 25 s earlier, and a bootstrap attempt in that window is rejected with **400** - the same status as "user already exists", which is why the gate cannot be "any HTTP response".
- Login is `POST /apiv2/login`; Dremio 26 returns a short token sent as `Authorization: _dremio<token>` (not a JWT).
- Source existence is `GET /api/v3/catalog/by-path/nessie` (404 when absent); creation is `POST /api/v3/catalog` with `entityType: source`.
- The Nessie config keys come from `GET /api/v3/source/type/NESSIE`: `nessieEndpoint`, `nessieAuthType: NONE`, `storageProvider: AWS`, `awsRootPath: warehouse`, `credentialType: ACCESS_KEY`, `awsAccessKey`, `awsAccessSecret`, `secure: false`, `propertyList`. It is `awsRootPath`, **not** `rootPath`.
- Verified end to end on clean volumes: bootstrap -> ingestion -> `SELECT COUNT(*) FROM nessie.lakehouse.churn_features` returned **2,500** through the auto-created source.

Still manual afterwards: one `Run All` click for MLflow, Tableau's Dremio password prompt, and the one-time Tableau driver copy. Dremio's own login screen is **not** avoidable — creating the account through the API cannot hand a browser a session, so the password is still typed once per session/token expiry.

### Vault (narrow demo built 2026-11-27)

The teacher also raised service-to-service identity and HashiCorp Vault. What exists now, and what deliberately does not:

**Built:** `hashicorp/vault:2.2.2` in **dev mode** (in-memory, unsealed, root token `lakehouse-dev-root` from `VAULT_DEV_ROOT_TOKEN_ID`) plus a one-shot `vault-init` service running `setup/vault_init.sh`. It writes `secret/lakehouse/minio` (KV v2), writes the read-only `lakehouse-minio-reader` policy, and renders `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` into the shared `vault-creds` volume. `nessie`, `mlflow` and `minio-init` source that file via a small `/bin/sh -c` shim at container start, because Compose cannot interpolate env from a running service.

- Nessie gets its dotted Quarkus properties through `env "nessie.catalog.secrets.access-key.name=..."` — dash rejects `export` with dots in the name, so `env` is required.
- MLflow uses the `sh -c '...; exec "$@"' <name>` trick so its pinned `command:` list is unchanged. In compose, shell variables must be written `$$VAR` or Compose interpolates them first.
- `vault-init` runs as `user: "0:0"`; the named volume is root-owned and the Vault image is unprivileged.
- The Vault flow adds no host dependency: `vault` is a `hashicorp/vault:2.2.2` container (healthcheck `vault status`), and `Reset Demo.bat` / `docker compose down -v` now drop five volumes including `vault-creds`.
- Verified 2026-11-27: KV readable, policy readable, `minio-init` exit 0, MLflow put/get/delete in `s3://mlflow` with the Vault-rendered keys, Nessie PID 1 env carrying the dotted keys, Nessie main at `640214d2...` matching `state/ingest_summary.json`, and `spark-sql` counting **2,500** rows through the Nessie catalog.

**Deliberately not done:** MinIO's own root login is the value being stored, so it must exist before anything can store it — that pair stays the one bootstrap value in `.env`, and `minio` itself still interpolates it. Dev mode keeps secrets in memory, so they are lost on restart and re-seeded on the next start. No dynamic secrets, AppRole, mTLS, rotation or per-service identity: Vault manages machine secrets and does not remove the human Dremio/Tableau login, so those stay the production story for Q&A rather than code.



## Verification and change discipline

Verification means running the demo, not just reading files.

Before claiming a change works:

1. `docker compose config` passes.
2. Core endpoints return 200.
3. Nessie main matches `state/ingest_summary.json` after ingestion.
3b. `vault-init` exits 0, `secret/lakehouse/minio` and the `lakehouse-minio-reader` policy are readable, and a Spark/MLflow S3 read succeeds with the rendered keys.
4. Dremio returns the expected 2,500 rows.
5. MLflow has the expected runs, models, and champion alias.
6. Tableau workbook opens against Dremio.
7. Docs, deck notes, `Presentation_Script.md`, `START HERE.md`, and README remain consistent.
8. A second start does not duplicate the Dremio user or the Nessie source, and a reset recreates exactly one admin (verified 2026-11-23).

Any V2 behavior change must update the synced artifacts: V2 README, `START HERE.md`, deck speaker notes, `Presentation_Script.md`, and this AGENTS.md when instructions change. V1 and the original paper presentation remain frozen.

Do not claim a fresh 16 GB machine or a clean-machine end-to-end run is verified; only the 8 GB laptop path has been tested. Do not claim the demo is one-click from zero: notebook **Run All**, the Tableau driver copy and Tableau's password prompt are still manual.

## Current state

- Presentation: recorded and done.
- Working directory: session moved to `C:\Theara\YEAR 3\SEMESTER 1\PP`; repo at `Data Lakehouse\MLflow Exact Stack V2`.
- Local repo: at `origin/main` (check `git log -1` for the current commit); 30 tracked files before the Vault change, 32 after it (adds `setup/vault_init.sh` and `.gitattributes`). `notebooks/lakehouse_mlflow.ipynb` (Run All outputs), `.env` and the session summaries stay local; `derby.log` and `metastore_db/` are Spark leftovers safe to delete.
- Repo: public.
- Stack: **running as of 2026-11-27** (vault, minio, nessie, mlflow, spark, dremio up; `vault-init` and `minio-init` exited 0; MLflow healthy); on a reset machine, no containers or volumes should be assumed until `Start Demo.bat` or Compose is run.
- ZIP: not present; the public repo is the complete clone source.
- Autologin: Dremio provisioning **implemented and verified** 2026-11-23 (admin123 user, Nessie source, `.env` password, launcher step `[3b/5]`). Notebook auto-run and the landing page were rejected.
- Vault: minimal dev-mode container + `vault-init` **implemented and verified** 2026-11-27 (see "Vault" above). MinIO's own root login is still the bootstrap value in `.env`; full service-to-service auth stays the production story only.
- Stack state after the Vault work: all eight compose services settled (vault, minio, nessie, mlflow, spark, dremio up; `vault-init` and `minio-init` exited 0), Nessie main unchanged at `640214d2...`, MLflow at 4 runs with `churn_classifier@champion` = version 3 (run `aa456c61...`, ROC AUC 0.7995).
