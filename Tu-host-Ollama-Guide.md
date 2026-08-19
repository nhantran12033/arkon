# Tự host mô hình với Arkon (Ollama)

Guide này thêm **Ollama** làm provider tự-host cho LLM / Embedding / Vision, tận dụng khung sườn có sẵn trong `app/ai/providers/` — không cần đổi frontend vì Settings UI đọc catalog động qua `GET /settings/providers`.

Ollama expose REST API tương thích chuẩn OpenAI tại `/v1`, nên cách nhanh nhất là tái dùng gần như nguyên `OpenAIProvider` với `base_url` trỏ vào Ollama và `api_key` là chuỗi bất kỳ (Ollama không kiểm tra key).

---

## 0. Chọn model

| Việc cần | Model gợi ý | Ghi chú |
|---|---|---|
| LLM (có tool-calling) | `llama3.3:70b` hoặc `qwen2.5:32b` | Cần hỗ trợ function calling — model nhỏ (<7B) thường tool-call không ổn định |
| Embedding | `nomic-embed-text` (768d) hoặc `mxbai-embed-large` (1024d) | Trùng khớp bảng `wiki_page_embeddings_768` / `_1024` đã có sẵn trong DB → **không cần migration mới** |
| Vision | `llama3.2-vision:11b` hoặc `llava:13b` | Chỉ cần nếu muốn caption ảnh tự host |

Model càng lớn thì cần VRAM càng nhiều (quy tắc thô: ~model size GB × 1.2 cho Q4 quantization). 70B ở Q4 cần ~40GB VRAM — nếu không có GPU đủ mạnh, dùng bản nhỏ hơn (8B–32B) hoặc chấp nhận chạy CPU (chậm).

---

## 1. Thêm service Ollama vào `docker-compose.yml`

```yaml
services:
  # ── Infrastructure ────────────────────────────────────────────
  ollama:
    image: ollama/ollama:latest
    container_name: arkon_ollama
    restart: always
    volumes:
      - ollama_data:/root/.ollama
    ports:
      - "11434:11434"          # bỏ nếu không cần truy cập từ host
    deploy:                     # bỏ khối này nếu chạy CPU-only
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:11434 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10

volumes:
  ollama_data:   # thêm vào khối volumes: ở cuối file, cùng chỗ postgres_data, redis_data...
```

Sau khi `docker compose up -d ollama`, pull model:

```bash
docker exec -it arkon_ollama ollama pull llama3.3
docker exec -it arkon_ollama ollama pull nomic-embed-text
docker exec -it arkon_ollama ollama pull llama3.2-vision   # nếu cần vision
```

Muốn dùng GPU cần cài `nvidia-container-toolkit` trên host trước — nếu chỉ có CPU thì bỏ khối `deploy:` ở trên, Ollama vẫn chạy được, chỉ chậm hơn nhiều.

Backend (`api`, `worker`) sẽ gọi Ollama qua `http://ollama:11434/v1` (tên service trong cùng docker network) — không cần expose port ra ngoài trừ khi bạn muốn test từ máy host.

---

## 2. Viết provider `app/ai/providers/ollama.py`

Tạo file mới, kế thừa gần như nguyên logic của `openai_provider.py` (đã đọc trong repo) vì Ollama tương thích OpenAI API:

