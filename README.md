# Knowledge Base

一个 **AI 驱动**的个人知识管理系统。你只管写内容，剩下的全交给 AI——自动标签、自动整理、自动质检、自动关联。后台脚本持续运行，无需人工干预。

![License](https://img.shields.io/badge/license-MIT-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![Python](https://img.shields.io/badge/Python-3.11+-green)
![FastAPI](https://img.shields.io/badge/FastAPI-0.100+-009688)

## 核心理念

**零人工操作** — 所有知识管理工作由 AI 自动完成：

- ✍️ **写入即归档** — 笔记写好后 AI 自动打标签、分类、建立关联
- 🔗 **自动关联** — AI 分析内容，自动发现并建立笔记间的 `[[wikilink]]`
- 🏷️ **智能标签** — 根据内容语义自动生成标签，无需手动选择
- 🏥 **持续质检** — 后台脚本自动检测断链、孤立笔记、内容问题
- 📊 **知识图谱** — 自动构建和更新笔记关系图谱

## 功能特性

- 📝 **笔记管理** — 支持 Markdown 的创建、编辑和组织
- 🏷️ **标签系统** — AI 自动标签 + 手动标签
- 🔍 **全文搜索** — 跨所有笔记的全文搜索
- 🕸️ **知识图谱** — 交互式力导向图可视化笔记关联
- 🔗 **Wiki 链接** — 用 `[[wiki-style]]` 语法链接笔记
- 🏥 **健康检查** — AI 驱动的断链检测、孤立笔记检测
- 🌙 **暗色模式** — 明暗主题切换
- 📱 **多平台** — Web UI、Android 应用、浏览器扩展

## 技术栈

| 层级 | 技术 |
|------|------|
| 后端 | Python, FastAPI, SQLite |
| AI | OpenAI API / 兼容接口 |
| Web 前端 | HTML/CSS/JS, Vue 3, Markdown-it |
| 移动应用 | Flutter, Dart |
| 浏览器扩展 | Chrome Extension (Manifest V3) |

## 项目结构

```
knowledge-base/
├── backend/              # FastAPI 后端服务
│   ├── api.py            # API 路由
│   ├── config.py         # 配置管理
│   ├── llm.py            # LLM 集成（AI 标签、关联、质检）
│   ├── models.py         # 数据模型
│   └── main.py           # 入口文件
├── frontend/             # Web 前端
│   └── index.html        # 单文件 SPA
├── app/                  # Flutter 移动应用
│   └── lib/
│       ├── main.dart     # 应用入口
│       ├── screens/      # 页面组件
│       ├── services/     # API 服务
│       └── models/       # 数据模型
├── extension/            # Chrome 浏览器扩展
├── data/                 # SQLite 数据库
├── uploads/              # 用户上传文件
├── nginx.conf            # Nginx 反向代理配置
└── start.sh              # 服务启动脚本
```

## 快速开始

### 环境要求

- Python 3.11+
- Flutter 3.x（移动端开发）
- LLM API 密钥（OpenAI 或兼容接口）

### 后端启动

```bash
# 安装依赖
cd backend
pip install -r requirements.txt

# 配置环境变量
export LLM_API_KEY="your-api-key"
export LLM_BASE_URL="https://api.openai.com/v1"  # 或兼容接口
export LLM_MODEL="gpt-4"

# 启动服务（AI 后台任务会自动运行）
python main.py
```

### Web 前端

直接在浏览器中打开 `frontend/index.html`，或使用 nginx 配置：

```bash
cp nginx.conf /etc/nginx/sites-available/knowledge-base
sudo ln -s /etc/nginx/sites-available/knowledge-base /etc/nginx/sites-enabled/
sudo nginx -t && sudo nginx -s reload
```

### 移动应用

```bash
cd app
flutter pub get
flutter run
```

首次启动时，在设置页面配置服务器地址。

### 浏览器扩展

1. 打开 Chrome → 扩展程序 → 加载已解压的扩展程序
2. 选择 `extension/` 目录

## 环境变量

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `LLM_API_KEY` | LLM API 密钥（必填） | 空 |
| `LLM_BASE_URL` | LLM API 地址 | `https://api.openai.com/v1` |
| `LLM_MODEL` | LLM 模型名称 | `gpt-4` |
| `WIKI_API_TOKEN` | API 访问令牌（留空则不启用认证） | 空 |
| `RAG_MAX_NOTES` | RAG 最大笔记数 | `5` |
| `RAG_MAX_CHARS` | 每篇笔记最大字符数 | `8000` |

## AI 自动化流程

```
用户写笔记 → AI 自动打标签 → AI 建立关联 → 后台质检 → 图谱更新
     ↓              ↓              ↓            ↓           ↓
   存入数据库    标签写入      wikilink生成   断链修复    力导向图
```

所有操作由后台脚本自动完成，用户无需任何额外操作。

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

## 构建 APK

APK 通过 GitHub Actions 自动构建。推送到 `main` 分支后会自动：
1. 编译 Release APK
2. 上传到 Artifacts
3. 创建 Release（带 APK 附件）

从 [Releases](../../releases) 下载最新版本。

## 开发指南

详见 [DEV.md](DEV.md)

## License

MIT
