#!/usr/bin/env python3
"""为已有笔记回填 source_created_at（源文件时间）"""
import os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from datetime import datetime, timezone, timedelta
from sqlalchemy import text as sa_text
from crud import init_db, SessionLocal, list_notes
from models import Note

BACKUP_DIRS = [
    "/vol1/1000/openclaw/backup/workspace.bak.20260522_000039",
    "/vol1/1000/openclaw/backup/workspace",
]

TZ = timezone(timedelta(hours=8))

def find_source_time(title):
    """尝试找到源文件时间，返回 datetime 或 None"""
    # 1. 尝试从标题解析日期（如 "2026-05-23 工作日记"）
    m = re.match(r'^(\d{4}-\d{2}-\d{2})', title)
    if m:
        try:
            dt = datetime.strptime(m.group(1), "%Y-%m-%d").replace(tzinfo=TZ)
            # 工作日记通常在晚上生成
            if "工作日记" in title or "工作总结" in title:
                dt = dt.replace(hour=23, minute=30)
            else:
                dt = dt.replace(hour=10, minute=0)
            return dt
        except: pass

    # 2. 在备份目录中找同名文件
    fname = title + ".md"
    for base in BACKUP_DIRS:
        # 根目录
        fp = os.path.join(base, fname)
        if os.path.isfile(fp):
            return datetime.fromtimestamp(os.path.getmtime(fp), tz=TZ)
        # drafts/
        fp = os.path.join(base, "drafts", fname)
        if os.path.isfile(fp):
            return datetime.fromtimestamp(os.path.getmtime(fp), tz=TZ)
        # memory/
        fp = os.path.join(base, "memory", fname)
        if os.path.isfile(fp):
            return datetime.fromtimestamp(os.path.getmtime(fp), tz=TZ)
        # docs/
        fp = os.path.join(base, "docs", fname)
        if os.path.isfile(fp):
            return datetime.fromtimestamp(os.path.getmtime(fp), tz=TZ)

    # 3. 在最新备份中再搜一遍
    latest = "/vol1/1000/openclaw/backup/workspace.bak.20260601_070024"
    for sub in ["", "drafts", "docs"]:
        fp = os.path.join(latest, sub, fname) if sub else os.path.join(latest, fname)
        if os.path.isfile(fp):
            return datetime.fromtimestamp(os.path.getmtime(fp), tz=TZ)

    return None

def main():
    init_db()
    db = SessionLocal()
    try:
        # 添加列（如果不存在）
        result = db.execute(sa_text("PRAGMA table_info(notes)")).fetchall()
        cols = [r[1] for r in result]
        if "source_created_at" not in cols:
            db.execute(sa_text("ALTER TABLE notes ADD COLUMN source_created_at DATETIME"))
            db.commit()
            print("✅ 添加 source_created_at 列")

        total, notes = list_notes(db, limit=1000)
        updated = 0
        for n in notes:
            if n.source_created_at:
                continue
            src_time = find_source_time(n.title)
            if src_time:
                n.source_created_at = src_time
                updated += 1
                print(f"  #{n.id:>3}  {n.title[:40]:40s} → {src_time.strftime('%Y-%m-%d %H:%M')}")
            else:
                # fallback: 使用 created_at
                n.source_created_at = n.created_at
                updated += 1

        db.commit()
        print(f"\n✅ 已更新 {updated}/{total} 条笔记")
    finally:
        db.close()

if __name__ == "__main__":
    main()
