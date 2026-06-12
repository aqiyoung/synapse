"""FastAPI 路由"""
import asyncio
import hmac
import logging
import os
import re
import time
import uuid
import zipfile
import io
from datetime import datetime, timezone, timedelta
from typing import List, Optional

from fastapi import FastAPI, Depends, HTTPException, Query, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse, Response, JSONResponse
from sqlalchemy.orm import Session
from pydantic import BaseModel

logger = logging.getLogger(__name__)

from models import Tag, note_tags, Note, Folder, ReadingStats, Notification, TagFolderRule
from crud import (
    get_db, create_note, get_note, get_note_by_slug, list_notes,
    update_note, delete_note, list_tags, get_or_create_tag,
    restore_note, permanent_delete_note, list_deleted_notes,
    create_folder, list_folders, update_folder, delete_folder, get_folder_notes,
    record_read, get_reading_stats, get_overall_stats,
    create_notification, list_notifications, mark_read, mark_all_read,
)
from config import API_TOKEN, ADMIN_PASSWORD

app = FastAPI(title="知识库 API", version="1.2.0")

# GZip 中间件：响应 ≥ 500B 才压缩，避免小的错误响应被额外压缩反而变大
app.add_middleware(GZipMiddleware, minimum_size=500)

# CORS - 从环境变量读取允许的源，默认只允许本地和自己的域名
_cors_origins = os.environ.get("CORS_ORIGINS", "http://localhost,http://127.0.0.1,https://wiki.threel.site").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in _cors_origins],
    allow_methods=["*"],
    allow_headers=["*"],
)

# 上传目录
UPLOAD_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)


# ===== 工具函数 =====

def _make_snippet(content, keyword, max_len=150):
    """生成搜索高亮摘要"""
    if not content:
        return ""
    idx = content.lower().find(keyword.lower())
    if idx < 0:
        snippet = content[:max_len]
    else:
        start = max(0, idx - 40)
        end = min(len(content), idx + len(keyword) + max_len - 40)
        snippet = content[start:end]
        if start > 0:
            snippet = "..." + snippet
        if end < len(content):
            snippet = snippet + "..."
    # 转义 HTML 特殊字符，防止 XSS
    snippet = snippet.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return snippet


def _fts_search(db: Session, query_text: str, limit: int = 20, title_only: bool = False) -> list[int]:
    """FTS5 全文搜索，返回笔记 ID 列表。失败时回退到 LIKE。"""
    from sqlalchemy import text as sa_text

    safe_q = re.sub(r'[^\w\s一-鿿]', '', query_text)
    terms = safe_q.strip().split()
    if not terms:
        return []
    match_expr = '"' + '" AND "'.join(terms) + '"'

    if title_only:
        fts_sql = sa_text("""
            SELECT rowid FROM note_search
            WHERE title MATCH :q AND rowid IN (SELECT id FROM notes WHERE deleted_at IS NULL)
            ORDER BY rank LIMIT :limit
        """)
    else:
        fts_sql = sa_text("""
            SELECT rowid FROM note_search
            WHERE note_search MATCH :q AND rowid IN (SELECT id FROM notes WHERE deleted_at IS NULL)
            ORDER BY rank LIMIT :limit
        """)

    try:
        rows = db.execute(fts_sql, {"q": match_expr, "limit": limit}).fetchall()
        fts_results = [r[0] for r in rows]
        # 如果FTS5返回结果，使用FTS5结果
        if fts_results:
            return fts_results
        # FTS5返回空时，回退到LIKE搜索（支持中文分词）
        _, notes_list = list_notes(db, keyword=query_text, limit=limit, title_only=title_only)
        return [n.id for n in notes_list]
    except Exception:
        # FTS5 失败时回退到 LIKE
        _, notes_list = list_notes(db, keyword=query_text, limit=limit, title_only=title_only)
        return [n.id for n in notes_list]


def _find_orphan_notes(db: Session, notes: list) -> list:
    """找出孤立笔记：无 outgoing wikilink、无 incoming 引用、无共享标签

    优化：每条笔记只跑一次 regex，同时构建 referenced 集合。
    """
    referenced = set()
    for n in notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                referenced.add(m.group(1))

    # 共享标签判定
    tag_note_map: dict[str, set] = {}
    for n in notes:
        for t in (n.tags or []):
            tag_note_map.setdefault(t.name, set()).add(n.id)
    shared_tag_notes = set()
    for _tag, note_ids in tag_note_map.items():
        if len(note_ids) > 1:
            shared_tag_notes.update(note_ids)

    orphans = []
    for n in notes:
        has_outgoing = bool(n.content and re.search(r'\[\[([^\]]+)\]\]', n.content))
        has_incoming = n.title in referenced
        has_shared_tag = n.id in shared_tag_notes
        if not has_outgoing and not has_incoming and not has_shared_tag:
            orphans.append(n)
    return orphans


# 公开接口不需要认证的路径
_PUBLIC_PATHS = {"/api/health", "/api/stats", "/api/update/check", "/api/update/download", "/api/admin/verify"}

# {title: id} 全表映射缓存，30 秒 TTL。graph/relations 复用。
_TITLE_MAP_CACHE: tuple[dict, float] | None = None

# 标签列表 60 秒 TTL 缓存
_TAGS_CACHE: tuple[list, float] | None = None


@app.middleware("http")
async def auth_middleware(request, call_next):
    """认证中间件：未配置 token 时放行所有请求"""
    if not API_TOKEN:
        return await call_next(request)
    # 公开接口放行
    if request.url.path in _PUBLIC_PATHS:
        return await call_next(request)
    # 其他接口需要认证
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != API_TOKEN:
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=401, content={"detail": "未认证，请在请求头中提供 Authorization: Bearer <token>"})
    return await call_next(request)


# ===== 数据模型 =====

class NoteCreate(BaseModel):
    title: str = "无标题"
    content: str = ""
    tags: List[str] = []
    source_created_at: Optional[str] = None

class NoteUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    tags: Optional[List[str]] = None



# ===== AI 请求模型 =====

class AIAutoTagRequest(BaseModel):
    title: str
    content: str

class SmartIngestRequest(BaseModel):
    note_id: int


def _build_title_map(db: Session) -> dict:
    """构建 {title: id} 映射，供 graph/relations 复用。
    使用 30 秒 TTL 缓存，避免每次请求全表扫。"""
    global _TITLE_MAP_CACHE
    now = time.monotonic()
    if _TITLE_MAP_CACHE and now - _TITLE_MAP_CACHE[1] < 30:
        return _TITLE_MAP_CACHE[0]
    rows = db.query(Note.id, Note.title).filter(Note.deleted_at.is_(None)).all()
    title_map = {row.title: row.id for row in rows}
    _TITLE_MAP_CACHE = (title_map, now)
    return title_map


# ===== 笔记 API =====

@app.get("/api/notes")
def api_list_notes(
    skip: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    tag: Optional[str] = None,
    keyword: Optional[str] = None,
    fields: Optional[str] = Query(None, description="逗号分隔的字段名子集，如 'summary,id,title,tags'"),
    db: Session = Depends(get_db),
):
    """列出笔记（fields 参数允许只取必要字段，节省 90%+ 响应体积）"""
    total, notes = list_notes(db, skip=skip, limit=limit, tag=tag, keyword=keyword)
    items = [n.to_dict() for n in notes]
    if fields:
        wanted = {f.strip() for f in fields.split(",") if f.strip()}
        items = [{k: v for k, v in n.items() if k in wanted} for n in items]
    return {
        "total": total,
        "notes": items,
    }



