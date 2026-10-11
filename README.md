# Kết nối Backend và PostgreSQL bằng Docker CLI: Network và Volume

## 1. Mục tiêu

Dùng Docker CLI (không dùng Docker Compose) để kết nối một container Backend với một container PostgreSQL:

- Tạo **custom bridge network** `app-net` để hai container gọi nhau bằng tên container.
- Tạo **named volume** `db-data` để dữ liệu của PostgreSQL không bị mất khi xóa container.

**Kịch bản:** container Backend `app-container` (image `hw-backend:v1`) cần kết nối tới database trong container `db-server` (image `postgres:15-alpine`). Backend nhận địa chỉ database qua biến môi trường `DB_HOST=db-server`, không dùng IP cố định.

## 2. Khái niệm

- **Custom bridge network:** Docker cung cấp DNS nội bộ cho các container trong cùng một network do người dùng tạo. Container có thể gọi nhau bằng **tên container**, nên Backend kết nối tới database qua hostname `db-server` (giá trị `DB_HOST`, `DB_URL` trong `commands.sh`). Network `bridge` mặc định **không** có tính năng này, các container ở đó chỉ gọi nhau được bằng IP, mà IP có thể thay đổi mỗi lần tạo lại container.
- **Named volume:** dữ liệu được lưu trong volume do Docker quản lý, nằm **ngoài lớp ghi (writable layer)** của container. Khi `docker rm` container, lớp ghi bị xóa nhưng volume vẫn còn, nên container mới gắn cùng volume sẽ thấy lại dữ liệu cũ.

## 3. Script `commands.sh`

~~~bash
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
~~~

Giải thích từng bước:

1. **Tạo custom bridge network** `app-net`: các container trong network này phân giải được tên của nhau.
2. **Tạo named volume** `db-data`: nơi lưu dữ liệu PostgreSQL, tồn tại độc lập với container.
3. **Chạy container database** `db-server`: gắn vào `app-net`, mount `db-data` vào `/var/lib/postgresql/data`, khai báo user/mật khẩu/database qua biến môi trường, rồi chờ đến khi `pg_isready` báo sẵn sàng.
4. **Chạy container Backend** `app-container`: build image `hw-backend:v1` nếu chưa có, chạy trong cùng `app-net` và truyền thông tin kết nối với `DB_HOST=db-server` (dùng tên container, không dùng IP).
5. **Kiểm tra network, volume và DNS:** liệt kê network và volume, `docker network inspect` để xem hai container đã gắn vào `app-net`, rồi `ping db-server` từ trong `app-container` để kiểm tra phân giải tên.
6. **Kiểm tra dữ liệu bền vững:** tạo bảng `students` và thêm một dòng, xóa hẳn container database bằng `docker rm -f`, tạo lại container với cùng volume rồi đọc lại dữ liệu.

## 4. Kết quả

Output khi chạy `bash commands.sh`:

