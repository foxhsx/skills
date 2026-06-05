#!/usr/bin/env bash
#
# git-diff-files.sh — 手动测试用例生成器的 diff 分析脚本
# 获取当前分支相对于主分支的变更文件列表，输出结构化 JSON
#
# 用法:
#   bash <SKILL_ROOT>/scripts/git-diff-files.sh [--plain] [主分支名]
#
# 示例:
#   bash <SKILL_ROOT>/scripts/git-diff-files.sh              # 自动检测主分支
#   bash <SKILL_ROOT>/scripts/git-diff-files.sh master        # 指定 master
#   bash <SKILL_ROOT>/scripts/git-diff-files.sh --plain       # 纯路径输出
#
# 输出:
#   - 默认模式：终端打印变更文件清单 + 写入 .diff-files.json
#   - --plain 模式：仅输出纯文件路径列表（适合管道串联）

set -euo pipefail

# ============================================================
# 颜色定义
# ============================================================
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; DIM='\033[2m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' RESET=''
fi

info()    { echo -e "${BLUE}$*${RESET}"; }
success() { echo -e "${GREEN}$*${RESET}"; }
warn()    { echo -e "${YELLOW}$*${RESET}"; }
error()   { echo -e "${RED}$*${RESET}"; }
dim()     { echo -e "${DIM}$*${RESET}"; }

# ============================================================
# 自动检测主分支
# ============================================================
detect_main_branch() {
  local hint="${1:-}"

  if [[ -n "$hint" ]]; then
    if git rev-parse --verify "$hint" &>/dev/null; then
      echo "$hint"
      return
    fi
  fi

  for candidate in main master; do
    if git rev-parse --verify "$candidate" &>/dev/null; then
      echo "$candidate"
      return
    fi
  done

  for candidate in origin/main origin/master; do
    if git rev-parse --verify "$candidate" &>/dev/null; then
      echo "$candidate"
      return
    fi
  done

  error "❌ 无法自动检测主分支，请手动指定：bash $0 <主分支名>"
  exit 1
}

# ============================================================
# 获取当前分支
# ============================================================
get_current_branch() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || branch=$(git rev-parse --short HEAD 2>/dev/null)
  echo "$branch"
}

# ============================================================
# 获取 merge base
# ============================================================
get_merge_base() {
  local main_branch="$1"
  local current_branch="$2"
  git merge-base "$main_branch" "$current_branch" 2>/dev/null || git rev-parse "$main_branch"
}

# ============================================================
# 收集 diff 文件列表
# ============================================================
collect_diff_files() {
  local base="$1"
  local current_branch="$2"
  # Only include files changed by non-merge commits on the feature branch,
  # excluding files brought in solely through merge/rebase from the main branch
  git log --no-merges --name-only --pretty=format: "$base".."$current_branch" 2>/dev/null | \
    grep -v '^$' | sort -u
}

# ============================================================
# 检测 merge 提交数量
# ============================================================
count_merge_commits() {
  local base="$1"
  local current_branch="$2"
  git rev-list --merges "$base".."$current_branch" 2>/dev/null | wc -l | tr -d ' '
}

# ============================================================
# 获取文件的变更类型和变更行数
# ============================================================
get_change_info() {
  local base="$1"
  local current_branch="$2"
  local file="$3"

  local status
  status=$(git diff --name-status "$base" "$current_branch" -- "$file" 2>/dev/null | awk '{print $1}' | head -1)
  [[ -z "$status" ]] && status="M"

  local additions=0 deletions=0
  local numstat_line
  numstat_line=$(git diff --numstat "$base" "$current_branch" -- "$file" 2>/dev/null | head -1)
  if [[ -n "$numstat_line" ]]; then
    additions=$(echo "$numstat_line" | awk '{print $1}')
    deletions=$(echo "$numstat_line" | awk '{print $2}')
    [[ "$additions" == "-" ]] && additions=0
    [[ "$deletions" == "-" ]] && deletions=0
  fi
  local total_changes=$((additions + deletions))

  echo "${status}|+${additions}/-${deletions} (${total_changes})"
}

