#!/usr/bin/env python3
"""从 OpenClaw 备份中导入 Markdown 文件到知识库数据库"""
import os
import sys

# 添加项目路径
sys.path.insert(0, os.path.dirname(__file__))

from crud import init_db, SessionLocal, create_note, delete_note, list_notes
from api import parse_frontmatter


def collect_md_files():
    """收集所有要导入的 .md 文件，返回 [(filepath, title, tags)]"""
    base_latest = "/vol1/1000/openclaw/backup/workspace.bak.20260522_000039"
    base_old = "/vol1/1000/openclaw/backup/workspace"

    # 标准系统文件，跳过
    skip_names = {
        "AGENTS.md", "SOUL.md", "IDENTITY.md", "MEMORY.md", "MEMORY-pruned.md",
        "HEARTBEAT.md", "TOOLS.md", "USER.md", "STARTUP.md", "DREAMS.md",
        "EVOLUTION.md", "TODO.md", "MANIFEST.md", "MEMORY.md.bak.before_skills_update",
        "MEMORY.md.pre-dream",
    }

    files = []

    # 1. 最新备份的根目录 .md（排除标准文件）
    if os.path.isdir(base_latest):
        for f in sorted(os.listdir(base_latest)):
            if f.endswith(".md") and f not in skip_names:
                filepath = os.path.join(base_latest, f)
                title = f[:-3]  # 去掉 .md
                # 根据文件名判断标签
                tags = []
                if title.startswith("教程"):
                    tags = ["教程"]
                elif title.startswith("文章"):
                    tags = ["文章"]
                elif "信创" in title or "UOS" in title or "麒麟" in title:
                    tags = ["信创运维"]
                elif "OpenClaw" in title:
                    tags = ["OpenClaw"]
                files.append((filepath, title, tags))

    # 2. 旧备份的根目录（教程、文章等只在旧备份有）
    if os.path.isdir(base_old):
        for f in sorted(os.listdir(base_old)):
            if f.endswith(".md") and f not in skip_names:
                filepath = os.path.join(base_old, f)
                title = f[:-3]
                # 检查是否已从最新备份导入同名文件
                if not any(t[1] == title for t in files):
                    tags = []
                    if title.startswith("教程"):
                        tags = ["教程"]
                    elif title.startswith("文章"):
                        tags = ["文章"]
                    elif "信创" in title:
                        tags = ["信创运维"]
                    files.append((filepath, title, tags))

    # 3. drafts 目录
    drafts_dir = os.path.join(base_latest, "drafts")
    if os.path.isdir(drafts_dir):
        for f in sorted(os.listdir(drafts_dir)):
            if f.endswith(".md"):
                filepath = os.path.join(drafts_dir, f)
                title = f[:-3]
                tags = ["草稿"]
                if "信创" in title or "UOS" in title or "麒麟" in title:
                    tags = ["草稿", "信创运维"]
                files.append((filepath, title, tags))

    # 4. memory 目录（日记）
    memory_dir = os.path.join(base_latest, "memory")
    if os.path.isdir(memory_dir):
        for f in sorted(os.listdir(memory_dir)):
            if f.endswith(".md"):
                filepath = os.path.join(memory_dir, f)
                title = f[:-3]
                tags = ["日记"]
                files.append((filepath, title, tags))

    # 5. docs 目录
    docs_dir = os.path.join(base_latest, "docs")
    if os.path.isdir(docs_dir):
        for f in sorted(os.listdir(docs_dir)):
            if f.endswith(".md"):
                filepath = os.path.join(docs_dir, f)
                title = f[:-3]
                tags = ["文档"]
                files.append((filepath, title, tags))

    return files


def main():
    init_db()
    db = SessionLocal()

    try:
        # 1. 删除现有笔记
        total, existing = list_notes(db, limit=1000)
        print(f"删除现有 {total} 条笔记...")
        for note in existing:
            delete_note(db, note.id)

        # 2. 收集并导入文件
        files = collect_md_files()
        print(f"找到 {len(files)} 个 Markdown 文件，开始导入...")
        print()

        success = 0
        skip = 0
        errors = []

        for filepath, title, tags in files:
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    content = f.read()

                # 跳过空文件
                if not content.strip():
                    print(f"  [跳过空文件] {title}")
                    skip += 1
                    continue

                # 剥离 frontmatter，保留正文
                fm_tags, body = parse_frontmatter(content)
                merged_tags = list(dict.fromkeys(tags + fm_tags))
                note = create_note(db, title=title, content=body, tag_names=merged_tags)
                print(f"  [导入成功] #{note.id} {title} (标签: {tags})")
                success += 1

            except Exception as e:
                print(f"  [错误] {title}: {e}")
                errors.append((title, str(e)))

        print()
        print(f"==========================================")
        print(f"  导入完成！")
        print(f"  成功: {success}")
        print(f"  跳过(空文件): {skip}")
        print(f"  失败: {len(errors)}")
        print(f"==========================================")

        if errors:
            print("\n失败的文件:")
            for title, err in errors:
                print(f"  - {title}: {err}")

        # 验证
        total, notes = list_notes(db, limit=1000)
        print(f"\n数据库现有 {total} 条笔记")

    finally:
        db.close()


if __name__ == "__main__":
    main()
