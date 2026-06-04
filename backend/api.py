"""FastAPI 路由"""
import logging

logger = logging.getLogger(__name__)
from fastapi import FastAPI, Depends, HTTPException, Query, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, Response
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
import os, shutil, uuid, zipfile, io, asyncio
from datetime import datetime, timezone, timedelta

from models import Tag, note_tags
from crud import (
    init_db, get_db, create_note, get_note, get_note_by_slug, list_notes,
    update_note, delete_note, list_tags, get_or_create_tag,
    restore_note, permanent_delete_note, list_deleted_notes, backfill_slugs,
)
from config import API_TOKEN, ADMIN_PASSWORD

# 初始化数据库
init_db()

# 自动迁移 slug
from crud import SessionLocal, backfill_slugs
_mig_db = SessionLocal()
try:
    _count = backfill_slugs(_mig_db)
    if _count:
        print(f"[迁移] 已为 {_count} 篇笔记生成 slug")
finally:
    _mig_db.close()

app = FastAPI(title="知识库 API", version="1.1.0")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure for your domain in production
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


# 公开接口不需要认证的路径
_PUBLIC_PATHS = {"/api/health", "/api/stats", "/api/update/check", "/api/update/download", "/api/admin/verify"}


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


# ===== 笔记 API =====

@app.get("/api/notes")
def api_list_notes(
    skip: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    tag: Optional[str] = None,
    keyword: Optional[str] = None,
    db: Session = Depends(get_db),
):
    """列出笔记"""
    total, notes = list_notes(db, skip=skip, limit=limit, tag=tag, keyword=keyword)
    return {
        "total": total,
        "notes": [n.to_dict() for n in notes],
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


@app.post("/api/notes")
async def api_create_note(data: NoteCreate, db: Session = Depends(get_db)):
    """创建笔记"""
    src = None
    if data.source_created_at:
        try:
            src = datetime.fromisoformat(data.source_created_at)
        except: pass
    note = create_note(db, title=data.title, content=data.content, tag_names=data.tags, source_created_at=src)
    if data.content and len(data.content) > 50:
        asyncio.create_task(_auto_analyze_note(note.id))
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
    """列出所有标签"""
    tags = list_tags(db)
    return [t.to_dict() for t in tags]


# ===== 搜索 API =====

@app.get("/api/search")
def api_search(
    q: str = Query(..., min_length=1),
    limit: int = Query(20, ge=1, le=100),
    filter: Optional[str] = Query(None, regex="^(title|content)$"),
    db: Session = Depends(get_db),
):
    """全文搜索，使用 FTS5"""
    from sqlalchemy import text as sa_text

    # FTS5 查询：严格过滤用户输入，防止 FTS5 注入
    # 只允许中文、英文、数字、空格，移除所有 FTS5 特殊字符（" * ^ OR AND NOT NEAR 等）
    import re as _re
    safe_q = _re.sub(r'[^\w\s一-鿿]', '', q)  # 只保留字字符和中文
    # 分词：按空格分割，每个词用引号包裹支持 AND 匹配
    terms = safe_q.strip().split()
    if not terms:
        return {"query": q, "total": 0, "results": []}
    match_expr = '"' + '" AND "'.join(terms) + '"'

    if filter == "title":
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
        ids = [r[0] for r in rows]
    except Exception:
        # FTS5 失败时回退到 LIKE
        total, notes = list_notes(db, keyword=q, limit=limit, title_only=(filter == "title"))
        results = []
        for n in notes:
            d = n.to_dict()
            d["snippet"] = _make_snippet(n.content, q)
            results.append(d)
        return {"query": q, "total": total, "results": results}

    if not ids:
        return {"query": q, "total": 0, "results": []}

    # 按 FTS5 返回顺序获取笔记（用 ORM 查询以获取 to_dict()）
    from models import Note
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
    if req.password == ADMIN_PASSWORD:
        return {"ok": True}
    raise HTTPException(401, "密码错误")


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

    # 获取所有笔记用于标题匹配
    total, all_notes = list_notes(db, limit=10000)
    title_to_id = {n.title: n.id for n in all_notes}
    id_to_note = {n.id: n for n in all_notes}

    # outgoing: 从本文内容中提取 [[wikilink]]
    outgoing = []
    if note.content:
        for m in re.finditer(r'\[\[([^\]]+)\]\]', note.content):
            target_title = m.group(1)
            target_id = title_to_id.get(target_title)
            if target_id and target_id != note_id:
                outgoing.append({"id": target_id, "title": target_title})

    # incoming: 扫描所有笔记，找包含 [[本文标题]] 的
    incoming = []
    for n in all_notes:
        if n.id == note_id or not n.content:
            continue
        if re.search(rf'\[\[{re.escape(note.title)}\]\]', n.content):
            incoming.append({"id": n.id, "title": n.title})

    return {
        "note_id": note_id,
        "title": note.title,
        "outgoing": outgoing,
        "incoming": incoming,
    }


@app.get("/api/graph")
def api_graph(db: Session = Depends(get_db)):
    """返回知识图谱数据（节点 + 边）"""
    total, notes = list_notes(db, limit=10000)
    # 构建标题 → id 映射
    title_map = {}
    for n in notes:
        title_map[n.title] = n.id

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
        count = len(t.notes)
        if count > 0:
            tag_stats.append({"name": t.name, "count": count, "color": t.color})
    tag_stats.sort(key=lambda x: x["count"], reverse=True)

    # 统计最近活跃
    recent_notes = sorted(notes, key=lambda n: n.source_created_at or n.created_at or datetime.min, reverse=True)[:10]

    # 统计孤立笔记（无 wikilink 引用 且 无标签关联）
    import re
    all_titles = {n.title for n in notes}
    referenced = set()
    for n in notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                referenced.add(m.group(1))

    # 标签关联：共享标签的笔记互相关联
    tag_note_map: dict[str, set] = {}
    for n in notes:
        for t in (n.tags or []):
            tag_note_map.setdefault(t.name, set()).add(n.id)
    shared_tag_notes = set()
    for tag_name, note_ids in tag_note_map.items():
        if len(note_ids) > 1:
            shared_tag_notes.update(note_ids)

    orphan_notes = []
    for n in notes:
        has_outgoing = n.content and re.search(r'\[\[([^\]]+)\]\]', n.content)
        has_incoming = n.title in referenced
        has_shared_tag = n.id in shared_tag_notes
        if not has_outgoing and not has_incoming and not has_shared_tag:
            orphan_notes.append({"id": n.id, "title": n.title})

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
        [(t.name, len(t.notes)) for t in tags if t.notes],
        key=lambda x: -x[1]
    )

    # 最近活跃笔记
    recent = sorted(notes, key=lambda n: n.updated_at or n.created_at, reverse=True)[:10]

    # 标签聚合：按标签归类笔记
    tag_notes: dict[str, list[str]] = {}
    for t in tags:
        if t.notes:
            tag_notes[t.name] = [n.title for n in t.notes[:10]]

    # 无标签笔记数
    no_tag_count = len([n for n in notes if not n.tags])

    return {
        "overview": {
            "total_notes": total,
            "total_tags": len([t for t in tags if t.notes]),
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
    1. 孤立笔记（无交叉引用）
    2. 断链（引用了不存在的笔记）
    3. 缺少标签的笔记
    4. 内容过短的笔记
    5. 矛盾或重复内容
    """
    import re

    total, notes = list_notes(db, limit=1000)
    tags = list_tags(db)
    all_titles = {n.title for n in notes}
    title_to_id = {n.title: n.id for n in notes}

    issues = []

    # 1. 孤立笔记（无交叉引用 且 无标签关联）
    referenced = set()
    for n in notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                referenced.add(m.group(1))

    # 构建标签→笔记映射，共享标签的笔记互相关联
    tag_note_map: dict[str, set] = {}  # tag_name -> set of note ids
    for n in notes:
        for t in (n.tags or []):
            tag_note_map.setdefault(t.name, set()).add(n.id)
    # 只保留有 2+ 笔记的标签（共享标签）
    shared_tag_notes = set()
    for tag_name, note_ids in tag_note_map.items():
        if len(note_ids) > 1:
            shared_tag_notes.update(note_ids)

    # 已被标记为孤立的笔记，不再重复告警
    orphan_tagged_ids = {
        nt.note_id for nt in db.query(note_tags).join(Tag).filter(Tag.name == "孤立").all()
    }

    orphans = []
    for n in notes:
        if n.id in orphan_tagged_ids:
            continue
        has_outgoing = n.content and re.search(r'\[\[([^\]]+)\]\]', n.content)
        has_incoming = n.title in referenced
        has_shared_tag = n.id in shared_tag_notes
        if not has_outgoing and not has_incoming and not has_shared_tag:
            orphans.append(n)

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
    stats = {
        "total_notes": total,
        "total_tags": len([t for t in tags if t.notes]),
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
    import re

    total, notes = list_notes(db, limit=1000)
    referenced = set()
    for n in notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                referenced.add(m.group(1))

    orphans = []
    for n in notes:
        has_outgoing = n.content and re.search(r'\[\[([^\]]+)\]\]', n.content)
        has_incoming = n.title in referenced
        if not has_outgoing and not has_incoming:
            orphans.append(n)

    if not req.dry_run:
        orphan_tag = db.query(Tag).filter(Tag.name == "孤立").first()
        if not orphan_tag:
            orphan_tag = Tag(name="孤立", color="#8d9e8a")
            db.add(orphan_tag)
            db.flush()

    fixes = []
    for n in orphans:
        if not req.dry_run:
            # 如果已经有"孤立"标签就跳过
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


@app.post("/api/graph/prune")
async def graph_prune(req: LintFixRequest, db: Session = Depends(get_db)):
    """清除图谱垃圾边：
    1. 自环（source == target）
    2. 重复边
    3. 指向已删除笔记的边（stale）
    返回清理统计和被清理的边列表
    """
    import re

    total, notes = list_notes(db, limit=1000, include_deleted=True)
    active_notes = [n for n in notes if n.deleted_at is None]
    all_titles = {n.title for n in active_notes}

    self_loops = 0
    duplicates = 0
    stale = 0
    edge_set = set()
    pruned_edges = []

    for n in notes:
        if not n.content or n.deleted_at is not None:
            continue
        for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
            target_title = m.group(1)

            # 自环
            if target_title == n.title:
                self_loops += 1
                pruned_edges.append({"from": n.title, "to": target_title, "reason": "self_loop"})
                continue

            # 指向已删除笔记
            if target_title not in all_titles:
                stale += 1
                pruned_edges.append({"from": n.title, "to": target_title, "reason": "stale"})
                continue

            # 重复边
            key = (n.id, target_title)
            if key in edge_set:
                duplicates += 1
                pruned_edges.append({"from": n.title, "to": target_title, "reason": "duplicate"})
                continue
            edge_set.add(key)

    return {
        "fixed_count": self_loops + duplicates + stale,
        "self_loops": self_loops,
        "duplicates": duplicates,
        "stale_edges": stale,
        "pruned_edges": pruned_edges[:20],
    }


# ===== 更新代理 API =====

@app.get("/api/update/check")
async def api_update_check():
    """版本检查：从 GitHub 获取最新版本信息"""
    import httpx
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.get(
                "https://api.github.com/repos/aqiyoung/synapse/releases/latest",
                headers={"Accept": "application/vnd.github.v3+json", "User-Agent": "Synapse"},
            )
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail="获取版本信息失败")
            data = resp.json()
            tag = data["tag_name"]
            version = tag.lstrip("v")
            return {
                "latest_version": version,
                "tag_name": tag,
                "release_notes": data.get("body", ""),
                "published_at": data.get("published_at", ""),
            }
    except Exception as e:
        logger.error(f"Update check failed: {e}")
        raise HTTPException(status_code=502, detail=f"版本检查失败: {str(e)}")


@app.get("/api/update/download")
async def update_download():
    """代理 APK 下载：从 GitHub 拉取最新 APK 流式返回"""
    import httpx
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.get(
                "https://api.github.com/repos/aqiyoung/synapse/releases/latest",
                headers={"Accept": "application/vnd.github.v3+json", "User-Agent": "Synapse"},
            )
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail="获取版本信息失败")
            data = resp.json()
            tag = data["tag_name"]
            version = tag.lstrip("v")
            apk_url = f"https://github.com/aqiyoung/synapse/releases/download/{tag}/synapse-v{version}.apk"

        async def _stream():
            async with httpx.AsyncClient(timeout=300.0) as client:
                async with client.stream("GET", apk_url, follow_redirects=True) as apk_resp:
                    if apk_resp.status_code != 200:
                        raise HTTPException(status_code=502, detail="下载 APK 失败")
                    async for chunk in apk_resp.aiter_bytes():
                        yield chunk

        from fastapi.responses import StreamingResponse
        return StreamingResponse(
            _stream(),
            media_type="application/vnd.android.package-archive",
            headers={"Content-Disposition": f'attachment; filename="synapse-v{version}.apk"'},
        )
    except Exception as e:
        logger.error(f"Update proxy failed: {e}")
        raise HTTPException(status_code=502, detail=f"代理下载失败: {str(e)}")
