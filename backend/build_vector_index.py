#!/usr/bin/env python3
"""构建向量索引脚本 - 将所有笔记的向量存入SQLite"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))

from sqlalchemy import create_engine, text as sa_text
from sqlalchemy.orm import sessionmaker
from vector_search import build_index, get_index_stats
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def main():
    # 连接数据库
    db_path = Path(__file__).parent.parent / "data" / "knowledge.db"
    engine = create_engine(f"sqlite:///{db_path}")
    Session = sessionmaker(bind=engine)
    db = Session()

    try:
        # 获取所有未删除的笔记
        logger.info("正在加载笔记...")
        rows = db.execute(
            sa_text("SELECT id, title, content FROM notes WHERE deleted_at IS NULL")
        ).fetchall()

        notes = [(row[0], row[1], row[2]) for row in rows]
        logger.info(f"共 {len(notes)} 篇笔记需要索引")

        # 构建索引
        logger.info("开始构建向量索引...")
        indexed = build_index(db, notes, batch_size=5)
        logger.info(f"✅ 索引完成: {indexed}/{len(notes)} 篇笔记")

        # 显示统计
        stats = get_index_stats(db)
        logger.info(f"📊 索引统计: {stats['total_notes']} 篇笔记已索引")

    except Exception as e:
        logger.error(f"❌ 索引构建失败: {e}")
        import traceback
        traceback.print_exc()
    finally:
        db.close()


if __name__ == "__main__":
    main()
