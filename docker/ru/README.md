English version: [README.md](../en/README.md)

# Izum Music — деплой через `deploy.sh`

`deploy.sh` — bash-скрипт для ручного развёртывания Izum Music в Docker без лаунчера. Он управляет четырьмя сервисами: **postgresql**, **minio**, **backend** (Spring Boot JAR) и **frontend** (nginx + собранный `dist`). Каждый сервис можно запускать, останавливать и обновлять независимо — в том числе на разных серверах (БД/хранилище отдельно от приложения). Конфигурация задаётся через env-переменные или файл `.env` рядом со скриптом.

## Требования

- **Docker** с запущенным daemon (`docker info` должен отвечать). Скрипт сам проверяет доступность daemon.
- **bash** (используется `set -euo pipefail`, массивы, `/dev/tcp`).
- **curl** — для health-чеков backend и frontend. Без него health-чеки работают некорректно (скрипт выдаёт предупреждение, но продолжает).
- **openssl** — для генерации JWT-секретов (см. ниже).
- Из репозитория для запуска **frontend**: папка `docker/nginx/` с шаблонами nginx (`docker/nginx/templates/`) и entrypoint (`docker/nginx/docker-entrypoint.sh`). Пути переопределяются через `TEMPLATES_DIR_HOST` и `ENTRYPOINT_HOST`.
- Собранные артефакты: `app.jar` (backend, путь в `BACKEND_JAR`) и каталог `dist` фронтенда (путь в `DIST_PATH`, внутри должен быть `index.html`).

## Быстрый старт

1. Сгенерируйте JWT-секреты (обязательно с `tr -d '\n'`, иначе в значении окажется перенос строки):

   ```sh
   openssl rand -base64 64 | tr -d '\n'; echo
   ```

   Выполните дважды — для `JWT_SECRET_ACCESS` и `JWT_SECRET_REFRESH`.

2. Создайте `.env` рядом со скриптом (`docker/.env`):

   ```ini
   PG_PASSWORD=change-me-strong
   JWT_SECRET_ACCESS=<вставьте сгенерированное значение>
   JWT_SECRET_REFRESH=<вставьте второе значение>
   BACKEND_JAR=/srv/musicapp/app.jar
   DIST_PATH=/srv/musicapp/dist
   STORAGE_MODE=storage
   ```

3. Ограничьте доступ к файлу и запустите всё:

   ```sh
   chmod 600 docker/.env
   ./deploy.sh up all
   ```

4. Проверьте статус:

   ```sh
   ./deploy.sh status
   ```

После старта фронтенд доступен на `http://localhost:80`, backend API — на `http://<server>:9090/api`.

## Команды

| Команда | Описание | Пример |
|---|---|---|
| `up <сервисы...>` | Запустить выбранные сервисы | `./deploy.sh up postgres backend` |
| `up all` | Запустить все четыре сервиса | `./deploy.sh up all` |
| `down <сервисы...>` | Остановить и удалить контейнеры выбранных сервисов | `./deploy.sh down frontend backend` |
| `down all` / `down` | Остановить всё (без аргументов = `all`) | `./deploy.sh down` |
| `status` | Показать состояние всех контейнеров | `./deploy.sh status` |
| `logs <сервис>` | Стрим логов одного сервиса (`docker logs -f`) | `./deploy.sh logs backend` |

Допустимые имена сервисов: `postgres`, `minio`, `backend`, `frontend`, а также `all`. Неизвестное имя приводит к ошибке.

**Порядок старта/остановки фиксирован и не зависит от порядка аргументов:**

- `up` всегда стартует в порядке: `postgres → minio → backend → frontend` (инфраструктура → backend → frontend).
- `down` всегда останавливает в обратном порядке: `frontend → backend → minio → postgres`.

`logs` принимает ровно один сервис.

## Конфигурация

Все переменные переопределяются через окружение или `.env`. Дефолты приведены дословно из скрипта.

### Общее

| Переменная | По умолчанию | Описание | Обяз. |
|---|---|---|---|
| `NETWORK_NAME` | `mal-net` | Имя bridge-сети Docker | нет |
| `DATA_DIR` | `/srv/musicapp-data` | Базовый каталог для volume'ов | нет |