```python
"""
Ollama provider — self-hosted LLM, embedding, and vision via Ollama's
OpenAI-compatible API (http://<host>:11434/v1).

Ollama does not check `api_key`, but the OpenAI SDK client requires a
non-empty string, so we default to a dummy value.
"""

import base64
import json
from typing import Optional

from loguru import logger

from app.ai.agent_protocol import (
    AssistantTurn,
    ToolCall,
    neutral_to_openai_messages,
)
from app.ai.providers.base import (
    EmbeddingProvider,
    LLMProvider,
    ProviderConfig,
    VisionProvider,
)

_DEFAULT_BASE_URL = "http://ollama:11434/v1"  # docker service name; use
                                                # http://localhost:11434/v1 for local dev


class OllamaEmbedding(EmbeddingProvider):
    """Ollama embedding provider (nomic-embed-text, mxbai-embed-large, ...)."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self._client = None

    @property
    def client(self):
        if self._client is None:
            import openai
            self._client = openai.AsyncOpenAI(
                api_key=self.config.api_key or "ollama",
                base_url=self.config.base_url or _DEFAULT_BASE_URL,
            )
        return self._client

    async def embed(self, text: str) -> list[float]:
        response = await self.client.embeddings.create(
            model=self.config.model_id,
            input=text,
        )
        return response.data[0].embedding

    async def embed_batch(
        self, texts: list[str], concurrency: int = 5
    ) -> list[list[float]]:
        # Most Ollama embedding models handle small batches fine; keep it
        # conservative since local hardware has less headroom than a
        # managed API.
        batch_size = 16
        all_embeddings: list[list[float]] = []

        for i in range(0, len(texts), batch_size):
            batch = texts[i : i + batch_size]
            response = await self.client.embeddings.create(
                model=self.config.model_id,
                input=batch,
            )
            sorted_data = sorted(response.data, key=lambda x: x.index)
            all_embeddings.extend([d.embedding for d in sorted_data])

        logger.debug(f"Ollama: embedded {len(texts)} texts in batches of {batch_size}")
        return all_embeddings

    async def test_connection(self) -> tuple[bool, str]:
        try:
            result = await self.embed("test connection")
            return True, f"OK — model={self.config.model_id}, dimensions={len(result)}"
        except Exception as e:
            return False, f"Ollama embedding error: {e}"


class OllamaLLM(LLMProvider):
    """Ollama LLM provider (llama3.3, qwen2.5, mistral, ...)."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self._client = None

    @property
    def client(self):
        if self._client is None:
            import openai
            self._client = openai.AsyncOpenAI(
                api_key=self.config.api_key or "ollama",
                base_url=self.config.base_url or _DEFAULT_BASE_URL,
            )
        return self._client

    async def generate(
        self,
        prompt: str,
        system: Optional[str] = None,
        max_tokens: Optional[int] = None,
        temperature: float = 0.7,
    ) -> str:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        kwargs: dict = {
            "model": self.config.model_id,
            "messages": messages,
            "temperature": temperature,
        }
        if max_tokens is not None:
            kwargs["max_tokens"] = max_tokens

        response = await self.client.chat.completions.create(**kwargs)
        return response.choices[0].message.content or ""

    async def generate_with_tools(
        self,
        messages: list[dict],
        tools: list[dict],
        system: Optional[str] = None,
        max_tokens: Optional[int] = None,
        temperature: float = 0.2,
    ) -> AssistantTurn:
        # Only works if the pulled model supports function calling
        # (llama3.1+, llama3.3, qwen2.5, mistral-nemo, ...). Small/older
        # models will error or ignore `tools` silently.
        ollama_messages = []
        if system:
            ollama_messages.append({"role": "system", "content": system})
        ollama_messages.extend(neutral_to_openai_messages(messages))

        kwargs: dict = {
            "model": self.config.model_id,
            "messages": ollama_messages,
            "tools": tools,
            "temperature": temperature,
        }
        if max_tokens is not None:
            kwargs["max_tokens"] = max_tokens

        response = await self.client.chat.completions.create(**kwargs)

        choice = response.choices[0]
        message = choice.message
        text = message.content
        tool_calls: list[ToolCall] = []
        if message.tool_calls:
            for tc in message.tool_calls:
                args: dict = {}
                if tc.function.arguments:
                    try:
                        args = json.loads(tc.function.arguments)
                    except Exception:
                        pass
                tool_calls.append(ToolCall(id=tc.id, name=tc.function.name, arguments=args))

        reason_map = {"stop": "end_turn", "tool_calls": "tool_use", "length": "max_tokens"}
        finish_reason = reason_map.get(choice.finish_reason or "stop", "end_turn")

        return AssistantTurn(text=text or None, tool_calls=tool_calls, finish_reason=finish_reason)

    async def test_connection(self) -> tuple[bool, str]:
        try:
            result = await self.generate("Say 'OK'", max_tokens=10, temperature=0)
            return True, f"OK — model={self.config.model_id}, response='{result[:50]}'"
        except Exception as e:
            return False, f"Ollama LLM error: {e}"


class OllamaVision(VisionProvider):
    """Ollama vision provider (llama3.2-vision, llava, bakllava, ...)."""

    def __init__(self, config: ProviderConfig):
        super().__init__(config)
        self._client = None

    @property
    def client(self):
        if self._client is None:
            import openai
            self._client = openai.AsyncOpenAI(
                api_key=self.config.api_key or "ollama",
                base_url=self.config.base_url or _DEFAULT_BASE_URL,
            )
        return self._client

    async def analyze_image(
        self,
        image_data: bytes,
        mime_type: str = "image/jpeg",
        prompt: Optional[str] = None,
    ) -> str:
        if not prompt:
            prompt = (
                "Describe this image in detail. If it's a diagram, flowchart, "
                "or table, explain the meaning and steps."
            )
        b64_image = base64.b64encode(image_data).decode("utf-8")
        data_url = f"data:{mime_type};base64,{b64_image}"

        response = await self.client.chat.completions.create(
            model=self.config.model_id,
            messages=[{
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": data_url}},
                ],
            }],
            temperature=0.2,
        )
        return response.choices[0].message.content or ""

    async def test_connection(self) -> tuple[bool, str]:
        try:
            tiny_png = (
                b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
                b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
                b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
                b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
            )
            await self.analyze_image(tiny_png, "image/png", "What is this?")
            return True, f"OK — model={self.config.model_id}"
        except Exception as e:
            return False, f"Ollama Vision error: {e}"
```