~~~text
== 1. Create custom bridge network ==
3f781379603b3d4510038495c444cdd1e0444eeab0e62ffec0722010f65c6f87
== 2. Create named volume ==
db-data
== 3. Run database container ==
Unable to find image 'postgres:15-alpine' locally
15-alpine: Pulling from library/postgres
277e2289225f: Pulling fs layer
e2de96513ba9: Pulling fs layer
2c2e40dd947e: Pulling fs layer
2e9987a42d41: Pulling fs layer
3f49193fd82d: Pulling fs layer
bc2205dd5a3a: Pulling fs layer
e9516be90840: Pulling fs layer
4f83103187f5: Pulling fs layer
c020dab2e853: Pulling fs layer
6ba2251a51ae: Pulling fs layer
0976f43b012c: Pulling fs layer
e2de96513ba9: Already exists
277e2289225f: Download complete
0976f43b012c: Download complete
2c2e40dd947e: Download complete
4f83103187f5: Download complete
c020dab2e853: Download complete
6ba2251a51ae: Download complete
bc2205dd5a3a: Download complete
3f49193fd82d: Download complete
2c2e40dd947e: Pull complete
2e9987a42d41: Download complete
bc2205dd5a3a: Pull complete
3f49193fd82d: Pull complete
2e9987a42d41: Pull complete
697de61d3cc1: Download complete
d3e3f1b947dc: Download complete
e9516be90840: Download complete
4f83103187f5: Pull complete
e9516be90840: Pull complete
277e2289225f: Pull complete
0976f43b012c: Pull complete
c020dab2e853: Pull complete
6ba2251a51ae: Pull complete
Digest: sha256:f7d23353e1b15400d22ebe31189f4d314b87a4c129cc400c8c2d8d4ca127bf81
Status: Downloaded newer image for postgres:15-alpine
21d47ced9f5c6097d743bd2cccba666cdfb2de0d77e4ce7cd79887b62aab69b0
== 4. Run backend container (DB host = db-server) ==
d3b1d75b35fd455afeff8ec0f57783de04eb0ba2d2e278de36194a711a21881c
== 5. Verify network, volume and DNS ==
3f781379603b   app-net       bridge    local
local     db-data
[
    {
        "Name": "app-net",
        "Id": "3f781379603b3d4510038495c444cdd1e0444eeab0e62ffec0722010f65c6f87",
        "Created": "2026-10-12T05:44:43.502974303+07:00",
        "Scope": "local",
        "Driver": "bridge",
        "EnableIPv4": true,
        "EnableIPv6": false,
        "IPAM": {
            "Driver": "default",
            "Options": {},
            "Config": [
                {
                    "Subnet": "172.19.0.0/16",
                    "Gateway": "172.19.0.1"
                }
            ]
        },
        "Internal": false,
        "Attachable": false,
        "Ingress": false,
        "ConfigFrom": {
            "Network": ""
        },
        "ConfigOnly": false,
        "Options": {},
        "Labels": {},
        "Containers": {
            "21d47ced9f5c6097d743bd2cccba666cdfb2de0d77e4ce7cd79887b62aab69b0": {
                "Name": "db-server",
                "EndpointID": "e1210e1b12938578c51527a4ce58727ee56330cb56759e5232d0023c9c75413a",
                "MacAddress": "f6:3e:b6:9b:af:25",
                "IPv4Address": "172.19.0.2/16",
                "IPv6Address": ""
            },
            "d3b1d75b35fd455afeff8ec0f57783de04eb0ba2d2e278de36194a711a21881c": {
                "Name": "app-container",
                "EndpointID": "268313c9d1e13e966e20becd054267aa4de0a1f5ba1f89860e5a825a1004bf94",
                "MacAddress": "0e:1b:e6:91:14:ed",
                "IPv4Address": "172.19.0.3/16",
                "IPv6Address": ""
            }
        },
        "Status": {
            "IPAM": {
                "Subnets": {
                    "172.19.0.0/16": {
                        "IPsInUse": 5,
                        "DynamicIPsAvailable": 65531
                    }
                }
            }
        }
    }
]
PING db-server (172.19.0.2): 56 data bytes
64 bytes from 172.19.0.2: seq=0 ttl=64 time=0.355 ms
64 bytes from 172.19.0.2: seq=1 ttl=64 time=0.112 ms

--- db-server ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.112/0.233/0.355 ms
== 6. Data persistence test ==
CREATE TABLE
INSERT 0 1
-- Data BEFORE removing the DB container:
 id | name  
----+-------
  1 | Khanh
(1 row)

-- Hard-remove the DB container (the volume stays):
db-server
local     db-data
-- Recreate the DB container with the same volume:
eb5a41827914c4a1ce889f3b021b970442b69a896d25fb12302f46ff46973416
-- Data AFTER recreating the DB container:
 id | name  
----+-------
  1 | Khanh
(1 row)

~~~

**Phân tích:**

- `docker network inspect app-net` cho thấy cả `db-server` (`172.19.0.2`) và `app-container` (`172.19.0.3`) đều nằm trong network `app-net` (subnet `172.19.0.0/16`).
- Lệnh `ping db-server` chạy trong `app-container` đã phân giải tên `db-server` thành IP nội bộ `172.19.0.2` và nhận đủ 2/2 gói tin (0% packet loss). Như vậy Backend gọi được database bằng tên container nhờ DNS của custom bridge network.
- Dòng `1 | Khanh` được thêm **trước** khi chạy `docker rm -f db-server` vẫn xuất hiện **sau** khi tạo lại container database. Container mới có ID khác (`eb5a41827914…` so với `21d47ced9f5c…` ban đầu) nhưng dùng chung volume `db-data`, nên dữ liệu được giữ nguyên.

## 5. Ghi chú

- Chỉ container database bị xóa (`docker rm -f db-server`), **volume `db-data` không bị xóa**. Lệnh `docker volume ls` ngay sau đó vẫn liệt kê `db-data`.
- Image PostgreSQL chỉ khởi tạo database (tạo user, database `appdb`) khi thư mục dữ liệu **trống**. Lần chạy thứ hai, thư mục `/var/lib/postgresql/data` đã có dữ liệu từ volume nên Postgres bỏ qua bước khởi tạo và dùng lại dữ liệu cũ, bao gồm bảng `students`.
