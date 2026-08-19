# Deploy Arkon lên IIS (Windows Server)

> Kiến trúc: **IIS chỉ làm reverse proxy**. Python và Node chạy thật dưới dạng
> **Windows Service** (NSSM). Postgres / Redis / MinIO chạy trong **Docker Desktop**
> trên chính server đó.

---

## 1. Hiểu mô hình trước khi làm

### 1.1. IIS làm gì và không làm gì

IIS **không chạy được** code Python hay Node. Nó chỉ nhận request từ bên ngoài rồi
chuyển tiếp (reverse proxy) sang các tiến trình đang lắng nghe trên `127.0.0.1`.

Nói cách khác: mọi thứ trong `CHAY-DU-AN.md` vẫn phải chạy y như cũ. Khác biệt duy
nhất là 4 cửa sổ terminal được biến thành **Windows Service** để tự bật khi server
khởi động, và IIS đứng trước làm cổng vào duy nhất (port 443).

### 1.2. Luồng request

```text
   Trinh duyet
   Claude Desktop (MCP)
          |
          |  HTTPS 443
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
```

Hai service còn lại **không có port**, không đi qua IIS. Chúng lấy việc từ hàng đợi
Redis và chạy ngầm:

```text
   Arkon-Worker   (arq WorkerSettings)        <-- Redis
   Arkon-Skills   (arq SkillWorkerSettings)   <-- Redis
```

Phía dưới cùng là hạ tầng chạy trong Docker, cũng chỉ bind `127.0.0.1`:

```text
   postgres  5433      redis  6379      minio  9002 / 9003
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
| IIS (site Arkon) | `:80` → redirect `:443` | **Có** |
| IIS (site files, cho MinIO) | `:443` | Có, nếu dùng — xem mục 7 |
| Arkon-API | `127.0.0.1:5055` | Không |
| Arkon-Frontend | `127.0.0.1:3000` | Không |
| PostgreSQL | `127.0.0.1:5433` | Không |
| Redis | `127.0.0.1:6379` | Không |
| MinIO API / Console | `127.0.0.1:9002` / `9003` | Không |

---

## 2. Cài đặt phần mềm trên server (làm 1 lần)

### 2.1. Vai trò IIS + module

```powershell
# PowerShell Administrator
Install-WindowsFeature -Name Web-Server, Web-WebSockets, Web-Mgmt-Console -IncludeManagementTools
```

Rồi tải và cài **2 module** (không có sẵn trong Windows):

- **URL Rewrite 2.1** — https://www.iis.net/downloads/microsoft/url-rewrite
- **Application Request Routing 3.0** — https://www.iis.net/downloads/microsoft/application-request-routing

> Cài ARR **sau** URL Rewrite. Cài xong mở lại IIS Manager, ở node server phải thấy
> icon **Application Request Routing Cache**.

### 2.2. Runtime

```powershell
winget install Python.Python.3.12       # 3.11 – 3.14
winget install OpenJS.NodeJS.LTS        # Node 22 LTS
winget install NSSM.NSSM                # quản lý Windows Service
winget install Docker.DockerDesktop
```

Đóng và mở lại PowerShell để `PATH` cập nhật, kiểm tra:

```powershell
python --version; node --version; nssm version; docker --version
```

---

## 3. Lấy code và cấu hình `.env`

```powershell
git clone <repo> D:\Storm12\Arkon\arkon      # hoặc copy sẵn thư mục
cd D:\Storm12\Arkon\arkon
```

Tạo file `.env` cho production. **Đừng dùng lại `.env` dev.**

```dotenv
# --- PostgreSQL (Docker, chỉ bind loopback) ---
DATABASE_URL=postgresql+asyncpg://arkon:DOI_MAT_KHAU_NAY@127.0.0.1:5433/arkon
POSTGRES_USER=arkon
POSTGRES_PASSWORD=DOI_MAT_KHAU_NAY
POSTGRES_DB=arkon

# --- Bảo mật: BẮT BUỘC đổi, sinh ngẫu nhiên ---
# python -c "import secrets; print(secrets.token_urlsafe(48))"
SECRET_KEY=<chuoi-ngau-nhien-48-ky-tu>
MCP_TOKEN_PEPPER=<chuoi-ngau-nhien-khac>