---

## 3. Đăng ký provider trong `app/ai/registry.py`

Sửa 3 hàm factory (thêm nhánh `elif provider == ProviderType.OLLAMA`):

```python
def _get_embedding_class(provider: ProviderType) -> type[EmbeddingProvider]:
    if provider == ProviderType.GOOGLE:
        from app.ai.providers.google import GoogleEmbedding
        return GoogleEmbedding
    elif provider == ProviderType.OPENAI:
        from app.ai.providers.openai_provider import OpenAIEmbedding
        return OpenAIEmbedding
    elif provider == ProviderType.OLLAMA:
        from app.ai.providers.ollama import OllamaEmbedding
        return OllamaEmbedding
    raise ValueError(f"Unsupported embedding provider: {provider}")


def _get_llm_class(provider: ProviderType) -> type[LLMProvider]:
    if provider == ProviderType.GOOGLE:
        from app.ai.providers.google import GoogleLLM
        return GoogleLLM
    elif provider == ProviderType.OPENAI:
        from app.ai.providers.openai_provider import OpenAILLM
        return OpenAILLM
    elif provider == ProviderType.ANTHROPIC:
        from app.ai.providers.anthropic_provider import AnthropicLLM
        return AnthropicLLM
    elif provider == ProviderType.OLLAMA:
        from app.ai.providers.ollama import OllamaLLM
        return OllamaLLM
    raise ValueError(f"Unsupported LLM provider: {provider}")


def _get_vision_class(provider: ProviderType) -> type[VisionProvider]:
    if provider == ProviderType.GOOGLE:
        from app.ai.providers.google import GoogleVision
        return GoogleVision
    elif provider == ProviderType.OPENAI:
        from app.ai.providers.openai_provider import OpenAIVision
        return OpenAIVision
    elif provider == ProviderType.OLLAMA:
        from app.ai.providers.ollama import OllamaVision
        return OllamaVision
    raise ValueError(f"Unsupported vision provider: {provider}")
```

Không cần sửa gì thêm trong file này — `_PROVIDER_LABELS` đã có sẵn `"ollama": "Ollama"`.

---

## 4. Thêm entry vào catalog

### `app/ai/llm_catalog.py`

```python
"ollama/llama3.3": LLMModelSpec(
    id="ollama/llama3.3",
    provider="ollama",
    model_id="llama3.3",              # tên đúng như đã `ollama pull`
    context_window_tokens=128_000,
    max_output_tokens=8_000,
    supports_tools=True,
    supports_vision=False,
    label="Llama 3.3 70B (self-hosted)",
    cost_per_1m_input_tokens=0.0,
    cost_per_1m_output_tokens=0.0,
    notes="Self-hosted via Ollama. Cần GPU ~40GB VRAM ở Q4 quantization.",
),
```

### `app/ai/embedding_catalog.py`

```python
"ollama/nomic-embed-text": EmbeddingModelSpec(
    id="ollama/nomic-embed-text",
    provider="ollama",
    model_id="nomic-embed-text",
    dimension=768,                    # khớp bảng wiki_page_embeddings_768 có sẵn
    max_input_tokens=8192,
    label="Nomic Embed Text (self-hosted, 768d)",
    cost_per_1m_tokens=0.0,
    notes="Self-hosted via Ollama. Không tốn phí API nhưng chất lượng multilingual kém hơn Gemini/OpenAI.",
),
```

