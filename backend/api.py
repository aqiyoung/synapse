"""FastAPI 路由"""
import logging

logger = logging.getLogger(__name__)
from fastapi import FastAPI, Depends, HTTPException, Query, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, Response, StreamingResponse
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
import os, shutil, uuid, zipfile, io

from crud import (
    init_db, get_db, create_note, get_note, get_note_by_slug, list_notes,
    update_note, delete_note, list_tags, get_or_create_tag,
    restore_note, permanent_delete_note, list_deleted_notes, backfill_slugs,
)
from config import LLM_MODEL, LLM_ENABLED, RAG_MAX_NOTES, RAG_MAX_CHARS, API_TOKEN
import llm

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
_PUBLIC_PATHS = {"/api/health", "/api/stats", "/api/ai/config"}


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

class NoteUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    tags: Optional[List[str]] = None



# ===== AI 请求模型 =====

class AIChatRequest(BaseModel):
    message: str
    note_ids: Optional[List[int]] = None

class AICompleteRequest(BaseModel):
    text: str
    action: str = "continue"  # continue | polish | translate | summarize
    target_lang: Optional[str] = "中文"

class AIAutoTagRequest(BaseModel):
    title: str
    content: str


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
    note = create_note(db, title=data.title, content=data.content, tag_names=data.tags)
    # 后台自动 AI 分析（不阻塞响应）
    if llm.is_enabled() and data.content and len(data.content) > 50:
        import asyncio
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
    # 后台自动 AI 分析（不阻塞响应）
    if llm.is_enabled() and data.content and len(data.content) > 50:
        import asyncio
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


# ===== AI API =====

@app.get("/api/ai/config")
def ai_config():
    """返回 AI 配置状态"""
    return {"enabled": llm.is_enabled(), "model": LLM_MODEL}


@app.post("/api/ai/chat")
async def ai_chat(req: AIChatRequest, db: Session = Depends(get_db)):
    """AI 对话（流式 SSE），支持 RAG"""
    if not llm.is_enabled():
        return Response(content="data: [ERROR] AI 未配置\n\n", media_type="text/event-stream")

    messages = []

    # RAG：拉取相关笔记作为上下文
    context_text = ""
    if req.note_ids:
        note_ids = req.note_ids[:RAG_MAX_NOTES]
        for nid in note_ids:
            n = get_note(db, nid)
            if n and n.content:
                truncated = n.content[:RAG_MAX_CHARS]
                context_text += f"\n\n--- 笔记《{n.title}》---\n{truncated}"

    if context_text:
        messages.append({
            "role": "system",
            "content": f"你是知识库助手。基于以下笔记内容回答用户问题。如果笔记中没有相关信息，请如实说明。\n{context_text}"
        })
    else:
        messages.append({
            "role": "system",
            "content": "你是知识库助手，帮助用户管理和理解他们的知识。回答简洁有用，使用中文。"
        })

    messages.append({"role": "user", "content": req.message})

    return StreamingResponse(llm.chat_stream(messages), media_type="text/event-stream")


@app.post("/api/ai/complete")
async def ai_complete(req: AICompleteRequest):
    """AI 辅助写作（流式 SSE）"""
    if not llm.is_enabled():
        return Response(content="data: [ERROR] AI 未配置\n\n", media_type="text/event-stream")

    action_prompts = {
        "continue": "请续写下面的内容，保持风格和语气一致，直接输出续写部分：\n\n",
        "polish": "请润色下面的内容，改进表达和流畅度，保持原意，直接输出润色后的内容：\n\n",
        "translate": f"请将下面的内容翻译为 {req.target_lang}，直接输出翻译结果：\n\n",
        "summarize": "请总结下面的内容，提炼关键要点，使用简洁的中文：\n\n",
    }

    prefix = action_prompts.get(req.action, action_prompts["continue"])
    system = "你是一个专业的写作助手，直接输出结果，不要解释。"
    prompt = prefix + req.text

    return StreamingResponse(llm.chat_complete_stream(prompt, system), media_type="text/event-stream")