@app.get("/api/notes/by-slug/{slug}")
def api_get_note_by_slug(slug: str, db: Session = Depends(get_db)):
    """通过 slug 获取笔记"""
    note = get_note_by_slug(db, slug)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")
    return note.to_dict()

@app.get("/api/notes/{note_id}")
def api_get_note(note_id: int, db: Session = Depends(get_db)):
    """获取单条笔记"""
    note = get_note(db, note_id)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")
    return note.to_dict()


@app.patch("/api/notes/{note_id}/pin")
def api_toggle_pin(note_id: int, db: Session = Depends(get_db)):
    """切换笔记置顶状态"""
    note = get_note(db, note_id)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")
    note.is_pinned = not note.is_pinned
    note.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))
    db.commit()
    db.refresh(note)
    return {"ok": True, "is_pinned": note.is_pinned}


@app.post("/api/notes")
async def api_create_note(data: NoteCreate, db: Session = Depends(get_db)):
    """创建笔记"""
    src = None
    if data.source_created_at:
        try:
            src = datetime.fromisoformat(data.source_created_at)
        except (ValueError, TypeError):
            logger.warning(f"无效的 source_created_at 格式: {data.source_created_at}")
    note = create_note(db, title=data.title, content=data.content, tag_names=data.tags, source_created_at=src)
    if data.content and len(data.content) > 50:
        asyncio.create_task(_auto_analyze_note(note.id))
    _invalidate_tags_cache()
    return note.to_dict()


@app.put("/api/notes/{note_id}")
async def api_update_note(note_id: int, data: NoteUpdate, db: Session = Depends(get_db)):
    """更新笔记"""
    note = update_note(
        db, note_id,
        title=data.title,
        content=data.content,
        tag_names=data.tags,
    )
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")
    if data.content and len(data.content) > 50:
        asyncio.create_task(_auto_analyze_note(note_id))
    _invalidate_tags_cache()
    return note.to_dict()


@app.delete("/api/notes/{note_id}")
def api_delete_note(note_id: int, db: Session = Depends(get_db)):
    """软删除笔记"""
    if not delete_note(db, note_id):
        raise HTTPException(status_code=404, detail="笔记不存在")
    return {"ok": True, "soft_deleted": True}


# ===== 回收站 API =====

@app.get("/api/trash")
def api_list_trash(
    skip: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """列出回收站中的笔记"""
    total, notes = list_deleted_notes(db, skip=skip, limit=limit)
    return {
        "total": total,
        "notes": [n.to_dict() for n in notes],
    }


@app.post("/api/notes/{note_id}/restore")
def api_restore_note(note_id: int, db: Session = Depends(get_db)):
    """恢复软删除的笔记"""
    note = restore_note(db, note_id)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不在回收站中")
    return note.to_dict()


@app.delete("/api/notes/{note_id}/permanent")
def api_permanent_delete_note(note_id: int, db: Session = Depends(get_db)):
    """永久删除笔记"""
    if not permanent_delete_note(db, note_id):
        raise HTTPException(status_code=404, detail="笔记不存在")
    return {"ok": True, "permanent": True}


# ===== 标签 API =====

@app.get("/api/tags")
def api_list_tags(db: Session = Depends(get_db)):
    """列出所有标签（60 秒 TTL 缓存）"""
    global _TAGS_CACHE
    now = time.monotonic()
    if _TAGS_CACHE and now - _TAGS_CACHE[1] < 60:
        return _TAGS_CACHE[0]
    tags = list_tags(db)
    result = [t.to_dict() for t in tags]
    _TAGS_CACHE = (result, now)
    return result


def _invalidate_tags_cache():
    global _TAGS_CACHE
    _TAGS_CACHE = None


# ===== 搜索 API =====

@app.get("/api/search")
def api_search(
    q: str = Query(..., min_length=1),
    limit: int = Query(20, ge=1, le=100),
    filter: Optional[str] = Query(None, regex="^(title|content)$"),
    db: Session = Depends(get_db),
):
    """全文搜索，使用 FTS5"""
    ids = _fts_search(db, q, limit=limit, title_only=(filter == "title"))
    if not ids:
        return {"query": q, "total": 0, "results": []}

    fts_notes = db.query(Note).filter(Note.id.in_(ids), Note.deleted_at.is_(None)).all()
    note_map = {n.id: n for n in fts_notes}
    ordered = [note_map[i] for i in ids if i in note_map]

    results = []
    for n in ordered:
        d = n.to_dict()
        d["snippet"] = _make_snippet(n.content, q)
        results.append(d)

    return {
        "query": q,
        "total": len(results),
        "results": results,
    }


# ===== frontmatter 处理工具 =====

def parse_frontmatter(content: str):
    """
    解析 YAML frontmatter，返回 (tag_names, body_without_frontmatter)。
    如果不是 frontmatter 格式，返回 ([], 原始内容)。
    """
    if not content.startswith("---"):
        return [], content

    end = content.find("---", 3)
    if end < 0:
        return [], content

    fm = content[3:end].strip()
    body = content[end + 3:].lstrip("\n")

    tag_names = []
    in_tags = False
    for line in fm.split("\n"):
        stripped = line.strip()
        if stripped.lower().startswith("tags:"):
            val = stripped.split(":", 1)[1].strip()
            if val.startswith("["):
                # tags: [tag1, tag2]
                tag_names = [t.strip().strip('"').strip("'")
                             for t in val.strip("[]").split(",") if t.strip()]
            elif val == "" or val == "[]":
                # tags:\n  - tag1\n  - tag2
                in_tags = True
                continue
            in_tags = False
        elif in_tags and stripped.startswith("- "):
            tag_names.append(stripped[2:].strip().strip('"').strip("'"))
        elif in_tags and not stripped.startswith("- "):
            in_tags = False

    return tag_names, body


# ===== 批量导入 API =====

@app.post("/api/notes/import")
async def api_import_notes(
    files: List[UploadFile] = File(...),
    db: Session = Depends(get_db),
):
    """批量导入 Markdown 文件"""
    results = {"success": 0, "skipped": 0, "errors": [], "notes": []}

    for file in files:
        if not file.filename or not file.filename.endswith(".md"):
            results["skipped"] += 1
            continue
        try:
            content = (await file.read()).decode("utf-8")
            if not content.strip():
                results["skipped"] += 1
                continue

            # 文件名（去掉 .md）作为标题
            title = os.path.splitext(file.filename)[0]

            # 解析 frontmatter：提取标签 + 剥离元数据
            tag_names, body = parse_frontmatter(content)

            note = create_note(db, title=title, content=body, tag_names=tag_names)
            results["success"] += 1
            results["notes"].append({"id": note.id, "title": note.title})
        except Exception as e:
            results["errors"].append({"file": file.filename, "error": str(e)})

    return results


# ===== 文件上传 API =====

# 允许上传的文件扩展名
_ALLOWED_EXTENSIONS = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg', '.ico',  # 图片
    '.pdf', '.md', '.txt', '.csv', '.json', '.yaml', '.yml',     # 文档
    '.zip', '.tar', '.gz', '.bz2', '.xz', '.7z',                 # 压缩包
    '.mp3', '.ogg', '.wav', '.mp4', '.webm',                      # 媒体
    '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',           # Office
}
_MAX_UPLOAD_SIZE = 50 * 1024 * 1024  # 50MB


