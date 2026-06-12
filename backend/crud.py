"""数据库 CRUD 操作"""
import hashlib as _hashlib
import logging
from sqlalchemy import create_engine, text, or_, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker, Session, joinedload, selectinload
from models import Base, Note, Tag, Folder, ReadingStats, Notification, note_tags
from datetime import datetime, timezone, timedelta
import os

logger = logging.getLogger("synapse.crud")

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "knowledge.db")
engine = create_engine(f"sqlite:///{DB_PATH}", echo=False)
SessionLocal = sessionmaker(bind=engine)


def init_db():
    """初始化数据库"""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    Base.metadata.create_all(engine)

    # 性能优化：显式创建复合/部分索引
    # create_all 只覆盖 __table_args__/index=True 声明，单列索引已建；
    # 这里补建 list_notes / stats 用的复合索引与部分索引
    with engine.connect() as conn:
        # 笔记列表排序：置顶优先 + source_created_at DESC（NULL 排后）
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_notes_pinned_srcdate "
            "ON notes(is_pinned DESC, source_created_at DESC)"
        ))
        # 按 updated_at 排（如 folder 笔记）
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_notes_updated_at "
            "ON notes(updated_at DESC) WHERE deleted_at IS NULL"
        ))
        # deleted_at 过滤：大部分查询都需要
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_notes_deleted_at "
            "ON notes(deleted_at) WHERE deleted_at IS NULL"
        ))
        # folder_id 过滤
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_notes_folder_id "
            "ON notes(folder_id) WHERE folder_id IS NOT NULL AND deleted_at IS NULL"
        ))
        # 标签-笔记反向查询（删除标签、计数）
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_note_tags_tag_note "
            "ON note_tags(tag_id, note_id)"
        ))
        # 阅读统计：按 last_read_at 排序 + 过滤
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_reading_stats_last_read "
            "ON reading_stats(last_read_at DESC)"
        ))
        # 通知：按 created_at DESC
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_notifications_created_at "
            "ON notifications(created_at DESC)"
        ))
        # 通知未读过滤
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_notifications_unread "
            "ON notifications(is_read) WHERE is_read = 0"
        ))
        conn.commit()

    # 创建 FTS5 全文搜索表
    with engine.connect() as conn:
        conn.execute(text("""
            CREATE VIRTUAL TABLE IF NOT EXISTS note_search USING fts5(
                title, content,
                content='notes',
                content_rowid='id'
            )
        """))
        # 创建触发器保持 FTS 索引同步
        conn.execute(text("""
            CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
                INSERT INTO note_search(rowid, title, content)
                VALUES (new.id, new.title, new.content);
            END
        """))
        conn.execute(text("""
            CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
                INSERT INTO note_search(note_search, rowid, title, content)
                VALUES ('delete', old.id, old.title, old.content);
            END
        """))
        conn.execute(text("""
            CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
                INSERT INTO note_search(note_search, rowid, title, content)
                VALUES ('delete', old.id, old.title, old.content);
                INSERT INTO note_search(rowid, title, content)
                VALUES (new.id, new.title, new.content);
            END
        """))
        conn.commit()

    # 迁移：添加 is_pinned 列（如果不存在）
    with engine.connect() as conn:
        cols = conn.execute(text("PRAGMA table_info(notes)")).fetchall()
        if "is_pinned" not in [c[1] for c in cols]:
            conn.execute(text("ALTER TABLE notes ADD COLUMN is_pinned BOOLEAN DEFAULT 0"))
            conn.commit()
            print("[迁移] 已添加 is_pinned 列")