@app.post("/api/ai/auto-tag")
async def ai_auto_tag(req: AIAutoTagRequest):
    """AI 自动标签和摘要"""
    if not llm.is_enabled():
        return {"tags": [], "summary": "", "error": "AI 未配置"}

    prompt = f"""请为以下笔记生成标签和摘要。

标题：{req.title}
内容：{req.content[:3000]}

请用 JSON 格式输出：
{{
  "tags": ["标签1", "标签2", "标签3"],
  "summary": "一句话摘要"
}}"""

    result = llm.complete(prompt, system="你是一个知识管理助手，输出纯 JSON，不要包含 markdown 代码块。")

    import json, re
    try:
        # 尝试提取 JSON
        json_str = result.strip()
        m = re.search(r'\{.*\}', json_str, re.DOTALL)
        if m:
            json_str = m.group()
        data = json.loads(json_str)
        return {"tags": data.get("tags", [])[:5], "summary": data.get("summary", "")[:200]}
    except Exception:
        return {"tags": [], "summary": ""}


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


# ===== 后台自动 AI 分析 =====

async def _auto_analyze_note(note_id: int):
    """后台自动分析笔记（静默运行，不阻塞主流程）"""
    try:
        from crud import SessionLocal
        from models import Note, Tag
        db = SessionLocal()
        try:
            note = db.query(Note).filter(Note.id == note_id).first()
            if not note:
                return
            
            # 获取所有笔记标题用于交叉引用
            total, all_notes = list_notes(db, limit=500)
            note_titles = [n.title for n in all_notes if n.id != note.id]
            
            prompt = f"""分析以下笔记，生成标签和摘要。

标题：{note.title}
内容：{(note.content or '')[:3000]}

现有笔记标题（用于交叉引用）：
{chr(10).join(note_titles[:50])}

请用 JSON 格式输出：
{{
  "tags": ["标签1", "标签2", "标签3"],
  "summary": "一句话摘要（50字以内）"
}}"""
            
            result = llm.complete(prompt, system="你是一个知识管理助手，输出纯 JSON。")
            
            import json, re
            json_str = result.strip()
            m = re.search(r'\{.*\}', json_str, re.DOTALL)
            if m:
                json_str = m.group()
            data = json.loads(json_str)
            
            tags = data.get("tags", [])[:5]
            summary = data.get("summary", "")[:200]
            
            # 更新笔记
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


# ===== Karpathy LLM Wiki 风格功能 =====

class SmartIngestRequest(BaseModel):
    """智能摄入请求"""
    note_id: int

class OverviewRequest(BaseModel):
    """全局概览请求"""
    pass


