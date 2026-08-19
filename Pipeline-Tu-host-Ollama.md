# Pipeline ingest của Arkon khi tự-host Ollama

Toàn bộ luồng dưới đây được trích trực tiếp từ code (`app/worker.py`, `app/ai/mrp/*.py`, `app/services/kb_service.py`). Mỗi bước ghi rõ: nó chạy ở đâu (arq task nào), có gọi AI không, gọi loại provider nào (LLM plain / LLM tool-calling / Embedding / Vision), và điều gì thay đổi khi provider đó là Ollama tự host thay vì Anthropic/OpenAI/Google.

---

## 0. Sơ đồ tổng thể (arq task chain)

```
Upload file/URL
      │
      ▼
┌─────────────────────┐
│ ingest_file_task     │  (hoặc ingest_url_task)
│ - PyMuPDF extract    │
│ - OCR fallback       │───▶ [VISION nếu trang scan]
│ - build outline      │
│ - đếm token          │
└─────────┬────────────┘
          │ có ảnh?
          ├─ có ──▶ caption_images_task ───▶ [VISION, mỗi ảnh 1 call]
          │                    │
          ▼                    ▼
      (không ảnh)      enqueue tiếp
          │                    │
          └──────────┬─────────┘
                      ▼
          ┌───────────────────────┐
          │ ingest_map_reduce_task │
          │  Phase 0: Triage       │  (không gọi AI — chỉ đo độ dài)
          │  Phase 1: MAP          │───▶ [LLM plain generate — song song 6]
          │  Phase 2: REDUCE       │───▶ [EMBEDDING dedup + LLM plain generate]
          └───────────┬────────────┘
                      │
              plan_ready (chờ duyệt) hoặc auto-approve
                      │
                      ▼
          ┌───────────────────────┐
          │ ingest_refine_task     │
          │  Phase 3: REFINE       │───▶ [LLM plain HOẶC LLM tool-calling — song song 4]
          │  Phase 4: VERIFY       │───▶ [EMBEDDING + LLM plain, không chặn pipeline]
          │  Phase 5: COMMIT       │───▶ [EMBEDDING mỗi trang + LLM merge nếu UPDATE]
          └───────────┬────────────┘
                      ▼
              Wiki page đã publish
```

Có 2 hàng đợi arq riêng: `WorkerSettings` (ingest chính) và `SkillWorkerSettings` (skill package — không liên quan AI). `worker_max_jobs=3` mặc định nghĩa là **tối đa 3 source được xử lý song song ở cấp job**, mỗi job lại tự fan-out thêm nhiều LLM call song song bên trong (chi tiết ở mục 6).

---

## 1. Trước MRP — trích xuất & OCR (`ingest_file_task`)

File: `app/worker.py` → `app/services/kb_service.py::_extract_text_from_file`

- PyMuPDF (`fitz`) tách text từng trang — **không dùng AI**, miễn phí, nhanh, không đổi khi self-host.
- Nếu một trang PDF không có text (bản scan/ảnh) → render trang thành PNG 2x, gọi `vision_provider.analyze_image()` với prompt OCR.
  - **Đây là điểm gọi Ollama Vision đầu tiên** — nếu bạn cấu hình `active_vision_model_spec_id = ollama/llama3.2-vision` (hoặc `ollama/llava`), mỗi trang scan sẽ tốn 1 lần suy luận vision.
  - Không giới hạn concurrency ở bước này (chạy tuần tự theo vòng lặp `for idx, page_num in empty_pages`) — tài liệu vài trăm trang toàn bản scan sẽ rất chậm nếu Ollama chạy CPU.
- Đếm token (`count_tokens`) để quyết định gate `awaiting_approval` (ngưỡng mặc định 200.000 token, `auto_approve_extraction_threshold_tokens`) — bước này không dùng LLM, chỉ tokenizer nội bộ.

---

## 2. Caption ảnh (`caption_images_task`, tách riêng khỏi MRP)

File: `app/worker.py` dòng ~1173–1290.

