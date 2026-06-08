"""LLM 客户端封装"""
import logging

from config import LLM_API_KEY, LLM_BASE_URL, LLM_MODEL

logger = logging.getLogger(__name__)

client = None
_initialized = False


def _init_client():
    global client, _initialized
    if _initialized:
        return

    _initialized = True

    if not LLM_API_KEY:
        logger.warning("LLM_API_KEY not set, LLM disabled")
        return

    try:
        from openai import OpenAI
        client = OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY)
        logger.info(f"LLM client initialized: {LLM_BASE_URL} / {LLM_MODEL}")
    except ImportError:
        logger.warning("openai package not installed, LLM disabled")
    except Exception as e:
        logger.warning(f"LLM client init failed: {e}")


def is_enabled() -> bool:
    _init_client()
    return client is not None


def chat_stream(messages: list[dict]):
    """流式对话，返回 SSE 生成器"""
    if not is_enabled():
        yield "data: [ERROR] AI 未配置，请设置 LLM_API_KEY 环境变量\n\n"
        return

    try:
        resp = client.chat.completions.create(
            model=LLM_MODEL,
            messages=messages,
            stream=True,
        )
        for chunk in resp:
            delta = chunk.choices[0].delta.content
            if delta:
                yield f"data: {delta}\n\n"
        yield "data: [DONE]\n\n"
    except Exception as e:
        logger.error(f"LLM chat error: {e}")
        yield f"data: [ERROR] {str(e)}\n\n"


def complete(prompt: str, system: str = "") -> str:
    """非流式补全，返回完整文本"""
    if not is_enabled():
        return ""

    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    try:
        resp = client.chat.completions.create(
            model=LLM_MODEL,
            messages=messages,
        )
        return resp.choices[0].message.content or ""
    except Exception as e:
        logger.error(f"LLM complete error: {e}")
        return ""


def chat_complete_stream(prompt: str, system: str = ""):
    """流式补全（用于辅助写作），返回 SSE 生成器"""
    if not is_enabled():
        yield "data: [ERROR] AI 未配置\n\n"
        return

    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    try:
        resp = client.chat.completions.create(
            model=LLM_MODEL,
            messages=messages,
            stream=True,
        )
        for chunk in resp:
            delta = chunk.choices[0].delta.content
            if delta:
                yield f"data: {delta}\n\n"
        yield "data: [DONE]\n\n"
    except Exception as e:
        logger.error(f"LLM stream error: {e}")
        yield f"data: [ERROR] {str(e)}\n\n"
