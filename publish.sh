#!/usr/bin/env bash
# ============================================================================
#  一键发布到 GitHub(在**装了 gh 的机器**上跑)
#
#  用法:
#     ./publish.sh                     # 建仓库 + 推送 + 发 Release
#     ./publish.sh --repo my-ime       # 换仓库名
#     ./publish.sh --owner someone     # 换 owner
#     ./publish.sh --no-release        # 只推代码,不建 Release
#
#  前置条件:
#     - 装了 gh 并已登录(gh auth login,或 gh auth login --with-token <<< "$TOKEN")
#     - 当前目录是本仓库的 git 工作区
# ============================================================================
set -euo pipefail

REPO_NAME="steamdeck-chinese-ime"
OWNER=""
DO_RELEASE=1
TAG="v1.0.0"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)       REPO_NAME="$2"; shift 2 ;;
        --owner)      OWNER="$2"; shift 2 ;;
        --tag)        TAG="$2"; shift 2 ;;
        --no-release) DO_RELEASE=0; shift ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数:$1" >&2; exit 1 ;;
    esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "没装 gh —— https://cli.github.com/ (或用 GitHub Desktop / 网页端手动建仓库)"
gh auth status >/dev/null 2>&1 || die "gh 没登录 —— 先跑 gh auth login"

# 没指定 owner 就用当前登录账号
[ -n "$OWNER" ] || OWNER=$(gh api user --jq .login)
say "owner=$OWNER  repo=$REPO_NAME  tag=$TAG"

# ---------------------------------------------------------------- 仓库
if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
    ok "仓库已存在:$OWNER/$REPO_NAME"
else
    say "创建公开仓库"
    gh repo create "$OWNER/$REPO_NAME" --public --description \
        "Steam Deck 中文输入法修复工具箱:桌面模式(fcitx5 + KWin Wayland 桥)+ 掌机模式(Steam OSK + IBus,dconf profile 缺失根因)" \
        --disable-issues=false >/dev/null
    ok "已创建:$OWNER/$REPO_NAME"
fi

# ---------------------------------------------------------------- 推送
say "推送分支与 tag"
# 让 git 用 gh 的凭据(否则 HTTPS push 会要用户名密码)
gh auth setup-git >/dev/null 2>&1 || true
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
git push -u origin HEAD
ok "分支已推送"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    git push origin "refs/tags/$TAG"
    ok "tag $TAG 已推送"
else
    echo "  ! tag $TAG 不存在,跳过"
fi

# ---------------------------------------------------------------- Release
if [ "$DO_RELEASE" = "1" ]; then
    NOTES="RELEASE-NOTES-$TAG.md"
    if [ -f "$NOTES" ]; then
        say "创建 GitHub Release $TAG"
        gh release create "$TAG" --title "$TAG — 首个正式版" --notes-file "$NOTES" \
            --repo "$OWNER/$REPO_NAME" || \
        gh release create "$TAG" --title "$TAG" --notes-file "$NOTES" --repo "$OWNER/$REPO_NAME"
        ok "Release 已创建:https://github.com/$OWNER/$REPO_NAME/releases/tag/$TAG"
    else
        echo "  ! 没有 $NOTES,跳过 Release 创建"
    fi
fi

# ---------------------------------------------------------------- topics
say "设置 topics"
gh repo edit "$OWNER/$REPO_NAME" \
    --add-topic steamos --add-topic steamdeck --add-topic chinese-input \
    --add-topic fcitx5 --add-topic ibus --add-topic wayland --add-topic linux \
    >/dev/null 2>&1 && ok "topics 已设置" || echo "  ! topics 设置失败(可手动补)"

echo
echo "完成:https://github.com/$OWNER/$REPO_NAME"
