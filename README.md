# Knowledge Base

A personal knowledge management system with web, mobile, and browser extension clients.

## Features

- **Note Management** — Create, edit, and organize notes with Markdown support
- **Tags** — Categorize notes with tags for easy filtering
- **Search** — Full-text search across all notes
- **Knowledge Graph** — Interactive force-directed graph visualization of note connections
- **Wikilinks** — Link notes together with `[[wiki-style]]` syntax
- **Health Check** — AI-powered lint for broken links, orphan notes, and content issues
- **Dark Mode** — Light/dark theme toggle
- **Multi-platform** — Web UI, Android app, browser extension

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | Python, FastAPI, SQLite |
| Web Frontend | Vue 3, Markdown-it |
| Mobile App | Flutter, Dart |
| Browser Extension | Chrome Extension (Manifest V3) |

## Project Structure

```
├── backend/          # FastAPI server
├── frontend/         # Web frontend (Vue 3)
├── app/              # Flutter mobile app
├── extension/        # Chrome browser extension
├── data/             # SQLite database
├── uploads/          # User uploads
├── nginx.conf        # Nginx reverse proxy config
└── start.sh          # Server startup script
```

## Getting Started

### Backend

```bash
cd backend
pip install -r requirements.txt
python main.py
```

The API server runs at `http://localhost:8000` by default.

### Web Frontend

Open `frontend/index.html` in a browser, or serve with nginx using the provided config.

### Mobile App

```bash
cd app
flutter pub get
flutter run
```

On first launch, configure the server URL in Settings.

### Browser Extension

1. Open Chrome → Extensions → Load unpacked
2. Select the `extension/` directory

## API

The backend exposes a REST API:

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/notes` | List notes (supports `?search=` and `?tag=`) |
| GET | `/api/notes/:id` | Get note detail |
| GET | `/api/notes/:id/relations` | Get note relations |
| GET | `/api/tags` | List all tags |
| GET | `/api/graph` | Get graph data (nodes + edges) |
| POST | `/api/ai/lint` | Run AI health check |

## Building the Android APK

APKs are built automatically via GitHub Actions on every push to `main`. Download the latest from [Releases](../../releases).

## License

Private project.