- Chạy **song song riêng** với MAP-REDUCE, enqueue ngay sau khi ảnh được lưu, để không chặn job chính.
- **Concurrency = 4** (`MAX_CONCURRENCY = 4`), **timeout = 120s/ảnh** (`PER_IMAGE_TIMEOUT`).
- Mỗi ảnh gọi `vision_provider.analyze_image()` với prompt caption ngắn (1–3 câu).
- → **Điểm gọi Ollama Vision thứ hai.** Nếu tài liệu có nhiều hình (biểu đồ, sơ đồ), 4 request vision chạy đồng thời trên cùng 1 Ollama server — nếu server chỉ có 1 GPU và model vision load 1 lần, 4 request sẽ **xếp hàng** (trừ khi bạn bật `OLLAMA_NUM_PARALLEL` và đủ VRAM cho nhiều context song song).
- Caption được "bake" thẳng vào `source.full_text` trước khi vào MAP — nghĩa là chất lượng caption của Ollama Vision ảnh hưởng trực tiếp đến nội dung mà LLM ở Phase 1 nhìn thấy.

---

## 3. Phase 0 — Triage (không gọi AI)

File: `app/ai/mrp/mapper.py::classify_strategy`

Chỉ đo `len(full_text)`:
- `< 30.000` ký tự → `single_pass`
- `30.000 – 200.000` → `standard`
- `> 200.000` → `hierarchical`

Tài liệu "vài trăm trang" gần như chắc chắn rơi vào `hierarchical`. Không có gì thay đổi khi self-host — đây là logic Python thuần.

---

## 4. Phase 1 — MAP (`app/ai/mrp/mapper.py`)

- `build_chunks()`: chia `full_text` thành chunk ~20.000 ký tự (`CHUNK_TARGET_CHARS`), bám theo ranh giới heading level 1–2 trong outline, overlap 1.000 ký tự giữa các chunk. **Không dùng AI.**
- `extract_chunk()`: với **mỗi chunk**, gọi:
  ```python
  llm.generate(prompt, system=EXTRACTION_SYSTEM, temperature=0.1)
  ```
  → **plain text completion, KHÔNG dùng tool-calling.** Prompt yêu cầu model trả về đúng JSON schema (entities/concepts/claims/relations/topics) và được parse bằng `parse_json_loose()` (parser khoan dung: cắt code fence, cắt chuỗi tại dấu `}`/`]` cuối nếu JSON bị lỗi).
  - Đây là tin tốt cho self-host: **MAP phase không cần model hỗ trợ function calling**, chỉ cần model theo đúng instruction "trả JSON" — Llama 3.x, Qwen2.5, Mistral bản 7B+ đều làm được, dù độ chính xác JSON thấp hơn Claude/GPT.
- `run_map_phase()`: chạy các `extract_chunk()` **song song tối đa 6** (`MAX_MAP_CONCURRENCY = 6`), mỗi lệnh gọi có **timeout 120s** (`EXTRACT_TIMEOUT`). Mỗi chunk-extract được lưu ngay vào DB (`SourceChunkExtract`) để resume nếu crash giữa chừng.
  - → Với tài liệu 900.000 ký tự / 20.000 mỗi chunk ≈ **45 chunk**, chia thành các đợt 6 song song ≈ 8 đợt tuần tự.
  - **Đây là điểm chịu tải nặng nhất khi tự host**: 6 request LLM đồng thời liên tục dội vào 1 Ollama server. Nếu server chỉ chạy 1 model instance không có `OLLAMA_NUM_PARALLEL` phù hợp, throughput thực tế sẽ giống chạy tuần tự — 45 chunk × (thời gian sinh ~1-2k token) có thể mất hàng giờ trên GPU tầm trung, so với vài phút qua API cloud.

---

## 5. Phase 2 — REDUCE (`app/ai/mrp/reducer.py`)

7 bước theo đúng docstring trong file:

