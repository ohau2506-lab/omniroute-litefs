# DEPLOY RUNBOOK — OmniRoute LiteFS + Consul (POC)

Tài liệu này là checklist triển khai theo từng bước, có tiêu chí **đúng/sai** và lệnh kiểm tra tương ứng.

---

## 0) Mục tiêu luồng đúng

Luồng đúng sau deploy:

1. `consul` chạy ổn định.
2. `omniroute-litefs` mount được FUSE + app chạy sau LiteFS proxy.
3. App phục vụ qua `:20128` (proxy), app thật ở `:20129`.
4. SQLite nằm trên `/litefs/storage.sqlite`.
5. Node 2 join được và không split-brain.
6. Chỉ sau khi pass bước 1-5 mới bật `cloudflared`.

---


## 0.1 Chạy nhanh bằng GitHub Actions

Repo đã có workflow `.github/workflows/deploy-litefs.yml` để bạn chỉ cần bấm chạy và kiểm tra.

Secrets tối thiểu cần set:

- `TS_AUTHKEY`
- `TS_TAILNET`
- `CONSUL_HTTP_ADDR` khi chạy multi-host thật với `consul_mode=external`
- `NEXT_PUBLIC_BASE_URL`
- `JWT_SECRET`
- `API_KEY_SECRET`
- `MACHINE_ID_SALT`
- `STORAGE_ENCRYPTION_KEY`
- `INITIAL_PASSWORD`

Cách chạy:

1. Vào **Actions** -> `deploy-litefs`.
2. Chọn `node_slot` (1/2/3...) để workflow tự đặt hostname Tailscale ổn định.
3. Chọn `consul_mode=external` cho multi-host thật, hoặc `consul_mode=local` nếu chỉ smoke test 1 node.
4. Chọn `skip_cloudflared=true` cho lần chạy kiểm tra nội bộ trước.
5. Run workflow và xem bước `Wait for health` + `Smoke test`.

---


## 0.2 Triển khai KHÔNG dùng cloudflared cần cấu hình gì?

Nếu bạn muốn chạy nội bộ/VPN trước, có thể **không bật cloudflared**.

Cần cấu hình:

1. `.env` đầy đủ secrets app + identity (`INSTANCE_NAME`, `INSTANCE_ADDR`).
2. `CONSUL_HTTP_ADDR`.
3. Với multi-host thật, trỏ `CONSUL_HTTP_ADDR` tới một cụm Consul dùng chung.
4. Với local/single-node, có thể dùng mặc định `http://consul:8500`.
5. Mở cổng truy cập nội bộ tới LiteFS proxy (`20128`) trên host chạy app.
6. Dùng URL nội bộ để test, ví dụ:
   - `http://<node-or-lb-internal>:20128/api/storage/health`
   - `http://<node-or-lb-internal>:20128/v1/models`

Lệnh chạy tối thiểu (không cloudflared):

```bash
docker compose up -d consul
docker compose up -d --build omniroute-litefs
```

Với GitHub Actions workflow `deploy-litefs`, đặt `skip_cloudflared=true`.

Khi nào mới cần cloudflared?

- Chỉ khi bạn muốn publish public domain qua Cloudflare Tunnel.
- Nếu chỉ kiểm thử nội bộ hoặc chạy private qua Tailscale/LB nội bộ thì chưa cần bật.

---

## 1) Preflight

## 1.1 Chuẩn bị env

```bash
cp .env.example .env
```

Điền tối thiểu trong `.env`:

- `NEXT_PUBLIC_BASE_URL`
- `INSTANCE_NAME`
- `JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`, `STORAGE_ENCRYPTION_KEY`, `INITIAL_PASSWORD`

Nếu node IP động:

```bash
export INSTANCE_ADDR="$(bash ./scripts/resolve-instance-addr.sh)"
export CONSUL_HTTP_ADDR="http://consul:8500" # hoặc endpoint Consul shared nếu multi-host
```

### PASS
- `.env` tồn tại và có đủ secret bắt buộc.
- `INSTANCE_ADDR` resolve được.
- `CONSUL_HTTP_ADDR` trỏ tới đúng cụm Consul và endpoint đó đang có leader.

### FAIL
- `CONSUL_HTTP_ADDR` trỏ sai cụm hoặc endpoint chưa có leader.

---

## 1.2 Kiểm tra môi trường runtime

```bash
test -e /dev/fuse && echo "fuse ok"
```

### PASS
- Có `/dev/fuse`.

### FAIL
- Không có `/dev/fuse` -> LiteFS không mount được.

---

## 2) Boot node 1 (single-node)

## 2.1 Start Consul

Single-node/local:

```bash
docker compose up -d consul
```

Multi-host/shared Consul:

- Không boot local `consul` trên từng node nếu bạn đang dùng một cụm Consul dùng chung.
- Chỉ cần đảm bảo `CONSUL_HTTP_ADDR` trỏ tới cụm shared đó.

Kiểm tra:

```bash
curl -fsS ${CONSUL_HTTP_ADDR:-http://localhost:8500}/v1/status/leader
```

### PASS
- Trả về chuỗi địa chỉ leader (không rỗng, không `""`).

### FAIL
- Không có leader -> chưa nên start app.

