# Exact-Stack Lakehouse — MinIO + Iceberg + Nessie + Spark + Jupyter + MLflow

This is the exact-stack follow-up demo: it keeps the architecture from the
professor's drawing and uses the **actual components**:

```
Sources (CSV batches)
      |
      v
Spark ingestion job
      |
      v
MinIO (S3)  ──  Parquet data files
      |          Iceberg table metadata
      |          Nessie catalog (warehouse = s3://warehouse/)
      |
      +──────────────> Spark (local[2]) ──> JupyterLab ──> MLflow
      |
      +──────────────> Dremio (optional profile) ──> Tableau dashboard
```

The data path is real: the table is stored in object storage, cataloged by
Nessie, and read by Spark. MLflow is the added layer that records which exact
data version each model learned from.

## What is running

| Diagram box | In this folder | Version |
|---|---|---|
| Sources | `data/churn_batch_1.csv`, `data/churn_batch_2.csv` | 2,000 + 500 rows |
| Data ingestion | `jobs/ingest.py` (Spark) | Spark 3.5.9 |
| Secrets | **Vault** dev server: one AppRole + KV path + MinIO user per service | 2.2.2 |
| S3 data lake | **MinIO**, bucket `warehouse` | `RELEASE.2026-10-23` |
| Iceberg tables | Apache Iceberg, Parquet data files | 1.11.0 |
| Catalog | **Nessie** REST catalog, RocksDB persistence | 0.109.0 |
| Compute engine (ML path) | Spark `local[2]` | 3.5.9 |
| Notebooks | JupyterLab | 4.4+ |
| Model lifecycle | **MLflow** tracking server + registry, artifacts in S3 | 3.17.2 |
| Compute engine (BI path) | Dremio | optional profile; verified running here |
| Dashboards | **Tableau Desktop (Free Edition)** via Dremio | `Tableau_Churn_Dashboard.twb` included |

### Vault: each service logs in as itself

Vault 2.2.2 runs in **dev mode**: in-memory store, already unsealed, fixed root
token `lakehouse-dev-root`. Only the one-shot `vault-init` container holds that
token. For each consumer it generates an S3 key pair at that service's own path
(`secret/lakehouse/s3/nessie`, `secret/lakehouse/s3/mlflow`), writes a policy that
can read only that path, and creates an AppRole with a one-hour token TTL plus
that role's `role_id` / `secret_id` in the service's own volume.

Each consumer runs a small `*-creds` sidecar, which is the Vault image again. It
logs in through that AppRole, reads only its own secret, and renders
`S3_ACCESS_KEY` / `S3_SECRET_KEY` into a volume that only its own service mounts.
No two services share a credential, and no service ever sees the root token.

The storage side matches. `minio-provision` (the pinned MinIO image, which ships
`mc`) registers that same key pair as a MinIO user restricted to one bucket:
`nessie-svc` on `warehouse`, `mlflow-svc` on `mlflow`, each with a canned policy
that allows list/read/write inside its bucket and nothing else.

```bash
docker compose logs vault-init minio-provision nessie-creds mlflow-creds
docker compose exec vault sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=lakehouse-dev-root vault kv get secret/lakehouse/s3/mlflow'
docker compose exec vault sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=lakehouse-dev-root vault policy read lakehouse-s3-nessie'
```

To see the least privilege, log in as one service and try to read another
service's key or write its own:

```bash
docker compose run --rm --no-deps --entrypoint sh nessie-creds -c '
  export VAULT_ADDR=http://vault:8200
  export VAULT_TOKEN=$(vault write -field=token auth/approle/login \
    role_id="$(cat /approle/role_id)" secret_id="$(cat /approle/secret_id)")
  vault read -field=policies auth/token/lookup-self            # [default lakehouse-s3-nessie]
  vault kv get -field=access_key secret/lakehouse/s3/nessie    # allowed
  vault kv get -field=access_key secret/lakehouse/s3/mlflow    # 403
  vault kv put secret/lakehouse/s3/nessie access_key=x secret_key=y'  # 403
```

The same split holds at the bucket level: MLflow's key cannot list `warehouse`
and Nessie's cannot list `mlflow`; both answer `AccessDenied`.

