#!/usr/bin/env bash
# 通用·逐文件批量翻译某一卷（缅->中），自包含(不依赖 translate_status.py)。
# 串行处理全部待译文件: 每个由 `claude -p` 翻译并立即写盘, 随后 check_lines 复核
# 逐行对齐。可中断后重跑(断点续译)。全卷译完后(可选)自动生成 epub。
#
# key 兼容各卷命名: vol_5 字母在括号外 [93]a, vol_1 字母在括号内 [186a], vol_4 [000A]。
# 键冲突组(同目录同 [页码] 有多个不同源文件, 如 vol_4): 用 _produced.tsv 记录
#   源->目标 映射逐一判重, 避免同键多文件互相覆盖/漏译。非冲突键行为不变。
#
# 用法:  tools/translate_vol.sh vol_1
#        OVERWRITE=1 tools/translate_vol.sh vol_1     # 已存在也重译
#        LIMIT=20    tools/translate_vol.sh vol_1     # 本次最多处理 20 个
#        BUILD_EPUB=0 tools/translate_vol.sh vol_1    # 译完不自动生成 epub
#
# 进度/日志写入  <vol>/chinese/_batch_translate.log
# 注意: 只新起 `claude -p` 子进程, 从不 kill 任何进程, 不影响 pali-translab。
set -uo pipefail

ROOT="/mnt/visuddhinanda/workspace/nibbana-gamini-patipada"
cd "$ROOT" || exit 1

VOL="${1:?用法: translate_vol.sh <vol_1|vol_5|...>}"
MANIFEST="$VOL/chinese/_manifest.tsv"
LOG="$VOL/chinese/_batch_translate.log"
INSTR="$VOL/chinese/_TRANSLATE_INSTRUCTIONS.md"
PRODUCED="$VOL/chinese/_produced.tsv"   # 键冲突组: 源路径<TAB>目标路径
PER_FILE_TIMEOUT="${PER_FILE_TIMEOUT:-1800}"
LIMIT="${LIMIT:-0}"
OVERWRITE="${OVERWRITE:-0}"
BUILD_EPUB="${BUILD_EPUB:-1}"
WAIT_ON_LIMIT="${WAIT_ON_LIMIT:-0}"   # 1=撞配额时等待重试(不停止)
LIMIT_WAIT="${LIMIT_WAIT:-1800}"      # 等待秒数
NSHARD="${NSHARD:-1}"                 # 分片总数(并行进程数); 1=不分片
SHARD="${SHARD:-0}"                   # 本进程分片号 [0, NSHARD)
# 分片按 (treldir,key) 的确定性哈希: 同一冲突组必落同一分片, 组内串行无竞争

[ -f "$MANIFEST" ] || { echo "找不到 manifest: $MANIFEST" >&2; exit 1; }
[ -f "$INSTR" ]    || { echo "找不到翻译指令: $INSTR" >&2; exit 1; }

log() { echo "$*" | tee -a "$LOG"; }

# 通用 key 正则: 兼容 [93]a/[186a]/[000A]/[က]/[11] 等各卷命名
PYKEY='import re; KEY=re.compile(r"^\s*(\[[^\]]+\][A-Za-z]?)")'

# 公共: 载入键冲突组集合与 _produced 映射, 并定义 is_done(源级, 冲突组感知)
PYCOMMON='
from collections import Counter
def _load(manifest, produced_path):
    rows=[]; cnt=Counter()
    for ln in open(manifest, encoding="utf-8"):
        ln=ln.rstrip("\n")
        if not ln or ln.startswith("#"): continue
        c=ln.split("\t"); rows.append(c); cnt[(c[1],c[2])]+=1
    coll={kk for kk,n in cnt.items() if n>1}
    prod={}; produced_exists=os.path.exists(produced_path)
    if produced_exists:
        for ln in open(produced_path, encoding="utf-8"):
            ln=ln.rstrip("\n")
            if not ln: continue
            p=ln.split("\t")
            if len(p)>=2: prod[p[0]]=p[1]
    return rows, coll, prod, produced_exists
def _is_done(src, treldir, key, chroot, coll, prod, produced_exists):
    tdir=os.path.join(chroot, treldir) if treldir else chroot
    # 冲突组判重仅在该卷存在 _produced.tsv 时启用; 否则(旧卷)一律按 key 扫描, 行为不变
    if produced_exists and (treldir,key) in coll:   # 冲突组: 按 源->目标 映射
        t=prod.get(src); return bool(t and os.path.exists(t))
    if not os.path.isdir(tdir): return False
    return any(f.endswith(".md") and k(f)==key for f in os.listdir(tdir))
'

