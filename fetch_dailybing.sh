#!/bin/bash
# 功能：下载每日必应故事图片，支持日期范围、并发、自定义路径、文件存在跳过、进度条、临时文件、断点续传、HTML实体解码，以及同名日期旧文件重命名

# 获取脚本所在目录作为默认输出目录
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR="$SCRIPT_DIR"
MAX_CONCURRENT=1

# 最早允许日期和今天日期（硬编码）
EARLIEST_DATE="20210315"
TODAY_STR=$(date +%Y%m%d)

# 用法说明
usage() {
    echo "用法: $0 [-d 输出目录] [-j 并发数] YYYYMMDD [YYYYMMDD]"
    echo "示例:"
    echo "  单日下载到脚本所在目录: $0 20260224"
    echo "  指定目录和并发数: $0 -d ./bing_images -j 5 20260201 20260228"
    exit 1
}

# 解析命令行选项
while getopts "d:j:h" opt; do
    case $opt in
        d) OUTPUT_DIR="$OPTARG" ;;
        j) MAX_CONCURRENT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# 检查日期参数个数
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
fi

# 创建输出目录（如果不存在）
mkdir -p "$OUTPUT_DIR" || { echo "错误：无法创建目录 $OUTPUT_DIR"; exit 1; }

# 检测 date 命令风格
detect_date_style() {
    if date -d "20250101" +%Y%m%d >/dev/null 2>&1; then
        echo "gnu"
    elif date -j -f "%Y%m%d" "20250101" +%Y%m%d >/dev/null 2>&1; then
        echo "bsd"
    else
        echo "unknown"
    fi
}

# 将 YYYYMMDD 转换为秒数（兼容 GNU 和 BSD date）
date_to_seconds() {
    local date_str=$1
    local style=$(detect_date_style)
    case $style in
        gnu) date -d "$date_str" +%s 2>/dev/null ;;
        bsd) date -j -f "%Y%m%d" "$date_str" +%s 2>/dev/null ;;
        *) echo ""; return 1 ;;
    esac
}

# 验证日期格式并在允许范围内
validate_date() {
    local date_str=$1
    if ! [[ "$date_str" =~ ^[0-9]{8}$ ]]; then
        echo "错误: 日期格式必须为 YYYYMMDD (如 20260224)"
        exit 1
    fi

    # 转换为秒数（同时检查有效性）
    local seconds=$(date_to_seconds "$date_str")
    if [ -z "$seconds" ]; then
        echo "错误: 无效日期 $date_str"
        exit 1
    fi

    # 范围检查：不能早于最早日期
    local earliest_seconds=$(date_to_seconds "$EARLIEST_DATE")
    if [ "$seconds" -lt "$earliest_seconds" ]; then
        echo "错误: 日期 $date_str 早于允许的最早日期 $EARLIEST_DATE"
        exit 1
    fi

    # 范围检查：不能晚于今天
    local today_seconds=$(date_to_seconds "$TODAY_STR")
    if [ "$seconds" -gt "$today_seconds" ]; then
        echo "错误: 日期 $date_str 晚于今天 $TODAY_STR"
        exit 1
    fi

    return 0
}

# 日期递增函数
next_day() {
    local current=$1
    local style=$(detect_date_style)
    case $style in
        gnu) date -d "$current +1 day" +%Y%m%d 2>/dev/null ;;
        bsd) date -j -v+1d -f "%Y%m%d" "$current" +%Y%m%d 2>/dev/null ;;
        *)
            echo "错误: 无法识别的 date 命令" >&2
            exit 1
            ;;
    esac
}

# HTML实体解码函数（处理常见实体）
decode_html_entities() {
    echo "$1" | sed \
        -e 's/&ldquo;/“/g' \
        -e 's/&rdquo;/”/g' \
        -e 's/&nbsp;/ /g' \
        -e 's/&amp;/\&/g' \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' \
        -e "s/&#39;/'/g" \
        -e 's/&hellip;/…/g' \
        -e 's/&mdash;/—/g'
}

