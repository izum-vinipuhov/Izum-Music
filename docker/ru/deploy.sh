#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  deploy.sh — MusicApp server deployment (advanced users)
#
#  Запускает любой набор сервисов в Docker:
#    • postgresql  (postgres:16-alpine)
#    • minio       (minio/minio:latest)
#    • backend     (Spring Boot JAR в eclipse-temurin:21-jre)
#    • frontend    (nginx:1.27-alpine + dist + шаблоны лаунчера)
#
#  Использование:
#    ./deploy.sh up [postgres] [minio] [backend] [frontend]
#    ./deploy.sh up all
#    ./deploy.sh down [сервисы...|all]
#    ./deploy.sh status
#    ./deploy.sh logs <сервис>
#
#  Конфигурация — через env-переменные или файл .env рядом со скриптом.
#  Пример: BACKEND_JAR=/srv/musicapp/app.jar DIST_PATH=/srv/musicapp/dist \
#          ./deploy.sh up all
# ════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Подхватываем .env, если есть ────────────────────────────────────
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/.env"
    set +a
fi

# ════════════════════════════════════════════════════════════════════
#  Конфигурация (все значения переопределяемы через env)
# ════════════════════════════════════════════════════════════════════

# ── Общее ────────────────────────────────────────────────────────────
NETWORK_NAME="${NETWORK_NAME:-mal-net}"
DATA_DIR="${DATA_DIR:-/srv/musicapp-data}" # база для volume'ов

# ── PostgreSQL ───────────────────────────────────────────────────────
PG_IMAGE="${PG_IMAGE:-postgres:16-alpine}"
PG_CONTAINER="${PG_CONTAINER:-mal-postgres}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-}" # ОБЯЗАТЕЛЬНО задать!
PG_DB="${PG_DB:-musicapp}"
PG_DATA="${PG_DATA:-${DATA_DIR}/postgres}"

# ── MinIO ────────────────────────────────────────────────────────────
MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:latest}"
MINIO_CONTAINER="${MINIO_CONTAINER:-mal-minio}"
MINIO_PORT="${MINIO_PORT:-9000}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-}" # ОБЯЗАТЕЛЬНО при запуске minio
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
MINIO_DATA="${MINIO_DATA:-${DATA_DIR}/minio}"
MINIO_BUCKET="${MINIO_BUCKET:-music}"

# ── Backend (Spring Boot) ────────────────────────────────────────────
BACKEND_IMAGE="${BACKEND_IMAGE:-eclipse-temurin:21-jre}"
BACKEND_CONTAINER="${BACKEND_CONTAINER:-mal-backend}"
BACKEND_PORT="${BACKEND_PORT:-9090}"
BACKEND_JAR="${BACKEND_JAR:-}" # путь к app.jar (обязателен)
BACKEND_XMX="${BACKEND_XMX:-2g}"
STORAGE_MODE="${STORAGE_MODE:-storage}" # storage | minio
STORAGE_PATH="${STORAGE_PATH:-${DATA_DIR}/storage}"
JWT_SECRET_ACCESS="${JWT_SECRET_ACCESS:-}" # >=32 символа
JWT_SECRET_REFRESH="${JWT_SECRET_REFRESH:-}"
FLYWAY_ENABLED="${FLYWAY_ENABLED:-true}"
DDL_AUTO="${DDL_AUTO:-validate}" # validate | create | update
APP_HTTPS="${APP_HTTPS:-false}"  # true если фронт на HTTPS
# Если postgres/minio НЕ в этом стеке — укажите внешние адреса:
DB_HOST="${DB_HOST:-${PG_CONTAINER}}" # DNS-имя в mal-net по умолчанию
DB_PORT_INTERNAL="${DB_PORT_INTERNAL:-5432}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://${MINIO_CONTAINER}:9000}"