### PostgreSQL

| Переменная | По умолчанию | Описание | Обяз. |
|---|---|---|---|
| `PG_IMAGE` | `postgres:16-alpine` | Образ PostgreSQL | нет |
| `PG_CONTAINER` | `mal-postgres` | Имя контейнера (и DNS-имя в сети) | нет |
| `PG_PORT` | `5432` | Порт, публикуемый на хост (`-p PG_PORT:5432`) | нет |
| `PG_USER` | `postgres` | Имя пользователя БД | нет |
| `PG_PASSWORD` | *(пусто)* | Пароль БД | **да** (postgres, backend) |
| `PG_DB` | `musicapp` | Имя базы данных | нет |
| `PG_DATA` | `${DATA_DIR}/postgres` | Каталог данных PostgreSQL на хосте | нет |

### MinIO

| Переменная | По умолчанию | Описание | Обяз. |
|---|---|---|---|
| `MINIO_IMAGE` | `minio/minio:latest` | Образ MinIO | нет |
| `MINIO_CONTAINER` | `mal-minio` | Имя контейнера (и DNS-имя) | нет |
| `MINIO_PORT` | `9000` | Порт S3 API на хост | нет |
| `MINIO_CONSOLE_PORT` | `9001` | Порт web-консоли на хост | нет |
| `MINIO_ROOT_USER` | *(пусто)* | Root-пользователь (access key) | **да** (minio, и backend при `STORAGE_MODE=minio`) |
| `MINIO_ROOT_PASSWORD` | *(пусто)* | Root-пароль (secret key), `>= 8` символов | **да** (minio) |
| `MINIO_DATA` | `${DATA_DIR}/minio` | Каталог данных MinIO на хосте | нет |
| `MINIO_BUCKET` | `music` | Имя бакета (создаётся автоматически) | нет |

### Backend

| Переменная | По умолчанию | Описание | Обяз. |
|---|---|---|---|
| `BACKEND_IMAGE` | `eclipse-temurin:21-jre` | Базовый образ для запуска JAR | нет |
| `BACKEND_CONTAINER` | `mal-backend` | Имя контейнера (и DNS-имя) | нет |
| `BACKEND_PORT` | `9090` | Порт backend (хост и контейнер) | нет |
| `BACKEND_JAR` | *(пусто)* | Путь к `app.jar` на хосте | **да** (backend) |
| `BACKEND_XMX` | `2g` | Лимит heap JVM (`-Xmx`) | нет |
| `STORAGE_MODE` | `storage` | Тип хранилища: `storage` (ФС) или `minio` | нет |
| `STORAGE_PATH` | `${DATA_DIR}/storage` | Каталог файлового хранилища (для `storage`) | нет |
| `JWT_SECRET_ACCESS` | *(пусто)* | JWT-секрет access, `>= 32` символа | **да** (backend) |
| `JWT_SECRET_REFRESH` | *(пусто)* | JWT-секрет refresh, `>= 32` символа | **да** (backend) |
| `FLYWAY_ENABLED` | `true` | Включение Flyway-миграций | нет |
| `DDL_AUTO` | `validate` | Hibernate DDL: `validate`/`create`/`update` | нет |
| `APP_HTTPS` | `false` | `true`, если фронт работает по HTTPS | нет |
| `DB_HOST` | `${PG_CONTAINER}` | Хост БД (DNS-имя в сети или внешний адрес) | нет |
| `DB_PORT_INTERNAL` | `5432` | Внутренний порт БД для подключения backend | нет |
| `MINIO_ENDPOINT` | `http://${MINIO_CONTAINER}:9000` | Endpoint MinIO для backend | нет |

### Frontend