1. **Gộp entities/concepts** từ tất cả chunk extract — thuần Python.
2. **Dedup chính xác** theo tên chuẩn hoá — thuần Python.
3. **Dedup bằng embedding** (cosine similarity, ngưỡng `MERGE_THRESHOLD=0.90`) → **gọi Ollama Embedding** cho từng entity/concept chưa dedup được bằng tên.
4. **LLM batch resolution** cho các cặp mơ hồ (similarity 0.75–0.90, `AMBIGUOUS_LOW`) → `llm.generate(...,"You are a concept resolution assistant. Return only JSON.")` — plain generate, batch nhiều cặp trong 1 prompt.
5. **KB reconciliation**: tìm trang wiki đã có tương ứng bằng embedding search (`reconcile_with_kb`) → **gọi Ollama Embedding** để encode từng entity rồi so cosine với các trang hiện có (`KB_UPDATE_THRESHOLD=0.85`, `KB_MAYBE_THRESHOLD=0.60`).
6. **LLM batch confirmation** cho các match "MAYBE" → plain generate khác.
7. **Planning call — 1 LLM call duy nhất** (`run_planning_call`) sinh ra toàn bộ **Compilation Plan JSON** (danh sách trang wiki sẽ tạo/cập nhật, cấu trúc, evidence mapping) → `llm.generate(prompt, system=PLANNING_SYSTEM, temperature=0.1)`.
   - Đây là **prompt lớn nhất và quan trọng nhất của cả pipeline** — nó nhìn toàn bộ entities/concepts/claims đã gom được từ MAP để quyết định cấu trúc wiki. Với tài liệu vài trăm trang, prompt này có thể rất dài (tuỳ số lượng entity/claim trích ra) → đây là chỗ **context window của model thực sự bị thử thách nhất**, không phải ở MAP (MAP chỉ thấy từng chunk 20k ký tự).
   - Nếu model self-host có context nhỏ hoặc quantization thấp làm giảm khả năng theo dõi danh sách dài → plan có thể bỏ sót/trùng lặp trang, hoặc JSON bị cắt cụt (model tự dừng giữa chừng vì token limit) → `parse_json_loose` fail → cả Phase 2 fail.

→ REDUCE là bước **dùng cả 2 loại provider tự host cùng lúc** (Embedding cho dedup/reconciliation, LLM cho resolution/planning) — nếu bạn định hybrid (self-host embedding, giữ LLM cloud), REDUCE vẫn benefit được phần rẻ (embedding) mà không rủi ro chất lượng planning call.

---

## 6. Cổng duyệt / auto-approve

Nếu `mrp_auto_approve_plan=False` (mặc định) → dừng ở `plan_ready`, chờ người duyệt qua UI (`POST /sources/{id}/plan/approve`), rồi mới enqueue `ingest_refine_task`. Không có AI call ở bước chờ này — nhưng nếu người dùng bấm "Regenerate" với feedback, `regenerate_plan_task` chạy lại `reconcile_with_kb` + `run_planning_call` (tức lặp lại bước 5+7 ở trên với 1 LLM call mới cộng note phản hồi).

---

## 7. Phase 3 — REFINE (`app/ai/mrp/writer.py`) — bước phức tạp nhất

Mỗi trang trong Compilation Plan được viết độc lập, **song song tối đa 4** (`MAX_WRITER_CONCURRENCY = 4`). Với mỗi trang, code chọn 1 trong 3 chiến lược:

### 7a. Ngân sách & chế độ single vs multi-pass
`_get_source_context_budget(llm)` đọc `context_window_tokens` từ catalog spec của LLM đang active → `budget_chars = context_window_tokens × 4 × 0.85` (cap 2.500.000 ký tự). Nếu phần văn bản liên quan (`tier_a + tier_b`) vượt `budget × 0.7` → chuyển **multipass**; nếu không → single-pass.

**Đây chính là nơi giá trị `context_window_tokens` bạn khai trong `llm_catalog.py` cho Ollama phải khớp với `num_ctx` thật sự cấu hình trên Ollama server** (đã cảnh báo ở bước tự-host trước) — khai sai làm toàn bộ phép tính single/multipass sai theo.

### 7b. Single-pass — simple (`_write_page_simple`)
Trang có ≤8 evidence item và (nếu UPDATE) nội dung cũ ≤3.000 ký tự (`WRITER_COMPLEX_THRESHOLD_EVIDENCE=8`, `WRITER_COMPLEX_THRESHOLD_EXISTING_CHARS=3_000`):
```python
llm.generate(prompt, system=WRITER_SYSTEM, temperature=0.15)
```
Plain generate — không cần tool-calling.

