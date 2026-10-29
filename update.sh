#!/usr/bin/env bash
# ============================================================================
#  GitHub 上游同步 + OpenWrt 插件包版本/哈希自动维护
#
#  两层能力：
#    A. sources —— 同步上游源码（如 luci-app-passwall / openwrt-passwall-packages）
#                   支持多个上游仓库，可按目录挑选，上游 commit 变化才重新拉取
#    B. packages —— 在本地包 Makefile 上自动更新版本号 / 校验值
#                   三种策略：
#                     tarball : 源码包，自动 PKG_VERSION + PKG_HASH
#                     assets  : 预编译资源 / 多架构二进制 / geodata，逐个算 hash
#                     notify  : 只提醒上游有新版（源码内嵌或 git-commit 型，不自动改）
#
#  用法：
#    bash update.sh                      # 全量：同步源码 + 更新版本哈希
#    bash update.sh --dry-run            # 只检查不修改、不推送
#    bash update.sh --force              # 忽略缓存状态，强制重新拉取/重算
#    bash update.sh --only xray-core     # 只处理指定的 source 或 package 名
#    bash update.sh --skip-source        # 只跑 packages
#    bash update.sh --skip-packages      # 只跑 sources
#    bash update.sh --sync-source        # 只跑 sources（别名）
#
#  环境变量（推送可选）：
#    GITHUB_TOKEN          GitHub API Token（强烈建议，提升速率限制）
#    TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID
#    WXPUSHER_APP_TOKEN / WXPUSHER_UIDS / WXPUSHER_TOPIC_IDS
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

# ------------------------- 命令行参数 -------------------------
CONFIG_FILE="config/packages.json"
STATE_DIR=".state"
DRY_RUN=false
FORCE=false
ONLY=""
SKIP_SOURCE=false
SKIP_PACKAGES=false
STRICT=false

usage() {
  cat <<'USAGE'
用法: bash update.sh [选项]

选项:
  -c, --config <file>   配置文件路径（默认: config/packages.json）
  -o, --only <name>     只处理指定的 source / package 名
  -f, --force           忽略缓存状态，强制重新拉取源码、重算哈希
  -n, --dry-run         只检查，不修改文件、不推送通知
      --skip-source     跳过上游源码同步
      --skip-packages   跳过版本/哈希更新
      --sync-source     只做上游源码同步（= --skip-packages）
      --strict          有包失败就以非 0 退出（默认只告警，不影响整次同步）
  -h, --help            显示本帮助

配置文件格式见 config/packages.json 与 README.md。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)        CONFIG_FILE="${2:?--config 需要一个路径}"; shift 2 ;;
    -o|--only)          ONLY="${2:?--only 需要一个名字}"; shift 2 ;;
    -f|--force)         FORCE=true; shift ;;
    -n|--dry-run)       DRY_RUN=true; shift ;;
    --skip-source)      SKIP_SOURCE=true; shift ;;
    --skip-packages)    SKIP_PACKAGES=true; shift ;;
    --sync-source)      SKIP_PACKAGES=true; shift ;;
    --strict)           STRICT=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "[错误] 未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

# ------------------------- 依赖检查 -------------------------
for bin in curl jq sed grep awk tar mktemp; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "[错误] 缺少依赖命令: $bin" >&2
    exit 1
  }
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[错误] 找不到配置文件: $CONFIG_FILE" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

# ------------------------- 基础工具 -------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { echo "[错误] $*" >&2; exit 1; }

# GitHub API 请求
gh_api() {
  local url="$1"
  local args=(-sL --retry 3 --retry-delay 2 --connect-timeout 20
              -H "Accept: application/vnd.github+json"
              -H "X-GitHub-Api-Version: 2022-11-28"
              -H "User-Agent: github-release-monitor")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${args[@]}" "$url"
}

