#!/bin/bash
# ============================================
# MaiBot 日志监控 & 管理脚本
# ============================================

# 切换到脚本所在目录
cd "$(dirname "$0")" || { echo "无法进入脚本目录"; read -r -p "按回车退出..."; exit 1; }

# 首次运行时自动添加执行权限
[ ! -x "$0" ] && chmod +x "$0" 2>/dev/null

SCRIPT_DIR="$(pwd)"

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_line() {
    echo -e "${CYAN}========================================================${NC}"
}

# ---------- 错误处理 ----------
_NEED_PAUSE=1
handle_exit() {
    if [ "$_NEED_PAUSE" = "1" ]; then
        echo ""
        echo -e "${RED}[!] 脚本异常退出${NC}"
        read -r -p "按回车关闭..." _
    fi
}
trap handle_exit EXIT
# Ctrl+C 只中断当前操作，不退出脚本
trap 'echo ""; echo -e "${YELLOW}[*] 已取消${NC}"; sleep 0.5' INT
set -E

# =============================================
# 自动探测
# =============================================
auto_detect() {
    local search_root="$SCRIPT_DIR"

    _is_bot_dir() {
        [ -f "$1/bot.py" ] && return 0
        [ -f "$1/pyproject.toml" ] && grep -qi 'maibot\|maim-message' "$1/pyproject.toml" 2>/dev/null && return 0
        return 1
    }

    if ! _is_bot_dir "$search_root"; then
        local found_sub=""
        for sub in "$search_root"/*/; do
            [ -d "$sub" ] || continue
            if _is_bot_dir "$sub"; then found_sub="$sub"; break; fi
            for sub2 in "$sub"/*/; do
                [ -d "$sub2" ] || continue
                if _is_bot_dir "$sub2"; then found_sub="$sub2"; break 2; fi
            done
        done
        [ -n "$found_sub" ] && search_root="$(cd "$found_sub" 2>/dev/null && pwd)"
    fi

    BOT_DIR="$search_root"

    # ---- venv 检测 ----
    VENV_DIR=""
    if [ -d "$BOT_DIR/.venv" ]; then
        VENV_DIR="$BOT_DIR/.venv"
    elif [ -d "$BOT_DIR/venv" ]; then
        VENV_DIR="$BOT_DIR/venv"
    elif [ -d "$SCRIPT_DIR/.venv" ]; then
        VENV_DIR="$SCRIPT_DIR/.venv"
    fi

    PYTHON_BIN="python3"
    if [ -n "$VENV_DIR" ] && [ -x "$VENV_DIR/bin/python3" ]; then
        PYTHON_BIN="$VENV_DIR/bin/python3"
    fi

    # ---- PID 文件 ----
    PID_FILE="$BOT_DIR/maibot.pid"

    # ---- 日志文件（固定为 maibot.log，启动时 nohup > 到此）----
    LOG_FILE="$BOT_DIR/maibot.log"
}

auto_detect

# =============================================
# 确保 uv 可用（首次运行自动安装）
# =============================================
ensure_uv() {
    if command -v uv &>/dev/null; then
        return 0
    fi

    warn "未检测到 uv 包管理器，正在自动安装..."
    info "uv 可以解决 pip 在部分环境下安装失败的问题"

    if command -v curl &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    elif command -v wget &>/dev/null; then
        wget -qO- https://astral.sh/uv/install.sh | sh
    else
        error "curl 和 wget 均不可用，无法自动安装 uv"
        info "请手动安装: curl -LsSf https://astral.sh/uv/install.sh | sh"
        return 1
    fi

    # 刷新 PATH（uv 安装到 ~/.local/bin 或 ~/.cargo/bin）
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

    if command -v uv &>/dev/null; then
        success "uv 安装成功: $(uv --version 2>/dev/null)"
        return 0
    else
        warn "uv 已安装但未在 PATH 中找到，请重新打开终端后重试"
        return 1
    fi
}

ensure_uv