# ── Frontend (nginx) ─────────────────────────────────────────────────
FRONTEND_IMAGE="${FRONTEND_IMAGE:-nginx:1.27-alpine}"
FRONTEND_CONTAINER="${FRONTEND_CONTAINER:-mal-frontend}"
FRONTEND_HOST_PORT="${FRONTEND_HOST_PORT:-80}"
FRONTEND_HOST_SSL_PORT="${FRONTEND_HOST_SSL_PORT:-443}"
DIST_PATH="${DIST_PATH:-}" # папка с собранным dist (обязательна)
TEMPLATES_DIR_HOST="${TEMPLATES_DIR_HOST:-${SCRIPT_DIR}/docker/nginx/templates}"
ENTRYPOINT_HOST="${ENTRYPOINT_HOST:-${SCRIPT_DIR}/docker/nginx/docker-entrypoint.sh}"
ENABLE_SSL="${ENABLE_SSL:-false}"
AUTO_GENERATE_SELF_SIGNED="${AUTO_GENERATE_SELF_SIGNED:-true}"
SERVER_NAME="${SERVER_NAME:-localhost}"
SSL_DIR_HOST="${SSL_DIR_HOST:-${SCRIPT_DIR}/docker/ssl}"
BACKEND_UPSTREAM="${BACKEND_UPSTREAM:-http://${BACKEND_CONTAINER}:${BACKEND_PORT}}"
PROXY_API="${PROXY_API:-true}"
PROXY_WS="${PROXY_WS:-true}"
CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-60g}"

# ════════════════════════════════════════════════════════════════════
#  Утилиты
# ════════════════════════════════════════════════════════════════════
log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker не найден в PATH"
    docker info >/dev/null 2>&1 || die "Docker daemon недоступен (проверьте права / systemctl start docker)"
    command -v curl >/dev/null 2>&1 || warn "curl не найден — health-чеки backend/frontend будут работать некорректно"
}

ensure_network() {
    if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
        log "Создаю сеть ${NETWORK_NAME}"
        docker network create --driver bridge "${NETWORK_NAME}" >/dev/null
    fi
}

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; }
container_exists() { docker inspect "$1" >/dev/null 2>&1; }

remove_if_exists() {
    if container_exists "$1"; then
        log "Удаляю старый контейнер $1"
        docker rm -f "$1" >/dev/null
    fi
}

wait_for_port() {
    # wait_for_port host port timeout_sec
    local host="$1" port="$2" timeout="${3:-30}" i=0
    while [ "$i" -lt "$timeout" ]; do
        if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
            exec 3>&-
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# ════════════════════════════════════════════════════════════════════
#  Сервисы
# ════════════════════════════════════════════════════════════════════

up_postgres() {
    [ -n "${PG_PASSWORD}" ] || die "PG_PASSWORD обязателен (export PG_PASSWORD=... или в .env)"
    mkdir -p "${PG_DATA}"

    # Защита от несовместимой версии данных
    if [ -f "${PG_DATA}/PG_VERSION" ]; then
        existing="$(cat "${PG_DATA}/PG_VERSION")"
        expected="$(echo "${PG_IMAGE}" | sed -n 's/.*postgres:\([0-9]*\).*/\1/p')"
        if [ -n "${expected}" ] && [ "${existing}" != "${expected}" ]; then
            die "Volume ${PG_DATA} содержит данные PG ${existing}, а образ — PG ${expected}. Смените PG_IMAGE=postgres:${existing}-alpine или удалите volume."
        fi
    fi

    if container_running "${PG_CONTAINER}"; then
        log "PostgreSQL уже запущен"
        return
    fi
    remove_if_exists "${PG_CONTAINER}"

    log "Запуск PostgreSQL (${PG_IMAGE}) → порт ${PG_PORT}"
    docker run -d \
        --name "${PG_CONTAINER}" \
        --network "${NETWORK_NAME}" \
        --restart unless-stopped \
        -p "${PG_PORT}:5432" \
        -v "${PG_DATA}:/var/lib/postgresql/data" \
        -e POSTGRES_USER="${PG_USER}" \
        -e POSTGRES_PASSWORD="${PG_PASSWORD}" \
        -e POSTGRES_DB="${PG_DB}" \
        "${PG_IMAGE}" >/dev/null

    log "Ожидание готовности БД…"
    i=0
    until docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -ge 30 ] && die "PostgreSQL не поднялся за 30s (docker logs ${PG_CONTAINER})"
        sleep 1
    done
    log "PostgreSQL готов ✓"
}