# --- Admin khởi tạo (đổi mật khẩu ngay sau lần đăng nhập đầu) ---
DEFAULT_ADMIN_EMAIL=admin@congty.com
DEFAULT_ADMIN_PASSWORD=<mat-khau-manh>

# --- Redis ---
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=DOI_MAT_KHAU_REDIS
REDIS_DB=0
WORKER_MAX_JOBS=3
WORKER_JOB_TIMEOUT=1800

# --- MinIO ---
MINIO_ENDPOINT=127.0.0.1:9002
MINIO_PUBLIC_ENDPOINT=files.congty.com     # xem mục 7 — quan trọng
MINIO_ACCESS_KEY=arkon-minio
MINIO_SECRET_KEY=<mat-khau-manh>
MINIO_BUCKET=arkon-files
MINIO_SECURE=false
MINIO_PRESIGN_EXPIRY_HOURS=24

# --- Domain public ---
CORS_ORIGINS=https://arkon.congty.com
PORTAL_BASE_URL=https://arkon.congty.com
NEXT_PUBLIC_API_URL=https://arkon.congty.com
```

Vài điểm dễ sai:

- `MINIO_ENDPOINT` là `9002` chứ không phải `9000` — vì `docker-compose` map ra `9002`.
- `CORS_ORIGINS` **không để `*`** trên production. Vì frontend và API cùng domain nên
  thực ra không cần CORS, để đúng domain là đủ.
- `NEXT_PUBLIC_API_URL` bị **nhúng cứng vào bundle JS lúc build**. Đổi domain ⇒ phải
  build lại frontend, restart service thôi không ăn thua.

Chặn file `.env` khỏi con mắt tò mò:

```powershell
icacls D:\Storm12\Arkon\arkon\.env /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

---

## 4. Bật hạ tầng (Docker)

Dùng file `docker-compose.infra.yml` đi kèm — nó chỉ chạy Postgres/Redis/MinIO và
**publish port ra `127.0.0.1`** (file `docker-compose.yml` gốc comment phần port lại,
nên tiến trình native trên Windows không kết nối được).

```powershell
cd D:\Storm12\Arkon\arkon
docker compose -f docker-compose.infra.yml --env-file .env up -d
docker ps
```

> **Bẫy Docker Desktop trên server:** Docker Desktop cần một phiên đăng nhập
> tương tác — server reboot mà không ai đăng nhập thì container **không tự chạy lại**,
> kéo theo cả 4 service Arkon chết. Ba cách xử lý:
>
> 1. Bật **auto-logon** cho tài khoản service + Docker Desktop "Start when you log in".
> 2. Chuyển sang **Docker Engine trên WSL2** có `systemd` (chạy nền không cần login).
> 3. Bỏ Docker: cài PostgreSQL + extension `pgvector` native, Redis thay bằng
>    **Memurai**, MinIO chạy như Windows Service qua NSSM.
>
> Nếu hệ thống chạy thật cho cả công ty, khuyên chọn (2) hoặc (3).

Tạo lại bucket không cần làm tay — `Arkon-API` tự tạo lúc khởi động.

---

## 5. Build

```powershell
cd D:\Storm12\Arkon\arkon
.\deploy\win\build.ps1 -PublicUrl "https://arkon.congty.com"
```

Script làm: tạo `.venv` → `pip install -e .` → `alembic upgrade head` →
`npm ci` → `npm run build` → copy `public/` và `.next/static` vào `.next/standalone`.

> Bước copy cuối là bắt buộc: Next.js chế độ `standalone` **không** tự gói file tĩnh
> vào, quên là site load ra nhưng mất sạch CSS/ảnh.

---

## 6. Tạo 4 Windows Service

```powershell
# PowerShell Administrator
cd D:\Storm12\Arkon\arkon
.\deploy\win\install-services.ps1
```

Kiểm tra ngay trước khi đụng đến IIS — nếu bước này không xanh thì IIS có cấu hình
đúng cũng vô ích:

```powershell
Get-Service Arkon-*
curl.exe http://127.0.0.1:5055/health     # phải trả status: healthy cho cả 3 dịch vụ
curl.exe -I http://127.0.0.1:3000/        # phải trả 200 hoặc 307
```