# ============================================================
# 按路径推断功能模块（通用版，不绑定前端目录结构）
# ============================================================
detect_module() {
  local file="$1"
  local first_dir second_dir

  first_dir=$(echo "$file" | cut -d'/' -f1)
  second_dir=$(echo "$file" | cut -d'/' -f2)

  case "$file" in
    src/components/*|src/views/*|src/pages/*)   echo "UI组件" ;;
    src/hooks/*|src/composables/*)               echo "Hooks" ;;
    src/utils/*|src/helpers/*|src/lib/*)          echo "工具函数" ;;
    src/services/*|src/api/*)                     echo "接口层" ;;
    src/store/*|src/stores/*|src/models/*)        echo "状态管理" ;;
    src/routes/*|src/router/*)                    echo "路由" ;;
    src/styles/*|src/css/*|*.css|*.less|*.scss)   echo "样式" ;;
    src/types/*|src/interfaces/*|*.d.ts)          echo "类型定义" ;;
    src/config/*|src/constants/*)                 echo "配置/常量" ;;
    *.config.*|.*rc|.*rc.*)                       echo "工程配置" ;;
    package.json|pom.xml|build.gradle*)           echo "依赖管理" ;;
    *.md|*.txt|docs/*)                            echo "文档" ;;
    *.test.*|*.spec.*|__tests__/*|test/*|tests/*) echo "测试" ;;
    src/*)                                        echo "$second_dir" ;;
    *)                                            echo "$first_dir" ;;
  esac
}

# ============================================================
# 仅排除的文件模式（lock 文件 + 二进制资源）
# ============================================================
IGNORED_LOCK_FILES=("package-lock.json" "yarn.lock" "pnpm-lock.yaml" "Gemfile.lock" "Cargo.lock" "poetry.lock" "composer.lock" "go.sum")
IGNORED_BINARY_EXTENSIONS=(".png" ".jpg" ".jpeg" ".gif" ".ico" ".svg" ".woff" ".woff2" ".ttf" ".eot" ".mp3" ".mp4" ".webm" ".zip" ".tar" ".gz" ".jar" ".war" ".class" ".pyc" ".o" ".so" ".dll" ".exe")

should_exclude() {
  local file="$1"
  local filename
  filename=$(basename "$file")

  for lock in "${IGNORED_LOCK_FILES[@]}"; do
    [[ "$filename" == "$lock" ]] && return 0
  done

  for ext in "${IGNORED_BINARY_EXTENSIONS[@]}"; do
    [[ "$filename" == *"$ext" ]] && return 0
  done

  return 1
}

# ============================================================
# 从分支名提取功能描述（用于 e2e 目录命名）
# ============================================================
extract_branch_feature() {
  local branch="$1"
  local feature="$branch"

  feature="${feature#feat/}"
  feature="${feature#fix/}"
  feature="${feature#feature/}"
  feature="${feature#bugfix/}"
  feature="${feature#hotfix/}"
  feature="${feature#release/}"
  feature="${feature#chore/}"
  feature="${feature#refactor/}"

  echo "$feature"
}

# ============================================================
# 主流程
# ============================================================
main() {
  local plain_mode=false
  local positional_args=()
  for arg in "$@"; do
    case "$arg" in
      --plain) plain_mode=true ;;
      *) positional_args+=("$arg") ;;
    esac
  done

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    error "❌ 当前目录不是 git 仓库"
    exit 1
  fi

  local first_arg=""
  if [[ ${#positional_args[@]} -gt 0 ]]; then
    first_arg="${positional_args[0]}"
  fi

  local main_branch
  main_branch=$(detect_main_branch "$first_arg")

  local current_branch
  current_branch=$(get_current_branch)

  local branch_feature
  branch_feature=$(extract_branch_feature "$current_branch")

  if ! $plain_mode; then
    info "🔀 主分支: ${main_branch}"
    info "🌿 当前分支: ${current_branch}"
    info "🏷️  分支功能: ${branch_feature}"
  fi

  if [[ "$current_branch" == "$main_branch" ]]; then
    if ! $plain_mode; then
      warn "⚠️  当前分支与主分支相同，没有差异可比较"
    fi
    exit 0
  fi

  local base
  base=$(get_merge_base "$main_branch" "$current_branch")

  if ! $plain_mode; then
    local short_base
    short_base=$(echo "$base" | cut -c1-8)
    info "📍 Merge base: ${short_base}"
  fi

  local merge_count
  merge_count=$(count_merge_commits "$base" "$current_branch")
  if ! $plain_mode && [[ "$merge_count" -gt 0 ]]; then
    info "🔄 检测到 ${merge_count} 个 merge 提交，已自动排除合并带入的变更"
  fi

  if ! $plain_mode; then
    echo ""
    info "⏳ 正在计算差异文件..."
  fi

  local all_files
  all_files=$(collect_diff_files "$base" "$current_branch")

  if [[ -z "$all_files" ]]; then
    if ! $plain_mode; then
      success "✅ 没有变更文件"
    fi
    exit 0
  fi

  # ============================================================
  # 过滤 + 分类
  # ============================================================
  local filtered_files=()
  local skipped_binary=0

  while IFS= read -r file; do
    if should_exclude "$file"; then
      skipped_binary=$((skipped_binary + 1))
      continue
    fi
    filtered_files+=("$file")
  done <<< "$all_files"

  if [[ ${#filtered_files[@]} -eq 0 ]]; then
    if ! $plain_mode; then
      warn "⚠️  过滤后没有需要分析的文件"
      [[ $skipped_binary -gt 0 ]] && dim "   （${skipped_binary} 个 lock/二进制文件已排除）"
    fi
    exit 0
  fi

  # ============================================================
  # 预计算每个文件的变更信息和模块分类
  # ============================================================
  local file_change_types=()
  local file_change_lines=()
  local file_modules=()

  for file in "${filtered_files[@]}"; do
    local change_info
    change_info=$(get_change_info "$base" "$current_branch" "$file")
    file_change_types+=("${change_info%%|*}")
    file_change_lines+=("${change_info#*|}")
    file_modules+=("$(detect_module "$file")")
  done

  # ============================================================
  # 写入 .diff-files.json
  # ============================================================
  local json_output_path=".diff-files.json"

  {
    echo "{"
    echo "  \"generatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"mainBranch\": \"${main_branch}\","
    echo "  \"currentBranch\": \"${current_branch}\","
    echo "  \"branchFeature\": \"${branch_feature}\","
    echo "  \"outputPath\": \"e2e/${branch_feature}/MANUAL-TEST-CASES.md\","
    echo "  \"summary\": {"
    echo "    \"totalFiles\": ${#filtered_files[@]},"
    echo "    \"skippedBinary\": ${skipped_binary},"
    echo "    \"mergeCommitsExcluded\": ${merge_count}"
    echo "  },"
    echo "  \"files\": ["

    local i
    for ((i=0; i<${#filtered_files[@]}; i++)); do
      local comma=""
      [[ $i -gt 0 ]] && comma=","
      # 转义 JSON 中的特殊字符
      local escaped_module="${file_modules[$i]//\"/\\\"}"
      echo "    ${comma}{\"filePath\":\"${filtered_files[$i]}\",\"changeType\":\"${file_change_types[$i]}\",\"changeLines\":\"${file_change_lines[$i]}\",\"module\":\"${escaped_module}\"}"
    done

    echo "  ]"
    echo "}"
  } > "$json_output_path"

  # --plain 模式
  if $plain_mode; then
    for file in "${filtered_files[@]}"; do
      echo "$file"
    done
    echo ""
    echo "📄 已写入 ${json_output_path}"
    exit 0
  fi

  # 默认模式：输出变更文件清单
  echo ""
  echo -e "${BOLD}${BLUE}📁 变更文件清单 (${#filtered_files[@]} 个):${RESET}"
  echo ""
  printf "%-55s | %-4s | %-18s | %s\n" "文件路径" "类型" "变更行数" "功能模块"
  printf "%-55s-+-%-4s-+-%-18s-+-%s\n" "$(printf '%0.s-' {1..55})" "----" "------------------" "$(printf '%0.s-' {1..15})"

  for ((i=0; i<${#filtered_files[@]}; i++)); do
    printf "%-55s | %-4s | %-18s | %s\n" "${filtered_files[$i]}" "${file_change_types[$i]}" "${file_change_lines[$i]}" "${file_modules[$i]}"
  done

  echo ""
  [[ $skipped_binary -gt 0 ]] && dim "ℹ️  ${skipped_binary} 个 lock/二进制文件已排除"
  echo ""
  info "📄 已写入 ${json_output_path}"
  info "📂 测试文档输出路径: e2e/${branch_feature}/MANUAL-TEST-CASES.md"
  success "✅ Diff 分析完成"
}

main "$@"