Vault UI: <http://localhost:8200>, token `lakehouse-dev-root` (set
`VAULT_DEV_ROOT_TOKEN_ID` in `.env` to change it; `VAULT_PORT` moves the port).

Two limits are deliberate. MinIO's own root login has to exist before anything
can store it, so that pair still arrives from `.env`; it is kept at
`secret/lakehouse/minio` for Dremio and for humans, readable only by the root
token. And dev mode keeps secrets in memory, so they are lost on restart and
re-seeded on the next start: there is no token renewal, rotation or revocation
here.

### Dremio and the BI branch

For the full Dremio + Tableau stack, double-click **`Start Demo.bat`**. It starts the
stack with Dremio, waits for port 9047, loads the two versions if needed, and
opens the UIs. Then do the one-time user + Nessie source setup below. The
manual commands here are the fallback.

Dremio is an optional Compose profile and **it now runs on this laptop**:
verified on 2026-10-25 with the full stack (measured ~3.3 GB of containers,
host RAM bottoming at ~0.5 GB free). The key is the WSL VM cap: **6 GB** in
`~/.wslconfig` (`memory=6GB`, `swap=4GB`). At the old 7.4 GiB cap the first
image pull froze the machine, so pull once with the stack stopped:

```bash
# one-time: pull the image with nothing else running
docker compose stop
docker compose --profile dremio pull dremio

# normal start (everything, including Dremio)
docker compose --profile dremio up -d
```

On Windows `Start Demo.bat` does this for you: `setup/dremio_bootstrap.ps1`
creates the **`admin123`** user and the **Nessie** source through the Dremio REST
API. Nothing is typed in the UI, and a second start creates nothing. Log in at
`http://localhost:9047` as **`admin123`** / **`admin123`** - that is also the
password Tableau asks for. Dremio requires 8+ characters with a digit, so
`admin` alone is refused; set `DREMIO_PASSWORD` in `.env` to override it.

The manual steps below are the fallback for macOS/Linux and for an existing
`admin123` whose password differs from `.env`: create the first user with
username **`admin123`** and your own password, and add a **Nessie** source at
`http://nessie:19120/api/v2` with Nessie authentication **none**. In **Storage**
choose **AWS**, then enter `warehouse` after the fixed `s3://` prefix (the full
value is `s3://warehouse`; do not add a leading slash). Use **AWS Access Key**
with `minioadmin` / `minioadmin`, and add the connection properties
`fs.s3a.path.style.access=true`, `fs.s3a.endpoint=minio:9000`, and
`dremio.s3.compat=true`; uncheck **Encrypt connection**.
Query `SELECT * FROM nessie.lakehouse.churn_features LIMIT 20;`. The Tableau
workbook connects to this Dremio server afterwards.

### Tableau dashboard (included)

`Tableau_Churn_Dashboard.twb` is the live BI deliverable: it reads the same
`nessie.lakehouse.churn_features` table through Dremio and shows three bar
charts (churn by contract, tenure group and internet service) on the
**Churn Dashboard** tab. It uses a custom SQL relation with the same query and
the verified Dremio native connector on `localhost:31010`.

To open it on another machine:

1. Install Tableau Desktop. The **Free Edition** is enough; publishing and
   sharing are not used.
2. Copy `Tableau Driver\dremio-jdbc-driver-26.0.5.jar` into
   `%USERPROFILE%\Documents\My Tableau Repository\Drivers` and restart Tableau
   if it was already open. Tableau does not ship the Dremio driver. The
   complete demo—including the 48 MB driver jar—is in both the ZIP and the
   GitHub clone.
3. Start the full stack, open the workbook, and enter `admin123` for the
   `admin123` user when prompted; tick **Save password** so it stops asking. Dremio
   must be running.
4. Open the **Churn Dashboard** tab. The proof screenshot is
   `assets/Tableau_Churn_Dashboard.png`.

The workbook stores calculated fields (`Churn Rate` = `AVG([churned])`, and
`Tenure Group` = 0-11 / 12-23 / 24-47 / 48+ months) and percentage formats, so
it opens ready to show. Tableau is a desktop app, not a Compose service; it is
not included in the container memory figures.

