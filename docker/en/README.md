Русская версия: [README_RU.md](../ru/README_RU.md)

# Izum Music — deployment via `deploy.sh`

`deploy.sh` is a bash script for manually deploying Izum Music with Docker (no launcher). It manages four services: **postgresql**, **minio**, **backend** (Spring Boot JAR), and **frontend** (nginx + a built `dist`). Each service can be started, stopped, and updated independently — including across separate servers (database/storage apart from the application). Configuration is supplied via environment variables or a `.env` file next to the script.

## Requirements

- **Docker** with a running daemon (`docker info` must respond). The script verifies daemon availability itself.
- **bash** (uses `set -euo pipefail`, arrays, `/dev/tcp`).
- **curl** — for backend and frontend healthchecks. Without it healthchecks won't work correctly (the script warns but continues).
- **openssl** — to generate JWT secrets (see below).
- From the repository, to run the **frontend**: the `docker/nginx/` directory with nginx templates (`docker/nginx/templates/`) and the entrypoint (`docker/nginx/docker-entrypoint.sh`). Their paths are overridable via `TEMPLATES_DIR_HOST` and `ENTRYPOINT_HOST`.
- Build artifacts: `app.jar` (backend, path in `BACKEND_JAR`) and the frontend `dist` directory (path in `DIST_PATH`, must contain `index.html`).

## Quick start

1. Generate JWT secrets (always with `tr -d '\n'`, otherwise the value will contain a trailing newline):

   ```sh
   openssl rand -base64 64 | tr -d '\n'; echo
   ```

   Run it twice — for `JWT_SECRET_ACCESS` and `JWT_SECRET_REFRESH`.

2. Create a `.env` next to the script (`docker/.env`):

   ```ini
   PG_PASSWORD=change-me-strong
   JWT_SECRET_ACCESS=<paste the generated value>
   JWT_SECRET_REFRESH=<paste the second value>
   BACKEND_JAR=/srv/musicapp/app.jar
   DIST_PATH=/srv/musicapp/dist
   STORAGE_MODE=storage
   ```

3. Restrict file access and start everything:

   ```sh
   chmod 600 docker/.env
   ./deploy.sh up all
   ```

4. Check status:

   ```sh
   ./deploy.sh status
   ```

After startup the frontend is available at `http://localhost:80`, and the backend API at `http://<server>:9090/api`.

## Commands

| Command | Description | Example |
|---|---|---|
| `up <services...>` | Start the selected services | `./deploy.sh up postgres backend` |
| `up all` | Start all four services | `./deploy.sh up all` |
| `down <services...>` | Stop and remove containers of the selected services | `./deploy.sh down frontend backend` |
| `down all` / `down` | Stop everything (no arguments = `all`) | `./deploy.sh down` |
| `status` | Show the state of all containers | `./deploy.sh status` |
| `logs <service>` | Stream logs of a single service (`docker logs -f`) | `./deploy.sh logs backend` |

Valid service names: `postgres`, `minio`, `backend`, `frontend`, plus `all`. An unknown name aborts with an error.

**Start/stop order is fixed and independent of the argument order:**

- `up` always starts in the order `postgres → minio → backend → frontend` (infrastructure → backend → frontend).
- `down` always stops in reverse order `frontend → backend → minio → postgres`.

`logs` accepts exactly one service.

## Configuration

All variables are overridable via the environment or `.env`. Defaults are quoted verbatim from the script.

### General

| Variable | Default | Description | Required |
|---|---|---|---|
| `NETWORK_NAME` | `mal-net` | Docker bridge network name | no |
| `DATA_DIR` | `/srv/musicapp-data` | Base directory for volumes | no |

### PostgreSQL

| Variable | Default | Description | Required |
|---|---|---|---|
| `PG_IMAGE` | `postgres:16-alpine` | PostgreSQL image | no |
| `PG_CONTAINER` | `mal-postgres` | Container name (and in-network DNS name) | no |
| `PG_PORT` | `5432` | Host-published port (`-p PG_PORT:5432`) | no |
| `PG_USER` | `postgres` | Database user | no |
| `PG_PASSWORD` | *(empty)* | Database password | **yes** (postgres, backend) |
| `PG_DB` | `musicapp` | Database name | no |
| `PG_DATA` | `${DATA_DIR}/postgres` | Host directory for PostgreSQL data | no |

### MinIO