up_minio() {
    [ -n "${MINIO_ROOT_USER}" ] && [ -n "${MINIO_ROOT_PASSWORD}" ] ||
        die "MINIO_ROOT_USER / MINIO_ROOT_PASSWORD обязательны"
    [ "${#MINIO_ROOT_PASSWORD}" -ge 8 ] || die "MINIO_ROOT_PASSWORD должен быть >= 8 символов"
    mkdir -p "${MINIO_DATA}"

    if container_running "${MINIO_CONTAINER}"; then
        log "MinIO уже запущен"
        return
    fi
    remove_if_exists "${MINIO_CONTAINER}"

    log "Запуск MinIO (${MINIO_IMAGE}) → API :${MINIO_PORT}, console :${MINIO_CONSOLE_PORT}"
    docker run -d \
        --name "${MINIO_CONTAINER}" \
        --network "${NETWORK_NAME}" \
        --restart unless-stopped \
        -p "${MINIO_PORT}:9000" \
        -p "${MINIO_CONSOLE_PORT}:9001" \
        -v "${MINIO_DATA}:/data" \
        -e MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
        -e MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
        "${MINIO_IMAGE}" \
        server /data --console-address ":9001" >/dev/null

    wait_for_port 127.0.0.1 "${MINIO_PORT}" 20 || die "MinIO не открыл порт за 20s"

    log "Создаю бакет ${MINIO_BUCKET} (если отсутствует)…"
    docker run --rm --network "${NETWORK_NAME}" --entrypoint sh minio/mc:latest -c \
        "mc alias set m http://${MINIO_CONTAINER}:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' >/dev/null && mc mb -p m/${MINIO_BUCKET}" \
        >/dev/null 2>&1 || warn "Не удалось создать бакет ${MINIO_BUCKET} — возможно, бекенд создаст его сам"

    log "MinIO готов ✓ (console: http://<server>:${MINIO_CONSOLE_PORT})"
}

