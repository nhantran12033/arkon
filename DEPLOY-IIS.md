# Deploy Arkon lên IIS (Windows)

> **Cấu hình tài liệu này mô tả**
>
> | | |
> |---|---|
> | Thư mục dự án | `C:\Storm12\Deployment\Arkon\arkon` |
> | Portal | `https://192.168.200.52:44380` |
> | File/ảnh (MinIO) | `https://192.168.200.52:44381` |
> | Chứng chỉ | Tự ký (self-signed) — môi trường test |
> | Python | 3.13 |
> | Log service | `C:\Logs\Arkon\` |
>
> Đổi IP hoặc port thì sửa ở 3 chỗ: `.env`, tham số `-PublicUrl` của `build.ps1`,
> tham số của `configure-iis.ps1`. Chi tiết ở mục 9.

---

## 1. Hiểu mô hình trước khi làm

### 1.1. IIS làm gì và không làm gì

IIS **không chạy được** code Python hay Node. Nó chỉ nhận request từ bên ngoài rồi
chuyển tiếp (reverse proxy) sang các tiến trình đang lắng nghe trên `127.0.0.1`.

Nói cách khác: mọi thứ trong `CHAY-DU-AN.md` vẫn phải chạy y như cũ. Khác biệt duy
nhất là 4 cửa sổ terminal được biến thành **Windows Service** để tự bật khi máy khởi
động, và IIS đứng trước làm cổng vào duy nhất.

### 1.2. Luồng request

```text
   Trinh duyet
   Claude Desktop (MCP)
          |
          |  HTTPS 44380
          v
   +--------------------------------+
   |  IIS  -  site "Arkon"          |
   |  (ARR + URL Rewrite)           |
   +--------------------------------+
          |
          +---> /api/*  /mcp  /oauth/*
          |     /.well-known/*  /docs
          |     /openapi.json  /health
          |            |
          |            v
          |     127.0.0.1:5055   Arkon-API        (uvicorn)
          |
          +---> tat ca duong dan con lai
                       |
                       v
                127.0.0.1:3000   Arkon-Frontend   (node server.js)


   Trinh duyet  --HTTPS 44381-->  IIS site "Arkon-Files"
                                        |
                                        v
                                 127.0.0.1:9002   MinIO
```

Hai service còn lại **không có port**, không đi qua IIS. Chúng lấy việc từ hàng đợi
Redis và chạy ngầm:

```text
   Arkon-Worker   (arq WorkerSettings)        <-- Redis
   Arkon-Skills   (arq SkillWorkerSettings)   <-- Redis
```

### 1.3. Bốn service bắt buộc

Thiếu bất kỳ cái nào cũng hỏng một phần hệ thống:

| Service | Tương ứng terminal | Vai trò | Thiếu thì sao |
|---|---|---|---|
| `Arkon-API` | Terminal 1 | FastAPI + MCP server | Cả web chết |
| `Arkon-Worker` | Terminal 2 | Pipeline MRP: upload tài liệu → sinh wiki | Upload xong đứng mãi ở `processing` |
| `Arkon-Skills` | Terminal 3 | Xử lý skills | Skill không chạy |
| `Arkon-Frontend` | Terminal 4 | Next.js SSR | Trắng trang |

### 1.4. Bảng cổng

| Thành phần | Địa chỉ | Mở ra ngoài? |
|---|---|---|
| IIS site `Arkon` | `*:44380` HTTPS | **Có** |
| IIS site `Arkon-Files` | `*:44381` HTTPS | **Có** |
| Arkon-API | `127.0.0.1:5055` | Không |
| Arkon-Frontend | `127.0.0.1:3000` | Không |
| PostgreSQL | `127.0.0.1:5433` | Không |
| Redis | `127.0.0.1:6379` | Không |
| MinIO API / Console | `127.0.0.1:9002` / `9003` | Không |

---

## 2. Cài đặt phần mềm (làm 1 lần)

### 2.1. Vai trò IIS + module

```powershell
# PowerShell Administrator
Install-WindowsFeature -Name Web-Server, Web-WebSockets, Web-Mgmt-Console -IncludeManagementTools
```

> Máy Windows 10/11 (không phải Server) thì dùng:
> `Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServer, IIS-WebSockets, IIS-ManagementConsole -All`

Rồi tải và cài **2 module** — không có sẵn trong Windows, và phải cài **URL Rewrite
trước, ARR sau**:

- URL Rewrite 2.1 — https://www.iis.net/downloads/microsoft/url-rewrite
- Application Request Routing 3.0 — https://www.iis.net/downloads/microsoft/application-request-routing

Cài xong mở lại IIS Manager, ở node server phải thấy icon **Application Request
Routing Cache**. Không thấy là chưa cài được.

### 2.2. Runtime

`winget` không có sẵn trên nhiều bản Windows Server. Tải trực tiếp cho chắc:

```powershell
# PowerShell Administrator
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Python 3.13 ---
$u = "https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe"
$f = "$env:TEMP\python-3.13.15-amd64.exe"
Invoke-WebRequest -Uri $u -OutFile $f
Start-Process -Wait -FilePath $f -ArgumentList `
  "/passive InstallAllUsers=1 PrependPath=1 Include_launcher=1 Include_test=0"
```

Node.js 22 LTS: tải MSI từ https://nodejs.org/en/download (bản LTS, Windows x64).

NSSM: tải từ https://nssm.cc/download, giải nén, copy `win64\nssm.exe` vào
`C:\Windows\System32`.

Đóng và mở lại PowerShell, rồi kiểm tra:

```powershell
py --list          # phải có -V:3.13
node --version     # v22.x
nssm version
```

---

## 3. Chuẩn bị `.env`

Copy `.env.iis-test.example` thành `.env` trong `C:\Storm12\Deployment\Arkon\arkon`.

```dotenv
# --- PostgreSQL (bind 127.0.0.1:5433) ---
DATABASE_URL=postgresql+asyncpg://arkon:b10cee481d058e16@127.0.0.1:5433/arkon
POSTGRES_USER=arkon
POSTGRES_PASSWORD=b10cee481d058e16
POSTGRES_DB=arkon

# --- Bảo mật (đã sinh ngẫu nhiên sẵn) ---
SECRET_KEY=bTGUaNfCAoVahCDLYQHm6h4EzF3tflzwvuGzYBx-h51WPS-HahcGyHaYGta5D4b5
MCP_TOKEN_PEPPER=Bgmy243q_aHBDBKJRzYFcAz__D4wQFxHFdbBfD0PDgg

# --- Admin khởi tạo ---
DEFAULT_ADMIN_EMAIL=admin@arkon.local
DEFAULT_ADMIN_PASSWORD=Arkon@Test2026

# --- Redis ---
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=8cdfa2bba30aa7d8
REDIS_DB=0
WORKER_MAX_JOBS=3
WORKER_JOB_TIMEOUT=1800

# --- MinIO ---
MINIO_ENDPOINT=localhost:9002
MINIO_PUBLIC_ENDPOINT=192.168.200.52:44381
MINIO_ACCESS_KEY=arkon-minio
MINIO_SECRET_KEY=e70de09ddbc35ea7df8ff239
MINIO_BUCKET=arkon-files
MINIO_SECURE=false
MINIO_PRESIGN_EXPIRY_HOURS=24
MINIO_BROWSER_REDIRECT_URL=http://localhost:9003

# --- Địa chỉ public của portal ---
CORS_ORIGINS=https://192.168.200.52:44380
PORTAL_BASE_URL=https://192.168.200.52:44380
NEXT_PUBLIC_API_URL=https://192.168.200.52:44380
```

### Hai biến MinIO trông giống nhau nhưng khác vai trò

| Biến | Ai dùng | Giá trị |
|---|---|---|
| `MINIO_ENDPOINT` | Backend gọi thẳng vào MinIO | `localhost:9002` — luôn giữ nguyên |
| `MINIO_PUBLIC_ENDPOINT` | Nhét vào presigned URL cho trình duyệt | `192.168.200.52:44381` — phải khớp binding IIS |

Chữ ký SigV4 của presigned URL bao gồm cả header `Host` (kể cả port). Lệch một ký tự
là ảnh wiki trả về `SignatureDoesNotMatch`. Khi `MINIO_PUBLIC_ENDPOINT` khác rỗng,
Arkon tự ký URL dạng `https://`.

### Với server thật thì đổi gì

- Sinh lại `SECRET_KEY` và `MCP_TOKEN_PEPPER`:
  `py -3.13 -c "import secrets; print(secrets.token_urlsafe(48))"`
- Đổi hết mật khẩu Postgres / Redis / MinIO / admin
- Thay IP:port bằng domain thật, dùng chứng chỉ thật
- Khoá quyền đọc file:
  `icacls C:\Storm12\Deployment\Arkon\arkon\.env /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"`

---

## 4. Bật hạ tầng (Postgres / Redis / MinIO)

### 4.1. Cách dùng Docker

```powershell
cd C:\Storm12\Deployment\Arkon\arkon
docker compose -f docker-compose.infra.yml --env-file .env up -d
docker compose -f docker-compose.infra.yml ps
```

File `docker-compose.infra.yml` chỉ chạy 3 dịch vụ nền và **publish port ra
`127.0.0.1`**. File `docker-compose.yml` gốc comment phần port lại, nên tiến trình
native trên Windows không kết nối được — đừng dùng nhầm file đó.

Bucket không cần tạo tay, `Arkon-API` tự tạo lúc khởi động.

### 4.2. Khi Docker Desktop trở chứng

Triệu chứng hay gặp — mọi lệnh docker trả về HTTP 500:

```
request returned 500 Internal Server Error for API route and version
http://%2F%2F.%2Fpipe%2FdockerDesktopLinuxEngine/v1.49/version
```

Nghĩa là named pipe còn sống nhưng **engine Linux bên trong đã chết**. Chẩn đoán:

```powershell
docker version     # Client OK, Server báo lỗi -> đúng là engine chết
wsl -l -v          # phải thấy distro docker-desktop
```

Xử lý theo thứ tự, dừng khi hết lỗi:

1. `wsl --shutdown` → chuột phải icon Docker ở khay → **Quit Docker Desktop** → đợi
   icon biến mất hẳn → mở lại → chờ icon hết animation.
2. `wsl --update` rồi lặp lại bước 1.
3. Kiểm tra ổ C còn trống: `Get-PSDrive C`.
4. Docker Desktop → Settings → Troubleshoot → **Reset to factory defaults**.
5. Xác nhận sống lại bằng `docker run --rm hello-world` trước khi chạy compose.

### 4.3. Không dùng Docker (khuyến nghị cho server chạy thật)

Docker Desktop vốn là công cụ cho máy dev: nó cần một phiên đăng nhập tương tác và
một máy ảo WSL. Đặt lên máy deploy thì thành điểm hỏng thêm — reboot mà không ai
đăng nhập là 3 dịch vụ nền không lên, kéo theo cả 4 service Arkon chết.

Cả 3 đều có bản Windows native chạy như service, ổn định hơn hẳn và khớp với kiến
trúc "mọi thứ đều là Windows Service" mà tài liệu này đang dựng:

| Dịch vụ | Bản native trên Windows |
|---|---|
| PostgreSQL + pgvector | PostgreSQL installer + extension `pgvector` |
| Redis | **Memurai** (bản Redis cho Windows, chạy dạng service) |
| MinIO | `minio.exe` chạy qua NSSM như 4 service Arkon |

Đi hướng này thì bỏ qua mục 4.1, phần còn lại của tài liệu giữ nguyên — chỉ cần 3
dịch vụ lắng nghe đúng port trong bảng ở mục 1.4.

---

## 5. Build

```powershell
cd C:\Storm12\Deployment\Arkon\arkon
.\deploy\win\build.ps1 -PublicUrl "https://192.168.200.52:44380"
```

Script làm: tạo `.venv` bằng `py -3.13` → kiểm tra đúng bản Python → `pip install -e .`
→ `alembic upgrade head` → `npm ci` → `npm run build` → copy `public/` và
`.next/static` vào `.next/standalone`.

Bước copy cuối là bắt buộc: Next.js chế độ `standalone` **không** tự gói file tĩnh
vào, quên là site load ra nhưng mất sạch CSS/ảnh.

> DB chưa sẵn sàng mà vẫn muốn build: thêm `-SkipMigration`, nhớ chạy
> `alembic upgrade head` trước khi start service.

---

## 6. Tạo 4 Windows Service

```powershell
# PowerShell Administrator
cd C:\Storm12\Deployment\Arkon\arkon
.\deploy\win\install-services.ps1
```

Kiểm tra ngay trước khi đụng đến IIS — bước này không xanh thì IIS có cấu hình đúng
cũng vô ích:

```powershell
Get-Service Arkon-*
curl.exe http://127.0.0.1:5055/health     # cả 3 dịch vụ phải healthy
curl.exe -I http://127.0.0.1:3000/        # 200 hoặc 307
```

Log nằm ở `C:\Logs\Arkon\`. Các service đặt **delayed auto-start** để hạ tầng kịp lên
trước khi API kết nối DB.

---

## 7. Cấu hình IIS

```powershell
# PowerShell Administrator
cd C:\Storm12\Deployment\Arkon\arkon
.\deploy\win\configure-iis.ps1 -CertSubject "192.168.200.52"
```

Một lệnh này làm hết: bật ARR proxy, timeout 600s, tắt response buffering, giữ HOST
header, cho phép rewrite ghi `X-Forwarded-Proto`, tạo chứng chỉ tự ký, tạo app pool +
2 site với binding HTTPS, copy `web.config`, mở firewall.

Đã có chứng chỉ thật thì truyền thumbprint vào thay vì để nó tự ký:

```powershell
.\deploy\win\configure-iis.ps1 -CertThumbprint "A1B2C3..." -CertSubject "arkon.congty.com"
```

### Nếu script báo `FAIL` ở dòng nào

Chỉnh tay trong **IIS Manager → chọn node server → Application Request Routing Cache
→ Server Proxy Settings**:

| Mục | Giá trị | Vì sao |
|---|---|---|
| Enable proxy | ✔ | Không bật thì rewrite sang URL ngoài sẽ 404 |
| Time-out (seconds) | `600` | Mặc định 120s — gọi LLM / ingest tài liệu lớn sẽ đứt giữa chừng |
| Response buffer threshold (KB) | `0` | **Bắt buộc.** Còn buffering thì `/mcp` treo, Claude Desktop không kết nối được |
| Preserve original HOST header | ✔ | **Bắt buộc.** Thiếu là presigned URL của MinIO sai chữ ký |
| Reverse rewrite host in response headers | ✘ | |

### Về `web.config`

`deploy\iis\web.config` có 3 rule chạy theo thứ tự:

1. **Set forwarded headers** — gắn `X-Forwarded-Proto: https`. Uvicorn chạy với
   `--proxy-headers` đọc header này để sinh đúng `https://` trong metadata OAuth của
   `/mcp`. Thiếu nó, Claude Desktop nhận link `http://` và bắt tay thất bại.
2. **Proxy to FastAPI** — các path của backend.
3. **Proxy to Next.js** — phần còn lại.

Rule số 2 tồn tại vì `next.config.ts` **chỉ** rewrite `/api/*`. Các endpoint `/mcp`,
`/oauth/*`, `/.well-known/*` không đi qua Next.js được — phải để IIS tự tách.

Trong file còn một rule **Force HTTPS đang bị comment**. Site hiện chỉ có binding
HTTPS nên nó thừa, mà bật lên khi port khác 443 thì sinh redirect sai port. Chỉ bỏ
comment khi site có cả binding HTTP port 80 lẫn HTTPS port 443.

### Chứng chỉ tự ký — hai việc phải làm

**Mở cả hai địa chỉ một lần và bấm qua cảnh báo:**

- `https://192.168.200.52:44380`
- `https://192.168.200.52:44381`

Nếu bỏ qua cái thứ hai, ảnh trong wiki sẽ không hiện — trình duyệt im lặng chặn
subresource đến từ origin có chứng chỉ chưa được chấp nhận, không báo gì cả.

**Claude Desktop sẽ không kết nối MCP được** với chứng chỉ tự ký — nó không có nút
"bấm qua". Phần MCP phải đợi có chứng chỉ thật mới test được.

Muốn hết cảnh báo trên các máy client: export chứng chỉ và import vào **Trusted Root
Certification Authorities** của từng máy.

---

## 8. Kiểm tra sau khi deploy

```powershell
curl.exe -k https://192.168.200.52:44380/health       # {"status":"healthy",...}
curl.exe -k -I https://192.168.200.52:44380/          # 200
curl.exe -k -I https://192.168.200.52:44380/login     # 200
curl.exe -k https://192.168.200.52:44380/api/health   # api/database/worker đều healthy
curl.exe -k -i https://192.168.200.52:44380/mcp       # 401 + header WWW-Authenticate
curl.exe -k -I https://192.168.200.52:44381/          # MinIO trả lời (403 là bình thường)
```

> `-k` bỏ qua kiểm tra chứng chỉ, cần thiết vì đang dùng cert tự ký.

Rồi mở trình duyệt:

- [ ] Đăng nhập `admin@arkon.local` / `Arkon@Test2026`
- [ ] Vào **Settings** cấu hình AI provider (embedding model + API key, LLM)
- [ ] Upload thử 1 tài liệu → theo dõi `C:\Logs\Arkon\Arkon-Worker.out.log`,
      trạng thái phải chạy hết `processing` → `completed`
- [ ] Mở 1 trang wiki có ảnh → ảnh phải hiện (kiểm tra presigned URL / MinIO)

---

## 9. Đổi IP hoặc port

Phải sửa đồng bộ ở **3 chỗ**, thiếu chỗ nào cũng hỏng:

**1. `.env`** — 4 dòng:

```dotenv
MINIO_PUBLIC_ENDPOINT=<ip>:<port-minio>
CORS_ORIGINS=https://<ip>:<port>
PORTAL_BASE_URL=https://<ip>:<port>
NEXT_PUBLIC_API_URL=https://<ip>:<port>
```

**2. Build lại frontend** — `NEXT_PUBLIC_API_URL` nhúng cứng vào bundle JS lúc build,
sửa `.env` không thôi là vô tác dụng:

```powershell
.\deploy\win\build.ps1 -PublicUrl "https://<ip>:<port>"
```

**3. Dựng lại binding IIS:**

```powershell
.\deploy\win\configure-iis.ps1 -CertSubject "<ip>" -Port <port> -MinioPort <port-minio>
```

Rồi `.\deploy\win\restart-services.ps1`.

> Dải `44300–44399` do IIS Express giữ URL ACL. Nếu binding báo trùng port, đổi sang
> `8443` / `8444`.

---

## 10. Quy trình deploy code mới

```powershell
cd C:\Storm12\Deployment\Arkon\arkon
git pull
.\deploy\win\build.ps1 -PublicUrl "https://192.168.200.52:44380"   # gồm cả alembic upgrade
.\deploy\win\restart-services.ps1
```

Không cần restart IIS. IIS chỉ proxy, không giữ state của app.

---

## 11. Lỗi hay gặp

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| **502.3 / 504** khi mở web | Service chưa chạy, hoặc ARR chưa bật proxy | `Get-Service Arkon-*`; kiểm tra Enable proxy |
| Web hiện nhưng **không có CSS**, ảnh vỡ | Quên copy `public/` và `.next/static` vào `.next\standalone` | Chạy lại `build.ps1` |
| Gọi API bị **CORS error** | `NEXT_PUBLIC_API_URL` build ra khác địa chỉ đang truy cập | Build lại với đúng `-PublicUrl` |
| Trình duyệt **ERR_CERT_AUTHORITY_INVALID** | Chứng chỉ tự ký | Bấm qua cảnh báo, hoặc import vào Trusted Root |
| **Ảnh wiki không hiện**, console báo cert | Chưa chấp nhận cảnh báo ở port 44381 | Mở `https://<ip>:44381` một lần, bấm qua |
| Ảnh wiki lỗi **SignatureDoesNotMatch** | `MINIO_PUBLIC_ENDPOINT` lệch binding IIS, hoặc ARR chưa giữ HOST header | Đối chiếu `.env` với binding; bật Preserve original HOST header |
| Upload file lớn bị **413** | `maxAllowedContentLength` trong `web.config` | Tăng lên, mặc định để 500 MB |
| Request dài **đứt sau ~2 phút** | ARR timeout mặc định | Server Proxy Settings → Time-out = 600 |
| Claude Desktop **không kết nối MCP** | Chứng chỉ tự ký, hoặc còn response buffering, hoặc thiếu `X-Forwarded-Proto` | Cần cert thật; Response buffer threshold = 0; kiểm tra `allowedServerVariables` |
| Upload xong đứng ở **processing** mãi | `Arkon-Worker` chết | `C:\Logs\Arkon\Arkon-Worker.err.log`; worker **không** tự reload code |
| Sau reboot **tất cả chết** | Docker Desktop chưa lên | Xem mục 4.2 và 4.3 |
| Rewrite báo **server variable not allowed** | Chưa khai báo trong `allowedServerVariables` | Chạy lại `configure-iis.ps1` |
| Binding báo **trùng port** | Dải 443xx do IIS Express giữ | Đổi sang 8443 / 8444 |

Thứ tự xem log khi debug: `C:\Logs\Arkon\*.err.log` → IIS log
`C:\inetpub\logs\LogFiles\` → `docker logs arkon_postgres`.

---

## 12. File đi kèm

```
.env.iis-test.example              # mẫu .env cho môi trường test này
docker-compose.infra.yml           # Postgres/Redis/MinIO, có publish port
deploy/
├── iis/
│   ├── web.config                 # site chính: rule reverse proxy
│   └── web.minio.config           # site Arkon-Files cho MinIO
└── win/
    ├── build.ps1                  # build backend + frontend + migration
    ├── install-services.ps1       # tạo 4 Windows Service bằng NSSM
    ├── restart-services.ps1       # restart sau khi deploy
    └── configure-iis.ps1          # ARR + cert + 2 site + binding + firewall
```