@app.post("/api/upload")
def api_upload_file(file: UploadFile = File(...)):
    """上传文件（限制类型和大小）"""
    # 检查文件类型
    ext = os.path.splitext(file.filename)[1].lower() if file.filename else ""
    if ext not in _ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"不支持的文件类型: {ext}。允许的类型: {', '.join(sorted(_ALLOWED_EXTENSIONS))}"
        )

    # 生成唯一文件名（保留原始扩展名）
    filename = f"{uuid.uuid4().hex}{ext}"
    filepath = os.path.join(UPLOAD_DIR, filename)

    # 写入文件并检查大小
    size = 0
    try:
        with open(filepath, "wb") as f:
            while True:
                chunk = file.file.read(8192)
                if not chunk:
                    break
                size += len(chunk)
                if size > _MAX_UPLOAD_SIZE:
                    os.remove(filepath)
                    raise HTTPException(status_code=413, detail=f"文件超过最大限制 {_MAX_UPLOAD_SIZE // 1024 // 1024}MB")
                f.write(chunk)
    except HTTPException:
        raise
    except Exception as e:
        # 写入过程中出异常（如磁盘满），清理残留文件
        if os.path.exists(filepath):
            os.remove(filepath)
        raise HTTPException(status_code=500, detail=f"文件上传失败: {str(e)}")

    return {
        "filename": filename,
        "original_name": file.filename,
        "size": size,
        "url": f"/uploads/{filename}",
    }


# ===== 导出 API =====

@app.get("/api/notes/{note_id}/export")
def api_export_note(note_id: int, db: Session = Depends(get_db)):
    """导出单条笔记为 Markdown 文件"""
    note = get_note(db, note_id)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")

    # 构建 Markdown 内容
    tag_names = [t.name for t in note.tags]
    lines = []
    lines.append(f"# {note.title}")
    lines.append("")
    if tag_names:
        lines.append(f"标签：{' '.join(f'#{t}' for t in tag_names)}")
        lines.append("")
    lines.append(f"创建时间：{note.created_at}")
    lines.append(f"更新时间：{note.updated_at}")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append(note.content)

    md_content = "\n".join(lines)
    from urllib.parse import quote
    filename = f"{note.title}.md"

    return Response(
        content=md_content.encode("utf-8"),
        media_type="text/markdown; charset=utf-8",
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}"
        }
    )


@app.get("/api/notes/export-all")
def api_export_all_notes(
    tag: Optional[str] = None,
    db: Session = Depends(get_db),
):
    """导出所有笔记为 ZIP 文件"""
    total, notes = list_notes(db, skip=0, limit=10000, tag=tag)
    if not total:
        raise HTTPException(status_code=400, detail="没有可导出的笔记")

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for note in notes:
            tag_names = [t.name for t in note.tags]
            lines = []
            lines.append(f"# {note.title}")
            lines.append("")
            if tag_names:
                lines.append(f"标签：{' '.join(f'#{t}' for t in tag_names)}")
                lines.append("")
            lines.append(f"创建时间：{note.created_at}")
            lines.append(f"更新时间：{note.updated_at}")
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append(note.content)
            md_content = "\n".join(lines)

            # 安全文件名，添加 ID 前缀防止同名覆盖
            safe_name = note.title.replace("/", "_").replace("\\", "_")
            filename = f"{note.id}_{safe_name}.md"
            zf.writestr(filename, md_content.encode("utf-8"))

    buf.seek(0)
    return Response(
        content=buf.getvalue(),
        media_type="application/zip",
        headers={
            "Content-Disposition": "attachment; filename=knowledge-export.zip"
        }
    )


# ===== 静态文件 =====

@app.get("/uploads/{filename}")
def api_get_upload(filename: str):
    """获取上传的文件"""
    filepath = os.path.join(UPLOAD_DIR, filename)
    # 防止路径穿越
    if not os.path.realpath(filepath).startswith(os.path.realpath(UPLOAD_DIR)):
        raise HTTPException(status_code=403, detail="禁止访问")
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail="文件不存在")
    return FileResponse(filepath)


# ===== 健康检查 =====

@app.get("/api/health")
def api_health(db: Session = Depends(get_db)):
    try:
        from sqlalchemy import text
        db.execute(text("SELECT 1"))
        db_status = "ok"
    except Exception as e:
        db_status = str(e)
    return {"status": "ok" if db_status == "ok" else "error", "db": db_status, "version": "1.0.0"}


class AdminVerifyRequest(BaseModel):
    password: str


@app.post("/api/admin/verify")
def admin_verify(req: AdminVerifyRequest):
    """验证管理员密码（服务端校验，密码不暴露在客户端）"""
    if not ADMIN_PASSWORD:
        raise HTTPException(500, "管理员密码未配置")
    if hmac.compare_digest(req.password, ADMIN_PASSWORD):
        return {"ok": True}
    raise HTTPException(401, "密码错误")


# ===== 阅读统计 API =====

@app.get("/api/stats")
def api_stats(db: Session = Depends(get_db)):
    """全局阅读统计"""
    return get_overall_stats(db)

@app.get("/api/stats/note/{note_id}")
def api_note_stats(note_id: int, db: Session = Depends(get_db)):
    """单篇笔记阅读统计"""
    stat = get_reading_stats(db, note_id)
    if not stat:
        return {"read_count": 0, "total_read_time": 0, "last_read_at": None, "first_read_at": None}
    return {
        "read_count": stat.read_count,
        "total_read_time": stat.total_read_time,
        "last_read_at": stat.last_read_at.isoformat() if stat.last_read_at else None,
        "first_read_at": stat.first_read_at.isoformat() if stat.first_read_at else None,
    }

@app.post("/api/stats/note/{note_id}/read")
def api_record_read(note_id: int, db: Session = Depends(get_db)):
    """记录一次阅读"""
    note = get_note(db, note_id)
    if not note:
        raise HTTPException(404, "笔记不存在")
    record_read(db, note_id)
    return {"ok": True}


# ===== 分类文件夹 API =====

class FolderCreate(BaseModel):
    name: str
    icon: str = "folder"
    color: str = "#c96442"
    parent_id: Optional[int] = None

class FolderUpdate(BaseModel):
    name: Optional[str] = None
    icon: Optional[str] = None
    color: Optional[str] = None
    parent_id: Optional[int] = None
    sort_order: Optional[int] = None

@app.get("/api/folders")
def api_list_folders(db: Session = Depends(get_db)):
    """列出所有分类"""
    folders = list_folders(db)
    return [f.to_dict() for f in folders]

@app.post("/api/folders")
def api_create_folder(data: FolderCreate, db: Session = Depends(get_db)):
    """创建分类"""
    folder = create_folder(db, name=data.name, icon=data.icon, color=data.color, parent_id=data.parent_id)
    return folder.to_dict()

@app.put("/api/folders/{folder_id}")
def api_update_folder(folder_id: int, data: FolderUpdate, db: Session = Depends(get_db)):
    """更新分类"""
    kwargs = {k: v for k, v in data.dict().items() if v is not None}
    folder = update_folder(db, folder_id, **kwargs)
    if not folder:
        raise HTTPException(404, "分类不存在")
    return folder.to_dict()

@app.delete("/api/folders/{folder_id}")
def api_delete_folder(folder_id: int, db: Session = Depends(get_db)):
    """删除分类"""
    folder = delete_folder(db, folder_id)
    if not folder:
        raise HTTPException(404, "分类不存在")
    return {"ok": True, "deleted": folder.name}

