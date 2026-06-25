#!/usr/bin/env python3
"""
zvec 集成评估 prototype — Synapse 知识库语义搜索

目标：验证把 SQLite FTS5 关键词搜索升级为 zvec 向量检索的可行性。
不要进生产，只用来给老板拍板用。

输出：
- FTS5 vs zvec 召回率对比
- zvec HNSW vs numpy 暴力搜索性能对比
- 集成方案 doc 的原始数据

用法：
    ./.zvec-venv/bin/python tools/zvec-prototype.py
"""

import json
import os
import sqlite3
import sys
import time
import hashlib
import struct
import math
from pathlib import Path
from typing import List, Tuple

# === 配置 ===
BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
DOCS_DIR = BASE_DIR / "docs"
DB_PATH = DATA_DIR / "knowledge.db"
ZVEC_PATH = Path("/tmp/zvec-prototype-data")  # 不进 data/
SILICONFLOW_API_KEY = os.environ.get("SILICONFLOW_API_KEY", "")
SILICONFLOW_BASE_URL = os.environ.get("SILICONFLOW_BASE_URL", "https://api.siliconflow.cn/v1")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_DIM_CHECK", "")  # 占位
# 用 BGE 中文小模型 (1024 维) — 跟 Synapse 现在用的 Qwen3-Embedding-0.6B 一样语义质量
EMBEDDING_MODEL = os.environ.get("ZVEC_EMBED_MODEL", "BAAI/bge-m3")
# 如果 BGE-m3 太慢降级到 0.6B
EMBEDDING_FALLBACK = "Qwen/Qwen3-Embedding-0.6B"
EMBEDDING_DIM = 1024  # bge-m3 是 1024 维

import requests
import numpy as np

import zvec

# === 1. 从 Synapse SQLite 读所有笔记 ===
def load_notes(limit: int = 100) -> List[dict]:
    """读 notes 表，跟生产 schema 一致"""
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT id, slug, title, content, created_at FROM notes "
        "WHERE deleted_at IS NULL AND content IS NOT NULL "
        "ORDER BY id LIMIT ?",
        (limit,)
    ).fetchall()
    notes = []
    for r in rows:
        notes.append({
            "id": r["id"],
            "slug": r["slug"],
            "title": r["title"],
            "content": r["content"] or "",
        })
    conn.close()
    return notes


# === 2. Embedding：先试 SiliconFlow BGE，失败用 hash 假向量 ===
def get_embedding_siliconflow(text: str, model: str = None) -> List[float]:
    """调用 SiliconFlow embedding API"""
    if not SILICONFLOW_API_KEY:
        return None
    model = model or EMBEDDING_MODEL
    try:
        resp = requests.post(
            f"{SILICONFLOW_BASE_URL}/embeddings",
            headers={
                "Authorization": f"Bearer {SILICONFLOW_API_KEY}",
                "Content-Type": "application/json",
            },
            json={"model": model, "input": text[:8000]},
            timeout=30,
        )
        resp.raise_for_status()
        return resp.json()["data"][0]["embedding"]
    except Exception as e:
        print(f"  ⚠️  SiliconFlow 失败 (model={model}): {e}")
        return None