Caveats: on the 8 GB laptop close other heavy apps and do not run the notebook
(Spark kernel) while Dremio is up - switch between the ML and BI paths. On a
16 GB machine, 10 GB is a safe WSL cap; on 12 GB use 8 GB. Portable setup on
bigger hardware is still untested. Steps are in `START HERE.md`; the proof image
is `assets/Tableau_Churn_Dashboard.png`. Capture a Dremio query screenshot as
`Dremio proof.png` beside it if you want both branches.

### Optional: the AI assistant panel (beta)

MLflow 3.17 ships an **Assistant** tab that can answer questions about the live
tracking data. Upstream it only answers clients on `127.0.0.1`, which a
Docker-published port can never be, so `Dockerfile.mlflow` runs
`setup/enable_mlflow_assistant.py` to lift that check and seed the provider.
Ollama is the backend because it needs no API key.

1. Install [Ollama](https://ollama.com) on the host and pull the model: `ollama pull qwen2.5-coder:3b`.
2. Start it so the container can reach it: `OLLAMA_HOST=0.0.0.0:11434 ollama serve`.
3. Rebuild once: `docker compose build mlflow && docker compose up -d mlflow`.
4. Open the **Assistant** tab inside an experiment page.

A different model: `MLFLOW_ASSISTANT_MODEL=qwen3.5:4b docker compose build mlflow`.

Caveats - this is a beta extra, not part of the demo path. The panel cannot save
its own settings (that route stays loopback-only), so the model is fixed at build
time. The Assistant's Bash tool runs inside the MLflow container, not on the
host. The patch is tied to MLflow 3.17.2 and fails the build loudly if a version
bump moves the code. Every evaluation run is plain MLflow; the assistant is only
for asking questions.

## Hardware reality (important)

- Host: **8.2 GB RAM** (7.6 GiB), 12 cores. The WSL VM is capped at **6 GB**
  (`memory=6GB`, `swap=4GB` in `~/.wslconfig`); this is what lets the whole
  stack, including Dremio, run without starving Windows. The default ~3.9 GB
  was too small, and the 7.4 GiB setting froze the host during a Dremio pull.
- Measured 2026-10-25 with the full stack + Dremio: Dremio ~1.3 GB, MLflow
  ~1.6 GB, Spark/Jupyter ~90 MB idle, Nessie ~245 MB, MinIO ~62 MB - about
  **3.3 GB of containers**, host free RAM ~0.5-0.7 GB.
- The stack is tuned for this machine: MLflow runs with one worker, Spark uses a
  768 MB driver, Nessie a 512 MB heap and a 32 MB cache. Dremio runs at its
  required 4 GB heap - its minimum; smaller values are refused.
- Practical limit: one path at a time. Showing Dremio live plus running the
  notebook (Spark kernel) is too much for 8 GB; switch between them.

## Run it

### One click (recommended)

**Start here:** open **`START HERE.md`**; it has the MinIO login, the Dremio
password location, and the Run All step. A fresh machine does not need a reset.

Double-click **`Start Demo.bat`**. It starts Docker Desktop if it is not
already running, builds and starts the full stack including Dremio, waits for
MinIO / Nessie / MLflow / Jupyter, and loads the two Iceberg versions only when
the lakehouse does not already have them. It then opens the UIs:

- JupyterLab: <http://localhost:8888/lab/tree/notebooks/lakehouse_mlflow.ipynb>
- MLflow: <http://localhost:5000>
- MinIO console: <http://localhost:9001> (`minioadmin` / `minioadmin`)
- Nessie API: <http://localhost:19120/api/v2/trees/main>
- Vault: <http://localhost:8200> (token `lakehouse-dev-root`; dev mode)
- Dremio: <http://localhost:9047>

`Start Demo.bat` is the only launcher in the folder. It always uses the
full Dremio profile; `Reset Demo.bat` is the only utility, and forced ingestion
is a manual command below.

Keeping the existing lakehouse is deliberate: the saved outputs and MLflow runs
are shown as-is, and the script does not re-run the notebook. Slide 5 uses
`<training-hash>` / `<current-hash>` slots rather than fixed values, so a reset
does not invalidate it; the notebook and MLflow show the live hashes. If MLflow
has no runs yet (for example after a reset), click Run All once. Running it
again adds new runs and moves the `champion` alias; reset first for a clean
version-1 demo.

The first run downloads images and builds the Spark image (roughly 2 GB, several
minutes); the Dremio profile also pulls the Dremio image (~5 GB). Later runs are
cached. For the full BI branch, use `Start Demo.bat`; the manual
equivalent is `docker compose --profile dremio up -d` (see the Dremio section).

### Manual commands

```bash
# start everything
docker compose up -d --build

# create the two Iceberg versions (2,000 then 2,500 rows)
docker compose exec -T spark spark-submit --master "local[2]" /workspace/jobs/ingest.py

# optional: run the notebook headlessly (it already has outputs saved)
docker compose exec -T spark bash -lc \
  "cd /workspace && jupyter nbconvert --to notebook --execute --inplace notebooks/lakehouse_mlflow.ipynb"

# stop, keeping the data
docker compose down

# wipe all volumes (including optional Dremio)
docker compose --profile dremio down -v
```

`Start Demo.bat` reruns ingestion only when the lakehouse does not match
`state/ingest_summary.json`. To force a rerun, use the `spark-submit` command
above; to wipe all volumes, use the reset command below.

## The 4-minute demo

1. **JupyterLab** — open `notebooks/lakehouse_mlflow.ipynb`. The saved outputs
   are already there; click **Run All** only if you want a live run. After a
   reset, Run All is required once and creates the two runs and v1.
   - Cell 3 shows the two Nessie commits and their row counts.
   - Cell 5 reads the same table at commit 1 (2,000 rows) and commit 2
     (2,500 rows): time travel on the exact data version.
   - Cell 7 trains `rf-100` and `rf-300`, logs metrics, the model and
     `training_nessie_commit` to MLflow.
   - Cell 9 sets the `champion` alias and loads it back through
     `models:/churn_classifier@champion`.
2. **MLflow** — experiment `churn-lakehouse-exact-stack`:
   - open either run → **Parameters** → `training_nessie_commit`
   - **Metrics** → compare `roc_auc` (≈0.799 vs ≈0.785)
   - **Artifacts** → `model/` and `plots/churn_by_contract.png`
   - **Models** → `churn_classifier` → versions 1/2 and the `champion` alias
3. **MinIO** — bucket `warehouse` → `lakehouse/churn_features_<uuid>/`:
   - `data/*.parquet` — the actual table data
   - `metadata/*.metadata.json` — Iceberg metadata (the current snapshot)
4. **Nessie** — `http://localhost:19120/api/v2/trees/main` shows the current
   commit hash. That hash is what MLflow logged.
5. **Dremio (optional)** — `http://localhost:9047` → Nessie source →
   `SELECT * FROM nessie.lakehouse.churn_features LIMIT 20;` (one-time user
   setup with username `admin123`; see the Dremio section).
6. **Tableau** — open `Tableau_Churn_Dashboard.twb`, enter the Dremio password,
   and show the **Churn Dashboard** tab. The Dremio driver must be installed
   once (see the Tableau section).

### The Nessie nuance (say this if asked)

Nessie deliberately returns **only the Iceberg snapshot that belongs to the
current Nessie commit**. It keeps the Git-like history itself, so time travel is
done with the Nessie commit hash:

```sql
SELECT * FROM nessie.lakehouse.`churn_features#<commit-hash>`;
```

That is why the MLflow parameter is `training_nessie_commit`, not an old
`training_snapshot_id`. The data version is still exact and reproducible; the
version handle is the catalog commit.

## Reset

Double-click **`Reset Demo.bat`**, or run:

```bash
docker compose --profile dremio down -v
```

This removes the MinIO data, Nessie RocksDB store, MLflow SQLite database,
Dremio data (if the optional profile was used) and the five Vault volumes (`approle-nessie`, `approle-mlflow`, `s3-creds-nessie`,
`s3-creds-mlflow`, `s3seed`); a stack created before these volumes existed can also
leave an unused `vault-creds` volume, which `down -v` removes;
Vault is in-memory and starts empty anyway. The notebook's saved outputs
stay in the file. `Start Demo.bat` reloads the data; click Run All once
after the reset to recreate the two runs and v1. A reset creates new Nessie
commit hashes; slide 5
uses hash slots, so it stays valid—read the live values from the notebook or
MLflow (the row counts and metrics are deterministic). The Tableau workbook and
its driver live outside Docker and are not wiped; after the reset, `Start Demo.bat`
recreates the Dremio `admin123` user and Nessie source itself, so just reopen the
workbook and enter the password.

## Troubleshooting

- **`docker compose` cannot connect** — `Start Demo.bat` starts Docker
  Desktop if it is installed. If it still fails, open Docker Desktop, wait for
  the engine, and run it again.
- **S3 access breaks after restarting Vault** — Vault keeps its store in memory, so
  `docker compose restart vault` empties it. `vault-init` restores the same keys from
  the `s3seed` volume on the next `up`, and running services keep working meanwhile.
  If that volume was deleted the keys rotate, so recreate the consumers:
  `docker compose up -d --force-recreate nessie mlflow`.
- **Port already in use** — change `MLFLOW_PORT`, `JUPYTER_PORT`, `MINIO_API_PORT`,
  `MINIO_CONSOLE_PORT`, `NESSIE_PORT` or `VAULT_PORT` in a `.env` file next to
  `docker-compose.yml`. Dremio's ports `9047`, `31010`, and `32010` are fixed;
  stop the conflicting app instead.
- **Notebook says `state/ingest_summary.json` is missing** — run the manual
  `spark-submit` command above. `Start Demo.bat` loads the data
  automatically when it is missing.
- **MLflow returns `Invalid Host header`** — the compose file already allows
  the `mlflow:5000` host used inside the Docker network. If you change the
  service name, update `--allowed-hosts`.
- **Spark job is slow on the first run** — the JVM and Iceberg jars are warming
  up; subsequent runs are faster.
- **Docker Desktop crashes** — close other memory-heavy apps. This laptop has
  8 GB total; the full stack measured about 3.3 GB of containers.
- **Tableau says the Dremio driver is missing** — copy
  `Tableau Driver\dremio-jdbc-driver-26.0.5.jar` into
  `%USERPROFILE%\Documents\My Tableau Repository\Drivers`, then restart Tableau.
- **Tableau cannot connect or asks for a password** — start the full stack
  with `Start Demo.bat` (Dremio on port 9047), sign in as `admin123` with the
  password chosen in Dremio; the workbook connects to `localhost:31010`.
  Recreate the Dremio source after a reset.

## Files

```
MLflow Exact Stack V2/
├── docker-compose.yml          Vault, MinIO, Nessie, MLflow, Spark+Jupyter, optional Dremio
├── Dockerfile.spark            Spark 3.5.9 + Iceberg 1.11.0 + Jupyter + MLflow client
├── Dockerfile.mlflow           MLflow 3.17.2 + boto3 for S3 artifacts, plus the assistant patch
├── conf/spark-defaults.conf    Nessie REST catalog + memory settings
├── data/                       the two source batches (deterministic synthetic churn)
├── jobs/
│   ├── make_data.py            regenerate the source batches
│   └── ingest.py               Spark ingestion, two Nessie commits, time-travel check
├── notebooks/
│   └── lakehouse_mlflow.ipynb  training, MLflow logging, champion alias, chart
├── state/ingest_summary.json   commit hashes + row counts from the last ingestion
├── setup/vault_init.sh         seeds Vault KV, then one policy + AppRole per service
├── setup/vault_fetch.sh        per-service sidecar: AppRole login, renders only its keys
├── setup/minio_provision.sh    one bucket-scoped MinIO user per service, via mc
├── assets/                     logos + Tableau_Churn_Dashboard.png proof
├── Tableau_Churn_Dashboard.twb live churn dashboard (Dremio -> Tableau)
├── Tableau Driver/             Dremio JDBC driver for the workbook
├── Start Demo.bat              the single launcher: full stack + Dremio
├── Reset Demo.bat              wipe all Docker volumes
├── START HERE.md               the one-page guide for everyone
├── Presentation_Script.md      readable speaker notes / talk track
├── Lakehouse_Explainer.png     one-image visual explainer
├── MLflow_Exact_Stack_V2_Presentation.pptx   the 7-slide V2 deck
└── README.md
```

The V2 deck lives in this folder; its speaker notes are the full talk track
(no separate script). The Q&A slide is the prepared answer set.

## Screenshots

### Key Images

![Lakehouse Explainer](Lakehouse_Explainer.png)

![Tableau Dashboard](assets/Tableau_Churn_Dashboard.png)