@app.get("/api/folders/{folder_id}/notes")
def api_folder_notes(
    folder_id: int,
    skip: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """获取分类下的笔记"""
    total, notes = get_folder_notes(db, folder_id, skip=skip, limit=limit)
    return {"total": total, "notes": [n.to_dict() for n in notes]}

@app.put("/api/notes/{note_id}/folder")
def api_set_note_folder(note_id: int, folder_id: Optional[int] = None, db: Session = Depends(get_db)):
    """设置笔记分类"""
    note = get_note(db, note_id)
    if not note:
        raise HTTPException(404, "笔记不存在")
    note.folder_id = folder_id
    db.commit()
    db.refresh(note)
    return {"ok": True, "folder_id": folder_id}


# ===== 通知 API =====

@app.get("/api/notifications")
def api_list_notifications(
    limit: int = Query(50, ge=1, le=200),
    unread_only: bool = Query(False),
    db: Session = Depends(get_db),
):
    """获取通知列表"""
    notifs = list_notifications(db, limit=limit, unread_only=unread_only)
    return [n.to_dict() for n in notifs]

@app.get("/api/notifications/unread-count")
def api_unread_count(db: Session = Depends(get_db)):
    """未读通知数"""
    count = db.query(Notification).filter(Notification.is_read == False).count()
    return {"count": count}

@app.post("/api/notifications/{notif_id}/read")
def api_mark_read(notif_id: int, db: Session = Depends(get_db)):
    """标记已读"""
    mark_read(db, notif_id)
    return {"ok": True}

@app.post("/api/notifications/read-all")
def api_mark_all_read(db: Session = Depends(get_db)):
    """全部已读"""
    mark_all_read(db)
    return {"ok": True}

@app.delete("/api/notifications/{notif_id}")
def api_delete_notification(notif_id: int, db: Session = Depends(get_db)):
    """删除通知"""
    notif = db.query(Notification).filter(Notification.id == notif_id).first()
    if not notif:
        raise HTTPException(404, "通知不存在")
    db.delete(notif)
    db.commit()
    return {"ok": True}


# ===== AI API =====

@app.post("/api/ai/auto-tag")
async def ai_auto_tag(req: AIAutoTagRequest):
    """算法自动标签和摘要"""
    tags, summary = _algo_analyze(req.title, req.content)
    return {"tags": tags[:5], "summary": summary[:200]}


@app.get("/api/notes/{note_id}/relations")
def api_note_relations(note_id: int, db: Session = Depends(get_db)):
    """返回笔记的 wikilink 关系： outgoing（本文链接到的笔记）和 incoming（链接到本文的笔记）"""
    import re

    note = get_note(db, note_id)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")

    # 使用 30 秒缓存的 title 映射，避免每次请求全表扫
    title_to_id = _build_title_map(db)

    # outgoing: 从本文内容中提取 [[wikilink]]
    outgoing = []
    if note.content:
        for m in re.finditer(r'\[\[([^\]]+)\]\]', note.content):
            target_title = m.group(1)
            target_id = title_to_id.get(target_title)
            if target_id and target_id != note_id:
                outgoing.append({"id": target_id, "title": target_title})

    # incoming: 用 SQL LIKE 查包含 [[本文标题]] 的笔记（O(log N)）
    # 转义 LIKE 通配符
    escaped = note.title.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
    pattern = f"%[[{escaped}]]%"
    rows = (
        db.query(Note.id, Note.title)
        .filter(Note.deleted_at.is_(None), Note.id != note_id, Note.content.like(pattern))
        .all()
    )
    incoming = [{"id": r.id, "title": r.title} for r in rows]

    return {
        "note_id": note_id,
        "title": note.title,
        "outgoing": outgoing,
        "incoming": incoming,
    }


@app.get("/api/graph")
def api_graph(db: Session = Depends(get_db)):
    """返回知识图谱数据（节点 + 边）"""
    from sqlalchemy.orm import selectinload

    # 一次性拉取所有 id/title（O(N)）
    notes = (
        db.query(Note)
        .options(selectinload(Note.tags))
        .filter(Note.deleted_at.is_(None))
        .all()
    )
    title_map = {n.title: n.id for n in notes}

    nodes = []
    for n in notes:
        nodes.append({
            "id": n.id,
            "title": n.title,
            "tags": [t.name for t in n.tags],
        })

    # 从内容中提取 [[wikilink]] 关系
    import re
    edges = []
    edge_set = set()
    for n in notes:
        if not n.content:
            continue
        for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
            target_title = m.group(1)
            target_id = title_map.get(target_title)
            if target_id and target_id != n.id:
                key = (n.id, target_id)
                if key not in edge_set:
                    edge_set.add(key)
                    edges.append({
                        "source": n.id,
                        "target": target_id,
                    })

    return {
        "nodes": nodes,
        "edges": edges,
    }




# ===== 标签管理 API =====

class TagUpdate(BaseModel):
    name: Optional[str] = None
    color: Optional[str] = None

@app.put("/api/tags/{tag_id}")
def api_update_tag(tag_id: int, data: TagUpdate, db: Session = Depends(get_db)):
    """更新标签"""
    from models import Tag
    tag = db.query(Tag).filter(Tag.id == tag_id).first()
    if not tag:
        raise HTTPException(status_code=404, detail="标签不存在")
    
    if data.name is not None:
        # 检查名称是否已存在
        existing = db.query(Tag).filter(Tag.name == data.name, Tag.id != tag_id).first()
        if existing:
            raise HTTPException(status_code=400, detail="标签名已存在")
        tag.name = data.name
    
    if data.color is not None:
        tag.color = data.color
    
    db.commit()
    db.refresh(tag)
    _invalidate_tags_cache()
    return tag.to_dict()

@app.delete("/api/tags/{tag_id}")
def api_delete_tag(tag_id: int, db: Session = Depends(get_db)):
    """删除标签"""
    from models import Tag
    tag = db.query(Tag).filter(Tag.id == tag_id).first()
    if not tag:
        raise HTTPException(status_code=404, detail="标签不存在")
    
    # 检查是否有笔记使用此标签
    if tag.notes:
        raise HTTPException(status_code=400, detail=f"标签 '{tag.name}' 正在被 {len(tag.notes)} 篇笔记使用，无法删除")
    
    db.delete(tag)
    db.commit()
    _invalidate_tags_cache()
    return {"ok": True, "deleted": tag.name}


def _clean_text(text: str) -> str:
    """清理 Markdown / HTML，返回纯文本"""
    import re
    text = re.sub(r'<[^>]+>', '', text)
    text = re.sub(r'!?\[\[([^\]]+)\]\]', r'\1', text)
    text = re.sub(r'[#*`~>|_\-]{1,}', ' ', text)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text

def _extract_keywords(text: str, top_n: int = 5) -> list[str]:
    """从文本中提取高频关键词"""
    import re, math
    text = _clean_text(text)
    if not text:
        return []

    # 提取中文词组（2~4 字滑动窗口，去停用字）
    stop_chars = set('的了是在有和我就不也人一个上要会这中大下时为你而所如得以可')
    chinese_ngrams: dict[str, int] = {}
    chars = [c for c in text if '\u4e00' <= c <= '\u9fff']
    for n in range(2, 5):
        for i in range(len(chars) - n + 1):
            gram = ''.join(chars[i:i+n])
            # 跳过全停用字的组合
            if all(c in stop_chars for c in gram):
                continue
            chinese_ngrams[gram] = chinese_ngrams.get(gram, 0) + 1

    # 提取英文单词
    words: dict[str, int] = {}
    for w in re.findall(r'[a-zA-Z][a-zA-Z0-9\-]{1,}', text):
        w = w.lower()
        if len(w) >= 2:
            words[w] = words.get(w, 0) + 1

    scored = []
    for phrase, freq in chinese_ngrams.items():
        if freq >= 2:
            scored.append((phrase, freq * math.log(len(phrase) + 1)))
    for word, freq in words.items():
        if freq >= 2:
            scored.append((word, freq * math.log(len(word) + 1)))

    scored.sort(key=lambda x: -x[1])
    return [item[0] for item in scored[:top_n]]

def _algo_analyze(title: str, content: str) -> tuple[list[str], str]:
    """算法分析：提取关键词作为标签，取首段作为摘要"""
    tags = _extract_keywords(title + ' ' + content, top_n=5)
    clean = _clean_text(content)[:200]
    return tags, clean


# ===== 后台自动分析 =====

# 并发锁：防止同一笔记被多个后台任务同时分析
_auto_analyze_locks: dict[int, asyncio.Lock] = {}

async def _auto_analyze_note(note_id: int):
    """后台自动分析笔记：关键词标签 + 首段摘要（加锁防并发）"""
    import asyncio
    lock = _auto_analyze_locks.setdefault(note_id, asyncio.Lock())
    async with lock:
        try:
            from crud import SessionLocal
            from models import Note, Tag
            db = SessionLocal()
            try:
                note = db.query(Note).filter(Note.id == note_id).first()
                if not note:
                    return

                tags, summary = _algo_analyze(note.title or '', note.content or '')

                if tags:
                    note.tags.clear()
                    for name in tags:
                        tag = db.query(Tag).filter(Tag.name == name).first()
                        if not tag:
                            tag = Tag(name=name)
                            db.add(tag)
                        note.tags.append(tag)

                    # 自动归类：根据标签匹配分类
                    rules = db.query(TagFolderRule).order_by(TagFolderRule.priority.desc()).all()
                    for rule in rules:
                        for tag_name in tags:
                            if rule.tag_name.lower() in tag_name.lower() or tag_name.lower() in rule.tag_name.lower():
                                folder = db.query(Folder).filter(Folder.id == rule.folder_id).first()
                                if folder:
                                    note.folder_id = folder.id
                                    logger.info(f"Auto-categorized note {note_id} to folder '{folder.name}' via tag '{tag_name}'")
                                    break

                if summary:
                    note.summary = summary

                db.commit()
                logger.info(f"Auto-analyzed note {note_id}: tags={tags}, summary={summary[:30]}...")
            finally:
                db.close()
        except Exception as e:
            logger.error(f"Auto-analyze failed for note {note_id}: {e}")
        finally:
            # 清理锁
            _auto_analyze_locks.pop(note_id, None)


@app.post("/api/ai/smart-ingest")
async def ai_smart_ingest(req: SmartIngestRequest, db: Session = Depends(get_db)):
    """智能摄入：算法分析笔记，生成标签、摘要"""
    note = get_note(db, req.note_id)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")

    tags, summary = _algo_analyze(note.title or '', note.content or '')

    if tags:
        note.tags.clear()
        for name in tags:
            tag = db.query(Tag).filter(Tag.name == name).first()
            if not tag:
                tag = Tag(name=name)
                db.add(tag)
            note.tags.append(tag)

    if summary:
        note.summary = summary

    note.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))
    db.commit()
    db.refresh(note)

    # 找标题包含相同关键词的笔记
    total, all_notes = list_notes(db, limit=500)
    related_notes = []
    keyword_set = set(t.lower() for t in tags if len(t) >= 2)
    for n in all_notes:
        if n.id == note.id:
            continue
        n_clean = _clean_text(n.title or '').lower()
        if any(kw in n_clean for kw in keyword_set):
            related_notes.append({"id": n.id, "title": n.title})
            if len(related_notes) >= 5:
                break

    return {
        "ok": True,
        "note_id": note.id,
        "tags": tags,
        "summary": summary,
        "entities": [],
        "concepts": [],
        "related_notes": related_notes,
    }


