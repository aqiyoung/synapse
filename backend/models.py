"""数据模型"""
from sqlalchemy import Column, Integer, String, Text, DateTime, Table, ForeignKey, Index
from sqlalchemy.orm import relationship, declarative_base
from datetime import datetime, timezone, timedelta

Base = declarative_base()

# 笔记-标签关联表
note_tags = Table(
    "note_tags",
    Base.metadata,
    Column("note_id", Integer, ForeignKey("notes.id"), primary_key=True),
    Column("tag_id", Integer, ForeignKey("tags.id"), primary_key=True),
)


class Note(Base):
    """笔记模型"""
    __tablename__ = "notes"

    id = Column(Integer, primary_key=True, autoincrement=True)
    slug = Column(String(20), unique=True, nullable=False, index=True)
    title = Column(String(500), nullable=False, default="无标题")
    content = Column(Text, nullable=False, default="")
    summary = Column(String(500), default="")
    created_at = Column(DateTime, default=lambda: datetime.now(tz=timezone(timedelta(hours=8))))
    updated_at = Column(DateTime, default=lambda: datetime.now(tz=timezone(timedelta(hours=8))),
                        onupdate=lambda: datetime.now(tz=timezone(timedelta(hours=8))))
    deleted_at = Column(DateTime, nullable=True, default=None)

    # 关联
    tags = relationship("Tag", secondary=note_tags, back_populates="notes")

    def to_dict(self):
        return {
            "id": self.id,
            "slug": self.slug,
            "title": self.title,
            "content": self.content,
            "summary": self.summary,
            "created_at": self.created_at.isoformat() if self.created_at else "",
            "updated_at": self.updated_at.isoformat() if self.updated_at else "",
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else "",
            "tags": [t.name for t in self.tags],
        }


class Tag(Base):
    """标签模型"""
    __tablename__ = "tags"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(100), unique=True, nullable=False)
    color = Column(String(20), default="#409EFF")
    created_at = Column(DateTime, default=lambda: datetime.now(tz=timezone(timedelta(hours=8))))

    # 关联
    notes = relationship("Note", secondary=note_tags, back_populates="tags")

    def to_dict(self):
        # 使用 len() 触发已加载的集合，避免额外 SQL 查询
        # 调用方应确保使用 joinedload 预加载 notes
        count = 0
        try:
            count = len(self.notes)
        except Exception:
            pass
        return {
            "id": self.id,
            "name": self.name,
            "color": self.color,
            "note_count": count,
        }
