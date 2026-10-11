#!/bin/bash
set -e

# Resource names (change here if a name is already used on a shared Docker host)
NET=app-net
VOL=db-data
DB=db-server
APP=app-container
APP_IMAGE=hw-backend:v1
PG_USER=appuser
PG_PASS=apppass123
PG_DB=appdb

wait_db() {
  until docker exec "$DB" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; do sleep 1; done
}

run_db() {
  docker run -d --name "$DB" --network "$NET" \
    -v "$VOL":/var/lib/postgresql/data \
    -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PASS" -e POSTGRES_DB="$PG_DB" \
    postgres:15-alpine
}

# Step 1: a user-defined bridge network gives containers DNS resolution by container name
echo "== 1. Create custom bridge network =="
docker network create "$NET"

# Step 2: a named volume keeps the PostgreSQL data outside the container's lifecycle
echo "== 2. Create named volume =="
docker volume create "$VOL"

# Step 3: start PostgreSQL on the network with the volume mounted, then wait until it accepts connections
echo "== 3. Run database container =="
run_db
wait_db

# Step 4: build the backend image if missing, then run it on the same network using the DB container name as host
echo "== 4. Run backend container (DB host = $DB) =="
docker image inspect "$APP_IMAGE" >/dev/null 2>&1 || docker build -t "$APP_IMAGE" /root/khanh/ss10-ex2
docker run -d --name "$APP" --network "$NET" \
  -e DB_HOST="$DB" -e DB_PORT=5432 -e DB_NAME="$PG_DB" -e DB_USER="$PG_USER" -e DB_PASSWORD="$PG_PASS" \
  -e DB_URL="jdbc:postgresql://$DB:5432/$PG_DB" \
  "$APP_IMAGE"

# Step 5: confirm the network and volume exist, both containers are attached, and the app resolves the DB by name
echo "== 5. Verify network, volume and DNS =="
docker network ls | grep "$NET"
docker volume ls | grep "$VOL"
docker network inspect "$NET"
docker exec "$APP" ping -c 2 "$DB"

# Step 6: write a row, remove the DB container, recreate it on the same volume and check the row is still there
echo "== 6. Data persistence test =="
docker exec "$DB" psql -U "$PG_USER" -d "$PG_DB" \
  -c "CREATE TABLE IF NOT EXISTS students (id SERIAL PRIMARY KEY, name TEXT);" \
  -c "INSERT INTO students (name) VALUES ('Khanh');"
echo "-- Data BEFORE removing the DB container:"
docker exec "$DB" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT * FROM students;"

echo "-- Hard-remove the DB container (the volume stays):"
docker rm -f "$DB"
docker volume ls | grep "$VOL"

echo "-- Recreate the DB container with the same volume:"
run_db
wait_db
echo "-- Data AFTER recreating the DB container:"
docker exec "$DB" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT * FROM students;"