@app.get("/api/overview")
async def api_overview(db: Session = Depends(get_db)):
    """生成全局概览 - 借鉴 Karpathy Wiki 的 overview.md 概念
    
    分析所有笔记，生成知识库全景摘要：
    - 主要知识领域
    - 活跃标签
    - 孤立笔记（无交叉引用）
    - 知识图谱统计
    """
    total, notes = list_notes(db, limit=1000)
    tags = list_tags(db)

    # 统计标签使用
    tag_stats = []
    for t in tags:
        count = t.note_count_query(db)
        if count > 0:
            tag_stats.append({"name": t.name, "count": count, "color": t.color})
    tag_stats.sort(key=lambda x: x["count"], reverse=True)

    # 统计最近活跃
    recent_notes = sorted(notes, key=lambda n: n.source_created_at or n.created_at or datetime.min, reverse=True)[:10]

    # 孤立笔记
    orphan_notes = [{"id": n.id, "title": n.title} for n in _find_orphan_notes(db, notes)]

    return {
        "total_notes": total,
        "total_tags": len(tags),
        "top_tags": tag_stats[:15],
        "recent_notes": [{"id": n.id, "title": n.title, "created_at": n.created_at.isoformat() if n.created_at else "", "source_created_at": n.source_created_at.isoformat() if n.source_created_at else ""} for n in recent_notes],
        "orphan_notes": orphan_notes[:20],
        "orphan_count": len(orphan_notes),
    }


@app.post("/api/ai/overview")
async def ai_overview_generate(db: Session = Depends(get_db)):
    """生成全局概览 - 基于统计和标签聚类"""
    total, notes = list_notes(db, limit=1000)
    tags = list_tags(db)

    # 统计各标签的笔记数
    tag_counts = sorted(
        [(t.name, t.note_count_query(db)) for t in tags],
        key=lambda x: -x[1]
    )
    tag_counts = [(n, c) for n, c in tag_counts if c > 0]

    # 最近活跃笔记
    recent = sorted(notes, key=lambda n: n.updated_at or n.created_at, reverse=True)[:10]

    # 标签聚合：按标签归类笔记
    tag_notes: dict[str, list[str]] = {}
    for t in tags:
        count = t.note_count_query(db)
        if count > 0:
            tag_notes[t.name] = [n.title for n in t.notes[:10]]

    # 无标签笔记数
    no_tag_count = len([n for n in notes if not n.tags])

    return {
        "overview": {
            "total_notes": total,
            "total_tags": len(tag_counts),
            "no_tag_notes": no_tag_count,
            "top_tags": [{"name": n, "count": c} for n, c in tag_counts[:15]],
            "recent_notes": [n.title for n in recent],
            "tag_clusters": tag_notes,
        }
    }