# 列出某卷全部"待译"源路径(按 page 排序), 每行一个
list_pending() {
  python3 - "$VOL" "$MANIFEST" "$PRODUCED" "${NSHARD:-1}" "${SHARD:-0}" <<PY
import os, sys, re, hashlib
$PYKEY
def k(n):
    m = KEY.match(n); return m.group(1) if m else None
$PYCOMMON
vol, manifest, produced = sys.argv[1], sys.argv[2], sys.argv[3]
nshard, shard = int(sys.argv[4]), int(sys.argv[5])
chroot = os.path.join(vol, "chinese")
def in_shard(c):
    if nshard <= 1: return True
    h = int(hashlib.md5((c[1] + "\t" + c[2]).encode("utf-8")).hexdigest(), 16)
    return h % nshard == shard
rows, coll, prod, pe = _load(manifest, produced)
rows = [c for c in rows if in_shard(c) and not _is_done(c[0], c[1], c[2], chroot, coll, prod, pe)]
rows.sort(key=lambda c: (int(c[3]) if c[3].isdigit() else 0, c[0]))
for c in rows:
    print(c[0])
PY
}

# 判断单个源是否已译完(循环内跳过判断; 冲突组感知)
is_done_src() {  # $1=src -> 打印 "1" 表示已完成
  python3 - "$VOL" "$MANIFEST" "$PRODUCED" "$1" <<PY
import os, sys, re
$PYKEY
def k(n):
    m = KEY.match(n); return m.group(1) if m else None
$PYCOMMON
vol, manifest, produced, src = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
chroot = os.path.join(vol, "chinese")
rows, coll, prod, pe = _load(manifest, produced)
row = next((c for c in rows if c[0]==src), None)
if row and _is_done(row[0], row[1], row[2], chroot, coll, prod, pe):
    print("1")
PY
}

# 列出目标目录中所有与 key 匹配的已写文件路径(每行一个, 已排序)
found_all() {  # $1=tdir $2=key
  python3 - "$1" "$2" <<PY
import os, sys, re
$PYKEY
tdir, key = sys.argv[1], sys.argv[2]
def k(n):
    m = KEY.match(n); return m.group(1) if m else None
if os.path.isdir(tdir):
    for f in sorted(os.listdir(tdir)):
        if f.endswith(".md") and k(f) == key:
            print(os.path.join(tdir, f))
PY
}

# 在目标目录找与 key 对应的已写文件(返回第一个或空)
found_target() { found_all "$1" "$2" | head -n1; }

# 是否为键冲突组成员(同 treldir+key 有多个源) -> 打印 "1"
is_collision() {  # $1=treldir $2=key
  python3 - "$MANIFEST" "$1" "$2" <<PY
import sys
from collections import Counter
manifest, treldir, key = sys.argv[1], sys.argv[2], sys.argv[3]
cnt=Counter()
for ln in open(manifest, encoding="utf-8"):
    ln=ln.rstrip("\n")
    if not ln or ln.startswith("#"): continue
    c=ln.split("\t"); cnt[(c[1],c[2])]+=1
if cnt[(treldir,key)]>1: print("1")
PY
}

# 冲突组: 相对 before 快照, 找出新出现的 key 匹配文件(本源的目标)
new_target() {  # $1=tdir $2=key $3=before快照文件
  python3 - "$1" "$2" "$3" <<PY
import os, sys, re
$PYKEY
tdir, key, snap = sys.argv[1], sys.argv[2], sys.argv[3]
def k(n):
    m = KEY.match(n); return m.group(1) if m else None
before=set()
if os.path.exists(snap):
    before=set(l.rstrip("\n") for l in open(snap, encoding="utf-8"))
cur=[]
if os.path.isdir(tdir):
    for f in sorted(os.listdir(tdir)):
        if f.endswith(".md") and k(f)==key:
            cur.append(os.path.join(tdir,f))
new=[p for p in cur if p not in before]
print(new[0] if new else "")
PY
}