up_backend() {
    [ -n "${BACKEND_JAR}" ] || die "BACKEND_JAR не задан (путь к app.jar)"
    [ -f "${BACKEND_JAR}" ] || die "JAR не найден: ${BACKEND_JAR}"
    [ "${#JWT_SECRET_ACCESS}" -ge 32 ] || die "JWT_SECRET_ACCESS обязателен (>=32 символа). Сгенерируйте: openssl rand -base64 64 | tr -d '\n'"
    [ "${#JWT_SECRET_REFRESH}" -ge 32 ] || die "JWT_SECRET_REFRESH обязателен (>=32 символа)"
    [ -n "${PG_PASSWORD}" ] || die "PG_PASSWORD обязателен для подключения бекенда к БД"

    remove_if_exists "${BACKEND_CONTAINER}" # пересоздаём всегда: JAR/env могли измениться

    # env-набор по аналогии с buildBackendEnv лаунчера
    env_args=(
        -e "SPRING_DATASOURCE_URL=jdbc:postgresql://${DB_HOST}:${DB_PORT_INTERNAL}/${PG_DB}"
        -e "SPRING_DATASOURCE_USERNAME=${PG_USER}"
        -e "SPRING_DATASOURCE_PASSWORD=${PG_PASSWORD}"
        -e "SPRING_FLYWAY_ENABLED=${FLYWAY_ENABLED}"
        -e "SPRING_JPA_HIBERNATE_DDL_AUTO=${DDL_AUTO}"
        -e "JWT_SECRET_ACCESS=${JWT_SECRET_ACCESS}"
        -e "JWT_SECRET_REFRESH=${JWT_SECRET_REFRESH}"
        -e "APP_HTTPS=${APP_HTTPS}"
        -e "SERVER_FORWARD_HEADERS_STRATEGY=framework"
        -e "SERVER_SHUTDOWN=graceful"
        -e "LOGGING_LEVEL_ROOT=INFO"
        -e "SPRING_OUTPUT_ANSI_ENABLED=NEVER"
        -e "SPRING_JPA_OPEN_IN_VIEW=false"
        -e "SPRING_SERVLET_MULTIPART_MAX_FILE_SIZE=60GB"
        -e "SPRING_SERVLET_MULTIPART_MAX_REQUEST_SIZE=60GB"
        -e "MUSIC_STORAGE_TYPE=${STORAGE_MODE}"
    )

    mount_args=(-v "${BACKEND_JAR}:/app/app.jar:ro")

    if [ "${STORAGE_MODE}" = "minio" ]; then
        [ -n "${MINIO_ROOT_USER}" ] || die "STORAGE_MODE=minio: нужны MINIO_ROOT_USER/MINIO_ROOT_PASSWORD"
        env_args+=(
            -e "MUSIC_STORAGE_MINIO_ENDPOINT=${MINIO_ENDPOINT}"
            -e "MUSIC_STORAGE_MINIO_ACCESS_KEY=${MINIO_ROOT_USER}"
            -e "MUSIC_STORAGE_MINIO_SECRET_KEY=${MINIO_ROOT_PASSWORD}"
            -e "MUSIC_STORAGE_MINIO_BUCKET=${MINIO_BUCKET}"
        )
    else
        mkdir -p "${STORAGE_PATH}/tracks" "${STORAGE_PATH}/covers" "${STORAGE_PATH}/artists"
        mount_args+=(-v "${STORAGE_PATH}:/data")
        env_args+=(
            -e "MUSIC_STORAGE_TRACKS_DIR=/data/tracks"
            -e "MUSIC_STORAGE_COVERS_DIR=/data/covers"
            -e "MUSIC_STORAGE_ARTISTS_DIR=/data/artists"
        )
    fi

    log "Запуск backend (${BACKEND_IMAGE}) → порт ${BACKEND_PORT}"
    docker run -d \
        --name "${BACKEND_CONTAINER}" \
        --network "${NETWORK_NAME}" \
        --restart unless-stopped \
        --add-host host.docker.internal:host-gateway \
        -p "${BACKEND_PORT}:${BACKEND_PORT}" \
        -w /app \
        "${mount_args[@]}" \
        "${env_args[@]}" \
        "${BACKEND_IMAGE}" \
        java -Xmx"${BACKEND_XMX}" \
        -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 \
        -jar /app/app.jar --server.port="${BACKEND_PORT}" >/dev/null

    # Проверка раннего краша
    sleep 5
    container_running "${BACKEND_CONTAINER}" ||
        {
            docker logs --tail 40 "${BACKEND_CONTAINER}"
            die "Backend упал сразу после старта (логи выше)"
        }

    log "Ожидание health-чека…"
    i=0
    until curl -fsS "http://127.0.0.1:${BACKEND_PORT}/api/health" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && {
            warn "health не ответил за 120s — смотрите: docker logs -f ${BACKEND_CONTAINER}"
            return
        }
        container_running "${BACKEND_CONTAINER}" ||
            {
                docker logs --tail 40 "${BACKEND_CONTAINER}"
                die "Backend упал во время старта"
            }
        sleep 1
    done
    log "Backend online ✓ (http://<server>:${BACKEND_PORT}/api)"
}

