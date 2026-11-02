#!/usr/bin/env python3
"""
srcpin.py —— dae / honk「外挂源码」的 pin 记录与拉取

背景：
  `daeuniverse/openwrt-packages` 只发 **feed 元数据**（Makefile / build.sh / files），
  源码不随包分发：
    dae/Makefile  → DAE_SRC := $(PKG_DIR)/src，期望 ./src 里已有 dae 源码
    honk/Makefile → HONK_SRC := $(PKG_DIR)/src，期望 ./src 里已有 honk 源码
  所以光同步 feed 是编不出来的，必须另外把「原作者仓库」的源码按版本拉进来。
  这就是 kenzok8/openwrt-honk 那套 pin 逻辑：把上游 ref + commit 钉在文件里，
  构建时按 pin 拉，而不是每次跟最新。

两个子命令：
  pin    读本地上游 Makefile 里的版本（PKG_VERSION / HONK_GIT_TAG 的默认值）→
         用 GitHub API 解析对应 commit → 写 config/src-pins.env；
         顺手从上游源码里读构建工具链版本（dae 的 go.mod、honk 的 ci/pins.env）。
         上游 feed 抬了版本，这里跟着抬；上游回退，这里也跟着记（并告警）。
  fetch  按 pin 把源码浅克隆到 <包>/src（dae 带 submodule），并用 *_COMMIT 校验
         tag 没被上游挪动。

用法:
    python3 tools/srcpin.py pin                  # 更新 pin（auto-sync 里跑这个）
    python3 tools/srcpin.py pin --dry-run        # 只看会改什么
    python3 tools/srcpin.py pin --only dae
    python3 tools/srcpin.py fetch                # 拉全部需要的源码
    python3 tools/srcpin.py fetch --only honk --root sdk/package
    python3 tools/srcpin.py fetch --force        # 已存在也重拉

环境变量:
    GITHUB_TOKEN  提高 GitHub API 限额（CI 里用 secrets.GITHUB_TOKEN 即可）

退出码:
    0  成功（含“无需改动”）
    1  失败（网络/解析/克隆出错；`pin` 用 --strict 才会因单包失败而失败）
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINS_REL = "config/src-pins.env"

# 每个「外挂源码」包：pin 前缀 / Makefile / 版本变量 / tag 变量 / 是否需要 submodule
PACKAGES = {
    "dae": {
        "pin": "DAE",
        "makefile": "dae/Makefile",
        "version_var": "PKG_VERSION",
        "tag_var": None,          # Makefile 里没有 tag 变量，约定 tag = "v" + version
        "tag_prefix": "v",
        "submodules": True,
    },
    "honk": {
        "pin": "HONK",
        "makefile": "honk/Makefile",
        "version_var": "PKG_VERSION",
        "tag_var": "HONK_GIT_TAG",
        "tag_prefix": "",
        "submodules": False,
    },
}

# pin 文件里工具链字段的来源（从上游源码里读，保证和上游 CI 用的一致）
TOOLCHAIN_KEYS = {
    "dae": ("DAE_GO_VERSION",),
    "honk": ("BPF_LINKER_VERSION",),
}


def log(msg):
    print(msg, flush=True)


def warn(msg):
    print(f"::warning::{msg}" if os.environ.get("GITHUB_ACTIONS") else f"[警告] {msg}",
          file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# 版本比较 / Makefile 取值
# --------------------------------------------------------------------------
def _ver_parts(v):
    """把 2.1.1 / 0.1.0_beta4 / v26.10.21 拆成可比较的 token 序列。"""
    v = v.strip()
    if v.startswith("v") and len(v) > 1 and v[1].isdigit():
        v = v[1:]
    out = []
    for tok in re.split(r"[._+\-~]", v):
        if tok == "":
            continue
        out.append(int(tok) if tok.isdigit() else tok)
    return out


def ver_cmp(a, b):
    """-1 = a<b，0 = 相等，1 = a>b。数字按数值比，字符串按字典序，数字压倒字符串（正式版 > 预发布）。"""
    pa, pb = _ver_parts(a), _ver_parts(b)
    for i in range(max(len(pa), len(pb))):
        x = pa[i] if i < len(pa) else 0
        y = pb[i] if i < len(pb) else 0
        if isinstance(x, int) and isinstance(y, int):
            if x != y:
                return 1 if x > y else -1
            continue
        if isinstance(x, int) != isinstance(y, int):
            return 1 if isinstance(x, int) else -1
        if str(x) != str(y):
            return 1 if str(x) > str(y) else -1
    return 0


def read_makefile_var(path, var):
    """取 Makefile 里 `VAR:=...` 的默认值；支持 `VAR:=$(if $(X),$(X),默认)` 这种派生式。"""
    if not var or not os.path.isfile(path):
        return None
    pat = re.compile(r"^[ \t]*" + re.escape(var) + r"[ \t]*[:?+]?=[ \t]*(.*)$")
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.match(line.rstrip("\r\n"))
            if not m:
                continue
            tail = m.group(1).strip()
            if tail.startswith("$(if ") and tail.endswith(")"):
                # $(if $(DAE_VERSION),$(DAE_VERSION),2.1.1) → 取最后一个逗号之后
                inner = tail[: tail.rfind(")")]
                cut = inner.rfind(",")
                if cut != -1:
                    return inner[cut + 1:].strip()
            return tail
    return None


def package_target(root, name):
    """从 Makefile 推导 (version, tag)。tag 缺失时用 tag_prefix + version。"""
    spec = PACKAGES[name]
    mf = os.path.join(root, spec["makefile"])
    version = read_makefile_var(mf, spec["version_var"])
    tag = read_makefile_var(mf, spec["tag_var"]) if spec["tag_var"] else None
    if not version:
        return None, None
    if not tag:
        tag = f'{spec["tag_prefix"]}{version}'
    return version, tag


# --------------------------------------------------------------------------
# pin 文件
# --------------------------------------------------------------------------
def read_pins(path):
    pins = {}
    if not os.path.isfile(path):
        return pins
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            pins[k.strip()] = v.strip()
    return pins


def render_pins(pins):
    """按固定顺序输出，方便 review diff。"""
    order = []
    for name in PACKAGES:
        p = PACKAGES[name]["pin"]
        order += [f"{p}_REPO", f"{p}_TAG", f"{p}_VERSION", f"{p}_COMMIT"]
        order += list(TOOLCHAIN_KEYS.get(name, ()))

    lines = [
        "# dae / honk 外挂源码 pin —— 由 `python3 tools/srcpin.py pin` 生成/更新",
        "#",
        "# 上游：daeuniverse/openwrt-packages（feed 元数据）",
        "#       daeuniverse/dae、daeuniverse/honk（源码，按需拉进 <包>/src）",
        "#",
        "# *_TAG / *_VERSION 来自上游 feed Makefile 的默认值（构建时也可用",
        "#   DAE_VERSION= / HONK_VERSION= / HONK_GIT_TAG= 覆盖）；",
        "# *_COMMIT 用来校验 clone 出来的 tag 没被上游挪动；",
        "# 工具链版本从上游源码里读（dae 的 go.mod、honk 的 .github/ci/pins.env）。",
        "",
    ]
    for key in order:
        if key in pins:
            lines.append(f"{key}={pins[key]}")
    # 其余未知字段原样保留在末尾，别把手写的东西吃掉
    for key in sorted(pins):
        if key not in order:
            lines.append(f"{key}={pins[key]}")
    return "\n".join(lines).rstrip("\n") + "\n"


def write_pins(path, pins, dry_run=False):
    text = render_pins(pins)
    old = ""
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            old = f.read()
    if old == text:
        return False
    if dry_run:
        import difflib
        sys.stdout.writelines(
            difflib.unified_diff(old.splitlines(keepends=True),
                                 text.splitlines(keepends=True),
                                 fromfile=PINS_REL, tofile=PINS_REL + " (new)"))
        return True
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return True


# --------------------------------------------------------------------------
# GitHub API（只用标准库）
# --------------------------------------------------------------------------
class ApiError(RuntimeError):
    pass


def _token(from_arg=None):
    return from_arg or os.environ.get("GITHUB_TOKEN") or ""


def api_get(path, token=None, tries=3):
    url = path if path.startswith("http") else "https://api.github.com" + path
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "github-release-sync/srcpin",
    }
    tok = _token(token)
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    last = None
    for attempt in range(1, tries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code} {url}"
            if e.code in (403, 429) and attempt < tries:
                time.sleep(5 * attempt)
                continue
            if e.code == 404:
                raise ApiError(f"404: {url}") from None
            raise ApiError(last) from None
        except Exception as e:  # 网络抖动
            last = f"{type(e).__name__}: {e}"
            if attempt < tries:
                time.sleep(2 * attempt)
                continue
    raise ApiError(last or "unknown error")


def resolve_commit(repo, ref, token=None):
    data = json.loads(api_get(f"/repos/{repo}/commits/{urllib.parse.quote(ref)}", token))
    sha = data.get("sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ApiError(f"{repo}@{ref}: 拿不到 commit sha")
    return sha


def latest_release_tag(repo, include_prerelease, token=None):
    """最新 Release tag；取不到就回退 tags（只打 tag 不发 Release 的仓库）。"""
    try:
        rels = json.loads(api_get(f"/repos/{repo}/releases?per_page=30", token))
        if isinstance(rels, list):
            for r in rels:
                if r.get("draft"):
                    continue
                if r.get("prerelease") and not include_prerelease:
                    continue
                tag = r.get("tag_name")
                if tag:
                    return tag
    except ApiError:
        pass
    try:
        tags = json.loads(api_get(f"/repos/{repo}/tags?per_page=30", token))
        if isinstance(tags, list):
            for t in tags:
                if t.get("name"):
                    return t["name"]
    except ApiError:
        pass
    return None


def raw_file(repo, ref, path, token=None):
    url = f"https://raw.githubusercontent.com/{repo}/{ref}/{path}"
    try:
        return api_get(url, token, tries=2).decode("utf-8", "replace")
    except ApiError:
        return None


# --------------------------------------------------------------------------
# pin 子命令
# --------------------------------------------------------------------------
def cmd_pin(args):
    root = args.root
    pins_path = os.path.join(root, PINS_REL)
    pins = read_pins(pins_path)
    changed = False
    failed = 0

    for name in PACKAGES:
        if args.only and name not in args.only:
            continue
        spec = PACKAGES[name]
        pre = spec["pin"]
        version, tag = package_target(root, name)
        if not version or not tag:
            warn(f"{name}: 读不到 {spec['version_var']}（{spec['makefile']}），跳过")
            failed += 1
            continue

        repo = pins.get(f"{pre}_REPO")
        if not repo:
            repo = f"daeuniverse/{name}"
        old_tag = pins.get(f"{pre}_TAG", "")
        old_ver = pins.get(f"{pre}_VERSION", "")

        if old_ver and ver_cmp(version, old_ver) < 0:
            warn(f"{name}: 上游 feed 版本比上次记录低（{old_ver} → {version}），已跟随（不拦，但请复核）")
        log(f"[pin] {name}: 本地 Makefile → tag={tag} version={version}")

        commit = ""
        try:
            commit = resolve_commit(repo, tag, args.token)
        except ApiError as e:
            # 没有网络 / 限额时不要动已有 pin，也别把整次同步搞挂
            warn(f"{name}: 解析 {repo}@{tag} 的 commit 失败（{e}），保留原 pin")
            failed += 1
            continue

        new = {f"{pre}_REPO": repo, f"{pre}_TAG": tag,
               f"{pre}_VERSION": version, f"{pre}_COMMIT": commit}
        for k, v in new.items():
            if pins.get(k) != v:
                log(f"       {k}: {pins.get(k) or '<无>'} → {v}")
                pins[k] = v
                changed = True

        # 工具链版本：从上游源码里读，保持和上游 CI 一致
        try:
            if name == "dae":
                gomod = raw_file(repo, tag, "go.mod", args.token)
                m = re.search(r"^go[ \t]+(\d+\.\d+(?:\.\d+)?)", gomod or "", re.M)
                if m and pins.get("DAE_GO_VERSION") != m.group(1):
                    log(f"       DAE_GO_VERSION: {pins.get('DAE_GO_VERSION') or '<无>'} → {m.group(1)}")
                    pins["DAE_GO_VERSION"] = m.group(1)
                    changed = True
            elif name == "honk":
                penv = raw_file(repo, tag, ".github/ci/pins.env", args.token)
                m = re.search(r"^BPF_LINKER_VERSION=(\S+)", penv or "", re.M)
                if m and pins.get("BPF_LINKER_VERSION") != m.group(1):
                    log(f"       BPF_LINKER_VERSION: {pins.get('BPF_LINKER_VERSION') or '<无>'} → {m.group(1)}")
                    pins["BPF_LINKER_VERSION"] = m.group(1)
                    changed = True
        except Exception as e:  # 工具链是锦上添花，出错不算失败
            warn(f"{name}: 读取工具链版本失败（{e}），沿用原值")

        # 上游已经有更新 tag 时提示一句：pin 跟的是「上游 feed 钉的版本」
        try:
            latest = latest_release_tag(repo, include_prerelease=(name == "honk"), token=args.token)
            if latest and ver_cmp(latest, tag) > 0:
                log(f"[pin] {name}: 上游已有更新 tag {latest}（feed 仍钉 {tag}，等上游 feed 跟进再拉）")
        except ApiError:
            pass

    if write_pins(pins_path, pins, dry_run=args.dry_run):
        if args.dry_run:
            log(f"[pin] {PINS_REL} 有变化（dry-run，未落盘）")
        else:
            log(f"[pin] 已更新 {PINS_REL}")
    else:
        log(f"[pin] {PINS_REL} 无变化")

    if failed and args.strict:
        log(f"[pin] {failed} 个包失败（--strict）")
        return 1
    return 0


# --------------------------------------------------------------------------
# fetch 子命令
# --------------------------------------------------------------------------
def run(cmd, cwd=None):
    log("    $ " + " ".join(cmd))
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def git_head(dest):
    try:
        p = subprocess.run(["git", "-C", dest, "rev-parse", "HEAD"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        return p.stdout.strip() if p.returncode == 0 else ""
    except FileNotFoundError:
        return ""


def cmd_fetch(args):
    if not shutil.which("git"):
        log("[错误] 需要 git：本地编译/CI 都要用它浅克隆上游源码")
        return 1
    root = os.path.abspath(args.root)
    # fetch 允许 --root 指向别处（CI 里是 sdk/package），此时 pin 文件仍在仓库根
    pins_path = os.path.join(root, PINS_REL)
    if not os.path.isfile(pins_path):
        pins_path = os.path.join(REPO_ROOT, PINS_REL)
    pins = read_pins(pins_path)

    failed = 0
    for name in PACKAGES:
        if args.only and name not in args.only:
            continue
        spec = PACKAGES[name]
        pre = spec["pin"]
        version, tag = package_target(root, name)
        if not tag:
            warn(f"{name}: 读不到版本（{os.path.join(root, spec['makefile'])} 存在吗？），跳过")
            failed += 1
            continue
        repo = pins.get(f"{pre}_REPO") or f"daeuniverse/{name}"
        expected = pins.get(f"{pre}_COMMIT", "") if pins.get(f"{pre}_TAG") == tag else ""

        pkgdir = os.path.join(root, name)
        dest = os.path.join(pkgdir, "src")
        if not os.path.isdir(pkgdir):
            warn(f"{name}: 没有包目录 {pkgdir}，跳过")
            failed += 1
            continue

        # 路径安全检查：dest 必须就在包目录下
        if os.path.realpath(os.path.dirname(os.path.realpath(dest))) != os.path.realpath(pkgdir):
            log(f"[错误] {name}: src 路径不正常（{dest}），拒绝操作")
            failed += 1
            continue

        cur = git_head(dest) if os.path.isdir(dest) else ""
        if cur and not args.force:
            if not expected or cur == expected:
                log(f"[fetch] {name}: 已存在 {tag}（{cur[:12]}），跳过")
                continue
            log(f"[fetch] {name}: 现有源码 {cur[:12]} ≠ pin {expected[:12]}，重拉")

        if os.path.isdir(dest):
            log(f"[fetch] {name}: 删除旧的 src/")
            shutil.rmtree(dest)

        url = f"https://github.com/{repo}.git"
        cmd = ["git", "clone", "--depth", "1", "--branch", tag]
        if spec["submodules"]:
            cmd += ["--recurse-submodules", "--shallow-submodules"]
        cmd += [url, dest]
        log(f"[fetch] {name}: {repo}@{tag} → {os.path.relpath(dest, root)}")
        p = run(cmd)
        if p.returncode != 0:
            log(p.stdout)
            warn(f"{name}: git clone 失败（{url}@{tag}）")
            failed += 1
            continue

        got = git_head(dest)
        if expected and got and got != expected:
            msg = (f"{name}: tag {tag} 指向 {got[:12]}，与 pin 记录的 {expected[:12]} 不一致"
                   f"（上游可能挪过 tag）；跑 `python3 tools/srcpin.py pin` 复核")
            if args.strict:
                log(f"[错误] {msg}")
                failed += 1
                continue
            warn(msg)
        log(f"[fetch] {name}: OK  {got[:12]}  (version {version})")

    if failed:
        log(f"[fetch] {failed} 个包失败")
        return 1
    log("[fetch] 全部就绪")
    if pins.get("DAE_GO_VERSION") or pins.get("BPF_LINKER_VERSION"):
        log(f"[fetch] 工具链：Go {pins.get('DAE_GO_VERSION', '?')}（dae）、"
            f"rustup + bpf-linker {pins.get('BPF_LINKER_VERSION', '?')}（honk）")
    return 0


# --------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="dae / honk 外挂源码的 pin 与拉取",
        formatter_class=argparse.RawDescriptionHelpFormatter)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--root", default=REPO_ROOT,
                        help="仓库根目录（fetch 时也可以指向 sdk/package）")
    common.add_argument("--only", default="",
                        help="只处理指定包，逗号分隔：dae,honk")
    common.add_argument("--token", default="", help="GitHub token（默认读 GITHUB_TOKEN）")

    sub = ap.add_subparsers(dest="cmd", required=True)

    p_pin = sub.add_parser("pin", parents=[common],
                           help="按上游 Makefile 的版本更新 config/src-pins.env")
    p_pin.add_argument("--dry-run", action="store_true")
    p_pin.add_argument("--strict", action="store_true", help="单包失败也返回非 0")
    p_pin.set_defaults(func=cmd_pin)

    p_fetch = sub.add_parser("fetch", parents=[common],
                             help="按 pin 把上游源码浅克隆到 <包>/src")
    p_fetch.add_argument("--force", action="store_true", help="已存在也重拉")
    p_fetch.add_argument("--strict", action="store_true", help="commit 与 pin 不一致时失败")
    p_fetch.set_defaults(func=cmd_fetch)

    args = ap.parse_args(argv)
    if args.only:
        args.only = [x.strip() for x in args.only.split(",") if x.strip()]
        bad = [x for x in args.only if x not in PACKAGES]
        if bad:
            ap.error(f"未知包: {', '.join(bad)}（支持: {', '.join(PACKAGES)}）")
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