> Nếu chọn model có `dimension` khác 768/1024/1536/3072 (các dim đã có bảng), bạn phải thêm bảng `wiki_page_embeddings_<dim>` mới + Alembic migration — xem comment trong `embedding_catalog.py` để rõ quy trình.

### `app/ai/vision_catalog.py` (nếu cần)

```python
"ollama/llama3.2-vision": VisionModelSpec(
    id="ollama/llama3.2-vision",
    provider="ollama",
    model_id="llama3.2-vision",
    max_image_size_mb=20,
    label="Llama 3.2 Vision 11B (self-hosted)",
    cost_per_1m_input_tokens=0.0,
    cost_per_image=0.0,
    notes="Self-hosted via Ollama.",
),
```

`VisionModelSpec.provider` comment ghi `"openai" | "google"` — cập nhật thành `"openai" | "google" | "ollama"` cho đúng thực tế.

---

## 5. Cấu hình qua Settings

Sau khi deploy code trên (`docker compose up -d --build`), vào Admin Portal → **Settings**, hoặc gọi thẳng API:

```bash
curl -X PUT http://localhost:5055/settings \
  -H "Content-Type: application/json" \
  -d '{
    "settings": {
      "active_llm_model_spec_id": "ollama/llama3.3",
      "llm_api_key": "ollama",
      "llm_base_url": "http://ollama:11434/v1",

      "active_embedding_model_spec_id": "ollama/nomic-embed-text",
      "embedding_api_key__ollama": "ollama",
      "embedding_base_url": "http://ollama:11434/v1"
    }
  }'
```

(Cần header auth của user có quyền `org:settings:manage` — dùng qua UI sẽ tự động kèm session.)

**Lưu ý quan trọng nếu đổi embedding model đang dùng:** Arkon có cơ chế "online re-embed migration" (atomic flip, không mất search) — nếu bạn đã có dữ liệu embed bằng Google/OpenAI trước đó, đừng đổi `active_embedding_model_spec_id` trực tiếp; dùng flow re-embed migration có sẵn trong Settings → Embedding thay vì set tay key này, nếu không search sẽ trả kết quả sai (vector cũ và mới không cùng không gian).

---

## 6. Test

```bash
curl -X POST http://localhost:5055/settings/test-llm
curl -X POST http://localhost:5055/settings/test-embedding
curl -X POST http://localhost:5055/settings/test-vision   # nếu đã cấu hình
```

Hoặc nút "Test Connection" trong Settings UI — nó gọi đúng 3 endpoint trên.

---

## 7. Checklist tổng hợp

1. Thêm service `ollama` vào `docker-compose.yml` + volume `ollama_data`.
2. `docker exec -it arkon_ollama ollama pull <model>` cho từng model cần dùng.
3. Tạo `app/ai/providers/ollama.py` (LLM, Embedding, Vision — vision optional).
4. Sửa `app/ai/registry.py`: thêm nhánh `OLLAMA` vào 3 hàm `_get_*_class`.
5. Thêm entry vào `llm_catalog.py` / `embedding_catalog.py` / `vision_catalog.py`.
6. Set config qua Settings UI hoặc API (`active_llm_model_spec_id`, `llm_base_url`, `llm_api_key`, tương tự cho embedding/vision).
7. Test connection qua UI hoặc `/settings/test-*`.
8. Theo dõi RAM/VRAM khi chạy MRP pipeline — giờ cả compile wiki lẫn inference đều ăn tài nguyên trên cùng máy chủ, khác với setup gọi API ngoài (README cũ nói "GPU is not required" — giả định này không còn đúng nữa).

## Rủi ro / đánh đổi cần biết

Chất lượng output (đặc biệt cho MRP wiki-compilation pipeline vốn cần context window lớn và suy luận tốt) của model self-host thường thấp hơn Claude/GPT/Gemini đời mới, trừ khi chạy model rất lớn (70B+). Tool-calling trên model nhỏ có thể không ổn định — nếu `wiki_agent.py` hoặc các bước MRP dùng `generate_with_tools`, nên test kỹ trước khi thay hoàn toàn provider ngoài. Có thể cân nhắc **hybrid**: dùng Ollama cho embedding (rẻ, ít nhạy cảm hơn) nhưng vẫn giữ Anthropic/OpenAI cho LLM compile wiki — vì đây là nơi chất lượng ảnh hưởng trực tiếp đến độ chính xác của knowledge base.
