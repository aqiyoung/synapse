"""数据迁移：为已有笔记生成 slug（日期编号格式 YYYYMMDDNNN）"""
import os
import sys
from datetime import datetime, timezone, timedelta

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE_DIR)

from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

DB_PATH = os.path.join(BASE_DIR, "data", "knowledge.db")
engine = create_engine(f"sqlite:///{DB_PATH}", echo=False)
SessionLocal = sessionmaker(bind=engine)

TZ8 = timezone(timedelta(hours=8))


def generate_slug(created_at: datetime, index: int) -> str:
    """生成日期编号 slug，格式：YYYYMMDDNNN"""
    date_str = created_at.strftime("%Y%m%d")
    return f"{date_str}{index:03d}"


def migrate():
    db = SessionLocal()
    try:
        # 检查 slug 列是否存在
        result = db.execute(text("PRAGMA table_info(notes)")).fetchall()
        col_names = [r[1] for r in result]
        if "slug" not in col_names:
            print("添加 slug 列...")
            db.execute(text("ALTER TABLE notes ADD COLUMN slug VARCHAR(20)"))
            db.commit()

        # 获取所有没有 slug 的笔记，按创建日期排序
        notes = db.execute(
            text("SELECT id, created_at FROM notes WHERE slug IS NULL OR slug = '' ORDER BY created_at ASC")
        ).fetchall()

        if not notes:
            print("没有需要迁移的笔记")
            return

        print(f"需要迁移 {len(notes)} 篇笔记")

        # 按日期分组
        date_counter = {}
        migrated = 0
        for note_id, created_at in notes:
            if isinstance(created_at, str):
                created_at = datetime.fromisoformat(created_at)
            if created_at.tzinfo is None:
                created_at = created_at.replace(tzinfo=TZ8)

            date_str = created_at.strftime("%Y%m%d")
            if date_str not in date_counter:
                # 检查该日期已有的最大序号
                existing = db.execute(
                    text("SELECT slug FROM notes WHERE slug LIKE :prefix AND slug != ''"),
                    {"prefix": f"{date_str}%"},
                ).fetchall()
                max_idx = 0
                for (slug,) in existing:
                    try:
                        idx = int(slug[8:])
                        if idx > max_idx:
                            max_idx = idx
                    except ValueError:
                        pass
                date_counter[date_str] = max_idx

            date_counter[date_str] += 1
            slug = f"{date_str}{date_counter[date_str]:03d}"

            db.execute(
                text("UPDATE notes SET slug = :slug WHERE id = :id"),
                {"slug": slug, "id": note_id},
            )
            migrated += 1
            print(f"  #{note_id} → {slug}")

        db.commit()
        print(f"\n迁移完成，共 {migrated} 篇笔记")

    except Exception as e:
        db.rollback()
        print(f"迁移失败: {e}")
        raise
    finally:
        db.close()


if __name__ == "__main__":
    migrate()
