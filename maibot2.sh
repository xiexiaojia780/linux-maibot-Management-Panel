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
# PID 进程管理
# =============================================
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
# 更新 MaiBot（与原版 maibot.sh 完全一致）
# =============================================
update_bot() {
    cd "$BOT_DIR" || { error "无法进入 $BOT_DIR"; return; }

    if [ ! -d ".git" ]; then
        error "不是 Git 仓库，无法更新"
        return
    fi

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
    if git pull --force; then
        success "仓库已成功拉取"
    else
        warn "仓库拉取失败"
        return
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

    info "激活虚拟环境"
    source "$VENV_DIR/bin/activate"
    info "开始安装依赖"
    # 安装 MaiBot 依赖
    attempt=1
    while [[ $attempt -le 3 ]]; do
        if [[ -f "requirements.txt" ]]; then
            if pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple --upgrade; then
                success "MaiBot 依赖安装成功"
                break
            else
                warn "MaiBot 依赖安装失败,重试 $attempt/3"
                ((attempt++))
                sleep 5
            fi
        else
            error "未找到 requirements.txt 文件"
            break
        fi
    done

    if [[ $attempt -gt 3 ]]; then
        error "MaiBot 依赖安装多次失败"
    fi
    deactivate
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
    echo -e "  ${GREEN}0${NC}  ❌ 退出"
    echo ""

    echo -ne "${BOLD}请选择 [0-8/c]: ${NC}"
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