# =============================================
# 确保 curl 可用（首次运行自动安装）
# =============================================
ensure_curl() {
    if command -v curl &>/dev/null; then
        return 0
    fi
    if command -v wget &>/dev/null; then
        info "已检测到 wget，跳过 curl 安装"
        return 0
    fi

    warn "未检测到 curl 或 wget，正在自动安装 curl..."
    info "curl 是下载脚本和依赖的必要工具"

    if command -v apt &>/dev/null; then
        sudo apt update -qq && sudo apt install curl -y -qq
    elif command -v yum &>/dev/null; then
        sudo yum install curl -y -q
    elif command -v dnf &>/dev/null; then
        sudo dnf install curl -y -q
    elif command -v pacman &>/dev/null; then
        sudo pacman -S curl --noconfirm
    else
        error "无法识别包管理器，请手动安装 curl"
        info "  Ubuntu/Debian: sudo apt install curl"
        info "  CentOS/RHEL:   sudo yum install curl"
        return 1
    fi

    if command -v curl &>/dev/null; then
        success "curl 安装成功: $(curl --version 2>/dev/null | head -1)"
        return 0
    else
        error "curl 安装失败，请手动安装后重试"
        return 1
    fi
}

ensure_curl

# =============================================
# 确保 git 可用（首次运行自动安装）
# =============================================
ensure_git() {
    if command -v git &>/dev/null; then
        return 0
    fi

    warn "未检测到 git，正在自动安装..."

    if command -v apt &>/dev/null; then
        sudo apt update -qq && sudo apt install git -y -qq
    elif command -v yum &>/dev/null; then
        sudo yum install git -y -q
    elif command -v dnf &>/dev/null; then
        sudo dnf install git -y -q
    elif command -v pacman &>/dev/null; then
        sudo pacman -S git --noconfirm
    else
        error "无法识别包管理器，请手动安装 git"
        info "  Ubuntu/Debian: sudo apt install git"
        info "  CentOS/RHEL:   sudo yum install git"
        return 1
    fi

    if command -v git &>/dev/null; then
        success "git 安装成功: $(git --version 2>/dev/null)"
        return 0
    else
        error "git 安装失败，请手动安装后重试"
        return 1
    fi
}

ensure_git

# =============================================
# 确保 MaiBot 项目存在
# =============================================
MAIBOT_REPO="https://github.com/Mai-with-u/MaiBot.git"

_verify_maibot_dir() {
    local dir="$1"
    [ -d "$dir" ] && [ -f "$dir/bot.py" ] && return 0
    return 1
}

_migrate_script_to() {
    local target_dir="$1"
    local script_name; script_name=$(basename "$0")
    local src="$SCRIPT_DIR/$script_name"
    local dst="$target_dir/$script_name"

    if [ "$src" = "$dst" ]; then
        info "脚本已在目标目录，无需迁移"
        return 0
    fi

    info "正在将脚本迁移到 $target_dir ..."
    cp "$src" "$dst" && chmod +x "$dst" || {
        error "脚本迁移失败"
        return 1
    }
    success "脚本已复制到 $dst"
    warn "脚本位置已变更，下次请运行: $dst"
    echo ""
    read -r -p "按回车退出（请重新运行新位置的脚本）..."
    exit 0
}

_suggest_maibot_path() {
    # 常见的 MaiBot 可能位置
    local guesses=(
        "$SCRIPT_DIR/MaiBot"
        "$SCRIPT_DIR/../MaiBot"
        "$HOME/MaiBot"
        "/opt/MaiBot"
        "/home/$USER/MaiBot"
    )
    local found=""
    for g in "${guesses[@]}"; do
        if _verify_maibot_dir "$g"; then
            found="$g"
            break
        fi
    done
    echo "$found"
}