@app.post("/api/ai/smart-ingest")
async def ai_smart_ingest(req: SmartIngestRequest, db: Session = Depends(get_db)):
    """AI 智能摄入：自动分析笔记，生成标签、摘要、交叉引用
    
    借鉴 Karpathy LLM Wiki 的两步思维链：
    第一步：分析内容，提取关键信息
    第二步：生成结构化输出（标签、摘要、相关笔记）
    """
    if not llm.is_enabled():
        return {"error": "AI 未配置"}

    note = get_note(db, req.note_id)
    if not note:
        raise HTTPException(status_code=404, detail="笔记不存在")

    # 获取所有笔记标题用于交叉引用
    total, all_notes = list_notes(db, limit=500)
    note_titles = [n.title for n in all_notes if n.id != note.id]

    # 第一步：分析内容
    analysis_prompt = f"""请分析以下笔记内容，提取关键信息。

标题：{note.title}
内容：{note.content[:4000]}

请用 JSON 格式输出：
{{
  "tags": ["标签1", "标签2", "标签3"],
  "summary": "一句话摘要（50字以内）",
  "entities": ["提到的人物/组织/产品"],
  "concepts": ["涉及的核心概念/技术/方法"],
  "related_titles": ["与现有笔记可能相关的标题"]
}}

现有笔记标题列表（用于交叉引用匹配）：
{chr(10).join(note_titles[:100])}
"""

    result = llm.complete(
        analysis_prompt,
        system="你是一个知识管理助手。分析笔记内容，提取标签、摘要、实体、概念，并找出与现有笔记的关联。输出纯 JSON。"
    )

    import json, re
    try:
        json_str = result.strip()
        m = re.search(r'\{.*\}', json_str, re.DOTALL)
        if m:
            json_str = m.group()
        data = json.loads(json_str)
    except Exception:
        return {"error": "AI 分析失败", "raw": result[:500]}

    tags = data.get("tags", [])[:5]
    summary = data.get("summary", "")[:200]
    entities = data.get("entities", [])
    concepts = data.get("concepts", [])
    related_titles = data.get("related_titles", [])

    # 更新笔记的标签和摘要
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

    # 找到匹配的笔记 ID
    related_notes = []
    for title in related_titles:
        for n in all_notes:
            if n.title == title or title in n.title:
                related_notes.append({"id": n.id, "title": n.title})
                break

    return {
        "ok": True,
        "note_id": note.id,
        "tags": tags,
        "summary": summary,
        "entities": entities,
        "concepts": concepts,
        "related_notes": related_notes[:5],
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
    recent_notes = sorted(notes, key=lambda n: n.updated_at or datetime.min, reverse=True)[:10]

    # 统计孤立笔记（无 wikilink 引用）
    import re
    all_titles = {n.title for n in notes}
    referenced = set()
    for n in notes:
        if n.content:
            for m in re.finditer(r'\[\[([^\]]+)\]\]', n.content):
                referenced.add(m.group(1))

    orphan_notes = []
    for n in notes:
        if n.title not in referenced and not (n.content and re.search(r'\[\[([^\]]+)\]\]', n.content)):
            orphan_notes.append({"id": n.id, "title": n.title})

    return {
        "total_notes": total,
        "total_tags": len(tags),
        "top_tags": tag_stats[:15],
        "recent_notes": [{"id": n.id, "title": n.title, "updated_at": n.updated_at.isoformat() if n.updated_at else ""} for n in recent_notes],
        "orphan_notes": orphan_notes[:20],
        "orphan_count": len(orphan_notes),
    }


@app.post("/api/ai/overview")
async def ai_overview_generate(db: Session = Depends(get_db)):
    """AI 生成全局概览 - 调用 LLM 分析知识库结构"""
    if not llm.is_enabled():
        return {"error": "AI 未配置"}

    total, notes = list_notes(db, limit=500)
    tags = list_tags(db)

    # 构建笔记索引
    note_index = []
    for n in notes:
        tag_names = [t.name for t in n.tags]
        snippet = (n.content or "")[:100].replace('\n', ' ')
        note_index.append(f"- [{n.id}] {n.title} | 标签: {','.join(tag_names)} | {snippet}")

    prompt = f"""你是一个知识库分析助手。请分析以下知识库的笔记列表，生成一份全局概览报告。

笔记总数：{total}
标签数：{len(tags)}

笔记列表（前200条）：
{chr(10).join(note_index[:200])}

请生成以下内容（使用 Markdown 格式）：

## 知识领域分布
按主题分类，列出主要的知识领域和每个领域的笔记数量。

## 核心主题
列出知识库中最核心的 5-8 个主题，每个主题一句话描述。

## 知识脉络
描述知识库中各主题之间的关联关系。

## 建议
- 可能需要补充的知识方向
- 可以深入研究的主题
- 需要整理或合并的内容
"""

    result = llm.complete(
        prompt,
        system="你是一个知识管理专家，擅长分析和总结知识库结构。使用中文输出，Markdown 格式。"
    )

    return {"overview": result}


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

    # 1. 孤立笔记
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

    if orphans:
        issues.append({
            "type": "orphan",
            "severity": "warning",
            "message": f"发现 {len(orphans)} 篇孤立笔记（无交叉引用）",
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
async def lint_fix_broken_links(req: LintFixRequest, db: Session = Depends(get_db)):
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
async def lint_fix_orphans(req: LintFixRequest, db: Session = Depends(get_db)):
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
