# 译文上传 wikipali 设计文档

目标：把 `<vol>/chinese/` 下已翻译好的 markdown 文件，对应到 wikipali 站点
(`next.wikipali.org`) 上事先建好的文章树（anthology），最终把译文内容写入
对应文章。**本文档记录整体设计，目前脚本 `tools/wikipali_sync.py` 只实现了
"匹配" 与 "校验" 两步，尚未做真正的上传/写入。**

## 背景 API

- 文章树（anthology 下所有文章标题、层级、article_id）：
  `GET https://next.wikipali.org/api/v2/article-map?view=anthology&id=<collection_uuid>`
  返回 `data.rows`，每行形如：
  ```json
  {"article_id": "9826ed28-...", "level": 2, "children": 0,
   "title": "NGP-Vol5-[1]c ကလာပသမ္မသန ခေါ် နယဝိပဿနာ", ...}
  ```
  - `level` 是文章树深度（1 = 卷内一级章节容器，2/3 = 更深层级），不是"是否有正文"的标志。
  - `children` > 0 表示该行是"容器"节点（对应本地一个子目录），仍可能有自己的正文页
    （例：`[1]b` 既是容器，也有一篇很短的正文 `[1]b 道非道智见清净释 - 思惟.md`）。
  - `children` == 0 是叶子文章，一定有正文。

- 单篇文章正文：
  `GET https://next.wikipali.org/api/v2/article/<article_id>`
  返回 `data.content`（`content_type` 为 `markdown` 的**字符串**，不是数组）。
  内容形如：
  ```
  {{3013-1-11-11}}

  {{3013-2-11-11}}

  {{3013-3-11-11}}
  {{3013-3-21-21}}
  {{3013-3-31-31}}
  ```
  每个 `{{...}}` 是一个"句子占位符"（未来上传译文时，大概率是按占位符逐句回填）。
  空行分隔段落；同一段落内可能有多行占位符（对应译文里同一段落被人工拆成多个短句）。

## 匹配算法（第一步，`match` 子命令）

1. 从 `_manifest.tsv`/其它工具沿用的通用 key 正则（与 `build_manifest.py`
   / `build_epub.py` / `translate_vol.sh` 一致，避免行为分裂）：
   ```
   KEY_RE = r"^\s*(\[[^\]]+\][A-Za-z]?)"
   ```
   对本地文件名（去掉目录、`.md` 后缀）取开头的 `[页码]字母` 作为 key，
   例如 `[1]c 聚思惟即理观.md` → key = `[1]c`。

2. 递归扫描 `<vol>/chinese/` 下所有 `*.md`（跳过下划线开头的脚手架文件如
   `_manifest.tsv`、`_TRANSLATE_INSTRUCTIONS.md` 等），建立 `key -> [本地路径,...]`
   索引。正常情况下每个 key 只对应一个文件；如果对应多个（见"已知坑"），
   该 key 标记为 `本地重复`，交给人工/`_produced.tsv` 消歧（目前 vol_5 没有
   `_produced.tsv`，视为该卷暂无冲突）。

3. wikipali 标题里 key 前常带前缀 `NGP-Vol<N>-`（level 1 容器节点没有此前缀，
   直接以 `[key]` 开头）。用
   ```
   TITLE_KEY_RE = r"^(?:NGP-?Vol-?\d+-)?\s*(\[[^\]]+\][A-Za-z]?)"
   ```
   先剥前缀再取 key。

4. 用 key 去本地索引里查，查到即为匹配；查不到 / 标题解析不出 key，都记为
   未匹配，原样列出供人工核对，不做猜测性模糊匹配。

5. 结果写入 `<vol>/chinese/_wikipali_map.tsv`：
   `article_id  level  children  key  title  local_path  status`
   （`status` ∈ `matched` / `unmatched` / `dup_local` / `parse_fail`）。

### 已知边界情况（vol_5 实测，484 行里 472 匹配）

- **标题本身有笔误**：个别标题缺开头 `[`（如 `133] ဒုက္ခအခြင်းအရာ`），
  `TITLE_KEY_RE` 匹配不到 key，归为 `parse_fail`，需要人工在 wikipali 后台改标题。
