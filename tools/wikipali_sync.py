#!/usr/bin/env python3
"""把 <vol>/chinese/ 下的译文和 wikipali 网站上的文章树对应起来。

目前只实现两步（设计见 doc/wikipali-sync-design.md）：
  match   -- 拉取 article-map，按 key 把每篇文章匹配到本地译文文件，
             写出 <vol>/chinese/_wikipali_map.tsv
  verify  -- 对 match 匹配上的条目，逐篇拉取正文，按"空行分段的每段行数"
             校验本地译文与 wikipali 正文占位符是否逐行(含空行)对应

不引入第三方库，只用标准库。

Usage:
  python3 tools/wikipali_sync.py match  vol_5 <collection_uuid>
  python3 tools/wikipali_sync.py verify vol_5 <collection_uuid> [--limit N] [--sleep 0.2]
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

API_BASE = "https://next.wikipali.org/api/v2"
USER_AGENT = "nibbana-gamini-patipada-wikipali-sync/1.0"

# 与 build_manifest.py / build_epub.py / translate_vol.sh 保持一致的通用 key 正则
KEY_RE = re.compile(r"^\s*(\[[^\]]+\][A-Za-z]?)")
# wikipali 标题里 key 前常带 "NGP-Vol5-" / "NGP-Vol-5-" 之类前缀，容器节点(level 1)则没有
TITLE_KEY_RE = re.compile(r"^(?:NGP-?Vol-?\d+-)?\s*(\[[^\]]+\][A-Za-z]?)")

MAP_HEADER = "article_id\tlevel\tchildren\tkey\ttitle\tlocal_path\tstatus\n"


def http_get_json(url, retries=2):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last_err = None
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.load(resp)
            break
        except urllib.error.URLError as e:
            last_err = e
            if attempt < retries:
                time.sleep(1)
    else:
        raise last_err
    if not data.get("ok", False):
        raise RuntimeError(f"API 返回 ok=false: {url} -> {data.get('message')}")
    return data["data"]


def fetch_article_map(collection_id):
    url = f"{API_BASE}/article-map?view=anthology&id={collection_id}"
    data = http_get_json(url)
    return data["rows"]


def fetch_article_content(article_id):
    url = f"{API_BASE}/article/{article_id}"
    data = http_get_json(url)
    return data.get("content", "")


def key_of_filename(filename):
    stem = filename[:-3] if filename.endswith(".md") else filename
    m = KEY_RE.match(stem)
    return m.group(1) if m else None


def key_of_title(title):
    m = TITLE_KEY_RE.match(title.strip())
    return m.group(1) if m else None


def build_local_index(vol):
    """扫描 <vol>/chinese/ 下所有正文 .md 文件，返回 key -> [路径,...]"""
    chinese_dir = os.path.join(vol, "chinese")
    index = {}
    for dirpath, _dirnames, filenames in os.walk(chinese_dir):
        for fn in filenames:
            if fn.startswith("_") or not fn.endswith(".md"):
                continue
            key = key_of_filename(fn)
            if key is None:
                continue
            index.setdefault(key, []).append(os.path.join(dirpath, fn))
    return index


def do_match(vol, collection_id):
    rows = fetch_article_map(collection_id)
    local_index = build_local_index(vol)

    out_rows = []
    n_matched = n_unmatched = n_parse_fail = n_dup_local = 0
    for r in rows:
        title = r["title"]
        key = key_of_title(title)
        if key is None:
            status = "parse_fail"
            local_path = ""
            n_parse_fail += 1
        else:
            candidates = local_index.get(key, [])
            if len(candidates) == 1:
                status = "matched"
                local_path = candidates[0]
                n_matched += 1
            elif len(candidates) > 1:
                status = "dup_local"
                local_path = ";".join(candidates)
                n_dup_local += 1
            else:
                status = "unmatched"
                local_path = ""
                n_unmatched += 1
        out_rows.append((
            r["article_id"], str(r["level"]), str(r["children"]),
            key or "", title, local_path, status,
        ))

    out_path = os.path.join(vol, "chinese", "_wikipali_map.tsv")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(MAP_HEADER)
        for row in out_rows:
            f.write("\t".join(row) + "\n")

    print(f"article-map 共 {len(rows)} 行 -> {out_path}")
    print(f"  matched={n_matched}  unmatched={n_unmatched}  "
          f"parse_fail={n_parse_fail}  dup_local={n_dup_local}")
    if n_unmatched:
        print("  未匹配(可能是容器节点，正文在带字母后缀的子文章里，属预期):")
        for row in out_rows:
            if row[6] == "unmatched":
                print(f"    {row[3]}\t{row[4]}")
    if n_parse_fail:
        print("  标题解析不出 key(需人工核对 wikipali 标题):")
        for row in out_rows:
            if row[6] == "parse_fail":
                print(f"    {row[4]}")
    if n_dup_local:
        print("  本地 key 重复(需人工消歧):")
        for row in out_rows:
            if row[6] == "dup_local":
                print(f"    {row[3]}\t{row[5]}")
    return out_rows


def load_map(vol):
    path = os.path.join(vol, "chinese", "_wikipali_map.tsv")
    if not os.path.exists(path):
        sys.exit(f"找不到 {path}，请先跑 match 子命令")
    rows = []
    with open(path, encoding="utf-8") as f:
        next(f)  # header
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln:
                continue
            rows.append(ln.split("\t"))
    return rows


def blank_separated_block_lengths(text):
    """按空行分段，返回每段的非空行数列表。"""
    lines = text.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    blocks = []
    cur = 0
    for line in lines:
        if line.strip() == "":
            if cur > 0:
                blocks.append(cur)
            cur = 0
        else:
            cur += 1
    if cur > 0:
        blocks.append(cur)
    return blocks


def non_blank_lines(text):
    lines = text.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    return [ln for ln in lines if ln.strip() != ""]


PLACEHOLDER_RE = re.compile(r"\{\{[^}]*\}\}")


def do_verify(vol, collection_id, limit, sleep_sec, show_pairs):
    rows = load_map(vol)
    matched = [r for r in rows if r[6] == "matched"]
    if limit:
        matched = matched[:limit]

    n_ok = n_mismatch = n_error = 0
    for i, row in enumerate(matched):
        article_id, _level, _children, key, title, local_path, _status = row
        try:
            content = fetch_article_content(article_id)
        except (urllib.error.URLError, RuntimeError) as e:
            n_error += 1
            print(f"✗ {key}\t{title}\t抓取失败: {e}")
            continue

        local_text = open(local_path, encoding="utf-8").read()
        remote_blocks = blank_separated_block_lengths(content)
        local_blocks = blank_separated_block_lengths(local_text)

        if remote_blocks == local_blocks:
            n_ok += 1
            print(f"✓ {key}\t{title}\t{len(local_blocks)} 段对齐")
            if show_pairs:
                remote_lines = non_blank_lines(content)
                local_lines = non_blank_lines(local_text)
                for j in range(min(show_pairs, len(remote_lines))):
                    tags = " ".join(PLACEHOLDER_RE.findall(remote_lines[j])) or remote_lines[j][:40]
                    txt = local_lines[j].strip()
                    if len(txt) > 40:
                        txt = txt[:40] + "…"
                    print(f"      {tags}  ->  {txt}")
        else:
            n_mismatch += 1
            print(f"✗ {key}\t{title}")
            print(f"    wikipali {len(remote_blocks)} 段: {remote_blocks}")
            print(f"    本地译文 {len(local_blocks)} 段: {local_blocks}")
            n = min(len(remote_blocks), len(local_blocks))
            for j in range(n):
                if remote_blocks[j] != local_blocks[j]:
                    print(f"    第一处不同: 第 {j+1} 段, "
                          f"wikipali={remote_blocks[j]} 行, 本地={local_blocks[j]} 行")
                    break

        if sleep_sec and i < len(matched) - 1:
            time.sleep(sleep_sec)

    print(f"\n共校验 {len(matched)} 篇: OK={n_ok}  MISMATCH={n_mismatch}  抓取失败={n_error}")
    return n_mismatch == 0 and n_error == 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_match = sub.add_parser("match", help="按 key 匹配 article-map 与本地译文")
    p_match.add_argument("vol", help="如 vol_5")
    p_match.add_argument("collection_id", help="wikipali anthology 的 uuid")

    p_verify = sub.add_parser("verify", help="校验匹配上的文章是否逐行(含空行)对应")
    p_verify.add_argument("vol")
    p_verify.add_argument("collection_id")
    p_verify.add_argument("--limit", type=int, default=0, help="只校验前 N 篇(0=全部)")
    p_verify.add_argument("--sleep", type=float, default=0.2, help="每次请求间隔秒数")
    p_verify.add_argument("--show-pairs", type=int, default=0,
                           help="对齐成功时，额外打印前 N 行 占位符<->译文 的逐行样例")

    args = ap.parse_args()
    vol = args.vol.rstrip("/")

    if args.cmd == "match":
        do_match(vol, args.collection_id)
    elif args.cmd == "verify":
        ok = do_verify(vol, args.collection_id, args.limit, args.sleep, args.show_pairs)
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