| Переменная | По умолчанию | Описание | Обяз. |
|---|---|---|---|
| `FRONTEND_IMAGE` | `nginx:1.27-alpine` | Образ nginx | нет |
| `FRONTEND_CONTAINER` | `mal-frontend` | Имя контейнера | нет |
| `FRONTEND_HOST_PORT` | `80` | HTTP-порт на хост | нет |
| `FRONTEND_HOST_SSL_PORT` | `443` | HTTPS-порт на хост (только при `ENABLE_SSL=true`) | нет |
| `DIST_PATH` | *(пусто)* | Каталог собранного фронтенда (с `index.html`) | **да** (frontend) |
| `TEMPLATES_DIR_HOST` | `${SCRIPT_DIR}/docker/nginx/templates` | Шаблоны nginx на хосте | нет |
| `ENTRYPOINT_HOST` | `${SCRIPT_DIR}/docker/nginx/docker-entrypoint.sh` | Entrypoint фронтенд-контейнера | нет |
| `ENABLE_SSL` | `false` | Включить HTTPS | нет |
| `AUTO_GENERATE_SELF_SIGNED` | `true` | Генерировать self-signed сертификат при `ENABLE_SSL=true` | нет |
| `SERVER_NAME` | `localhost` | `server_name` для nginx | нет |
| `SSL_DIR_HOST` | `${SCRIPT_DIR}/docker/ssl` | Каталог с сертификатами на хосте (монтируется в `/etc/nginx/ssl`) | нет |
| `BACKEND_UPSTREAM` | `http://${BACKEND_CONTAINER}:${BACKEND_PORT}` | Upstream для проксирования API/WS | нет |
| `PROXY_API` | `true` | Проксировать `/api` на backend | нет |
| `PROXY_WS` | `true` | Проксировать WebSocket на backend | нет |
| `CLIENT_MAX_BODY_SIZE` | `60g` | `client_max_body_size` nginx | нет |

## Сценарии развёртывания

### а) Один сервер, файловое хранилище (`STORAGE_MODE=storage`)

`.env`:

```ini
PG_PASSWORD=strong-db-pass
JWT_SECRET_ACCESS=<openssl rand -base64 64 | tr -d '\n'>
JWT_SECRET_REFRESH=<второй секрет>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
STORAGE_MODE=storage
```

```sh
./deploy.sh up postgres backend frontend
```

MinIO не нужен. Файлы лежат в `STORAGE_PATH` (по умолчанию `/srv/musicapp-data/storage`) в подкаталогах `tracks`, `covers`, `artists`.

### б) Один сервер с MinIO (`STORAGE_MODE=minio`)

```ini
PG_PASSWORD=strong-db-pass
MINIO_ROOT_USER=musicadmin
MINIO_ROOT_PASSWORD=minio-strong-pass
JWT_SECRET_ACCESS=<секрет>
JWT_SECRET_REFRESH=<секрет>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
STORAGE_MODE=minio
```

```sh
./deploy.sh up all
```

Бакет `music` создаётся автоматически, backend получает `MINIO_ENDPOINT` по умолчанию (`http://mal-minio:9000` внутри сети).

### в) Разнесённое развёртывание (БД+MinIO и приложение на разных серверах)

**Сервер 1 (данные):**

```ini
PG_PASSWORD=strong-db-pass
MINIO_ROOT_USER=musicadmin
MINIO_ROOT_PASSWORD=minio-strong-pass
```

```sh
./deploy.sh up postgres minio
```

Порты `5432`, `9000`, `9001` публикуются на хост (см. раздел «Безопасность»).

**Сервер 2 (приложение):**

```ini
PG_PASSWORD=strong-db-pass
DB_HOST=10.0.0.10
DB_PORT_INTERNAL=5432
MINIO_ROOT_USER=musicadmin
MINIO_ROOT_PASSWORD=minio-strong-pass
MINIO_ENDPOINT=http://10.0.0.10:9000
STORAGE_MODE=minio
JWT_SECRET_ACCESS=<секрет>
JWT_SECRET_REFRESH=<секрет>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
```

```sh
./deploy.sh up backend frontend
```

Так как backend и frontend в одной сети `mal-net`, `BACKEND_UPSTREAM` остаётся дефолтным (`http://mal-backend:9090`).

### г) Production: домен + реальный сертификат

```ini
PG_PASSWORD=strong-db-pass
JWT_SECRET_ACCESS=<секрет>
JWT_SECRET_REFRESH=<секрет>
BACKEND_JAR=/srv/musicapp/app.jar
DIST_PATH=/srv/musicapp/dist
STORAGE_MODE=storage
ENABLE_SSL=true
AUTO_GENERATE_SELF_SIGNED=false
SSL_DIR_HOST=/srv/musicapp/ssl
SERVER_NAME=music.example.com
APP_HTTPS=true
```

