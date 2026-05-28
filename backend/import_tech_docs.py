#!/usr/bin/env python3
"""只导入技术文档到知识库（教程、文章、草稿、docs）"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from crud import init_db, SessionLocal, create_note, list_notes
from api import parse_frontmatter

BACKUP = "/vol1/1000/openclaw/backup/workspace.bak.20260522_000039"
OLD_BACKUP = "/vol1/1000/openclaw/backup/workspace"

SKIP = {
    "AGENTS.md", "SOUL.md", "IDENTITY.md", "MEMORY.md", "MEMORY-pruned.md",
    "HEARTBEAT.md", "TOOLS.md", "USER.md", "STARTUP.md", "DREAMS.md",
    "EVOLUTION.md", "TODO.md", "MANIFEST.md",
    "dream-summary.md", "skills-list.md", "memory-system-upgrade.md",
    "claw-code-learning.md", "3月报告生成.md", "dream_diary_2026-04-17.md",
    "dream-diary.md", "dream_diary_entry.md", "tmp_rufus_article.md",
    "tmp_rufus_article_v2.md", "daily-work-diary-sync-report.md",
}

# 目录 → 标签
DIR_TAGS = {
    "drafts": ["草稿"],
    "docs": ["文档"],
}

# 前缀 → 标签
PREFIX_TAGS = {
    "教程": ["教程"],
    "文章": ["文章"],
    "公众号": ["公众号"],
    "小红书": ["小红书"],
}

KEYWORD_TAGS = {
    "信创": ["信创运维"], "UOS": ["信创运维"], "麒麟": ["信创运维"],
    "OpenClaw": ["OpenClaw"], "mihomo": ["网络代理"], "proxy": ["网络代理"],
    "磁盘": ["运维"], "打印机": ["运维"], "装机": ["运维"],
    "排查": ["运维"], "踩坑": ["经验"], "技巧": ["技巧"], "实战": ["实战"],
    "Windows": ["Windows"], "Ansible": ["自动化"],
}


def get_tags(fname, rel_path):
    tags = set()
    parts = rel_path.split(os.sep)
    for p in parts:
        if p in DIR_TAGS:
            tags.update(DIR_TAGS[p])
    for prefix, pt in PREFIX_TAGS.items():
        if fname.startswith(prefix):
            tags.update(pt)
    for kw, kt in KEYWORD_TAGS.items():
        if kw in fname:
            tags.update(kt)
    return sorted(tags)


def collect_files():
    files = []

    # 1. 旧备份根目录（教程、文章）
    if os.path.isdir(OLD_BACKUP):
        for f in sorted(os.listdir(OLD_BACKUP)):
            if f.endswith(".md") and f not in SKIP:
                files.append(os.path.join(OLD_BACKUP, f))

    # 2. 新备份根目录（信创、微信等）
    for f in ["信创系统连接Win7共享打印机调试方案.md", "微信公众号推文_信创系统写作实录.md"]:
        p = os.path.join(BACKUP, f)
        if os.path.exists(p):
            files.append(p)

    # 3. drafts 目录
    drafts_dir = os.path.join(BACKUP, "drafts")
    if os.path.isdir(drafts_dir):
        for f in sorted(os.listdir(drafts_dir)):
            if f.endswith(".md"):
                files.append(os.path.join(drafts_dir, f))

    # 4. docs 目录
    docs_dir = os.path.join(BACKUP, "docs")
    if os.path.isdir(docs_dir):
        for f in sorted(os.listdir(docs_dir)):
            if f.endswith(".md"):
                files.append(os.path.join(docs_dir, f))

    return files


def main():
    init_db()
    db = SessionLocal()
    try:
        total_before, _ = list_notes(db, limit=1000)
        print(f"导入前: {total_before} 条笔记")

        files = collect_files()
        print(f"找到 {len(files)} 个技术文档")
        print()

        ok = 0
        for filepath in files:
            fname = os.path.basename(filepath)
            title = fname[:-3]
            rel_path = os.path.relpath(filepath, BACKUP) if filepath.startswith(BACKUP) else os.path.relpath(filepath, OLD_BACKUP)
            tags = get_tags(fname, rel_path)

            with open(filepath, "r", encoding="utf-8") as f:
                raw = f.read()

            if not raw.strip():
                print(f"  [空] {title}")
                continue

            # 剥离 frontmatter，保留正文
            fm_tags, body = parse_frontmatter(raw)
            # frontmatter 中的 tags 优先级低于文件名推断的 tags
            merged_tags = list(dict.fromkeys(tags + fm_tags))

            note = create_note(db, title=title, content=body, tag_names=merged_tags)
            tag_str = ",".join(tags) if tags else "-"
            print(f"  [#{note.id}] {title}  [{tag_str}]")
            ok += 1

        total_after, _ = list_notes(db, limit=1000)
        print()
        print(f"导入完成: {ok} 条成功，知识库共 {total_after} 条")

    finally:
        db.close()


if __name__ == "__main__":
    main()