| Variable | Default | Description | Required |
|---|---|---|---|
| `MINIO_IMAGE` | `minio/minio:latest` | MinIO image | no |
| `MINIO_CONTAINER` | `mal-minio` | Container name (and DNS name) | no |
| `MINIO_PORT` | `9000` | S3 API host port | no |
| `MINIO_CONSOLE_PORT` | `9001` | Web console host port | no |
| `MINIO_ROOT_USER` | *(empty)* | Root user (access key) | **yes** (minio, and backend when `STORAGE_MODE=minio`) |
| `MINIO_ROOT_PASSWORD` | *(empty)* | Root password (secret key), `>= 8` chars | **yes** (minio) |
| `MINIO_DATA` | `${DATA_DIR}/minio` | Host directory for MinIO data | no |
| `MINIO_BUCKET` | `music` | Bucket name (created automatically) | no |

### Backend

| Variable | Default | Description | Required |
|---|---|---|---|
| `BACKEND_IMAGE` | `eclipse-temurin:21-jre` | Base image to run the JAR | no |
| `BACKEND_CONTAINER` | `mal-backend` | Container name (and DNS name) | no |
| `BACKEND_PORT` | `9090` | Backend port (host and container) | no |
| `BACKEND_JAR` | *(empty)* | Path to `app.jar` on the host | **yes** (backend) |
| `BACKEND_XMX` | `2g` | JVM heap limit (`-Xmx`) | no |
| `STORAGE_MODE` | `storage` | Storage type: `storage` (filesystem) or `minio` | no |
| `STORAGE_PATH` | `${DATA_DIR}/storage` | Filesystem storage directory (for `storage`) | no |
| `JWT_SECRET_ACCESS` | *(empty)* | JWT access secret, `>= 32` chars | **yes** (backend) |
| `JWT_SECRET_REFRESH` | *(empty)* | JWT refresh secret, `>= 32` chars | **yes** (backend) |
| `FLYWAY_ENABLED` | `true` | Enable Flyway migrations | no |
| `DDL_AUTO` | `validate` | Hibernate DDL: `validate`/`create`/`update` | no |
| `APP_HTTPS` | `false` | `true` if the frontend serves over HTTPS | no |
| `DB_HOST` | `${PG_CONTAINER}` | Database host (in-network DNS name or external address) | no |
| `DB_PORT_INTERNAL` | `5432` | Internal database port for the backend connection | no |
| `MINIO_ENDPOINT` | `http://${MINIO_CONTAINER}:9000` | MinIO endpoint for the backend | no |

### Frontend

| Variable | Default | Description | Required |
|---|---|---|---|
| `FRONTEND_IMAGE` | `nginx:1.27-alpine` | nginx image | no |
| `FRONTEND_CONTAINER` | `mal-frontend` | Container name | no |
| `FRONTEND_HOST_PORT` | `80` | Host HTTP port | no |
| `FRONTEND_HOST_SSL_PORT` | `443` | Host HTTPS port (only when `ENABLE_SSL=true`) | no |
| `DIST_PATH` | *(empty)* | Built frontend directory (with `index.html`) | **yes** (frontend) |
| `TEMPLATES_DIR_HOST` | `${SCRIPT_DIR}/docker/nginx/templates` | nginx templates on the host | no |
| `ENTRYPOINT_HOST` | `${SCRIPT_DIR}/docker/nginx/docker-entrypoint.sh` | Frontend container entrypoint | no |
| `ENABLE_SSL` | `false` | Enable HTTPS | no |
| `AUTO_GENERATE_SELF_SIGNED` | `true` | Generate a self-signed certificate when `ENABLE_SSL=true` | no |
| `SERVER_NAME` | `localhost` | nginx `server_name` | no |
| `SSL_DIR_HOST` | `${SCRIPT_DIR}/docker/ssl` | Host certificate directory (mounted to `/etc/nginx/ssl`) | no |
| `BACKEND_UPSTREAM` | `http://${BACKEND_CONTAINER}:${BACKEND_PORT}` | Upstream for proxying API/WS | no |
| `PROXY_API` | `true` | Proxy `/api` to the backend | no |
| `PROXY_WS` | `true` | Proxy WebSocket to the backend | no |
| `CLIENT_MAX_BODY_SIZE` | `60g` | nginx `client_max_body_size` | no |

## Deployment scenarios

### a) Single server, filesystem storage (`STORAGE_MODE=storage`)

`.env`:

```ini
PG_PASSWORD=strong-db-pass
JWT_SECRET_ACCESS=<openssl rand -base64 64 | tr -d '\n'>
JWT_SECRET_REFRESH=<second secret>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
STORAGE_MODE=storage
```

```sh
./deploy.sh up postgres backend frontend
```

MinIO is not needed. Files live in `STORAGE_PATH` (default `/srv/musicapp-data/storage`) under the `tracks`, `covers`, and `artists` subdirectories.

