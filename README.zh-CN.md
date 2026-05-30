# Synapse

**一个 AI 驱动的个人知识管理系统。** 你只管写内容，剩下的全交给 AI —— 自动标签、自动关联、自动质检、自动构建知识图谱。零人工干预。

[English](README.md)

![License](https://img.shields.io/badge/license-MIT-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![Python](https://img.shields.io/badge/Python-3.11+-green)
![FastAPI](https://img.shields.io/badge/FastAPI-0.100+-009688)

## 什么是 Synapse？

Synapse 是一个自托管的知识库，使用 AI 自动整理你的笔记。不同于传统笔记应用需要手动打标签、分类、链接，Synapse 在后台自动完成所有这些工作 —— 你只需要写。

**核心理念：零触摸知识管理。**

## 功能特性

- ✍️ **写完即忘** — AI 自动打标签、分类、建立关联
- 🔗 **自动关联** — AI 发现笔记间的联系，自动创建 `[[wikilink]]`
- 🏷️ **智能标签** — 基于内容语义自动生成标签，无需手动选择
- 🏥 **健康检查** — 自动检测断链、孤立笔记、内容问题
- 🕸️ **知识图谱** — 交互式力导向图可视化笔记关联
- 🔍 **全文搜索** — 支持中文的全文搜索
- 🌙 **暗色模式** — 明暗主题切换
- 📱 **多平台** — Web UI、Android 应用、Chrome 扩展

## 工作原理

```
你写笔记 → AI 打标签 → AI 建关联 → 后台质检 → 图谱更新
    ↓           ↓           ↓           ↓            ↓
  存入数据库  标签写入    wikilink    断链修复    力导向图
```

所有操作在后台自动运行，无需点击按钮，无需额外操作。

## 技术栈

| 层级 | 技术 |
|------|------|
| 后端 | Python, FastAPI, SQLite |
| AI | OpenAI API / 兼容接口 |
| Web 前端 | HTML/CSS/JS, Vue 3, Markdown-it |
| 移动应用 | Flutter, Dart |
| 浏览器扩展 | Chrome Extension (Manifest V3) |

## 快速开始

### 环境要求

- Python 3.11+
- Flutter 3.x（移动端开发）
- LLM API 密钥（OpenAI 或兼容接口）

### 后端启动

```bash
cd backend
pip install -r requirements.txt

# 配置环境变量
export LLM_API_KEY="your-api-key"
export LLM_BASE_URL="https://api.openai.com/v1"
export LLM_MODEL="gpt-4"

# 启动服务（AI 后台任务自动运行）
python main.py
```

### Web 前端

直接在浏览器中打开 `frontend/index.html`，或使用 nginx 部署。

### 移动应用

```bash
cd app
flutter pub get
flutter run
```

首次启动时，在设置页面配置服务器地址。

### 浏览器扩展

1. Chrome → 扩展程序 → 加载已解压的扩展程序
2. 选择 `extension/` 目录

## 环境变量

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `LLM_API_KEY` | LLM API 密钥（必填） | — |
| `LLM_BASE_URL` | LLM API 地址 | `https://api.openai.com/v1` |
| `LLM_MODEL` | LLM 模型名称 | `gpt-4` |
| `WIKI_API_TOKEN` | API 访问令牌（留空则不启用认证） | — |
| `RAG_MAX_NOTES` | RAG 最大笔记数 | `5` |
| `RAG_MAX_CHARS` | 每篇笔记最大字符数 | `8000` |

## API 文档

| 方法 | 端点 | 说明 |
|------|------|------|
| GET | `/api/notes` | 获取笔记列表（支持 `?search=` 和 `?tag=`） |
| GET | `/api/notes/:id` | 获取笔记详情 |
| GET | `/api/notes/:id/relations` | 获取笔记关联 |
| GET | `/api/tags` | 获取所有标签 |
| GET | `/api/graph` | 获取图谱数据 |
| POST | `/api/ai/lint` | 运行 AI 健康检查 |
| POST | `/api/ai/chat` | AI 对话 |
| POST | `/api/ai/auto-tag` | AI 自动标签 |
| POST | `/api/upload` | 上传文件 |

## 构建

APK 通过 GitHub Actions 自动构建。推送到 `main` 分支后会自动发布到 [Releases](../../releases)。

## 开发

详见 [DEV.md](DEV.md)

## License

MIT
