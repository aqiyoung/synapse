"""LLM 配置"""
import os

# LLM 配置 — 通过环境变量设置
LLM_API_KEY = os.environ.get("LLM_API_KEY", os.environ.get("ANTHROPIC_AUTH_TOKEN", ""))
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "https://api.longcat.chat/openai/v1")
LLM_MODEL = os.environ.get("LLM_MODEL", "LongCat-2.0-Preview")
LLM_ENABLED = bool(LLM_API_KEY)

# RAG 配置
RAG_MAX_NOTES = int(os.environ.get("RAG_MAX_NOTES", "5"))       # 最多传入几篇笔记
RAG_MAX_CHARS = int(os.environ.get("RAG_MAX_CHARS", "8000"))    # 每篇笔记最多字符数

# API 认证 token（通过环境变量 WIKI_API_TOKEN 设置，留空则不启用认证）
API_TOKEN = os.environ.get("WIKI_API_TOKEN", "")
