#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docker_bin=${DOCKER:-docker}
container="pgsql-el-tls-${RANDOM}-$$"
work=$(mktemp -d "${TMPDIR:-/tmp}/pgsql-el-tls.XXXXXX")
started=0

cleanup() {
  if ((started)); then
    "$docker_bin" rm -f "$container" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

command -v "$docker_bin" >/dev/null
command -v openssl >/dev/null

openssl req -quiet -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj "/CN=pgsql.el test CA" \
  -keyout "$work/ca.key" -out "$work/ca.crt" >/dev/null
openssl req -quiet -new -newkey rsa:2048 -nodes -sha256 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" \
  -keyout "$work/server.key" -out "$work/server.csr" >/dev/null
openssl x509 -req -sha256 -days 1 \
  -in "$work/server.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
  -CAcreateserial -copy_extensions copy \
  -out "$work/server.crt" >/dev/null

"$docker_bin" run --rm -d --name "$container" \
  -e POSTGRES_USER=pgsql \
  -e POSTGRES_PASSWORD=pgsql \
  -e POSTGRES_DB=pgsql_test \
  -p "127.0.0.1::5432" \
  postgres:16 >/dev/null
started=1

wait_for_postgres() {
  for _ in {1..120}; do
    if "$docker_bin" exec "$container" sh -c \
         'test "$(cat /proc/1/comm)" = postgres && pg_isready -U pgsql -d pgsql_test' \
         >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done
  "$docker_bin" logs "$container" >&2
  return 1
}

wait_for_postgres
"$docker_bin" exec -u root "$container" \
  mkdir -p /var/lib/postgresql/tls
"$docker_bin" cp "$work/server.crt" \
  "$container:/var/lib/postgresql/tls/server.crt" >/dev/null
"$docker_bin" cp "$work/server.key" \
  "$container:/var/lib/postgresql/tls/server.key" >/dev/null
"$docker_bin" exec -u root "$container" \
  chown postgres:postgres \
  /var/lib/postgresql/tls/server.crt \
  /var/lib/postgresql/tls/server.key
"$docker_bin" exec -u root "$container" \
  chmod 600 /var/lib/postgresql/tls/server.key
"$docker_bin" exec "$container" \
  psql -v ON_ERROR_STOP=1 -U pgsql -d pgsql_test \
  -c "ALTER SYSTEM SET ssl = 'on'" \
  -c "ALTER SYSTEM SET ssl_cert_file = '/var/lib/postgresql/tls/server.crt'" \
  -c "ALTER SYSTEM SET ssl_key_file = '/var/lib/postgresql/tls/server.key'" \
  >/dev/null
"$docker_bin" restart "$container" >/dev/null
wait_for_postgres

endpoint=$("$docker_bin" port "$container" 5432/tcp | head -n 1)
port=${endpoint##*:}
env \
  PGSQL_TEST_HOST=localhost \
  PGSQL_TEST_PORT="$port" \
  PGSQL_TEST_USER=pgsql \
  PGSQL_TEST_PASSWORD=pgsql \
  PGSQL_TEST_DATABASE=pgsql_test \
  PGSQL_TEST_TLS_CA="$work/ca.crt" \
  PGSQL_TEST_TLS_HOST=localhost \
  PGSQL_TEST_TLS_WRONG_HOST=127.0.0.1 \
  "$repo/test/run-ci.sh" tls-live
