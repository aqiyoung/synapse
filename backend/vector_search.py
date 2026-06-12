"""向量搜索模块 - 使用SiliconFlow Embedding API实现RAG"""

import json
import requests
import numpy as np
from typing import List, Tuple
import logging
from sqlalchemy import text as sa_text
from sqlalchemy.orm import Session

logger = logging.getLogger(__name__)

# SiliconFlow配置（从openclaw复用）
SILICONFLOW_API_KEY = "sk-dbagbhhfsydarnnypjwyzhfusdriykjsigzjdpmuswpamvem"
SILICONFLOW_BASE_URL = "https://api.siliconflow.cn/v1"
EMBEDDING_MODEL = "Qwen/Qwen3-Embedding-0.6B"


def get_embedding(text: str) -> List[float]:
    """获取文本的向量表示"""
    try:
        response = requests.post(
            f"{SILICONFLOW_BASE_URL}/embeddings",
            headers={
                "Authorization": f"Bearer {SILICONFLOW_API_KEY}",
                "Content-Type": "application/json"
            },
            json={
                "model": EMBEDDING_MODEL,
                "input": text[:8000]  # 限制文本长度
            },
            timeout=30
        )
        response.raise_for_status()
        data = response.json()
        return data["data"][0]["embedding"]
    except Exception as e:
        logger.error(f"获取Embedding失败: {e}")
        return None


def cosine_similarity(a: List[float], b: List[float]) -> float:
    """计算余弦相似度"""
    a = np.array(a)
    b = np.array(b)
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))


def init_vector_table(db: Session):
    """初始化向量表"""
    db.execute(sa_text("""
        CREATE TABLE IF NOT EXISTS note_vectors (
            note_id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            embedding TEXT NOT NULL,
            content_hash INTEGER NOT NULL,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (note_id) REFERENCES notes(id)
        )
    """))
    db.commit()


def build_note_text(title: str, content: str) -> str:
    """构建用于Embedding的文本（标题+内容摘要）"""
    # 取标题 + 内容前1000字符
    content_preview = content[:1000] if content else ""
    return f"{title}\n{content_preview}"


def index_note(db: Session, note_id: int, title: str, content: str) -> bool:
    """索引单篇笔记"""
    # 检查是否已索引且内容未变
    content_hash = hash(content[:1000])
    existing = db.execute(
        sa_text("SELECT content_hash FROM note_vectors WHERE note_id = :note_id"),
        {"note_id": note_id}
    ).fetchone()

    if existing and existing[0] == content_hash:
        return True  # 内容没变，跳过

    # 获取向量
    text = build_note_text(title, content)
    embedding = get_embedding(text)
    if not embedding:
        return False

    # 存储到SQLite
    embedding_json = json.dumps(embedding)
    db.execute(
        sa_text("""
            INSERT OR REPLACE INTO note_vectors (note_id, title, embedding, content_hash, updated_at)
            VALUES (:note_id, :title, :embedding, :content_hash, CURRENT_TIMESTAMP)
        """),
        {
            "note_id": note_id,
            "title": title,
            "embedding": embedding_json,
            "content_hash": content_hash
        }
    )
    db.commit()
    logger.info(f"已索引笔记: {note_id} - {title}")
    return True


def build_index(db: Session, notes: List[Tuple[int, str, str]], batch_size: int = 10) -> int:
    """批量构建索引

    Args:
        db: 数据库会话
        notes: [(id, title, content), ...]
        batch_size: 批量大小

    Returns:
        成功索引的数量
    """
    init_vector_table(db)
    indexed = 0

    for i, (note_id, title, content) in enumerate(notes):
        # 检查是否已索引且内容未变
        content_hash = hash(content[:1000])
        existing = db.execute(
            sa_text("SELECT content_hash FROM note_vectors WHERE note_id = :note_id"),
            {"note_id": note_id}
        ).fetchone()

        if existing and existing[0] == content_hash:
            indexed += 1
            continue

        # 获取向量
        text = build_note_text(title, content)
        embedding = get_embedding(text)
        if embedding:
            embedding_json = json.dumps(embedding)
            db.execute(
                sa_text("""
                    INSERT OR REPLACE INTO note_vectors (note_id, title, embedding, content_hash, updated_at)
                    VALUES (:note_id, :title, :embedding, :content_hash, CURRENT_TIMESTAMP)
                """),
                {
                    "note_id": note_id,
                    "title": title,
                    "embedding": embedding_json,
                    "content_hash": content_hash
                }
            )
            indexed += 1
            logger.info(f"[{i+1}/{len(notes)}] 已索引: {title}")

        # 每batch_size个提交一次
        if (i + 1) % batch_size == 0:
            db.commit()

    db.commit()
    return indexed


def vector_search(db: Session, query: str, limit: int = 5) -> List[int]:
    """向量搜索，返回笔记ID列表"""
    # 检查向量表是否存在
    table_exists = db.execute(
        sa_text("SELECT name FROM sqlite_master WHERE type='table' AND name='note_vectors'")
    ).fetchone()

    if not table_exists:
        return []

    # 获取所有向量
    rows = db.execute(
        sa_text("SELECT note_id, embedding FROM note_vectors")
    ).fetchall()

    if not rows:
        return []

    # 获取查询的向量
    query_embedding = get_embedding(query)
    if not query_embedding:
        return []

    # 计算相似度
    similarities = []
    for row in rows:
        note_id = row[0]
        embedding = json.loads(row[1])
        sim = cosine_similarity(query_embedding, embedding)
        similarities.append((note_id, sim))

    # 按相似度降序排序
    similarities.sort(key=lambda x: x[1], reverse=True)

    # 返回top N的笔记ID
    return [note_id for note_id, _ in similarities[:limit]]


def get_index_stats(db: Session) -> dict:
    """获取索引统计信息"""
    table_exists = db.execute(
        sa_text("SELECT name FROM sqlite_master WHERE type='table' AND name='note_vectors'")
    ).fetchone()

    if not table_exists:
        return {"total_notes": 0}

    count = db.execute(sa_text("SELECT COUNT(*) FROM note_vectors")).fetchone()[0]
    return {"total_notes": count}


if __name__ == "__main__":
    # 测试
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent))
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker

    logging.basicConfig(level=logging.INFO)

    # 测试Embedding
    print("测试Embedding API...")
    embedding = get_embedding("Hello, world!")
    if embedding:
        print(f"✅ Embedding维度: {len(embedding)}")
    else:
        print("❌ Embedding获取失败")
        sys.exit(1)

    # 测试数据库操作
    print("\n测试数据库操作...")
    engine = create_engine(f"sqlite:///{Path(__file__).parent.parent / 'data' / 'knowledge.db'}")
    Session = sessionmaker(bind=engine)
    db = Session()

    init_vector_table(db)
    stats = get_index_stats(db)
    print(f"当前索引: {stats['total_notes']} 篇笔记")

    db.close()