### 7c. Single-pass — complex (`_write_page_complex`)
Trang có **>8 evidence item** HOẶC nội dung cũ **>3.000 ký tự** — tức là các trang "hub"/trang quan trọng có nhiều claim đổ về, hoặc trang đang cập nhật đã có sẵn nội dung lớn:
```python
llm.generate_with_tools(messages=..., tools=_COMPLEX_WRITER_TOOLS, system=_COMPLEX_WRITER_SYSTEM, ...)
```
Đây là **agent loop thật sự** — tối đa 10 bước (`WRITER_AGENT_MAX_STEPS=10`), model tự quyết định gọi tool `read_kb_page` (đọc trang wiki liên quan), `read_source_excerpt` (đọc thêm đoạn gốc), hoặc `finish` (kết thúc, trả `content_md` + `summary`). Timeout **300s/lần gọi** (`WRITER_AGENT_TIMEOUT`).

→ **Đây là điểm bắt buộc phải có function-calling đáng tin cậy** — chính là giới hạn lớn nhất khi self-host, vì `LLMProvider.generate_with_tools` mặc định `raise NotImplementedError` nếu provider không hỗ trợ (`base.py`), và với model Ollama nhỏ/quantize thấp, tool-call JSON hay bị sai schema, gọi sai tool, hoặc lặp vô hạn tới khi hết 10 bước mà chưa gọi `finish`. Với tài liệu vài trăm trang, **rất nhiều trang sẽ có >8 evidence item** (vì càng nhiều nguồn thì càng nhiều claim đổ về các trang khái niệm trung tâm) → nhánh complex này sẽ được kích hoạt thường xuyên, không phải trường hợp hiếm.

### 7d. Multi-pass (`_write_page_multipass`)
Khi tài liệu liên quan vượt ngân sách 1 lần gọi — chia thành nhiều lượt: viết bản đầu → `WRITER_SYSTEM` → mở rộng thêm → `WRITER_SYSTEM_EXTEND` → hoàn thiện/polish → `WRITER_SYSTEM_POLISH`. Toàn bộ đều `llm.generate()` thuần (không tool-calling), nhưng **nhiều lần gọi tuần tự cho CÙNG 1 trang** → với model self-host chậm, một trang multipass có thể mất nhiều phút.

---

## 8. Phase 4 — VERIFY (`app/ai/mrp/verifier.py`)

Không chặn pipeline (issues chỉ log/gắn marker), 2 kiểm tra:

- **4.1 Coverage check**: đếm entity xuất hiện ≥3 lần trong extract nhưng không trang nào cover — **thuần Python, không AI**.
- **4.2 Conflict check**: so sánh nội dung trang mới với trang KB cũ bằng embedding similarity (`CONFLICT_SIM_THRESHOLD=0.80`) rồi xác nhận bằng `llm.generate(..., "You are a fact-checking assistant. Return only JSON.")` — plain generate.

→ Dùng cả Ollama Embedding và Ollama LLM (plain), nhưng vì non-blocking nên kết quả tệ ở bước này **không làm hỏng dữ liệu đã ghi**, chỉ giảm chất lượng cảnh báo xung đột.

---

## 9. Phase 5 — COMMIT (`app/ai/mrp/pipeline.py::run_commit_phase`)

- Ghi từng trang vào DB (`wiki_service.apply_create` / `apply_update`) — không AI.
- Nếu action = UPDATE và trang cũ đã có nội dung (>100 ký tự) và nguồn mới chưa từng đóng góp vào trang này → gọi `merge_page_content()` (`app/ai/mrp/merger.py`) → `llm.generate(prompt, system=MERGE_SYSTEM, temperature=0.1)` để hợp nhất nội dung cũ + mới. Plain generate.
- Với mỗi trang vừa tạo/cập nhật → **1 lần gọi Ollama Embedding** (`embedding_provider.embed(embed_text)`) để lưu vector tìm kiếm.
- Cuối cùng `regenerate_index()` build lại trang mục lục — không AI.

---

## 10. Bảng tổng hợp điểm chạm Ollama