@app.post("/api/ai/lint")
async def ai_lint(db: Session = Depends(get_db)):
    """Wiki 健康检查 - 借鉴 Karpathy Wiki 的 Lint 概念

    检查项目：
    1. 孤立笔记（无交叉引用且无共享标签）
    2. 断链（引用了不存在的笔记）
    3. 缺少标签的笔记
    4. 内容过短的笔记
    """
    total, notes = list_notes(db, limit=1000)
    tags = list_tags(db)
    all_titles = {n.title for n in notes}

    issues = []

    # 1. 孤立笔记（排除已标记的）
    orphan_tagged_ids = {
        nt.note_id for nt in db.query(note_tags).join(Tag).filter(Tag.name == "孤立").all()
    }
    orphans = [n for n in _find_orphan_notes(db, notes) if n.id not in orphan_tagged_ids]

    if orphans:
        issues.append({
            "type": "orphan",
            "severity": "warning",
            "message": f"发现 {len(orphans)} 篇孤立笔记（无交叉引用且无标签关联）",
            "notes": [{"id": n.id, "title": n.title} for n in orphans[:10]]
        })

    # 2. 断链
    broken_links = []
    for n in notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                target = m.group(1)
                if target not in all_titles:
                    broken_links.append({"from": n.title, "to": target})

    if broken_links:
        issues.append({
            "type": "broken_link",
            "severity": "error",
            "message": f"发现 {len(broken_links)} 个断链（引用了不存在的笔记）",
            "links": broken_links[:10]
        })

    # 3. 缺少标签
    no_tags = [n for n in notes if not n.tags]
    if no_tags:
        issues.append({
            "type": "no_tags",
            "severity": "info",
            "message": f"{len(no_tags)} 篇笔记没有标签",
            "notes": [{"id": n.id, "title": n.title} for n in no_tags[:10]]
        })

    # 4. 内容过短
    short_notes = [n for n in notes if len(n.content or "") < 50]
    if short_notes:
        issues.append({
            "type": "short_content",
            "severity": "info",
            "message": f"{len(short_notes)} 篇笔记内容过短（<50字）",
            "notes": [{"id": n.id, "title": n.title} for n in short_notes[:10]]
        })

    # 5. 统计
    referenced = set()
    for n in notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                referenced.add(m.group(1))

    stats = {
        "total_notes": total,
        "total_tags": len([t for t in tags if t.note_count_query(db) > 0]),
        "orphan_count": len(orphans),
        "broken_link_count": len(broken_links),
        "no_tag_count": len(no_tags),
        "short_note_count": len(short_notes),
        "link_density": round(len(referenced) / max(total, 1), 2),
    }

    return {"issues": issues, "stats": stats}


# ===== 健康检查修复 API =====

class LintFixRequest(BaseModel):
    """修复请求"""
    dry_run: bool = False  # 试运行模式，不实际修改


@app.post("/api/lint/fix/broken-links")
async def lint_fix_broken_links(req: LintFixRequest = None, db: Session = Depends(get_db)):
    if req is None:
        req = LintFixRequest()
    """清除断链：从笔记内容中移除引用了不存在的 [[wikilink]]"""
    import re

    total, notes = list_notes(db, limit=1000)
    all_titles = {n.title for n in notes}

    fixes = []
    for n in notes:
        if not n.content:
            continue
        broken = []
        for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
            if m.group(1) not in all_titles:
                broken.append(m.group(1))
        if broken:
            new_content = n.content
            for target in broken:
                new_content = re.sub(rf'\[\[{re.escape(target)}\]\]', target, new_content)
            if not req.dry_run:
                n.content = new_content
                n.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))
            fixes.append({
                "note_id": n.id,
                "title": n.title,
                "removed": broken,
            })

    if not req.dry_run:
        db.commit()

    return {
        "fixed_count": len(fixes),
        "fixes": fixes,
        "dry_run": req.dry_run,
    }


@app.post("/api/lint/fix/orphans")
async def lint_fix_orphans(req: LintFixRequest = None, db: Session = Depends(get_db)):
    if req is None:
        req = LintFixRequest()
    """修复孤立笔记：给孤立笔记添加 '孤立' 标签，方便用户批量处理"""
    total, notes = list_notes(db, limit=1000)
    orphans = _find_orphan_notes(db, notes)

    if not req.dry_run:
        orphan_tag = db.query(Tag).filter(Tag.name == "孤立").first()
        if not orphan_tag:
            orphan_tag = Tag(name="孤立", color="#8d9e8a")
            db.add(orphan_tag)
            db.flush()

    fixes = []
    for n in orphans:
        if not req.dry_run:
            if orphan_tag not in n.tags:
                n.tags.append(orphan_tag)
                n.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))
        fixes.append({"note_id": n.id, "title": n.title})

    if not req.dry_run:
        db.commit()

    return {
        "fixed_count": len(fixes),
        "fixes": fixes,
        "dry_run": req.dry_run,
    }


@app.post("/api/lint/fix/no-tags")
async def lint_fix_no_tags(req: LintFixRequest, db: Session = Depends(get_db)):
    """修复无标签笔记：给没有标签的笔记添加 '未分类' 标签"""
    total, notes = list_notes(db, limit=1000)
    no_tags = [n for n in notes if not n.tags]

    if not req.dry_run:
        uncategorized = db.query(Tag).filter(Tag.name == "未分类").first()
        if not uncategorized:
            uncategorized = Tag(name="未分类", color="#8d9e8a")
            db.add(uncategorized)
            db.flush()

    fixes = []
    for n in no_tags:
        if not req.dry_run:
            n.tags.append(uncategorized)
            n.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))
        fixes.append({"note_id": n.id, "title": n.title})

    if not req.dry_run:
        db.commit()

    return {
        "fixed_count": len(fixes),
        "fixes": fixes,
        "dry_run": req.dry_run,
    }


@app.post("/api/lint/fix/link-orphans")
async def lint_fix_link_orphans(req: LintFixRequest = None, db: Session = Depends(get_db)):
    """自动关联孤立笔记：使用 AI 分析内容，为孤立笔记添加 [[引用]]"""
    import re
    import llm

    if req is None:
        req = LintFixRequest()

    if not llm.is_enabled():
        raise HTTPException(status_code=400, detail="AI 未配置，请设置 LLM_API_KEY 环境变量")

    total, notes = list_notes(db, limit=1000)
    active_notes = [n for n in notes if n.deleted_at is None]

    # 找出孤立笔记
    referenced = set()
    for n in active_notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                referenced.add(m.group(1))

    orphans = []
    for n in active_notes:
        has_outgoing = n.content and re.search(r'\[\[([^\]]+)\]\]', n.content)
        has_incoming = n.title in referenced
        if not has_outgoing and not has_incoming:
            orphans.append(n)

    if not orphans:
        return {"fixed_count": 0, "fixes": [], "dry_run": req.dry_run}

    # 构建笔记索引（用于 AI 分析）
    note_index = "\n".join([f"- {n.title}: {(n.summary or n.content or '')[:80]}" for n in active_notes[:200]])

    fixes = []
    for orphan in orphans:
        # 用 AI 分析应该关联哪些笔记
        prompt = f"""你是一个知识管理助手。请分析以下孤立笔记的内容，找出最相关的 1-3 篇笔记。

## 孤立笔记
标题：{orphan.title}
内容：{(orphan.content or orphan.summary or '')[:500]}

## 可选的笔记列表
{note_index}

请返回最相关的笔记标题，每行一个标题。只返回标题，不要其他内容。如果没有相关的笔记，返回空。"""

        response = llm.complete(prompt, system="你是一个知识管理助手，负责分析笔记内容并找出关联。")
        referenced_titles = [t.strip() for t in response.strip().split('\n') if t.strip()]

        # 验证标题是否存在
        valid_titles = []
        for t in referenced_titles:
            if t in {n.title for n in active_notes} and t != orphan.title:
                valid_titles.append(t)

        if valid_titles and not req.dry_run:
            # 在内容末尾添加引用
            links = "\n".join([f"[[{t}]]" for t in valid_titles[:3]])
            orphan.content = (orphan.content or "") + "\n\n" + links
            orphan.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))

            # 移除孤立标签
            orphan_tag = db.query(Tag).filter(Tag.name == "孤立").first()
            if orphan_tag and orphan_tag in orphan.tags:
                orphan.tags.remove(orphan_tag)

            # 被引用的笔记也移除孤立标签
            for t in valid_titles[:3]:
                ref_note = db.query(Note).filter(Note.title == t, Note.deleted_at.is_(None)).first()
                if ref_note and orphan_tag and orphan_tag in ref_note.tags:
                    ref_note.tags.remove(orphan_tag)

        fixes.append({
            "note_id": orphan.id,
            "title": orphan.title,
            "linked_to": valid_titles[:3] if valid_titles else []
        })

    if not req.dry_run:
        db.commit()

    return {
        "fixed_count": len([f for f in fixes if f["linked_to"]]),
        "fixes": fixes,
        "dry_run": req.dry_run,
    }


