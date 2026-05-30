# Synapse

**An AI-powered personal knowledge management system.** Write your notes, and let AI handle the rest — auto-tagging, auto-linking, auto-quality checks, and auto-graph building. Zero manual intervention.

[中文文档](README.zh-CN.md)

![License](https://img.shields.io/badge/license-MIT-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![Python](https://img.shields.io/badge/Python-3.11+-green)
![FastAPI](https://img.shields.io/badge/FastAPI-0.100+-009688)

## What is Synapse?

Synapse is a self-hosted knowledge base that uses AI to automatically organize your notes. Unlike traditional note-taking apps where you manually tag, categorize, and link notes, Synapse does all of this in the background — you just write.

**Core philosophy: Zero-touch knowledge management.**

## Features

- ✍️ **Write & Forget** — AI automatically tags, categorizes, and links your notes
- 🔗 **Auto-linking** — AI discovers connections between notes and creates `[[wikilinks]]`
- 🏷️ **Smart Tags** — Semantic auto-tagging based on content, no manual selection needed
- 🏥 **Health Checks** — Automatic detection of broken links, orphan notes, and content issues
- 🕸️ **Knowledge Graph** — Interactive force-directed graph visualization of note connections
- 🔍 **Full-text Search** — Search across all notes with Chinese support
- 🌙 **Dark Mode** — Light/dark theme toggle
- 📱 **Multi-platform** — Web UI, Android app, Chrome extension

## How it Works

```
You write → AI tags → AI links → Background QA → Graph updates
    ↓           ↓           ↓           ↓            ↓
  Database    Tags DB    Wikilinks    Fixes       Force graph
```

All operations run automatically in the background. No buttons to click, no actions to take.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | Python, FastAPI, SQLite |
| AI | OpenAI API / compatible endpoints |
| Web Frontend | HTML/CSS/JS, Vue 3, Markdown-it |
| Mobile App | Flutter, Dart |
| Browser Extension | Chrome Extension (Manifest V3) |

## Quick Start

### Requirements

- Python 3.11+
- Flutter 3.x (for mobile app)
- LLM API key (OpenAI or compatible)

### Backend

```bash
cd backend
pip install -r requirements.txt

# Configure
export LLM_API_KEY="your-api-key"
export LLM_BASE_URL="https://api.openai.com/v1"
export LLM_MODEL="gpt-4"

# Start (AI background tasks run automatically)
python main.py
```

### Web Frontend

Open `frontend/index.html` in a browser, or deploy with nginx using the provided config.

### Mobile App

```bash
cd app
flutter pub get
flutter run
```

Configure the server URL in Settings on first launch.

### Browser Extension

1. Chrome → Extensions → Load unpacked
2. Select the `extension/` directory

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `LLM_API_KEY` | LLM API key (required) | — |
| `LLM_BASE_URL` | LLM API endpoint | `https://api.openai.com/v1` |
| `LLM_MODEL` | LLM model name | `gpt-4` |
| `WIKI_API_TOKEN` | API auth token (empty = no auth) | — |
| `RAG_MAX_NOTES` | Max notes for RAG context | `5` |
| `RAG_MAX_CHARS` | Max chars per note for RAG | `8000` |

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/notes` | List notes (`?search=`, `?tag=`) |
| GET | `/api/notes/:id` | Note detail |
| GET | `/api/notes/:id/relations` | Note relations |
| GET | `/api/tags` | List all tags |
| GET | `/api/graph` | Graph data (nodes + edges) |
| POST | `/api/ai/lint` | Run AI health check |
| POST | `/api/ai/chat` | AI chat |
| POST | `/api/ai/auto-tag` | AI auto-tagging |
| POST | `/api/upload` | Upload file |

## Building

APKs are built automatically via GitHub Actions on every push to `main`. Download from [Releases](../../releases).

## Development

See [DEV.md](DEV.md) for development guidelines.

## License

MIT