install_maibot() {
    echo ""
    print_line
    echo -e "${BOLD}${MAGENTA}安装 MaiBot${RESET}"
    print_line
    echo ""

    # 选择 GitHub 代理
    echo -e "${CYAN}请选择 GitHub 下载代理:${RESET}"
    echo -e "  ${GREEN}[1]${RESET} ghfast.top 镜像 (推荐)"
    echo -e "  ${GREEN}[2]${RESET} gh.llkk.cc 镜像"
    echo -e "  ${GREEN}[3]${RESET} 不使用代理（直连 GitHub）"
    echo -e "  ${GREEN}[4]${RESET} 自定义代理"
    echo ""
    echo -ne "${BOLD}${YELLOW}请选择 [1-4]: ${RESET}"
    read -r proxy_choice
    local proxy=""
    case $proxy_choice in
        1) proxy="https://ghfast.top/" ;;
        2) proxy="https://gh.llkk.cc/" ;;
        3) proxy="" ;;
        4)
            read -r -p "请输入自定义代理 URL (以 / 结尾): " proxy
            [[ -n "$proxy" && "$proxy" != */ ]] && proxy="${proxy}/"
            ;;
        *) proxy="https://ghfast.top/" ;;
    esac

    # 选择安装位置
    echo ""
    local default_dir="$SCRIPT_DIR/MaiBot"
    echo -e "${CYAN}直接回车 = 使用默认路径 | 输入新路径 = 安装到指定位置${RESET}"
    echo -e "${BOLD}${YELLOW}安装目录 (默认: $default_dir): ${RESET}"
    echo -ne "${CYAN}> ${RESET}"
    read -r install_dir
    install_dir="${install_dir:-$default_dir}"

    echo -e "${BOLD}${YELLOW}确认安装到 $install_dir ? (Y/n): ${RESET}"
    read -r confirm
    case "${confirm:-y}" in
        y|Y|yes|YES) info "继续安装..." ;;
        *) info "已取消安装"; return ;;
    esac

    local parent_dir; parent_dir=$(dirname "$install_dir")
    if [ ! -d "$parent_dir" ]; then
        info "创建父目录: $parent_dir"
        mkdir -p "$parent_dir" || { error "无法创建目录"; return 1; }
    fi

    if [ -d "$install_dir" ]; then
        warn "目录已存在: $install_dir"
        read -r -p "是否删除并重新克隆？(y/N): " del_choice
        case "${del_choice:-n}" in
            y|Y|yes|YES) rm -rf "$install_dir" ;;
            *) info "跳过安装"; return ;;
        esac
    fi

    # 克隆
    local clone_url="${proxy}${MAIBOT_REPO}"
    info "克隆仓库: $clone_url"
    info "目标目录: $install_dir"

    local attempt=1
    while [[ $attempt -le 3 ]]; do
        info "尝试 $attempt/3..."
        if git clone --depth 1 "$clone_url" "$install_dir" 2>/dev/null; then
            success "MaiBot 克隆成功"
            break
        else
            warn "克隆失败,重试 $attempt/3"
            ((attempt++))
            sleep 5
        fi
    done

    if [[ $attempt -gt 3 ]]; then
        error "克隆失败，请检查网络或更换代理"
        return 1
    fi

    # 安装依赖
    echo ""
    info "正在安装 MaiBot 依赖..."
    cd "$install_dir" || { error "无法进入 $install_dir"; return 1; }

    info "使用 uv sync 安装依赖..."
    if uv sync -i https://pypi.tuna.tsinghua.edu.cn/simple 2>&1; then
        success "MaiBot 依赖安装成功"
    else
        warn "依赖安装可能不完整，请稍后手动执行: cd $install_dir && uv sync"
    fi

    # 迁移脚本到 MaiBot 同级目录
    _migrate_script_to "$parent_dir"
}

specify_maibot_path() {
    echo ""
    local guess; guess=$(_suggest_maibot_path)
    if [ -n "$guess" ]; then
        info "自动探测到可能的 MaiBot 位置: ${GREEN}$guess${RESET}"
        echo -ne "${BOLD}${YELLOW}使用此路径? (Y/n): ${RESET}"
        read -r use_guess
        use_guess="${use_guess:-y}"
        case "${use_guess:-y}" in
            y|Y|yes|YES)
                local parent; parent=$(dirname "$guess")
                _migrate_script_to "$parent"
                return
                ;;
        esac
    fi

    echo -ne "${BOLD}${YELLOW}请输入 MaiBot 所在目录的完整路径（包含 bot.py 的目录）: ${RESET}"
    read -r user_path

    if [ -z "$user_path" ]; then
        warn "未输入路径，跳过"
        return
    fi

    # 展开 ~
    user_path="${user_path/#\~/$HOME}"

    if ! _verify_maibot_dir "$user_path"; then
        error "该目录不存在或不包含 bot.py: $user_path"
        return
    fi

    success "检测到有效的 MaiBot: $user_path"
    local parent; parent=$(dirname "$user_path")
    _migrate_script_to "$parent"
}

ensure_maibot() {
    # auto_detect 已经找到了
    if [ -n "$BOT_DIR" ] && _verify_maibot_dir "$BOT_DIR"; then
        info "MaiBot: ${GREEN}$BOT_DIR${RESET}"
        return 0
    fi

    warn "未检测到 MaiBot 项目"

    echo ""
    echo -e "${CYAN}----------------------------------------${NC}"
    echo -e "${BOLD}未找到 MaiBot，请选择:${NC}"
    echo -e "${CYAN}----------------------------------------${NC}"
    echo -e "  ${GREEN}[1]${RESET} 🚀 自动安装 MaiBot (从 GitHub 克隆)"
    echo -e "  ${GREEN}[2]${RESET} 📁 手动指定 MaiBot 所在目录"
    echo -e "  ${GREEN}[0]${RESET} ⏭️  跳过（仅管理已有实例，稍后配置）"
    echo ""
    echo -ne "${BOLD}${YELLOW}请选择 [0-2]: ${RESET}"

    read -r choice
    case $choice in
        1)
            install_maibot
            ;;
        2)
            specify_maibot_path
            ;;
        0)
            warn "跳过 MaiBot 检测，部分功能可能不可用"
            ;;
        *)
            warn "无效选择，跳过"
            ;;
    esac
}