def get_embedding_hash(text: str, dim: int = 128) -> List[float]:
    """假 embedding：用词袋 hash 投影 — 验证 pipeline 通，但语义能力=0"""
    # 简单分词（中文按字，英文按词）
    tokens = []
    cur = ""
    for ch in text.lower():
        if "\u4e00" <= ch <= "\u9fff":
            if cur:
                tokens.append(cur)
                cur = ""
            tokens.append(ch)
        elif ch.isalnum():
            cur += ch
        else:
            if cur:
                tokens.append(cur)
                cur = ""
    if cur:
        tokens.append(cur)
    # hash 投影
    vec = [0.0] * dim
    for tok in tokens:
        h = int(hashlib.md5(tok.encode("utf-8")).hexdigest(), 16)
        idx = h % dim
        sign = 1.0 if (h // dim) % 2 == 0 else -1.0
        vec[idx] += sign
    # L2 归一化
    norm = math.sqrt(sum(x * x for x in vec))
    if norm > 0:
        vec = [x / norm for x in vec]
    return vec


# === 3. FTS5 搜索（复刻 Synapse 现有行为） ===
def fts5_search(query: str, limit: int = 5) -> List[int]:
    """跟 Synapse api.py 里 _fts_search 一样的逻辑"""
    conn = sqlite3.connect(str(DB_PATH))
    # 分词（同 Synapse: 去掉标点，按空格分）
    import re
    safe_q = re.sub(r"[^\w\s一-鿿]", "", query)
    terms = safe_q.strip().split()
    if not terms:
        return []
    match_expr = '"' + '" AND "'.join(terms) + '"'
    try:
        rows = conn.execute(
            "SELECT rowid FROM note_search WHERE note_search MATCH ? "
            "AND rowid IN (SELECT id FROM notes WHERE deleted_at IS NULL) "
            "ORDER BY rank LIMIT ?",
            (match_expr, limit)
        ).fetchall()
        return [r[0] for r in rows]
    except Exception as e:
        print(f"  ⚠️  FTS5 失败: {e}")
        # LIKE 回退
        like_q = f"%{query}%"
        rows = conn.execute(
            "SELECT id FROM notes WHERE deleted_at IS NULL AND (title LIKE ? OR content LIKE ?) LIMIT ?",
            (like_q, like_q, limit)
        ).fetchall()
        return [r[0] for r in rows]
    finally:
        conn.close()


# === 4. 暴力 numpy 搜索（复刻 Synapse 当前 vector_search.py） ===
def brute_force_search(query_vec: List[float], all_vecs: List[Tuple[int, List[float]]], limit: int = 5):
    """O(N) 余弦相似度"""
    q = np.array(query_vec)
    q = q / (np.linalg.norm(q) + 1e-10)
    scored = []
    for nid, vec in all_vecs:
        v = np.array(vec)
        v = v / (np.linalg.norm(v) + 1e-10)
        sim = float(np.dot(q, v))
        scored.append((nid, sim))
    scored.sort(key=lambda x: x[1], reverse=True)
    return scored[:limit]


# === 5. zvec 搜索（HNSW 索引） ===
def zvec_search(collection, query_vec: List[float], limit: int = 5):
    """用 zvec HNSW ANN 搜索"""
    result = collection.query(
        zvec.Query(
            field_name="embedding",
            vector=query_vec,
        ),
        topk=limit,
    )
    return [(d.id, getattr(d, "score", 0.0)) for d in result]


# === 6. Ground truth：人工标注 5 个查询的「应该返回的笔记 ID」 ===
# 基于 note 标题人工判断，对应"语义相关性"（不只是关键词命中）
GROUND_TRUTH = {
    "AI agent 或 AI 智能体": {
        "expected_ids": [1, 6, 7, 8, 32, 33],  # OpenClaw 入门/能力/小红书踩坑
        "description": "涉及 AI Agent / 智能体概念的笔记",
    },
    "OpenClaw 升级或升级踩坑": {
        "expected_ids": [13, 14, 32, 33],  # 升级+解决审批, 升级+通知权限, 小红书
        "description": "OpenClaw 升级相关的笔记",
    },
    "信创电脑或国产化运维": {
        "expected_ids": [9, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31],
        "description": "信创运维相关的笔记",
    },
    "代理或 mihomo 翻墙": {
        "expected_ids": [16, 17],  # mihomo 升级
        "description": "网络代理相关笔记",
    },
    "FTS5 全文搜索 vs 向量检索": {
        "expected_ids": [],  # 知识库里没有专门讲这个的
        "description": "查不到是预期的（验证空查询处理）",
    },
}


# === 7. 主流程 ===
def main():
    print("=" * 70)
    print("zvec 集成评估 prototype — Synapse 知识库")
    print("=" * 70)

    # 1. 加载笔记
    print("\n[1] 从 SQLite 加载笔记…")
    notes = load_notes(limit=100)
    print(f"    加载了 {len(notes)} 篇笔记")
    if len(notes) < 50:
        print(f"    ⚠️  笔记数偏少，建议至少 100 篇")

    # 2. 生成 embedding
    print("\n[2] 生成 embedding…")
    embeddings_real = []
    use_real = False
    real_dim = 0
    if SILICONFLOW_API_KEY:
        print(f"    尝试 SiliconFlow ({EMBEDDING_MODEL})…")
        # 先试一篇文章确认维度
        test_text = f"{notes[0]['title']}\n{notes[0]['content'][:500]}"
        test_vec = get_embedding_siliconflow(test_text, EMBEDDING_MODEL)
        if test_vec:
            use_real = True
            real_dim = len(test_vec)
            print(f"    ✅ 真实 embedding 可用，dim={real_dim}")
            for i, n in enumerate(notes):
                text = f"{n['title']}\n{n['content'][:1000]}"
                vec = get_embedding_siliconflow(text, EMBEDDING_MODEL)
                if vec:
                    embeddings_real.append((n["id"], vec))
                if (i + 1) % 20 == 0:
                    print(f"    [{i+1}/{len(notes)}] 完成")
                # 避免触发 rate limit
                time.sleep(0.1)
            print(f"    完成 {len(embeddings_real)}/{len(notes)} 篇真实 embedding")
        else:
            print(f"    ⚠️  BGE 失败，尝试降级到 {EMBEDDING_FALLBACK}")
            test_vec = get_embedding_siliconflow(test_text, EMBEDDING_FALLBACK)
            if test_vec:
                use_real = True
                real_dim = len(test_vec)
                print(f"    ✅ 降级成功，dim={real_dim}")
                for i, n in enumerate(notes):
                    text = f"{n['title']}\n{n['content'][:1000]}"
                    vec = get_embedding_siliconflow(text, EMBEDDING_FALLBACK)
                    if vec:
                        embeddings_real.append((n["id"], vec))
                    if (i + 1) % 20 == 0:
                        print(f"    [{i+1}/{len(notes)}] 完成")
                    time.sleep(0.1)
                print(f"    完成 {len(embeddings_real)}/{len(notes)} 篇真实 embedding")
            else:
                print(f"    ❌ 所有 SiliconFlow 模型都失败")

    if not use_real:
        print(f"    改用 hash 假 embedding (dim=128) — 验证 pipeline 通")
        for n in notes:
            text = f"{n['title']}\n{n['content'][:1000]}"
            vec = get_embedding_hash(text, dim=128)
            embeddings_real.append((n["id"], vec))
        real_dim = 128

    # 3. 写入 zvec
    print(f"\n[3] 写入 zvec 集合 (HNSW + COSINE, dim={real_dim})…")

    schema = zvec.CollectionSchema(
        name="synapse_notes",
        vectors=[
            zvec.VectorSchema(
                name="embedding",
                data_type=zvec.DataType.VECTOR_FP32,
                dimension=real_dim,
                index_param=zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE),
            ),
        ],
    )

    # 清理旧数据
    if ZVEC_PATH.exists():
        import shutil
        shutil.rmtree(ZVEC_PATH, ignore_errors=True)

    collection = zvec.create_and_open(path=str(ZVEC_PATH), schema=schema)
    docs = [
        zvec.Doc(id=str(nid), vectors={"embedding": vec})
        for nid, vec in embeddings_real
    ]
    t0 = time.time()
    collection.insert(docs)
    insert_time = time.time() - t0
    print(f"    ✅ 插入 {len(docs)} 个 doc，耗时 {insert_time:.2f}s")

    # optimize (构建 HNSW 索引)
    print("    调用 optimize() 构建 HNSW 索引…")
    t0 = time.time()
    collection.optimize()
    opt_time = time.time() - t0
    print(f"    ✅ optimize 耗时 {opt_time:.2f}s")

    # 4. 跑 5 个语义查询
    print(f"\n[4] 跑 5 个语义查询，对比 FTS5 vs zvec 召回率…")
    print("=" * 70)

    results = []
    for query, info in GROUND_TRUTH.items():
        expected = set(info["expected_ids"])
        print(f"\n📝 Query: 「{query}」")
        print(f"   期望命中: {sorted(expected) if expected else '(无)'}")

        # FTS5
        fts5_ids = set(fts5_search(query, limit=10))
        fts5_hit = expected & fts5_ids if expected else set()
        fts5_recall = len(fts5_hit) / len(expected) if expected else None
        print(f"   FTS5 top-10: {sorted(fts5_ids)[:10]}")
        print(f"   FTS5 命中: {sorted(fts5_hit)} ({len(fts5_hit)}/{len(expected)})" if expected else "   FTS5: 命中=N/A (无 ground truth)")

        # zvec
        q_text = query
        q_vec = (get_embedding_siliconflow(q_text, EMBEDDING_MODEL) or
                 get_embedding_siliconflow(q_text, EMBEDDING_FALLBACK) or
                 get_embedding_hash(q_text, dim=real_dim))
        if q_vec is None:
            print(f"   ❌ query embedding 失败，跳过")
            continue

        # zvec HNSW
        t0 = time.time()
        zvec_results = zvec_search(collection, q_vec, limit=10)
        zvec_time = (time.time() - t0) * 1000
        zvec_ids = set(int(d[0]) for d in zvec_results)
        zvec_hit = expected & zvec_ids if expected else set()
        zvec_recall = len(zvec_hit) / len(expected) if expected else None
        print(f"   zvec top-10: {sorted(zvec_ids)[:10]} ({zvec_time:.1f}ms)")
        print(f"   zvec 命中: {sorted(zvec_hit)} ({len(zvec_hit)}/{len(expected)})" if expected else "   zvec: 命中=N/A")

        # numpy 暴力（基线）
        t0 = time.time()
        bf_results = brute_force_search(q_vec, embeddings_real, limit=10)
        bf_time = (time.time() - t0) * 1000
        bf_ids = set(d[0] for d in bf_results)
        bf_hit = expected & bf_ids if expected else set()
        bf_recall = len(bf_hit) / len(expected) if expected else None
        print(f"   brute-force: {sorted(bf_ids)[:10]} ({bf_time:.1f}ms)")
        print(f"   brute 命中: {sorted(bf_hit)} ({len(bf_hit)}/{len(expected)})" if expected else "   brute: 命中=N/A")

        results.append({
            "query": query,
            "expected_count": len(expected),
            "fts5_hit": len(fts5_hit),
            "zvec_hit": len(zvec_hit),
            "bf_hit": len(bf_hit),
            "fts5_recall": fts5_recall,
            "zvec_recall": zvec_recall,
            "bf_recall": bf_recall,
            "zvec_time_ms": zvec_time,
            "bf_time_ms": bf_time,
            "fts5_ids": sorted(fts5_ids),
            "zvec_ids": sorted(zvec_ids),
            "bf_ids": sorted(bf_ids),
        })

    # 5. 性能对比 — 模拟 1000 / 10000 / 100000 规模
    print("\n" + "=" * 70)
    print("[5] 性能对比：zvec HNSW vs numpy 暴力搜索（当前实现）")
    print("=" * 70)

    if len(embeddings_real) >= 1:
        # 用真实 embedding 做 scaling test
        base_vecs = [v for _, v in embeddings_real]
        base_dim = len(base_vecs[0])

        # 复制扩展到 N 篇
        for N in [100, 1000, 10000]:
            if N > len(embeddings_real) * 100:
                # 重复采样
                vecs_n = [base_vecs[i % len(base_vecs)] for i in range(N)]
            else:
                vecs_n = base_vecs * (N // len(base_vecs) + 1)
                vecs_n = vecs_n[:N]

            # numpy 暴力
            t0 = time.time()
            q = np.array(q_vec)
            q = q / (np.linalg.norm(q) + 1e-10)
            mat = np.array(vecs_n)
            mat = mat / (np.linalg.norm(mat, axis=1, keepdims=True) + 1e-10)
            sims = mat @ q
            top10 = np.argsort(-sims)[:10]
            bf_t = (time.time() - t0) * 1000

            # zvec HNSW (新 collection 每次)
            test_path = Path(f"/tmp/zvec-perf-{N}")
            if test_path.exists():
                import shutil
                shutil.rmtree(test_path, ignore_errors=True)
            test_schema = zvec.CollectionSchema(
                name=f"perf_{N}",
                vectors=[
                    zvec.VectorSchema(
                        name="embedding",
                        data_type=zvec.DataType.VECTOR_FP32,
                        dimension=base_dim,
                        index_param=zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE),
                    ),
                ],
            )
            test_col = zvec.create_and_open(path=str(test_path), schema=test_schema)
            t0 = time.time()
            BATCH = 1024
            for start in range(0, N, BATCH):
                end = min(start + BATCH, N)
                test_col.insert([zvec.Doc(id=str(i), vectors={"embedding": v}) for i, v in enumerate(vecs_n[start:end], start=start)])
            test_col.optimize()
            build_t = time.time() - t0

            t0 = time.time()
            _ = test_col.query(zvec.Query(field_name="embedding", vector=q_vec), topk=10)
            zvec_t = (time.time() - t0) * 1000

            speedup = bf_t / zvec_t if zvec_t > 0 else float("inf")
            print(f"  N={N:>6}: numpy 暴力 {bf_t:>8.1f}ms | zvec HNSW {zvec_t:>6.1f}ms (build {build_t:.1f}s) | 加速 {speedup:>6.1f}x")

    # 6. 保存结果到 JSON
    output = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "embedding_model": EMBEDDING_MODEL if use_real else "hash-fake-128d",
        "embedding_dim": real_dim,
        "notes_count": len(notes),
        "queries": results,
    }
    out_path = DOCS_DIR / "zvec-eval-results.json"
    DOCS_DIR.mkdir(exist_ok=True)
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2))
    print(f"\n[6] 结果已保存到 {out_path}")

    # 总结
    print("\n" + "=" * 70)
    print("📊 总结")
    print("=" * 70)
    if results:
        fts5_recalls = [r["fts5_recall"] for r in results if r["fts5_recall"] is not None]
        zvec_recalls = [r["zvec_recall"] for r in results if r["zvec_recall"] is not None]
        if fts5_recalls and zvec_recalls:
            print(f"  FTS5 平均召回率: {sum(fts5_recalls)/len(fts5_recalls):.1%}")
            print(f"  zvec 平均召回率: {sum(zvec_recalls)/len(zvec_recalls):.1%}")
            improvement = (sum(zvec_recalls)/len(zvec_recalls)) - (sum(fts5_recalls)/len(fts5_recalls))
            print(f"  提升: {improvement:+.1%}")

    return output


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n⚠️  用户中断")
        sys.exit(1)