- **标题用位置后缀而非字母后缀**：个别标题是 `NGP-Vol-5[330]-1` /
  `NGP-Vol-5[330]-2` 这种"同一 key 后面挂 `-1`/`-2`"，而本地对应文件其实是
  `[330]a` / `[330]b`（字母后缀）。这种命名不一致目前也归为 `parse_fail`，
  不做"猜测 -1→a、-2→b"的自动映射，避免匹配错行。
- **容器节点本身不对应正文文件**：某些 `children>0` 的行（如 `[210]`、
  `[343]`、`[349]`、`[463]`）在本地只是一个目录（`[343]省察随观智章/`），
  真正的正文是目录下带字母后缀的第一篇（`[343]a 省察随观智章.md`）。这类行
  会落入 `unmatched`，这是预期行为，不是 bug——它们不需要单独的正文，未来
  上传时应跳过或仅用于建目录层级。
- **本地 key 重复**：vol_5 里 `[135]` 同时对应两个文件（`[135]所谓百年.md`
  与 `[135]二、以衰老坏灭而观的方法.md`），需人工消歧（可能是源文件拆分时
  译者忘记按 `[nnn]a`/`[nnn]b` 规范命名）。

## 校验算法（第二步，`verify` 子命令）

目的：确认"本地译文"与"wikipali 正文占位符"是逐行对应的——即本地译文里
空行分隔出的每一段，行数要和 wikipali 正文里对应段落的占位符行数完全一致。
逐字符对应无法验证（wikipali 侧是句子编号，不是中文原文），但**结构对齐**
（段落数、每段行数、空行位置）可以验证，这也是未来"按占位符顺序回填译文"
能不能对上的前提。

算法（对 `match` 阶段产出的每个 `matched` 条目）：

1. `GET /api/v2/article/<article_id>`，取 `data.content`（markdown 字符串），
   按 `\n` 切行，去掉结尾的空行残留。
2. 读本地译文文件，同样按 `\n` 切行。
3. 两边各自按"空行分段"，得到每段的**非空行数**列表，例如
   `[1, 1, 3, 2, 1, 1, 1, 2, ...]`。
4. 比较两个列表是否完全相等：
   - 相等 → `OK`（段数、每段行数都对上，等价于"行数、空行都能对应上"）。
   - 不等 → `MISMATCH`，报告出第一处不同的段号、两边的行数，便于人工去看
     具体是本地译文分段有问题，还是 wikipali 占位符结构有问题。

已用 `NGP-Vol5-[1]c ကလာပသမ္မသန ခေါ် နယဝိပဿနာ`
(article_id `9826ed28-ea01-476f-b103-6c18a2bcf747`) 实测：
两边都是 34 段，`[1,1,3,2,1,1,1,2,1,1,1,1,3,6,1,1,1,25,1,3,1,1,3,2,7,8,1,2,1,1,1,6,3,5]`，
完全一致。

## 尚未实现（留给后续修改）

- 真正把译文内容按占位符顺序回填、调用写入/更新接口上传到 wikipali（需要
  确认认证方式、写接口路径、占位符与译文行的具体回填规则——一行一句还是
  一段一句，是否需要保留 `**粗体**`/巴利罗马转写等 markdown 语法）。
- `parse_fail` / 本地 key 重复 / 容器节点未匹配 这几类边界情况的人工消歧
  或半自动修复流程。

## CLI 用法

```bash
# 第一步：匹配 + 落地 <vol>/chinese/_wikipali_map.tsv
python3 tools/wikipali_sync.py match vol_5 22ae16b4-68b3-4403-b155-ede40c509c7e

# 第二步：校验行数/空行是否逐行对应（默认对 match 产出里全部 matched 条目跑一遍）
python3 tools/wikipali_sync.py verify vol_5 22ae16b4-68b3-4403-b155-ede40c509c7e

# 校验时可加 --limit 先抽查几篇，或 --sleep 调整请求间隔（默认 0.2s，避免打太快）
python3 tools/wikipali_sync.py verify vol_5 22ae16b4-68b3-4403-b155-ede40c509c7e --limit 20
```

不引入第三方库，只用标准库 `urllib.request` 发请求。
