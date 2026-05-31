#!/bin/bash
set -uo pipefail

# 快捷切换前后端两个仓库到同一个 ticket 对应的分支。
#
# 用法:
#   ./script/switch_branch.sh ASAIO-1384            # 自动匹配 bugfix/feature 等前缀
#   ./script/switch_branch.sh feature/ASAIO-1384    # 直接给完整分支名
#   ./script/switch_branch.sh -n ASAIO-1384         # 跳过 git fetch(离线/想快一点)
#   ./script/switch_branch.sh -h                    # 查看帮助
#
# 会在 test-mng-service 和 test-mng-web 各自独立查找匹配分支, 优先级:
#   bugfix/<name> -> feature/<name> -> fix/<name> -> hotfix/<name> -> feat/<name> -> <name>
# 两个仓库前缀可以不同(比如后端 feature、前端 bugfix), 各自匹配各自的。
# 本地有该分支则直接切; 本地没有但 origin 上有, 则创建本地跟踪分支再切。

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 仓库列表: "标签:路径"
REPOS=(
  "service:$ROOT_DIR/test-mng-service"
  "web:$ROOT_DIR/test-mng-web"
)

# 候选前缀(按优先级从前到后)
PREFIXES=("bugfix" "feature" "fix" "hotfix" "feat")

DO_FETCH=1
NAME=""

# ---- 解析参数 ----
for arg in "$@"; do
  case "$arg" in
    -n|--no-fetch) DO_FETCH=0 ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      echo "❌ 未知参数: $arg (用 -h 查看帮助)"; exit 1 ;;
    *)
      NAME="$arg" ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "❌ 用法: $0 <ticket 或 分支名>   例如: $0 ASAIO-1384"
  exit 1
fi

# 构造候选分支名(按优先级, 每行一个)
build_candidates() {
  local name="$1"
  if [[ "$name" == */* ]]; then
    # 已经是完整分支名, 原样使用
    printf '%s\n' "$name"
    return
  fi
  local p
  for p in "${PREFIXES[@]}"; do
    printf '%s/%s\n' "$p" "$name"
  done
  printf '%s\n' "$name" # 裸名兜底
}

# 在单个仓库里查找并切换, 返回 0 成功 / 非 0 失败
switch_repo() {
  local label="$1" dir="$2"

  echo ""
  echo "📂 [$label] $dir"

  if [ ! -d "$dir/.git" ]; then
    echo "   ⚠️  不是 git 仓库, 跳过"
    return 1
  fi

  if [ "$DO_FETCH" -eq 1 ]; then
    echo "   ⬇️  git fetch --prune origin ..."
    git -C "$dir" fetch --prune origin >/dev/null 2>&1 \
      || echo "   ⚠️  fetch 失败(可能离线), 继续用本地引用"
  fi

  local cand found="" found_kind=""
  while IFS= read -r cand; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$cand"; then
      found="$cand"; found_kind="local"; break
    elif git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$cand"; then
      found="$cand"; found_kind="remote"; break
    fi
  done < <(build_candidates "$NAME")

  if [ -z "$found" ]; then
    echo "   ❌ 没找到匹配分支 (尝试过: $(build_candidates "$NAME" | tr '\n' ' '))"
    return 1
  fi

  local cur
  cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  if [ "$cur" = "$found" ]; then
    echo "   ✅ 已在分支 $found, 无需切换"
    return 0
  fi

  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "   ⚠️  存在未提交改动, 尝试切换(若有冲突 git 会自动中止)"
  fi

  if [ "$found_kind" = "local" ]; then
    if git -C "$dir" checkout "$found"; then
      echo "   ✅ 已切到本地分支 $found (原: $cur)"
      return 0
    fi
  else
    # 远程分支: 创建本地跟踪分支
    if git -C "$dir" checkout -b "$found" --track "origin/$found" 2>/dev/null \
       || git -C "$dir" checkout "$found"; then
      echo "   ✅ 已切到分支 $found, 跟踪 origin/$found (原: $cur)"
      return 0
    fi
  fi

  echo "   ❌ 切换到 $found 失败"
  return 1
}

echo "🎯 目标: $NAME"

overall=0
for spec in "${REPOS[@]}"; do
  switch_repo "${spec%%:*}" "${spec#*:}" || overall=1
done

echo ""
if [ "$overall" -eq 0 ]; then
  echo "🎉 前后端均已切换完成"
else
  echo "⚠️  有仓库未成功切换, 详见上面日志"
fi
exit "$overall"