@app.post("/api/graph/analyze")
async def graph_analyze(db: Session = Depends(get_db)):
    """分析图谱问题边：
    1. 自环（source == target）
    2. 重复边
    3. 指向已删除笔记的边（stale）
    返回统计和问题边列表（只读，不修改数据）
    """
    total, notes = list_notes(db, limit=1000, include_deleted=True)
    active_notes = [n for n in notes if n.deleted_at is None]
    all_titles = {n.title for n in active_notes}

    self_loops = 0
    duplicates = 0
    stale = 0
    edge_set = set()
    problem_edges = []

    for n in notes:
        if not n.content or n.deleted_at is not None:
            continue
        for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
            target_title = m.group(1)

            if target_title == n.title:
                self_loops += 1
                problem_edges.append({"from": n.title, "to": target_title, "reason": "self_loop"})
                continue

            if target_title not in all_titles:
                stale += 1
                problem_edges.append({"from": n.title, "to": target_title, "reason": "stale"})
                continue

            key = (n.id, target_title)
            if key in edge_set:
                duplicates += 1
                problem_edges.append({"from": n.title, "to": target_title, "reason": "duplicate"})
                continue
            edge_set.add(key)

    return {
        "problem_count": self_loops + duplicates + stale,
        "self_loops": self_loops,
        "duplicates": duplicates,
        "stale_edges": stale,
        "problem_edges": problem_edges[:20],
    }


# ===== 更新代理 API =====

@app.get("/api/update/check")
async def api_update_check(channel: str = Query("stable")):
    """版本检查：从 GitHub 获取最新版本信息
    channel: stable（默认）或 beta
    """
    import httpx
    if channel not in ("stable", "beta"):
        raise HTTPException(status_code=400, detail="channel must be stable or beta")
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            if channel == "stable":
                # 正式版：直接取 latest
                resp = await client.get(
                    "https://api.github.com/repos/aqiyoung/synapse/releases/latest",
                    headers={"Accept": "application/vnd.github.v3+json", "User-Agent": "Synapse"},
                )
                if resp.status_code != 200:
                    raise HTTPException(status_code=502, detail="获取版本信息失败")
                data = resp.json()
            else:
                # Beta：取所有 release，找最新的 prerelease
                resp = await client.get(
                    "https://api.github.com/repos/aqiyoung/synapse/releases",
                    headers={"Accept": "application/vnd.github.v3+json", "User-Agent": "Synapse"},
                )
                if resp.status_code != 200:
                    raise HTTPException(status_code=502, detail="获取版本信息失败")
                releases = resp.json()
                beta_releases = [r for r in releases if r.get("prerelease")]
                if not beta_releases:
                    raise HTTPException(status_code=404, detail="暂无 beta 版本")
                data = beta_releases[0]  # 最新的 prerelease

            tag = data["tag_name"]
            version = tag.lstrip("v")
            return {
                "latest_version": version,
                "tag_name": tag,
                "channel": channel,
                "release_notes": data.get("body", ""),
                "published_at": data.get("published_at", ""),
            }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Update check failed: {e}")
        raise HTTPException(status_code=502, detail=f"版本检查失败: {str(e)}")