ensure_maibot
# 重新探测（用户可能指定了新路径，或子目录安装后已就位）
auto_detect

# 扫描所有 bot.py 进程（不依赖 PID 文件）
_scan_pids() {
    if command -v pgrep &>/dev/null; then
        pgrep -f "bot\.py" 2>/dev/null
    else
        ps aux 2>/dev/null | grep -iE 'python.*bot\.py' | grep -v grep | awk '{print $1}'
    fi
}

is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid; pid=$(cat "$PID_FILE")
        kill -0 "$pid" 2>/dev/null && return 0
        rm -f "$PID_FILE"
    fi
    # 兜底：扫描进程
    [ -n "$(_scan_pids | head -1)" ] && return 0
    return 1
}

get_pid() {
    [ -f "$PID_FILE" ] && cat "$PID_FILE" || _scan_pids | head -1
}

save_pid() {
    echo "$1" > "$PID_FILE"
}

remove_pid() {
    rm -f "$PID_FILE"
}

# =============================================
# 跨平台杀进程
# =============================================
kill_by_pattern() {
    local pattern="$1"
    if command -v pkill &>/dev/null; then
        pkill -f "$pattern" 2>/dev/null
    elif command -v taskkill &>/dev/null; then
        ps aux 2>/dev/null | grep -i "$pattern" | grep -v grep | awk '{print $1}' | while read -r p; do
            taskkill //PID "$p" //F 2>/dev/null
        done
    else
        ps aux 2>/dev/null | grep -i "$pattern" | grep -v grep | awk '{print $1}' | while read -r p; do
            kill "$p" 2>/dev/null
        done
    fi
}

# =============================================
# 启动 MaiBot
# =============================================
start_bot() {
    cd "$BOT_DIR" || { error "无法进入 $BOT_DIR"; return 1; }

    if is_running; then
        warn "MaiBot 已在运行中 (PID: $(get_pid))"
        return 1
    fi

    info "正在启动 MaiBot..."
    if command -v unbuffer &>/dev/null; then
        nohup unbuffer bash -c "$PYTHON_BIN bot.py" >> "$LOG_FILE" 2>&1 &
    else
        nohup bash -c "$PYTHON_BIN bot.py" >> "$LOG_FILE" 2>&1 &
    fi
    local pid=$!
    save_pid "$pid"

    sleep 3

    if is_running; then
        success "MaiBot 启动成功 (PID: $pid)"
        info "日志: $LOG_FILE"
        return 0
    else
        error "MaiBot 可能启动失败，请检查日志"
        remove_pid
        return 1
    fi
}

# =============================================
# 读取 WebUI 端口
# =============================================
_get_webui_port() {
    local port=""
    # 尝试从 bot_config.toml [webui] 段读取 port
    if [ -f "$BOT_DIR/config/bot_config.toml" ]; then
        # 匹配 [webui] 段下的 port = xxxx
        port=$(awk '/^\[webui\]/{found=1; next} /^\[/{found=0} found && /^\s*port\s*=/{gsub(/[^0-9]/,""); print; exit}' "$BOT_DIR/config/bot_config.toml" 2>/dev/null)
    fi
    echo "${port:-8001}"
}

# =============================================
# 读取 WebUI Access Token
# =============================================
_get_access_token() {
    local token=""
    if [ -f "$BOT_DIR/data/webui.json" ] && command -v python3 &>/dev/null; then
        token=$("$PYTHON_BIN" -c "import json; print(json.load(open('$BOT_DIR/data/webui.json')).get('access_token',''))" 2>/dev/null)
    fi
    echo "$token"
}

# =============================================
# 查找 Worker 进程 PID（带 MAIBOT_WORKER_PROCESS=1 环境变量）
# =============================================
_find_worker_pid() {
    local pids; pids=$(_scan_pids)
    for p in $pids; do
        # Linux: 通过 /proc/PID/environ 检查
        if [ -f "/proc/$p/environ" ]; then
            if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q "MAIBOT_WORKER_PROCESS=1"; then
                echo "$p"
                return 0
            fi
        fi
    done
    # 无法区分时返回空
    echo ""
    return 1
}

