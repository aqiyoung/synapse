"""向量搜索 v2 模块 - 基于 zvec HNSW (Apache 2.0)

与 v1 的区别:
- v1: numpy 暴力余弦, O(n) 每次 query
- v2: zvec HNSW, O(log n) 每次 query, 同维度 (1024)

设计文档: docs/zvec-stage1-design.md
上游调研: docs/zvec-integration-proposal.md

v1 完全保留, v2 走 lazy fallback — zvec 不可用时自动降级到 v1.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import List, Optional, Tuple

logger = logging.getLogger(__name__)

# === 配置 ===

# 索引路径: data/zvec_index/ (跟 DB 同级, 不进 git)
BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
ZvecConfig_INDEX_PATH = str(DATA_DIR / "zvec_index")
EMBED_DIM = 1024  # Qwen3-Embedding-0.6B 输出维度

# HNSW 参数 (跟 prototype 一致)
HNSW_M = 16
HNSW_EF_CONSTRUCTION = 200
HNSW_EF_SEARCH = 50

# === zvec 导入 (lazy + 容错) ===

_zvec_module = None
_zvec_import_error: Optional[str] = None


def _try_import_zvec():
    """Try to import zvec; capture error for graceful fallback."""
    global _zvec_module, _zvec_import_error
    if _zvec_module is not None:
        return _zvec_module
    if _zvec_import_error is not None:
        return None
    try:
        import zvec as _z

        _zvec_module = _z
        return _z
    except Exception as e:  # noqa: BLE001
        _zvec_import_error = f"{type(e).__name__}: {e}"
        logger.warning("zvec import failed, vector_search_v2 disabled: %s", _zvec_import_error)
        return None


def is_zvec_available() -> bool:
    """外部代码可以问: zvec 可用吗?"""
    return _try_import_zvec() is not None


# === ZvecIndex 类 ===

class ZvecIndex:
    """zvec HNSW 索引包装.

    线程安全: 内部用 RLock 保护 collection (zvec.Collection 不是线程安全的).
    """

    def __init__(self, path: str, dim: int = EMBED_DIM, m: int = HNSW_M,
                 ef_construction: int = HNSW_EF_CONSTRUCTION,
                 ef_search: int = HNSW_EF_SEARCH):
        self.path = path
        self.dim = dim
        self.m = m
        self.ef_construction = ef_construction
        self.ef_search = ef_search
        self._coll = None
        self._lock = threading.RLock()
        self._available = False
        self._init_error: Optional[str] = None
        self._init_collection()

    # ---- internal ----

    def _init_collection(self) -> None:
        """初始化 zvec collection. 文件存在 → open, 否则 → create."""
        zvec = _try_import_zvec()
        if zvec is None:
            self._init_error = f"zvec import failed: {_zvec_import_error}"
            return

        try:
            # zvec.init 只能调一次 (全局), 用 fallback 处理重复调用
            try:
                zvec.init(log_type=zvec.LogType.CONSOLE, log_level=zvec.LogLevel.WARN)
            except RuntimeError:
                pass  # already initialized — OK

            import zvec.typing as zt

            schema = zvec.CollectionSchema(
                name="synapse_notes",
                fields=[
                    zvec.FieldSchema("note_id", zvec.DataType.INT64),
                    zvec.FieldSchema("title", zvec.DataType.STRING),
                ],
                vectors=[
                    zvec.VectorSchema(
                        "embedding",
                        data_type=zvec.DataType.VECTOR_FP32,
                        dimension=self.dim,
                        index_param=zvec.HnswIndexParam(
                            metric_type=zt.MetricType.COSINE,
                            m=self.m,
                            ef_construction=self.ef_construction,
                        ),
                    )
                ],
            )

            p = Path(self.path)
            if p.exists():
                # 已存在 → open. 如果损坏会抛, 由外层 backup 后重建
                logger.info("[zvec] opening existing index at %s", self.path)
                self._coll = zvec.open(self.path)
            else:
                # zvec 要求 path 不存在
                p.parent.mkdir(parents=True, exist_ok=True)
                logger.info("[zvec] creating new index at %s (dim=%d, m=%d, ef_c=%d)",
                            self.path, self.dim, self.m, self.ef_construction)
                self._coll = zvec.create_and_open(self.path, schema)

            self._available = True
            logger.info("[zvec] index ready, doc_count=%s", self._coll.stats.doc_count)

        except Exception as e:  # noqa: BLE001
            self._init_error = f"{type(e).__name__}: {e}"
            logger.error("[zvec] init failed: %s", self._init_error)
            self._coll = None
            self._available = False

    # ---- public API ----

    @property
    def available(self) -> bool:
        return self._available and self._coll is not None

    @property
    def init_error(self) -> Optional[str]:
        return self._init_error

    def count(self) -> int:
        if not self.available:
            return 0
        with self._lock:
            try:
                return int(self._coll.stats.doc_count)
            except Exception as e:  # noqa: BLE001
                logger.warning("[zvec] count failed: %s", e)
                return 0

    def add(self, note_id: int, embedding: List[float], title: str = "") -> bool:
        """添加或更新单条 vector (upsert 语义).

        Returns True on success, False on failure (zvec 不可用 / 维度错 / write 失败).
        """
        if not self.available:
            return False
        if not embedding or len(embedding) != self.dim:
            logger.warning("[zvec] add: skip note_id=%s, embedding dim mismatch (%s vs %d)",
                           note_id, len(embedding) if embedding else 0, self.dim)
            return False

        with self._lock:
            try:
                t0 = time.perf_counter()
                doc = zvec_module().Doc(
                    id=str(note_id),
                    vectors={"embedding": list(embedding)},
                    fields={"note_id": int(note_id), "title": title or ""},
                )
                status = self._coll.upsert(doc)
                # flush 落盘 (172 篇规模, 写不频繁)
                self._coll.flush()
                dt_ms = (time.perf_counter() - t0) * 1000
                logger.debug("[zvec] upsert note_id=%s in %.2fms status=%s", note_id, dt_ms, status)
                return True
            except Exception as e:  # noqa: BLE001
                logger.error("[zvec] add note_id=%s failed: %s", note_id, e)
                return False

    def remove(self, note_id: int) -> bool:
        if not self.available:
            return False
        with self._lock:
            try:
                t0 = time.perf_counter()
                self._coll.delete(str(note_id))
                self._coll.flush()
                dt_ms = (time.perf_counter() - t0) * 1000
                logger.debug("[zvec] delete note_id=%s in %.2fms", note_id, dt_ms)
                return True
            except Exception as e:  # noqa: BLE001
                logger.error("[zvec] delete note_id=%s failed: %s", note_id, e)
                return False

    def search(self, query_vec: List[float], top_k: int = 10) -> List[Tuple[int, float]]:
        """搜索 top-k 最近邻.

        Returns: [(note_id, score), ...] 按 score 降序. 失败/空 → [].
        """
        if not self.available:
            return []
        if not query_vec or len(query_vec) != self.dim:
            logger.warning("[zvec] search: skip, query_vec dim mismatch")
            return []

        with self._lock:
            try:
                t0 = time.perf_counter()
                q = zvec_module().Query(
                    field_name="embedding",
                    vector=list(query_vec),
                    param=zvec_module().HnswQueryParam(ef=self.ef_search),
                )
                docs = self._coll.query(queries=q, topk=top_k,
                                         output_fields=["note_id", "title"])
                dt_ms = (time.perf_counter() - t0) * 1000
                results: List[Tuple[int, float]] = []
                for d in docs:
                    # zvec 把 id 存成 string, 转回 int
                    try:
                        nid = int(d.id)
                    except (TypeError, ValueError):
                        # 从 fields 取
                        nid = int(d.fields.get("note_id", 0)) if d.fields else 0
                    if nid <= 0:
                        continue
                    results.append((nid, float(d.score) if d.score is not None else 0.0))
                logger.info("[zvec] search top_k=%d returned %d hits in %.2fms (top score=%.4f)",
                            top_k, len(results), dt_ms, results[0][1] if results else 0.0)
                return results
            except Exception as e:  # noqa: BLE001
                logger.error("[zvec] search failed, fallback to v1: %s", e)
                return []

    def rebuild(self, docs: List[Tuple[int, List[float], str]]) -> int:
        """批量重建索引 (从 DB 一次性灌).

        Args:
            docs: [(note_id, embedding, title), ...]

        Returns: 成功写入的数量. 失败一条不影响其他.
        """
        if not self.available:
            return 0

        # 先备份旧索引 (如果存在)
        p = Path(self.path)
        if p.exists():
            ts = int(time.time())
            bak = p.with_suffix(f".bak.{ts}")
            try:
                p.rename(bak)
                logger.info("[zvec] backed up old index to %s", bak)
            except Exception as e:  # noqa: BLE001
                logger.warning("[zvec] backup failed: %s (继续重建)", e)

        # 重建
        try:
            zvec = zvec_module()
            import zvec.typing as zt
            schema = zvec.CollectionSchema(
                name="synapse_notes",
                fields=[
                    zvec.FieldSchema("note_id", zvec.DataType.INT64),
                    zvec.FieldSchema("title", zvec.DataType.STRING),
                ],
                vectors=[
                    zvec.VectorSchema(
                        "embedding",
                        data_type=zvec.DataType.VECTOR_FP32,
                        dimension=self.dim,
                        index_param=zvec.HnswIndexParam(
                            metric_type=zt.MetricType.COSINE,
                            m=self.m,
                            ef_construction=self.ef_construction,
                        ),
                    )
                ],
            )
            # 释放旧 collection, 创建新的
            if self._coll is not None:
                try:
                    self._coll.destroy()
                except Exception:  # noqa: BLE001
                    pass

            # path 已被 rename, 现在不存在了
            self._coll = zvec.create_and_open(self.path, schema)
            self._available = True
            logger.info("[zvec] rebuilt collection, inserting %d docs", len(docs))

        except Exception as e:  # noqa: BLE001
            logger.error("[zvec] rebuild: failed to recreate collection: %s", e)
            self._available = False
            return 0

        # 批量 insert
        success = 0
        t0 = time.perf_counter()
        with self._lock:
            for note_id, embedding, title in docs:
                if not embedding or len(embedding) != self.dim:
                    logger.warning("[zvec] rebuild skip note_id=%s dim mismatch", note_id)
                    continue
                try:
                    doc = zvec.Doc(
                        id=str(note_id),
                        vectors={"embedding": list(embedding)},
                        fields={"note_id": int(note_id), "title": title or ""},
                    )
                    status = self._coll.insert(doc)
                    success += 1
                except Exception as e:  # noqa: BLE001
                    logger.warning("[zvec] rebuild insert note_id=%s failed: %s", note_id, e)

            try:
                self._coll.flush()
            except Exception as e:  # noqa: BLE001
                logger.warning("[zvec] rebuild flush failed: %s", e)

        dt = time.perf_counter() - t0
        logger.info("[zvec] rebuild done: %d/%d vectors in %.2fs",
                    success, len(docs), dt)
        return success


def zvec_module():
    """Helper to get the imported zvec module (assumes is_zvec_available())."""
    m = _try_import_zvec()
    assert m is not None
    return m


# === 单例管理 ===

_index_singleton: Optional[ZvecIndex] = None
_index_lock = threading.Lock()


def get_or_init_index(path: str = ZvecConfig_INDEX_PATH) -> Optional[ZvecIndex]:
    """全局单例 lazy init. 失败返回 None (caller 走 v1 fallback)."""
    global _index_singleton
    if _index_singleton is not None:
        return _index_singleton

    with _index_lock:
        if _index_singleton is not None:
            return _index_singleton
        if not is_zvec_available():
            logger.info("[zvec] not available, v2 disabled")
            return None
        try:
            idx = ZvecIndex(path)
            _index_singleton = idx
            return idx
        except Exception as e:  # noqa: BLE001
            logger.error("[zvec] get_or_init_index failed: %s", e)
            return None


def reset_index_singleton() -> None:
    """测试用: 重置单例, 强制下次重建."""
    global _index_singleton
    _index_singleton = None


# === 高层 API (供 api.py 调用) ===

def search_similar_notes_v2(query_vec: List[float], top_k: int = 10) -> List[Tuple[int, float]]:
    """zvec 搜索, 失败返回 [] (caller 决定是否 fallback v1)."""
    idx = get_or_init_index()
    if idx is None or not idx.available:
        return []
    return idx.search(query_vec, top_k=top_k)


def add_note_to_index(note_id: int, embedding: List[float], title: str = "") -> bool:
    """写新 note 时调. 失败仅 log, 不抛."""
    idx = get_or_init_index()
    if idx is None or not idx.available:
        return False
    return idx.add(note_id, embedding, title)


def remove_note_from_index(note_id: int) -> bool:
    """删 note 时调. 失败仅 log, 不抛."""
    idx = get_or_init_index()
    if idx is None or not idx.available:
        return False
    return idx.remove(note_id)


def rebuild_index_from_db(db_session_factory) -> int:
    """一次性从 DB 重建. 调用方传一个 callable → Session.

    读 note_vectors (已经有 embedding 的) → 直接灌.
    没有 embedding 的 notes 不灌 (跟 v1 行为一致: 缺 embedding 就跳过).
    """
    from sqlalchemy import text as sa_text

    idx = get_or_init_index()
    if idx is None or not idx.available:
        logger.warning("[zvec] rebuild skipped: index not available")
        return 0

    session = db_session_factory()
    try:
        # 优先 join 到 notes, 过滤掉已软删的 (跟现状 v1 行为对齐:
        # v1 也是只扫有 embedding 的行, 软删的不主动从 note_vectors 删除)
        rows = session.execute(sa_text("""
            SELECT nv.note_id, nv.embedding, nv.title
            FROM note_vectors nv
            JOIN notes n ON n.id = nv.note_id
            WHERE n.deleted_at IS NULL
        """)).fetchall()

        docs: List[Tuple[int, List[float], str]] = []
        for row in rows:
            try:
                emb = json.loads(row[1])
                if not isinstance(emb, list) or len(emb) != EMBED_DIM:
                    continue
                docs.append((int(row[0]), emb, str(row[2] or "")))
            except (json.JSONDecodeError, TypeError, ValueError) as e:
                logger.warning("[zvec] rebuild skip note_id=%s parse error: %s", row[0], e)

        return idx.rebuild(docs)
    finally:
        session.close()


# === 测试用工具 ===

def _hash_fallback_embedding(text: str, dim: int = EMBED_DIM) -> List[float]:
    """跟 prototype 一致的 hash fallback, 用于 SiliconFlow 失效时.

    用文本 hash → seed → 生成稳定的伪 embedding. 注意: 不保证语义召回,
    仅用于 stage 1 测试 pipeline. Stage 2 修 key 后切回真实 embedding.
    """
    import hashlib
    import random
    h = hashlib.sha256(text.encode("utf-8")).digest()
    seed = int.from_bytes(h[:8], "big")
    rng = random.Random(seed)
    # 归一化后跟真实 embedding 维度一致
    vec = [rng.gauss(0, 1) for _ in range(dim)]
    norm = sum(x * x for x in vec) ** 0.5 or 1.0
    return [x / norm for x in vec]


# 暴露给 api.py 用的常量
INDEX_PATH = ZvecConfig_INDEX_PATH
DIM = EMBED_DIM


if __name__ == "__main__":
    # 简单冒烟
    logging.basicConfig(level=logging.INFO)
    if not is_zvec_available():
        print("zvec not available")
        raise SystemExit(1)
    print("zvec available, INDEX_PATH =", INDEX_PATH)
    idx = get_or_init_index("/tmp/zvec_v2_smoke_main")
    if idx is None:
        print("init failed")
        raise SystemExit(1)
    print("count:", idx.count())
    print("available:", idx.available)
    print("init_error:", idx.init_error)