@app.get("/api/update/download")
async def update_download(channel: str = Query("stable")):
    """代理 APK 下载：从 GitHub 拉取最新 APK 流式返回
    channel: stable（默认）或 beta
    使用 ghproxy.com 国内代理加速下载
    """
    import httpx
    if channel not in ("stable", "beta"):
        raise HTTPException(status_code=400, detail="channel must be stable or beta")

    # 国内 GitHub 代理列表（按优先级）
    GH_PROXIES = [
        "https://ghfast.top/",
        "https://ghproxy.cn/",
        "https://gh-proxy.com/",
        "",  # 直连兜底
    ]

    try:
        async with httpx.AsyncClient(timeout=30.0) as gh_client:
            if channel == "stable":
                resp = await gh_client.get(
                    "https://api.github.com/repos/aqiyoung/synapse/releases/latest",
                    headers={"Accept": "application/vnd.github.v3+json", "User-Agent": "Synapse"},
                )
                if resp.status_code != 200:
                    raise HTTPException(status_code=502, detail="获取版本信息失败")
                data = resp.json()
            else:
                resp = await gh_client.get(
                    "https://api.github.com/repos/aqiyoung/synapse/releases",
                    headers={"Accept": "application/vnd.github.v3+json", "User-Agent": "Synapse"},
                )
                if resp.status_code != 200:
                    raise HTTPException(status_code=502, detail="获取版本信息失败")
                releases = resp.json()
                beta_releases = [r for r in releases if r.get("prerelease")]
                if not beta_releases:
                    raise HTTPException(status_code=404, detail="暂无 beta 版本")
                data = beta_releases[0]

            tag = data["tag_name"]
            version = tag.lstrip("v")
            apk_url = f"https://github.com/aqiyoung/synapse/releases/download/{tag}/synapse-v{version}.apk"

        # 尝试通过国内代理下载
        async def _stream():
            async with httpx.AsyncClient(timeout=300.0) as client:
                for proxy_prefix in GH_PROXIES:
                    try:
                        url = f"{proxy_prefix}{apk_url}" if proxy_prefix else apk_url
                        async with client.stream("GET", url, follow_redirects=True) as apk_resp:
                            if apk_resp.status_code == 200:
                                async for chunk in apk_resp.aiter_bytes():
                                    yield chunk
                                return
                    except Exception:
                        continue
                raise HTTPException(status_code=502, detail="下载 APK 失败")

        from fastapi.responses import StreamingResponse
        return StreamingResponse(
            _stream(),
            media_type="application/vnd.android.package-archive",
            headers={"Content-Disposition": f'attachment; filename="synapse-v{version}.apk"'},
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Update proxy failed: {e}")
        raise HTTPException(status_code=502, detail=f"代理下载失败: {str(e)}")


# ============ AI 对话（RAG） ============

class ChatRequest(BaseModel):
    question: str
    limit: int = 5  # 检索笔记数量


def _smart_search(db: Session, query: str, limit: int = 5) -> list[int]:
    """智能搜索：优先使用向量搜索，回退到FTS搜索"""
    from vector_search import vector_search, get_index_stats

    # 检查是否有向量索引
    stats = get_index_stats(db)
    if stats["total_notes"] > 0:
        # 使用向量搜索
        ids = vector_search(db, query, limit=limit)
        if ids:
            logger.info(f"向量搜索成功: {len(ids)} 个结果")
            return ids

    # 回退到FTS搜索
    logger.info("回退到FTS搜索")
    return _fts_search(db, query, limit=limit)


@app.post("/api/ai/chat")
async def api_ai_chat(req: ChatRequest, db: Session = Depends(get_db)):
    """RAG 对话：检索知识库 + LLM 生成回答"""
    from llm import is_enabled, complete
    if not is_enabled():
        raise HTTPException(status_code=503, detail="AI 未配置，请设置 LLM_API_KEY 环境变量")

    ids = _smart_search(db, req.question, limit=req.limit)
    if not ids:
        return {"answer": "知识库中没有找到相关内容。", "references": []}

    notes = db.query(Note).filter(Note.id.in_(ids)).all()
    context_parts = []
    references = []
    for note in notes:
        context_parts.append(f"## {note.title}\n{note.content[:2000]}")
        references.append({"id": note.id, "title": note.title, "slug": note.slug})

    context = "\n\n---\n\n".join(context_parts)

    system = """你是知识库助手。根据用户的问题和知识库中的相关内容，给出准确、简洁的回答。
规则：
- 只基于提供的知识库内容回答，不要编造信息
- 如果知识库内容不足以回答问题，坦诚说明
- 回答时引用具体的笔记来源"""

    prompt = f"""知识库相关内容：
{context}

用户问题：{req.question}"""

    answer = complete(prompt, system=system)
    return {"answer": answer, "references": references}


@app.post("/api/ai/chat/stream")
async def api_ai_chat_stream(req: ChatRequest, db: Session = Depends(get_db)):
    """RAG 对话（流式输出）"""
    from llm import is_enabled, chat_complete_stream
    if not is_enabled():
        raise HTTPException(status_code=503, detail="AI 未配置")

    ids = _smart_search(db, req.question, limit=req.limit)
    if not ids:
        async def empty():
            yield "data: 知识库中没有找到相关内容。\n\n"
            yield "data: [DONE]\n\n"
        from fastapi.responses import StreamingResponse
        return StreamingResponse(empty(), media_type="text/event-stream")

    notes = db.query(Note).filter(Note.id.in_(ids)).all()
    context_parts = []
    references = []
    for note in notes:
        context_parts.append(f"## {note.title}\n{note.content[:2000]}")
        references.append({"id": note.id, "title": note.title, "slug": note.slug})

    context = "\n\n---\n\n".join(context_parts)

    system = """你是知识库助手。根据用户的问题和知识库中的相关内容，给出准确、简洁的回答。
规则：
- 只基于提供的知识库内容回答，不要编造信息
- 如果知识库内容不足以回答问题，坦诚说明
- 回答时引用具体的笔记来源"""

    prompt = f"""知识库相关内容：
{context}

用户问题：{req.question}"""

    # 先发送引用信息
    import json
    ref_data = json.dumps({"type": "references", "data": references}, ensure_ascii=False)

    async def stream_with_refs():
        yield f"data: {ref_data}\n\n"
        for chunk in chat_complete_stream(prompt, system=system):
            yield chunk

    from fastapi.responses import StreamingResponse
    return StreamingResponse(stream_with_refs(), media_type="text/event-stream")


@app.post("/api/ai/build-index")
async def api_build_vector_index(db: Session = Depends(get_db)):
    """构建向量索引"""
    from vector_search import build_index, get_index_stats

    # 获取所有未删除的笔记
    notes = db.query(Note).filter(Note.deleted_at.is_(None)).all()
    notes_data = [(n.id, n.title, n.content) for n in notes]

    # 构建索引
    indexed = build_index(db, notes_data, batch_size=5)

    # 获取统计
    stats = get_index_stats(db)

    return {
        "success": True,
        "indexed": indexed,
        "total": len(notes_data),
        "stats": stats
    }


@app.get("/api/ai/index-stats")
async def api_get_index_stats(db: Session = Depends(get_db)):
    """获取向量索引统计信息"""
    from vector_search import get_index_stats
    stats = get_index_stats(db)
    return stats


# ===== 标签→分类映射规则管理 =====

class TagFolderRuleCreate(BaseModel):
    tag_name: str
    folder_id: int
    priority: int = 0

class TagFolderRuleUpdate(BaseModel):
    tag_name: Optional[str] = None
    folder_id: Optional[int] = None
    priority: Optional[int] = None

@app.get("/api/tag-folder-rules")
def api_list_tag_folder_rules(db: Session = Depends(get_db)):
    """获取所有标签→分类映射规则"""
    rules = db.query(TagFolderRule).order_by(TagFolderRule.priority.desc()).all()
    return [{"id": r.id, "tag_name": r.tag_name, "folder_id": r.folder_id, "folder_name": r.folder.name if r.folder else None, "priority": r.priority} for r in rules]

@app.post("/api/tag-folder-rules")
def api_create_tag_folder_rule(req: TagFolderRuleCreate, db: Session = Depends(get_db)):
    """创建标签→分类映射规则"""
    folder = db.query(Folder).filter(Folder.id == req.folder_id).first()
    if not folder:
        raise HTTPException(404, "分类不存在")
    rule = TagFolderRule(tag_name=req.tag_name, folder_id=req.folder_id, priority=req.priority)
    db.add(rule)
    db.commit()
    db.refresh(rule)
    return {"id": rule.id, "tag_name": rule.tag_name, "folder_id": rule.folder_id, "priority": rule.priority}

@app.put("/api/tag-folder-rules/{rule_id}")
def api_update_tag_folder_rule(rule_id: int, req: TagFolderRuleUpdate, db: Session = Depends(get_db)):
    """更新标签→分类映射规则"""
    rule = db.query(TagFolderRule).filter(TagFolderRule.id == rule_id).first()
    if not rule:
        raise HTTPException(404, "规则不存在")
    if req.tag_name is not None:
        rule.tag_name = req.tag_name
    if req.folder_id is not None:
        rule.folder_id = req.folder_id
    if req.priority is not None:
        rule.priority = req.priority
    db.commit()
    return {"ok": True}

@app.delete("/api/tag-folder-rules/{rule_id}")
def api_delete_tag_folder_rule(rule_id: int, db: Session = Depends(get_db)):
    """删除标签→分类映射规则"""
    rule = db.query(TagFolderRule).filter(TagFolderRule.id == rule_id).first()
    if not rule:
        raise HTTPException(404, "规则不存在")
    db.delete(rule)
    db.commit()
    return {"ok": True}

@app.post("/api/auto-categorize")
def api_auto_categorize(db: Session = Depends(get_db)):
    """手动触发：对所有未分类笔记执行自动归类"""
    rules = db.query(TagFolderRule).order_by(TagFolderRule.priority.desc()).all()
    if not rules:
        return {"message": "没有配置映射规则", "updated": 0}
    notes = db.query(Note).filter(Note.folder_id.is_(None), Note.deleted_at.is_(None)).all()
    updated = 0
    for note in notes:
        tag_names = [t.name for t in note.tags]
        for rule in rules:
            matched = False
            for tag_name in tag_names:
                if rule.tag_name.lower() in tag_name.lower() or tag_name.lower() in rule.tag_name.lower():
                    matched = True
                    break
            if matched:
                folder = db.query(Folder).filter(Folder.id == rule.folder_id).first()
                if folder:
                    note.folder_id = folder.id
                    updated += 1
                    break
    db.commit()
    return {"message": f"已自动归类 {updated} 篇笔记", "updated": updated}