up_frontend() {
    [ -n "${DIST_PATH}" ] || die "DIST_PATH не задан (папка с собранным фронтендом)"
    [ -f "${DIST_PATH}/index.html" ] || die "index.html не найден в ${DIST_PATH} — соберите фронт (pnpm build)"
    [ -d "${TEMPLATES_DIR_HOST}" ] || die "Шаблоны nginx не найдены: ${TEMPLATES_DIR_HOST} (нужна папка docker/nginx из репозитория)"
    [ -f "${ENTRYPOINT_HOST}" ] || die "Entrypoint не найден: ${ENTRYPOINT_HOST}"
    chmod +x "${ENTRYPOINT_HOST}" 2>/dev/null || true

    if [ "${ENABLE_SSL}" = "true" ] && [ "${AUTO_GENERATE_SELF_SIGNED}" != "true" ]; then
        [ -f "${SSL_DIR_HOST}/fullchain.pem" ] && [ -f "${SSL_DIR_HOST}/privkey.pem" ] ||
            die "ENABLE_SSL=true: положите fullchain.pem и privkey.pem в ${SSL_DIR_HOST}"
    fi

    # Если проксируем на контейнер бекенда — он должен быть запущен,
    # иначе nginx упадёт на старте с "host not found in upstream"
    if [ "${PROXY_API}" = "true" ] || [ "${PROXY_WS}" = "true" ]; then
        case "${BACKEND_UPSTREAM}" in
            *"${BACKEND_CONTAINER}"*)
                container_running "${BACKEND_CONTAINER}" ||
                    warn "BACKEND_UPSTREAM=${BACKEND_UPSTREAM}, но контейнер ${BACKEND_CONTAINER} не запущен — nginx упадёт на старте. Укажите внешний BACKEND_UPSTREAM или PROXY_API=false PROXY_WS=false."
                ;;
        esac
    fi

    remove_if_exists "${FRONTEND_CONTAINER}"

    port_args=(-p "${FRONTEND_HOST_PORT}:80")
    [ "${ENABLE_SSL}" = "true" ] && port_args+=(-p "${FRONTEND_HOST_SSL_PORT}:443")

    ssl_mount=()
    [ -d "${SSL_DIR_HOST}" ] && ssl_mount=(-v "${SSL_DIR_HOST}:/etc/nginx/ssl")

    log "Запуск frontend (${FRONTEND_IMAGE}) → HTTP :${FRONTEND_HOST_PORT}$([ "${ENABLE_SSL}" = "true" ] && echo ", HTTPS :${FRONTEND_HOST_SSL_PORT}")"
    docker run -d \
        --name "${FRONTEND_CONTAINER}" \
        --network "${NETWORK_NAME}" \
        --restart unless-stopped \
        --add-host host.docker.internal:host-gateway \
        "${port_args[@]}" \
        -v "${DIST_PATH}:/usr/share/nginx/html:ro" \
        -v "${TEMPLATES_DIR_HOST}:/mal/templates:ro" \
        -v "${ENTRYPOINT_HOST}:/mal/docker-entrypoint.sh:ro" \
        ${ssl_mount[@]+"${ssl_mount[@]}"} \
        -e ENABLE_SSL="${ENABLE_SSL}" \
        -e AUTO_GENERATE_SELF_SIGNED="${AUTO_GENERATE_SELF_SIGNED}" \
        -e SERVER_NAME="${SERVER_NAME}" \
        -e BACKEND_UPSTREAM="${BACKEND_UPSTREAM}" \
        -e PROXY_API="${PROXY_API}" \
        -e PROXY_WS="${PROXY_WS}" \
        -e CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE}" \
        -e TEMPLATES_DIR=/mal/templates \
        --entrypoint /mal/docker-entrypoint.sh \
        "${FRONTEND_IMAGE}" \
        nginx -g 'daemon off;' >/dev/null

    log "Ожидание готовности nginx…"
    wait_for_port 127.0.0.1 "${FRONTEND_HOST_PORT}" 15 ||
        {
            docker logs --tail 40 "${FRONTEND_CONTAINER}"
            die "Frontend не открыл порт за 15s (логи выше)"
        }

    # Healthcheck из шаблонов (__nginx_health отдаёт 'ok')
    if curl -fsS "http://127.0.0.1:${FRONTEND_HOST_PORT}/__nginx_health" >/dev/null 2>&1 ||
        curl -fsSk "https://127.0.0.1:${FRONTEND_HOST_SSL_PORT}/__nginx_health" >/dev/null 2>&1; then
        log "Frontend online ✓"
    else
        warn "Контейнер запущен, но healthcheck не ответил — проверьте: docker logs ${FRONTEND_CONTAINER}"
    fi

    if [ "${ENABLE_SSL}" = "true" ]; then
        log "Доступ: https://${SERVER_NAME}:${FRONTEND_HOST_SSL_PORT} (HTTP :${FRONTEND_HOST_PORT} → redirect)"
    else
        log "Доступ: http://${SERVER_NAME}:${FRONTEND_HOST_PORT}"
    fi
}

# ════════════════════════════════════════════════════════════════════
#  Остановка
# ════════════════════════════════════════════════════════════════════

down_service() {
    # down_service <имя контейнера> <человекочитаемое имя>
    local cn="$1" label="$2"
    if container_exists "${cn}"; then
        log "Останавливаю ${label} (${cn})…"
        docker stop -t 30 "${cn}" >/dev/null 2>&1 || true
        docker rm "${cn}" >/dev/null 2>&1 || true
        log "${label} остановлен ✓"
    else
        log "${label}: контейнер ${cn} не найден — пропуск"
    fi
}