# =============================================
# 停止 MaiBot
# =============================================
stop_bot() {
    if ! is_running; then
        warn "MaiBot 未运行"
        remove_pid
        return 1
    fi

    local webui_port; webui_port=$(_get_webui_port)
    local access_token; access_token=$(_get_access_token)
    local worker_pid; worker_pid=$(_find_worker_pid)

    # ---- 方法1: 通过 WebUI API 触发优雅关闭（推荐）----
    if [ -n "$access_token" ] && [ -n "$webui_port" ]; then
        info "通过 WebUI API 触发优雅关闭..."

        # 调用 /system/restart，内部会依次：
        #   触发 ON_STOP 事件 → 停止插件运行时 → 取消异步任务 → os._exit(42)
        curl -s -X POST "http://127.0.0.1:${webui_port}/api/webui/system/restart" \
             -H "Cookie: maibot_session=${access_token}" \
             --max-time 5 2>/dev/null && {
            info "API 请求已发送，Worker 正在执行优雅清理..."
        } || warn "WebUI API 请求失败，将尝试信号方式"

        # 立即杀掉 Runner 进程（防止它在 Worker 退出码=42 时重启 Worker）
        # Runner 是没有 MAIBOT_WORKER_PROCESS 的 bot.py 进程
        local runner_killed=0
        for p in $(_scan_pids); do
            if [ -n "$worker_pid" ] && [ "$p" = "$worker_pid" ]; then
                continue  # 跳过 Worker
            fi
            kill "$p" 2>/dev/null && runner_killed=1
        done
        [ "$runner_killed" = "1" ] && info "已终止 Runner 进程（防止自动重启）"
    else
        warn "无法获取 WebUI Token 或端口，跳过 API 方式"
    fi

    # ---- 方法2: 直接向 Worker 发送 SIGINT（兜底）----
    if is_running; then
        if [ -n "$worker_pid" ]; then
            info "向 Worker 进程发送 SIGINT..."
            kill -INT "$worker_pid" 2>/dev/null
        else
            # 无法识别 Worker，对所有 bot.py 发 SIGINT
            info "发送 SIGINT 到所有 bot.py 进程..."
            if command -v pkill &>/dev/null; then
                pkill -INT -f "bot\.py" 2>/dev/null
            fi
        fi
    fi

    # ---- 等待优雅退出 (30s) ----
    local count=0
    while is_running && [ $count -lt 30 ]; do
        sleep 1
        count=$((count + 1))
        if [ $((count % 5)) -eq 0 ]; then
            info "等待 MaiBot 退出... (${count}s/30s)"
        fi
    done

    # ---- 超时后强制 kill -9（最后兜底）----
    if is_running; then
        warn "优雅停止超时，强制终止..."
        if command -v pkill &>/dev/null; then
            pkill -9 -f "bot\.py" 2>/dev/null
        else
            ps aux 2>/dev/null | grep -iE 'python.*bot\.py' | grep -v grep | awk '{print $1}' | while read -r p; do
                kill -9 "$p" 2>/dev/null
            done
        fi
        sleep 2
    fi

    # ---- 清理 bash wrapper（nohup 启动时的 bash 层）----
    local saved_pid; saved_pid=$(get_pid)
    if [ -n "$saved_pid" ]; then
        kill -0 "$saved_pid" 2>/dev/null && kill "$saved_pid" 2>/dev/null
        sleep 1
        kill -0 "$saved_pid" 2>/dev/null && kill -9 "$saved_pid" 2>/dev/null
    fi

    if ! is_running; then
        remove_pid
        success "MaiBot 已停止"
        return 0
    else
        error "MaiBot 停止失败，请手动 kill"
        return 1
    fi
}

# =============================================
# 重启 MaiBot
# =============================================
restart_bot() {
    stop_bot
    sleep 1
    start_bot
}

