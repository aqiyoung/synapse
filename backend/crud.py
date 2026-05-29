"""数据库 CRUD 操作"""
from sqlalchemy import create_engine, text, or_
from sqlalchemy.orm import sessionmaker, Session
from models import Base, Note, Tag, note_tags
from datetime import datetime, timezone, timedelta
import os

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "knowledge.db")
engine = create_engine(f"sqlite:///{DB_PATH}", echo=False)
SessionLocal = sessionmaker(bind=engine)


def init_db():
    """初始化数据库"""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    Base.metadata.create_all(engine)

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


def create_note(db: Session, title: str, content: str, tag_names: list = None) -> Note:
    """创建笔记"""
    now = datetime.now(tz=timezone(timedelta(hours=8)))
    note = Note(title=title, content=content, created_at=now)
    # 先提交拿到 created_at，再生成 slug
    db.add(note)
    db.flush()
    note.slug = _generate_slug(db, note.created_at)
    if tag_names:
        for name in tag_names:
            tag = db.query(Tag).filter(Tag.name == name).first()
            if not tag:
                tag = Tag(name=name)
                db.add(tag)
            note.tags.append(tag)
    db.add(note)
    db.commit()
    db.refresh(note)
    return note


def get_note(db: Session, note_id: int) -> Note:
    """获取单条笔记"""
    return db.query(Note).filter(Note.id == note_id).first()


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
    notes = query.order_by(Note.updated_at.desc()).offset(skip).limit(limit).all()
    return total, notes


def update_note(db: Session, note_id: int, title: str = None, content: str = None, tag_names: list = None) -> Note:
    """更新笔记"""
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
    """列出所有标签"""
    from sqlalchemy.orm import joinedload
    return db.query(Tag).options(joinedload(Tag.notes)).order_by(Tag.name).all()


def get_or_create_tag(db: Session, name: str) -> Tag:
    """获取或创建标签"""
    tag = db.query(Tag).filter(Tag.name == name).first()
    if not tag:
        tag = Tag(name=name)
        db.add(tag)
        db.commit()
        db.refresh(tag)
    return tag