def get_db():
    """获取数据库会话"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ===== 笔记 CRUD =====

def _generate_slug(db: Session, created_at: datetime) -> str:
    """生成日期slug: YYYYMMDDNNN（当天序号）"""
    date_str = created_at.strftime("%Y%m%d")
    date_start = created_at.replace(hour=0, minute=0, second=0, microsecond=0)
    date_end = created_at.replace(hour=23, minute=59, second=59, microsecond=0)
    count = db.query(Note).filter(
        Note.created_at >= date_start,
        Note.created_at <= date_end,
    ).count()
    return f"{date_str}{count + 1:03d}"


def create_note(db: Session, title: str, content: str, tag_names: list = None, source_created_at: datetime = None) -> Note:
    """创建笔记（幂等）：如果存在相同 content 的 active 笔记，直接返回它。

    去重依据：md5(content)。同一篇内容被重复推（公众号同步、脚本批导、
    APP 重复创建）时，返回原笔记，不写新行。重复检测只对未删除的 active
    笔记生效；恢复后池子里允许存在多份 md5 相同但不是同时 active 的笔记。

    实现说明：SQLite 不内置 md5()，用 Python 算后拉全量 active 笔记的
    (id, content) 逐个比较。O(N) 对千条以内合算。超过千条时建议后续
    加 notes.content_hash 列 + 索引（待性能优化阶段考虑）。
    """
    content_hash = _hashlib.md5((content or "").encode("utf-8")).hexdigest()
    if content_hash and content:
        # 先按 length 收窄，避免不必要的 md5 计算
        target_len = len(content)
        for cand in (
            db.query(Note.id, Note.title)
            .filter(Note.deleted_at.is_(None))
            .filter(func.length(Note.content) == target_len)
            .all()
        ):
            # 同 length 极可能是同内容，算 md5 确认
            cand_content = (
                db.query(Note.content).filter(Note.id == cand.id).first()
            )
            if cand_content and _hashlib.md5(
                (cand_content[0] or "").encode("utf-8")
            ).hexdigest() == content_hash:
                logger.info(
                    f"create_note idempotent skip: md5={content_hash[:8]} "
                    f"existing_id={cand.id} title='{cand.title}' (requested '{title}')"
                )
                return db.query(Note).filter(Note.id == cand.id).first()

    now = datetime.now(tz=timezone(timedelta(hours=8)))
    note = Note(title=title, content=content, created_at=now, source_created_at=source_created_at)
    db.add(note)
    db.flush()  # 拿到 id 和 created_at

    # 生成 slug，靠 UNIQUE 约束 + IntegrityError 重试防竞态
    for attempt in range(5):
        note.slug = _generate_slug(db, note.created_at)
        try:
            # 先尝试 flush slug，触发 UNIQUE 约束检查
            db.flush()
            break
        except IntegrityError:
            db.rollback()
            db.add(note)
            db.flush()
            note.slug = None  # 下一轮重新生成

    # 处理标签
    if tag_names:
        for name in tag_names:
            tag = db.query(Tag).filter(Tag.name == name).first()
            if not tag:
                tag = Tag(name=name)
                db.add(tag)
            note.tags.append(tag)

    db.commit()
    db.refresh(note)
    return note


def get_note(db: Session, note_id: int) -> Note:
    """获取单条笔记（预加载标签和文件夹，1 次 JOIN 查询代替 N+1）"""
    return (
        db.query(Note)
        .options(joinedload(Note.folder), selectinload(Note.tags))
        .filter(Note.id == note_id)
        .first()
    )


def get_note_by_slug(db: Session, slug: str) -> Note:
    """通过 slug 获取笔记"""
    return db.query(Note).filter(Note.slug == slug, Note.deleted_at.is_(None)).first()


def backfill_slugs(db: Session) -> int:
    """为没有 slug 的笔记生成 slug，返回迁移数量"""
    from sqlalchemy import text as sa_text
    # 检查列是否存在
    result = db.execute(sa_text("PRAGMA table_info(notes)")).fetchall()
    if "slug" not in [r[1] for r in result]:
        db.execute(sa_text("ALTER TABLE notes ADD COLUMN slug VARCHAR(20)"))
        db.commit()

    notes = db.query(Note).filter((Note.slug.is_(None)) | (Note.slug == "")).order_by(Note.created_at.asc()).all()
    if not notes:
        return 0

    date_counter = {}
    migrated = 0
    for note in notes:
        date_str = note.created_at.strftime("%Y%m%d")
        date_counter[date_str] = date_counter.get(date_str, 0) + 1
        note.slug = f"{date_str}{date_counter[date_str]:03d}"
        migrated += 1

    db.commit()
    return migrated


def list_notes(db: Session, skip: int = 0, limit: int = 50, tag: str = None, keyword: str = None, include_deleted: bool = False, title_only: bool = False):
    """列出笔记"""
    query = db.query(Note)

    # 默认排除已删除
    if not include_deleted:
        query = query.filter(Note.deleted_at.is_(None))

    if tag:
        query = query.join(note_tags).join(Tag).filter(Tag.name == tag)

    if keyword:
        # 转义 LIKE 通配符，防止 % 和 _ 被当作通配符
        escaped = keyword.replace('%', '%%').replace('_', '\_')
        if title_only:
            query = query.filter(Note.title.like(f"%{escaped}%"))
        else:
            query = query.filter(
                or_(
                    Note.title.like(f"%{escaped}%"),
                    Note.content.like(f"%{escaped}%"),
                )
            )

    total = query.count()
    notes = (
        query
        .options(joinedload(Note.folder), selectinload(Note.tags))
        .order_by(Note.is_pinned.desc(), Note.source_created_at.desc().nulls_last(), Note.created_at.desc())
        .offset(skip).limit(limit).all()
    )
    return total, notes


def update_note(db: Session, note_id: int, title: str = None, content: str = None, tag_names: list = None) -> Note:
    """更新笔记"""
    import re

    note = db.query(Note).filter(Note.id == note_id).first()
    if not note:
        return None

    if title is not None:
        note.title = title
    if content is not None:
        note.content = content
    if tag_names is not None:
        note.tags.clear()
        for name in tag_names:
            tag = db.query(Tag).filter(Tag.name == name).first()
            if not tag:
                tag = Tag(name=name)
                db.add(tag)
            note.tags.append(tag)

    note.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))

    # 自动移除"孤立"标签（仅当笔记当前有该标签时才做全表扫描）
    if content is not None:
        orphan_tag = db.query(Tag).filter(Tag.name == "孤立").first()

        if orphan_tag and orphan_tag in note.tags:
            has_outgoing = bool(re.search(r'\[\[([^\]]+)\]\]', content))
            if has_outgoing:
                note.tags.remove(orphan_tag)

    db.commit()
    db.refresh(note)
    return note


def delete_note(db: Session, note_id: int) -> bool:
    """软删除笔记"""
    note = db.query(Note).filter(Note.id == note_id, Note.deleted_at.is_(None)).first()
    if not note:
        return False
    note.deleted_at = datetime.now(tz=timezone(timedelta(hours=8)))
    db.commit()
    return True


def restore_note(db: Session, note_id: int) -> Note:
    """恢复软删除的笔记"""
    note = db.query(Note).filter(Note.id == note_id, Note.deleted_at.is_not(None)).first()
    if not note:
        return None
    note.deleted_at = None
    note.updated_at = datetime.now(tz=timezone(timedelta(hours=8)))
    db.commit()
    db.refresh(note)
    return note


def permanent_delete_note(db: Session, note_id: int) -> bool:
    """永久删除笔记"""
    note = db.query(Note).filter(Note.id == note_id).first()
    if not note:
        return False
    db.delete(note)
    db.commit()
    return True


def list_deleted_notes(db: Session, skip: int = 0, limit: int = 50):
    """列出已删除的笔记（回收站）"""
    query = db.query(Note).filter(Note.deleted_at.is_not(None))
    total = query.count()
    notes = query.order_by(Note.deleted_at.desc()).offset(skip).limit(limit).all()
    return total, notes


# ===== 标签 CRUD =====

def list_tags(db: Session):
    """列出所有标签（带笔记计数，不加载全部笔记）"""
    tags = db.query(Tag).order_by(Tag.name).all()
    # 批量查询每个标签的笔记数
    counts = dict(
        db.query(note_tags.c.tag_id, func.count(note_tags.c.note_id))
        .group_by(note_tags.c.tag_id)
        .all()
    )
    for tag in tags:
        tag._note_count = counts.get(tag.id, 0)
    return tags


def get_or_create_tag(db: Session, name: str) -> Tag:
    """获取或创建标签"""
    tag = db.query(Tag).filter(Tag.name == name).first()
    if not tag:
        tag = Tag(name=name)
        db.add(tag)
        db.commit()
        db.refresh(tag)
    return tag


# === Folder CRUD ===

def create_folder(db, name, icon="folder", color="#c96442", parent_id=None, sort_order=0):
    folder = Folder(name=name, icon=icon, color=color, parent_id=parent_id, sort_order=sort_order)
    db.add(folder)
    db.commit()
    db.refresh(folder)
    return folder

def list_folders(db):
    return db.query(Folder).order_by(Folder.sort_order, Folder.name).all()

def update_folder(db, folder_id, **kwargs):
    folder = db.query(Folder).filter(Folder.id == folder_id).first()
    if not folder: return None
    for k, v in kwargs.items():
        if hasattr(folder, k): setattr(folder, k, v)
    db.commit()
    db.refresh(folder)
    return folder

def delete_folder(db, folder_id):
    folder = db.query(Folder).filter(Folder.id == folder_id).first()
    if not folder: return None
    db.query(Note).filter(Note.folder_id == folder_id).update({"folder_id": None})
    db.delete(folder)
    db.commit()
    return folder

def get_folder_notes(db, folder_id, skip=0, limit=50):
    total = db.query(Note).filter(Note.folder_id == folder_id, Note.deleted_at.is_(None)).count()
    notes = db.query(Note).filter(Note.folder_id == folder_id, Note.deleted_at.is_(None)).order_by(Note.updated_at.desc()).offset(skip).limit(limit).all()
    return total, notes


# === Stats CRUD ===

def record_read(db, note_id):
    stat = db.query(ReadingStats).filter(ReadingStats.note_id == note_id).first()
    now = datetime.now(tz=timezone(timedelta(hours=8)))
    if not stat:
        stat = ReadingStats(note_id=note_id, read_count=1, first_read_at=now, last_read_at=now)
        db.add(stat)
    else:
        stat.read_count += 1
        stat.last_read_at = now
    db.commit()

def get_reading_stats(db, note_id):
    return db.query(ReadingStats).filter(ReadingStats.note_id == note_id).first()

def get_overall_stats(db):
    total_notes = db.query(Note).filter(Note.deleted_at.is_(None)).count()
    total_tags = db.query(Tag).count()
    total_reads = db.query(func.sum(ReadingStats.read_count)).scalar() or 0
    total_read_time = db.query(func.sum(ReadingStats.total_read_time)).scalar() or 0
    week_ago = datetime.now(tz=timezone(timedelta(hours=8))) - timedelta(days=7)
    recent_reads = db.query(func.sum(ReadingStats.read_count)).filter(ReadingStats.last_read_at >= week_ago).scalar() or 0
    hot_notes = db.query(Note, ReadingStats.read_count).join(ReadingStats).filter(Note.deleted_at.is_(None)).order_by(ReadingStats.read_count.desc()).limit(10).all()
    thirty_days_ago = datetime.now(tz=timezone(timedelta(hours=8))) - timedelta(days=30)
    daily = db.query(
        func.date(ReadingStats.last_read_at).label('date'),
        func.sum(ReadingStats.read_count).label('count')
    ).filter(ReadingStats.last_read_at >= thirty_days_ago).group_by(func.date(ReadingStats.last_read_at)).all()
    return {
        "total_notes": total_notes,
        "total_tags": total_tags,
        "total_reads": total_reads,
        "total_read_time": total_read_time,
        "recent_reads": recent_reads,
        "hot_notes": [{"id": n.id, "title": n.title, "reads": c} for n, c in hot_notes],
        "daily_trend": [{"date": str(d.date), "count": d.count} for d in daily],
    }


# === Notification CRUD ===

def create_notification(db, title, body="", type="system", action_url=None):
    notif = Notification(title=title, body=body, type=type, action_url=action_url)
    db.add(notif)
    db.commit()
    db.refresh(notif)
    return notif

def list_notifications(db, limit=50, unread_only=False):
    q = db.query(Notification)
    if unread_only:
        q = q.filter(Notification.is_read == False)
    return q.order_by(Notification.created_at.desc()).limit(limit).all()

def mark_read(db, notif_id):
    notif = db.query(Notification).filter(Notification.id == notif_id).first()
    if notif:
        notif.is_read = True
        db.commit()
    return notif

def mark_all_read(db):
    db.query(Notification).filter(Notification.is_read == False).update({"is_read": True})
    db.commit()