### b) Single server with MinIO (`STORAGE_MODE=minio`)

```ini
PG_PASSWORD=strong-db-pass
MINIO_ROOT_USER=musicadmin
MINIO_ROOT_PASSWORD=minio-strong-pass
JWT_SECRET_ACCESS=<secret>
JWT_SECRET_REFRESH=<secret>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
STORAGE_MODE=minio
```

```sh
./deploy.sh up all
```

The `music` bucket is created automatically, and the backend uses the default `MINIO_ENDPOINT` (`http://mal-minio:9000` inside the network).

### c) Split deployment (DB+MinIO and application on separate servers)

**Server 1 (data):**

```ini
PG_PASSWORD=strong-db-pass
MINIO_ROOT_USER=musicadmin
MINIO_ROOT_PASSWORD=minio-strong-pass
```

```sh
./deploy.sh up postgres minio
```

Ports `5432`, `9000`, `9001` are published on the host (see the "Security" section).

**Server 2 (application):**

```ini
PG_PASSWORD=strong-db-pass
DB_HOST=10.0.0.10
DB_PORT_INTERNAL=5432
MINIO_ROOT_USER=musicadmin
MINIO_ROOT_PASSWORD=minio-strong-pass
MINIO_ENDPOINT=http://10.0.0.10:9000
STORAGE_MODE=minio
JWT_SECRET_ACCESS=<secret>
JWT_SECRET_REFRESH=<secret>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
```

```sh
./deploy.sh up backend frontend
```

Since the backend and frontend share the `mal-net` network, `BACKEND_UPSTREAM` stays at its default (`http://mal-backend:9090`).

### d) Production: domain + real certificate

```ini
PG_PASSWORD=strong-db-pass
JWT_SECRET_ACCESS=<secret>
JWT_SECRET_REFRESH=<secret>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
STORAGE_MODE=storage
ENABLE_SSL=true
AUTO_GENERATE_SELF_SIGNED=false
SSL_DIR_HOST=/srv/musicapp/ssl
SERVER_NAME=music.example.com
APP_HTTPS=true
```