down_postgres() { down_service "${PG_CONTAINER}" "PostgreSQL"; }
down_minio() { down_service "${MINIO_CONTAINER}" "MinIO"; }
down_backend() { down_service "${BACKEND_CONTAINER}" "Backend"; }
down_frontend() { down_service "${FRONTEND_CONTAINER}" "Frontend"; }

# ════════════════════════════════════════════════════════════════════
#  Status / logs
# ════════════════════════════════════════════════════════════════════

status() {
    printf '%-14s %-16s %s\n' "SERVICE" "CONTAINER" "STATE"
    printf '%-14s %-16s %s\n' "──────" "─────────" "─────"
    for pair in \
        "postgres:${PG_CONTAINER}" \
        "minio:${MINIO_CONTAINER}" \
        "backend:${BACKEND_CONTAINER}" \
        "frontend:${FRONTEND_CONTAINER}"; do
        svc="${pair%%:*}"
        cn="${pair#*:}"
        if container_exists "${cn}"; then
            state="$(docker inspect -f '{{.State.Status}} (up {{.State.StartedAt}})' "${cn}" 2>/dev/null)"
        else
            state="not created"
        fi
        printf '%-14s %-16s %s\n' "${svc}" "${cn}" "${state}"
    done
}

logs_for() {
    case "$1" in
    postgres) docker logs -f --tail 100 "${PG_CONTAINER}" ;;
    minio) docker logs -f --tail 100 "${MINIO_CONTAINER}" ;;
    backend) docker logs -f --tail 200 "${BACKEND_CONTAINER}" ;;
    frontend) docker logs -f --tail 100 "${FRONTEND_CONTAINER}" ;;
    *) die "Неизвестный сервис: $1 (доступны: postgres, minio, backend, frontend)" ;;
    esac
}

# ════════════════════════════════════════════════════════════════════
#  Разбор аргументов
# ════════════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
Использование: $0 <команда> [сервисы...]

Команды:
  up [postgres] [minio] [backend] [frontend]   — запустить выбранные сервисы
  up all                                       — запустить всё
  down [сервисы...|all]                        — остановить
  status                                       — статус контейнеров
  logs <сервис>                                — стрим логов сервиса

Минимальные обязательные переменные:
  postgres:  PG_PASSWORD
  minio:     MINIO_ROOT_USER, MINIO_ROOT_PASSWORD
  backend:   BACKEND_JAR, PG_PASSWORD, JWT_SECRET_ACCESS, JWT_SECRET_REFRESH
  frontend:  DIST_PATH (+ docker/nginx/ из репозитория)
EOF
    exit 1
}

# ════════════════════════════════════════════════════════════════════
#  Точка входа
# ════════════════════════════════════════════════════════════════════

[ $# -ge 1 ] || usage
CMD="$1"
shift || true

SERVICES="$*"

# Раскрываем 'all' в полный список сервисов
if [ "${SERVICES}" = "all" ]; then
    SERVICES="postgres minio backend frontend"
fi

# Валидация имён сервисов (для up/down/logs)
case "${CMD}" in
    up|down|logs)
        for s in ${SERVICES}; do
            case "$s" in
                postgres|minio|backend|frontend) ;;
                *) die "Неизвестный сервис: '$s' (доступны: postgres, minio, backend, frontend, all)" ;;
            esac
        done
        ;;
esac

case "${CMD}" in
up)
    [ -n "${SERVICES}" ] || usage
    require_docker
    ensure_network
    # Порядок старта: инфраструктура → backend → frontend
    for s in postgres minio backend frontend; do
        case " ${SERVICES} " in
        *" ${s} "*) "up_${s}" ;;
        esac
    done
    echo
    status
    ;;
down)
    # Без аргументов — останавливаем всё
    [ -n "${SERVICES}" ] || SERVICES="postgres minio backend frontend"
    require_docker
    # Обратный порядок: frontend → backend → инфраструктура
    for s in frontend backend minio postgres; do
        case " ${SERVICES} " in
        *" ${s} "*) "down_${s}" ;;
        esac
    done
    ;;
status)
    require_docker
    status
    ;;
logs)
    [ -n "${SERVICES}" ] || die "Укажите сервис: $0 logs backend"
    require_docker
    logs_for "${SERVICES}"
    ;;
*)
    usage
    ;;
esac