Положите в `SSL_DIR_HOST` файлы `fullchain.pem` и `privkey.pem` (например, из Let's Encrypt), затем:

```sh
./deploy.sh up all
```

Доступ: `https://music.example.com` (HTTP редиректит на HTTPS). `APP_HTTPS=true` сообщает backend, что внешняя схема — HTTPS.

## Как это работает (детали)

- **Docker-сеть.** Скрипт создаёт bridge-сеть `NETWORK_NAME` (по умолчанию `mal-net`), если её нет. Все контейнеры подключаются к ней, поэтому доступны друг другу по DNS-именам контейнеров (`mal-postgres`, `mal-minio`, `mal-backend`). Поэтому дефолтные `DB_HOST`, `MINIO_ENDPOINT`, `BACKEND_UPSTREAM` указывают на имена контейнеров.
- **Хранение данных.** Все volume'ы лежат под `DATA_DIR` (`/srv/musicapp-data`): `postgres/` (`PG_DATA`), `minio/` (`MINIO_DATA`), `storage/` с подкаталогами `tracks`, `covers`, `artists` (`STORAGE_PATH`). Это bind-mount'ы на хосте, поэтому данные переживают `down`/`up` — при остановке удаляются только контейнеры, не каталоги.
- **Пересоздание контейнеров.** При каждом `up` backend и frontend удаляются и создаются заново (`remove_if_exists`) — это подхватывает обновлённый JAR/dist и env. PostgreSQL и MinIO **не** пересоздаются, если уже запущены (`container_running` → выход с сообщением «уже запущен»).
- **Защита версии PostgreSQL.** Перед стартом postgres скрипт читает `${PG_DATA}/PG_VERSION` и сравнивает с мажорной версией из `PG_IMAGE`. При несовпадении — завершение с ошибкой и подсказкой сменить `PG_IMAGE` или удалить volume. Это предотвращает повреждение данных несовместимым сервером.
- **Бакет MinIO.** После запуска MinIO скрипт одноразовым контейнером `minio/mc:latest` выполняет `mc alias set` + `mc mb -p m/${MINIO_BUCKET}`. Если не удалось — выдаётся предупреждение (бекенд может создать бакет сам), но деплой продолжается.
- **Health-чеки и таймауты:**
  - **postgres:** `pg_isready -U $PG_USER` в цикле, до 30 с, иначе ошибка.
  - **minio:** ожидание TCP-порта `MINIO_PORT` через `/dev/tcp`, до 20 с.
  - **backend:** после старта пауза 5 с (проверка раннего краша), затем `curl -fsS http://127.0.0.1:$BACKEND_PORT/api/health` в цикле до 120 с; при крахе контейнера — вывод `docker logs --tail 40` и ошибка; по таймауту health — предупреждение (контейнер остаётся).
  - **frontend:** ожидание TCP-порта `FRONTEND_HOST_PORT`, до 15 с, затем `curl` на `/__nginx_health` (HTTP или HTTPS). Нет ответа — предупреждение.
- **Фронтенд-контейнер.** В контейнер монтируются: `DIST_PATH` → `/usr/share/nginx/html` (ro), `TEMPLATES_DIR_HOST` → `/mal/templates` (ro), `ENTRYPOINT_HOST` → `/mal/docker-entrypoint.sh` (ro), и `SSL_DIR_HOST` → `/etc/nginx/ssl` (если каталог существует). Контейнер запускается с `--entrypoint /mal/docker-entrypoint.sh` и переменными `ENABLE_SSL`, `AUTO_GENERATE_SELF_SIGNED`, `SERVER_NAME`, `BACKEND_UPSTREAM`, `PROXY_API`, `PROXY_WS`, `CLIENT_MAX_BODY_SIZE`, `TEMPLATES_DIR=/mal/templates`. Entrypoint подставляет эти значения в шаблоны (envsubst) и формирует конфиг nginx; при `ENABLE_SSL=true` и `AUTO_GENERATE_SELF_SIGNED=true` генерирует self-signed сертификат, иначе ожидает реальные `fullchain.pem`/`privkey.pem` в смонтированном каталоге.

> Примечание: файлы `docker/nginx/templates/` и `docker/nginx/docker-entrypoint.sh` поставляются из репозитория и в этом дереве могут отсутствовать — их необходимо взять из исходников проекта. Конкретное содержимое шаблонов скриптом не задаётся.

## Безопасность

- **Права на `.env`:** `chmod 600 docker/.env` — файл содержит пароли и JWT-секреты.
- **`.gitignore`:** добавьте `docker/.env` (и каталог с сертификатами) в `.gitignore`, чтобы не закоммитить секреты.
- **Требования к секретам:** `JWT_SECRET_ACCESS` и `JWT_SECRET_REFRESH` — не короче 32 символов (проверяется скриптом); `MINIO_ROOT_PASSWORD` — не короче 8 символов (проверяется скриптом).
- **Переносы строк в секретах:** значения не должны содержать `\n`. Именно поэтому JWT генерируется через `openssl rand -base64 64 | tr -d '\n'` — без `tr` в конце окажется перевод строки, и контейнер получит битый секрет.
- **Публикация портов.** Скрипт всегда публикует порты на хост через `-p`: postgres `PG_PORT:5432`, minio `MINIO_PORT:9000` и `MINIO_CONSOLE_PORT:9001`, backend `BACKEND_PORT:BACKEND_PORT`, frontend `FRONTEND_HOST_PORT:80` (+ `FRONTEND_HOST_SSL_PORT:443` при SSL). При развёртывании на одном сервере публиковать PG/MinIO наружу не нужно — взаимодействие идёт по внутренней сети `mal-net`. Скрипт не поддерживает отключение публикации флагом; чтобы закрыть порты, либо привяжите их к loopback через `PG_PORT`/`MINIO_PORT` на уровне фаервола, либо ограничьте доступ фаерволом (ufw/iptables/security group). Менять формат публикации (например, на `127.0.0.1:5432:5432`) можно только правкой скрипта.

## Диагностика (Troubleshooting)

| Проблема | Причина | Решение |
|---|---|---|
| `Backend упал сразу после старта` | Ошибка конфигурации/подключения к БД, неверный JAR | `./deploy.sh logs backend` или `docker logs mal-backend`; проверьте `DB_HOST`, `PG_PASSWORD`, доступность БД |
| nginx падает с `host not found in upstream` | Frontend запущен без backend, а `BACKEND_UPSTREAM` указывает на контейнер `mal-backend` | Запустите backend, либо задайте внешний `BACKEND_UPSTREAM`, либо `PROXY_API=false PROXY_WS=false` |
| `Volume ... содержит данные PG X, а образ — PG Y` | Версия данных не совпадает с образом | Укажите `PG_IMAGE=postgres:X-alpine` либо удалите `PG_DATA` (потеря данных) |
| Backend: `health не ответил за 120s` | Долгий старт/миграции или зависание | Смотрите `docker logs -f mal-backend`; проверьте Flyway и подключение к БД |
| Frontend: `healthcheck не ответил` | Ошибка в шаблонах/сертификатах | `docker logs mal-frontend`; проверьте `TEMPLATES_DIR_HOST`, корректность сертификатов в `SSL_DIR_HOST` |
| `Frontend не открыл порт за 15s` | nginx не стартовал (битый конфиг/upstream) | `docker logs mal-frontend`; чаще всего — `host not found in upstream` (см. выше) |
| `MinIO не открыл порт за 20s` | MinIO не стартовал или порт занят | `docker logs mal-minio`; проверьте, что `MINIO_PORT`/`MINIO_CONSOLE_PORT` свободны |
| Порт занят (`address already in use`) | Хост-порт уже используется другим процессом | Освободите порт или переопределите `PG_PORT`/`MINIO_PORT`/`BACKEND_PORT`/`FRONTEND_HOST_PORT` |
| `PG_PASSWORD обязателен` / `JWT_SECRET_* обязателен` | Не заданы обязательные переменные | Задайте их в `.env`; JWT — `openssl rand -base64 64 | tr -d '\n'` (>= 32 символов) |
| `Docker daemon недоступен` | Daemon не запущен или нет прав | `systemctl start docker`; добавьте пользователя в группу `docker` |
