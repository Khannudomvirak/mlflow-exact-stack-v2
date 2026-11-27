@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo   Lakehouse + MLflow  -  Full demo (Dremio included)
echo ============================================================

docker info >nul 2>&1
if not errorlevel 1 goto docker_ready

set "DOCKER_EXE=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
if not exist "%DOCKER_EXE%" set "DOCKER_EXE=%LOCALAPPDATA%\Docker\Docker Desktop.exe"
if not exist "%DOCKER_EXE%" (
  echo Docker Desktop was not found in the usual places.
  echo Start it manually, wait for the engine, then run this file again.
  pause
  exit /b 1
)

echo [0/5] Starting Docker Desktop...
start "" "%DOCKER_EXE%"
echo       Waiting for the Docker engine (up to 3 minutes)...
for /l %%i in (1,1,90) do (
  timeout /t 2 /nobreak >nul
  docker info >nul 2>&1 && goto docker_ready
)
echo Docker Desktop did not become ready in time.
echo Open it manually, wait for the engine, then run this file again.
pause
exit /b 1

:docker_ready
echo [1/5] Starting Vault, MinIO, Nessie, MLflow, Spark+Jupyter and Dremio...
docker compose --profile dremio up -d --build
if errorlevel 1 goto fail

echo [2/5] Waiting for the core services to answer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$urls=@('http://localhost:5000/health','http://localhost:8888/api','http://localhost:19120/api/v2/trees/main','http://localhost:9000/minio/health/live','http://localhost:8200/v1/sys/health'); foreach($u in $urls){$ok=$false; for($i=0;$i -lt 90;$i++){try{$r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 $u; if($r.StatusCode -eq 200){$ok=$true;break}}catch{}; Start-Sleep -Seconds 2}; if(-not $ok){Write-Host ('Timed out waiting for ' + $u); exit 1}}; Write-Host 'Core services are up.'"
if errorlevel 1 goto fail

echo [3/5] Waiting for Dremio (1-2 minutes on first start)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i -lt 150;$i++){ $t=New-Object Net.Sockets.TcpClient; try{$t.Connect('127.0.0.1',9047); $ok=$true; $t.Close(); break}catch{}; Start-Sleep -Seconds 2 }; if(-not $ok){Write-Host 'Dremio did not open port 9047 in time.'; exit 1}; Write-Host 'Dremio is up.'"
if errorlevel 1 goto fail

echo [3b/5] Creating the Dremio admin123 user and the Nessie source...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\dremio_bootstrap.ps1"
if errorlevel 1 echo       Provisioning skipped - set Dremio up by hand (see README.md).

powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:11434/api/tags | Out-Null; exit 0 } catch { exit 1 }"
if errorlevel 1 (
  echo.
  echo Ollama is not answering on http://127.0.0.1:11434.
  echo The MLflow Assistant needs it; the rest of the demo does not.
  echo Start the Ollama app, or run these in a second window:
  echo   set OLLAMA_HOST=0.0.0.0:11434
  echo   ollama serve
  echo.
) else (
  echo Ollama is answering on port 11434 - the MLflow Assistant backend is available.
)
set "NEED_INGEST=1"
if exist "state\ingest_summary.json" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=Get-Content -LiteralPath 'state\ingest_summary.json' -Raw | ConvertFrom-Json; $h=(Invoke-RestMethod 'http://localhost:19120/api/v2/trees/main').reference.hash; if ($h -eq $s.batch_2.commit) { exit 0 } else { exit 1 }"
  if not errorlevel 1 set "NEED_INGEST=0"
)
if "%NEED_INGEST%"=="1" (
  echo [4/5] Creating the two Iceberg versions in the lakehouse...
  docker compose exec -T spark spark-submit --master "local[2]" /workspace/jobs/ingest.py
  if errorlevel 1 goto fail
) else (
  echo [4/5] Lakehouse already holds the verified versions - keeping them.
)

set "HAS_RUNS=1"
docker compose exec -T mlflow python3 -c "import sqlite3; c=sqlite3.connect('/mlflow/mlflow.db'); n=c.execute('select count(*) from runs').fetchone()[0]; raise SystemExit(0 if n != 0 else 1)" >nul 2>&1
if errorlevel 1 set "HAS_RUNS=0"

echo [5/5] Opening the UIs...
start "" http://localhost:5000
start "" http://localhost:8888/lab/tree/notebooks/lakehouse_mlflow.ipynb
start "" http://localhost:9001
start "" http://localhost:19120/api/v2/trees/main
start "" http://localhost:9047

echo.
echo The deck is not opened for you: double-click MLflow_Exact_Stack_V2_Presentation.pptx,
echo then press Alt+F5 for Presenter View. The talk track is Presentation_Script.md.
echo   1. Slides 1-5: follow the presenter notes.
if "%HAS_RUNS%"=="0" (
  echo   2. Slide 6: MLflow is empty - choose Run All to create the two runs.
) else (
  echo   2. Slide 6: MLflow already has runs; open the notebook and show them.
  echo      Run All again only if you want a live run; it adds runs and moves the champion.
)
echo   3. MLflow: experiment churn-lakehouse-exact-stack - open rf-100 (v1 champion).
echo   MinIO: http://localhost:9001 - login minioadmin / minioadmin
  echo   Vault: http://localhost:8200 - dev mode, token lakehouse-dev-root
  echo          The MinIO keys live in secret/lakehouse/minio (see README.md).
echo   4. Dremio: http://localhost:9047 - admin123 and the Nessie source are ready.
echo        Log in as admin123 / admin123.
echo        Query: SELECT * FROM nessie.lakehouse.churn_features LIMIT 20;
echo   5. Tableau: open Tableau_Churn_Dashboard.twb (driver in Tableau Driver).
echo        Use the same Dremio password (admin123); tick "Save password" to stop retyping.
echo.
echo   Close other heavy apps before the demo.
echo   If Docker feels tight, see README.md for WSL memory guidance.
echo.
pause
exit /b 0

:fail
echo.
echo Something failed. Inspect the logs with:
echo   docker compose logs --tail=80
pause
exit /b 1