Place `fullchain.pem` and `privkey.pem` (e.g. from Let's Encrypt) into `SSL_DIR_HOST`, then:

```sh
./deploy.sh up all
```

Access: `https://music.example.com` (HTTP redirects to HTTPS). `APP_HTTPS=true` tells the backend the external scheme is HTTPS.

## How it works (details)

- **Docker network.** The script creates the `NETWORK_NAME` bridge network (default `mal-net`) if it does not exist. All containers attach to it and can reach each other by container DNS names (`mal-postgres`, `mal-minio`, `mal-backend`). That is why the default `DB_HOST`, `MINIO_ENDPOINT`, and `BACKEND_UPSTREAM` point at container names.
- **Data storage.** All volumes live under `DATA_DIR` (`/srv/musicapp-data`): `postgres/` (`PG_DATA`), `minio/` (`MINIO_DATA`), and `storage/` with the `tracks`, `covers`, `artists` subdirectories (`STORAGE_PATH`). These are host bind mounts, so data survives `down`/`up` — stopping removes only the containers, not the directories.
- **Container recreation.** On every `up` the backend and frontend are removed and recreated (`remove_if_exists`) — this picks up an updated JAR/dist and env. PostgreSQL and MinIO are **not** recreated if already running (`container_running` → exits with an "already running" message).
- **PostgreSQL version guard.** Before starting postgres the script reads `${PG_DATA}/PG_VERSION` and compares it to the major version parsed from `PG_IMAGE`. On a mismatch it aborts with an error suggesting you change `PG_IMAGE` or remove the volume. This prevents data corruption by an incompatible server.
- **MinIO bucket.** After MinIO starts, the script runs a one-off `minio/mc:latest` container performing `mc alias set` + `mc mb -p m/${MINIO_BUCKET}`. On failure it warns (the backend may create the bucket itself) but deployment continues.
- **Healthchecks and timeouts:**
  - **postgres:** `pg_isready -U $PG_USER` in a loop, up to 30s, otherwise an error.
  - **minio:** waits for the `MINIO_PORT` TCP port via `/dev/tcp`, up to 20s.
  - **backend:** a 5s pause after start (early-crash check), then `curl -fsS http://127.0.0.1:$BACKEND_PORT/api/health` in a loop up to 120s; on a container crash it prints `docker logs --tail 40` and errors out; on a health timeout it warns (the container stays).
  - **frontend:** waits for the `FRONTEND_HOST_PORT` TCP port, up to 15s, then `curl` on `/__nginx_health` (HTTP or HTTPS). No response → a warning.
- **Frontend container.** The container mounts: `DIST_PATH` → `/usr/share/nginx/html` (ro), `TEMPLATES_DIR_HOST` → `/mal/templates` (ro), `ENTRYPOINT_HOST` → `/mal/docker-entrypoint.sh` (ro), and `SSL_DIR_HOST` → `/etc/nginx/ssl` (if the directory exists). It runs with `--entrypoint /mal/docker-entrypoint.sh` and the variables `ENABLE_SSL`, `AUTO_GENERATE_SELF_SIGNED`, `SERVER_NAME`, `BACKEND_UPSTREAM`, `PROXY_API`, `PROXY_WS`, `CLIENT_MAX_BODY_SIZE`, `TEMPLATES_DIR=/mal/templates`. The entrypoint substitutes these values into the templates (envsubst) and renders the nginx config; with `ENABLE_SSL=true` and `AUTO_GENERATE_SELF_SIGNED=true` it generates a self-signed certificate, otherwise it expects real `fullchain.pem`/`privkey.pem` in the mounted directory.

> Note: `docker/nginx/templates/` and `docker/nginx/docker-entrypoint.sh` are shipped from the repository and may be absent in this tree — obtain them from the project sources. The script itself does not define the template contents.

## Security

- **`.env` permissions:** `chmod 600 docker/.env` — the file holds passwords and JWT secrets.
- **`.gitignore`:** add `docker/.env` (and the certificate directory) to `.gitignore` so secrets are never committed.
- **Secret requirements:** `JWT_SECRET_ACCESS` and `JWT_SECRET_REFRESH` must be at least 32 chars (enforced by the script); `MINIO_ROOT_PASSWORD` must be at least 8 chars (enforced by the script).
- **No newlines in secrets:** values must not contain `\n`. That is exactly why JWT is generated with `openssl rand -base64 64 | tr -d '\n'` — without the trailing `tr` you get a newline and the container receives a broken secret.
- **Port publishing.** The script always publishes ports on the host via `-p`: postgres `PG_PORT:5432`, minio `MINIO_PORT:9000` and `MINIO_CONSOLE_PORT:9001`, backend `BACKEND_PORT:BACKEND_PORT`, frontend `FRONTEND_HOST_PORT:80` (+ `FRONTEND_HOST_SSL_PORT:443` with SSL). For a single-server deployment there is no need to expose PG/MinIO externally — communication happens over the internal `mal-net` network. The script does not support disabling publishing via a flag; to close the ports, restrict access with a firewall (ufw/iptables/security group). Changing the publishing format (e.g. to `127.0.0.1:5432:5432`) requires editing the script.

## Troubleshooting

| Problem | Cause | Solution |
|---|---|---|
| `Backend crashed right after start` | Config/database connection error, wrong JAR | `./deploy.sh logs backend` or `docker logs mal-backend`; check `DB_HOST`, `PG_PASSWORD`, database availability |
| nginx fails with `host not found in upstream` | Frontend started without the backend while `BACKEND_UPSTREAM` points at the `mal-backend` container | Start the backend, or set an external `BACKEND_UPSTREAM`, or `PROXY_API=false PROXY_WS=false` |
| `Volume ... holds PG X data, image is PG Y` | Data version does not match the image | Set `PG_IMAGE=postgres:X-alpine` or remove `PG_DATA` (data loss) |
| Backend: `health did not respond within 120s` | Slow start/migrations or a hang | Inspect `docker logs -f mal-backend`; check Flyway and the database connection |
| Frontend: `healthcheck did not respond` | Template/certificate error | `docker logs mal-frontend`; check `TEMPLATES_DIR_HOST` and certificate validity in `SSL_DIR_HOST` |
| `Frontend did not open the port within 15s` | nginx failed to start (broken config/upstream) | `docker logs mal-frontend`; usually `host not found in upstream` (see above) |
| `MinIO did not open the port within 20s` | MinIO failed to start or the port is busy | `docker logs mal-minio`; verify `MINIO_PORT`/`MINIO_CONSOLE_PORT` are free |
| Port busy (`address already in use`) | A host port is already used by another process | Free the port or override `PG_PORT`/`MINIO_PORT`/`BACKEND_PORT`/`FRONTEND_HOST_PORT` |
| `PG_PASSWORD is required` / `JWT_SECRET_* is required` | Required variables are not set | Set them in `.env`; JWT — `openssl rand -base64 64 | tr -d '\n'` (>= 32 chars) |
| `Docker daemon unavailable` | The daemon is not running or you lack permissions | `systemctl start docker`; add your user to the `docker` group |