---

## 2.2 Start omniroute-litefs

```bash
docker compose up -d --build omniroute-litefs
```

Kiểm tra health container:

```bash
docker compose ps omniroute-litefs
```

### PASS
- Trạng thái `running` và health `healthy`.

### FAIL
- `unhealthy` hoặc restart loop -> xem `docker compose logs omniroute-litefs`.

---

## 2.3 Verify app path/proxy đúng luồng

```bash
bash ./scripts/litefs-smoke.sh http://localhost:20128
curl -fsS http://localhost:20128/v1/models >/dev/null
```

### PASS
- Cả 2 lệnh trả 2xx.

### FAIL
- Timeout/5xx -> kiểm tra logs LiteFS + app.

---

## 3) Migration DB từ hệ cũ (nếu có)

## 3.1 Chuẩn bị DB nguồn

Dừng ghi app cũ, lấy file `storage.sqlite` chuẩn.

## 3.2 Chạy migration + integrity check

```bash
bash ./scripts/migrate-from-litestream.sh ./data/storage.sqlite ./bootstrap/storage.sqlite
```

### PASS
- Script in ra `PRAGMA integrity_check` kết quả `ok`.

### FAIL
- DB lỗi integrity -> dừng rollout, lấy bản DB khác.

---

## 4) Join node 2

Trên node 2:

1. Set `INSTANCE_NAME` khác node 1.
2. Resolve `INSTANCE_ADDR` + `CONSUL_HTTP_ADDR`.
3. `docker compose up -d --build omniroute-litefs`.

Kiểm tra từ node 2:

```bash
bash ./scripts/litefs-smoke.sh http://localhost:20128
curl -fsS http://localhost:20128/v1/models >/dev/null
```

### PASS
- Node 2 phục vụ read bình thường.
- Không phát hiện split-brain (Consul chỉ có 1 leader lock).

### FAIL
- Node 2 không đọc được hoặc mất đồng bộ liên tục.

## 4.1 Cảnh báo split-brain quan trọng

- Nếu mỗi node tự chạy `consul agent -server -bootstrap-expect=1` riêng của nó, bạn sẽ có nhiều cụm Consul độc lập.
- Khi đó LiteFS trên mỗi node có thể đều tự nhận primary vì chúng không dùng chung lease backend.
- Multi-host thật nên dùng `consul_mode=external` trong workflow và trỏ mọi node về cùng một `CONSUL_HTTP_ADDR`.

---

## 5) Kiểm thử song song 2 node + report

```bash
bash ./scripts/litefs-two-node-report.sh \
  http://node1.internal:20128 \
  http://node2.internal:20128 \
  600 \
  5
```

### PASS
- Report tạo thành công trong `docs/reports/`.
- `Overall status` là `PASS` hoặc `WARN` thấp, tỷ lệ thành công cao.

### FAIL
- `FAIL_EVENTS` cao, tỷ lệ health/models thấp.

---

## 6) Bật cloudflared (chỉ sau khi pass)

```bash
docker compose up -d cloudflared
```

Kiểm tra:

- Truy cập public domain app.
- Theo dõi log cloudflared và omniroute-litefs.

### PASS
- Public domain trả về bình thường.

### FAIL
- 502/route lỗi -> rollback traffic về route cũ.

---

## 7) Smoke + Soak test sau cutover

Smoke:

```bash
bash ./scripts/litefs-smoke.sh http://localhost:20128
```

Soak 2 giờ (ví dụ):

```bash
bash ./scripts/litefs-soak.sh http://localhost:20128 7200 2
```

### PASS
- Smoke OK.
- Soak không có lỗi hoặc lỗi rất thấp theo ngưỡng chấp nhận.

### FAIL
- lỗi lặp lại -> dừng scale-out, kiểm tra lease/proxy/IO.

---

## 8) Tiêu chí chốt “đúng luồng”

Đánh dấu **DONE** khi đạt đủ:

- [ ] Consul có leader ổn định.
- [ ] Node 1 healthy, app qua proxy ổn định.
- [ ] DB migrate integrity OK (nếu có migration).
- [ ] Node 2 join thành công, không split-brain.
- [ ] Report 2-node hợp lệ và đạt ngưỡng.
- [ ] Cloudflared public traffic ổn định sau cutover.
- [ ] Smoke + soak đạt yêu cầu.

Nếu thiếu bất kỳ mục nào -> coi là rollout **chưa đạt**.


## 9) Troubleshooting nhanh

### Lỗi build LiteFS: `gzip: stdin: not in gzip format`

Nguyên nhân thường gặp: URL release LiteFS hardcode bị lỗi/404/403 nên `curl` trả về nội dung text thay vì tar.gz.

Bản Dockerfile hiện tại đã chuyển sang cơ chế:

- query GitHub Releases API (`latest` hoặc `tags/v<version>`)
- tự lấy asset `linux-amd64.tar.gz`
- dùng `curl -fsSL` để fail sớm nếu tải lỗi

Nếu cần pin version, build với:

```bash
docker compose build --build-arg LITEFS_VERSION=0.5.13 omniroute-litefs
```

Nếu bỏ pin, Dockerfile sẽ lấy release mới nhất.

---