| Bước | Provider cần | Tool-calling bắt buộc? | Concurrency | Timeout | Rủi ro chính khi self-host |
|---|---|---|---|---|---|
| OCR trang scan (extract) | Vision | Không | Tuần tự | — | Chậm nếu CPU; chất lượng OCR kém với bảng/chữ Việt có dấu |
| Caption ảnh | Vision | Không | 4 | 120s/ảnh | Nghẽn nếu Ollama không phục vụ song song |
| MAP — extract_chunk | LLM | **Không** | 6 | 120s/chunk | Model nhỏ ra JSON sai format; tổng thời gian dài (~45 chunk cho 300 trang) |
| REDUCE — dedup/reconcile | Embedding | — | tuần tự theo entity | — | Chậm nếu nhiều entity; chất lượng dedup phụ thuộc embedding model |
| REDUCE — resolution/confirm | LLM | Không | batch trong 1 call | — | JSON batch dài dễ lỗi ở model yếu |
| REDUCE — planning call | LLM | Không | 1 call/tài liệu | — | **Prompt dài nhất pipeline** — nơi context window/quality bị thử thách nhất |
| REFINE — simple writer | LLM | Không | 4 | — | Chấp nhận được với model tầm trung |
| REFINE — **complex writer** | LLM | **Có — bắt buộc** | 4 | 300s/call, tối đa 10 bước | **Rủi ro cao nhất**: cần model hỗ trợ tool-calling ổn định; kích hoạt thường xuyên (>8 evidence) |
| REFINE — multipass writer | LLM | Không | 4 | — | Một trang có thể mất nhiều lượt gọi tuần tự |
| VERIFY — conflict check | Embedding + LLM | Không | — | — | Non-blocking, rủi ro thấp |
| COMMIT — merge | LLM | Không | tuần tự theo trang | — | Chấp nhận được |
| COMMIT — embed trang | Embedding | — | tuần tự theo trang | — | Chấp nhận được |

---

## 11. Vấn đề vận hành tổng thể (riêng cho self-host)

**Tổng số request đồng thời có thể dội vào Ollama:** `worker_max_jobs=3` (số source xử lý song song ở cấp job) × tối đa 6 (MAP) hoặc 4 (WRITER) request/job → lý thuyết tới 18 request LLM đồng thời nếu 3 source cùng ở Phase 1 MAP. Một Ollama server chạy 1 GPU thường chỉ phục vụ tốt vài request song song (`OLLAMA_NUM_PARALLEL`, mặc định thấp) — vượt quá sẽ bị xếp hàng, không lỗi nhưng chậm tuyến tính. Cân nhắc giảm `worker_max_jobs` xuống 1 khi self-host, hoặc chấp nhận hàng đợi dài.

**Timeout hiện có được thiết kế quanh tốc độ API cloud** — `EXTRACT_TIMEOUT=120s`, `WRITER_AGENT_TIMEOUT=300s`, `worker_job_timeout=1800s` (toàn job). Model self-host chạy CPU hoặc GPU yếu có thể sinh 1 response JSON dài chậm hơn 120s, khiến chunk bị coi là thất bại dù model "đang chạy". Cần benchmark tốc độ token/s thực tế của model đã chọn trước khi ingest tài liệu vài trăm trang, và tăng các hằng số timeout này trong code nếu cần (chúng là hardcode, không đọc từ `.env`).

**Tool-calling ở REFINE complex writer là rủi ro lớn nhất.** Nếu bạn dùng đúng `OllamaLLM.generate_with_tools` đã viết trong guide tự-host (tái dùng `/v1/chat/completions` tương thích OpenAI) thì về mặt kỹ thuật không raise `NotImplementedError` — nhưng chất lượng tool-call thực tế của model vẫn là điểm rủi ro: model self-host có thể (a) trả JSON tool-call sai format khiến `json.loads` fail âm thầm (args rỗng, trang bị viết thiếu evidence), hoặc (b) không bao giờ gọi `finish` → vòng lặp chạy đủ 10 bước (`WRITER_AGENT_MAX_STEPS`) rồi trả về rỗng, trang đó coi như thất bại. Nên test kỹ nhánh này riêng (tạo 1 trang có >8 evidence thủ công) trước khi chạy full pipeline trên tài liệu vài trăm trang.

**Khuyến nghị hybrid thực tế**: dùng Ollama cho Embedding (bước 5, 8, 9 — ít nhạy cảm, rẻ) và giữ Anthropic/Gemini cho LLM (đặc biệt REDUCE planning call và REFINE complex writer — 2 chỗ đòi hỏi chất lượng/context/tool-calling cao nhất). Cách này vẫn giảm đáng kể chi phí embedding (khối lượng lớn nhất về số lượng call) mà không đánh đổi chất lượng ở 2 điểm quyết định cấu trúc và nội dung wiki.