mapfile -t PENDING < <(list_pending)
total=${#PENDING[@]}
log "[$(date '+%F %T')] === 批量翻译 $VOL 开始：待译 $total 个 (timeout=${PER_FILE_TIMEOUT}s LIMIT=$LIMIT OVERWRITE=$OVERWRITE) ==="

done_cnt=0 ok=0 warn=0 fail=0 LIMIT_HIT=0
for src in "${PENDING[@]}"; do
  [ "$LIMIT" -gt 0 ] && [ "$done_cnt" -ge "$LIMIT" ] && { log "达到 LIMIT=$LIMIT, 停止本次。"; break; }
  done_cnt=$((done_cnt+1))

  row=$(awk -F'\t' -v s="$src" '$1==s{print; exit}' "$MANIFEST")
  if [ -z "$row" ]; then log "[$done_cnt/$total] ⚠ manifest 无此源, 跳过: $src"; warn=$((warn+1)); continue; fi
  treldir=$(printf '%s' "$row" | cut -f2)
  key=$(printf '%s'     "$row" | cut -f3)
  eng=$(printf '%s'     "$row" | cut -f5)
  subset=$(printf '%s'  "$row" | cut -f6)
  if [ -n "$treldir" ]; then tdir="$VOL/chinese/$treldir"; else tdir="$VOL/chinese"; fi
  mkdir -p "$tdir"

  if [ "$OVERWRITE" != "1" ]; then
    if [ -n "$(is_done_src "$src")" ]; then log "[$done_cnt/$total] ⏭ 已存在跳过 key=$key"; continue; fi
  fi

  # 冲突组: 记录翻译前的 key 匹配文件快照, 译后据此认定本源新产出的目标
  coll_member=$(is_collision "$treldir" "$key")
  before_snap=""
  if [ -n "$coll_member" ]; then before_snap=$(mktemp); found_all "$tdir" "$key" > "$before_snap"; fi

  log "[$done_cnt/$total] ▶ $(date '+%T') 翻译 key=$key  $src"

  prompt="你是把帕奥西亚多《去向涅槃之道》从缅文逐行翻译成简体中文的翻译器。

第一步: 用 Read 读 ${INSTR} 并严格遵循其中【全部】规则。

只翻译这一个源文件(底本=缅文, 逐句逐行译):
  ${src}

把译文用 Write 工具写入目录:
  ${tdir}/
目标文件名 = 把上面源文件名译成中文, 并【原样保留开头的方括号 [页码] 前缀(如 [186a]/[002a]/[000A]/[035], 一字不差)】, 文件名内不加巴利。同目录若已有同页码前缀的其它文件, 请按本源标题另取不同的中文文件名, 不要覆盖它们。

辅助材料:
  英文参考(仅帮助理解长难句, 禁止直译英文): ${eng}
  术语子集(pali->中文, 有则用表中用词): ${subset}
  勘误表(其中错误条目不采用, 用正确译法): glossary/errata.tsv

硬性要求: 逐行对齐——中文文件行数必须与源文件完全相同, 中文第N行=源第N行的译文, 源空行↔中文空行位置完全一致, 禁止合并/拆分/折行/增删空行; 术语首现写「中文(pali)」其后仅用中文; 纯巴利句/行只给罗马转写不翻译; 书名固定《去向涅槃之道》; 保留 markdown 标记。

写完后【必须】运行:
  python3 tools/check_lines.py \"${src}\" \"<你写的目标文件>\"
若不是逐行对齐就修正并重写, 直到 check_lines 显示 ✓。
不要 commit, 不要翻译其它文件, 不要输出多余说明。"

  while :; do
    tmpout=$(mktemp)
    if timeout "$PER_FILE_TIMEOUT" claude -p "$prompt" --dangerously-skip-permissions >"$tmpout" 2>&1; then rc=0; else rc=$?; fi
    if grep -qiE 'session limit|usage limit|hit your .*limit|rate.?limit' "$tmpout"; then
      rm -f "$tmpout"
      if [ "$WAIT_ON_LIMIT" = "1" ]; then
        log "[$done_cnt/$total] ⏳ $(date '+%T') 撞配额/限流, 等待 ${LIMIT_WAIT}s 后重试同一文件…"
        sleep "$LIMIT_WAIT"
        continue
      fi
      log "[$done_cnt/$total] ⛔ 撞配额/限流, 停止本次(已译保留, 配额恢复后重跑续译)。"
      LIMIT_HIT=1
      [ -n "$before_snap" ] && rm -f "$before_snap"
      break 2
    fi
    cat "$tmpout" >>"$LOG"; rm -f "$tmpout"
    [ "$rc" != "0" ] && log "[$done_cnt/$total] ⚠ claude 退出码非0 (key=$key), 继续后验。"
    break
  done

  # 认定本源目标: 冲突组用 before/after 差集; 非冲突组按 key 找
  if [ -n "$coll_member" ]; then
    tgt=$(new_target "$tdir" "$key" "$before_snap")
    rm -f "$before_snap"
    [ -n "$tgt" ] && printf '%s\t%s\n' "$src" "$tgt" >> "$PRODUCED"
  else
    tgt=$(found_target "$tdir" "$key")
  fi

  if [ -z "$tgt" ]; then
    log "[$done_cnt/$total] ✗ 未写出译文 key=$key"; fail=$((fail+1)); continue
  fi
  if python3 tools/check_lines.py "$src" "$tgt" >/dev/null 2>&1; then
    log "[$done_cnt/$total] ✓ 完成且逐行对齐: $(basename "$tgt")"; ok=$((ok+1))
  else
    log "[$done_cnt/$total] ⚠ 已写出但行数不齐, 需重译: $(basename "$tgt")"; warn=$((warn+1))
  fi
done

remain=$(NSHARD=1 SHARD=0 list_pending | wc -l)   # 全卷剩余(不分片), 供 epub 触发与日志
shard_note=""; [ "$NSHARD" -gt 1 ] && shard_note=" [分片 $SHARD/$NSHARD]"
hit_note=""; [ "$LIMIT_HIT" = "1" ] && hit_note=" (因配额停止)"
log "[$(date '+%F %T')] === 结束$hit_note$shard_note: 本次 ✓$ok ⚠$warn ✗$fail。 $VOL 剩余待译 $remain ==="

if [ "$BUILD_EPUB" = "1" ] && [ "$remain" -eq 0 ]; then
  log "[$(date '+%F %T')] 全卷译完, 生成 epub …"
  python3 tools/build_epub.py "$VOL" >>"$LOG" 2>&1 && log "epub 生成完成。" || log "⚠ epub 生成失败, 见日志。"
fi
