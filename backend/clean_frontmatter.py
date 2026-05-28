#!/usr/bin/env python3
"""清洗已有笔记中的 YAML frontmatter，将元数据剥离后只保留正文。"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from crud import init_db, SessionLocal, list_notes, update_note


def strip_frontmatter(content: str) -> str:
    """剥离开头的 YAML frontmatter，返回正文。"""
    if not content or not content.startswith("---"):
        return content

    end = content.find("---", 3)
    if end < 0:
        return content

    body = content[end + 3:].lstrip("\n")
    return body


def main():
    init_db()
    db = SessionLocal()

    try:
        total, notes = list_notes(db, limit=10000)
        print(f"共 {total} 条笔记，开始检查 frontmatter...")

        cleaned = 0
        skipped = 0

        for note in notes:
            original = note.content or ""
            body = strip_frontmatter(original)

            if body != original:
                # 内容有变化，更新
                note.content = body
                note.updated_at = __import__("datetime").datetime.now(
                    tz=__import__("datetime").timezone(__import__("datetime").timedelta(hours=8))
                )
                db.commit()
                db.refresh(note)
                cleaned += 1
                print(f"  [清洗] #{note.id} {note.title[:40]}")
            else:
                skipped += 1

        print(f"\n完成: {cleaned} 条清洗, {skipped} 条无需处理")

    finally:
        db.close()


if __name__ == "__main__":
    main()