Log nằm ở `D:\Logs\Arkon\`.

Các service được đặt **delayed auto-start** để Docker kịp lên trước khi API kết nối DB.

---

## 7. Cấu hình IIS

```powershell
# PowerShell Administrator
cd D:\Storm12\Arkon\arkon
.\deploy\win\configure-iis.ps1 -SiteName "Arkon" -HostName "arkon.congty.com"
```

Script bật ARR proxy, đặt timeout 600s, tắt response buffering, cho phép rewrite ghi
`X-Forwarded-Proto`, tạo app pool + site và copy `deploy\iis\web.config` vào.

Nếu dòng nào báo `FAIL`, chỉnh tay trong **IIS Manager → chọn node server →
Application Request Routing Cache → Server Proxy Settings**:

| Mục | Giá trị | Vì sao |
|---|---|---|
| Enable proxy | ✔ | Không bật thì rewrite sang URL ngoài sẽ 404 |
| Time-out (seconds) | `600` | Mặc định 120s — gọi LLM / ingest tài liệu lớn sẽ đứt giữa chừng |
| Response buffer threshold (KB) | `0` | **Bắt buộc.** Còn buffering thì MCP streamable HTTP (`/mcp`) treo, Claude Desktop không kết nối được |
| Preserve original HOST header | ✔ | Cần cho presigned URL của MinIO và cho OAuth discovery của MCP |
| Reverse rewrite host in response headers | ✘ | |

Sau đó làm 3 việc bằng tay:

1. **Gắn chứng chỉ SSL**: IIS Manager → site `Arkon` → Bindings → Add → `https`,
   port 443, host name `arkon.congty.com`, chọn certificate.
   *Chưa có SSL?* Xoá rule `Force HTTPS` trong `web.config`, và trong `.env` đổi các
   URL `https://` thành `http://` — nhưng MCP OAuth và presigned URL sẽ hạn chế.
2. **Firewall**: chỉ mở `80` và `443`. **Không** mở 3000, 5055, 5433, 6379, 9002, 9003.
3. **App pool** để `.NET CLR version = No Managed Code` (script đã set sẵn).

### Về `web.config`

File `deploy\iis\web.config` có 4 rule chạy theo thứ tự:

1. `Force HTTPS` — redirect 80 → 443.
2. `Set forwarded headers` — gắn `X-Forwarded-Proto: https`. Uvicorn chạy với
   `--proxy-headers` đọc header này để sinh đúng `https://` trong metadata OAuth của
   `/mcp`. Thiếu nó, Claude Desktop nhận link `http://` và bắt tay thất bại.
3. `Proxy to FastAPI` — các path của backend.
4. `Proxy to Next.js` — phần còn lại.

> Rule 3 tồn tại vì `next.config.ts` **chỉ** rewrite `/api/*`. Các endpoint `/mcp`,
> `/oauth/*`, `/.well-known/*` không đi qua Next.js được — phải để IIS tự tách.

### MinIO và link tải file

Link tải tài liệu / ảnh trong wiki là **presigned URL** do MinIO ký. Chữ ký SigV4 bao
gồm hostname, nên hostname trong link phải là hostname mà trình duyệt gọi tới được.

Khuyến nghị: tạo **site IIS thứ hai** cho MinIO.

```powershell
# tạo site files.congty.com trỏ vào D:\inetpub\arkon-files
New-Website -Name "Arkon-Files" -PhysicalPath "D:\inetpub\arkon-files" `
            -ApplicationPool "Arkon" -HostHeader "files.congty.com" -Port 80
Copy-Item .\deploy\iis\web.minio.config D:\inetpub\arkon-files\web.config
```

Rồi gắn SSL cho site này và đặt `MINIO_PUBLIC_ENDPOINT=files.congty.com` trong `.env`.
Khi biến này khác rỗng, Arkon tự ký URL dạng `https://`.

*Không muốn dựng site thứ hai?* Để `MINIO_PUBLIC_ENDPOINT=` rỗng và đặt
`MINIO_ENDPOINT=<ten-may-chu>:9002`, đồng thời sửa `docker-compose.infra.yml` bind
`0.0.0.0:9002` và mở firewall port 9002. Cách này **chỉ dùng được khi portal chạy
HTTP**; portal HTTPS mà ảnh gọi HTTP thì trình duyệt chặn (mixed content).

