from app.ai.llm_catalog import get_spec
from app.ai.providers.base import ProviderType
from app.ai.registry import _get_llm_class


def test_groq_qwen_3_8_27b_catalog_entry():
    spec = get_spec("groq/qwen/qwen3.8-27b")

    assert spec.provider == "groq"
    assert spec.model_id == "qwen/qwen3.8-27b"
    assert spec.context_window_tokens == 131_042
    assert spec.max_output_tokens == 16_384
    assert spec.supports_tools
    assert spec.supports_vision


def test_groq_uses_openai_compatible_llm_provider():
    provider_class = _get_llm_class(ProviderType.GROQ)

    assert provider_class.__name__ == "OpenAILLM"
