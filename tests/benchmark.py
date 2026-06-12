"""Synapse 后端性能基准测试

用法：
  1. 启动服务：cd backend && WIKI_API_TOKEN=t python3 -c "import uvicorn, api; uvicorn.run(api.app, host='127.0.0.1', port=19999)"
  2. 跑基准：PORT=19999 WIKI_API_TOKEN=t python3 tests/benchmark.py

对比：可通过 git checkout main~ -- backend/api.py backend/crud.py 来回滚
"""
import os
import sys
import time
import http.client
import json
import argparse

PORT = int(os.environ.get("PORT", "19999"))
TOKEN = os.environ.get("WIKI_API_TOKEN", "testtoken")
ROUNDS = int(os.environ.get("ROUNDS", "30"))


def req(path, headers=None):
    h = headers or {"Authorization": f"Bearer {TOKEN}"}
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", path, headers=h)
    r = c.getresponse()
    body = r.read()
    c.close()
    return r.status, body


def bench(path, n=ROUNDS, headers=None):
    h = headers or {"Authorization": f"Bearer {TOKEN}"}
    # 3 次 warmup
    for _ in range(3):
        req(path, h)
    times = []
    last_body = b""
    for _ in range(n):
        t0 = time.perf_counter()
        st, last_body = req(path, h)
        times.append((time.perf_counter() - t0) * 1000)
    times.sort()
    median = times[len(times) // 2]
    p95 = times[int(len(times) * 0.95)]
    size = len(last_body)
    return median, p95, size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=os.environ.get("PORT", PORT))
    ap.add_argument("--rounds", type=int, default=os.environ.get("ROUNDS", ROUNDS))
    args = ap.parse_args()

    port = args.port
    rounds = args.rounds
    token = os.environ.get("WIKI_API_TOKEN", TOKEN)

    endpoints = [
        ("/api/notes?limit=50", "全字段列表"),
        ("/api/notes?limit=50&fields=id,title,tags,summary,created_at,is_pinned", "瘦身列表（fields=）"),
        ("/api/notes?limit=50&fields=id,title", "极致瘦身"),
        ("/api/tags", "标签列表（60s 缓存）"),
        ("/api/notes?limit=50&tag=ai", "按标签过滤"),
        ("/api/graph", "知识图谱"),
        ("/api/overview", "总览（含孤立笔记扫描）"),
        ("/api/stats", "统计数据"),
        ("/api/folders", "分类列表"),
        ("/api/folders/1/notes", "某分类下的笔记"),
        ("/api/notes/1/relations", "笔记关联（无 wikilink）"),
    ]

    print(f"=== Synapse Benchmark (rounds={args.rounds}, port={port}) ===\n")
    print(f"{'描述':<28} {'中位 (ms)':>10} {'p95 (ms)':>10} {'响应 (B)':>10}  端点")
    print("-" * 110)
    for path, desc in endpoints:
        try:
            median, p95, size = bench(path, n=args.rounds)
            print(f"{desc:<28} {median:>10.1f} {p95:>10.1f} {size:>10d}  {path}")
        except Exception as e:
            print(f"{desc:<28}  ERROR: {e}")

    # GZip 测试
    print("\n=== GZip 对比 ===")
    path = "/api/notes?limit=50"
    h = {"Authorization": f"Bearer {token}", "Accept-Encoding": "gzip"}
    sizes = []
    for _ in range(5):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", path, headers=h)
        r = c.getresponse()
        body = r.read()
        c.close()
        sizes.append((r.getheader("Content-Encoding"), len(body)))
    enc, sz = max(set(sizes), key=lambda x: sizes.count(x))
    print(f"  {path}")
    print(f"    gzip  → {sz:>7d} B  ({enc})")
    print(f"    plain → {194186:>7d} B  (no compression)")
    if sz > 0:
        print(f"    节省  → {194186 - sz:>7d} B  ({(1 - sz / 194186) * 100:.1f}%)")


if __name__ == "__main__":
    main()