# 从配置里取字段（支持默认值）
#   cfg_get <json-file> <jq-path> [default]
cfg_get() {
  local file="$1" path="$2" default="${3-}"
  local val
  val=$(jq -r "${path} | if . == null then empty else tostring end" "$file" 2>/dev/null)
  if [[ -z "$val" || "$val" == "null" ]]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# 数组元素数量
cfg_len() { jq -r "$2 // [] | length" "$1" 2>/dev/null || echo 0; }

# 从 tag 推导版本号
#   输出：version[\trelease]
#   version_regex 为 bash 正则：第 1 个捕获组 = 版本，第 2 个捕获组（可选）= PKG_RELEASE
derive_version() {
  local tag="$1" prefix="$2" regex="$3"
  if [[ -n "$regex" ]]; then
    if [[ "$tag" =~ $regex ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      if [[ -n "${BASH_REMATCH[2]:-}" ]]; then printf '\t%s' "${BASH_REMATCH[2]}"; fi
    fi
  elif [[ -n "$prefix" ]]; then
    printf '%s' "${tag#"$prefix"}"
  else
    printf '%s' "$tag"
  fi
}

# 版本号比较：返回 0=相等  1=a>b  2=a<b
# 点分段逐段数字比较，遇到非数字段则退化为字符串比较
ver_cmp() {
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then return 0; fi

  local IFS='.'
  local -a pa=() pb=()
  read -ra pa <<< "$a"
  read -ra pb <<< "$b"

  local max=${#pa[@]}
  if (( ${#pb[@]} > max )); then max=${#pb[@]}; fi

  local i x y
  for ((i = 0; i < max; i++)); do
    x="${pa[i]:-0}"
    y="${pb[i]:-0}"
    if [[ ! "$x" =~ ^[0-9]+$ || ! "$y" =~ ^[0-9]+$ ]]; then
      if [[ "$a" == "$b" ]]; then return 0; fi
      if [[ "$a" > "$b" ]]; then return 1; fi
      return 2
    fi
    if (( 10#$x > 10#$y )); then return 1; fi
    if (( 10#$x < 10#$y )); then return 2; fi
  done
  return 0
}

# 候选版本是否严格“更新”于基线
#   is_newer <candidate> <baseline>   → 0=是  1=否
is_newer() {
  local cand="$1" base="$2"
  if [[ -z "$cand" ]]; then return 1; fi
  if [[ -z "$base" ]]; then return 0; fi   # 本地没有版本号，视为需要更新
  local rc=0
  ver_cmp "$cand" "$base" || rc=$?
  if [[ "$rc" -eq 1 ]]; then return 0; fi
  return 1
}

# 模板替换：${REPO} ${TAG} ${VERSION} ${RELEASE} ${ASSET} 以及 $(PKG_VERSION)
expand_tpl() {
  local s="$1" repo="$2" tag="$3" version="$4" asset="$5" release="${6-}"
  s="${s//\$\{REPO\}/$repo}"
  s="${s//\$\{TAG\}/$tag}"
  s="${s//\$\{VERSION\}/$version}"
  s="${s//\$\{RELEASE\}/$release}"
  s="${s//\$\{ASSET\}/$asset}"
  s="${s//\$(PKG_VERSION)/$version}"
  printf '%s' "$s"
}

# 计算 SHA256（兼容 macOS 的 shasum）
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# 下载文件到临时路径，输出 <sha256>\t<size>
download_and_hash() {
  local url="$1" tmp
  tmp=$(mktemp)
  if ! curl -sL --fail --retry 3 --retry-delay 2 \
       --connect-timeout 20 --max-time 600 \
       -A "github-release-monitor" -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
  local sha size
  sha=$(file_sha256 "$tmp")
  size=$(wc -c < "$tmp" | tr -d '[:space:]')
  rm -f "$tmp"
  printf '%s\t%s' "$sha" "$size"
}

human_size() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$bytes"
  else
    echo "${bytes}B"
  fi
}

# ------------------------- Makefile 改写工具 -------------------------
# 判断是否存在 <var>:= 行
has_var_line() {
  local file="$1" var="$2"
  grep -qE "^[[:space:]]*${var}[[:space:]]*[:?+]?=" "$file"
}

# 替换/追加一行 <var>:=<value>
# 替换变量赋值行（只改第一处，避免误伤后续的 $(subst) 派生式）
#   保留原有缩进，只换 = 右侧的值；不存在则追加一行
replace_var_line() {
  local file="$1" var="$2" value="$3"
  local tmp
  tmp=$(mktemp)
  awk -v v="$var" -v nv="$value" '
    BEGIN { done = 0 }
    {
      if (!done && match($0, "^[ \t]*" v "[ \t]*[:?+]?=")) {
        print substr($0, 1, RLENGTH) nv
        done = 1
        next
      }
      print
    }
  ' "$file" > "$tmp"
  if ! grep -qE "^[[:space:]]*${var}[[:space:]]*[:?+]?=" "$file"; then
    printf '%s:=%s\n' "$var" "$value" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

# 读取变量值
read_var_line() {
  local file="$1" var="$2"
  sed -nE "s/^[[:space:]]*${var}[[:space:]]*[:?+]?=[[:space:]]*//p" "$file" | head -n1
}

# 读取“包含 anchor 的那一行”里 <var> 的值（如 GEOIP_VER、PKG_VERSION）
read_anchor_var() {
  local file="$1" anchor="$2" var="$3"
  grep -F "$anchor" "$file" 2>/dev/null | head -n1 \
    | sed -nE "s/.*${var}[[:space:]]*[:?+]?=[[:space:]]*//p"
}

# 是否为可比较的字面量版本号（排除 $(...) / ${...} 这类 Makefile 派生式）
is_literal_ver() {
  local v="$1"
  [[ -n "$v" ]] || return 1
  [[ "$v" == *'$'* ]] && return 1
  [[ "$v" == *'('* || "$v" == *')'* ]] && return 1
  return 0
}

# 版本闸门：上游版本不高于本地则应忽略同步
#   should_skip_sync <上游版本> <本地版本> <skip_if_not_newer>
#   返回 0=应忽略  1=应同步
should_skip_sync() {
  local up="$1" loc="$2" gate="$3"
  if [[ "$gate" != "true" ]]; then return 1; fi
  is_literal_ver "$up"   || return 1   # 上游是派生式/空 → 无法比较，放行
  is_literal_ver "$loc"  || return 1
  if is_newer "$up" "$loc"; then return 1; fi
  return 0
}

# 源码同步的版本闸门（多版本变量）
#   比较两个 Makefile 里一组版本变量（如 PKG_VERSION / GEOIP_VER / GEOSITE_VER）：
#     · 只要有一个上游值严格更新 → 同步
#     · 所有可比变量都不更高 → 忽略
#     · 一个可比的都没有 → 同步（无法判定时保守放行）
#   should_skip_source <上游Makefile> <本地Makefile> <gate> <变量列表,换行分隔>
#   返回 0=应忽略  1=应同步
should_skip_source() {
  local upfile="$1" locfile="$2" gate="$3" vars="$4"
  if [[ "$gate" != "true" ]]; then return 1; fi
  if [[ ! -f "$upfile" || ! -f "$locfile" ]]; then return 1; fi

  local compared=0 newer=0 v uv lv
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    uv=$(read_var_line "$upfile" "$v")
    lv=$(read_var_line "$locfile" "$v")
    # 只比较字面量版本号，跳过 $(...) / ${...} 派生式
    is_literal_ver "$uv" || continue
    is_literal_ver "$lv" || continue
    compared=$((compared + 1))
    if is_newer "$uv" "$lv"; then newer=$((newer + 1)); fi
  done <<< "$vars"

  if [[ "$compared" -eq 0 ]]; then return 1; fi
  if [[ "$newer" -gt 0 ]]; then return 1; fi
  return 0
}

# 用字面量 anchor 定位块，替换其后第一条 <hash_var>:= 行
replace_hash_after_anchor() {
  local file="$1" anchor="$2" hash_var="$3" newhash="$4"
  local tmp
  tmp=$(mktemp)
  awk -v anchor="$anchor" -v hv="$hash_var" -v nh="$newhash" '
    {
      if (index($0, anchor) > 0) { pending = 1; print; next }
      # 保留原有缩进（只换 = 右侧的值）
      if (pending && match($0, "^[ \t]*" hv "[ \t]*[:?+]?=")) {
        print substr($0, 1, RLENGTH) nh
        pending = 0
        next
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# 用字面量 anchor 定位行，整行替换为 newline（支持 ${VERSION} 等占位）
replace_line_after_anchor() {
  local file="$1" anchor="$2" newline="$3"
  local tmp
  tmp=$(mktemp)
  awk -v anchor="$anchor" -v nl="$newline" '
    BEGIN { done = 0 }
    {
      if (!done && index($0, anchor) > 0) { print nl; done = 1; next }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ------------------------- 状态记录 -------------------------
write_state() {
  local file="$1" payload="$2"
  printf '%s\n' "$payload" > "$file"
}

# ============================================================================
#  A. 上游源码同步
# ============================================================================
SOURCE_CHANGED=0

sync_source() {
  local idx="$1"
  local cfg="$CONFIG_FILE"

  local name repo ref target
  name=$(cfg_get "$cfg" ".sources[$idx].name")
  repo=$(cfg_get "$cfg" ".sources[$idx].repo")
  ref=$(cfg_get "$cfg" ".sources[$idx].ref" "main")
  target=$(cfg_get "$cfg" ".sources[$idx].target" ".")

  [[ -z "$name" || -z "$repo" ]] && { log "[跳过] sources[$idx] 缺少 name / repo"; return 1; }

  log "────────────────────────────────────────"
  log "[源码] ${name}  ←  ${repo}@${ref}"

  # ---------- 1. 取上游 commit ----------
  local sha=""
  local info
  if info=$(gh_api "https://api.github.com/repos/${repo}/commits/${ref}" 2>/dev/null); then
    sha=$(printf '%s' "$info" | jq -r '.sha // empty' 2>/dev/null || echo "")
  fi

  local state_file="${STATE_DIR}/source-${name}.json"
  if [[ "$FORCE" != "true" && -f "$state_file" && -n "$sha" ]]; then
    local last
    last=$(jq -r '.sha // empty' "$state_file" 2>/dev/null || echo "")
    if [[ -n "$last" && "$last" == "$sha" ]]; then
      log "[源码] ${name} 上游无变化 (commit ${sha:0:12})，跳过"
      return 0
    fi
  fi

  # ---------- 2. 下载上游 tarball ----------
  local url="https://codeload.github.com/${repo}/tar.gz/${ref}"
  local tmp_tar
  tmp_tar=$(mktemp --suffix=.tar.gz)
  log "[源码] 下载 ${url}"
  if ! curl -sL --fail --retry 3 --retry-delay 2 \
       --connect-timeout 20 --max-time 300 \
       -A "github-release-monitor" -o "$tmp_tar" "$url"; then
    log "[失败] 上游源码下载失败: ${url}"
    rm -f "$tmp_tar"
    return 1
  fi

  # ---------- 3. 解压 ----------
  local work
  work=$(mktemp -d)
  if ! tar xzf "$tmp_tar" -C "$work" --strip-components=1 2>/dev/null; then
    log "[失败] 上游源码解压失败"
    rm -rf "$work" "$tmp_tar"
    return 1
  fi
  rm -f "$tmp_tar"

  # ---------- 4. 挑选目录 ----------
  local dirs_json exclude_json as_pkg
  as_pkg=$(cfg_get "$cfg" ".sources[$idx].as_package" "false")
  if [[ "$as_pkg" == "true" ]]; then
    dirs_json='["*"]'   # 整棵树就是一个包 → 顶层全部条目
  else
    dirs_json=$(jq -c ".sources[$idx].dirs // [\"*\"]" "$CONFIG_FILE")
  fi
  exclude_json=$(jq -c ".sources[$idx].exclude // []" "$CONFIG_FILE")

  # items = 上游里的源路径，dests = 落地时用的目录名（支持 "src=>dst" 显式改名，
  # 不写 => 则取 basename；上游里包可能嵌套在子目录，如 dae-box 的 openwrt/dae-box）
  local items=()
  local dests=()
  add_item() {
    local e="$1" src dst
    if [[ "$e" == *'=>'* ]]; then
      src="${e%%=>*}"; dst="${e##*=>}"
    else
      src="$e"; dst="${e##*/}"
    fi
    [[ -e "$work/$src" ]] || { log "[警告] 上游没有 $src，跳过"; return 0; }
    items+=("$src"); dests+=("$dst")
  }

  if printf '%s' "$dirs_json" | jq -e 'index("*")' >/dev/null 2>&1; then
    # "*" = 顶层全部条目，排除 exclude
    while IFS= read -r e; do
      add_item "$e"
    done < <(cd "$work" && ls -1A | while IFS= read -r e; do
      printf '%s' "$exclude_json" | jq -e --arg x "$e" 'index($x)' >/dev/null 2>&1 || printf '%s\n' "$e"
    done)
  else
    while IFS= read -r e; do
      add_item "$e"
    done < <(printf '%s' "$dirs_json" | jq -r '.[]')
  fi

  if [[ ${#items[@]} -eq 0 ]]; then
    log "[失败] ${name} 没有匹配到任何目录（检查 dirs / exclude）"
    rm -rf "$work"
    return 1
  fi

  # ---------- 5. 落地 ----------
  # as_package=true：上游整棵树就是一个 OpenWrt 包，全部落到 target 目录内，
  #                 先清空 target 保证上游删除的文件不残留
  # as_package=false：每个条目落到 target/<条目>
  local gate ver_vars
  gate=$(cfg_get "$cfg" ".sources[$idx].skip_if_not_newer" "true")
  ver_vars=$(jq -r ".sources[$idx].version_vars // [\"PKG_VERSION\",\"PKG_UPSTREAM_VERSION\",\"GEOIP_VER\",\"GEOSITE_VER\"] | .[]" "$CONFIG_FILE" 2>/dev/null)
  local changed=0
  local copied=()
  local ignored=()
  local it dst gate_up gate_loc

  # as_package：整包先判一次版本闸门，**确定要同步才清空 target**，
  # 否则会先删本地再判定跳过，等于丢数据
  if [[ "$as_pkg" == "true" ]]; then
    gate_up="$work/Makefile"
    gate_loc="$target/Makefile"
    if [[ "$FORCE" != "true" ]] && should_skip_source "$gate_up" "$gate_loc" "$gate" "$ver_vars"; then
      local cmp_desc="" vv uu ll
      while IFS= read -r vv; do
        [[ -z "$vv" ]] && continue
        uu=$(read_var_line "$gate_up" "$vv")
        ll=$(read_var_line "$gate_loc" "$vv")
        [[ -z "$uu" && -z "$ll" ]] && continue
        is_literal_ver "$uu" || continue
        is_literal_ver "$ll" || continue
        cmp_desc+="${cmp_desc:+ }${vv}=${uu:-?}/${ll:-?}"
      done <<< "$ver_vars"
      log "[源码] ${name} 上游版本不高于本地（${cmp_desc:-无可比变量}），忽略同步"
      ignored+=("$name")
      rm -rf "$work"
      write_state "$state_file" "$(jq -n \
        --arg name "$name" --arg repo "$repo" --arg ref "$ref" --arg sha "$sha" \
        --arg target "$target" --argjson copied '[]' --argjson ignored "[\"$name\"]" \
        --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{name:$name,repo:$repo,ref:$ref,sha:$sha,target:$target,copied:$copied,ignored:$ignored,updated_at:$updated_at}')"
      return 0
    fi
    if [[ "$DRY_RUN" != "true" ]]; then
      rm -rf "$target"   # 只有确定要同步才清空
    fi
  fi

  local _i=0
  for it in "${items[@]}"; do
    local dname="${dests[$_i]}"
    _i=$((_i + 1))
    [[ -e "$work/$it" ]] || { log "[警告] 上游没有 ${it}，跳过"; continue; }

    dst="${target}/${dname}"
    gate_up="$work/$it/Makefile"
    gate_loc="$dst/Makefile"

    # 版本闸门（非 as_package 时逐条目判定）
    if [[ "$FORCE" != "true" && "$as_pkg" != "true" ]]; then
      if should_skip_source "$gate_up" "$gate_loc" "$gate" "$ver_vars"; then
        local cmp_desc="" vv uu ll
        while IFS= read -r vv; do
          [[ -z "$vv" ]] && continue
          uu=$(read_var_line "$gate_up" "$vv")
          ll=$(read_var_line "$gate_loc" "$vv")
          [[ -z "$uu" && -z "$ll" ]] && continue
          is_literal_ver "$uu" || continue
          is_literal_ver "$ll" || continue
          cmp_desc+="${cmp_desc:+ }${vv}=${uu:-?}/${ll:-?}"
        done <<< "$ver_vars"
        log "[源码] ${dname} 上游版本不高于本地（${cmp_desc:-无可比变量}），忽略同步"
        ignored+=("$dname")
        continue
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "[dry-run] 将同步 ${repo}/${it} → ${dst}"
      copied+=("$dname")
      changed=1
      continue
    fi

    rm -rf "$dst"
    mkdir -p "$target"
    cp -a "$work/$it" "$dst"
    copied+=("$dname")
    changed=1
    log "[源码] 已同步 ${dst}${it:+  (来自 ${it})}"
  done
  rm -rf "$work"

  # ---------- 6. 状态 & 通知 ----------
  local payload
  payload=$(jq -n \
    --arg name "$name" --arg repo "$repo" --arg ref "$ref" \
    --arg sha "$sha" --arg target "$target" \
    --argjson copied "$(printf '%s\n' "${copied[@]:-}" | jq -R . | jq -s -c 'map(select(length>0))')" \
    --argjson ignored "$(printf '%s\n' "${ignored[@]:-}" | jq -R . | jq -s -c 'map(select(length>0))')" \
    --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{name:$name, repo:$repo, ref:$ref, sha:$sha, target:$target, copied:$copied, ignored:$ignored, updated_at:$updated_at}')
  write_state "$state_file" "$payload"

  if [[ "$changed" == "1" ]]; then
    SOURCE_CHANGED=$((SOURCE_CHANGED + 1))
    if [[ "$DRY_RUN" != "true" ]]; then
      local title body
      title="📦 上游源码已同步: ${name}"
      body=$(cat <<EOF
上游: ${repo}@${ref}
Commit: ${sha:-unknown}
同步到: ${target}/
条目: ${copied[*]:-}
忽略: ${ignored[*]:-（无）}

时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF
)
      notify "$title" "$body"
    fi
  fi

  return 0
}

run_sources() {
  local total
  total=$(cfg_len "$CONFIG_FILE" ".sources")
  if [[ "$total" -eq 0 ]]; then
    log "[源码] 配置中没有 sources，跳过"
    return 0
  fi
  local ok=0 fail=0
  for ((i = 0; i < total; i++)); do
    local sname
    sname=$(cfg_get "$CONFIG_FILE" ".sources[$i].name")
    if [[ -n "$ONLY" && "$sname" != "$ONLY" ]]; then continue; fi
    if sync_source "$i"; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
  done
  log "[源码] 汇总: 成功 ${ok} / 失败 ${fail}"
  return 0
}

# ============================================================================
#  B. 版本 / 哈希更新
# ============================================================================

# ---------- 策略 1: tarball（源码包，自动 PKG_VERSION + PKG_HASH）----------
strategy_tarball() {
  local idx="$1"
  local cfg="$CONFIG_FILE"

  local name repo makefile source include_pre tag_prefix version_regex reset_release src_tpl
  name=$(cfg_get "$cfg" ".packages[$idx].name")
  repo=$(cfg_get "$cfg" ".packages[$idx].repo")
  makefile=$(cfg_get "$cfg" ".packages[$idx].makefile" "${name}/Makefile")
  source=$(cfg_get "$cfg" ".packages[$idx].source" "release")
  include_pre=$(cfg_get "$cfg" ".packages[$idx].include_prerelease" "true")
  tag_prefix=$(cfg_get "$cfg" ".packages[$idx].tag_prefix" "")
  version_regex=$(cfg_get "$cfg" ".packages[$idx].version_regex" "")
  reset_release=$(cfg_get "$cfg" ".packages[$idx].reset_release_on_change" "false")
  src_tpl=$(cfg_get "$cfg" ".packages[$idx].source_url" "")

  [[ -f "$makefile" ]] || { log "[失败] 找不到 Makefile: ${makefile}"; return 1; }

  local tag
  if ! tag=$(fetch_latest_tag "$repo" "$source" "$include_pre"); then
    # 拿不到版本信息不视为致命错误，否则一个仓库挂了会拖掉整次同步
    log "[warn] ${name}: ${repo} 无可跟踪版本，跳过"
    LAST_ACTION="skipped"
    return 0
  fi

  local raw_ver release
  raw_ver=$(derive_version "$tag" "$tag_prefix" "$version_regex")
  version="${raw_ver%%$'\t'*}"
  release="${raw_ver#*$'\t'}"
  [[ "$release" == "$raw_ver" ]] && release=""

  [[ -n "$version" ]] || { log "[失败] 无法从 tag 「${tag}」推导版本号"; return 1; }

  # 版本/哈希写入哪两个变量（默认 PKG_VERSION / PKG_HASH）
  # 例：VIKINGYFY 的 sing-box 用 PKG_UPSTREAM_VERSION，PKG_VERSION 由 $(subst) 派生不能碰
  local ver_var hash_var
  ver_var=$(cfg_get "$cfg" ".packages[$idx].version_var" "PKG_VERSION")
  hash_var=$(cfg_get "$cfg" ".packages[$idx].hash_var" "PKG_HASH")

  local cur_version cur_hash
  cur_version=$(read_var_line "$makefile" "$ver_var")
  cur_hash=$(read_var_line "$makefile" "$hash_var")

  log "[tarball] ${name}: tag=${tag} → ${ver_var}=${version}"
  log "[tarball] 当前 Makefile: ${ver_var}=${cur_version:-<空>}"

  if [[ "$FORCE" != "true" ]]; then
    # 版本闸门：上游版本不高于本地 → 忽略同步（不降级、不重复拉取）
    if should_skip_sync "$version" "$cur_version" "$(cfg_get "$cfg" ".packages[$idx].skip_if_not_newer" "true")"; then
      log "[tarball] ${name} 上游版本 ${version} 不高于本地 ${cur_version}，忽略同步"
      LAST_ACTION="skipped"
      return 0
    fi
    # 同版本但本地缺哈希，仍需补算
    if [[ "$cur_version" == "$version" && -n "$cur_hash" ]]; then
      log "[tarball] ${name} 已是最新，跳过"
      LAST_ACTION="skipped"
      return 0
    fi
  fi

  [[ -n "$src_tpl" ]] || src_tpl='https://codeload.github.com/${REPO}/tar.gz/${TAG}'
  local url
  url=$(expand_tpl "$src_tpl" "$repo" "$tag" "$version" "")

  log "[tarball] 下载 ${url}"
  local hs sha size
  if ! hs=$(download_and_hash "$url"); then
    log "[失败] 下载失败: ${url}"
    return 1
  fi
  sha="${hs%%$'\t'*}"; size="${hs#*$'\t'}"
  log "[tarball] ${hash_var}=${sha}  ($(human_size "$size"))"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] ${makefile} → ${ver_var}=${version}, ${hash_var}=${sha}"
    LAST_ACTION="updated"
    return 0
  fi

  replace_var_line "$makefile" "$ver_var" "$version"
  replace_var_line "$makefile" "$hash_var" "$sha"
  if [[ -n "$release" ]]; then
    replace_var_line "$makefile" "PKG_RELEASE" "$release"
  elif [[ "$reset_release" == "true" ]] && has_var_line "$makefile" "PKG_RELEASE"; then
    replace_var_line "$makefile" "PKG_RELEASE" "1"
  fi
  log "[tarball] 已更新 ${makefile}"

  write_state "${STATE_DIR}/pkg-${name}.json" "$(jq -n \
    --arg name "$name" --arg repo "$repo" --arg tag "$tag" --arg version "$version" \
    --arg hash "$sha" --arg url "$url" --arg strategy "tarball" \
    --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{name:$name,repo:$repo,tag:$tag,version:$version,hash:$hash,source_url:$url,strategy:$strategy,updated_at:$updated_at}')"

  notify "🚀 新 Release: ${repo} ${tag}" "$(cat <<EOF
包名: ${name}
仓库: ${repo}
版本: ${tag}  →  ${ver_var}:=${version}
大小: $(human_size "$size")
时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

下载: ${url}

PKG_HASH:
${sha}
EOF
)"

  LAST_ACTION="updated"
  return 0
}

# ---------- 策略 2: assets（预编译资源 / 多架构二进制 / geodata）----------
strategy_assets() {
  local idx="$1"
  local cfg="$CONFIG_FILE"

  local name makefile
  name=$(cfg_get "$cfg" ".packages[$idx].name")
  makefile=$(cfg_get "$cfg" ".packages[$idx].makefile" "${name}/Makefile")

  [[ -f "$makefile" ]] || { log "[失败] 找不到 Makefile: ${makefile}"; return 1; }

  # ---------- 包级版本（可选）----------
  local pkg_ver="" pkg_rel="" vtag=""
  local vrepo vsource vpre vprefix vregex
  vrepo=$(cfg_get "$cfg" ".packages[$idx].version.repo")
  if [[ -n "$vrepo" ]]; then
    vsource=$(cfg_get "$cfg" ".packages[$idx].version.source" "release")
    vpre=$(cfg_get "$cfg" ".packages[$idx].version.include_prerelease" "true")
    vprefix=$(cfg_get "$cfg" ".packages[$idx].version.tag_prefix" "")
    vregex=$(cfg_get "$cfg" ".packages[$idx].version.version_regex" "")
    local vraw
    if ! vtag=$(fetch_latest_tag "$vrepo" "$vsource" "$vpre"); then
      log "[warn] ${name}: ${vrepo} 无可跟踪版本，跳过"
      LAST_ACTION="skipped"
      return 0
    fi
    vraw=$(derive_version "$vtag" "$vprefix" "$vregex")
    pkg_ver="${vraw%%$'\t'*}"
    pkg_rel="${vraw#*$'\t'}"
    [[ "$pkg_rel" == "$vraw" ]] && pkg_rel=""
    log "[assets] ${name}: 上游 ${vrepo} tag=${vtag} → 版本=${pkg_ver}${pkg_rel:+ (PKG_RELEASE=${pkg_rel})}"
  fi

  # ---------- 包级版本闸门 ----------
  local ver_var2
  ver_var2=$(cfg_get "$cfg" ".packages[$idx].version_var" "PKG_VERSION")
  if [[ "$FORCE" != "true" && -n "$pkg_ver" ]]; then
    local gate pkg_cur
    gate=$(cfg_get "$cfg" ".packages[$idx].skip_if_not_newer" "true")
    pkg_cur=$(read_var_line "$makefile" "$ver_var2")
    if should_skip_sync "$pkg_ver" "$pkg_cur" "$gate"; then
      log "[assets] ${name} 上游版本 ${pkg_ver} 不高于本地 ${pkg_cur}，忽略同步"
      LAST_ACTION="skipped"
      return 0
    fi
  fi

  local changed=0
  local summary=()

  # ---------- 逐个资源 ----------
  local n_assets
  n_assets=$(cfg_len "$cfg" ".packages[$idx].assets")
  if [[ "$n_assets" -eq 0 ]]; then
    log "[警告] ${name} 没有配置 assets"
    return 0
  fi

  for ((j = 0; j < n_assets; j++)); do
    local p=".packages[$idx].assets[$j]"
    local aid anchor url_tpl hash_var ver_anchor ver_line aasset
    aid=$(cfg_get "$cfg" "$p.id")
    anchor=$(cfg_get "$cfg" "$p.anchor")
    url_tpl=$(cfg_get "$cfg" "$p.url")
    hash_var=$(cfg_get "$cfg" "$p.hash_var" "PKG_HASH")
    aasset=$(cfg_get "$cfg" "$p.asset" "$aid")
    ver_anchor=$(cfg_get "$cfg" "$p.ver_anchor")
    ver_line=$(cfg_get "$cfg" "$p.ver_line")

    # 资源可自带版本来源
    local a_ver="$pkg_ver" a_tag="$vtag" a_rel="$pkg_rel"
    local a_repo a_src a_pre a_prefix a_regex
    a_repo=$(cfg_get "$cfg" "$p.version.repo")
    if [[ -n "$a_repo" ]]; then
      a_src=$(cfg_get "$cfg" "$p.version.source" "release")
      a_pre=$(cfg_get "$cfg" "$p.version.include_prerelease" "true")
      a_prefix=$(cfg_get "$cfg" "$p.version.tag_prefix" "")
      a_regex=$(cfg_get "$cfg" "$p.version.version_regex" "")
      if ! a_tag=$(fetch_latest_tag "$a_repo" "$a_src" "$a_pre"); then
        log "[warn] ${name}/${aid}: 无可跟踪版本，跳过该资源"
        continue
      fi
      local a_raw
      a_raw=$(derive_version "$a_tag" "$a_prefix" "$a_regex")
      a_ver="${a_raw%%$'\t'*}"
      a_rel="${a_raw#*$'\t'}"
      [[ "$a_rel" == "$a_raw" ]] && a_rel=""
    fi

    [[ -n "$anchor" && -n "$url_tpl" ]] || { log "[警告] ${name}/${aid} 缺少 anchor / url"; continue; }
    [[ -n "$a_ver" ]] || { log "[警告] ${name}/${aid} 无法确定版本号"; continue; }

    # ---------- 单资源版本闸门（针对 GEOIP_VER 这类独立版本变量）----------
    if [[ "$FORCE" != "true" && -n "$ver_anchor" ]]; then
      local a_cur
      a_cur=$(read_anchor_var "$makefile" "$ver_anchor" "${ver_anchor%%:*}")
      if should_skip_sync "$a_ver" "$a_cur" "$(cfg_get "$cfg" ".packages[$idx].skip_if_not_newer" "true")"; then
        log "[assets] ${name}/${aid} 上游版本 ${a_ver} 不高于本地 ${a_cur}，忽略该资源"
        continue
      fi
    fi

    local url
    url=$(expand_tpl "$url_tpl" "${a_repo:-}" "$a_tag" "$a_ver" "$aasset" "$a_rel")
    log "[assets] ${name}/${aid}: 版本=${a_ver} 下载 ${url}"

    local hs sha size
    if ! hs=$(download_and_hash "$url"); then
      log "[失败] ${name}/${aid} 下载失败: ${url}"
      continue
    fi
    sha="${hs%%$'\t'*}"; size="${hs#*$'\t'}"
    log "[assets]   → ${hash_var}=${sha}  ($(human_size "$size"))"

    local old
    old=$(sed -nE "s/.*${hash_var}[[:space:]]*[:?+]?=[[:space:]]*//p" "$makefile" | head -n1)

    if [[ "$DRY_RUN" == "true" ]]; then
      log "[dry-run] ${makefile}: 在「${anchor}」后写入 ${hash_var}:=${sha}"
    else
      replace_hash_after_anchor "$makefile" "$anchor" "$hash_var" "$sha"
    fi

    # 版本变量（如 GEOIP_VER / PKG_VERSION）
    if [[ -n "$ver_anchor" && -n "$ver_line" ]]; then
      local expanded
      expanded=$(expand_tpl "$ver_line" "${a_repo:-}" "$a_tag" "$a_ver" "$aasset" "$a_rel")
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] ${makefile}: 在「${ver_anchor}」处写入 ${expanded}"
      else
        replace_line_after_anchor "$makefile" "$ver_anchor" "$expanded"
      fi
    fi

    summary+=("${aid}=${a_ver}")
    if [[ "$old" != "$sha" ]]; then changed=1; fi
  done

  # 包级版本变量 / PKG_RELEASE
  if [[ -n "$pkg_ver" ]]; then
    local cur
    cur=$(read_var_line "$makefile" "$ver_var2")
    if [[ "$cur" != "$pkg_ver" ]]; then changed=1; fi
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[dry-run] ${makefile} → ${ver_var2}:=${pkg_ver}"
    else
      replace_var_line "$makefile" "$ver_var2" "$pkg_ver"
    fi

    # 版本正则第 2 捕获组 = PKG_RELEASE
    if [[ -n "$pkg_rel" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] ${makefile} → PKG_RELEASE:=${pkg_rel}"
      else
        replace_var_line "$makefile" "PKG_RELEASE" "$pkg_rel"
      fi
    fi
  fi

  write_state "${STATE_DIR}/pkg-${name}.json" "$(jq -n \
    --arg name "$name" --arg version "$pkg_ver" \
    --argjson details "$(printf '%s\n' "${summary[@]:-}" | jq -R . | jq -s -c 'map(select(length>0))')" \
    --arg strategy "assets" --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{name:$name,version:$version,details:$details,strategy:$strategy,updated_at:$updated_at}')"

  if [[ "$changed" == "1" ]]; then
    if [[ "$DRY_RUN" != "true" ]]; then
      notify "🔄 依赖已更新: ${name}" "$(cat <<EOF
包名: ${name}
策略: assets（多资源校验值）
版本: ${pkg_ver:-<不变>}

资源:
$(printf '  - %s\n' "${summary[@]:-}")

时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF
)"
    fi
    LAST_ACTION="updated"
  else
    log "[assets] ${name} 无变化"
    LAST_ACTION="skipped"
  fi
  return 0
}

# ---------- 策略 3: notify（只提醒，不自动改）----------
strategy_notify() {
  local idx="$1"
  local cfg="$CONFIG_FILE"

  local name repo source include_pre tag_prefix version_regex makefile note
  name=$(cfg_get "$cfg" ".packages[$idx].name")
  repo=$(cfg_get "$cfg" ".packages[$idx].repo")
  source=$(cfg_get "$cfg" ".packages[$idx].source" "release")
  include_pre=$(cfg_get "$cfg" ".packages[$idx].include_prerelease" "true")
  tag_prefix=$(cfg_get "$cfg" ".packages[$idx].tag_prefix" "")
  version_regex=$(cfg_get "$cfg" ".packages[$idx].version_regex" "")
  makefile=$(cfg_get "$cfg" ".packages[$idx].makefile" "${name}/Makefile")
  note=$(cfg_get "$cfg" ".packages[$idx].note" "")

  # 未配置上游仓库：由 source 同步维护，只登记一笔
  if [[ -z "$repo" ]]; then
    log "[notify] ${name}: 无轮询上游（${note:-由上游源码同步维护}）"
    LAST_ACTION="skipped"
    return 0
  fi

  local tag
  if ! tag=$(fetch_latest_tag "$repo" "$source" "$include_pre"); then
    log "[warn] ${name}: ${repo} 无可跟踪的 ${source}，跳过"
    LAST_ACTION="skipped"
    return 0
  fi

  local raw_ver version
  raw_ver=$(derive_version "$tag" "$tag_prefix" "$version_regex")
  version="${raw_ver%%$'\t'*}"

  # 设了 version_regex 却没命中（如 gecoosac 的 ^gecoosac-(.+)$ 碰上 apk-packages-arm64）
  # 不要把错误版本写进状态/推送
  if [[ -n "$version_regex" && -z "$version" ]]; then
    log "[warn] ${name}: tag ${tag} 不匹配 version_regex ${version_regex}，跳过"
    LAST_ACTION="skipped"
    return 0
  fi

  local cur=""
  [[ -f "$makefile" ]] && cur=$(read_var_line "$makefile" "PKG_VERSION")

  log "[notify] ${name}: 上游 ${repo} tag=${tag} → 版本=${version}  (本地: ${cur:-<无>})"

  # 版本闸门：上游版本不高于本地 → 忽略
  if [[ "$FORCE" != "true" ]] \
     && should_skip_sync "$version" "$cur" "$(cfg_get "$cfg" ".packages[$idx].skip_if_not_newer" "true")"; then
    log "[notify] ${name} 上游版本 ${version} 不高于本地 ${cur}，忽略"
    LAST_ACTION="skipped"
    return 0
  fi

  local state_file="${STATE_DIR}/pkg-${name}.json"
  local last
  last=$(jq -r '.tag // empty' "$state_file" 2>/dev/null || echo "")

  if [[ "$FORCE" != "true" && "$last" == "$tag" ]]; then
    log "[notify] ${name} 无新版本，跳过"
    LAST_ACTION="skipped"
    return 0
  fi

  if [[ "$DRY_RUN" != "true" ]]; then
    write_state "$state_file" "$(jq -n \
      --arg name "$name" --arg repo "$repo" --arg tag "$tag" --arg version "$version" \
      --arg strategy "notify" --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      '{name:$name,repo:$repo,tag:$tag,version:$version,strategy:$strategy,updated_at:$updated_at}')"

    notify "🔔 上游有新版本（需手工跟进）: ${name}" "$(cat <<EOF
包名: ${name}
仓库: ${repo}
上游版本: ${tag}  (推导 PKG_VERSION=${version})
本地版本: ${cur:-<无>}
时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

说明: 该包为内嵌源码 / git-commit / 多架构二进制型，
      请手工核对 Makefile 后更新。
EOF
)"
  else
    log "[dry-run] 将提醒 ${name} 有新版本 ${tag}"
  fi

  LAST_ACTION="updated"
  return 0
}

# ---------- 通用：取最新 tag ----------
# fetch_latest_tag <repo> <source:release|tag> <include_prerelease>
#   source=release 时先取 Release；取不到（部分仓库只打 tag 不发 Release，
#   如 XTLS/Xray-core）则回退到 tags。两者都空才返回 1。
gh_releases() {
  local repo="$1" include_pre="$2" raw filter
  raw=$(gh_api "https://api.github.com/repos/${repo}/releases?per_page=30") || return 1
  [[ "$(printf '%s' "$raw" | jq -r 'type' 2>/dev/null)" == "array" ]] || return 1
  filter='map(select(.draft != true))'
  if [[ "$include_pre" != "true" ]]; then
    filter+=' | map(select(.prerelease != true))'
  fi
  printf '%s' "$raw" | jq -r "${filter} | .[0].tag_name // empty"
}

gh_tags() {
  local repo="$1" raw
  raw=$(gh_api "https://api.github.com/repos/${repo}/tags?per_page=30") || return 1
  [[ "$(printf '%s' "$raw" | jq -r 'type' 2>/dev/null)" == "array" ]] || return 1
  printf '%s' "$raw" | jq -r '.[0].name // empty'
}

fetch_latest_tag() {
  local repo="$1" source="$2" include_pre="$3" tag=""

  case "$source" in
    tag|tags)
      tag=$(gh_tags "$repo")
      ;;
    *)
      tag=$(gh_releases "$repo" "$include_pre")
      # 回退：有些仓库只打 tag 不发 Release
      if [[ -z "$tag" ]]; then tag=$(gh_tags "$repo"); fi
      ;;
  esac

  if [[ -z "$tag" || "$tag" == "null" ]]; then
    log "[warn] ${repo} 没有可跟踪的 ${source}/tag"
    return 1
  fi
  printf '%s' "$tag"
}

# ---------- 分发 ----------
process_package() {
  local idx="$1"
  local cfg="$CONFIG_FILE"
  local name strategy

  name=$(cfg_get "$cfg" ".packages[$idx].name")
  strategy=$(cfg_get "$cfg" ".packages[$idx].strategy" "tarball")

  if [[ -z "$name" ]]; then
    log "[跳过] packages[$idx] 缺少 name"
    return 1
  fi

  log "────────────────────────────────────────"
  log "[包] ${name}  (策略: ${strategy})"

  case "$strategy" in
    tarball) strategy_tarball "$idx" ;;
    assets)  strategy_assets  "$idx" ;;
    notify)  strategy_notify  "$idx" ;;
    *)       log "[失败] ${name} 未知策略: ${strategy}"; return 1 ;;
  esac
}

run_packages() {
  local total
  total=$(cfg_len "$CONFIG_FILE" ".packages")
  if [[ "$total" -eq 0 ]]; then
    log "[包] 配置中没有 packages，跳过"
    return 0
  fi

  local updated=0 skipped=0 failed=0
  for ((i = 0; i < total; i++)); do
    local pname
    pname=$(cfg_get "$CONFIG_FILE" ".packages[$i].name")
    if [[ -n "$ONLY" && "$pname" != "$ONLY" ]]; then continue; fi

    LAST_ACTION=""
    if process_package "$i"; then
      case "$LAST_ACTION" in
        updated) updated=$((updated + 1)) ;;
        *)       skipped=$((skipped + 1)) ;;
      esac
    else
      failed=$((failed + 1))
    fi
  done

  log "[包] 汇总: 更新 ${updated} / 跳过 ${skipped} / 失败 ${failed}"
  if [[ "$failed" -gt 0 ]]; then
    if [[ "$STRICT" == "true" ]]; then
      log "[strict] 有 ${failed} 个包失败，按 --strict 退出非 0"
      return 1
    fi
    log "[warn] 有 ${failed} 个包失败（非致命，已跳过；需要硬失败请加 --strict）"
  fi
  return 0
}

# ------------------------- 主流程 -------------------------
# 只加载函数库（供测试 / 被其他脚本复用），不执行主流程
if [[ "${GRM_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

log "========== 开始同步 =========="
[[ "$DRY_RUN" == "true" ]] && log "[模式] dry-run（不修改文件、不推送）"
[[ "$FORCE" == "true" ]] && log "[模式] force（忽略缓存状态）"

rc=0

if [[ "$SKIP_SOURCE" != "true" ]]; then
  run_sources || rc=1
else
  log "[源码] 已跳过"
fi

if [[ "$SKIP_PACKAGES" != "true" ]]; then
  run_packages || rc=1
else
  log "[包] 已跳过"
fi

log "========== 同步结束 =========="
exit $rc