# =============================================
# =============================================
# 更新 MaiBot
# =============================================
update_bot() {
    cd "$BOT_DIR" || { error "无法进入 $BOT_DIR"; return; }

    if [ ! -d ".git" ]; then
        error "不是 Git 仓库，无法更新"
        return
    fi

    # ---- 选择 GitHub 代理 ----
    local remote_url; remote_url=$(git remote get-url origin 2>/dev/null)
    echo ""
    echo -e "${CYAN}当前远程仓库: ${GREEN}${remote_url:-未知}${RESET}"
    echo ""
    echo -e "${CYAN}请选择 GitHub 下载代理:${RESET}"
    echo -e "  ${GREEN}[1]${RESET} ghfast.top 镜像 (推荐)"
    echo -e "  ${GREEN}[2]${RESET} gh.llkk.cc 镜像"
    echo -e "  ${GREEN}[3]${RESET} 不使用代理（直连 GitHub）"
    echo -e "  ${GREEN}[4]${RESET} 自定义代理"
    echo ""
    echo -ne "${BOLD}${YELLOW}请选择 [1-4]: ${RESET}"
    read -r proxy_choice
    local proxy=""
    case $proxy_choice in
        1) proxy="https://ghfast.top/" ;;
        2) proxy="https://gh.llkk.cc/" ;;
        3) proxy="" ;;
        4)
            read -r -p "请输入自定义代理 URL (以 / 结尾): " proxy
            [[ -n "$proxy" && "$proxy" != */ ]] && proxy="${proxy}/"
            ;;
        *) proxy="https://ghfast.top/" ;;
    esac

    info "正在备份data和config"
    if [ -d "../backup" ]; then
        info "备份文件夹已存在"
        rm -rf ../backup/*
    else
        mkdir -p "../backup"
    fi
    cp -r ./config "../backup/"
    cp -r ./data "../backup/"
    cp -r ./plugins "../backup/"

    info "开始处理Git更新"

    # 检查是否有本地修改
    if git diff --quiet && git diff --staged --quiet; then
        info "没有本地修改，直接拉取更新"
    else
        info "保存本地修改..."
        git stash push -m "auto-update-local-changes-$(date +%Y%m%d-%H%M%S)"
    fi

    info "拉取远程仓库最新代码..."
    if [ -n "$proxy" ]; then
        info "使用代理: ${proxy}"
        if git -c url."${proxy}".insteadOf=https://github.com/ pull --force --progress; then
            success "仓库已成功拉取"
        else
            error "仓库拉取失败，请检查网络或更换代理后重试"
            return
        fi
    else
        info "直连 GitHub..."
        if git pull --force --progress; then
            success "仓库已成功拉取"
        else
            error "仓库拉取失败，请检查网络或尝试使用代理后重试"
            return
        fi
    fi

    # 如果有保存的stash，则尝试恢复
    if git stash list | grep -q "auto-update-local-changes"; then
        info "恢复本地修改并尝试合并..."
        if git stash pop; then
            success "本地修改已成功合并"
        else
            warn "自动合并出现冲突，需要手动解决"
            info "请手动执行以下命令来解决冲突："
            info "1. 查看冲突文件: git diff --name-only --diff-filter=U"
            info "2. 手动编辑冲突文件解决冲突"
            info "3. 标记冲突已解决: git add <冲突文件>"
            info "4. 完成合并: git stash drop"
        fi
    fi

    info "安装依赖 (uv sync)..."
    cd "$BOT_DIR"

    # 删除旧的 uv.lock 避免版本不兼容导致解析失败
    if [ -f "uv.lock" ]; then
        info "清除旧的 uv.lock..."
        rm -f uv.lock
    fi

    if uv sync -i https://pypi.tuna.tsinghua.edu.cn/simple 2>&1; then
        success "MaiBot 依赖安装成功"
    else
        error "依赖安装失败，请手动执行: cd $BOT_DIR && uv sync"
    fi

    # 更新 VENV_DIR（uv sync 创建 .venv）
    if [ -d "$BOT_DIR/.venv" ]; then
        VENV_DIR="$BOT_DIR/.venv"
        PYTHON_BIN="$VENV_DIR/bin/python3"
    fi
    info "更新已结束"
    echo ""
    read -r -p "按回车返回菜单..."
}

# =============================================
# 更新并重启
# =============================================
update_and_restart() {
    stop_bot
    sleep 1
    update_bot
    echo ""
    start_bot
}

# =============================================
# 日志查看
# =============================================
follow_log() {
    if [ ! -f "$LOG_FILE" ]; then
        warn "日志文件不存在: $LOG_FILE"
        info "正在等待日志文件生成..."
        while [ ! -f "$LOG_FILE" ]; do sleep 1; done
    fi
    echo -e "${GREEN}[*] 实时追踪日志 (按 Ctrl+C 返回)${NC}"
    echo ""
    tail -n 50 -f "$LOG_FILE" 2>/dev/null
}

view_last_n() {
    local n=$1
    if [ ! -f "$LOG_FILE" ]; then
        error "日志文件不存在: $LOG_FILE"
    else
        echo -e "${GREEN}[*] 最近 $n 行:${NC}"
        echo -e "${CYAN}--------------------------------------${NC}"
        tail -n "$n" "$LOG_FILE" 2>/dev/null
        echo -e "${CYAN}--------------------------------------${NC}"
    fi
    echo ""
    read -r -p "按回车返回菜单..."
}

search_log() {
    if [ ! -f "$LOG_FILE" ]; then
        error "日志文件不存在: $LOG_FILE"
        read -r -p "按回车返回菜单..."
        return
    fi
    read -r -p "请输入搜索关键词: " keyword
    if [ -z "$keyword" ]; then
        warn "关键词不能为空"
    else
        echo -e "${GREEN}[*] 搜索 \"$keyword\" (最近 500 行):${NC}"
        echo -e "${CYAN}--------------------------------------${NC}"
        tail -n 500 "$LOG_FILE" 2>/dev/null | grep -i --color=always "$keyword" || echo "(无匹配)"
        echo -e "${CYAN}--------------------------------------${NC}"
    fi
    echo ""
    read -r -p "按回车返回菜单..."
}

check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${GREEN}[*] 日志文件信息:${NC}"
        echo -e "  路径: $LOG_FILE"
        echo -e "  大小: $(du -h "$LOG_FILE" | cut -f1)"
        echo -e "  行数: $(wc -l < "$LOG_FILE")"
    else
        warn "日志文件不存在: $LOG_FILE"
    fi
    echo ""
    read -r -p "按回车返回菜单..."
}

# =============================================
# 清理日志
# =============================================
clean_logs() {
    if [ -f "$LOG_FILE" ]; then
        > "$LOG_FILE"
        success "已清空日志"
    else
        warn "日志文件不存在"
    fi
    # 清理无效 PID
    if [ -f "$PID_FILE" ] && ! is_running; then
        remove_pid
        info "已清理无效 PID 文件"
    fi
    echo ""
    read -r -p "按回车返回菜单..."
}

# =============================================
# 安装 NapCatQQ
# =============================================
NAPCAT_INSTALLER_URL="https://nclatest.znin.net/NapNeko/NapCat-Installer/main/script/install.sh"

install_napcat() {
    echo ""
    print_line
    echo -e "${BOLD}${MAGENTA}安装 NapCatQQ${RESET}"
    print_line
    echo ""

    info "NapCatQQ 是基于无头 NTQQ 的 OneBot 协议实现，用于 MaiBot 连接 QQ"
    info "安装位置: ${GREEN}$HOME${RESET} (用户主目录)"
    echo ""

    # 选择 GitHub 代理
    echo -e "${CYAN}请选择下载代理:${RESET}"
    echo -e "  ${GREEN}[1]${RESET} ghfast.top 镜像 (推荐)"
    echo -e "  ${GREEN}[2]${RESET} gh.llkk.cc 镜像"
    echo -e "  ${GREEN}[3]${RESET} 不使用代理（直连）"
    echo -e "  ${GREEN}[4]${RESET} 自定义代理"
    echo ""
    echo -ne "${BOLD}${YELLOW}请选择 [1-4]: ${RESET}"
    read -r proxy_choice
    local proxy=""
    case $proxy_choice in
        1) proxy="https://ghfast.top/" ;;
        2) proxy="https://gh.llkk.cc/" ;;
        3) proxy="" ;;
        4)
            read -r -p "请输入自定义代理 URL (以 / 结尾): " proxy
            [[ -n "$proxy" && "$proxy" != */ ]] && proxy="${proxy}/"
            ;;
        *) proxy="https://ghfast.top/" ;;
    esac

    echo ""
    echo -e "${BOLD}${YELLOW}确认安装 NapCatQQ？(Y/n): ${RESET}"
    read -r confirm
    case "${confirm:-y}" in
        y|Y|yes|YES) info "继续安装..." ;;
        *) info "已取消安装"; return ;;
    esac

    # 下载安装脚本
    local installer_url
    local installer_file="$HOME/napcat-install.sh"

    if [ -n "$proxy" ]; then
        installer_url="${proxy}https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh"
    else
        installer_url="$NAPCAT_INSTALLER_URL"
    fi

    info "下载 NapCat 安装脚本..."
    info "URL: $installer_url"
    echo ""

    if command -v curl &>/dev/null; then
        if curl -L --progress-bar -o "$installer_file" "$installer_url"; then
            success "脚本下载完成"
        else
            error "下载失败，请检查网络或更换代理后重试"
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if wget --show-progress -O "$installer_file" "$installer_url"; then
            success "脚本下载完成"
        else
            error "下载失败，请检查网络或更换代理后重试"
            return 1
        fi
    else
        error "curl 和 wget 均不可用，无法下载"
        return 1
    fi

    # 运行安装脚本
    echo ""
    info "运行 NapCat 官方安装脚本..."
    echo ""
    print_line

    chmod +x "$installer_file"
    if bash "$installer_file"; then
        success "NapCatQQ 安装完成"
    else
        warn "安装脚本退出（可能已手动完成或取消）"
    fi

    # 清理安装脚本
    rm -f "$installer_file"

    echo ""
    print_line
    echo -e "${BOLD}安装后配置步骤:${NC}"
    echo -e "  ${GREEN}1${NC} 终端输入 ${CYAN}napcat${NC} 启动管理面板"
    echo -e "  ${GREEN}2${NC} 浏览器访问 ${CYAN}http://localhost:6099/webui${NC}"
    echo -e "  ${GREEN}3${NC} 默认 Token: ${CYAN}napcat${NC}"
    echo -e "  ${GREEN}4${NC} 扫码登录 QQ（建议使用小号）"
    echo -e "  ${GREEN}5${NC} 配置 WebSocket 连接到 MaiBot"
    print_line
    echo ""
    read -r -p "按回车返回菜单..."
}