# 下载单日图片（接受日期和输出目录参数）
download_date() {
    local date=$1
    local outdir=$2

    # 获取标题
    local title_url="https://dailybing.com/bing/zh-cn/${date}.html"
    local title=""
    echo "[$date] 正在提取标题..."

    # --- 新增最高优先级方法：从 class="copyright" 的 a 标签提取，并去除括号内容 ---
    if [ -z "$title" ]; then
        local raw_title=""
        if command -v pup >/dev/null 2>&1; then
            raw_title=$(curl -s "$title_url" | pup 'div.copyright a text{}' | head -1)
        else
            # 后备：正则提取 copyright div 中的 a 标签文本
            raw_title=$(curl -s "$title_url" | \
                        grep -o '<div[^>]*class="copyright"[^>]*>.*</div>' | \
                        grep -o '<a[^>]*>.*</a>' | \
                        sed -e 's/<[^>]*>//g' | head -1)
        fi
        if [ -n "$raw_title" ]; then
            # 去除末尾的括号及内容，例如 " (© Designpics/Adobe Stock)"
            # 使用 sed 去除最后一个括号及其内容（如果存在）
            title=$(echo "$raw_title" | sed 's/\s*([^)]*)\s*$//')
            # 如果去除后为空（极少见），则保留原样
            [ -z "$title" ] && title="$raw_title"
        fi
    fi

    # --- 原优先级最高的方法（现在降为第二优先级）：从 class="title" 提取 ---
    if [ -z "$title" ]; then
        if command -v pup >/dev/null 2>&1; then
            title=$(curl -s "$title_url" | pup '.title text{}' | head -1)
        else
            title=$(curl -s "$title_url" | \
                    grep -o '<[^>]*class="title"[^>]*>.*</[^>]*>' | \
                    sed -e 's/<[^>]*>//g' | head -1)
        fi
    fi

    # --- 最后尝试的方法：从 class="story-title" 的 strong 标签提取（静默切换） ---
    if [ -z "$title" ]; then
        if command -v pup >/dev/null 2>&1; then
            title=$(curl -s "$title_url" | pup '.story-title strong text{}' | head -1)
        else
            title=$(curl -s "$title_url" | \
                    grep -o '<[^>]*class="story-title"[^>]*>.*</[^>]*>' | \
                    sed -n 's/.*<strong>\(.*\)<\/strong>.*/\1/p')
        fi
    fi

    # 去除首尾空白
    title=$(echo "$title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # 根据标题是否为空决定文件名
    if [ -n "$title" ]; then
        # 解码HTML实体
        title=$(decode_html_entities "$title")
        echo "[$date] 解码后标题：$title"
        # 清理标题中非法字符（文件系统不允许的字符）
        local safe_title=$(echo "$title" | sed 's/[\/:*?"<>|]/-/g')
        local filename="${outdir}/${date}@${safe_title}.jpg"
    else
        echo "[$date] 警告：未能提取到标题，将使用纯日期作为文件名。"
        local filename="${outdir}/${date}.jpg"
    fi

    local tmp_filename="${filename}.tmp"

    # 检查最终文件是否已存在（新标题文件）
    if [ -f "$filename" ]; then
        echo "[$date] 文件已存在，跳过下载: $filename"
        return 0
    fi

    # 查找该日期的所有旧文件（包括带标题和不带标题的）
    local old_files=()
    while IFS= read -r -d '' file; do
        old_files+=("$file")
    done < <(find "$outdir" -maxdepth 1 -type f \( -name "${date}@*.jpg" -o -name "${date}.jpg" \) -print0 2>/dev/null)

    for oldf in "${old_files[@]}"; do
        if [ -f "$oldf" ] && [ "$(basename "$oldf")" != "$(basename "$filename")" ]; then
            echo "[$date] 发现旧文件 $(basename "$oldf")，重命名为 $(basename "$filename")"
            mv -f "$oldf" "$filename" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "[$date] 重命名成功，跳过下载"
                return 0
            else
                echo "[$date] 重命名失败，将继续下载新文件"
            fi
            break
        fi
    done

    # 下载图片（支持断点续传）
    local download_url="https://dailybing.com/download/${date}/zh-cn/UHD.html"
    local referer="https://dailybing.com/bing/zh-cn/${date}.html"
    local resume_option=""

    echo "[$date] 正在下载图片 -> $filename"

    # 如果存在临时文件，尝试续传
    if [ -f "$tmp_filename" ]; then
        echo "[$date] 发现未完成文件，尝试续传..."
        if command -v wget >/dev/null 2>&1; then
            resume_option="-c"  # wget 续传选项
        elif command -v curl >/dev/null 2>&1; then
            resume_option="-C -" # curl 续传选项
        fi
    fi

    if command -v wget >/dev/null 2>&1; then
        wget --referer="$referer" \
             --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" \
             $resume_option -q -O "$tmp_filename" "$download_url"
    elif command -v curl >/dev/null 2>&1; then
        curl -s -L -e "$referer" \
             -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" \
             $resume_option -o "$tmp_filename" "$download_url"
    else
        echo "[$date] 错误：未找到 wget 或 curl。"
        return 1
    fi

    if [ $? -eq 0 ] && [ -s "$tmp_filename" ]; then
        mv "$tmp_filename" "$filename"
        local size=$(du -h "$filename" | cut -f1)
        echo "[$date] 下载成功 (${size})"
        return 0
    else
        echo "[$date] 下载失败或文件为空"
        rm -f "$tmp_filename"
        return 1
    fi
}

# 生成日期列表
generate_date_list() {
    local start=$1
    local end=$2
    local list=()
    local current=$start
    while [ "$current" -le "$end" ]; do
        list+=("$current")
        [ "$current" = "$end" ] && break
        current=$(next_day "$current")
        if [ -z "$current" ] || [ "$current" = "$start" ]; then
            echo "错误：日期计算异常" >&2
            exit 1
        fi
    done
    printf '%s\n' "${list[@]}"
}

# 显示进度条
show_progress() {
    local completed=$1
    local total=$2
    local percent=$((completed * 100 / total))
    local bar_width=50
    local filled=$((percent * bar_width / 100))
    printf "\r进度: [%s%s] %d/%d (%d%%)" \
           "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
           "$(printf '%*s' $((bar_width - filled)) '')" \
           "$completed" "$total" "$percent"
}

# 检查是否支持 wait -n
wait_n_supported() {
    ( wait -n 2>/dev/null ) &
    local pid=$!
    sleep 0.1
    if kill -0 $pid 2>/dev/null; then
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
        return 0
    else
        return 1
    fi
}

# 主逻辑
# 验证日期（包括格式、有效性和范围）
validate_date "$1"
if [ $# -eq 2 ]; then
    validate_date "$2"
    # 检查开始日期是否晚于结束日期
    if [ "$1" \> "$2" ]; then
        echo "错误: 开始日期不能晚于结束日期"
        exit 1
    fi
    echo "准备下载从 $1 到 $2 的所有图片，保存到 $OUTPUT_DIR"
    # 生成日期列表
    dates=()
    while IFS= read -r d; do
        dates+=("$d")
    done < <(generate_date_list "$1" "$2")
else
    echo "准备下载单日 $1 图片，保存到 $OUTPUT_DIR"
    dates=("$1")
fi

# 并发下载控制（真并发）
total=${#dates[@]}
echo "共 $total 个日期需要处理，并发数 $MAX_CONCURRENT"

completed=0
declare -A pid_to_date
job_count=0
index=0

show_progress 0 $total

if wait_n_supported; then
    USE_WAIT_N=true
else
    USE_WAIT_N=false
    echo "注意：当前 Bash 版本不支持 wait -n，将使用轮询方式，效率略低。"
fi

while [ $completed -lt $total ]; do
    while [ $job_count -lt $MAX_CONCURRENT ] && [ $index -lt $total ]; do
        date="${dates[$index]}"
        download_date "$date" "$OUTPUT_DIR" &
        pid=$!
        pid_to_date[$pid]="$date"
        job_count=$((job_count + 1))
        index=$((index + 1))
    done

    if [ $job_count -eq 0 ]; then
        break
    fi

    if $USE_WAIT_N; then
        wait -n 2>/dev/null
        for pid in "${!pid_to_date[@]}"; do
            if ! kill -0 $pid 2>/dev/null; then
                wait $pid 2>/dev/null
                unset pid_to_date[$pid]
                job_count=$((job_count - 1))
                completed=$((completed + 1))
                show_progress $completed $total
                break
            fi
        done
    else
        while true; do
            for pid in "${!pid_to_date[@]}"; do
                if ! kill -0 $pid 2>/dev/null; then
                    wait $pid 2>/dev/null
                    unset pid_to_date[$pid]
                    job_count=$((job_count - 1))
                    completed=$((completed + 1))
                    show_progress $completed $total
                    break 2
                fi
            done
            sleep 0.2
        done
    fi
done

echo
echo "所有任务完成！"