---

## 8. Kiểm tra sau khi deploy

```powershell
curl.exe -k https://arkon.congty.com/health          # {"status":"healthy",...}
curl.exe -k -I https://arkon.congty.com/             # 200
curl.exe -k -I https://arkon.congty.com/login        # 200
curl.exe -k https://arkon.congty.com/api/health      # api/database/worker đều healthy
curl.exe -k -i https://arkon.congty.com/mcp          # 401 + header WWW-Authenticate
```

Rồi mở trình duyệt:

- [ ] Đăng nhập bằng tài khoản `DEFAULT_ADMIN_EMAIL` → **đổi mật khẩu ngay**
- [ ] Vào **Settings** cấu hình AI provider (embedding model + API key, LLM)
- [ ] Upload thử 1 tài liệu → theo dõi `D:\Logs\Arkon\Arkon-Worker.out.log`,
      trạng thái phải chạy hết `processing` → `completed`
- [ ] Mở 1 trang wiki có ảnh → ảnh phải hiện (kiểm tra presigned URL / MinIO)
- [ ] Tạo MCP token ở trang **Profile**, kết nối thử từ Claude Desktop tới
      `https://arkon.congty.com/mcp`

---

## 9. Quy trình deploy code mới

```powershell
cd D:\Storm12\Arkon\arkon
git pull
.\deploy\win\build.ps1 -PublicUrl "https://arkon.congty.com"   # gồm cả alembic upgrade
.\deploy\win\restart-services.ps1
```

> Không cần restart IIS. IIS chỉ proxy, không giữ state của app.

---

## 10. Lỗi hay gặp

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| **502.3 / 504** khi mở web | Service chưa chạy, hoặc ARR chưa bật proxy | `Get-Service Arkon-*`; kiểm tra Enable proxy |
| Web hiện nhưng **không có CSS**, ảnh vỡ | Quên copy `public/` và `.next/static` vào `.next\standalone` | Chạy lại `build.ps1` |
| Gọi API bị **CORS error** | `NEXT_PUBLIC_API_URL` build ra khác domain đang truy cập | Build lại frontend với đúng `-PublicUrl` |
| Upload file lớn bị **413** | `maxAllowedContentLength` trong `web.config` | Tăng lên, mặc định file này để 500 MB |
| Request dài **đứt sau ~2 phút** | ARR timeout mặc định | Server Proxy Settings → Time-out = 600 |
| Claude Desktop **không kết nối MCP** | Còn response buffering, hoặc thiếu `X-Forwarded-Proto` | Response buffer threshold = 0; kiểm tra `allowedServerVariables` đã có `HTTP_X_FORWARDED_PROTO` |
| `/mcp` trả **500** | Rule rewrite không khớp `/mcp` (không có dấu `/` cuối) | Rule trong `web.config` đã match cả `mcp` và `mcp/...` |
| Upload xong đứng ở **processing** mãi | `Arkon-Worker` chết | `D:\Logs\Arkon\Arkon-Worker.err.log`; nhớ worker **không** tự reload code |
| Ảnh wiki **404 / mixed content** | `MINIO_PUBLIC_ENDPOINT` sai hoặc chưa dựng site `files.*` | Xem mục 7 |
| Sau reboot server **tất cả chết** | Docker Desktop chưa lên | Xem cảnh báo ở mục 4 |
| Rewrite báo lỗi **server variable not allowed** | Chưa khai báo trong `allowedServerVariables` | Chạy lại `configure-iis.ps1` |

Xem log theo thứ tự này khi debug: `D:\Logs\Arkon\*.err.log` → IIS log
`C:\inetpub\logs\LogFiles\` → `docker logs arkon_postgres`.

---

## 11. File đi kèm

```
docker-compose.infra.yml           # Postgres/Redis/MinIO, có publish port
deploy/
├── iis/
│   ├── web.config                 # site chính: rule reverse proxy
│   └── web.minio.config           # site files.* cho MinIO (đổi tên thành web.config)
└── win/
    ├── build.ps1                  # build backend + frontend + migration
    ├── install-services.ps1       # tạo 4 Windows Service bằng NSSM
    ├── restart-services.ps1       # restart sau khi deploy
    └── configure-iis.ps1          # ARR + app pool + site + copy web.config
```