# =============================================
# 主菜单
# =============================================
show_menu() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}     MaiBot 管理面板${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 系统信息
    echo -e "${CYAN}系统信息:${NC}"
    echo -e "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  项目: ${GREEN}$BOT_DIR${NC}"
    echo -e "  venv: ${GREEN}${VENV_DIR:-未检测到}${NC}"

    # 服务状态
    echo ""
    echo -e "${CYAN}服务状态:${NC}"
    if is_running; then
        echo -e "  MaiBot: ${GREEN}[运行中]${NC} PID: $(get_pid)"
    else
        echo -e "  MaiBot: ${RED}[已停止]${NC}"
    fi

    # 日志状态
    if [ -f "$LOG_FILE" ]; then
        echo -e "  日志:   ${GREEN}$LOG_FILE${NC} ($(du -h "$LOG_FILE" | cut -f1))"
    else
        echo -e "  日志:   ${RED}不存在${NC}"
    fi

    echo ""
    echo -e "${CYAN}----------------------------------------${NC}"
    echo -e "${BOLD}操作菜单:${NC}"
    echo -e "${CYAN}----------------------------------------${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}  ▶  启动 MaiBot"
    echo -e "  ${GREEN}2${NC}  ⏹  停止 MaiBot"
    echo -e "  ${GREEN}3${NC}  🔄 重启 MaiBot"
    echo ""
    echo -e "  ${GREEN}4${NC}  📋 实时查看日志 (tail -f)"
    echo -e "  ${GREEN}5${NC}  📄 查看最近 50 行"
    echo -e "  ${GREEN}6${NC}  🔍 搜索日志关键词"
    echo ""
    echo -e "  ${GREEN}7${NC}  🔺 更新代码并重启"
    echo ""
    echo -e "  ${GREEN}8${NC}  📊 日志文件信息"
    echo -e "  ${GREEN}c${NC}  🧹 清理日志"
    echo ""
    echo -e "  ${GREEN}n${NC}  🐱 安装 NapCatQQ"
    echo ""
    echo -e "  ${GREEN}0${NC}  ❌ 退出"
    echo ""

    echo -ne "${BOLD}请选择 [0-8/c/n]: ${NC}"
}

# =============================================
# 主循环
# =============================================
while true; do
    show_menu
    read -r choice
    case $choice in
        1) start_bot ;;
        2) stop_bot ;;
        3) restart_bot ;;
        4) follow_log ;;
        5) view_last_n 50 ;;
        6) search_log ;;
        7) update_and_restart ;;
        8) check_log_size ;;
        c|C) clean_logs ;;
        n|N) install_napcat ;;
        0)
            _NEED_PAUSE=0
            echo -e "${GREEN}再见!${NC}"
            exit 0
            ;;
        *)
            error "无效选项，按回车重试..."
            read -r
            ;;
    esac
done
