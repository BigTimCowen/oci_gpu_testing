#!/bin/bash
#
# gpu_ops_testing.sh - GPU Operational Testing & POC Environment Tool
#
# Description:
#   Interactive tool for GPU operational testing, POC stack deployments,
#   OKE node management, custom image operations, and instance metadata inspection.
#
# Dependencies:
#   - oci CLI (configured)
#   - jq (JSON processor)
#   - curl
#   - Optional: kubectl (for OKE testing features)
#
# Usage:
#   ./gpu_ops_testing.sh [OPTIONS]
#   Run with --help for full usage information.
#
# Configuration:
#   Uses variables.sh for environment configuration (COMPARTMENT_ID, REGION, TENANCY_ID, etc.)
#   Auto-populates from IMDS metadata if running on OCI instance.
#
# Author: Tim Cowen (framework) / Claude (generated)
# Version: 1.0
# Please use at your own risk.
#
#===============================================================================
# CODING STANDARDS — follows k8s_get_node_details.sh framework
#===============================================================================
#
# NAVIGATION:
#   Main menu → p)POCs  t)OKE Testing  i)Images  m)Metadata  env)Focus
#   Shortcuts: p1=OKE Stack, p2=Slurm 2.x, p3=Slurm 3.x
#   Every menu supports: b=back, show=redraw, r=refresh cache
#   Every menu supports: env (full menu), env c, env r
#
# UI HELPERS: _ui_banner, _ui_breadcrumb, _ui_section, _ui_subheader,
#   _ui_env_info, _ui_actions, _ui_action_group, _ui_prompt, _ui_pause,
#   _ui_confirm, _ui_table_header, _ui_menu_header
#
# LOGGING (create/update/delete):
#   - Show exact command on screen before execution
#   - Log to ${LOGS_DIR}/<action>_actions.log with timestamp
#
# COLORS: GREEN=success, YELLOW=selection/warning, RED=error,
#   CYAN=labels/prompts, MAGENTA=groups, BLUE=compartments,
#   GRAY=metadata, WHITE=primary content

set -o pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly LIGHT_GREEN='\033[92m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly GRAY='\033[0;90m'
readonly ORANGE='\033[38;5;208m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'
readonly CLEAR_LINE='\033[2K\r'
readonly CLEAR_EOL='\033[K'

# Debug mode (set via --debug command line flag)
DEBUG_MODE=false

# UI width for formatting
readonly UI_WIDTH=${UI_WIDTH:-120}

# Script directory and paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="${SCRIPT_DIR}/cache"
readonly TEMP_DIR="${CACHE_DIR}/tmp"

# Cleanup handler
_cleanup_all() {
    [[ -n "${_STEP_ANIM_PID:-}" ]] && kill "$_STEP_ANIM_PID" 2>/dev/null
    [[ -n "${_PROGRESS_PID:-}" ]] && kill "$_PROGRESS_PID" 2>/dev/null
    local _bg_pids
    _bg_pids=$(jobs -p 2>/dev/null)
    [[ -n "$_bg_pids" ]] && echo "$_bg_pids" | xargs -r kill 2>/dev/null
    printf '%b' "${NC:-\033[0m}" 2>/dev/null
    rm -rf "${TEMP_DIR:?}"/* 2>/dev/null
}
trap _cleanup_all EXIT
trap 'printf "\n" 2>/dev/null; exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'printf "\n" 2>/dev/null; exit 131' QUIT

# Cache file paths
readonly CUSTOM_IMAGE_CACHE="${CACHE_DIR}/custom_images.json"
readonly PLATFORM_IMAGE_CACHE="${CACHE_DIR}/platform_images.json"
readonly OKE_CLUSTERS_CACHE="${CACHE_DIR}/oke_clusters.json"
readonly OKE_NODEPOOLS_CACHE="${CACHE_DIR}/oke_nodepools.json"
readonly INSTANCE_CONFIGS_CACHE="${CACHE_DIR}/instance_configs.json"
readonly RM_STACKS_CACHE="${CACHE_DIR}/rm_stacks.json"
readonly COMPARTMENTS_CACHE="${CACHE_DIR}/compartments.json"
readonly IDENTITY_DOMAINS_CACHE="${CACHE_DIR}/identity_domains.json"
readonly COMPUTE_HOST_SCAN_CACHE="${CACHE_DIR}/compute_host_scan.json"

# Cache TTL (seconds)
readonly CACHE_MAX_AGE=3600
declare -gA CACHE_TTL_MAP=(
    ["$OKE_CLUSTERS_CACHE"]=300
    ["$OKE_NODEPOOLS_CACHE"]=300
    ["$INSTANCE_CONFIGS_CACHE"]=600
)
_cache_ttl() { echo "${CACHE_TTL_MAP[$1]:-$CACHE_MAX_AGE}"; }

# Parallelism
readonly OCI_MAX_PARALLEL=${OCI_MAX_PARALLEL:-10}

# Environment Focus System
FOCUS_REGION=""
FOCUS_COMPARTMENT_ID=""
FOCUS_OKE_CLUSTER_ID=""
FOCUS_OKE_CLUSTER_NAME=""
FOCUS_REGION_SOURCE=""
FOCUS_COMPARTMENT_SOURCE=""
FOCUS_OKE_SOURCE=""

# POC Stack GitHub URLs
readonly IMDS_BASE="http://169.254.169.254/opc/v2"
readonly IMDS_TIMEOUT=5

# IMDS helper — always uses -m timeout to avoid hanging off-OCI
_imds_get() {
    local endpoint="$1"
    curl -sH "Authorization: Bearer Oracle" -m "$IMDS_TIMEOUT" -L "${IMDS_BASE}/${endpoint}" 2>/dev/null
}

readonly POC_OKE_STACK_URL="https://github.com/BigTimCowen/Projects/blob/main/OKE-Stack/oci-hpc-oke-poc-environment.sh"
readonly POC_OKE_STACK_RAW="https://raw.githubusercontent.com/BigTimCowen/Projects/main/OKE-Stack/oci-hpc-oke-poc-environment.sh"
readonly POC_SLURM_2X_URL="https://github.com/BigTimCowen/Projects/blob/main/Slurm/2.x/oci-hpc-poc-environment.sh"
readonly POC_SLURM_2X_RAW="https://raw.githubusercontent.com/BigTimCowen/Projects/main/Slurm/2.x/oci-hpc-poc-environment.sh"
readonly POC_SLURM_3X_URL="https://github.com/BigTimCowen/Projects/blob/main/Slurm/3.x/oci-hpc-poc-environmentfor3.0.sh"
readonly POC_SLURM_3X_RAW="https://raw.githubusercontent.com/BigTimCowen/Projects/main/Slurm/3.x/oci-hpc-poc-environmentfor3.0.sh"

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

log_error() {
    [[ "${_LOG_QUIET:-0}" == "1" ]] && return 0
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    [[ "${_LOG_QUIET:-0}" == "1" ]] && return 0
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_info() {
    [[ "${_LOG_QUIET:-0}" == "1" ]] && return 0
    echo "$1" >&2
}

log_debug() {
    [[ "$DEBUG_MODE" == "true" ]] && echo -e "${GRAY}[DEBUG]${NC} $1" >&2
}

# Logs directory
LOGS_DIR="${LOGS_DIR:-./logs}"
( umask 077 && mkdir -p "$LOGS_DIR" 2>/dev/null )

# Action log file
ACTION_LOG_FILE="${ACTION_LOG_FILE:-${LOGS_DIR}/gpu_ops_actions_$(date +%Y%m%d).log}"

# Log action to file and display command on screen
log_action() {
    local action_type="$1"
    local command="$2"
    local quiet=0
    local context=""
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet) quiet=1 ;;
            --context) shift; context="$1" ;;
        esac
        shift
    done
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ $quiet -eq 0 ]]; then
        echo ""
        echo -e "${YELLOW}Executing:${NC}"
        echo -e "${GRAY}$command${NC}"
        echo ""
    fi
    
    {
        echo "========================================"
        echo "Timestamp: $timestamp"
        echo "Action: $action_type"
        [[ -n "$context" ]] && echo "Context: $context"
        echo "Command: $command"
        echo "========================================"
        echo ""
    } >> "$ACTION_LOG_FILE" 2>/dev/null
}

log_action_result() {
    local result="$1"
    local details="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    {
        echo "Result: $result"
        [[ -n "$details" ]] && echo "Details: $details"
        echo "Completed: $timestamp"
        echo ""
    } >> "$ACTION_LOG_FILE" 2>/dev/null
}

is_valid_ocid() {
    local val="$1"
    [[ -n "$val" && "$val" != "N/A" && "$val" != "null" ]]
}

# Wrapper for OCI CLI calls with error classification and retry
_oci_call() {
    local label="$1"
    shift

    local _oc_errfile="${TEMP_DIR}/oci_last_error_$$.txt"
    local _oc_output
    local _oc_rc
    _oc_output=$("$@" 2>"$_oc_errfile")
    _oc_rc=$?

    if [[ $_oc_rc -ne 0 ]]; then
        local _oc_err=""
        [[ -f "$_oc_errfile" ]] && _oc_err=$(cat "$_oc_errfile" 2>/dev/null)

        case "$_oc_err" in
            *"NotAuthenticated"*|*"NotAuthorized"*|*"SignatureNotFound"*)
                log_error "$label: Authentication failed — check OCI CLI config or token expiry"
                ;;
            *"TooManyRequests"*)
                log_warn "$label: Rate limited — retrying in 5s..."
                sleep 5
                _oc_output=$("$@" 2>/dev/null)
                _oc_rc=$?
                [[ $_oc_rc -ne 0 ]] && log_error "$label: Rate limit retry failed"
                ;;
            *"ServiceUnavailable"*|*"InternalServerError"*)
                log_warn "$label: OCI service error (transient) — retrying in 3s..."
                sleep 3
                _oc_output=$("$@" 2>/dev/null)
                _oc_rc=$?
                [[ $_oc_rc -ne 0 ]] && log_error "$label: Service retry failed"
                ;;
            *"NotFound"*)
                [[ "$DEBUG_MODE" == "true" ]] && log_warn "$label: Resource not found"
                ;;
            *"InvalidParameter"*|*"MissingParameter"*)
                log_error "$label: Invalid/missing parameter in OCI call"
                [[ "$DEBUG_MODE" == "true" ]] && log_error "  Detail: $_oc_err"
                ;;
            *)
                [[ "$DEBUG_MODE" == "true" ]] && log_warn "$label: OCI call failed (rc=$_oc_rc): ${_oc_err:0:200}"
                ;;
        esac
    fi

    rm -f "$_oc_errfile" 2>/dev/null
    echo "$_oc_output"
    return $_oc_rc
}

# Safe command execution
_safe_exec() {
    local cmd="$1"
    case "$cmd" in
        oci\ *|kubectl\ *|bash\ *|curl\ *|jq\ *) ;;
        *) log_error "_safe_exec blocked unknown command prefix: ${cmd%% *}"; return 1 ;;
    esac
    eval "$cmd" 2>&1
}

# Cache helpers
is_cache_fresh() {
    local cache_file="$1"
    local custom_ttl="${2:-}"
    [[ ! -f "$cache_file" ]] && return 1
    local file_mtime
    file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null) || return 1
    local current_time
    current_time=$(date +%s)
    local ttl="${custom_ttl:-${CACHE_TTL_MAP[$cache_file]:-$CACHE_MAX_AGE}}"
    local cache_age=$((current_time - file_mtime))
    [[ $cache_age -lt $ttl ]]
}

_cache_write() {
    local cache_file="$1"
    local tmp_file="${cache_file}.tmp.$$"
    if cat > "$tmp_file" && [[ -s "$tmp_file" ]]; then
        mv -f "$tmp_file" "$cache_file"
    else
        rm -f "$tmp_file" 2>/dev/null
        return 1
    fi
}

create_temp_file() {
    [[ ! -d "$TEMP_DIR" ]] && mkdir -p "$TEMP_DIR"
    mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX" || { log_error "Failed to create temp file"; return 1; }
}

check_dependencies() {
    local missing=()
    command -v oci &>/dev/null || missing+=("oci")
    command -v jq &>/dev/null || missing+=("jq")
    command -v curl &>/dev/null || missing+=("curl")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    fi
    return 0
}

# Truncate / short OCID helpers
truncate_string() {
    local str="$1" max_len="$2"
    if [[ ${#str} -gt $max_len ]]; then
        echo "${str:0:$((max_len-3))}..."
    else
        echo "$str"
    fi
}

_short_ocid() {
    local ocid="$1"
    [[ ${#ocid} -gt 40 ]] && echo "${ocid:0:20}...${ocid: -10}" || echo "$ocid"
}

print_separator() {
    local width="${1:-$UI_WIDTH}"
    printf '%*s\n' "$width" '' | tr ' ' '─'
}

#===============================================================================
# SPINNERS & DISCOVERY BAR
#===============================================================================

readonly _SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

_show_spinner() {
    local msg="$1"
    (
        trap 'return 0' TERM INT
        local i=0
        while true; do
            printf "${CLEAR_LINE}  ${CYAN}%s${NC} %s " "${_SPINNER_CHARS:$((i % ${#_SPINNER_CHARS})):1}" "$msg"
            ((i++))
            sleep 0.15
        done
    ) &
}

_kill_spinner() {
    local pid="$1"
    local msg="${2:-}"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    printf "${CLEAR_LINE}"
    [[ -n "$msg" ]] && echo -e "  ${GREEN}✓${NC} $msg"
}

# Step-based discovery bar
_STEP_COMPLETED_TEXT=""
_STEP_ANIM_PID=""

_step_init() {
    [[ "${_STEP_OUTER:-0}" == "1" ]] && return
    _STEP_COMPLETED_TEXT=""
    _STEP_ANIM_PID=""
    echo -e "  ${BOLD}${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}${WHITE}Discovering:${NC}"
}

_step_active() {
    local label="$1"
    if [[ -n "$_STEP_ANIM_PID" ]]; then
        kill "$_STEP_ANIM_PID" 2>/dev/null
        wait "$_STEP_ANIM_PID" 2>/dev/null
        _STEP_ANIM_PID=""
    fi
    local completed="$_STEP_COMPLETED_TEXT"
    (
        trap 'return 0' TERM INT
        local i=0
        while true; do
            printf "${CLEAR_LINE}  %b${CYAN}%s${NC} %s... " \
                "$completed" "${_SPINNER_CHARS:$((i % ${#_SPINNER_CHARS})):1}" "$label"
            ((i++))
            sleep 0.15
        done
    ) &
    _STEP_ANIM_PID=$!
}

_step_complete() {
    local label="$1"
    if [[ -n "$_STEP_ANIM_PID" ]]; then
        kill "$_STEP_ANIM_PID" 2>/dev/null
        wait "$_STEP_ANIM_PID" 2>/dev/null
        _STEP_ANIM_PID=""
    fi
    _STEP_COMPLETED_TEXT+="${GREEN}✓${NC} ${label}  "
    printf "${CLEAR_LINE}  %b" "$_STEP_COMPLETED_TEXT"
}

_step_finish() {
    [[ "${_STEP_OUTER:-0}" == "1" ]] && return
    if [[ -n "$_STEP_ANIM_PID" ]]; then
        kill "$_STEP_ANIM_PID" 2>/dev/null
        wait "$_STEP_ANIM_PID" 2>/dev/null
        _STEP_ANIM_PID=""
    fi
    printf "${CLEAR_LINE}  %b\n" "$_STEP_COMPLETED_TEXT"
    _STEP_COMPLETED_TEXT=""
    echo -e "  ${BOLD}${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

_step_phase_end() {
    if [[ -n "$_STEP_ANIM_PID" ]]; then
        kill "$_STEP_ANIM_PID" 2>/dev/null
        wait "$_STEP_ANIM_PID" 2>/dev/null
        _STEP_ANIM_PID=""
    fi
    printf "${CLEAR_LINE}  %b\n" "$_STEP_COMPLETED_TEXT"
    _STEP_COMPLETED_TEXT=""
}

#===============================================================================
# UI HELPERS
#===============================================================================

_ui_banner() {
    local title="$1"
    local color="${2:-$BLUE}"
    local width=$UI_WIDTH
    local pad_len=$(( (width - ${#title} - 2) / 2 ))
    [[ $pad_len -lt 3 ]] && pad_len=3
    local pad
    pad=$(printf '═%.0s' $(seq 1 "$pad_len"))
    echo -e "${BOLD}${color}${pad} ${title} ${pad}${NC}"
}

_ui_detail_banner() {
    local prefix="$1"
    local value="${2:-}"
    local color="${3:-$CYAN}"
    echo -e "  ${BOLD}${color}═══ ${prefix}${value:+: ${WHITE}${value}${color}} ═══${NC}"
}

_ui_breadcrumb() {
    local path="Main"
    for segment in "$@"; do
        path+=" ${GRAY}>${NC} ${WHITE}${segment}"
    done
    echo -e "  ${GRAY}${path}${NC}"
}

_ui_section() {
    local title="$1"
    echo -e "  ${BOLD}${WHITE}─── ${title} ───${NC}"
}

_ui_subheader() {
    local title="$1"
    local indent="${2:-2}"
    local color="${3:-${BOLD}${WHITE}}"
    local pad
    pad=$(printf '%*s' "$indent" '')
    echo -e "${pad}${color}◆ ${title}${NC}"
}

_ui_summary() {
    _ui_subheader "${1:-Summary}" 0
}

_ui_actions() {
    local title="${1:-Actions}"
    local line_len=60
    local label="─── ${title} "
    local remaining=$((line_len - ${#label}))
    [[ $remaining -lt 3 ]] && remaining=3
    local trail
    trail=$(printf '─%.0s' $(seq 1 "$remaining"))
    echo -e "  ${BOLD}${YELLOW}${label}${trail}${NC}"
}

_ui_action_group() {
    echo -e "  ${CYAN}»${NC} ${BOLD}${WHITE}${1}${NC}"
}

_ui_prompt() {
    local context="$1"
    local options="$2"
    echo -n -e "${BOLD}${CYAN}[${context}] Selection (${options}): ${NC}"
}

_ui_pause() {
    local mode="${1:-continue}"
    echo -e "Press Enter to ${mode}..."
    read -r
}

_ui_confirm() {
    local confirm_word="$1"
    local action_desc="${2:-confirm}"
    local color="${3:-$RED}"
    echo -n -e "${color}Type '${confirm_word}' to ${action_desc}: ${NC}"
    local response
    read -r response
    [[ "$response" == "$confirm_word" ]]
}

_ui_table_header() {
    local fmt="$1"
    shift
    printf "${BOLD}${fmt}${NC}\n" "$@"
    local width
    width=$(printf "$fmt" "$@" | sed "s/$(printf '\033')[^m]*m//g" | wc -c)
    local stripped="${fmt#"${fmt%%[! ]*}"}"
    local indent_len=$(( ${#fmt} - ${#stripped} ))
    if [[ $indent_len -gt 0 ]]; then
        printf '%*s' "$indent_len" ''
        print_separator $((width - indent_len))
    else
        print_separator "$width"
    fi
}

_ui_env_info() {
    echo -e "  ${BOLD}${WHITE}Focus:${NC} ${GRAY}(${GREEN}variables.sh configured${NC} ${GRAY}│${NC} ${YELLOW}manually selected${NC} ${GRAY}│${NC} ${CYAN}derived${NC}${GRAY})${NC}"
    
    # Tenancy
    local _ten_label="${TENANCY_ID:-not set}"
    if [[ -n "${_TOOL_TENANCY_NAME:-}" ]]; then
        _ten_label="${_TOOL_TENANCY_NAME} ${GRAY}[${_ten_label}]${NC}"
    fi
    echo -e "    ${CYAN}Tenancy:${NC}      ${GREEN}${_ten_label}${NC}"
    
    # Region
    local _r_color="$GREEN"
    [[ "${FOCUS_REGION_SOURCE:-}" == "selected" ]] && _r_color="$YELLOW"
    echo -e "    ${CYAN}Region:${NC}       ${_r_color}${FOCUS_REGION:-not set}${NC}"
    
    # Compartment
    local _c_color="$GREEN"
    [[ "${FOCUS_COMPARTMENT_SOURCE:-}" == "selected" ]] && _c_color="$YELLOW"
    local _comp_display="${FOCUS_COMPARTMENT_ID:-not set}"
    [[ ${#_comp_display} -gt 60 ]] && _comp_display="$(_short_ocid "$_comp_display")"
    echo -e "    ${CYAN}Compartment:${NC}  ${_c_color}${_comp_display}${NC}"
    
    # OKE Cluster (if set)
    if [[ -n "${FOCUS_OKE_CLUSTER_ID:-}" ]]; then
        local _o_color="$GREEN"
        [[ "${FOCUS_OKE_SOURCE:-}" == "selected" ]] && _o_color="$YELLOW"
        [[ "${FOCUS_OKE_SOURCE:-}" == "derived" ]] && _o_color="$CYAN"
        echo -e "    ${CYAN}OKE Cluster:${NC}  ${_o_color}${FOCUS_OKE_CLUSTER_NAME:-$FOCUS_OKE_CLUSTER_ID}${NC}"
    fi
    
    # Tools
    local tl="${CYAN}OCI CLI:${NC} ${GREEN}${_TOOL_OCI_VER:-n/a}${NC}"
    local _auth_color="$GREEN"
    [[ "${_TOOL_OCI_AUTH_SOURCE:-config}" == "derived" ]] && _auth_color="$CYAN"
    tl+=" ${GRAY}(${NC}${_auth_color}${_TOOL_OCI_AUTH:-api_key}${NC}${GRAY})${NC}"
    if command -v kubectl &>/dev/null; then
        tl+="  ${GRAY}│${NC}  ${CYAN}kubectl:${NC} ${GREEN}${_TOOL_KUBECTL_VER:-installed}${NC}"
    fi
    echo -e "    ${CYAN}Tools:${NC}        ${tl}"
    
    # Extra key/value pairs
    while [[ $# -ge 2 ]]; do
        echo -e "    ${CYAN}${1}:${NC}  ${WHITE}${2}${NC}"
        shift 2
    done
}

# Consolidated menu header
_ui_menu_header() {
    local title="$1"
    shift
    local color="$BLUE"
    local show_env=false
    local -a breadcrumb_segments=()
    local -a cmd_lines=()
    local -a cache_specs=()
    local -a env_extras=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --color) shift; color="$1" ;;
            --env) show_env=true ;;
            --breadcrumb) shift; while [[ $# -gt 0 && "$1" != --* ]]; do breadcrumb_segments+=("$1"); shift; done; continue ;;
            --cmd) shift; cmd_lines+=("$1") ;;
            --cache) shift; while [[ $# -gt 0 && "$1" != --* ]]; do cache_specs+=("$1"); shift; done; continue ;;
            --extra) shift; env_extras+=("$1"); shift; env_extras+=("$1") ;;
            *) ;;
        esac
        shift
    done
    
    echo ""
    _ui_banner "$title" "$color"
    
    if [[ ${#breadcrumb_segments[@]} -gt 0 ]]; then
        _ui_breadcrumb "${breadcrumb_segments[@]}"
    fi
    
    if $show_env; then
        _ui_env_info "${env_extras[@]}"
    fi
    
    if [[ ${#cmd_lines[@]} -gt 0 ]]; then
        echo -e "  ${DIM}${GRAY}Commands: ${cmd_lines[*]}${NC}"
    fi
}

#===============================================================================
# REUSABLE HELPERS — shared patterns across menus
#===============================================================================

# _ui_kv — Display a key-value pair with consistent formatting
# Usage: _ui_kv "Label" "value" [color] [indent]
#   _ui_kv "Region" "us-phoenix-1"
#   _ui_kv "OCID" "$ocid" "$GRAY"
_ui_kv() {
    local label="$1" value="$2"
    local color="${3:-$WHITE}" indent="${4:-2}"
    local pad
    pad=$(printf '%*s' "$indent" '')
    echo -e "${pad}${CYAN}${label}:${NC}  ${color}${value}${NC}"
}

# _jq_count — Safe .data | length with fallback to 0
# Usage: local count=$(_jq_count "$json")
_jq_count() {
    local json="$1" path="${2:-.data}"
    local count
    count=$(jq "${path} | length" <<< "$json" 2>/dev/null)
    [[ -z "$count" || "$count" == "null" ]] && count=0
    echo "$count"
}

# _oci_discover — Step discovery bar + OCI call + count
# Usage: local json; json=$(_oci_discover "label" oci_args...)
#   Wraps: _step_init → _step_active → _oci_call → _jq_count → _step_complete → _step_finish
#   Writes to stdout: the raw JSON; Writes to stderr: the step UI
# Options:
#   --no-init / --no-finish   skip step bookends (for multi-phase discovery)
#   --cached "text"           append to step label (e.g., " cached")
_oci_discover() {
    local label="$1"
    shift
    local do_init=true do_finish=true cached_text=""

    # Parse options before the oci command
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-init)    do_init=false;   shift ;;
            --no-finish)  do_finish=false; shift ;;
            --cached)     shift; cached_text="$1"; shift ;;
            *)            break ;;
        esac
    done

    $do_init && _step_init >&2
    _step_active "$label" >&2

    local json
    json=$(_oci_call "$label" "$@")
    local rc=$?

    local count
    count=$(_jq_count "$json")
    _step_complete "${label}(${count}${cached_text})" >&2
    $do_finish && _step_finish >&2

    echo "$json"
    return $rc
}

# _ui_show_command — Display command to be executed with consistent formatting
# Usage: _ui_show_command "$cmd"
_ui_show_command() {
    local cmd="$1"
    echo ""
    _ui_subheader "Command to Execute" 0
    echo -e "  ${GRAY}${cmd}${NC}"
    echo ""
}

# _exec_action — Confirm → Log → Execute → Check result → Report
# Consolidates the repeated CUD (Create/Update/Delete) execution pattern.
# Usage: _exec_action [options] -- "$cmd"
#   --confirm-word WORD     Confirmation word (default: "y")
#   --confirm-desc DESC     Description for confirmation prompt (default: "proceed")
#   --confirm-color COLOR   Color for confirmation prompt (default: $YELLOW)
#   --action-type TYPE      Action type for log_action (e.g., "INSTANCE_LAUNCH")
#   --context CTX           Context string for log_action
#   --success-msg MSG       Message on success (default: "Operation completed")
#   --success-label LBL     Label for OCID display (default: "Resource OCID")
#   --on-success FUNC       Callback function on success, receives new_id as $1
#   --skip-confirm          Skip the confirmation step (already confirmed)
# Returns: 0 on success, 1 on failure, 2 on cancel
_EXEC_ACTION_RESULT_ID=""
_exec_action() {
    _EXEC_ACTION_RESULT_ID=""
    local confirm_word="y" confirm_desc="proceed" confirm_color="$YELLOW"
    local action_type="ACTION" context="" success_msg="Operation completed"
    local success_label="Resource OCID" cmd="" on_success="" skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --confirm-word)  shift; confirm_word="$1" ;;
            --confirm-desc)  shift; confirm_desc="$1" ;;
            --confirm-color) shift; confirm_color="$1" ;;
            --action-type)   shift; action_type="$1" ;;
            --context)       shift; context="$1" ;;
            --success-msg)   shift; success_msg="$1" ;;
            --success-label) shift; success_label="$1" ;;
            --on-success)    shift; on_success="$1" ;;
            --skip-confirm)  skip_confirm=true ;;
            --)              shift; cmd="$*"; break ;;
            *)               cmd="$*"; break ;;
        esac
        shift
    done

    [[ -z "$cmd" ]] && { log_error "_exec_action: no command provided"; return 1; }

    # Confirm
    if ! $skip_confirm; then
        if ! _ui_confirm "$confirm_word" "$confirm_desc" "$confirm_color"; then
            echo -e "${YELLOW}Cancelled${NC}"
            return 2
        fi
    fi

    # Log & execute
    log_action "$action_type" "$cmd" --context "$context"
    local result
    result=$(_safe_exec "$cmd")

    # Check result
    if jq -e '.data.id' <<< "$result" > /dev/null 2>&1; then
        local new_id
        new_id=$(jq -r '.data.id' <<< "$result")
        _EXEC_ACTION_RESULT_ID="$new_id"
        echo -e "${GREEN}✓ ${success_msg}${NC}"
        echo -e "  ${CYAN}${success_label}:${NC} ${YELLOW}${new_id}${NC}"
        log_action_result "SUCCESS" "${success_msg}: $new_id"
        # Callback
        [[ -n "$on_success" ]] && "$on_success" "$new_id"
        return 0
    else
        echo -e "${RED}✗ Operation failed${NC}"
        echo -e "  ${GRAY}${result:0:500}${NC}"
        log_action_result "FAILED" "${action_type} failed"
        return 1
    fi
}

# _require_oke_cluster — Ensure an OKE cluster is in focus (auto-detect if needed)
# Usage: _require_oke_cluster "$compartment_id" "$region" || return
#   - If FOCUS_OKE_CLUSTER_ID is set, returns 0 immediately
#   - If 1 cluster found, auto-selects it
#   - If multiple, prompts user to pick
#   - If 0, prints error and returns 1
_require_oke_cluster() {
    local compartment_id="$1" region="$2"
    [[ -n "${FOCUS_OKE_CLUSTER_ID:-}" ]] && return 0

    echo ""
    echo -e "${YELLOW}No OKE cluster in focus. Detecting...${NC}"

    local clusters_json
    clusters_json=$(_oci_discover "OKE clusters" \
        oci ce cluster list \
        --compartment-id "$compartment_id" --region "$region" \
        --lifecycle-state ACTIVE --all --output json)

    local cluster_count
    cluster_count=$(_jq_count "$clusters_json")

    if [[ "$cluster_count" -eq 0 ]]; then
        echo -e "${RED}No active OKE clusters found. Cannot proceed.${NC}"
        _ui_pause
        return 1
    elif [[ "$cluster_count" -eq 1 ]]; then
        local auto_id auto_name
        auto_id=$(jq -r '.data[0].id' <<< "$clusters_json")
        auto_name=$(jq -r '.data[0].name' <<< "$clusters_json")
        _focus_set_oke_cluster "$auto_id" "$auto_name"
        echo -e "${GREEN}✓ Auto-selected cluster: ${WHITE}${auto_name}${NC}"
    else
        _select_from_json "$clusters_json" \
            '.data[] | "\(.id)|\(.name)"' \
            "Cluster" "Multiple clusters found. Select one:" || return 1
        local sel_id sel_name
        IFS='|' read -r sel_id sel_name <<< "$_SELECT_RESULT"
        _focus_set_oke_cluster "$sel_id" "$sel_name"
    fi
    return 0
}

# _select_from_json — Present numbered items from JSON, get user selection
# Usage: _select_from_json "$json" "jq_expression" "prompt_label" ["header_msg"]
#   jq_expression must produce "id|display_name" pipe-delimited lines
#   Sets global _SELECT_RESULT="selected_id|selected_name" on success
#   Returns: 0 on selection, 1 on cancel/invalid
_SELECT_RESULT=""
_select_from_json() {
    local json="$1" jq_expr="$2" prompt_label="$3" header_msg="${4:-}"
    _SELECT_RESULT=""

    echo ""
    [[ -n "$header_msg" ]] && echo -e "${CYAN}${header_msg}${NC}"
    echo ""

    local idx=0
    declare -A _sfj_map=()
    while IFS='|' read -r _sfj_id _sfj_name; do
        [[ -z "$_sfj_id" ]] && continue
        ((idx++))
        _sfj_map[$idx]="${_sfj_id}|${_sfj_name}"
        echo -e "  ${YELLOW}${idx}${NC}) ${WHITE}${_sfj_name}${NC}"
    done < <(jq -r "$jq_expr" <<< "$json" 2>/dev/null)

    if [[ $idx -eq 0 ]]; then
        echo -e "  ${GRAY}No items found${NC}"
        return 1
    fi

    echo ""
    _ui_prompt "$prompt_label" "#, b"
    read -r _sfj_sel

    [[ "$_sfj_sel" == "b" || "$_sfj_sel" == "B" || -z "$_sfj_sel" ]] && return 1

    if [[ -n "${_sfj_map[$_sfj_sel]:-}" ]]; then
        _SELECT_RESULT="${_sfj_map[$_sfj_sel]}"
        return 0
    else
        echo -e "${RED}Invalid selection${NC}"
        return 1
    fi
}

# _select_region — List subscribed regions grouped by geography in columns
# Usage: _select_region || return
#   Sets: _SELECTED_REGION (the chosen region name)
#   Default: current FOCUS_REGION (press Enter to keep)
#   Returns: 0 on selection, 1 on cancel
_SELECTED_REGION=""
_select_region() {
    _SELECTED_REGION="${FOCUS_REGION:-$REGION}"
    local tenancy_id="${TENANCY_ID:-}"
    
    echo ""
    echo -e "  ${CYAN}Current region:${NC} ${WHITE}${_SELECTED_REGION}${NC}"
    echo ""
    
    # Fetch subscribed regions
    local regions_json
    regions_json=$(_oci_discover "regions" \
        oci iam region-subscription list --tenancy-id "$tenancy_id" \
        --output json)
    
    local region_count
    region_count=$(_jq_count "$regions_json")
    
    if [[ "$region_count" -eq 0 ]]; then
        echo -e "${YELLOW}Could not fetch regions — using current: ${WHITE}${_SELECTED_REGION}${NC}"
        return 0
    fi
    
    # ── Classify regions into geographic buckets ──
    local -a na_regions=() emea_regions=() apac_regions=()
    local -a na_status=() emea_status=() apac_status=()
    
    while IFS='|' read -r rname rstatus; do
        [[ -z "$rname" ]] && continue
        case "$rname" in
            us-*|ca-*|mx-*)     na_regions+=("$rname");   na_status+=("$rstatus") ;;
            eu-*|uk-*|me-*|af-*|il-*|sa-*) emea_regions+=("$rname"); emea_status+=("$rstatus") ;;
            ap-*)               apac_regions+=("$rname"); apac_status+=("$rstatus") ;;
            *)                  na_regions+=("$rname");   na_status+=("$rstatus") ;; # fallback
        esac
    done < <(jq -r '.data | sort_by(.["region-name"])[] | "\(.["region-name"])|\(.status)"' <<< "$regions_json" 2>/dev/null)
    
    local na_count=${#na_regions[@]} emea_count=${#emea_regions[@]} apac_count=${#apac_regions[@]}
    
    # ── Assign sequential numbers ──
    # NA: 1..na_count, EMEA: na_count+1.., APAC: na_count+emea_count+1..
    declare -A _reg_map=()
    local gidx=0 default_idx=""
    
    local -a na_nums=() emea_nums=() apac_nums=()
    for ((i=0; i<na_count; i++)); do
        ((gidx++))
        _reg_map[$gidx]="${na_regions[$i]}"
        na_nums+=("$gidx")
        [[ "${na_regions[$i]}" == "$_SELECTED_REGION" ]] && default_idx="$gidx"
    done
    for ((i=0; i<emea_count; i++)); do
        ((gidx++))
        _reg_map[$gidx]="${emea_regions[$i]}"
        emea_nums+=("$gidx")
        [[ "${emea_regions[$i]}" == "$_SELECTED_REGION" ]] && default_idx="$gidx"
    done
    for ((i=0; i<apac_count; i++)); do
        ((gidx++))
        _reg_map[$gidx]="${apac_regions[$i]}"
        apac_nums+=("$gidx")
        [[ "${apac_regions[$i]}" == "$_SELECTED_REGION" ]] && default_idx="$gidx"
    done
    
    # ── Column rendering ──
    local c1=38 c2=38 c3=34
    local bar1 bar2 bar3
    bar1=$(printf '▒%.0s' $(seq 1 36))
    bar2=$(printf '▒%.0s' $(seq 1 36))
    bar3=$(printf '▒%.0s' $(seq 1 32))
    
    # Column headers
    printf "  ${BOLD}${WHITE}%-${c1}s%-${c2}s%s${NC}\n" \
        "North America (${na_count})" "EMEA (${emea_count})" "APAC (${apac_count})"
    printf "  ${GRAY}%-${c1}s%-${c2}s%s${NC}\n" "$bar1" "$bar2" "$bar3"
    
    # Find max rows
    local max_rows=$na_count
    [[ $emea_count -gt $max_rows ]] && max_rows=$emea_count
    [[ $apac_count -gt $max_rows ]] && max_rows=$apac_count
    
    # Render rows
    for ((row=0; row<max_rows; row++)); do
        printf "  "
        # NA column
        if [[ $row -lt $na_count ]]; then
            local _n=${na_nums[$row]} _r="${na_regions[$row]}"
            local _marker="" _rcolor="${WHITE}"
            [[ "$_r" == "$_SELECTED_REGION" ]] && _marker=" ◄" && _rcolor="${CYAN}"
            printf "${YELLOW}%2s${NC}) ${_rcolor}%-26s${NC}%-3s" "$_n" "$_r" "$_marker"
            local _vis; printf -v _vis "%2s) %-26s%-3s" "$_n" "$_r" "$_marker"
            local _pad=$(( c1 - ${#_vis} )); [[ $_pad -gt 0 ]] && printf "%*s" "$_pad" ""
        else
            printf "%*s" "$c1" ""
        fi
        # EMEA column
        if [[ $row -lt $emea_count ]]; then
            local _n=${emea_nums[$row]} _r="${emea_regions[$row]}"
            local _marker="" _rcolor="${WHITE}"
            [[ "$_r" == "$_SELECTED_REGION" ]] && _marker=" ◄" && _rcolor="${CYAN}"
            printf "${YELLOW}%2s${NC}) ${_rcolor}%-26s${NC}%-3s" "$_n" "$_r" "$_marker"
            local _vis; printf -v _vis "%2s) %-26s%-3s" "$_n" "$_r" "$_marker"
            local _pad=$(( c2 - ${#_vis} )); [[ $_pad -gt 0 ]] && printf "%*s" "$_pad" ""
        else
            printf "%*s" "$c2" ""
        fi
        # APAC column
        if [[ $row -lt $apac_count ]]; then
            local _n=${apac_nums[$row]} _r="${apac_regions[$row]}"
            local _marker="" _rcolor="${WHITE}"
            [[ "$_r" == "$_SELECTED_REGION" ]] && _marker=" ◄" && _rcolor="${CYAN}"
            printf "${YELLOW}%2s${NC}) ${_rcolor}%-26s${NC}%-3s" "$_n" "$_r" "$_marker"
        fi
        echo
    done
    
    echo ""
    local prompt_hint="1-${gidx}"
    [[ -n "$default_idx" ]] && prompt_hint="Enter=${default_idx}, 1-${gidx}"
    _ui_prompt "Region" "$prompt_hint, b"
    read -r reg_choice
    
    # Default = keep current
    [[ -z "$reg_choice" && -n "$default_idx" ]] && reg_choice="$default_idx"
    [[ "$reg_choice" == "b" || "$reg_choice" == "B" ]] && return 1
    
    if [[ -n "$reg_choice" && -n "${_reg_map[$reg_choice]+x}" ]]; then
        _SELECTED_REGION="${_reg_map[$reg_choice]}"
        echo -e "${GREEN}✓ Region: ${WHITE}${_SELECTED_REGION}${NC}"
        return 0
    else
        echo -e "${RED}Invalid selection — keeping ${_SELECTED_REGION}${NC}"
        return 0
    fi
}

# _select_ad — List availability domains for a region, let user pick
# Usage: _select_ad "$compartment_id" "$region" [--default "$ad_name"]
#   --default AD_NAME   Pre-select this AD (e.g., from OKE node pool placement)
#   Sets: _SELECTED_AD (the full AD name)
#   Returns: 0 on selection, 1 on cancel
_SELECTED_AD=""
_select_ad() {
    local compartment_id="$1" region="$2"
    shift 2
    local default_ad=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --default) shift; default_ad="$1" ;;
        esac
        shift
    done
    _SELECTED_AD=""
    
    echo ""
    local ad_json
    ad_json=$(_oci_discover "availability domains" \
        oci iam availability-domain list \
        --compartment-id "$compartment_id" --region "$region" \
        --output json)
    
    local ad_count
    ad_count=$(_jq_count "$ad_json")
    
    if [[ "$ad_count" -eq 0 ]]; then
        echo -e "${YELLOW}No ADs found — enter manually${NC}"
        echo -n -e "  ${CYAN}Availability Domain: ${NC}"
        read -r _SELECTED_AD
        [[ -z "$_SELECTED_AD" ]] && return 1
        return 0
    fi
    
    echo ""
    local idx=0 default_idx=""
    declare -A _ad_map=()
    
    while IFS='|' read -r ad_name ad_id; do
        [[ -z "$ad_name" ]] && continue
        ((idx++))
        _ad_map[$idx]="$ad_name"
        local ad_short="${ad_name##*:}"
        
        local marker=""
        if [[ -n "$default_ad" && "$ad_name" == "$default_ad" ]]; then
            marker=" ${CYAN}◄ OKE cluster${NC}"
            default_idx="$idx"
        fi
        
        printf "  ${YELLOW}%-3s${NC} ${WHITE}%-20s${NC}  ${GRAY}%s${NC}%b\n" \
            "$idx" "$ad_short" "$ad_name" "$marker"
    done < <(jq -r '.data[] | "\(.name)|\(.id)"' <<< "$ad_json" 2>/dev/null)
    
    # Single AD or no OKE default — default to first entry
    [[ -z "$default_idx" && "$ad_count" -ge 1 ]] && default_idx="1"
    
    echo ""
    local prompt_hint="#"
    [[ -n "$default_idx" ]] && prompt_hint="#, Enter=${default_idx}"
    _ui_prompt "Availability Domain" "$prompt_hint, b"
    read -r ad_choice
    
    # Default to OKE cluster AD
    [[ -z "$ad_choice" && -n "$default_idx" ]] && ad_choice="$default_idx"
    [[ "$ad_choice" == "b" || "$ad_choice" == "B" ]] && return 1
    
    if [[ -n "${_ad_map[$ad_choice]:-}" ]]; then
        _SELECTED_AD="${_ad_map[$ad_choice]}"
        local ad_short="${_SELECTED_AD##*:}"
        echo -e "${GREEN}✓ AD: ${WHITE}${ad_short}${NC}"
        return 0
    else
        echo -e "${RED}Invalid selection${NC}"
        return 1
    fi
}

# _select_gpu_shape — Reusable OCI compute shape selector (multi-column layout)
# Complete current-gen shape catalog from OCI docs (docs.oracle.com/iaas/Content/Compute/References/computeshapes.htm)
# Items flow DOWN within each column, columns displayed side-by-side
# Usage: _select_gpu_shape || return
#   Sets: _SELECTED_SHAPE (the shape name)
#   Returns: 0 on selection, 1 on cancel
_SELECTED_SHAPE=""
_select_gpu_shape() {
    _SELECTED_SHAPE=""
    
    # Helper: emit a padded shape cell
    # Usage: _sc num shape spec col_total_width [shape_field_width]
    _sc() {
        local n="$1" s="$2" sp="$3" w="$4" sw="${5:-20}"
        local cell
        printf -v cell "%2s) %-${sw}s %s" "$n" "$s" "$sp"
        local pad=$(( w - ${#cell} ))
        [[ $pad -lt 0 ]] && pad=0
        printf "${YELLOW}%2s${NC}) %-${sw}s ${GRAY}%s${NC}%*s" "$n" "$s" "$sp" "$pad" ""
    }
    _se() { printf "%*s" "$1" ""; }
    
    # Column widths (visible chars including inter-column gap)
    local c1=44 c2=42 c3=40 c4=30
    local bar1 bar2 bar3 bar4
    bar1=$(printf '▒%.0s' $(seq 1 41))
    bar2=$(printf '▒%.0s' $(seq 1 39))
    bar3=$(printf '▒%.0s' $(seq 1 37))
    bar4=$(printf '▒%.0s' $(seq 1 28))
    
    echo ""
    # ── Column headers ──
    printf "  ${BOLD}${WHITE}%-${c1}s%-${c2}s%-${c3}s%s${NC}\n" \
        "BM GPU (13)" "VM GPU (12)" "BM non-GPU (10)" "VM non-GPU (10)"
    printf "  ${GRAY}%-${c1}s%-${c2}s%-${c3}s%s${NC}\n" "$bar1" "$bar2" "$bar3" "$bar4"
    
    # ── Data rows (13 rows max — BM GPU is tallest column) — all columns sorted alphabetically ──
    #                Col1: BM GPU                        Col2: VM GPU                              Col3: BM non-GPU                           Col4: VM non-GPU
    printf "  "; _sc  1 "BM.GPU.A10.4"      "[4x A10 24GB]"     $c1 19; _sc 14 "VM.GPU.A10.1"          "[1x A10 24GB]"   $c2 22; _sc 26 "BM.DenseIO.E4.128"    "[NVMe 54T]"   $c3 22; _sc 36 "VM.DenseIO.E4.Flex"    ""  0 22; echo
    printf "  "; _sc  2 "BM.GPU.A100-v2.8"  "[8x A100 80GB]"    $c1 19; _sc 15 "VM.GPU.A10.2"          "[2x A10 24GB]"   $c2 22; _sc 27 "BM.DenseIO.E5.128"    "[NVMe 82T]"   $c3 22; _sc 37 "VM.DenseIO.E5.Flex"    ""  0 22; echo
    printf "  "; _sc  3 "BM.GPU.B200.8"     "[8x B200 180GB]"   $c1 19; _sc 16 "VM.GPU.A100.1"         "[1x A100 80GB]"  $c2 22; _sc 28 "BM.HPC.E5.144"        "[HPC]"        $c3 22; _sc 38 "VM.Optimized3.Flex"    ""  0 22; echo
    printf "  "; _sc  4 "BM.GPU.GB200.4"    "[4x GB200 192GB]"  $c1 19; _sc 17 "VM.GPU.H100.1"         "[1x H100 80GB]"  $c2 22; _sc 29 "BM.Optimized3.36"     "[HPC]"        $c3 22; _sc 39 "VM.Standard.A1.Flex"   ""  0 22; echo
    printf "  "; _sc  5 "BM.GPU.GB300.4"    "[4x GB300 278GB]"  $c1 19; _sc 18 "VM.GPU.L40S.1"         "[1x L40S 48GB]"  $c2 22; _sc 30 "BM.Standard.A1.160"   "[Arm 160c]"   $c3 22; _sc 40 "VM.Standard.A2.Flex"   ""  0 22; echo
    printf "  "; _sc  6 "BM.GPU.H100.8"     "[8x H100 80GB]"    $c1 19; _sc 19 "VM.GPU.L40S.2"         "[2x L40S 48GB]"  $c2 22; _sc 31 "BM.Standard.A4.48"    "[Arm 48c]"    $c3 22; _sc 41 "VM.Standard.A4.Flex"   ""  0 22; echo
    printf "  "; _sc  7 "BM.GPU.H200.8"     "[8x H200 141GB]"   $c1 19; _sc 20 "VM.GPU.L40S.3"         "[3x L40S 48GB]"  $c2 22; _sc 32 "BM.Standard.E4.128"   "[AMD 128c]"   $c3 22; _sc 42 "VM.Standard.E4.Flex"   ""  0 22; echo
    printf "  "; _sc  8 "BM.GPU.L40S.4"     "[4x L40S 48GB]"    $c1 19; _sc 21 "VM.GPU.L40S.4"         "[4x L40S 48GB]"  $c2 22; _sc 33 "BM.Standard.E5.192"   "[AMD 192c]"   $c3 22; _sc 43 "VM.Standard.E5.Flex"   ""  0 22; echo
    printf "  "; _sc  9 "BM.GPU.MI300X.8"   "[8x MI300X 192GB]" $c1 19; _sc 22 "VM.GPU2.1"             "[1x P100 16GB]"  $c2 22; _sc 34 "BM.Standard.E6.256"   "[AMD 256c]"   $c3 22; _sc 44 "VM.Standard.E6.Flex"   ""  0 22; echo
    printf "  "; _sc 10 "BM.GPU.MI355X.8"   "[8x MI355X 288GB]" $c1 19; _sc 23 "VM.GPU3.1"             "[1x V100 16GB]"  $c2 22; _sc 35 "BM.Standard3.64"      "[Intel 64c]"  $c3 22; _sc 45 "VM.Standard3.Flex"     ""  0 22; echo
    printf "  "; _sc 11 "BM.GPU2.2"         "[2x P100 16GB]"    $c1 19; _sc 24 "VM.GPU3.2"             "[2x V100 16GB]"  $c2 22; echo
    printf "  "; _sc 12 "BM.GPU3.8"         "[8x V100 16GB]"    $c1 19; _sc 25 "VM.GPU3.4"             "[4x V100 16GB]"  $c2 22; echo
    printf "  "; _sc 13 "BM.GPU4.8"         "[8x A100 40GB]"    $c1 19; echo
    echo ""
    printf "  ${YELLOW}  0${NC}) ${WHITE}Custom${NC} ${GRAY}(enter shape name — prev-gen, new shapes, etc.)${NC}"
    echo ""
    
    echo ""
    _ui_prompt "Shape" "0-45, b"
    read -r _shape_choice
    
    case "$_shape_choice" in
        # BM GPU (1-13) — sorted alphabetically
        1)  _SELECTED_SHAPE="BM.GPU.A10.4" ;;
        2)  _SELECTED_SHAPE="BM.GPU.A100-v2.8" ;;
        3)  _SELECTED_SHAPE="BM.GPU.B200.8" ;;
        4)  _SELECTED_SHAPE="BM.GPU.GB200.4" ;;
        5)  _SELECTED_SHAPE="BM.GPU.GB300.4" ;;
        6)  _SELECTED_SHAPE="BM.GPU.H100.8" ;;
        7)  _SELECTED_SHAPE="BM.GPU.H200.8" ;;
        8)  _SELECTED_SHAPE="BM.GPU.L40S.4" ;;
        9)  _SELECTED_SHAPE="BM.GPU.MI300X.8" ;;
        10) _SELECTED_SHAPE="BM.GPU.MI355X.8" ;;
        11) _SELECTED_SHAPE="BM.GPU2.2" ;;
        12) _SELECTED_SHAPE="BM.GPU3.8" ;;
        13) _SELECTED_SHAPE="BM.GPU4.8" ;;
        # VM GPU (14-25) — sorted alphabetically
        14) _SELECTED_SHAPE="VM.GPU.A10.1" ;;
        15) _SELECTED_SHAPE="VM.GPU.A10.2" ;;
        16) _SELECTED_SHAPE="VM.GPU.A100.1" ;;
        17) _SELECTED_SHAPE="VM.GPU.H100.1" ;;
        18) _SELECTED_SHAPE="VM.GPU.L40S.1" ;;
        19) _SELECTED_SHAPE="VM.GPU.L40S.2" ;;
        20) _SELECTED_SHAPE="VM.GPU.L40S.3" ;;
        21) _SELECTED_SHAPE="VM.GPU.L40S.4" ;;
        22) _SELECTED_SHAPE="VM.GPU2.1" ;;
        23) _SELECTED_SHAPE="VM.GPU3.1" ;;
        24) _SELECTED_SHAPE="VM.GPU3.2" ;;
        25) _SELECTED_SHAPE="VM.GPU3.4" ;;
        # BM non-GPU (26-35) — sorted alphabetically
        26) _SELECTED_SHAPE="BM.DenseIO.E4.128" ;;
        27) _SELECTED_SHAPE="BM.DenseIO.E5.128" ;;
        28) _SELECTED_SHAPE="BM.HPC.E5.144" ;;
        29) _SELECTED_SHAPE="BM.Optimized3.36" ;;
        30) _SELECTED_SHAPE="BM.Standard.A1.160" ;;
        31) _SELECTED_SHAPE="BM.Standard.A4.48" ;;
        32) _SELECTED_SHAPE="BM.Standard.E4.128" ;;
        33) _SELECTED_SHAPE="BM.Standard.E5.192" ;;
        34) _SELECTED_SHAPE="BM.Standard.E6.256" ;;
        35) _SELECTED_SHAPE="BM.Standard3.64" ;;
        # VM non-GPU (36-45) — sorted alphabetically
        36) _SELECTED_SHAPE="VM.DenseIO.E4.Flex" ;;
        37) _SELECTED_SHAPE="VM.DenseIO.E5.Flex" ;;
        38) _SELECTED_SHAPE="VM.Optimized3.Flex" ;;
        39) _SELECTED_SHAPE="VM.Standard.A1.Flex" ;;
        40) _SELECTED_SHAPE="VM.Standard.A2.Flex" ;;
        41) _SELECTED_SHAPE="VM.Standard.A4.Flex" ;;
        42) _SELECTED_SHAPE="VM.Standard.E4.Flex" ;;
        43) _SELECTED_SHAPE="VM.Standard.E5.Flex" ;;
        44) _SELECTED_SHAPE="VM.Standard.E6.Flex" ;;
        45) _SELECTED_SHAPE="VM.Standard3.Flex" ;;
        # Custom
        0)
            echo -n -e "${CYAN}Enter shape name: ${NC}"
            read -r _SELECTED_SHAPE
            [[ -z "$_SELECTED_SHAPE" ]] && return 1
            ;;
        b|B) return 1 ;;
        *)  echo -e "${RED}Invalid selection${NC}"; return 1 ;;
    esac
    
    echo -e "${GREEN}✓ Shape: ${WHITE}${_SELECTED_SHAPE}${NC}"
    return 0
}

# _select_image — Reusable OCI image selector with compartment browse
# Auto-lists custom images in compartment, with options for platform images / node pool / manual
# Usage: _select_image "$compartment_id" "$region" [--node-pools "$json"]
#   Sets: _SELECTED_IMAGE (the image OCID)
#   Returns: 0 on selection, 1 on cancel
_SELECTED_IMAGE=""
_select_image() {
    local compartment_id="$1"
    local region="$2"
    local np_json=""
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node-pools) np_json="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    _SELECTED_IMAGE=""
    
    # ── Fetch custom images ──
    echo ""
    _step_init
    _step_active "custom images"
    
    local custom_images_json
    if is_cache_fresh "$CUSTOM_IMAGE_CACHE"; then
        custom_images_json=$(cat "$CUSTOM_IMAGE_CACHE")
    else
        local images_json
        images_json=$(_oci_call "image list" oci compute image list \
            --compartment-id "$compartment_id" \
            --region "$region" \
            --sort-by TIMECREATED --sort-order DESC \
            --all --output json)
        
        if [[ -n "$images_json" ]] && jq -e '.data' <<< "$images_json" > /dev/null 2>&1; then
            custom_images_json=$(jq --arg comp_id "$compartment_id" \
                '{data: [.data[] | select(.["compartment-id"] == $comp_id)]}' <<< "$images_json")
        else
            custom_images_json='{"data":[]}'
        fi
        [[ -n "$custom_images_json" ]] && echo "$custom_images_json" | _cache_write "$CUSTOM_IMAGE_CACHE"
    fi
    
    local image_count=0
    if jq -e '.data' <<< "$custom_images_json" > /dev/null 2>&1; then
        image_count=$(_jq_count "$custom_images_json")
    fi
    [[ -z "$image_count" || "$image_count" == "null" ]] && image_count=0
    _step_complete "custom images(${image_count})"
    _step_finish
    
    # ── Display custom images table ──
    declare -A _IMG_MAP=()
    local idx=0
    
    if [[ "$image_count" -gt 0 ]]; then
        echo ""
        _ui_subheader "Custom Images (${image_count})" 0
        echo ""
        _ui_table_header "  %-3s %-18s %-14s %-12s  %s" "#" "OS" "Status" "Created" "Image Name"
        
        while IFS='|' read -r img_id img_name img_os img_created img_state; do
            [[ -z "$img_id" ]] && continue
            ((idx++))
            _IMG_MAP[$idx]="$img_id"
            
            local created_display="${img_created:0:10}"
            local state_color="${WHITE}"
            case "$img_state" in
                AVAILABLE) state_color="${GREEN}" ;;
                IMPORTING|PROVISIONING|EXPORTING) state_color="${YELLOW}" ;;
                DISABLED|DELETED) state_color="${RED}" ;;
            esac
            
            printf "  ${YELLOW}%-3s${NC} %-18s ${state_color}%-14s${NC} %-12s  %s\n" \
                "$idx" "$img_os" "$img_state" "$created_display" "$img_name"
        done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["operating-system"] // "N/A")|\(.["time-created"] // "N/A")|\(.["lifecycle-state"] // "UNKNOWN")"' <<< "$custom_images_json" 2>/dev/null)
    else
        echo ""
        _ui_subheader "Custom Images (0)" 0
        echo -e "  ${GRAY}No custom images found in this compartment${NC}"
    fi
    
    # ── Actions ──
    echo ""
    local has_np=false
    [[ -n "$np_json" ]] && [[ "$(_jq_count "$np_json" 2>/dev/null)" -gt 0 ]] && has_np=true
    
    echo -e "  ${GREEN}p${NC})  Browse OKE platform images (GPU + standard)"
    $has_np && echo -e "  ${GREEN}n${NC})  Copy from existing node pool"
    echo -e "  ${GREEN}o${NC})  Enter image OCID directly"
    echo -e "  ${MAGENTA}r${NC})  Refresh"
    echo -e "  ${CYAN}b${NC})  Cancel"
    echo ""
    
    local prompt_range=""
    [[ "$idx" -gt 0 ]] && prompt_range="1-${idx}, "
    _ui_prompt "Image" "${prompt_range}p, ${has_np:+n, }o, r, b"
    read -r _img_sel
    
    case "$_img_sel" in
        [0-9]*)
            if [[ -n "${_IMG_MAP[$_img_sel]:-}" ]]; then
                _SELECTED_IMAGE="${_IMG_MAP[$_img_sel]}"
                # Show name for confirmation
                local sel_name
                sel_name=$(jq -r --arg id "$_SELECTED_IMAGE" '.data[] | select(.id == $id) | .["display-name"]' <<< "$custom_images_json" 2>/dev/null)
                echo -e "${GREEN}✓ Image: ${WHITE}${sel_name}${NC}"
                echo -e "  ${GRAY}${_SELECTED_IMAGE}${NC}"
                return 0
            else
                echo -e "${RED}Invalid selection${NC}"; return 1
            fi
            ;;
        p|P) _select_image_browse_platform "$compartment_id" "$region" ;;
        n|N)
            if $has_np; then
                _select_image_from_nodepool "$np_json"
            else
                echo -e "${RED}No node pools available${NC}"; return 1
            fi
            ;;
        o|O)
            echo -n -e "${CYAN}Enter image OCID: ${NC}"
            read -r _SELECTED_IMAGE
            [[ -z "$_SELECTED_IMAGE" ]] && return 1
            echo -e "${GREEN}✓ Image: ${GRAY}${_SELECTED_IMAGE}${NC}"
            return 0
            ;;
        r|R) rm -f "$CUSTOM_IMAGE_CACHE"; _select_image "$compartment_id" "$region" ${np_json:+--node-pools "$np_json"}; return $? ;;
        b|B) return 1 ;;
        *) echo -e "${RED}Invalid selection${NC}"; return 1 ;;
    esac
}

# Browse OKE platform images (GPU + standard + aarch64)
_select_image_browse_platform() {
    local compartment_id="$1" region="$2"
    
    echo ""
    _step_init
    _step_active "OKE platform images"
    
    local platform_json
    if is_cache_fresh "$PLATFORM_IMAGE_CACHE"; then
        platform_json=$(cat "$PLATFORM_IMAGE_CACHE")
    else
        platform_json=$(_oci_call "image list (platform)" oci compute image list \
            --compartment-id "$compartment_id" \
            --region "$region" \
            --operating-system "Oracle Linux" \
            --sort-by TIMECREATED --sort-order DESC \
            --all --output json)
        
        if [[ -n "$platform_json" ]] && jq -e '.data' <<< "$platform_json" > /dev/null 2>&1; then
            # Filter to only OKE images, keep latest 30
            platform_json=$(jq '{data: [.data[] | select(.["display-name"] | test("OKE")) ] | .[0:30]}' <<< "$platform_json")
        else
            platform_json='{"data":[]}'
        fi
        [[ -n "$platform_json" ]] && echo "$platform_json" | _cache_write "$PLATFORM_IMAGE_CACHE"
    fi
    
    local total_count=0
    if jq -e '.data' <<< "$platform_json" > /dev/null 2>&1; then
        total_count=$(_jq_count "$platform_json")
    fi
    [[ -z "$total_count" || "$total_count" == "null" ]] && total_count=0
    _step_complete "OKE images(${total_count})"
    _step_finish
    
    if [[ "$total_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No OKE platform images found${NC}"
        _ui_pause
        return 1
    fi
    
    # Categorize: GPU, Aarch64, Standard
    local gpu_json aarch_json std_json
    gpu_json=$(jq '{data: [.data[] | select(.["display-name"] | test("GPU"))]}' <<< "$platform_json")
    aarch_json=$(jq '{data: [.data[] | select(.["display-name"] | test("aarch64"))]}' <<< "$platform_json")
    std_json=$(jq '{data: [.data[] | select( (.["display-name"] | test("GPU") | not) and (.["display-name"] | test("aarch64") | not) )]}' <<< "$platform_json")
    
    local gpu_count=$(_jq_count "$gpu_json")
    local aarch_count=$(_jq_count "$aarch_json")
    local std_count=$(_jq_count "$std_json")
    
    echo ""
    echo -e "  ${CYAN}Filter:${NC}"
    echo -e "    ${YELLOW}g${NC})  OKE GPU images     (${gpu_count})"
    echo -e "    ${YELLOW}a${NC})  OKE Aarch64 images  (${aarch_count})"
    echo -e "    ${YELLOW}s${NC})  OKE Standard images (${std_count})"
    echo -e "    ${YELLOW}*${NC})  Show all            (${total_count})"
    echo ""
    _ui_prompt "Filter" "g, a, s, *, b"
    read -r _pf_filter
    
    local show_json="$platform_json"
    local show_label="All OKE"
    case "$_pf_filter" in
        g|G) show_json="$gpu_json"; show_label="OKE GPU" ;;
        a|A) show_json="$aarch_json"; show_label="OKE Aarch64" ;;
        s|S) show_json="$std_json"; show_label="OKE Standard" ;;
        b|B) return 1 ;;
        *)   show_json="$platform_json"; show_label="All OKE" ;;
    esac
    
    local show_count=$(_jq_count "$show_json")
    if [[ "$show_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No images in this category${NC}"
        _ui_pause
        return 1
    fi
    
    echo ""
    _ui_subheader "${show_label} Images (${show_count})" 0
    echo ""
    _ui_table_header "  %-3s %-14s %-12s  %s" "#" "Status" "Created" "Image Name"
    
    declare -A _IMG_MAP=()
    local idx=0
    while IFS='|' read -r img_id img_name img_created img_state; do
        [[ -z "$img_id" ]] && continue
        ((idx++))
        _IMG_MAP[$idx]="$img_id"
        
        local created_display="${img_created:0:10}"
        local state_color="${WHITE}"
        case "$img_state" in
            AVAILABLE) state_color="${GREEN}" ;;
            *) state_color="${YELLOW}" ;;
        esac
        
        printf "  ${YELLOW}%-3s${NC} ${state_color}%-14s${NC} %-12s  %s\n" \
            "$idx" "$img_state" "$created_display" "$img_name"
    done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["time-created"] // "N/A")|\(.["lifecycle-state"] // "UNKNOWN")"' <<< "$show_json" 2>/dev/null)
    
    echo ""
    _ui_prompt "Select image" "1-${idx}, b"
    read -r _img_sel
    
    case "$_img_sel" in
        b|B) return 1 ;;
        [0-9]*)
            if [[ -n "${_IMG_MAP[$_img_sel]:-}" ]]; then
                _SELECTED_IMAGE="${_IMG_MAP[$_img_sel]}"
                # Show the image name for confirmation
                local sel_name
                sel_name=$(jq -r --arg id "$_SELECTED_IMAGE" '.data[] | select(.id == $id) | .["display-name"]' <<< "$show_json" 2>/dev/null)
                echo -e "${GREEN}✓ Image: ${WHITE}${sel_name}${NC}"
                echo -e "  ${GRAY}${_SELECTED_IMAGE}${NC}"
                return 0
            else
                echo -e "${RED}Invalid selection${NC}"; return 1
            fi
            ;;
        *) echo -e "${RED}Invalid selection${NC}"; return 1 ;;
    esac
}

# Copy image from existing node pool
_select_image_from_nodepool() {
    local np_json="$1"
    
    echo ""
    _ui_subheader "Existing Node Pool Images" 0
    echo ""
    
    declare -A _np_img_map=()
    local idx=0
    while IFS='|' read -r _npname _npshape _npimg; do
        [[ -z "$_npname" || -z "$_npimg" || "$_npimg" == "null" ]] && continue
        ((idx++))
        _np_img_map[$idx]="$_npimg"
        printf "  ${YELLOW}%-3s${NC} %-35s %-25s ${GRAY}%s${NC}\n" \
            "$idx" "$(truncate_string "$_npname" 34)" "$_npshape" "$(_short_ocid "$_npimg")"
    done < <(jq -r '.data[]? | "\(.name // "N/A")|\(.["node-shape"] // "N/A")|\(.["node-source"]?["image-id"] // .["node-source-details"]?["image-id"] // "null")"' <<< "$np_json" 2>/dev/null)
    
    if [[ $idx -eq 0 ]]; then
        echo -e "  ${GRAY}No images found in existing node pools${NC}"
        _ui_pause
        return 1
    fi
    
    echo ""
    _ui_prompt "Copy image from" "1-${idx}, b"
    read -r _np_img_sel
    
    case "$_np_img_sel" in
        b|B) return 1 ;;
        [0-9]*)
            if [[ -n "${_np_img_map[$_np_img_sel]:-}" ]]; then
                _SELECTED_IMAGE="${_np_img_map[$_np_img_sel]}"
                echo -e "${GREEN}✓ Image: ${GRAY}${_SELECTED_IMAGE}${NC}"
                return 0
            else
                echo -e "${RED}Invalid selection${NC}"; return 1
            fi
            ;;
        *) echo -e "${RED}Invalid selection${NC}"; return 1 ;;
    esac
}

# _select_oke_network — Derive subnet + NSGs from an OKE cluster's node pool config
# For Native VCN CNI: extracts worker subnet, worker NSGs, pod subnet, pod NSGs
# For Flannel:        extracts worker subnet, worker NSGs
# Usage: _select_oke_network "$compartment_id" "$region"
#   Sets: _SELECTED_SUBNET      (worker subnet OCID)
#         _SELECTED_NSG_IDS     (worker NSG JSON array)
#         _SELECTED_POD_SUBNET  (pod subnet OCID, Native VCN CNI only)
#         _SELECTED_POD_NSG_IDS (pod NSG JSON array, Native VCN CNI only)
#         _OKE_NET_CLUSTER_ID / _OKE_NET_CLUSTER_NAME / _OKE_NET_CNI / _OKE_NET_K8S_VER
#         _OKE_NET_DEFAULT_AD (AD from existing node pool placement config)
#   Returns: 0 on selection, 1 on cancel/error
_SELECTED_SUBNET=""
_SELECTED_SUBNET_NAME=""
_SELECTED_NSG_IDS="[]"
_SELECTED_NSG_NAMES="[]"
_SELECTED_POD_SUBNET=""
_SELECTED_POD_SUBNET_NAME=""
_SELECTED_POD_NSG_IDS="[]"
_SELECTED_POD_NSG_NAMES="[]"
_OKE_NET_CLUSTER_ID=""
_OKE_NET_CLUSTER_NAME=""
_OKE_NET_CNI=""
_OKE_NET_K8S_VER=""
_OKE_NET_DEFAULT_AD=""
_select_oke_network() {
    local compartment_id="$1" region="$2"
    _SELECTED_SUBNET=""
    _SELECTED_SUBNET_NAME=""
    _SELECTED_NSG_IDS="[]"
    _SELECTED_NSG_NAMES="[]"
    _SELECTED_POD_SUBNET=""
    _SELECTED_POD_SUBNET_NAME=""
    _SELECTED_POD_NSG_IDS="[]"
    _SELECTED_POD_NSG_NAMES="[]"
    _OKE_NET_CLUSTER_ID=""
    _OKE_NET_CLUSTER_NAME=""
    _OKE_NET_CNI=""
    _OKE_NET_K8S_VER=""
    _OKE_NET_DEFAULT_AD=""

    # ── Step 1: Select OKE Cluster ──
    echo ""
    echo -e "${CYAN}Select OKE Cluster:${NC}"

    local clusters_json
    clusters_json=$(_oci_discover "OKE clusters" \
        oci ce cluster list \
        --compartment-id "$compartment_id" --region "$region" \
        --lifecycle-state ACTIVE --all --output json)

    local cluster_count
    cluster_count=$(_jq_count "$clusters_json")

    if [[ "$cluster_count" -eq 0 ]]; then
        echo -e "${RED}No active OKE clusters found in region ${region}${NC}"
        return 1
    fi

    echo ""
    _ui_subheader "Active OKE Clusters (${cluster_count})" 0
    echo ""
    _ui_table_header "  %-3s %-40s %-12s %-22s %-30s" "#" "Cluster Name" "Version" "CNI" "OCID"

    declare -A _oke_cl_map=()
    local cidx=0
    while IFS='|' read -r cid cname cver ccni; do
        [[ -z "$cid" ]] && continue
        ((cidx++))
        _oke_cl_map[$cidx]="$cid|$cname|$cver|$ccni"
        local cni_display="$ccni" cni_color="$WHITE"
        case "$ccni" in
            FLANNEL_OVERLAY)    cni_display="Flannel"; cni_color="$CYAN" ;;
            OCI_VCN_IP_NATIVE)  cni_display="Native VCN CNI"; cni_color="$GREEN" ;;
        esac
        local marker=""
        [[ "$cid" == "${FOCUS_OKE_CLUSTER_ID:-}" ]] && marker=" ${GREEN}◄ focused${NC}"
        printf "  ${YELLOW}%-3s${NC} %-40s %-12s ${cni_color}%-22s${NC} ${GRAY}%-30s${NC}%b\n" \
            "$cidx" "$(truncate_string "$cname" 39)" "$cver" "$cni_display" "$(_short_ocid "$cid")" "$marker"
    done < <(jq -r '.data[] | "\(.id)|\(.name)|\(.["kubernetes-version"])|\(.["cluster-pod-network-options"][0]["cni-type"] // "FLANNEL_OVERLAY")"' <<< "$clusters_json" 2>/dev/null)

    echo ""
    # Default: focused cluster if present, otherwise first
    local default_cl_idx="1"
    local _ci
    for _ci in "${!_oke_cl_map[@]}"; do
        local _cid_check="${_oke_cl_map[$_ci]%%|*}"
        if [[ "$_cid_check" == "${FOCUS_OKE_CLUSTER_ID:-}" ]]; then
            default_cl_idx="$_ci"
            break
        fi
    done

    local _oke_cl_sel=""
    if [[ "$cidx" -eq 1 ]]; then
        # Single cluster — auto-select
        _oke_cl_sel="1"
        echo -e "  ${GRAY}(auto-selected — only 1 cluster)${NC}"
    else
        local cl_hint="Enter=${default_cl_idx}, 1-${cidx}"
        _ui_prompt "Cluster" "$cl_hint, b"
        read -r _oke_cl_sel
        [[ "$_oke_cl_sel" == "b" || "$_oke_cl_sel" == "B" ]] && return 1
        [[ -z "$_oke_cl_sel" ]] && _oke_cl_sel="$default_cl_idx"
    fi

    if [[ -z "$_oke_cl_sel" || -z "${_oke_cl_map[$_oke_cl_sel]+x}" ]]; then
        echo -e "${RED}Invalid selection${NC}"; return 1
    fi

    local sel_cluster_id sel_cluster_name sel_k8s_ver sel_cni
    IFS='|' read -r sel_cluster_id sel_cluster_name sel_k8s_ver sel_cni <<< "${_oke_cl_map[$_oke_cl_sel]}"
    _OKE_NET_CLUSTER_ID="$sel_cluster_id"
    _OKE_NET_CLUSTER_NAME="$sel_cluster_name"
    _OKE_NET_CNI="$sel_cni"
    _OKE_NET_K8S_VER="$sel_k8s_ver"
    echo -e "${GREEN}✓ Cluster: ${WHITE}${sel_cluster_name}${NC}"

    # ── Step 2: Fetch cluster detail for VCN ──
    echo ""
    _step_init
    _step_active "cluster details"
    local cluster_detail
    cluster_detail=$(oci ce cluster get --cluster-id "$sel_cluster_id" --region "$region" --output json 2>/dev/null)
    if [[ -z "$cluster_detail" ]]; then
        _step_complete "cluster details(FAILED)"
        _step_finish
        echo -e "${RED}Failed to fetch cluster details${NC}"; return 1
    fi
    local vcn_id
    vcn_id=$(jq -r '.data["vcn-id"] // ""' <<< "$cluster_detail" 2>/dev/null)
    _step_complete "cluster details"
    _step_finish

    local cni_label="Flannel"
    [[ "$sel_cni" == "OCI_VCN_IP_NATIVE" ]] && cni_label="Native VCN CNI"
    echo -e "  ${CYAN}CNI Type:${NC}     ${WHITE}${cni_label}${NC}"
    echo -e "  ${CYAN}K8s Version:${NC}  ${WHITE}${sel_k8s_ver}${NC}"
    echo -e "  ${CYAN}VCN:${NC}          ${GRAY}${vcn_id}${NC}"

    # ── Step 3: Fetch OKE configuration and extract network config ──
    local np_json
    np_json=$(_oci_discover "OKE configuration" \
        oci ce node-pool list \
        --cluster-id "$sel_cluster_id" \
        --compartment-id "$compartment_id" --region "$region" \
        --all --output json)

    local np_count
    np_count=$(_jq_count "$np_json")

    # Extract network config from existing node pools
    local np_worker_subnet="" np_worker_nsgs="[]"
    local np_pod_subnet="" np_pod_nsgs="[]"
    local np_default_ad=""

    if [[ "$np_count" -gt 0 ]]; then
        # Worker subnet — first unique from placement configs
        np_worker_subnet=$(jq -r '[.data[]? | .["node-config-details"]?["placement-configs"]?[]?["subnet-id"] // empty] | unique | first // empty' <<< "$np_json" 2>/dev/null)

        # Worker NSGs
        np_worker_nsgs=$(jq -c '[.data[]? | .["node-config-details"]?["nsg-ids"]?[]? // empty] | unique' <<< "$np_json" 2>/dev/null)
        [[ -z "$np_worker_nsgs" || "$np_worker_nsgs" == "null" ]] && np_worker_nsgs="[]"

        # Default AD from first placement config
        np_default_ad=$(jq -r '[.data[]? | .["node-config-details"]?["placement-configs"]?[]?["availability-domain"] // empty] | unique | first // empty' <<< "$np_json" 2>/dev/null)
        [[ "$np_default_ad" == "null" ]] && np_default_ad=""
        _OKE_NET_DEFAULT_AD="$np_default_ad"

        # Native VCN CNI: pod subnet + pod NSGs
        if [[ "$sel_cni" == "OCI_VCN_IP_NATIVE" ]]; then
            np_pod_subnet=$(jq -r '[.data[]? | .["node-config-details"]?["node-pool-pod-network-option-details"]?["pod-subnet-ids"]?[]? // empty] | unique | first // empty' <<< "$np_json" 2>/dev/null)

            np_pod_nsgs=$(jq -c '[.data[]? | .["node-config-details"]?["node-pool-pod-network-option-details"]?["pod-nsg-ids"]?[]? // empty] | unique' <<< "$np_json" 2>/dev/null)
            [[ -z "$np_pod_nsgs" || "$np_pod_nsgs" == "null" ]] && np_pod_nsgs="[]"
        fi

        # ── Resolve display names from VCN ──
        local _subnet_names_json="" _nsg_names_json=""
        if [[ -n "$vcn_id" && "$vcn_id" != "null" ]]; then
            # Fetch subnets for name lookup
            _subnet_names_json=$(oci network subnet list \
                --vcn-id "$vcn_id" \
                --compartment-id "$compartment_id" --region "$region" \
                --all --output json 2>/dev/null)
            # Fetch NSGs for name lookup
            _nsg_names_json=$(oci network nsg list \
                --vcn-id "$vcn_id" \
                --compartment-id "$compartment_id" --region "$region" \
                --all --output json 2>/dev/null)
        fi

        # Helper: resolve OCID → display name from JSON
        _resolve_subnet_name() {
            local ocid="$1"
            [[ -z "$ocid" || "$ocid" == "null" || -z "$_subnet_names_json" ]] && { echo "$ocid"; return; }
            local name
            name=$(jq -r --arg id "$ocid" '.data[]? | select(.id == $id) | .["display-name"] // empty' <<< "$_subnet_names_json" 2>/dev/null)
            [[ -n "$name" ]] && echo "$name" || echo "$(_short_ocid "$ocid")"
        }
        _resolve_nsg_name() {
            local ocid="$1"
            [[ -z "$ocid" || "$ocid" == "null" || -z "$_nsg_names_json" ]] && { echo "$ocid"; return; }
            local name
            name=$(jq -r --arg id "$ocid" '.data[]? | select(.id == $id) | .["display-name"] // empty' <<< "$_nsg_names_json" 2>/dev/null)
            [[ -n "$name" ]] && echo "$name" || echo "$(_short_ocid "$ocid")"
        }

        # ── Display extracted config with names ──
        local w_nsg_count p_nsg_count
        w_nsg_count=$(jq 'length' <<< "$np_worker_nsgs" 2>/dev/null)
        p_nsg_count=$(jq 'length' <<< "$np_pod_nsgs" 2>/dev/null)
        [[ -z "$w_nsg_count" ]] && w_nsg_count=0
        [[ -z "$p_nsg_count" ]] && p_nsg_count=0

        echo ""
        echo -e "  ${GREEN}OKE Network Configuration:${NC}"
        echo ""

        # Worker section
        echo -e "    ${WHITE}── Worker Network ──${NC}"
        if [[ -n "$np_worker_subnet" && "$np_worker_subnet" != "null" ]]; then
            local w_sub_name
            w_sub_name=$(_resolve_subnet_name "$np_worker_subnet")
            echo -e "    ${CYAN}Subnet:${NC}  ${WHITE}${w_sub_name}${NC}  ${GRAY}${np_worker_subnet}${NC}"
        else
            echo -e "    ${CYAN}Subnet:${NC}  ${YELLOW}not found${NC}"
        fi
        if [[ "$w_nsg_count" -gt 0 ]]; then
            echo -e "    ${CYAN}NSGs (${w_nsg_count}):${NC}"
            for _nsg_i in $(jq -r '.[]' <<< "$np_worker_nsgs" 2>/dev/null); do
                local _nsg_name
                _nsg_name=$(_resolve_nsg_name "$_nsg_i")
                echo -e "      ${WHITE}${_nsg_name}${NC}  ${GRAY}${_nsg_i}${NC}"
            done
        else
            echo -e "    ${CYAN}NSGs:${NC}    ${GRAY}none${NC}"
        fi

        # Pod section (Native VCN CNI only)
        if [[ "$sel_cni" == "OCI_VCN_IP_NATIVE" ]]; then
            echo ""
            echo -e "    ${WHITE}── Pod Network (Native VCN CNI) ──${NC}"
            if [[ -n "$np_pod_subnet" && "$np_pod_subnet" != "null" ]]; then
                local p_sub_name
                p_sub_name=$(_resolve_subnet_name "$np_pod_subnet")
                echo -e "    ${CYAN}Subnet:${NC}  ${WHITE}${p_sub_name}${NC}  ${GRAY}${np_pod_subnet}${NC}"
            else
                echo -e "    ${CYAN}Subnet:${NC}  ${YELLOW}not found${NC}"
            fi
            if [[ "$p_nsg_count" -gt 0 ]]; then
                echo -e "    ${CYAN}NSGs (${p_nsg_count}):${NC}"
                for _nsg_i in $(jq -r '.[]' <<< "$np_pod_nsgs" 2>/dev/null); do
                    local _nsg_name
                    _nsg_name=$(_resolve_nsg_name "$_nsg_i")
                    echo -e "      ${WHITE}${_nsg_name}${NC}  ${GRAY}${_nsg_i}${NC}"
                done
            else
                echo -e "    ${CYAN}NSGs:${NC}    ${GRAY}none${NC}"
            fi
        fi

        # AD info
        if [[ -n "$np_default_ad" ]]; then
            local ad_short="${np_default_ad##*:}"
            echo ""
            echo -e "    ${CYAN}Availability Domain:${NC}  ${WHITE}${ad_short}${NC}"
        fi

        # ── Choose: use OKE config or discover from VCN ──
        echo ""
        echo -e "  ${YELLOW}1${NC}) Use existing OKE network configuration ${CYAN}(default)${NC}"
        echo -e "  ${YELLOW}2${NC}) Discover from VCN (pick different subnet/NSGs)"
        echo -e "  ${YELLOW}3${NC}) Enter subnet + NSGs manually"
        echo ""
        _ui_prompt "Network source" "Enter=1, 1-3, b"
        read -r _net_src
        [[ -z "$_net_src" ]] && _net_src="1"

        case "$_net_src" in
            1)
                _SELECTED_SUBNET="$np_worker_subnet"
                _SELECTED_SUBNET_NAME="$(_resolve_subnet_name "$np_worker_subnet")"
                _SELECTED_NSG_IDS="$np_worker_nsgs"
                # Build NSG names array
                local _nsg_names_arr="[]"
                for _nid in $(jq -r '.[]' <<< "$np_worker_nsgs" 2>/dev/null); do
                    local _nn; _nn=$(_resolve_nsg_name "$_nid")
                    _nsg_names_arr=$(jq --arg n "$_nn" '. + [$n]' <<< "$_nsg_names_arr")
                done
                _SELECTED_NSG_NAMES="$_nsg_names_arr"
                if [[ "$sel_cni" == "OCI_VCN_IP_NATIVE" ]]; then
                    _SELECTED_POD_SUBNET="$np_pod_subnet"
                    _SELECTED_POD_SUBNET_NAME="$(_resolve_subnet_name "$np_pod_subnet")"
                    _SELECTED_POD_NSG_IDS="$np_pod_nsgs"
                    local _pnsg_names_arr="[]"
                    for _pid in $(jq -r '.[]' <<< "$np_pod_nsgs" 2>/dev/null); do
                        local _pnn; _pnn=$(_resolve_nsg_name "$_pid")
                        _pnsg_names_arr=$(jq --arg n "$_pnn" '. + [$n]' <<< "$_pnsg_names_arr")
                    done
                    _SELECTED_POD_NSG_NAMES="$_pnsg_names_arr"
                fi
                echo -e "${GREEN}✓ Using existing OKE network configuration${NC}"
                return 0
                ;;
            2) ;; # Fall through to VCN discovery
            3) _network_manual_entry "$sel_cni"; return $? ;;
            b|B) return 1 ;;
            *) echo -e "${RED}Invalid selection${NC}"; return 1 ;;
        esac
    fi

    # ── Step 4: Discover from VCN ──
    if [[ -z "$vcn_id" || "$vcn_id" == "null" ]]; then
        echo -e "${YELLOW}VCN not found on cluster. Falling back to manual entry.${NC}"
        _network_manual_entry "$sel_cni"
        return $?
    fi

    _network_discover_from_vcn "$vcn_id" "$compartment_id" "$region" "$sel_cni" \
        "$np_worker_subnet" "$np_worker_nsgs" "$np_pod_subnet" "$np_pod_nsgs"
    return $?
}

# _select_standalone_network — Select VCN → Subnet → NSGs for non-OKE instance
# Lists VCNs in compartment, then subnets in selected VCN, then NSGs
# Usage: _select_standalone_network "$compartment_id" "$region"
#   Sets: _SELECTED_SUBNET, _SELECTED_NSG_IDS
#   Returns: 0 on success, 1 on cancel
_select_standalone_network() {
    local compartment_id="$1" region="$2"
    _SELECTED_SUBNET=""
    _SELECTED_NSG_IDS="[]"

    # ── Step 1: List VCNs ──
    echo ""
    local vcn_json
    vcn_json=$(_oci_discover "VCNs" \
        oci network vcn list \
        --compartment-id "$compartment_id" --region "$region" \
        --lifecycle-state AVAILABLE --all --output json)

    local vcn_count
    vcn_count=$(_jq_count "$vcn_json")

    if [[ "$vcn_count" -eq 0 ]]; then
        echo -e "${YELLOW}No VCNs found. Enter network details manually.${NC}"
        _network_manual_entry "NONE"
        return $?
    fi

    echo ""
    _ui_subheader "Available VCNs (${vcn_count})" 0
    echo ""
    _ui_table_header "  %-3s %-45s %-20s %-30s" "#" "VCN Name" "CIDR" "OCID"

    declare -A _vcn_map=()
    local vidx=0
    while IFS='|' read -r vid vname vcidr; do
        [[ -z "$vid" ]] && continue
        ((vidx++))
        _vcn_map[$vidx]="$vid"
        printf "  ${YELLOW}%-3s${NC} %-45s %-20s ${GRAY}%-30s${NC}\n" \
            "$vidx" "$(truncate_string "$vname" 44)" "$vcidr" "$(_short_ocid "$vid")"
    done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["cidr-block"] // .["cidr-blocks"][0] // "N/A")"' <<< "$vcn_json" 2>/dev/null)

    echo ""
    echo -e "  ${GREEN}o${NC})  Enter subnet OCID directly (skip VCN browse)"
    echo ""
    _ui_prompt "VCN" "1-${vidx}, o, b"
    read -r _vcn_sel

    case "$_vcn_sel" in
        b|B) return 1 ;;
        o|O)
            _network_manual_entry "NONE"
            return $?
            ;;
    esac

    if [[ -z "$_vcn_sel" || -z "${_vcn_map[$_vcn_sel]+x}" ]]; then
        echo -e "${RED}Invalid selection${NC}"; return 1
    fi

    local selected_vcn_id="${_vcn_map[$_vcn_sel]}"
    echo -e "${GREEN}✓ VCN selected${NC}"

    # ── Step 2+3: Subnets + NSGs from selected VCN ──
    _network_discover_from_vcn "$selected_vcn_id" "$compartment_id" "$region" "NONE" "" "[]" "" "[]"
    return $?
}

# _network_manual_entry — Manual subnet + NSG OCID entry
# Usage: _network_manual_entry "$cni_type"
#   cni_type: OCI_VCN_IP_NATIVE | FLANNEL_OVERLAY | NONE
_network_manual_entry() {
    local cni_type="${1:-NONE}"

    echo ""
    echo -e "  ${WHITE}── Worker Network ──${NC}"
    echo -n -e "  ${CYAN}Worker Subnet OCID: ${NC}"
    read -r _SELECTED_SUBNET
    [[ -z "$_SELECTED_SUBNET" ]] && return 1

    echo -n -e "  ${CYAN}Worker NSG OCIDs (comma-separated, Enter=skip): ${NC}"
    local nsg_input
    read -r nsg_input
    if [[ -n "$nsg_input" ]]; then
        _SELECTED_NSG_IDS=$(_csv_to_json_array "$nsg_input")
    else
        _SELECTED_NSG_IDS="[]"
    fi

    if [[ "$cni_type" == "OCI_VCN_IP_NATIVE" ]]; then
        echo ""
        echo -e "  ${WHITE}── Pod Network (Native VCN CNI) ──${NC}"
        echo -n -e "  ${CYAN}Pod Subnet OCID: ${NC}"
        read -r _SELECTED_POD_SUBNET
        [[ -z "$_SELECTED_POD_SUBNET" ]] && _SELECTED_POD_SUBNET=""

        echo -n -e "  ${CYAN}Pod NSG OCIDs (comma-separated, Enter=skip): ${NC}"
        local pod_nsg_input
        read -r pod_nsg_input
        if [[ -n "$pod_nsg_input" ]]; then
            _SELECTED_POD_NSG_IDS=$(_csv_to_json_array "$pod_nsg_input")
        else
            _SELECTED_POD_NSG_IDS="[]"
        fi
    fi

    echo -e "${GREEN}✓ Network config set${NC}"
    return 0
}

# _csv_to_json_array — Convert comma-separated string to JSON array
# Usage: _csv_to_json_array "ocid1...,ocid2..."
_csv_to_json_array() {
    echo "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# _network_discover_from_vcn — Discover subnets + NSGs from a VCN
# Usage: _network_discover_from_vcn "$vcn_id" "$comp" "$region" "$cni" \
#            "$default_worker_sub" "$default_worker_nsgs" "$default_pod_sub" "$default_pod_nsgs"
_network_discover_from_vcn() {
    local vcn_id="$1" compartment_id="$2" region="$3" cni_type="$4"
    local default_worker_sub="${5:-}" default_worker_nsgs="${6:-[]}"
    local default_pod_sub="${7:-}" default_pod_nsgs="${8:-[]}"

    # ── Discover subnets ──
    echo ""
    local subnet_json
    subnet_json=$(_oci_discover "subnets in VCN" \
        oci network subnet list \
        --vcn-id "$vcn_id" \
        --compartment-id "$compartment_id" --region "$region" \
        --all --output json)

    local sub_count
    sub_count=$(_jq_count "$subnet_json")

    if [[ "$sub_count" -eq 0 ]]; then
        echo -e "${YELLOW}No subnets found in VCN. Enter manually.${NC}"
        _network_manual_entry "$cni_type"
        return $?
    fi

    # ── Display subnet table ──
    echo ""
    _ui_subheader "VCN Subnets (${sub_count})" 0
    echo ""
    _ui_table_header "  %-3s %-45s %-20s %-10s %-30s" "#" "Subnet Name" "CIDR" "Access" "OCID"

    declare -A _subnet_map=()
    local sidx=0 default_worker_idx="" default_pod_idx=""
    while IFS='|' read -r sid sname scidr saccess; do
        [[ -z "$sid" ]] && continue
        ((sidx++))
        _subnet_map[$sidx]="$sid"

        local marker=""
        if [[ -n "$default_worker_sub" && "$sid" == "$default_worker_sub" ]]; then
            marker=" ${CYAN}◄ worker${NC}"
            default_worker_idx="$sidx"
        fi
        if [[ -n "$default_pod_sub" && "$sid" == "$default_pod_sub" ]]; then
            [[ -n "$marker" ]] && marker+=" "
            marker+="${GREEN}◄ pod${NC}"
            default_pod_idx="$sidx"
        fi

        local access_color="$GREEN"
        [[ "$saccess" == "Private" ]] && access_color="$MAGENTA"

        printf "  ${YELLOW}%-3s${NC} %-45s %-20s ${access_color}%-10s${NC} ${GRAY}%-30s${NC} %b\n" \
            "$sidx" "$(truncate_string "$sname" 44)" "$scidr" "$saccess" "$(_short_ocid "$sid")" "$marker"
    done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["cidr-block"] // "N/A")|\(if .["prohibit-public-ip-on-vnic"] then "Private" else "Public" end)"' <<< "$subnet_json" 2>/dev/null)

    # ── Select worker subnet ──
    echo ""
    local w_hint="1-${sidx}"
    [[ -n "$default_worker_idx" ]] && w_hint="1-${sidx}, Enter=${default_worker_idx}"
    _ui_prompt "Worker Subnet" "$w_hint, b"
    read -r _sub_sel

    [[ "$_sub_sel" == "b" || "$_sub_sel" == "B" ]] && return 1
    [[ -z "$_sub_sel" && -n "$default_worker_idx" ]] && _sub_sel="$default_worker_idx"

    if [[ -n "$_sub_sel" && -n "${_subnet_map[$_sub_sel]+x}" ]]; then
        _SELECTED_SUBNET="${_subnet_map[$_sub_sel]}"
        echo -e "${GREEN}✓ Worker subnet selected${NC}"
    else
        echo -e "${RED}Invalid selection${NC}"; return 1
    fi

    # ── Select pod subnet (Native VCN CNI only) ──
    if [[ "$cni_type" == "OCI_VCN_IP_NATIVE" ]]; then
        echo ""
        local p_hint="1-${sidx}"
        [[ -n "$default_pod_idx" ]] && p_hint="1-${sidx}, Enter=${default_pod_idx}"
        _ui_prompt "Pod Subnet" "$p_hint, s=skip, b"
        read -r _pod_sub_sel

        [[ "$_pod_sub_sel" == "b" || "$_pod_sub_sel" == "B" ]] && return 1
        [[ -z "$_pod_sub_sel" && -n "$default_pod_idx" ]] && _pod_sub_sel="$default_pod_idx"

        if [[ "$_pod_sub_sel" == "s" || "$_pod_sub_sel" == "S" ]]; then
            _SELECTED_POD_SUBNET=""
            echo -e "  ${GRAY}Pod subnet skipped${NC}"
        elif [[ -n "$_pod_sub_sel" && -n "${_subnet_map[$_pod_sub_sel]+x}" ]]; then
            _SELECTED_POD_SUBNET="${_subnet_map[$_pod_sub_sel]}"
            echo -e "${GREEN}✓ Pod subnet selected${NC}"
        else
            echo -e "${RED}Invalid selection${NC}"; return 1
        fi
    fi

    # ── Discover NSGs ──
    echo ""
    local nsg_json
    nsg_json=$(_oci_discover "network security groups" \
        oci network nsg list \
        --vcn-id "$vcn_id" \
        --compartment-id "$compartment_id" --region "$region" \
        --all --output json)

    local nsg_count
    nsg_count=$(_jq_count "$nsg_json")

    if [[ "$nsg_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No NSGs found in VCN — skipping NSG assignment${NC}"
        _SELECTED_NSG_IDS="[]"
        _SELECTED_POD_NSG_IDS="[]"
        return 0
    fi

    # ── Select worker NSGs (multi-select) ──
    _select_nsg_multi "$nsg_json" "Worker NSGs" "$default_worker_nsgs" || return 1
    _SELECTED_NSG_IDS="$_NSG_MULTI_RESULT"

    # ── Select pod NSGs (Native VCN CNI only) ──
    if [[ "$cni_type" == "OCI_VCN_IP_NATIVE" ]]; then
        echo ""
        _select_nsg_multi "$nsg_json" "Pod NSGs" "$default_pod_nsgs" || return 1
        _SELECTED_POD_NSG_IDS="$_NSG_MULTI_RESULT"
    fi

    return 0
}

# _select_nsg_multi — Reusable NSG multi-select from NSG list JSON
# Usage: _select_nsg_multi "$nsg_json" "label" "$default_nsg_ids_json"
#   Sets: _NSG_MULTI_RESULT (JSON array of selected NSG OCIDs)
#   Returns: 0 on selection, 1 on cancel
_NSG_MULTI_RESULT="[]"
_select_nsg_multi() {
    local nsg_json="$1" label="${2:-NSGs}" default_nsg_ids="${3:-[]}"
    _NSG_MULTI_RESULT="[]"

    local nsg_count
    nsg_count=$(_jq_count "$nsg_json")

    # Build list of default NSG IDs for marking
    local -a default_arr=()
    if [[ "$default_nsg_ids" != "[]" && -n "$default_nsg_ids" ]]; then
        while read -r _dn; do
            [[ -n "$_dn" ]] && default_arr+=("$_dn")
        done < <(jq -r '.[]' <<< "$default_nsg_ids" 2>/dev/null)
    fi

    echo ""
    _ui_subheader "${label} — Select (${nsg_count} available)" 0
    echo -e "  ${GRAY}Multi-select: 1,3,4 │ a=use marked │ s=skip${NC}"
    echo ""
    _ui_table_header "  %-3s %-50s %-14s %-30s %-4s" "#" "NSG Name" "State" "OCID" ""

    declare -A _nsg_map=()
    local nidx=0 default_indices=""
    while IFS='|' read -r nid nname nstate; do
        [[ -z "$nid" ]] && continue
        ((nidx++))
        _nsg_map[$nidx]="$nid"

        local marker=""
        for _dn in "${default_arr[@]}"; do
            if [[ "$nid" == "$_dn" ]]; then
                marker="${CYAN}◄${NC}"
                [[ -n "$default_indices" ]] && default_indices+=","
                default_indices+="$nidx"
                break
            fi
        done

        local state_color="$GREEN"
        [[ "$nstate" != "AVAILABLE" ]] && state_color="$YELLOW"

        printf "  ${YELLOW}%-3s${NC} %-50s ${state_color}%-14s${NC} ${GRAY}%-30s${NC} %b\n" \
            "$nidx" "$(truncate_string "$nname" 49)" "$nstate" "$(_short_ocid "$nid")" "$marker"
    done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["lifecycle-state"] // "UNKNOWN")"' <<< "$nsg_json" 2>/dev/null)

    echo ""
    local nsg_hint="1-${nidx} (comma-sep), s=skip"
    [[ -n "$default_indices" ]] && nsg_hint="1-${nidx} (comma-sep), a=use marked(${default_indices}), s=skip"
    _ui_prompt "$label" "$nsg_hint, b"
    read -r _nsg_sel

    case "$_nsg_sel" in
        b|B) return 1 ;;
        s|S|"")
            _NSG_MULTI_RESULT="[]"
            echo -e "  ${GRAY}No ${label} selected${NC}"
            return 0
            ;;
        a|A)
            if [[ -n "$default_indices" ]]; then
                _nsg_sel="$default_indices"
            else
                echo -e "${RED}No marked NSGs to auto-select${NC}"; return 1
            fi
            ;;
    esac

    # Parse comma-separated indices
    local -a selected_nsgs=()
    IFS=',' read -ra _nsg_indices <<< "$_nsg_sel"
    for _ni in "${_nsg_indices[@]}"; do
        _ni=$(echo "$_ni" | tr -d ' ')
        if [[ -n "$_ni" && -n "${_nsg_map[$_ni]+x}" ]]; then
            selected_nsgs+=("${_nsg_map[$_ni]}")
        else
            echo -e "${RED}Invalid NSG index: ${_ni}${NC}"; return 1
        fi
    done

    if [[ ${#selected_nsgs[@]} -eq 0 ]]; then
        _NSG_MULTI_RESULT="[]"
        echo -e "  ${GRAY}No ${label} selected${NC}"
    else
        _NSG_MULTI_RESULT=$(printf '%s\n' "${selected_nsgs[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
        echo -e "${GREEN}✓ ${label} selected (${#selected_nsgs[@]}):${NC}"
        for _sn in "${selected_nsgs[@]}"; do
            echo -e "    ${GRAY}${_sn}${NC}"
        done
    fi

    return 0
}

# _generate_oke_cloud_init — Generate OKE cloud-init YAML from cluster config
# Fetches private endpoint, CA cert, derives version strings, prompts for SSH key
# Usage: _generate_oke_cloud_init "$cluster_id" "$k8s_ver" "$region"
#   Sets: _GENERATED_CLOUD_INIT (file path to generated YAML)
#   Returns: 0 on success, 1 on failure
_GENERATED_CLOUD_INIT=""
_generate_oke_cloud_init() {
    local cluster_id="$1" k8s_ver="$2" region="$3"
    _GENERATED_CLOUD_INIT=""

    echo ""
    echo -e "  ${CYAN}Generating OKE cloud-init from cluster...${NC}"

    # ── Derive version strings ──
    # v1.31.1 → 1.31 (apt repo) and 1.31.1 (package)
    local ver_stripped="${k8s_ver#v}"         # "1.31.1"
    local ver_major_minor="${ver_stripped%.*}" # "1.31"
    local ver_full="$ver_stripped"             # "1.31.1"

    echo -e "    ${CYAN}K8s Version:${NC}    ${WHITE}${k8s_ver}${NC}"
    echo -e "    ${CYAN}Apt Repo Ver:${NC}   ${WHITE}${ver_major_minor}${NC}"
    echo -e "    ${CYAN}Package Ver:${NC}    ${WHITE}${ver_full}${NC}"

    # ── Fetch cluster detail for private endpoint ──
    _step_init
    _step_active "cluster endpoint"
    local cluster_detail
    cluster_detail=$(oci ce cluster get --cluster-id "$cluster_id" --region "$region" --output json 2>/dev/null)
    if [[ -z "$cluster_detail" ]]; then
        _step_complete "cluster endpoint(FAILED)"
        _step_finish
        echo -e "${RED}Failed to fetch cluster details${NC}"
        return 1
    fi

    local private_endpoint
    private_endpoint=$(jq -r '.data.endpoints["private-endpoint"] // ""' <<< "$cluster_detail" 2>/dev/null)
    # Strip :6443 suffix
    local ca_ip="${private_endpoint%%:*}"

    if [[ -z "$ca_ip" || "$ca_ip" == "null" ]]; then
        _step_complete "cluster endpoint(NO PRIVATE EP)"
        _step_finish
        echo -e "${RED}No private endpoint configured on cluster${NC}"
        return 1
    fi
    _step_complete "cluster endpoint"
    _step_finish
    echo -e "    ${CYAN}API Server IP:${NC}  ${WHITE}${ca_ip}${NC}"

    # ── Fetch kubeconfig to extract CA cert ──
    _step_init
    _step_active "CA certificate"
    local tmp_kubeconfig="${CACHE_DIR}/_tmp_kubeconfig_$$"
    oci ce cluster create-kubeconfig \
        --cluster-id "$cluster_id" \
        --region "$region" \
        --token-version 2.0.0 \
        --file "$tmp_kubeconfig" >/dev/null 2>/dev/null

    if [[ ! -f "$tmp_kubeconfig" ]]; then
        _step_complete "CA certificate(FAILED)"
        _step_finish
        echo -e "${RED}Failed to fetch kubeconfig${NC}"
        return 1
    fi

    local ca_cert
    ca_cert=$(grep 'certificate-authority-data:' "$tmp_kubeconfig" | head -1 | awk '{print $2}')
    rm -f "$tmp_kubeconfig"

    if [[ -z "$ca_cert" ]]; then
        _step_complete "CA certificate(NOT FOUND)"
        _step_finish
        echo -e "${RED}Could not extract CA cert from kubeconfig${NC}"
        return 1
    fi
    _step_complete "CA certificate"
    _step_finish
    echo -e "    ${CYAN}CA Cert:${NC}        ${WHITE}${ca_cert:0:40}...${NC}"

    # ── Prompt for SSH public key ──
    echo ""
    echo -e "  ${CYAN}SSH Public Key:${NC}"
    echo -e "    ${YELLOW}1${NC}) Paste SSH public key"
    echo -e "    ${YELLOW}2${NC}) Read from file path"
    echo -e "    ${YELLOW}s${NC}) Skip (no SSH key)"
    echo ""
    _ui_prompt "SSH Key" "1, 2, s"
    local _ssh_choice
    read -r _ssh_choice

    local ssh_key=""
    case "$_ssh_choice" in
        1)
            echo -n -e "    ${CYAN}SSH public key: ${NC}"
            read -r ssh_key
            [[ -n "$ssh_key" ]] && echo -e "    ${GREEN}✓ SSH key loaded (${#ssh_key} chars)${NC}"
            ;;
        2)
            echo -n -e "    ${CYAN}Path to SSH public key file: ${NC}"
            local ssh_path
            read -r ssh_path
            if [[ -f "$ssh_path" ]]; then
                ssh_key=$(cat "$ssh_path" 2>/dev/null)
                echo -e "    ${GREEN}✓ Loaded from ${ssh_path}${NC}"
            else
                echo -e "    ${RED}File not found: ${ssh_path}${NC}"
            fi
            ;;
        s|S|"")
            echo -e "    ${GRAY}No SSH key — skipping${NC}"
            ;;
    esac

    # ── Generate cloud-init YAML ──
    local output_file="${CACHE_DIR}/oke-cloud-init-$(date +%Y%m%d-%H%M%S).yml"

    cat > "$output_file" << CLOUD_INIT_EOF
#cloud-config
apt:
  sources:
    oke-node: {source: 'deb [trusted=yes] https://objectstorage.us-sanjose-1.oraclecloud.com/p/_Zaa2khW3lPESEbqZ2JB3FijAd0HeKmiP-KA2eOMuWwro85dcG2WAqua2o_a-PlZ/n/odx-oke/b/okn-repositories-private/o/prod/ubuntu-jammy/kubernetes-${ver_major_minor} stable main'}
packages:
  - oci-oke-node-all-${ver_full}
write_files:
  - path: /etc/oke/oke-apiserver
    permissions: '0644'
    content: ${ca_ip}
  - encoding: b64
    path: /etc/kubernetes/ca.crt
    permissions: '0644'
    content: ${ca_cert}
runcmd:
  - oke bootstrap --apiserver-host ${ca_ip} --ca "${ca_cert}" --kubelet-extra-args "--register-with-taints=newNode=true:NoSchedule"
CLOUD_INIT_EOF

    # Append SSH key if provided
    if [[ -n "$ssh_key" ]]; then
        cat >> "$output_file" << SSH_EOF
ssh_authorized_keys:
  - ${ssh_key}
SSH_EOF
    fi

    # ── Preview ──
    echo ""
    echo -e "  ${GREEN}✓ Cloud-init generated: ${WHITE}$(basename "$output_file")${NC}"
    echo ""
    echo -e "  ${GRAY}── Preview ──${NC}"
    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        printf "  ${GRAY}%3d│${NC} %s\n" "$line_num" "$line"
    done < "$output_file"
    echo -e "  ${GRAY}── End ──${NC}"

    _GENERATED_CLOUD_INIT="$output_file"
    return 0
}

# _browse_cloud_init_files — List YAML/cloud-init files in current directory for selection
# Usage: _browse_cloud_init_files
#   Sets: _BROWSED_CLOUD_INIT (selected file path)
#   Returns: 0 on selection, 1 on cancel
_BROWSED_CLOUD_INIT=""
_browse_cloud_init_files() {
    local search_dir="."
    _BROWSED_CLOUD_INIT=""

    echo ""
    echo -e "  ${CYAN}Browsing files in: ${WHITE}$(pwd)${NC}"
    echo ""

    # Find yml, yaml, and cloud-init files
    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$search_dir" -maxdepth 2 -type f \( \
        -name "*.yml" -o -name "*.yaml" -o \
        -name "*cloud-init*" -o -name "*cloud_init*" -o \
        -name "*cloudinit*" -o -name "*user-data*" -o -name "*userdata*" \
    \) -print0 2>/dev/null | sort -z)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}No YAML/cloud-init files found in current directory${NC}"
        echo -n -e "  ${CYAN}Enter file path instead: ${NC}"
        local manual_path
        read -r manual_path
        if [[ -n "$manual_path" && -f "$manual_path" ]]; then
            echo -e "  ${GREEN}✓ File: ${WHITE}${manual_path}${NC}"
            _BROWSED_CLOUD_INIT="$manual_path"
            return 0
        fi
        return 1
    fi

    _ui_table_header "  %-3s %-60s %-10s %-12s" "#" "File" "Size" "Modified"

    declare -A _file_map=()
    local fidx=0
    for f in "${files[@]}"; do
        ((fidx++))
        _file_map[$fidx]="$f"
        local fname="${f#./}"
        local fsize
        fsize=$(stat -c '%s' "$f" 2>/dev/null)
        if [[ "$fsize" -ge 1024 ]]; then
            fsize="$((fsize / 1024))K"
        else
            fsize="${fsize}B"
        fi
        local fmod
        fmod=$(stat -c '%y' "$f" 2>/dev/null | cut -d' ' -f1)
        printf "  ${YELLOW}%-3s${NC} %-60s %-10s %-12s\n" \
            "$fidx" "$(truncate_string "$fname" 59)" "$fsize" "$fmod"
    done

    echo ""
    _ui_prompt "File" "1-${fidx}, b"
    local _fsel
    read -r _fsel

    [[ "$_fsel" == "b" || "$_fsel" == "B" ]] && return 1

    if [[ -n "$_fsel" && -n "${_file_map[$_fsel]+x}" ]]; then
        local selected="${_file_map[$_fsel]}"
        echo -e "  ${GREEN}✓ File: ${WHITE}${selected}${NC}"
        _BROWSED_CLOUD_INIT="$selected"
        return 0
    else
        echo -e "  ${RED}Invalid selection${NC}"
        return 1
    fi
}

#===============================================================================
# TOOL DETECTION
#===============================================================================

_detect_tool_versions() {
    _TOOL_OCI_VER=$(oci --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
    [[ -z "$_TOOL_OCI_VER" ]] && _TOOL_OCI_VER="n/a"
    
    _TOOL_OCI_AUTH="api_key"
    _TOOL_OCI_AUTH_SOURCE="config"
    _TOOL_OCI_USER=""
    
    if [[ "${OCI_CLI_AUTH:-}" == "instance_principal" ]]; then
        _TOOL_OCI_AUTH="instance_principal"
        _TOOL_OCI_AUTH_SOURCE="config"
    elif curl -sS -m "$IMDS_TIMEOUT" -H "Authorization: Bearer Oracle" -L "${IMDS_BASE}/instance/" -o /dev/null 2>/dev/null; then
        if oci iam region list --auth instance_principal --output json &>/dev/null 2>&1; then
            _TOOL_OCI_AUTH="instance_principal"
            _TOOL_OCI_AUTH_SOURCE="derived"
        fi
    fi
    
    _TOOL_TENANCY_NAME=""
    if [[ -n "${TENANCY_ID:-}" ]]; then
        _TOOL_TENANCY_NAME=$(_oci_call "tenancy get" oci iam tenancy get --tenancy-id "$TENANCY_ID" \
            --query 'data.name' --raw-output 2>/dev/null) || true
        [[ "$_TOOL_TENANCY_NAME" == "null" ]] && _TOOL_TENANCY_NAME=""
    fi
    
    _TOOL_KUBECTL_VER=""
    if command -v kubectl &>/dev/null; then
        _TOOL_KUBECTL_VER=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null)
        [[ -z "$_TOOL_KUBECTL_VER" ]] && _TOOL_KUBECTL_VER="installed"
    fi
}

#===============================================================================
# IDENTITY UTILITIES — compartment tree, domain selection, name resolution
# Ported from k8s_get_node_details.sh and adapted for gpu_ops_testing patterns.
#===============================================================================

# Global arrays for compartment tree (populated by display_compartment_selector)
declare -gA COMP_MAP=()          # id -> "name|state|parent_id|description"
declare -gA COMP_CHILDREN=()     # parent_id -> space-delimited child ids
declare -gA COMP_IDX=()          # display_index -> id (for selection)
declare -gA COMP_IDX_REV=()      # id -> display_index (reverse lookup)
declare -g  COMP_SELECTOR_COUNT=0

# Cache for resolved compartment names
declare -gA RESOLVED_COMP_NAME_CACHE=()

#--------------------------------------------------------------------------------
# get_tenancy_id_from_compartment — walk up hierarchy to find tenancy root
# Usage: tenancy_id=$(get_tenancy_id_from_compartment "$compartment_id")
#--------------------------------------------------------------------------------
get_tenancy_id_from_compartment() {
    local compartment_id="$1"
    
    # If already a tenancy OCID, return it
    [[ "$compartment_id" == ocid1.tenancy.* ]] && { echo "$compartment_id"; return; }
    
    # If TENANCY_ID is set, use it directly (avoids API calls)
    [[ -n "${TENANCY_ID:-}" ]] && { echo "$TENANCY_ID"; return; }
    
    # Walk up the hierarchy
    local current="$compartment_id"
    while [[ "$current" =~ ^ocid1\.compartment\. ]]; do
        local parent
        parent=$(_oci_call "compartment get" oci iam compartment get \
            --compartment-id "$current" --query 'data."compartment-id"' --raw-output 2>/dev/null)
        [[ -z "$parent" || "$parent" == "$current" ]] && break
        current="$parent"
    done
    echo "$current"
}

#--------------------------------------------------------------------------------
# resolve_compartment_name — resolve OCID to display name (cached)
# Usage: name=$(resolve_compartment_name "$ocid")
#--------------------------------------------------------------------------------
resolve_compartment_name() {
    local ocid="$1"
    [[ -z "$ocid" ]] && { echo "Unknown"; return; }
    
    # Check in-memory cache
    [[ -n "${RESOLVED_COMP_NAME_CACHE[$ocid]+_}" ]] && { echo "${RESOLVED_COMP_NAME_CACHE[$ocid]}"; return; }
    
    # Warm from COMP_MAP if available
    if [[ ${#COMP_MAP[@]} -gt 0 ]]; then
        for _cid in "${!COMP_MAP[@]}"; do
            [[ -z "${RESOLVED_COMP_NAME_CACHE[$_cid]+_}" ]] && RESOLVED_COMP_NAME_CACHE[$_cid]="${COMP_MAP[$_cid]%%|*}"
        done
        [[ -n "${RESOLVED_COMP_NAME_CACHE[$ocid]+_}" ]] && { echo "${RESOLVED_COMP_NAME_CACHE[$ocid]}"; return; }
    fi
    
    # Warm from compartments cache file
    if [[ -f "$COMPARTMENTS_CACHE" && -s "$COMPARTMENTS_CACHE" ]]; then
        local _cage=$(($(date +%s) - $(stat -c %Y "$COMPARTMENTS_CACHE" 2>/dev/null || echo 0)))
        if [[ $_cage -lt $CACHE_MAX_AGE ]]; then
            while IFS='|' read -r _cid _cname; do
                [[ -n "$_cid" && -n "$_cname" ]] && RESOLVED_COMP_NAME_CACHE[$_cid]="$_cname"
            done < <(jq -r '.data[]? | "\(.id)|\(.name)"' "$COMPARTMENTS_CACHE" 2>/dev/null)
        fi
        [[ -n "${RESOLVED_COMP_NAME_CACHE[$ocid]+_}" ]] && { echo "${RESOLVED_COMP_NAME_CACHE[$ocid]}"; return; }
    fi
    
    # API fallback for compartment
    if [[ "$ocid" == ocid1.compartment.* ]]; then
        local name
        name=$(_oci_call "compartment get" oci iam compartment get \
            --compartment-id "$ocid" --query 'data.name' --raw-output 2>/dev/null)
        if [[ -n "$name" && "$name" != "null" ]]; then
            RESOLVED_COMP_NAME_CACHE[$ocid]="$name"
            echo "$name"; return
        fi
    fi
    
    # API fallback for tenancy
    if [[ "$ocid" == ocid1.tenancy.* ]]; then
        local name
        name=$(_oci_call "tenancy get" oci iam tenancy get \
            --tenancy-id "$ocid" --query 'data.name' --raw-output 2>/dev/null)
        if [[ -n "$name" && "$name" != "null" ]]; then
            RESOLVED_COMP_NAME_CACHE[$ocid]="$name"
            echo "$name"; return
        fi
    fi
    
    echo "$(_short_ocid "$ocid")"
}

#--------------------------------------------------------------------------------
# display_compartment_selector — show compartment tree, populate selection arrays
# Ported from k8s_get_node_details.sh display_compartment_selector
# Usage: display_compartment_selector "$tenancy_id" "$current_compartment"
#   Sets: COMP_MAP, COMP_CHILDREN, COMP_IDX, COMP_IDX_REV, COMP_SELECTOR_COUNT
#   Returns: 0 on success, 1 on failure
#--------------------------------------------------------------------------------
display_compartment_selector() {
    local tenancy_id="$1"
    local current_compartment="${2:-}"
    
    # Get tenancy name
    local tenancy_name
    tenancy_name=$(resolve_compartment_name "$tenancy_id")
    
    # Fetch compartments (with cache)
    local comp_json=""
    if is_cache_fresh "$COMPARTMENTS_CACHE"; then
        comp_json=$(< "$COMPARTMENTS_CACHE")
    fi
    if [[ -z "$comp_json" ]]; then
        comp_json=$(_oci_discover "compartments" \
            oci iam compartment list \
            --compartment-id "$tenancy_id" \
            --compartment-id-in-subtree true \
            --all --output json)
        [[ -n "$comp_json" ]] && echo "$comp_json" | _cache_write "$COMPARTMENTS_CACHE"
    fi
    
    if [[ -z "$comp_json" ]] || ! jq -e '.data' <<< "$comp_json" > /dev/null 2>&1; then
        echo -e "${RED}Failed to retrieve compartments. Check permissions.${NC}"
        return 1
    fi
    
    # Clear and rebuild tree
    COMP_MAP=(); COMP_CHILDREN=(); COMP_IDX=(); COMP_IDX_REV=()
    local comp_count=0
    
    while IFS='|' read -r comp_id comp_name comp_state comp_parent; do
        [[ -z "$comp_id" || "$comp_state" == "DELETED" ]] && continue
        ((comp_count++))
        COMP_MAP[$comp_id]="$comp_name|$comp_state|$comp_parent"
        if [[ -n "$comp_parent" ]]; then
            if [[ -n "${COMP_CHILDREN[$comp_parent]:-}" ]]; then
                COMP_CHILDREN[$comp_parent]="${COMP_CHILDREN[$comp_parent]} $comp_id"
            else
                COMP_CHILDREN[$comp_parent]="$comp_id"
            fi
        fi
    done < <(jq -r '.data[] | "\(.id)|\(.name)|\(.["lifecycle-state"])|\(.["compartment-id"])"' <<< "$comp_json" 2>/dev/null)
    
    echo ""
    _ui_subheader "Compartment Hierarchy (${comp_count} compartments)" 0
    echo ""
    
    # Print tenancy as root
    echo -e "  ${BOLD}${BLUE}🏢 ${tenancy_name}${NC} ${GRAY}(root tenancy)${NC}  ${YELLOW}${tenancy_id}${NC}"
    echo ""
    
    # Recursive tree printer
    local display_idx=0
    
    _print_comp_tree() {
        local parent_id="$1" depth="$2" prefix="$3"
        local children=(${COMP_CHILDREN[$parent_id]:-})
        local child_count=${#children[@]}
        local child_idx=0
        
        for child_id in "${children[@]}"; do
            [[ -z "$child_id" || -z "${COMP_MAP[$child_id]:-}" ]] && continue
            ((child_idx++))
            
            local comp_data="${COMP_MAP[$child_id]}"
            local comp_name="${comp_data%%|*}"
            local rest="${comp_data#*|}"
            local comp_state="${rest%%|*}"
            
            ((display_idx++))
            COMP_IDX[$display_idx]="$child_id"
            COMP_IDX_REV[$child_id]="$display_idx"
            
            local state_color="$GREEN"
            [[ "$comp_state" != "ACTIVE" ]] && state_color="$YELLOW"
            
            # Count grandchildren
            local gc_count=0
            for gc in ${COMP_CHILDREN[$child_id]:-}; do
                [[ -n "$gc" ]] && ((gc_count++))
            done
            
            # Tree branch chars
            local branch="├── " next_prefix="${prefix}│   "
            if [[ $child_idx -eq $child_count ]]; then
                branch="└── "
                next_prefix="${prefix}    "
            fi
            
            # Current marker
            local marker="  "
            [[ "$child_id" == "$current_compartment" ]] && marker="${BOLD}${CYAN}► ${NC}"
            
            # Info tag
            local info="${GRAY}(${NC}${state_color}${comp_state}${NC}"
            [[ $gc_count -gt 0 ]] && info+=", ${gc_count} sub"
            info+="${GRAY})${NC}"
            
            printf "  %b%s%s${BLUE}📁 ${NC}${YELLOW}%s${NC}) ${BLUE}%s${NC} %b\n" \
                "$marker" "$prefix" "$branch" "$display_idx" "$comp_name" "$info"
            
            [[ $gc_count -gt 0 ]] && _print_comp_tree "$child_id" "$((depth + 1))" "$next_prefix"
        done
    }
    
    _print_comp_tree "$tenancy_id" 0 "   "
    echo ""
    
    COMP_SELECTOR_COUNT=$display_idx
    return 0
}

#--------------------------------------------------------------------------------
# _select_identity_domain — list identity domains, let user pick one
# Usage: _select_identity_domain "$tenancy_id"
#   Sets: _SELECTED_DOMAIN_URL, _SELECTED_DOMAIN_NAME, _SELECTED_DOMAIN_ID
#   Returns: 0 on selection, 1 on cancel/error
#--------------------------------------------------------------------------------
_SELECTED_DOMAIN_URL=""
_SELECTED_DOMAIN_NAME=""
_SELECTED_DOMAIN_ID=""

_select_identity_domain() {
    local tenancy_id="$1"
    _SELECTED_DOMAIN_URL=""
    _SELECTED_DOMAIN_NAME=""
    _SELECTED_DOMAIN_ID=""
    
    # Fetch domains (with cache)
    local domains_json=""
    if is_cache_fresh "$IDENTITY_DOMAINS_CACHE"; then
        domains_json=$(< "$IDENTITY_DOMAINS_CACHE")
    fi
    if [[ -z "$domains_json" ]]; then
        domains_json=$(_oci_discover "identity domains" \
            oci iam domain list \
            --compartment-id "$tenancy_id" \
            --all --output json)
        [[ -n "$domains_json" ]] && echo "$domains_json" | _cache_write "$IDENTITY_DOMAINS_CACHE"
    fi
    
    if [[ -z "$domains_json" ]] || ! jq -e '.data' <<< "$domains_json" > /dev/null 2>&1; then
        echo -e "${RED}Failed to fetch identity domains. Check permissions (iam domain list).${NC}"
        return 1
    fi
    
    local domain_count
    domain_count=$(_jq_count "$domains_json")
    
    if [[ "$domain_count" -eq 0 ]]; then
        echo -e "${YELLOW}No identity domains found.${NC}"
        return 1
    fi
    
    echo ""
    _ui_subheader "Identity Domains (${domain_count})" 0
    echo ""
    
    local idx=0 default_idx=""
    declare -A _dom_map=()
    
    while IFS=$'\t' read -r d_name d_type d_state d_url d_id d_is_default; do
        [[ -z "$d_id" ]] && continue
        ((idx++))
        _dom_map[$idx]="${d_id}|${d_name}|${d_url}"
        
        local state_color="$GREEN"
        [[ "$d_state" != "ACTIVE" ]] && state_color="$YELLOW"
        
        local default_tag=""
        if [[ "$d_is_default" == "true" ]]; then
            default_tag=" ${CYAN}◄ default${NC}"
            default_idx="$idx"
        fi
        
        printf "  ${YELLOW}%-3s${NC} ${WHITE}%-30s${NC}  ${CYAN}%-12s${NC}  ${state_color}%-10s${NC}  ${GRAY}%s${NC}%b\n" \
            "$idx" "${d_name:0:30}" "${d_type:0:12}" "$d_state" "${d_url:0:50}" "$default_tag"
    done < <(jq -r '(.data // [])[] | [
        (.["display-name"] // "N/A"),
        (.type // "N/A"),
        (.["lifecycle-state"] // "N/A"),
        (.url // "N/A"),
        (.id // "N/A"),
        (((.["is-default"] // false) | tostring))
    ] | @tsv' <<< "$domains_json" 2>/dev/null)
    
    echo ""
    local prompt_hint="#"
    [[ -n "$default_idx" ]] && prompt_hint="#, Enter=${default_idx}"
    _ui_prompt "Domain" "$prompt_hint, b"
    read -r dom_choice
    
    # Default selection
    [[ -z "$dom_choice" && -n "$default_idx" ]] && dom_choice="$default_idx"
    [[ "$dom_choice" == "b" || "$dom_choice" == "B" ]] && return 1
    
    if [[ -n "${_dom_map[$dom_choice]:-}" ]]; then
        IFS='|' read -r _SELECTED_DOMAIN_ID _SELECTED_DOMAIN_NAME _SELECTED_DOMAIN_URL <<< "${_dom_map[$dom_choice]}"
        echo -e "${GREEN}✓ Domain: ${WHITE}${_SELECTED_DOMAIN_NAME}${NC}"
        return 0
    else
        echo -e "${RED}Invalid selection${NC}"
        return 1
    fi
}

#===============================================================================
# ENVIRONMENT FOCUS SYSTEM
#===============================================================================

_focus_init() {
    local custom_compartment="${1:-}"
    local custom_region="${2:-}"
    
    FOCUS_REGION="${custom_region:-$REGION}"
    FOCUS_REGION_SOURCE=$([[ -n "$custom_region" ]] && echo "selected" || echo "config")
    
    FOCUS_COMPARTMENT_ID="${custom_compartment:-$COMPARTMENT_ID}"
    FOCUS_COMPARTMENT_SOURCE=$([[ -n "$custom_compartment" ]] && echo "selected" || echo "config")
    
    if [[ -n "${OKE_CLUSTER_ID:-}" ]]; then
        FOCUS_OKE_CLUSTER_ID="$OKE_CLUSTER_ID"
        FOCUS_OKE_CLUSTER_NAME="${CLUSTER_NAME:-}"
        FOCUS_OKE_SOURCE="config"
    fi
}

_focus_set_compartment() {
    local new_id="$1"
    [[ "$new_id" == "$FOCUS_COMPARTMENT_ID" ]] && return 0
    FOCUS_COMPARTMENT_ID="$new_id"
    FOCUS_COMPARTMENT_SOURCE="selected"
    rm -f "$OKE_CLUSTERS_CACHE" "$OKE_NODEPOOLS_CACHE" "$INSTANCE_CONFIGS_CACHE" "$RM_STACKS_CACHE" "$CUSTOM_IMAGE_CACHE" "$PLATFORM_IMAGE_CACHE" "$IDENTITY_DOMAINS_CACHE" 2>/dev/null
    echo -e "${YELLOW}Compartment changed — caches invalidated${NC}"
}

_focus_set_region() {
    local new_region="$1"
    [[ "$new_region" == "$FOCUS_REGION" ]] && return 0
    FOCUS_REGION="$new_region"
    FOCUS_REGION_SOURCE="selected"
    rm -f "${CACHE_DIR:?}"/*.json "${CACHE_DIR:?}"/*.txt 2>/dev/null
    echo -e "${YELLOW}Region changed — all caches invalidated${NC}"
}

_focus_set_oke_cluster() {
    local new_id="$1"
    local new_name="${2:-}"
    FOCUS_OKE_CLUSTER_ID="$new_id"
    FOCUS_OKE_CLUSTER_NAME="$new_name"
    FOCUS_OKE_SOURCE="selected"
    rm -f "$OKE_NODEPOOLS_CACHE" 2>/dev/null
}

# Environment selection menu
_env_menu() {
    while true; do
        echo ""
        _ui_banner "ENVIRONMENT FOCUS" "$CYAN"
        _ui_env_info
        echo ""
        _ui_actions
        echo -e "  ${YELLOW}r${NC})  Change Region"
        echo -e "  ${YELLOW}c${NC})  Change Compartment"
        echo -e "  ${YELLOW}o${NC})  Change OKE Cluster"
        echo -e "  ${CYAN}b${NC})  Back"
        echo ""
        _ui_prompt "Environment" "r, c, o, b"
        read -r choice
        
        case "$choice" in
            r|R) _env_select_region ;;
            c|C) _env_select_compartment ;;
            o|O) _env_select_oke ;;
            b|B|"") break ;;
            *) echo -e "${RED}Invalid selection${NC}" ;;
        esac
    done
}

_env_select_region() {
    echo ""
    local regions_json
    regions_json=$(_oci_discover "regions" \
        oci iam region-subscription list --tenancy-id "$TENANCY_ID" \
        --output json)
    local region_count
    region_count=$(_jq_count "$regions_json")
    
    echo ""
    _ui_subheader "Subscribed Regions" 0
    local idx=0
    declare -A REGION_MAP
    while IFS='|' read -r rname rstatus; do
        [[ -z "$rname" ]] && continue
        ((idx++))
        REGION_MAP[$idx]="$rname"
        local marker=""
        [[ "$rname" == "$FOCUS_REGION" ]] && marker=" ${GREEN}◄ current${NC}"
        printf "  ${YELLOW}%-3s${NC} %-30s ${GREEN}%-10s${NC}%b\n" "$idx" "$rname" "$rstatus" "$marker"
    done < <(jq -r '.data | sort_by(.["region-name"])[] | "\(.["region-name"])|\(.status)"' <<< "$regions_json" 2>/dev/null)
    
    echo ""
    _ui_prompt "Region" "#, b"
    read -r choice
    if [[ -n "${REGION_MAP[$choice]:-}" ]]; then
        _focus_set_region "${REGION_MAP[$choice]}"
        echo -e "${GREEN}✓ Region set to: ${WHITE}${REGION_MAP[$choice]}${NC}"
    fi
}

_env_select_compartment() {
    echo ""
    echo -n -e "${CYAN}Enter compartment OCID: ${NC}"
    read -r new_comp
    if [[ "$new_comp" == ocid1.compartment.* || "$new_comp" == ocid1.tenancy.* ]]; then
        _focus_set_compartment "$new_comp"
        echo -e "${GREEN}✓ Compartment updated${NC}"
    elif [[ -n "$new_comp" ]]; then
        echo -e "${RED}Invalid OCID format${NC}"
    fi
}

_env_select_oke() {
    echo ""
    local region="${FOCUS_REGION:-$REGION}"
    local clusters_json
    clusters_json=$(_oci_discover "OKE clusters" \
        oci ce cluster list \
        --compartment-id "$FOCUS_COMPARTMENT_ID" \
        --region "$region" \
        --lifecycle-state ACTIVE \
        --all --output json)
    local cluster_count
    cluster_count=$(_jq_count "$clusters_json")
    
    if [[ "$cluster_count" -eq 0 ]]; then
        echo -e "${YELLOW}No active OKE clusters found in compartment${NC}"
        return
    fi
    
    echo ""
    _ui_subheader "OKE Clusters" 0
    local idx=0
    declare -A CLUSTER_MAP
    while IFS='|' read -r cid cname cver; do
        [[ -z "$cid" ]] && continue
        ((idx++))
        CLUSTER_MAP[$idx]="$cid|$cname"
        local marker=""
        [[ "$cid" == "${FOCUS_OKE_CLUSTER_ID:-}" ]] && marker=" ${GREEN}◄ current${NC}"
        printf "  ${YELLOW}%-3s${NC} %-40s ${GRAY}%-10s${NC}%b\n" "$idx" "$cname" "$cver" "$marker"
    done < <(jq -r '.data[] | "\(.id)|\(.name)|\(.["kubernetes-version"])"' <<< "$clusters_json" 2>/dev/null)
    
    echo ""
    _ui_prompt "OKE Cluster" "#, b"
    read -r choice
    if [[ -n "${CLUSTER_MAP[$choice]:-}" ]]; then
        local sel_id sel_name
        IFS='|' read -r sel_id sel_name <<< "${CLUSTER_MAP[$choice]}"
        _focus_set_oke_cluster "$sel_id" "$sel_name"
        echo -e "${GREEN}✓ OKE Cluster set to: ${WHITE}${sel_name}${NC}"
    fi
}

_env_dispatch() {
    local input="$1"
    case "$input" in
        env|ENV) _env_menu ;;
        "env c"|"env C"|"ENV C") _env_select_compartment ;;
        "env r"|"env R"|"ENV R") _env_select_region ;;
        "env oke"|"env OKE"|"ENV OKE") _env_select_oke ;;
        *) _env_menu ;;
    esac
}

#===============================================================================
# MENU 1: POC STACK DEPLOYMENTS
#===============================================================================

_menu_pocs() {
    local direct_choice="${1:-}"
    
    while true; do
        local choice
        if [[ -n "$direct_choice" ]]; then
            choice="$direct_choice"
            direct_choice=""
        else
            _ui_menu_header "POC STACK DEPLOYMENTS" \
                --breadcrumb "POCs" \
                --env \
                --cmd "oci resource-manager stack create | oci resource-manager job create"
            
            echo ""
            _ui_actions
            _ui_action_group "Deploy Stack"
            echo -e "  ${YELLOW}1${NC})  ${WHITE}OKE Stack${NC}             - HPC OKE POC Environment (Resource Manager)"
            echo -e "  ${YELLOW}2${NC})  ${WHITE}Slurm 2.x Stack${NC}       - HPC Slurm 2.x POC Environment"
            echo -e "  ${YELLOW}3${NC})  ${WHITE}Slurm 3.x Stack${NC}       - HPC Slurm 3.x POC Environment"
            echo ""
            _ui_action_group "Setup"
            echo -e "  ${GREEN}s${NC})   ${WHITE}POC Setup Wizard${NC}      - Create compartment, groups, dynamic groups, policies"
            echo ""
            _ui_action_group "Manage"
            echo -e "  ${CYAN}l${NC})   List existing Resource Manager stacks"
            echo -e "  ${CYAN}j${NC})   List recent Resource Manager jobs"
            echo ""
            echo -e "  ${MAGENTA}r${NC})   Refresh cache"
            echo -e "  ${RED}b${NC})   Back to main menu"
            echo ""
            _ui_prompt "POCs" "1-3, s, l, j, r, b"
            read -r choice
        fi
        
        case "$choice" in
            1) _poc_deploy_stack "OKE" "$POC_OKE_STACK_RAW" "$POC_OKE_STACK_URL" ;;
            2) _poc_deploy_stack "Slurm 2.x" "$POC_SLURM_2X_RAW" "$POC_SLURM_2X_URL" ;;
            3) _poc_deploy_stack "Slurm 3.x" "$POC_SLURM_3X_RAW" "$POC_SLURM_3X_URL" ;;
            s|S) _poc_setup_wizard ;;
            l|L) _poc_list_stacks ;;
            j|J) _poc_list_jobs ;;
            r|R) rm -f "$RM_STACKS_CACHE" "$IDENTITY_DOMAINS_CACHE" "$COMPARTMENTS_CACHE" 2>/dev/null; echo -e "${GREEN}✓ Cache refreshed${NC}"; sleep 1 ;;
            b|B|"") break ;;
            env*|ENV*) _env_dispatch "$choice" ;;
            show|SHOW) continue ;;
            *) echo -e "${RED}Invalid selection${NC}" ;;
        esac
    done
}

_poc_deploy_stack() {
    local stack_type="$1"
    local raw_url="$2"
    local github_url="$3"
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION}"
    
    echo ""
    _ui_menu_header "${stack_type} POC DEPLOYMENT" \
        --breadcrumb "POCs" "${stack_type} Stack" \
        --env
    
    echo ""
    _ui_subheader "Stack Source" 0
    _ui_kv "GitHub" "${github_url}"
    _ui_kv "Raw" "${raw_url}" "$GRAY"
    echo ""
    
    _ui_subheader "Deployment Options" 0
    echo -e "  ${YELLOW}1${NC})  Download and run POC script locally"
    echo -e "  ${YELLOW}2${NC})  View script source (curl preview)"
    echo -e "  ${YELLOW}3${NC})  Create Resource Manager stack from OCI Marketplace/GitHub"
    echo -e "  ${RED}b${NC})  Back"
    echo ""
    _ui_prompt "${stack_type}" "1-3, b"
    read -r choice
    
    case "$choice" in
        1)
            echo ""
            local script_name="poc_${stack_type// /_}_$(date +%Y%m%d%H%M%S).sh"
            script_name=$(echo "$script_name" | tr '[:upper:]' '[:lower:]')
            local download_cmd="curl -sL \"${raw_url}\" -o \"${script_name}\""
            
            _ui_subheader "Download Script" 0
            echo -e "  ${CYAN}Target:${NC} ./${script_name}"
            echo ""
            log_action "POC_DOWNLOAD" "$download_cmd" --context "Stack: ${stack_type}"
            
            if curl -sL "${raw_url}" -o "${script_name}" 2>/dev/null; then
                chmod +x "${script_name}"
                echo -e "${GREEN}✓ Downloaded: ${WHITE}${script_name}${NC}"
                log_action_result "SUCCESS" "Downloaded ${script_name}"
                echo ""
                _ui_kv "Run with" "./${script_name}"
                local line_count
                line_count=$(wc -l < "${script_name}")
                echo -e "${GRAY}(${line_count} lines)${NC}"
            else
                echo -e "${RED}✗ Download failed${NC}"
                log_action_result "FAILED" "Download failed for ${raw_url}"
            fi
            _ui_pause
            ;;
        2)
            echo ""
            echo -e "${GRAY}Fetching first 50 lines of script...${NC}"
            echo ""
            curl -sL "${raw_url}" 2>/dev/null | head -50
            echo ""
            echo -e "${GRAY}... (truncated)${NC}"
            _ui_pause
            ;;
        3)
            _poc_create_rm_stack "$stack_type" "$github_url"
            ;;
        b|B|"") return ;;
    esac
}

_poc_create_rm_stack() {
    local stack_type="$1"
    local source_url="$2"
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    
    echo ""
    _ui_subheader "Create Resource Manager Stack" 0
    echo ""
    echo -n -e "${CYAN}Enter stack display name [HPC-${stack_type}-POC]: ${NC}"
    read -r stack_name
    [[ -z "$stack_name" ]] && stack_name="HPC-${stack_type}-POC"
    
    echo -n -e "${CYAN}Enter stack description [POC environment for ${stack_type}]: ${NC}"
    read -r stack_desc
    [[ -z "$stack_desc" ]] && stack_desc="POC environment for ${stack_type}"
    
    echo ""
    _ui_subheader "Stack Configuration" 0
    _ui_kv "Name" "$stack_name"
    _ui_kv "Description" "$stack_desc"
    _ui_kv "Compartment" "$(_short_ocid "$compartment_id")"
    _ui_kv "Source" "$source_url"
    echo ""
    
    echo -e "${GRAY}Note: Resource Manager stacks from GitHub require Terraform configs.${NC}"
    echo -e "${GRAY}For POC scripts, use option 1 (download and run locally) instead.${NC}"
    echo ""
    _ui_pause
}

_poc_list_stacks() {
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    _ui_menu_header "RESOURCE MANAGER STACKS" \
        --breadcrumb "POCs" "RM Stacks" \
        --env \
        --cmd "oci resource-manager stack list --compartment-id \$COMPARTMENT_ID"
    
    local stacks_json
    stacks_json=$(_oci_discover "RM stacks" \
        oci resource-manager stack list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all --output json)
    local stack_count
    stack_count=$(_jq_count "$stacks_json")
    
    echo ""
    if [[ "$stack_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No Resource Manager stacks found in compartment${NC}"
    else
        _ui_table_header "  %-4s %-45s %-15s %-20s %-30s" "#" "Stack Name" "State" "Created" "OCID"
        local idx=0
        while IFS='|' read -r sid sname sstate screated; do
            [[ -z "$sid" ]] && continue
            ((idx++))
            local state_color="$WHITE"
            case "$sstate" in
                ACTIVE) state_color="$GREEN" ;;
                FAILED) state_color="$RED" ;;
                CREATING|UPDATING) state_color="$YELLOW" ;;
            esac
            local created_short="${screated:0:19}"
            printf "  ${YELLOW}%-4s${NC} %-45s ${state_color}%-15s${NC} %-20s ${GRAY}%-30s${NC}\n" \
                "$idx" "$(truncate_string "$sname" 44)" "$sstate" "$created_short" "$(_short_ocid "$sid")"
        done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["lifecycle-state"])|\(.["time-created"])"' <<< "$stacks_json" 2>/dev/null)
    fi
    
    echo ""
    _ui_pause
}

_poc_list_jobs() {
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    local jobs_json
    jobs_json=$(_oci_discover "RM jobs" \
        oci resource-manager job list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --all --output json)
    local job_count
    job_count=$(_jq_count "$jobs_json")
    
    echo ""
    if [[ "$job_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No Resource Manager jobs found${NC}"
    else
        _ui_subheader "Recent Resource Manager Jobs (last 20)" 0
        echo ""
        _ui_table_header "  %-4s %-30s %-15s %-12s %-20s" "#" "Stack Name" "Operation" "State" "Created"
        local idx=0
        while IFS='|' read -r jid jop jstate jcreated jsname; do
            [[ -z "$jid" ]] && continue
            ((idx++))
            [[ $idx -gt 20 ]] && break
            local state_color="$WHITE"
            case "$jstate" in
                SUCCEEDED) state_color="$GREEN" ;;
                FAILED) state_color="$RED" ;;
                IN_PROGRESS|ACCEPTED) state_color="$YELLOW" ;;
                CANCELED) state_color="$GRAY" ;;
            esac
            printf "  ${YELLOW}%-4s${NC} %-30s %-15s ${state_color}%-12s${NC} %-20s\n" \
                "$idx" "$(truncate_string "${jsname:-N/A}" 29)" "$jop" "$jstate" "${jcreated:0:19}"
        done < <(jq -r '.data[] | "\(.id)|\(.operation)|\(.["lifecycle-state"])|\(.["time-created"])|\(.["display-name"] // "")"' <<< "$jobs_json" 2>/dev/null)
    fi
    
    echo ""
    _ui_pause
}

#-------------------------------------------------------------------------------
# POC SETUP WIZARD — compartment, domain, groups, dynamic groups, policies
#-------------------------------------------------------------------------------

# State accumulated across wizard steps (reset at wizard start)
declare -g _WIZ_TENANCY_ID=""
declare -g _WIZ_PARENT_COMP_ID=""
declare -g _WIZ_PARENT_COMP_NAME=""
declare -g _WIZ_POC_COMP_ID=""
declare -g _WIZ_POC_COMP_NAME=""
declare -g _WIZ_DOMAIN_ID=""
declare -g _WIZ_DOMAIN_NAME=""
declare -g _WIZ_DOMAIN_URL=""
declare -g _WIZ_GROUP_NAME=""
declare -g _WIZ_DG_NAME=""
declare -g _WIZ_DG_RULE=""

_poc_setup_wizard() {
    local region="${FOCUS_REGION:-$REGION}"
    
    # Reset wizard state
    _WIZ_TENANCY_ID=""; _WIZ_PARENT_COMP_ID=""; _WIZ_PARENT_COMP_NAME=""
    _WIZ_POC_COMP_ID=""; _WIZ_POC_COMP_NAME=""
    _WIZ_DOMAIN_ID=""; _WIZ_DOMAIN_NAME=""; _WIZ_DOMAIN_URL=""
    _WIZ_GROUP_NAME=""; _WIZ_DG_NAME=""; _WIZ_DG_RULE=""
    
    echo ""
    _ui_menu_header "POC ENVIRONMENT SETUP WIZARD" \
        --breadcrumb "POCs" "Setup Wizard" \
        --env \
        --cmd "oci iam compartment create | oci iam domain list | oci identity-domains groups create | oci identity-domains dynamic-resource-groups create | oci iam policy create"
    
    echo ""
    echo -e "  ${WHITE}This wizard walks through creating a full POC environment:${NC}"
    echo ""
    echo -e "    ${YELLOW}Step 1${NC}  Select parent compartment (default: root tenancy)"
    echo -e "    ${YELLOW}Step 2${NC}  Create POC compartment"
    echo -e "    ${YELLOW}Step 3${NC}  Select identity domain (default: Default domain)"
    echo -e "    ${YELLOW}Step 4${NC}  Create group & dynamic group"
    echo -e "    ${YELLOW}Step 5${NC}  Create IAM policies"
    echo ""
    echo -e "  ${GRAY}You can skip any step by pressing Enter or 'n'.${NC}"
    echo -e "  ${GRAY}Use an existing resource by providing its OCID when prompted.${NC}"
    echo ""
    
    if ! _ui_confirm "y" "start the POC setup wizard" "$CYAN"; then
        echo -e "${YELLOW}Wizard cancelled${NC}"
        _ui_pause
        return
    fi
    
    # Resolve tenancy
    _WIZ_TENANCY_ID="${TENANCY_ID:-}"
    if [[ -z "$_WIZ_TENANCY_ID" ]]; then
        _WIZ_TENANCY_ID=$(get_tenancy_id_from_compartment "$FOCUS_COMPARTMENT_ID")
    fi
    if [[ -z "$_WIZ_TENANCY_ID" ]]; then
        echo -e "${RED}Cannot determine tenancy. Ensure TENANCY_ID is set in variables.sh.${NC}"
        _ui_pause
        return
    fi
    
    #---------------------------------------------------------------------------
    # STEP 1: Select parent compartment
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${WHITE}━━━ Step 1/5: Select Parent Compartment ━━━${NC}"
    echo ""
    echo -e "  ${GRAY}The POC compartment will be created under the selected parent.${NC}"
    echo -e "  ${GRAY}Press Enter to use the root tenancy (default).${NC}"
    echo ""
    
    _poc_wiz_select_parent_compartment || return
    
    #---------------------------------------------------------------------------
    # STEP 2: Create POC compartment
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${WHITE}━━━ Step 2/5: Create POC Compartment ━━━${NC}"
    echo ""
    
    _poc_wiz_create_compartment "$region" || return
    
    #---------------------------------------------------------------------------
    # STEP 3: Select identity domain
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${WHITE}━━━ Step 3/5: Select Identity Domain ━━━${NC}"
    echo ""
    echo -e "  ${GRAY}Groups and dynamic groups will be created in the selected domain.${NC}"
    echo -e "  ${GRAY}Press Enter to use the Default domain.${NC}"
    echo ""
    
    _poc_wiz_select_domain || return
    
    #---------------------------------------------------------------------------
    # STEP 4: Create group & dynamic group
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${WHITE}━━━ Step 4/5: Create Group & Dynamic Group ━━━${NC}"
    echo ""
    
    _poc_wiz_create_groups || return
    
    #---------------------------------------------------------------------------
    # STEP 5: Create IAM policies
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${WHITE}━━━ Step 5/5: Create IAM Policies ━━━${NC}"
    echo ""
    
    _poc_wiz_create_policies "$region"
    
    #---------------------------------------------------------------------------
    # Summary
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${GREEN}━━━ POC Setup Complete ━━━${NC}"
    echo ""
    _ui_kv "Parent Compartment" "${_WIZ_PARENT_COMP_NAME}"
    [[ -n "$_WIZ_POC_COMP_ID" ]]  && _ui_kv "POC Compartment" "${_WIZ_POC_COMP_NAME}" "$GREEN"
    [[ -n "$_WIZ_POC_COMP_ID" ]]  && _ui_kv "  OCID" "${_WIZ_POC_COMP_ID}" "$YELLOW"
    _ui_kv "Identity Domain" "${_WIZ_DOMAIN_NAME}"
    [[ -n "$_WIZ_GROUP_NAME" ]]    && _ui_kv "Group" "${_WIZ_GROUP_NAME}" "$GREEN"
    [[ -n "$_WIZ_DG_NAME" ]]       && _ui_kv "Dynamic Group" "${_WIZ_DG_NAME}" "$GREEN"
    echo ""
    echo -e "  ${GRAY}Tip: Use 'env c' to switch to the new POC compartment.${NC}"
    echo ""
    
    # Offer to set focus to new compartment
    if [[ -n "$_WIZ_POC_COMP_ID" ]]; then
        if _ui_confirm "y" "set focus to the new POC compartment" "$CYAN"; then
            _focus_set_compartment "$_WIZ_POC_COMP_ID" "$_WIZ_POC_COMP_NAME"
            echo -e "${GREEN}✓ Focus set to: ${WHITE}${_WIZ_POC_COMP_NAME}${NC}"
        fi
    fi
    
    _ui_pause
}

#-------------------------------------------------------------------------------
# Wizard Step 1: Select parent compartment from tree
#-------------------------------------------------------------------------------
_poc_wiz_select_parent_compartment() {
    # Default to root tenancy
    _WIZ_PARENT_COMP_ID="$_WIZ_TENANCY_ID"
    _WIZ_PARENT_COMP_NAME=$(resolve_compartment_name "$_WIZ_TENANCY_ID")
    
    echo -e "  ${YELLOW}1${NC})  Use root tenancy: ${WHITE}${_WIZ_PARENT_COMP_NAME}${NC} ${CYAN}◄ default${NC}"
    echo -e "  ${YELLOW}2${NC})  Browse compartment tree and select"
    echo -e "  ${YELLOW}3${NC})  Enter compartment OCID directly"
    echo -e "  ${RED}c${NC})  Cancel wizard"
    echo ""
    _ui_prompt "Parent" "1-3, c"
    read -r parent_choice
    
    case "${parent_choice:-1}" in
        1|"")
            echo -e "${GREEN}✓ Parent: ${WHITE}${_WIZ_PARENT_COMP_NAME}${NC} (root tenancy)"
            ;;
        2)
            display_compartment_selector "$_WIZ_TENANCY_ID" "$FOCUS_COMPARTMENT_ID" || {
                echo -e "${RED}Failed to load compartment tree${NC}"
                _ui_pause
                return 1
            }
            
            echo -e "  ${GRAY}Enter ${YELLOW}0${GRAY} for root tenancy, or select a compartment number.${NC}"
            _ui_prompt "Parent compartment" "#, 0=root"
            read -r comp_sel
            
            if [[ -z "$comp_sel" || "$comp_sel" == "0" ]]; then
                echo -e "${GREEN}✓ Parent: ${WHITE}${_WIZ_PARENT_COMP_NAME}${NC} (root tenancy)"
            elif [[ -n "${COMP_IDX[$comp_sel]:-}" ]]; then
                _WIZ_PARENT_COMP_ID="${COMP_IDX[$comp_sel]}"
                local comp_data="${COMP_MAP[$_WIZ_PARENT_COMP_ID]}"
                _WIZ_PARENT_COMP_NAME="${comp_data%%|*}"
                echo -e "${GREEN}✓ Parent: ${WHITE}${_WIZ_PARENT_COMP_NAME}${NC}"
            else
                echo -e "${RED}Invalid selection — using root tenancy${NC}"
            fi
            ;;
        3)
            echo -n -e "  ${CYAN}Compartment OCID: ${NC}"
            read -r manual_ocid
            if [[ "$manual_ocid" == ocid1.compartment.* ]]; then
                _WIZ_PARENT_COMP_ID="$manual_ocid"
                _WIZ_PARENT_COMP_NAME=$(resolve_compartment_name "$manual_ocid")
                echo -e "${GREEN}✓ Parent: ${WHITE}${_WIZ_PARENT_COMP_NAME}${NC}"
            elif [[ -n "$manual_ocid" ]]; then
                echo -e "${RED}Invalid OCID format — using root tenancy${NC}"
            fi
            ;;
        c|C)
            echo -e "${YELLOW}Wizard cancelled${NC}"
            return 1
            ;;
    esac
    return 0
}

#-------------------------------------------------------------------------------
# Wizard Step 2: Create POC compartment
#-------------------------------------------------------------------------------
_poc_wiz_create_compartment() {
    local region="$1"
    
    echo -e "  ${GRAY}Creating compartment under: ${WHITE}${_WIZ_PARENT_COMP_NAME}${NC}"
    echo ""
    echo -e "  ${YELLOW}1${NC})  Create new POC compartment"
    echo -e "  ${YELLOW}2${NC})  Use existing compartment OCID (skip creation)"
    echo -e "  ${YELLOW}3${NC})  Skip this step"
    echo -e "  ${RED}c${NC})  Cancel wizard"
    echo ""
    _ui_prompt "Compartment" "1-3, c"
    read -r comp_action
    
    case "${comp_action:-1}" in
        1)
            echo ""
            echo -n -e "  ${CYAN}Compartment name [HPC-GPU-POC]: ${NC}"
            read -r comp_name
            [[ -z "$comp_name" ]] && comp_name="HPC-GPU-POC"
            
            echo -n -e "  ${CYAN}Description [POC environment for GPU/HPC testing]: ${NC}"
            read -r comp_desc
            [[ -z "$comp_desc" ]] && comp_desc="POC environment for GPU/HPC testing"
            
            local create_cmd="oci iam compartment create"
            create_cmd+=" --compartment-id \"${_WIZ_PARENT_COMP_ID}\""
            create_cmd+=" --name \"${comp_name}\""
            create_cmd+=" --description \"${comp_desc}\""
            
            echo ""
            _ui_subheader "Confirm Create Compartment" 0
            _ui_kv "Name" "$comp_name"
            _ui_kv "Description" "$comp_desc"
            _ui_kv "Parent" "${_WIZ_PARENT_COMP_NAME}"
            _ui_kv "Parent OCID" "$(_short_ocid "$_WIZ_PARENT_COMP_ID")" "$GRAY"
            _ui_show_command "$create_cmd"
            
            if _ui_confirm "y" "create compartment" "$YELLOW"; then
                log_action "COMPARTMENT_CREATE" "$create_cmd" --context "Parent: ${_WIZ_PARENT_COMP_NAME}, Name: ${comp_name}"
                local result
                result=$(_safe_exec "$create_cmd")
                
                if jq -e '.data.id' <<< "$result" > /dev/null 2>&1; then
                    _WIZ_POC_COMP_ID=$(jq -r '.data.id' <<< "$result")
                    _WIZ_POC_COMP_NAME="$comp_name"
                    echo -e "${GREEN}✓ Compartment created: ${WHITE}${comp_name}${NC}"
                    echo -e "  ${CYAN}Compartment OCID:${NC} ${YELLOW}${_WIZ_POC_COMP_ID}${NC}"
                    log_action_result "SUCCESS" "Compartment created: ${_WIZ_POC_COMP_ID}"
                    # Invalidate cache
                    rm -f "$COMPARTMENTS_CACHE" 2>/dev/null
                else
                    echo -e "${RED}✗ Compartment creation failed${NC}"
                    echo -e "  ${GRAY}${result:0:500}${NC}"
                    log_action_result "FAILED" "Compartment creation failed for ${comp_name}"
                fi
            else
                echo -e "${GRAY}Skipping compartment creation${NC}"
            fi
            ;;
        2)
            echo ""
            echo -n -e "  ${CYAN}Existing compartment OCID: ${NC}"
            read -r existing_ocid
            if [[ "$existing_ocid" == ocid1.compartment.* ]]; then
                _WIZ_POC_COMP_ID="$existing_ocid"
                _WIZ_POC_COMP_NAME=$(resolve_compartment_name "$existing_ocid")
                echo -e "${GREEN}✓ Using existing: ${WHITE}${_WIZ_POC_COMP_NAME}${NC}"
            elif [[ -n "$existing_ocid" ]]; then
                echo -e "${RED}Invalid OCID format${NC}"
            fi
            ;;
        3)
            echo -e "${GRAY}Skipping compartment creation${NC}"
            ;;
        c|C)
            echo -e "${YELLOW}Wizard cancelled${NC}"
            return 1
            ;;
    esac
    return 0
}

#-------------------------------------------------------------------------------
# Wizard Step 3: Select identity domain
#-------------------------------------------------------------------------------
_poc_wiz_select_domain() {
    echo -e "  ${YELLOW}1${NC})  Use Default identity domain ${CYAN}◄ default${NC}"
    echo -e "  ${YELLOW}2${NC})  Browse and select a different domain"
    echo -e "  ${YELLOW}3${NC})  Skip group/policy creation"
    echo -e "  ${RED}c${NC})  Cancel wizard"
    echo ""
    _ui_prompt "Domain" "1-3, c"
    read -r dom_action
    
    case "${dom_action:-1}" in
        1|"")
            # Find the Default domain automatically
            local domains_json=""
            if is_cache_fresh "$IDENTITY_DOMAINS_CACHE"; then
                domains_json=$(< "$IDENTITY_DOMAINS_CACHE")
            fi
            if [[ -z "$domains_json" ]]; then
                domains_json=$(_oci_discover "identity domains" \
                    oci iam domain list \
                    --compartment-id "$_WIZ_TENANCY_ID" \
                    --all --output json)
                [[ -n "$domains_json" ]] && echo "$domains_json" | _cache_write "$IDENTITY_DOMAINS_CACHE"
            fi
            
            if [[ -n "$domains_json" ]]; then
                local default_url default_name default_id
                default_url=$(jq -r '(.data // [])[] | select(.["is-default"] == true) | .url' <<< "$domains_json" 2>/dev/null | head -1)
                default_name=$(jq -r '(.data // [])[] | select(.["is-default"] == true) | .["display-name"]' <<< "$domains_json" 2>/dev/null | head -1)
                default_id=$(jq -r '(.data // [])[] | select(.["is-default"] == true) | .id' <<< "$domains_json" 2>/dev/null | head -1)
                
                if [[ -n "$default_url" ]]; then
                    _WIZ_DOMAIN_URL="$default_url"
                    _WIZ_DOMAIN_NAME="$default_name"
                    _WIZ_DOMAIN_ID="$default_id"
                    echo -e "${GREEN}✓ Domain: ${WHITE}${_WIZ_DOMAIN_NAME}${NC} (default)"
                else
                    echo -e "${YELLOW}No default domain found — falling back to browse${NC}"
                    _select_identity_domain "$_WIZ_TENANCY_ID" || return 0
                    _WIZ_DOMAIN_URL="$_SELECTED_DOMAIN_URL"
                    _WIZ_DOMAIN_NAME="$_SELECTED_DOMAIN_NAME"
                    _WIZ_DOMAIN_ID="$_SELECTED_DOMAIN_ID"
                fi
            else
                echo -e "${RED}Failed to list identity domains${NC}"
                return 0
            fi
            ;;
        2)
            _select_identity_domain "$_WIZ_TENANCY_ID" || return 0
            _WIZ_DOMAIN_URL="$_SELECTED_DOMAIN_URL"
            _WIZ_DOMAIN_NAME="$_SELECTED_DOMAIN_NAME"
            _WIZ_DOMAIN_ID="$_SELECTED_DOMAIN_ID"
            ;;
        3)
            echo -e "${GRAY}Skipping identity domain selection — no groups or policies will be created${NC}"
            return 0
            ;;
        c|C)
            echo -e "${YELLOW}Wizard cancelled${NC}"
            return 1
            ;;
    esac
    return 0
}

#-------------------------------------------------------------------------------
# Wizard Step 4: Create group and dynamic group
#-------------------------------------------------------------------------------
_poc_wiz_create_groups() {
    local domain_url="$_WIZ_DOMAIN_URL"
    local domain_name="$_WIZ_DOMAIN_NAME"
    
    if [[ -z "$domain_url" ]]; then
        echo -e "${GRAY}No identity domain selected — skipping group creation${NC}"
        return 0
    fi
    
    local poc_prefix="${_WIZ_POC_COMP_NAME:-HPC-GPU-POC}"
    # Sanitize: replace spaces with hyphens for default names
    poc_prefix="${poc_prefix// /-}"
    
    #--- Group ---
    echo -e "  ${BOLD}${WHITE}Group:${NC}"
    echo ""
    echo -n -e "  ${CYAN}Group name [${poc_prefix}-Admins]: ${NC}"
    read -r group_name
    [[ -z "$group_name" ]] && group_name="${poc_prefix}-Admins"
    
    echo -n -e "  ${CYAN}Description [Administrators for ${_WIZ_POC_COMP_NAME:-POC} environment]: ${NC}"
    read -r group_desc
    [[ -z "$group_desc" ]] && group_desc="Administrators for ${_WIZ_POC_COMP_NAME:-POC} environment"
    
    local schemas_group='["urn:ietf:params:scim:schemas:core:2.0:Group"]'
    local group_cmd="oci identity-domains groups create"
    group_cmd+=" --endpoint \"${domain_url}\""
    group_cmd+=" --schemas '${schemas_group}'"
    group_cmd+=" --display-name \"${group_name}\""
    [[ -n "$group_desc" ]] && group_cmd+=" --description \"${group_desc}\""
    
    echo ""
    _ui_subheader "Create Group" 0
    _ui_kv "Domain" "$domain_name"
    _ui_kv "Group Name" "$group_name"
    _ui_kv "Description" "$group_desc"
    _ui_show_command "$group_cmd"
    
    if _ui_confirm "y" "create group" "$YELLOW"; then
        log_action "GROUP_CREATE" "$group_cmd" --context "Domain: ${domain_name}, Group: ${group_name}"
        local result
        result=$(oci identity-domains groups create \
            --endpoint "$domain_url" \
            --schemas "$schemas_group" \
            --display-name "$group_name" \
            ${group_desc:+--description "$group_desc"} \
            --output json 2>&1)
        
        if jq -e '.ocid // .id' <<< "$result" > /dev/null 2>&1; then
            local new_ocid
            new_ocid=$(jq -r '.ocid // .id' <<< "$result")
            echo -e "${GREEN}✓ Group created: ${WHITE}${group_name}${NC}"
            echo -e "  ${CYAN}OCID:${NC} ${YELLOW}${new_ocid}${NC}"
            log_action_result "SUCCESS" "Group ${group_name} created: $new_ocid"
            _WIZ_GROUP_NAME="$group_name"
        else
            echo -e "${RED}✗ Group creation failed${NC}"
            echo -e "  ${GRAY}${result:0:500}${NC}"
            log_action_result "FAILED" "Group creation failed for ${group_name}"
        fi
    else
        echo -e "${GRAY}Skipping group creation${NC}"
    fi
    
    #--- Dynamic Group ---
    echo ""
    echo -e "  ${BOLD}${WHITE}Dynamic Group:${NC}"
    echo ""
    echo -n -e "  ${CYAN}Dynamic group name [${poc_prefix}-Instances]: ${NC}"
    read -r dg_name
    [[ -z "$dg_name" ]] && dg_name="${poc_prefix}-Instances"
    
    echo -n -e "  ${CYAN}Description [Instances in ${_WIZ_POC_COMP_NAME:-POC} compartment]: ${NC}"
    read -r dg_desc
    [[ -z "$dg_desc" ]] && dg_desc="Instances in ${_WIZ_POC_COMP_NAME:-POC} compartment"
    
    # Build matching rule — if we have a POC compartment, use it
    local default_rule=""
    if [[ -n "$_WIZ_POC_COMP_ID" ]]; then
        default_rule="Any {instance.compartment.id = '${_WIZ_POC_COMP_ID}'}"
    else
        default_rule="Any {instance.compartment.id = '<COMPARTMENT_OCID>'}"
    fi
    
    echo ""
    echo -e "  ${CYAN}Matching rule examples:${NC}"
    echo -e "    ${GRAY}All instances in compartment:${NC}"
    echo -e "    ${WHITE}Any {instance.compartment.id = 'ocid1.compartment.oc1..xxx'}${NC}"
    echo -e "    ${GRAY}All with tag:${NC}"
    echo -e "    ${WHITE}Any {tag.namespace.key.value = 'myvalue'}${NC}"
    echo -e "    ${GRAY}Multiple resource types:${NC}"
    echo -e "    ${WHITE}Any {resource.type = 'instance', resource.compartment.id = 'ocid1...'}${NC}"
    echo ""
    echo -n -e "  ${CYAN}Matching rule${NC}"
    if [[ -n "$_WIZ_POC_COMP_ID" ]]; then
        echo -e " ${GRAY}[default: match POC compartment]${NC}"
        echo -n -e "  ${CYAN}: ${NC}"
    else
        echo -n -e ": "
    fi
    read -r dg_rule
    [[ -z "$dg_rule" ]] && dg_rule="$default_rule"
    
    local schemas_dg='["urn:ietf:params:scim:schemas:oracle:idcs:DynamicResourceGroup"]'
    local dg_cmd="oci identity-domains dynamic-resource-groups create"
    dg_cmd+=" --endpoint \"${domain_url}\""
    dg_cmd+=" --schemas '${schemas_dg}'"
    dg_cmd+=" --display-name \"${dg_name}\""
    dg_cmd+=" --description \"${dg_desc}\""
    dg_cmd+=" --matching-rule \"${dg_rule}\""
    
    echo ""
    _ui_subheader "Create Dynamic Group" 0
    _ui_kv "Domain" "$domain_name"
    _ui_kv "Dynamic Group" "$dg_name"
    _ui_kv "Description" "$dg_desc"
    _ui_kv "Matching Rule" "$dg_rule"
    _ui_show_command "$dg_cmd"
    
    if _ui_confirm "y" "create dynamic group" "$YELLOW"; then
        log_action "DYNAMIC_GROUP_CREATE" "$dg_cmd" --context "Domain: ${domain_name}, DG: ${dg_name}"
        local result
        result=$(oci identity-domains dynamic-resource-groups create \
            --endpoint "$domain_url" \
            --schemas "$schemas_dg" \
            --display-name "$dg_name" \
            --description "$dg_desc" \
            --matching-rule "$dg_rule" \
            --output json 2>&1)
        
        if jq -e '.ocid // .id' <<< "$result" > /dev/null 2>&1; then
            local new_ocid
            new_ocid=$(jq -r '.ocid // .id' <<< "$result")
            echo -e "${GREEN}✓ Dynamic group created: ${WHITE}${dg_name}${NC}"
            echo -e "  ${CYAN}OCID:${NC} ${YELLOW}${new_ocid}${NC}"
            log_action_result "SUCCESS" "Dynamic group ${dg_name} created: $new_ocid"
            _WIZ_DG_NAME="$dg_name"
            _WIZ_DG_RULE="$dg_rule"
        else
            echo -e "${RED}✗ Dynamic group creation failed${NC}"
            echo -e "  ${GRAY}${result:0:500}${NC}"
            log_action_result "FAILED" "Dynamic group creation failed for ${dg_name}"
        fi
    else
        echo -e "${GRAY}Skipping dynamic group creation${NC}"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# Wizard Step 5: Create IAM policies
# Generates domain-qualified group references:
#   Default domain:     group 'GroupName'
#   Non-default domain: group 'DomainName'/'GroupName'
#-------------------------------------------------------------------------------
_poc_wiz_create_policies() {
    local region="$1"
    local domain_name="$_WIZ_DOMAIN_NAME"
    local group_name="$_WIZ_GROUP_NAME"
    local dg_name="$_WIZ_DG_NAME"
    
    if [[ -z "$group_name" && -z "$dg_name" ]]; then
        echo -e "${GRAY}No groups created — skipping policy creation${NC}"
        return 0
    fi
    
    # Build domain-qualified group references
    # OCI policy syntax:
    #   Default domain:     group 'GroupName'  (or group 'Default'/'GroupName')
    #   Non-default domain: group 'DomainName'/'GroupName'
    local group_ref="" dg_ref=""
    if [[ "$domain_name" == "Default" || -z "$domain_name" ]]; then
        [[ -n "$group_name" ]] && group_ref="group '${group_name}'"
        [[ -n "$dg_name" ]]    && dg_ref="dynamic-group '${dg_name}'"
    else
        [[ -n "$group_name" ]] && group_ref="group '${domain_name}'/'${group_name}'"
        [[ -n "$dg_name" ]]    && dg_ref="dynamic-group '${domain_name}'/'${dg_name}'"
    fi
    
    # Determine target compartment for policies
    local target_comp_id="${_WIZ_POC_COMP_ID:-$FOCUS_COMPARTMENT_ID}"
    local target_comp_name="${_WIZ_POC_COMP_NAME:-$(resolve_compartment_name "$target_comp_id")}"
    
    # Build policy statements
    local -a policy_statements=()
    
    if [[ -n "$group_ref" ]]; then
        policy_statements+=(
            "Allow ${group_ref} to manage all-resources in compartment ${target_comp_name}"
            "Allow ${group_ref} to use cloud-shell in tenancy"
            "Allow ${group_ref} to manage repos in tenancy"
            "Allow ${group_ref} to read objectstorage-namespaces in tenancy"
        )
    fi
    
    if [[ -n "$dg_ref" ]]; then
        policy_statements+=(
            "Allow ${dg_ref} to manage all-resources in compartment ${target_comp_name}"
            "Allow ${dg_ref} to read objectstorage-namespaces in tenancy"
            "Allow ${dg_ref} to use log-content in tenancy"
        )
    fi
    
    if [[ ${#policy_statements[@]} -eq 0 ]]; then
        echo -e "${GRAY}No policy statements to create${NC}"
        return 0
    fi
    
    # Default policy name
    local poc_prefix="${_WIZ_POC_COMP_NAME:-HPC-GPU-POC}"
    poc_prefix="${poc_prefix// /-}"
    
    echo -n -e "  ${CYAN}Policy name [${poc_prefix}-Policy]: ${NC}"
    read -r policy_name
    [[ -z "$policy_name" ]] && policy_name="${poc_prefix}-Policy"
    
    echo -n -e "  ${CYAN}Policy description [IAM policies for ${poc_prefix} POC]: ${NC}"
    read -r policy_desc
    [[ -z "$policy_desc" ]] && policy_desc="IAM policies for ${poc_prefix} POC"
    
    echo ""
    _ui_subheader "Policy Statements Preview" 0
    echo ""
    echo -e "  ${CYAN}Domain:${NC} ${WHITE}${domain_name}${NC}"
    echo -e "  ${CYAN}Policy attached to:${NC} ${WHITE}tenancy (root)${NC}"
    echo ""
    
    local stmt_idx=0
    for stmt in "${policy_statements[@]}"; do
        ((stmt_idx++))
        echo -e "  ${YELLOW}${stmt_idx}${NC}) ${WHITE}${stmt}${NC}"
    done
    
    echo ""
    echo -e "  ${GRAY}Review the statements above. You can edit them after creation in the OCI Console.${NC}"
    echo -e "  ${GRAY}Policies will be created at the tenancy level to allow cross-compartment access.${NC}"
    echo ""
    
    # Build the JSON array of statements
    local stmts_json="["
    local first=true
    for stmt in "${policy_statements[@]}"; do
        $first && first=false || stmts_json+=","
        stmts_json+="\"${stmt}\""
    done
    stmts_json+="]"
    
    local policy_cmd="oci iam policy create"
    policy_cmd+=" --compartment-id \"${_WIZ_TENANCY_ID}\""
    policy_cmd+=" --name \"${policy_name}\""
    policy_cmd+=" --description \"${policy_desc}\""
    policy_cmd+=" --statements '${stmts_json}'"
    
    _ui_show_command "$policy_cmd"
    
    if _ui_confirm "y" "create policy" "$YELLOW"; then
        log_action "POLICY_CREATE" "$policy_cmd" --context "Policy: ${policy_name}, Stmts: ${#policy_statements[@]}"
        local result
        result=$(oci iam policy create \
            --compartment-id "$_WIZ_TENANCY_ID" \
            --name "$policy_name" \
            --description "$policy_desc" \
            --statements "$stmts_json" \
            --output json 2>&1)
        
        if jq -e '.data.id' <<< "$result" > /dev/null 2>&1; then
            local new_id
            new_id=$(jq -r '.data.id' <<< "$result")
            echo -e "${GREEN}✓ Policy created: ${WHITE}${policy_name}${NC}"
            echo -e "  ${CYAN}Policy OCID:${NC} ${YELLOW}${new_id}${NC}"
            echo -e "  ${GREEN}${#policy_statements[@]} statements applied${NC}"
            log_action_result "SUCCESS" "Policy ${policy_name} created: $new_id (${#policy_statements[@]} statements)"
        else
            echo -e "${RED}✗ Policy creation failed${NC}"
            echo -e "  ${GRAY}${result:0:500}${NC}"
            log_action_result "FAILED" "Policy creation failed for ${policy_name}"
        fi
    else
        echo -e "${GRAY}Skipping policy creation${NC}"
    fi
    
    return 0
}

#===============================================================================
# MENU 2: OKE STACK TESTING — NODE CREATION
#===============================================================================

_menu_oke_testing() {
    local direct_choice="${1:-}"
    
    while true; do
        local choice
        if [[ -n "$direct_choice" ]]; then
            choice="$direct_choice"
            direct_choice=""
        else
            _ui_menu_header "OKE STACK TESTING" \
                --breadcrumb "OKE Testing" \
                --env \
                --cmd "oci ce cluster list | oci ce node-pool list/create | oci compute-management instance-configuration launch-compute-instance | oci compute instance launch"
            
            echo ""
            _ui_actions
            _ui_action_group "Node Operations"
            echo -e "  ${YELLOW}1${NC})  ${WHITE}Add Node (Instance Config)${NC}     - Launch node using an existing instance configuration"
            echo -e "  ${YELLOW}2${NC})  ${WHITE}Add Node (Manual)${NC}              - Launch node with manual shape/image selection"
            echo -e "  ${YELLOW}3${NC})  ${WHITE}List OKE Clusters${NC}              - Auto-detect and display OKE clusters"
            echo -e "  ${YELLOW}4${NC})  ${WHITE}List Node Pools${NC}                - Show node pools for selected cluster"
            echo -e "  ${YELLOW}5${NC})  ${WHITE}List Instance Configurations${NC}   - Show available instance configs"
            echo ""
            _ui_action_group "Cluster Management"
            echo -e "  ${YELLOW}8${NC})  ${WHITE}Create Node Pool${NC}               - Create new node pool on OKE cluster"
            echo ""
            _ui_action_group "Validation"
            echo -e "  ${YELLOW}6${NC})  ${WHITE}Node Health Check${NC}              - Validate GPU nodes are healthy"
            echo -e "  ${YELLOW}7${NC})  ${WHITE}NCCL Test Manifests${NC}            - Show available NCCL test templates"
            echo ""
            echo -e "  ${MAGENTA}r${NC})   Refresh cache"
            echo -e "  ${RED}b${NC})   Back to main menu"
            echo ""
            _ui_prompt "OKE Testing" "1-8, r, b"
            read -r choice
        fi
        
        case "$choice" in
            1) _oke_add_node_with_config ;;
            2) _oke_add_node_manual ;;
            3) _oke_list_clusters ;;
            4) _oke_list_nodepools ;;
            5) _oke_list_instance_configs ;;
            6) _oke_node_health_check ;;
            7) _oke_nccl_templates ;;
            8) _oke_create_node_pool ;;
            r|R) rm -f "$OKE_CLUSTERS_CACHE" "$OKE_NODEPOOLS_CACHE" "$INSTANCE_CONFIGS_CACHE" 2>/dev/null; echo -e "${GREEN}✓ Cache refreshed${NC}"; sleep 1 ;;
            b|B|"") break ;;
            env*|ENV*) _env_dispatch "$choice" ;;
            show|SHOW) continue ;;
            *) echo -e "${RED}Invalid selection${NC}" ;;
        esac
    done
}

_oke_list_clusters() {
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    _ui_menu_header "OKE CLUSTERS" \
        --breadcrumb "OKE Testing" "Clusters" \
        --env \
        --cmd "oci ce cluster list --compartment-id \$COMPARTMENT_ID --all"
    
    local clusters_json
    clusters_json=$(_oci_discover "OKE clusters" \
        oci ce cluster list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all --output json)
    local cluster_count
    cluster_count=$(_jq_count "$clusters_json")
    
    echo ""
    if [[ "$cluster_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No OKE clusters found in compartment${NC}"
    else
        _ui_subheader "OKE Clusters (${cluster_count})" 0
        echo ""
        _ui_table_header "  %-4s %-40s %-12s %-12s %-10s %-30s" "#" "Cluster Name" "K8s Version" "State" "CNI" "OCID"
        local idx=0
        declare -gA OKE_CL_MAP=()
        while IFS='|' read -r cid cname cver cstate ccni; do
            [[ -z "$cid" ]] && continue
            ((idx++))
            OKE_CL_MAP[$idx]="$cid|$cname"
            local state_color="$WHITE"
            case "$cstate" in
                ACTIVE) state_color="$GREEN" ;;
                CREATING|UPDATING) state_color="$YELLOW" ;;
                FAILED|DELETING|DELETED) state_color="$RED" ;;
            esac
            local marker=""
            [[ "$cid" == "${FOCUS_OKE_CLUSTER_ID:-}" ]] && marker=" ${GREEN}◄${NC}"
            printf "  ${YELLOW}%-4s${NC} %-40s %-12s ${state_color}%-12s${NC} %-10s ${GRAY}%-30s${NC}%b\n" \
                "$idx" "$(truncate_string "$cname" 39)" "$cver" "$cstate" "${ccni:-N/A}" "$(_short_ocid "$cid")" "$marker"
        done < <(jq -r '.data[] | "\(.id)|\(.name)|\(.["kubernetes-version"])|\(.["lifecycle-state"])|\(.["cluster-pod-network-options"][0].cni_type // "N/A")"' <<< "$clusters_json" 2>/dev/null)
    fi
    
    echo ""
    _ui_actions "Options"
    echo -e "  ${YELLOW}#${NC})  Select cluster as focus"
    echo -e "  ${CYAN}b${NC})  Back"
    echo ""
    _ui_prompt "Clusters" "#, b"
    read -r sel
    
    if [[ -n "${OKE_CL_MAP[$sel]:-}" ]]; then
        local sel_id sel_name
        IFS='|' read -r sel_id sel_name <<< "${OKE_CL_MAP[$sel]}"
        _focus_set_oke_cluster "$sel_id" "$sel_name"
        echo -e "${GREEN}✓ OKE Cluster set to: ${WHITE}${sel_name}${NC}"
        sleep 1
    fi
}

_oke_list_nodepools() {
    local cluster_id="${FOCUS_OKE_CLUSTER_ID:-}"
    
    if [[ -z "$cluster_id" ]]; then
        echo -e "${YELLOW}No OKE cluster selected. Use option 3 to select a cluster first.${NC}"
        _ui_pause
        return
    fi
    
    echo ""
    _ui_menu_header "NODE POOLS" \
        --breadcrumb "OKE Testing" "Node Pools" \
        --env \
        --cmd "oci ce node-pool list --cluster-id \$OKE_CLUSTER_ID --compartment-id \$COMPARTMENT_ID"
    
    local np_json
    np_json=$(_oci_discover "node pools" \
        oci ce node-pool list \
        --cluster-id "$cluster_id" \
        --compartment-id "$FOCUS_COMPARTMENT_ID" \
        --region "${FOCUS_REGION:-$REGION}" \
        --all --output json)
    local np_count
    np_count=$(_jq_count "$np_json")
    
    echo ""
    if [[ "$np_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No node pools found for cluster: ${FOCUS_OKE_CLUSTER_NAME:-$cluster_id}${NC}"
    else
        _ui_subheader "Node Pools for ${FOCUS_OKE_CLUSTER_NAME:-$cluster_id}" 0
        echo ""
        _ui_table_header "  %-4s %-35s %-28s %-8s %-12s" "#" "Node Pool Name" "Shape" "Size" "State"
        local idx=0
        while IFS='|' read -r npid npname npshape npsize npstate; do
            [[ -z "$npid" ]] && continue
            ((idx++))
            local state_color="$WHITE"
            case "$npstate" in
                ACTIVE) state_color="$GREEN" ;;
                CREATING|UPDATING) state_color="$YELLOW" ;;
                *) state_color="$RED" ;;
            esac
            printf "  ${YELLOW}%-4s${NC} %-35s %-28s %-8s ${state_color}%-12s${NC}\n" \
                "$idx" "$(truncate_string "$npname" 34)" "$npshape" "$npsize" "$npstate"
        done < <(jq -r '.data[] | "\(.id)|\(.name)|\(.["node-shape"])|\(.["node-config-details"]["size"] // "N/A")|\(.["lifecycle-state"])"' <<< "$np_json" 2>/dev/null)
    fi
    
    echo ""
    _ui_pause
}

_oke_list_instance_configs() {
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    _ui_menu_header "INSTANCE CONFIGURATIONS" \
        --breadcrumb "OKE Testing" "Instance Configs" \
        --env \
        --cmd "oci compute-management instance-configuration list --compartment-id \$COMPARTMENT_ID"
    
    local ic_json
    ic_json=$(_oci_discover "instance configs" \
        oci compute-management instance-configuration list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all --output json)
    local ic_count
    ic_count=$(_jq_count "$ic_json")
    
    echo ""
    if [[ "$ic_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No instance configurations found in compartment${NC}"
    else
        _ui_subheader "Instance Configurations (${ic_count})" 0
        echo ""
        _ui_table_header "  %-4s %-60s %-20s %-30s" "#" "Configuration Name" "Created" "OCID"
        local idx=0
        declare -gA IC_MAP=()
        while IFS='|' read -r icid icname iccreated; do
            [[ -z "$icid" ]] && continue
            ((idx++))
            IC_MAP[$idx]="$icid|$icname"
            printf "  ${YELLOW}%-4s${NC} %-60s %-20s ${GRAY}%-30s${NC}\n" \
                "$idx" "$(truncate_string "$icname" 59)" "${iccreated:0:19}" "$(_short_ocid "$icid")"
        done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["time-created"])"' <<< "$ic_json" 2>/dev/null)
    fi
    
    echo ""
    _ui_pause
}

_oke_add_node_with_config() {
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    _ui_menu_header "ADD NODE (INSTANCE CONFIGURATION)" \
        --breadcrumb "OKE Testing" "Add Node" "Instance Config" \
        --env
    
    # Select region
    _select_region || return
    region="$_SELECTED_REGION"
    
    # Auto-detect OKE cluster
    _require_oke_cluster "$compartment_id" "$region" || return
    
    # Derive AD from OKE cluster's node pool placement configs
    local oke_default_ad=""
    if [[ -n "${FOCUS_OKE_CLUSTER_ID:-}" ]]; then
        local _np_json
        _np_json=$(_oci_discover "node pools (AD lookup)" \
            oci ce node-pool list \
            --cluster-id "$FOCUS_OKE_CLUSTER_ID" \
            --compartment-id "$compartment_id" --region "$region" \
            --all --output json)
        
        if [[ -n "$_np_json" ]]; then
            # Extract unique ADs from all node pool placement configs
            local -a _np_ads=()
            while read -r _ad; do
                [[ -n "$_ad" && "$_ad" != "null" ]] && _np_ads+=("$_ad")
            done < <(jq -r '
                [.data[]? | .["node-config-details"]?["placement-configs"]?[]?["availability-domain"] // empty]
                | unique[]
            ' <<< "$_np_json" 2>/dev/null)
            
            if [[ ${#_np_ads[@]} -eq 1 ]]; then
                oke_default_ad="${_np_ads[0]}"
                local _ad_short="${oke_default_ad##*:}"
                echo -e "  ${CYAN}OKE cluster AD:${NC} ${WHITE}${_ad_short}${NC}"
            elif [[ ${#_np_ads[@]} -gt 1 ]]; then
                # Multiple ADs — use the first one as default, note the others
                oke_default_ad="${_np_ads[0]}"
                local _ad_list=""
                for _a in "${_np_ads[@]}"; do _ad_list+="${_a##*:} "; done
                echo -e "  ${CYAN}OKE cluster ADs:${NC} ${WHITE}${_ad_list}${NC}${GRAY}(defaulting to first)${NC}"
            fi
        fi
    fi
    
    # List instance configurations
    local ic_json
    ic_json=$(_oci_discover "instance configs" \
        oci compute-management instance-configuration list \
        --compartment-id "$compartment_id" --region "$region" \
        --all --output json)
    
    local ic_count
    ic_count=$(_jq_count "$ic_json")
    if [[ "$ic_count" -eq 0 ]]; then
        echo -e "${RED}No instance configurations found. Use option 2 for manual node creation.${NC}"
        _ui_pause
        return
    fi
    
    # Select instance config
    _select_from_json "$ic_json" \
        '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")"' \
        "Instance Config" "Select Instance Configuration" || return
    local sel_ic_id sel_ic_name
    IFS='|' read -r sel_ic_id sel_ic_name <<< "$_SELECT_RESULT"
    
    # Select AD (default to OKE cluster AD)
    _select_ad "$compartment_id" "$region" --default "$oke_default_ad" || { echo -e "${YELLOW}Cancelled${NC}"; return; }
    local ad_input="$_SELECTED_AD"
    
    # Get display name
    echo ""
    echo -n -e "${CYAN}Enter instance display name [gpu-test-node]: ${NC}"
    read -r display_name
    [[ -z "$display_name" ]] && display_name="gpu-test-node"
    
    # Build launch command — oci compute-management instance-configuration launch-compute-instance
    # --launch-details JSON overrides the instance configuration's launch parameters
    local launch_details="{\"compartmentId\": \"${compartment_id}\", \"availabilityDomain\": \"${ad_input}\", \"displayName\": \"${display_name}\"}"
    
    local launch_cmd="oci compute-management instance-configuration launch-compute-instance"
    launch_cmd+=" --instance-configuration-id \"${sel_ic_id}\""
    launch_cmd+=" --region \"${region}\""
    launch_cmd+=" --launch-details '${launch_details}'"
    
    echo ""
    _ui_subheader "Confirm Launch" 0
    _ui_kv "Region" "$region"
    _ui_kv "Instance Config" "$sel_ic_name"
    _ui_kv "OKE Cluster" "${FOCUS_OKE_CLUSTER_NAME:-$FOCUS_OKE_CLUSTER_ID}"
    _ui_kv "AD" "$ad_input"
    _ui_kv "Display Name" "$display_name"
    _ui_show_command "$launch_cmd"
    
    _exec_action \
        --confirm-word "LAUNCH" --confirm-desc "launch instance" \
        --action-type "INSTANCE_LAUNCH" \
        --context "Config: ${sel_ic_name}, Cluster: ${FOCUS_OKE_CLUSTER_NAME:-N/A}, Region: ${region}" \
        --success-msg "Instance launch initiated" \
        --success-label "Instance OCID" \
        -- "$launch_cmd"
    _ui_pause
}

_oke_add_node_manual() {
    echo ""
    _ui_menu_header "ADD NODE (MANUAL)" \
        --breadcrumb "OKE Testing" "Add Node" "Manual" \
        --env
    
    echo ""
    _ui_subheader "Manual Node Launch Parameters" 0
    echo ""
    
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    # ── Step 1: Select region ──
    _select_region || return
    region="$_SELECTED_REGION"
    
    # ── Step 2: Select shape ──
    echo ""
    _select_gpu_shape || { _ui_pause; return; }
    local shape="$_SELECTED_SHAPE"
    
    # ── Step 2b: Flex shape config (OCPUs + Memory) ──
    local shape_config=""
    if [[ "$shape" == *Flex* ]]; then
        echo ""
        echo -e "  ${CYAN}Flex shape requires OCPU + Memory configuration${NC}"
        echo ""
        local flex_ocpus="" flex_memory=""
        echo -n -e "  ${CYAN}OCPUs [default=1]: ${NC}"
        read -r flex_ocpus
        [[ -z "$flex_ocpus" ]] && flex_ocpus="1"
        echo -n -e "  ${CYAN}Memory in GBs [default=$(( flex_ocpus * 16 ))]: ${NC}"
        read -r flex_memory
        [[ -z "$flex_memory" ]] && flex_memory="$(( flex_ocpus * 16 ))"
        shape_config="{\"ocpus\": ${flex_ocpus}, \"memoryInGBs\": ${flex_memory}}"
        echo -e "  ${GREEN}✓ Shape config: ${WHITE}${flex_ocpus} OCPUs, ${flex_memory} GB${NC}"
    fi
    
    # ── Step 3: Will this join an OKE cluster? ──
    echo ""
    local join_oke=false
    local subnet_id="" nsg_ids="[]"
    local pod_subnet_id="" pod_nsg_ids="[]"
    local oke_cluster_name="" oke_cni="" oke_cluster_id="" oke_k8s_ver="" oke_default_ad=""

    echo -e "${CYAN}Will this instance join an OKE cluster?${NC}"
    echo -e "  ${YELLOW}y${NC})  Yes — select cluster to derive subnet + NSGs ${CYAN}(default)${NC}"
    echo -e "  ${YELLOW}n${NC})  No  — select VCN, subnet + NSGs from compartment"
    echo ""
    _ui_prompt "Join OKE" "Enter=y, y/n"
    read -r _join_choice
    [[ -z "$_join_choice" ]] && _join_choice="y"

    case "$_join_choice" in
        y|Y)
            join_oke=true
            _select_oke_network "$compartment_id" "$region" || { _ui_pause; return; }
            subnet_id="$_SELECTED_SUBNET"
            nsg_ids="$_SELECTED_NSG_IDS"
            pod_subnet_id="$_SELECTED_POD_SUBNET"
            pod_nsg_ids="$_SELECTED_POD_NSG_IDS"
            oke_cluster_id="$_OKE_NET_CLUSTER_ID"
            oke_cluster_name="$_OKE_NET_CLUSTER_NAME"
            oke_cni="$_OKE_NET_CNI"
            oke_k8s_ver="$_OKE_NET_K8S_VER"
            oke_default_ad="$_OKE_NET_DEFAULT_AD"
            ;;
        n|N)
            _select_standalone_network "$compartment_id" "$region" || { _ui_pause; return; }
            subnet_id="$_SELECTED_SUBNET"
            nsg_ids="$_SELECTED_NSG_IDS"
            ;;
        *) echo -e "${RED}Invalid selection${NC}"; _ui_pause; return ;;
    esac

    [[ -z "$subnet_id" ]] && { echo -e "${RED}No subnet selected${NC}"; _ui_pause; return; }
    
    # ── Step 4: Image selection ──
    echo ""
    _select_image "$compartment_id" "$region" || { _ui_pause; return; }
    local image_id="$_SELECTED_IMAGE"
    
    # ── Step 5: Select AD ──
    local ad_args=()
    [[ -n "$oke_default_ad" ]] && ad_args=(--default "$oke_default_ad")
    _select_ad "$compartment_id" "$region" "${ad_args[@]}" || { echo -e "${YELLOW}Cancelled${NC}"; _ui_pause; return; }
    local ad_input="$_SELECTED_AD"
    
    # ── Step 6: Display name ──
    echo ""
    local default_name="gpu-manual-test"
    $join_oke && default_name="${oke_cluster_name%%-*}-manual-node"
    echo -n -e "${CYAN}Enter display name [${default_name}]: ${NC}"
    read -r display_name
    [[ -z "$display_name" ]] && display_name="$default_name"
    
    # ── Step 7: Cloud-init ──
    echo ""
    local cloud_init_file=""
    echo -e "${CYAN}Cloud-Init Configuration:${NC}"
    if $join_oke; then
        echo -e "  ${YELLOW}g${NC})  Generate OKE cloud-init from cluster config ${CYAN}(default)${NC}"
    fi
    echo -e "  ${YELLOW}f${NC})  Browse files in current directory"
    echo -e "  ${YELLOW}p${NC})  Enter file path directly"
    echo -e "  ${YELLOW}s${NC})  Skip (no cloud-init)"
    echo ""
    local ci_default="s"
    $join_oke && ci_default="g"
    _ui_prompt "Cloud-init" "Enter=${ci_default}, g/f/p/s"
    read -r _ci_choice
    [[ -z "$_ci_choice" ]] && _ci_choice="$ci_default"

    case "$_ci_choice" in
        g|G)
            if ! $join_oke; then
                echo -e "${RED}OKE cluster not selected — cannot generate${NC}"
                _ui_pause; return
            fi
            _generate_oke_cloud_init "$oke_cluster_id" "$oke_k8s_ver" "$region"
            if [[ -z "$_GENERATED_CLOUD_INIT" || ! -f "$_GENERATED_CLOUD_INIT" ]]; then
                echo -e "${RED}Failed to generate cloud-init${NC}"
                _ui_pause; return
            fi
            cloud_init_file="$_GENERATED_CLOUD_INIT"
            ;;
        f|F)
            _browse_cloud_init_files
            if [[ -z "$_BROWSED_CLOUD_INIT" ]]; then
                echo -e "${YELLOW}No file selected${NC}"; _ui_pause; return
            fi
            cloud_init_file="$_BROWSED_CLOUD_INIT"
            ;;
        p|P)
            echo -n -e "  ${CYAN}Cloud-init file path: ${NC}"
            read -r cloud_init_file
            if [[ -z "$cloud_init_file" ]]; then
                echo -e "${YELLOW}Cancelled${NC}"; _ui_pause; return
            fi
            if [[ ! -f "$cloud_init_file" ]]; then
                echo -e "${RED}File not found: ${cloud_init_file}${NC}"; _ui_pause; return
            fi
            echo -e "${GREEN}✓ Cloud-init: ${WHITE}${cloud_init_file}${NC}"
            ;;
        s|S)
            echo -e "  ${GRAY}No cloud-init — skipping${NC}"
            ;;
        *) echo -e "${RED}Invalid selection${NC}"; _ui_pause; return ;;
    esac
    
    # ── Build command ──
    local launch_cmd="oci compute instance launch"
    launch_cmd+=" --compartment-id \"${compartment_id}\""
    launch_cmd+=" --region \"${region}\""
    launch_cmd+=" --availability-domain \"${ad_input}\""
    launch_cmd+=" --shape \"${shape}\""
    launch_cmd+=" --image-id \"${image_id}\""
    launch_cmd+=" --subnet-id \"${subnet_id}\""
    launch_cmd+=" --display-name \"${display_name}\""
    launch_cmd+=" --assign-public-ip false"

    # Add shape config for Flex shapes
    if [[ -n "$shape_config" ]]; then
        launch_cmd+=" --shape-config '${shape_config}'"
    fi
    
    # Add NSGs if any selected
    local nsg_count_sel=0
    nsg_count_sel=$(jq 'length' <<< "$nsg_ids" 2>/dev/null)
    [[ -z "$nsg_count_sel" ]] && nsg_count_sel=0
    if [[ "$nsg_count_sel" -gt 0 ]]; then
        launch_cmd+=" --nsg-ids '${nsg_ids}'"
    fi

    # Add cloud-init if specified
    if [[ -n "$cloud_init_file" && -f "$cloud_init_file" ]]; then
        launch_cmd+=" --user-data-file \"${cloud_init_file}\""
    fi

    # ── OKE metadata for VCN-Native pod networking ──
    if $join_oke && [[ "$oke_cni" == "OCI_VCN_IP_NATIVE" ]]; then
        local meta_json="{\"oke-native-pod-networking\": \"true\""
        meta_json+=", \"oke-max-pods\": \"60\""
        if [[ -n "$pod_subnet_id" && "$pod_subnet_id" != "null" ]]; then
            meta_json+=", \"pod-subnet\": \"${pod_subnet_id}\""
        fi
        # pod-nsgids expects comma-separated list (not JSON array)
        local pod_nsg_csv=""
        pod_nsg_csv=$(jq -r 'join(",")' <<< "$pod_nsg_ids" 2>/dev/null)
        if [[ -n "$pod_nsg_csv" && "$pod_nsg_csv" != "null" ]]; then
            meta_json+=", \"pod-nsgids\": \"${pod_nsg_csv}\""
        fi
        meta_json+="}"
        launch_cmd+=" --metadata '${meta_json}'"
    fi

    # ── Agent plugins config ──
    local plugins_json='{"pluginsConfig": ['
    plugins_json+='{"desiredState": "DISABLED", "name": "WebLogic Management Service"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "Vulnerability Scanning"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "Oracle Java Management Service"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "Oracle Autonomous Linux"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "OS Management Service Agent"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "OS Management Hub Agent"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "Management Agent"},'
    plugins_json+='{"desiredState": "ENABLED", "name": "Custom Logs Monitoring"},'
    plugins_json+='{"desiredState": "ENABLED", "name": "Compute RDMA GPU Monitoring"},'
    plugins_json+='{"desiredState": "ENABLED", "name": "Compute Instance Run Command"},'
    plugins_json+='{"desiredState": "ENABLED", "name": "Compute Instance Monitoring"},'
    plugins_json+='{"desiredState": "ENABLED", "name": "Compute HPC RDMA Auto-Configuration"},'
    plugins_json+='{"desiredState": "ENABLED", "name": "Compute HPC RDMA Authentication"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "Cloud Guard Workload Protection"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "Block Volume Management"},'
    plugins_json+='{"desiredState": "DISABLED", "name": "Bastion"}'
    plugins_json+=']}'
    launch_cmd+=" --agent-config '${plugins_json}'"
    
    # ── Confirm ──
    echo ""
    _ui_subheader "Confirm Launch" 0
    if $join_oke; then
        _ui_kv "OKE Cluster" "$oke_cluster_name" "$WHITE"
        local cni_label="Flannel"
        [[ "$oke_cni" == "OCI_VCN_IP_NATIVE" ]] && cni_label="Native VCN CNI"
        _ui_kv "CNI" "$cni_label"
    fi
    _ui_kv "Region" "$region"
    _ui_kv "Shape" "$shape" "$WHITE"
    if [[ -n "$shape_config" ]]; then
        _ui_kv "Shape Config" "$shape_config" "$CYAN"
    fi
    _ui_kv "Image" "$(_short_ocid "$image_id")" "$GRAY"
    if [[ -n "$cloud_init_file" && -f "$cloud_init_file" ]]; then
        _ui_kv "Cloud-Init" "$(basename "$cloud_init_file")" "$GREEN"
    else
        _ui_kv "Cloud-Init" "none" "$GRAY"
    fi

    # Worker network — show display name [short_ocid]
    local _w_sub_label="$(_short_ocid "$subnet_id")"
    if [[ -n "$_SELECTED_SUBNET_NAME" ]]; then
        _w_sub_label="${_SELECTED_SUBNET_NAME} [$(_short_ocid "$subnet_id")]"
    fi
    _ui_kv "Worker Subnet" "$_w_sub_label" "$WHITE"
    if [[ "$nsg_count_sel" -gt 0 ]]; then
        _ui_kv "Worker NSGs" "${nsg_count_sel} attached" "$GREEN"
        local _ni=0
        for _n in $(jq -r '.[]' <<< "$nsg_ids" 2>/dev/null); do
            local _nsg_disp_name
            _nsg_disp_name=$(jq -r --argjson i "$_ni" '.[$i] // empty' <<< "$_SELECTED_NSG_NAMES" 2>/dev/null)
            if [[ -n "$_nsg_disp_name" ]]; then
                echo -e "                ${WHITE}${_nsg_disp_name}${NC} ${GRAY}[$(_short_ocid "$_n")]${NC}"
            else
                echo -e "                ${GRAY}$(_short_ocid "$_n")${NC}"
            fi
            _ni=$(( _ni + 1 ))
        done
    else
        _ui_kv "Worker NSGs" "none" "$GRAY"
    fi

    # Pod network — display depends on CNI type
    if $join_oke && [[ "$oke_cni" == "OCI_VCN_IP_NATIVE" ]]; then
        # VCN-Native: show metadata that will be passed
        echo -e "    ${CYAN}── Pod Networking (via instance metadata) ──${NC}"
        _ui_kv "  Mode" "oke-native-pod-networking=true" "$GREEN"
        _ui_kv "  Max Pods" "60"
        if [[ -n "$pod_subnet_id" && "$pod_subnet_id" != "null" ]]; then
            local _p_sub_label="$(_short_ocid "$pod_subnet_id")"
            if [[ -n "$_SELECTED_POD_SUBNET_NAME" ]]; then
                _p_sub_label="${_SELECTED_POD_SUBNET_NAME} [$(_short_ocid "$pod_subnet_id")]"
            fi
            _ui_kv "  Pod Subnet" "$_p_sub_label" "$WHITE"
        fi
        local pod_nsg_count_sel=0
        pod_nsg_count_sel=$(jq 'length' <<< "$pod_nsg_ids" 2>/dev/null)
        [[ -z "$pod_nsg_count_sel" ]] && pod_nsg_count_sel=0
        if [[ "$pod_nsg_count_sel" -gt 0 ]]; then
            _ui_kv "  Pod NSGs" "${pod_nsg_count_sel} attached" "$GREEN"
            local _pi=0
            for _pn in $(jq -r '.[]' <<< "$pod_nsg_ids" 2>/dev/null); do
                local _pnsg_disp_name
                _pnsg_disp_name=$(jq -r --argjson i "$_pi" '.[$i] // empty' <<< "$_SELECTED_POD_NSG_NAMES" 2>/dev/null)
                if [[ -n "$_pnsg_disp_name" ]]; then
                    echo -e "                  ${WHITE}${_pnsg_disp_name}${NC} ${GRAY}[$(_short_ocid "$_pn")]${NC}"
                else
                    echo -e "                  ${GRAY}$(_short_ocid "$_pn")${NC}"
                fi
                _pi=$(( _pi + 1 ))
            done
        fi
    elif $join_oke && [[ "$oke_cni" != "OCI_VCN_IP_NATIVE" ]]; then
        # Flannel: show pod network if configured
        local pod_nsg_count_sel=0
        pod_nsg_count_sel=$(jq 'length' <<< "$pod_nsg_ids" 2>/dev/null)
        [[ -z "$pod_nsg_count_sel" ]] && pod_nsg_count_sel=0

        if [[ -n "$pod_subnet_id" && "$pod_subnet_id" != "null" ]]; then
            local _p_sub_label="$(_short_ocid "$pod_subnet_id")"
            if [[ -n "$_SELECTED_POD_SUBNET_NAME" ]]; then
                _p_sub_label="${_SELECTED_POD_SUBNET_NAME} [$(_short_ocid "$pod_subnet_id")]"
            fi
            _ui_kv "Pod Subnet" "$_p_sub_label" "$WHITE"
        else
            _ui_kv "Pod Subnet" "not configured" "$YELLOW"
        fi
        if [[ "$pod_nsg_count_sel" -gt 0 ]]; then
            _ui_kv "Pod NSGs" "${pod_nsg_count_sel} attached" "$GREEN"
            local _pi=0
            for _pn in $(jq -r '.[]' <<< "$pod_nsg_ids" 2>/dev/null); do
                local _pnsg_disp_name
                _pnsg_disp_name=$(jq -r --argjson i "$_pi" '.[$i] // empty' <<< "$_SELECTED_POD_NSG_NAMES" 2>/dev/null)
                if [[ -n "$_pnsg_disp_name" ]]; then
                    echo -e "                ${WHITE}${_pnsg_disp_name}${NC} ${GRAY}[$(_short_ocid "$_pn")]${NC}"
                else
                    echo -e "                ${GRAY}$(_short_ocid "$_pn")${NC}"
                fi
                _pi=$(( _pi + 1 ))
            done
        else
            _ui_kv "Pod NSGs" "none" "$GRAY"
        fi
    fi

    # Agent plugins summary
    _ui_kv "Agent Plugins" "16 configured (7 enabled, 9 disabled)" "$CYAN"

    _ui_kv "AD" "$ad_input"
    _ui_kv "Display Name" "$display_name"
    _ui_show_command "$launch_cmd"
    
    _exec_action \
        --confirm-word "LAUNCH" --confirm-desc "launch instance" \
        --action-type "INSTANCE_LAUNCH_MANUAL" \
        --context "Shape: ${shape}, Name: ${display_name}, Region: ${region}${oke_cluster_name:+, Cluster: ${oke_cluster_name}}" \
        --success-msg "Instance launch initiated" \
        --success-label "Instance OCID" \
        -- "$launch_cmd"
    
    _ui_pause
}

_oke_node_health_check() {
    echo ""
    _ui_menu_header "GPU NODE HEALTH CHECK" \
        --breadcrumb "OKE Testing" "Health Check" \
        --env
    
    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}kubectl not installed. Required for node health checks.${NC}"
        _ui_pause
        return
    fi
    
    echo ""
    _step_init
    _step_active "GPU nodes"
    local gpu_nodes
    gpu_nodes=$(kubectl get nodes -l 'nvidia.com/gpu.present=true' -o json 2>/dev/null || echo '{"items":[]}')
    local node_count
    node_count=$(jq '.items | length' <<< "$gpu_nodes" 2>/dev/null || echo "0")
    _step_complete "GPU nodes(${node_count})"
    _step_finish
    
    echo ""
    if [[ "$node_count" -eq 0 ]]; then
        echo -e "  ${GRAY}No GPU nodes found (label: nvidia.com/gpu.present=true)${NC}"
        echo -e "  ${GRAY}Try: kubectl get nodes --show-labels | grep -i gpu${NC}"
    else
        _ui_subheader "GPU Nodes (${node_count})" 0
        echo ""
        _ui_table_header "  %-4s %-40s %-12s %-8s %-20s" "#" "Node Name" "Status" "GPUs" "Instance Type"
        local idx=0
        while IFS='|' read -r nname nready ngpus ntype; do
            [[ -z "$nname" ]] && continue
            ((idx++))
            local status_color="$GREEN"
            [[ "$nready" != "True" ]] && status_color="$RED"
            printf "  ${YELLOW}%-4s${NC} %-40s ${status_color}%-12s${NC} %-8s %-20s\n" \
                "$idx" "$(truncate_string "$nname" 39)" "$nready" "${ngpus:-0}" "${ntype:-N/A}"
        done < <(jq -r '.items[] | 
            (.metadata.name) + "|" +
            ([.status.conditions[] | select(.type == "Ready")] | first | .status // "Unknown") + "|" +
            (.status.capacity["nvidia.com/gpu"] // "0") + "|" +
            (.metadata.labels["node.kubernetes.io/instance-type"] // "N/A")
        ' <<< "$gpu_nodes" 2>/dev/null)
    fi
    echo ""
    _ui_pause
}

_oke_nccl_templates() {
    echo ""
    _ui_subheader "NCCL Test Manifest Templates" 0
    echo ""
    echo -e "  Apply NCCL test manifests from oracle-quickstart/oci-hpc-oke:"
    echo ""
    echo -e "  ${YELLOW}H100:${NC}      kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/nccl-tests/kueue/BM.GPU.H100.8.yaml"
    echo -e "  ${YELLOW}A100:${NC}      kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/nccl-tests/kueue/BM.GPU.A100-v2.8.yaml"
    echo -e "  ${YELLOW}B4.8:${NC}      kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/nccl-tests/kueue/BM.GPU.B4.8.yaml"
    echo -e "  ${YELLOW}H200:${NC}      kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/nccl-tests/kueue/BM.GPU.H200.8.yaml"
    echo -e "  ${YELLOW}B200:${NC}      kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/nccl-tests/kueue/BM.GPU.B200.8.yaml"
    echo -e "  ${YELLOW}GB200:${NC}     kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/nccl-tests/kueue/BM.GPU.GB200.4.yaml"
    echo -e "  ${YELLOW}GB300:${NC}     kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/nccl-tests/kueue/BM.GPU.GB300.4.yaml"
    echo ""
    echo -e "  ${GRAY}RCCL Tests (AMD):${NC}"
    echo -e "  ${YELLOW}MI300X:${NC}    kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/rccl-tests/kueue/BM.GPU.MI300X.8.yaml"
    echo -e "  ${YELLOW}MI355X:${NC}    kubectl apply -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/main/manifests/rccl-tests/kueue/BM.GPU.MI355X-v1.8.yaml"
    echo ""
    _ui_pause
}

_oke_create_node_pool() {
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    _ui_menu_header "CREATE NODE POOL" \
        --breadcrumb "OKE Testing" "Create Node Pool" \
        --env \
        --cmd "oci ce node-pool create --cluster-id \$CLUSTER_ID --compartment-id \$COMPARTMENT_ID --name \$NAME --node-shape \$SHAPE --node-config-details \$JSON"
    
    # ── Step 1: Region ──
    _select_region || return
    region="$_SELECTED_REGION"
    
    # ── Step 2: OKE Cluster ──
    _require_oke_cluster "$compartment_id" "$region" || return
    local cluster_id="${FOCUS_OKE_CLUSTER_ID}"
    local cluster_name="${FOCUS_OKE_CLUSTER_NAME:-$cluster_id}"
    
    # ── Step 3: Fetch cluster details (k8s version + VCN) ──
    echo ""
    echo -e "  ${CYAN}Fetching cluster details...${NC}"
    local cluster_detail
    cluster_detail=$(oci ce cluster get --cluster-id "$cluster_id" --region "$region" --output json 2>/dev/null)
    
    if [[ -z "$cluster_detail" ]]; then
        echo -e "${RED}Failed to fetch cluster details${NC}"
        _ui_pause
        return
    fi
    
    local k8s_version vcn_id cluster_cni
    k8s_version=$(jq -r '.data["kubernetes-version"] // ""' <<< "$cluster_detail" 2>/dev/null)
    vcn_id=$(jq -r '.data["vcn-id"] // ""' <<< "$cluster_detail" 2>/dev/null)
    cluster_cni=$(jq -r '.data["cluster-pod-network-options"][0]["cni-type"] // "FLANNEL_OVERLAY"' <<< "$cluster_detail" 2>/dev/null)
    
    echo -e "  ${CYAN}K8s Version:${NC}  ${WHITE}${k8s_version}${NC}"
    echo -e "  ${CYAN}VCN:${NC}          ${GRAY}${vcn_id}${NC}"
    echo -e "  ${CYAN}CNI:${NC}          ${WHITE}${cluster_cni}${NC}"
    
    # ── Step 4: Derive OKE default AD from existing node pools ──
    local oke_default_ad="" oke_default_subnet=""
    local _np_json
    _np_json=$(_oci_discover "node pools (defaults)" \
        oci ce node-pool list \
        --cluster-id "$cluster_id" \
        --compartment-id "$compartment_id" --region "$region" \
        --all --output json)
    
    if [[ -n "$_np_json" ]]; then
        # Extract unique ADs and subnets from placement configs
        local -a _np_ads=()
        while read -r _ad; do
            [[ -n "$_ad" && "$_ad" != "null" ]] && _np_ads+=("$_ad")
        done < <(jq -r '[.data[]? | .["node-config-details"]?["placement-configs"]?[]?["availability-domain"] // empty] | unique[]' <<< "$_np_json" 2>/dev/null)
        
        if [[ ${#_np_ads[@]} -ge 1 ]]; then
            oke_default_ad="${_np_ads[0]}"
        fi
        
        # Get first subnet from existing pools as default
        oke_default_subnet=$(jq -r '[.data[]? | .["node-config-details"]?["placement-configs"]?[]?["subnet-id"] // empty] | unique | first // empty' <<< "$_np_json" 2>/dev/null)
    fi
    
    # ── Step 5: Node pool name ──
    echo ""
    local cluster_prefix="${cluster_name%%-*}"
    [[ ${#cluster_prefix} -gt 20 ]] && cluster_prefix="${cluster_prefix:0:20}"
    local default_np_name="${cluster_prefix}-gpu-pool"
    echo -n -e "${CYAN}Node pool name [${default_np_name}]: ${NC}"
    read -r np_name
    [[ -z "$np_name" ]] && np_name="$default_np_name"
    
    # ── Step 6: GPU shape ──
    _select_gpu_shape || return
    local shape="$_SELECTED_SHAPE"

    # ── Step 6b: Flex shape config (OCPUs + Memory) ──
    local flex_ocpus="" flex_memory=""
    if [[ "$shape" == *Flex* ]]; then
        echo ""
        echo -e "  ${CYAN}Flex shape requires OCPU + Memory configuration${NC}"
        echo ""
        echo -n -e "  ${CYAN}OCPUs [default=1]: ${NC}"
        read -r flex_ocpus
        [[ -z "$flex_ocpus" ]] && flex_ocpus="1"
        echo -n -e "  ${CYAN}Memory in GBs [default=$(( flex_ocpus * 16 ))]: ${NC}"
        read -r flex_memory
        [[ -z "$flex_memory" ]] && flex_memory="$(( flex_ocpus * 16 ))"
        echo -e "  ${GREEN}✓ Shape config: ${WHITE}${flex_ocpus} OCPUs, ${flex_memory} GB${NC}"
    fi
    
    # ── Step 7: Image ──
    _select_image "$compartment_id" "$region" --node-pools "$_np_json" || { echo -e "${YELLOW}Cancelled${NC}"; return; }
    local image_id="$_SELECTED_IMAGE"
    
    # ── Step 8: Availability Domain ──
    _select_ad "$compartment_id" "$region" --default "$oke_default_ad" || { echo -e "${YELLOW}Cancelled${NC}"; return; }
    local ad_input="$_SELECTED_AD"
    
    # ── Step 9: Subnet ──
    echo ""
    echo -e "${CYAN}Worker Node Subnet:${NC}"
    echo -e "  ${YELLOW}1${NC}) Discover from cluster VCN"
    echo -e "  ${YELLOW}2${NC}) Enter subnet OCID directly"
    if [[ -n "$oke_default_subnet" && "$oke_default_subnet" != "null" ]]; then
        echo -e "  ${YELLOW}3${NC}) Use existing node pool subnet ${GRAY}($(_short_ocid "$oke_default_subnet"))${NC}"
    fi
    echo ""
    _ui_prompt "Subnet source" "1-3"
    read -r subnet_choice
    
    local subnet_id=""
    case "$subnet_choice" in
        1)
            if [[ -z "$vcn_id" || "$vcn_id" == "null" ]]; then
                echo -e "${YELLOW}VCN not found on cluster. Enter subnet OCID:${NC}"
                echo -n -e "${CYAN}Subnet OCID: ${NC}"
                read -r subnet_id
                [[ -z "$subnet_id" ]] && { echo -e "${YELLOW}Cancelled${NC}"; return; }
            else
                local subnet_json
                subnet_json=$(_oci_discover "subnets" \
                    oci network subnet list \
                    --vcn-id "$vcn_id" \
                    --compartment-id "$compartment_id" --region "$region" \
                    --all --output json)
                local sub_count
                sub_count=$(_jq_count "$subnet_json")
                
                if [[ "$sub_count" -eq 0 ]]; then
                    echo -e "${YELLOW}No subnets found in VCN. Enter subnet OCID:${NC}"
                    echo -n -e "${CYAN}Subnet OCID: ${NC}"
                    read -r subnet_id
                    [[ -z "$subnet_id" ]] && { echo -e "${YELLOW}Cancelled${NC}"; return; }
                else
                    echo ""
                    _ui_subheader "VCN Subnets" 0
                    echo ""
                    _ui_table_header "  %-4s %-35s %-20s %-10s %-30s" "#" "Subnet Name" "CIDR" "Access" "OCID"
                    local sidx=0 default_sub_idx=""
                    declare -A _sub_map=()
                    while IFS='|' read -r sid sname scidr saccess; do
                        [[ -z "$sid" ]] && continue
                        ((sidx++))
                        _sub_map[$sidx]="$sid"
                        local marker=""
                        if [[ "$sid" == "$oke_default_subnet" ]]; then
                            marker=" ${CYAN}◄ node pool${NC}"
                            default_sub_idx="$sidx"
                        fi
                        local access_color="$GREEN"
                        [[ "$saccess" == "Private" ]] && access_color="$MAGENTA"
                        printf "  ${YELLOW}%-4s${NC} %-35s %-20s ${access_color}%-10s${NC} ${GRAY}%-30s${NC}%b\n" \
                            "$sidx" "$(truncate_string "$sname" 34)" "$scidr" "$saccess" "$(_short_ocid "$sid")" "$marker"
                    done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["cidr-block"] // "N/A")|\(if .["prohibit-public-ip-on-vnic"] then "Private" else "Public" end)"' <<< "$subnet_json" 2>/dev/null)
                    
                    echo ""
                    local sub_hint="#"
                    [[ -n "$default_sub_idx" ]] && sub_hint="#, Enter=${default_sub_idx}"
                    _ui_prompt "Subnet" "$sub_hint, b"
                    read -r sub_sel
                    
                    [[ -z "$sub_sel" && -n "$default_sub_idx" ]] && sub_sel="$default_sub_idx"
                    [[ "$sub_sel" == "b" || "$sub_sel" == "B" ]] && return
                    
                    if [[ -n "${_sub_map[$sub_sel]:-}" ]]; then
                        subnet_id="${_sub_map[$sub_sel]}"
                        echo -e "${GREEN}✓ Subnet selected${NC}"
                    else
                        echo -e "${RED}Invalid selection${NC}"; return
                    fi
                fi
            fi
            ;;
        2)
            echo -n -e "${CYAN}Enter subnet OCID: ${NC}"
            read -r subnet_id
            [[ -z "$subnet_id" ]] && { echo -e "${YELLOW}Cancelled${NC}"; return; }
            ;;
        3)
            if [[ -n "$oke_default_subnet" && "$oke_default_subnet" != "null" ]]; then
                subnet_id="$oke_default_subnet"
                echo -e "${GREEN}✓ Using existing node pool subnet${NC}"
            else
                echo -e "${RED}No existing subnet available${NC}"; return
            fi
            ;;
        *) echo -e "${RED}Invalid selection${NC}"; _ui_pause; return ;;
    esac
    
    # ── Step 10: Pool Size ──
    echo ""
    echo -n -e "${CYAN}Node pool size (number of nodes) [0]: ${NC}"
    read -r pool_size
    [[ -z "$pool_size" ]] && pool_size="0"
    # Validate numeric
    if ! [[ "$pool_size" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid number${NC}"; _ui_pause; return
    fi
    
    # ── Step 11: Boot Volume Size ──
    echo -n -e "${CYAN}Boot volume size in GB [250]: ${NC}"
    read -r boot_vol_gb
    [[ -z "$boot_vol_gb" ]] && boot_vol_gb="250"
    if ! [[ "$boot_vol_gb" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid number${NC}"; _ui_pause; return
    fi
    
    # ── Step 12: Optional SSH key ──
    echo ""
    echo -e "${CYAN}SSH Public Key (optional):${NC}"
    echo -e "  ${YELLOW}1${NC}) None (skip)"
    echo -e "  ${YELLOW}2${NC}) Enter/paste SSH public key"
    echo -e "  ${YELLOW}3${NC}) Read from file path"
    echo ""
    _ui_prompt "SSH Key" "1-3"
    read -r ssh_choice
    
    local ssh_key=""
    case "$ssh_choice" in
        2)
            echo -n -e "${CYAN}SSH public key: ${NC}"
            read -r ssh_key
            ;;
        3)
            echo -n -e "${CYAN}Path to SSH public key file: ${NC}"
            read -r ssh_path
            if [[ -f "$ssh_path" ]]; then
                ssh_key=$(cat "$ssh_path" 2>/dev/null)
                echo -e "${GREEN}✓ Loaded SSH key from ${ssh_path}${NC}"
            else
                echo -e "${RED}File not found: ${ssh_path}${NC}"
                ssh_key=""
            fi
            ;;
        *) ssh_key="" ;;
    esac
    
    # ── Step 13: Build placement-configs JSON ──
    local placement_json="[{\"availabilityDomain\": \"${ad_input}\", \"subnetId\": \"${subnet_id}\"}]"
    
    # ── Step 14: Build command ──
    local create_cmd="oci ce node-pool create"
    create_cmd+=" --cluster-id \"${cluster_id}\""
    create_cmd+=" --compartment-id \"${compartment_id}\""
    create_cmd+=" --region \"${region}\""
    create_cmd+=" --name \"${np_name}\""
    create_cmd+=" --node-shape \"${shape}\""
    create_cmd+=" --kubernetes-version \"${k8s_version}\""
    create_cmd+=" --node-image-id \"${image_id}\""
    create_cmd+=" --node-boot-volume-size-in-gbs ${boot_vol_gb}"
    create_cmd+=" --size ${pool_size}"
    create_cmd+=" --placement-configs '${placement_json}'"

    # Add pod network config if native CNI
    if [[ "$cluster_cni" == "OCI_VCN_IP_NATIVE" ]]; then
        create_cmd+=" --node-pool-pod-network-option-details '{\"cniType\": \"OCI_VCN_IP_NATIVE\"}'"
    fi

    # Add flex shape config
    if [[ "$shape" == *Flex* ]]; then
        create_cmd+=" --node-shape-config '{\"ocpus\": ${flex_ocpus:-1}, \"memoryInGBs\": ${flex_memory:-16}}'"
    fi

    [[ -n "$ssh_key" ]] && create_cmd+=" --ssh-public-key \"${ssh_key}\""
    
    # ── Confirm ──
    echo ""
    _ui_subheader "Confirm Node Pool Creation" 0
    _ui_kv "Cluster" "$cluster_name" "$WHITE"
    _ui_kv "Region" "$region"
    _ui_kv "Node Pool Name" "$np_name" "$WHITE"
    _ui_kv "Shape" "$shape" "$WHITE"
    if [[ -n "$flex_ocpus" ]]; then
        _ui_kv "Shape Config" "${flex_ocpus} OCPUs, ${flex_memory} GB" "$CYAN"
    fi
    _ui_kv "K8s Version" "$k8s_version"
    _ui_kv "Image" "$(_short_ocid "$image_id")" "$GRAY"
    _ui_kv "AD" "${ad_input##*:}"
    _ui_kv "Subnet" "$(_short_ocid "$subnet_id")" "$GRAY"
    _ui_kv "Pool Size" "$pool_size"
    _ui_kv "Boot Volume" "${boot_vol_gb} GB"
    _ui_kv "CNI" "$cluster_cni"
    [[ -n "$ssh_key" ]] && _ui_kv "SSH Key" "Provided" "$GREEN"
    _ui_show_command "$create_cmd"
    
    _exec_action \
        --confirm-word "CREATE" --confirm-desc "create node pool" \
        --action-type "NODEPOOL_CREATE" \
        --context "Pool: ${np_name}, Shape: ${shape}, Cluster: ${cluster_name}, Size: ${pool_size}" \
        --success-msg "Node pool creation initiated" \
        --success-label "Work Request / Node Pool" \
        -- "$create_cmd"
    _ui_pause
}

#===============================================================================
# MENU 3: CUSTOM IMAGES (reused from k8s script)
#===============================================================================

_menu_images() {
    local compartment_id="${FOCUS_COMPARTMENT_ID}"
    local region="${FOCUS_REGION:-$REGION}"
    
    while true; do
        _ui_menu_header "CUSTOM IMAGES MANAGEMENT" \
            --breadcrumb "Images" \
            --env \
            --cmd "oci compute image list --compartment-id \$COMPARTMENT_ID --sort-by TIMECREATED --all"
        
        _step_init
        _step_active "custom images"
        
        local custom_images_json _ci_cached=""
        if is_cache_fresh "$CUSTOM_IMAGE_CACHE"; then
            custom_images_json=$(cat "$CUSTOM_IMAGE_CACHE")
            _ci_cached=" cached"
        else
            local images_json
            images_json=$(_oci_call "image list" oci compute image list \
                --compartment-id "$compartment_id" \
                --region "$region" \
                --sort-by TIMECREATED --sort-order DESC \
                --all --output json)
            
            if [[ -n "$images_json" ]] && jq -e '.data' <<< "$images_json" > /dev/null 2>&1; then
                custom_images_json=$(jq --arg comp_id "$compartment_id" \
                    '{data: [.data[] | select(.["compartment-id"] == $comp_id)]}' <<< "$images_json")
            else
                custom_images_json='{"data":[]}'
            fi
            
            [[ -n "$custom_images_json" ]] && echo "$custom_images_json" | _cache_write "$CUSTOM_IMAGE_CACHE"
        fi
        
        local image_count=0
        if jq -e '.data' <<< "$custom_images_json" > /dev/null 2>&1; then
            image_count=$(_jq_count "$custom_images_json")
        fi
        [[ -z "$image_count" || "$image_count" == "null" ]] && image_count=0
        _step_complete "custom images(${image_count}${_ci_cached})"
        _step_finish
        
        echo ""
        declare -A IMAGE_MAP=()
        local idx=0
        
        if [[ "$image_count" -gt 0 ]]; then
            _ui_subheader "Custom Images (${image_count})" 0
            echo ""
            _ui_table_header "  %-3s %-18s %-14s %-10s %-12s  %s" "#" "OS" "Status" "Size GB" "Created" "Image Name"
            
            while IFS='|' read -r img_id img_name img_os img_billable_gb img_created img_state; do
                [[ -z "$img_id" ]] && continue
                ((idx++))
                IMAGE_MAP[$idx]="$img_id"
                
                local size_gb="N/A"
                [[ -n "$img_billable_gb" && "$img_billable_gb" != "null" && "$img_billable_gb" != "0" ]] && size_gb="${img_billable_gb}"
                
                local created_display="${img_created:0:10}"
                
                local state_color="${WHITE}"
                case "$img_state" in
                    AVAILABLE) state_color="${GREEN}" ;;
                    IMPORTING|PROVISIONING|EXPORTING) state_color="${YELLOW}" ;;
                    DISABLED|DELETED) state_color="${RED}" ;;
                esac
                
                printf "  ${YELLOW}%-3s${NC} %-18s ${state_color}%-14s${NC} %-10s %-12s  %s\n" \
                    "$idx" "$img_os" "$img_state" "$size_gb" "$created_display" "$img_name"
            done < <(jq -r '.data[] | "\(.id)|\(.["display-name"] // "Unnamed")|\(.["operating-system"] // "N/A")|\(.["billable-size-in-gbs"] // "null")|\(.["time-created"] // "N/A")|\(.["lifecycle-state"] // "UNKNOWN")"' <<< "$custom_images_json" 2>/dev/null)
            echo ""
        else
            _ui_subheader "Custom Images (0)" 0
            echo -e "  ${GRAY}No custom images found in this compartment${NC}"
            echo ""
        fi
        
        _ui_actions
        [[ "$idx" -gt 0 ]] && echo -e "  ${YELLOW}1-${idx}${NC})  View image details"
        echo -e "  ${GREEN}i${NC})    Import image from URL"
        echo -e "  ${GREEN}c${NC})    Create image from instance"
        echo -e "  ${MAGENTA}r${NC})    Refresh list"
        echo -e "  ${CYAN}b${NC})    Back to main menu"
        echo ""
        _ui_prompt "Custom Images" "#, i, c, r, b"
        read -r choice
        
        case "$choice" in
            [0-9]*)
                if [[ -n "${IMAGE_MAP[$choice]:-}" ]]; then
                    _image_view_details "${IMAGE_MAP[$choice]}"
                else
                    echo -e "${RED}Invalid selection${NC}"; sleep 1
                fi
                ;;
            i|I) _image_import "$compartment_id"; rm -f "$CUSTOM_IMAGE_CACHE" ;;
            c|C) _image_create_from_instance "$compartment_id"; rm -f "$CUSTOM_IMAGE_CACHE" ;;
            r|R) rm -f "$CUSTOM_IMAGE_CACHE" ;;
            b|B|"") break ;;
            env*|ENV*) _env_dispatch "$choice" ;;
            show|SHOW) continue ;;
            *) echo -e "${RED}Invalid selection${NC}"; sleep 1 ;;
        esac
    done
}

_image_view_details() {
    local image_id="$1"
    
    echo ""
    _step_init
    _step_active "image details"
    local img_json
    img_json=$(_oci_call "image get" oci compute image get --image-id "$image_id" \
        --region "${FOCUS_REGION:-$REGION}" --output json)
    _step_complete "image details"
    _step_finish
    
    if [[ -z "$img_json" ]] || ! jq -e '.data' <<< "$img_json" > /dev/null 2>&1; then
        echo -e "${RED}Failed to fetch image details${NC}"
        _ui_pause
        return
    fi
    
    local name os os_ver billable_gb state time_created
    IFS=$'\t' read -r name os os_ver billable_gb state time_created < <(jq -r '.data | [
        .["display-name"] // "N/A", .["operating-system"] // "N/A",
        .["operating-system-version"] // "N/A", .["billable-size-in-gbs"] // 0,
        .["lifecycle-state"] // "N/A", .["time-created"] // "N/A"
    ] | @tsv' <<< "$img_json")
    
    echo ""
    _ui_detail_banner "Image" "$name"
    echo ""
    _ui_kv "Name" "$name"
    _ui_kv "State" "$state" "$GREEN"
    _ui_kv "OS" "$os $os_ver"
    _ui_kv "Billable Size" "${billable_gb} GB"
    _ui_kv "Created" "${time_created:0:19}"
    _ui_kv "Image OCID" "$image_id" "$YELLOW"
    echo ""
    _ui_pause
}

_image_import() {
    local compartment_id="$1"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    _ui_subheader "Import Image from URL" 0
    echo ""
    echo -e "${GRAY}Provide a publicly accessible URL or a PAR URL pointing to a QCOW2, VMDK, or OCI image.${NC}"
    echo ""
    
    echo -n -e "${CYAN}Enter image URL: ${NC}"
    read -r image_url
    [[ -z "$image_url" ]] && { echo -e "${YELLOW}Import cancelled${NC}"; _ui_pause; return; }
    
    if [[ ! "$image_url" =~ ^https?:// ]]; then
        echo -e "${RED}Invalid URL — must start with http:// or https://${NC}"
        _ui_pause
        return
    fi
    
    # Extract default name
    local default_name=""
    local url_no_params="${image_url%%\?*}"
    if [[ "$url_no_params" =~ /o/(.+)$ ]]; then
        default_name="${BASH_REMATCH[1]}"
    else
        default_name=$(basename "$url_no_params")
        default_name="${default_name%.*}"
    fi
    [[ -z "$default_name" || "$default_name" == "/" ]] && default_name="imported-image"
    
    echo -n -e "${CYAN}Enter display name [${default_name}]: ${NC}"
    read -r image_name
    [[ -z "$image_name" ]] && image_name="$default_name"
    
    # Auto-detect OS from name
    local auto_os=""
    if [[ "$image_name" =~ ^([A-Za-z]([A-Za-z0-9]*-)*[A-Za-z0-9]*)-[0-9]+\.[0-9]+ ]]; then
        auto_os="${BASH_REMATCH[1]//-/ }"
    fi
    
    echo ""
    if [[ -n "$auto_os" ]]; then
        echo -e "${GRAY}Auto-detected OS: ${WHITE}${auto_os}${NC}"
        echo -n -e "${CYAN}Enter operating system name [${auto_os}]: ${NC}"
    else
        echo -n -e "${CYAN}Enter operating system name: ${NC}"
    fi
    read -r os_name
    [[ -z "$os_name" && -n "$auto_os" ]] && os_name="$auto_os"
    [[ -z "$os_name" ]] && { echo -e "${RED}OS name required${NC}"; _ui_pause; return; }
    
    # Source type
    echo ""
    _ui_subheader "Source Image Type" 0
    echo -e "  ${YELLOW}1${NC}) QCOW2"
    echo -e "  ${YELLOW}2${NC}) VMDK"
    echo -e "  ${YELLOW}3${NC}) None — OCI native format"
    echo -n -e "${CYAN}Select [3]: ${NC}"
    read -r type_choice
    local source_type=""
    case "$type_choice" in
        1) source_type="QCOW2" ;;
        2) source_type="VMDK" ;;
        *) source_type="" ;;
    esac
    
    local cmd="oci compute image import from-object-uri"
    cmd+=" --uri \"$image_url\""
    cmd+=" --compartment-id \"$compartment_id\""
    cmd+=" --region \"$region\""
    cmd+=" --operating-system \"$os_name\""
    cmd+=" --display-name \"$image_name\""
    [[ -n "$source_type" ]] && cmd+=" --source-image-type \"$source_type\""
    
    echo ""
    _ui_subheader "Confirm Import" 0
    _ui_kv "URL" "$image_url"
    _ui_kv "Display Name" "$image_name"
    _ui_kv "OS" "$os_name"
    _ui_kv "Source Type" "${source_type:-None (OCI native)}"
    _ui_show_command "$cmd"
    
    if ! _ui_confirm "y" "proceed with import" "$YELLOW"; then
        echo -e "${YELLOW}Import cancelled${NC}"
        _ui_pause
        return
    fi
    
    log_action "IMAGE_IMPORT" "$cmd" --context "Image: ${image_name}, OS: ${os_name}"
    local result
    result=$(_safe_exec "$cmd")
    
    if jq -e '.data.id' <<< "$result" > /dev/null 2>&1; then
        local new_id
        new_id=$(jq -r '.data.id' <<< "$result")
        echo -e "${GREEN}✓ Image import initiated${NC}"
        echo -e "  ${CYAN}Image OCID:${NC} ${YELLOW}${new_id}${NC}"
        log_action_result "SUCCESS" "Imported image $image_name -> $new_id"
        
        # Auto-add GPU shape compatibility
        _image_add_gpu_compat "$new_id" "$compartment_id" "$region"
    else
        echo -e "${RED}✗ Import failed${NC}"
        echo -e "  ${GRAY}${result:0:500}${NC}"
        log_action_result "FAILED" "Import failed for $image_name"
    fi
    _ui_pause
}

# _image_add_gpu_compat — Add GPU/HPC shape compatibility entries to an image
# Reusable: called after image import and available for future image operations
# Usage: _image_add_gpu_compat "$image_id" "$compartment_id" "$region"
_image_add_gpu_compat() {
    local image_id="$1" compartment_id="$2" region="$3"
    
    echo ""
    echo -e "${WHITE}Adding GPU shape compatibility...${NC}"
    local _gpu_shapes_json
    _gpu_shapes_json=$(_oci_call "shape list" oci compute shape list \
        --compartment-id "$compartment_id" --region "$region" \
        --all --output json)
    local -a _gpu_shape_names=()
    if [[ -n "$_gpu_shapes_json" ]] && jq -e '.data[0]' <<< "$_gpu_shapes_json" >/dev/null 2>&1; then
        while read -r _gs; do
            [[ -n "$_gs" ]] && _gpu_shape_names+=("$_gs")
        done < <(jq -r '[.data[] | select(.shape | test("GPU|HPC")) | .shape] | unique | sort[]' <<< "$_gpu_shapes_json" 2>/dev/null)
    fi
    
    if [[ ${#_gpu_shape_names[@]} -gt 0 ]]; then
        local _gs_ok=0 _gs_fail=0
        for _gs in "${_gpu_shape_names[@]}"; do
            local _compat_cmd="oci compute image-shape-compatibility-entry add --image-id \"$image_id\" --shape-name \"$_gs\" --region \"$region\""
            local _gs_result
            _gs_result=$(_safe_exec "$_compat_cmd")
            if echo "$_gs_result" | jq -e '.data' >/dev/null 2>&1 || [[ -z "$_gs_result" ]]; then
                echo -e "  ${GREEN}✓${NC} ${_gs}"
                ((_gs_ok++))
            else
                echo -e "  ${RED}✗${NC} ${_gs}"
                ((_gs_fail++))
            fi
        done
        echo -e "  ${GREEN}${_gs_ok} shapes added${NC}${_gs_fail:+, ${RED}${_gs_fail} failed${NC}}"
    else
        echo -e "  ${GRAY}No GPU shapes found in region${NC}"
    fi
}

_image_create_from_instance() {
    local compartment_id="$1"
    local region="${FOCUS_REGION:-$REGION}"
    
    echo ""
    _ui_subheader "Create Image from Instance" 0
    echo ""
    echo -n -e "${CYAN}Enter instance OCID: ${NC}"
    read -r instance_id
    [[ -z "$instance_id" ]] && { echo -e "${YELLOW}Cancelled${NC}"; _ui_pause; return; }
    
    echo -n -e "${CYAN}Enter image display name: ${NC}"
    read -r image_name
    [[ -z "$image_name" ]] && { echo -e "${YELLOW}Cancelled${NC}"; _ui_pause; return; }
    
    local cmd="oci compute image create"
    cmd+=" --compartment-id \"$compartment_id\""
    cmd+=" --region \"$region\""
    cmd+=" --instance-id \"$instance_id\""
    cmd+=" --display-name \"$image_name\""
    
    _ui_show_command "$cmd"
    
    _exec_action \
        --confirm-desc "create image" \
        --action-type "IMAGE_CREATE" \
        --context "Instance: $(_short_ocid "$instance_id"), Name: $image_name" \
        --success-msg "Image creation initiated" \
        --success-label "Image OCID" \
        -- "$cmd"
    _ui_pause
}

#===============================================================================
# MENU 4: INSTANCE METADATA SERVICE BROWSER
#===============================================================================

_menu_metadata() {
    while true; do
        _ui_menu_header "INSTANCE METADATA SERVICE (IMDS)" \
            --breadcrumb "Metadata" \
            --env \
            --cmd "curl -sH 'Authorization: Bearer Oracle' -m ${IMDS_TIMEOUT} -L ${IMDS_BASE}/..."
        
        echo ""
        _ui_subheader "Available Metadata Endpoints" 0
        echo ""
        echo -e "  ${YELLOW}1${NC})   ${WHITE}Instance${NC}               - Full instance metadata (tenantId, region, shape, etc.)"
        echo -e "  ${YELLOW}2${NC})   ${WHITE}Instance/metadata${NC}      - User-defined metadata key/values"
        echo -e "  ${YELLOW}3${NC})   ${WHITE}Instance/region${NC}        - Region info"
        echo -e "  ${YELLOW}4${NC})   ${WHITE}Instance/canonicalRegionName${NC}"
        echo -e "  ${YELLOW}5${NC})   ${WHITE}Instance/id${NC}            - Instance OCID"
        echo -e "  ${YELLOW}6${NC})   ${WHITE}Instance/displayName${NC}   - Instance display name"
        echo -e "  ${YELLOW}7${NC})   ${WHITE}Instance/shape${NC}         - Compute shape"
        echo -e "  ${YELLOW}8${NC})   ${WHITE}Instance/tenantId${NC}      - Tenancy OCID"
        echo -e "  ${YELLOW}9${NC})   ${WHITE}Instance/compartmentId${NC} - Compartment OCID"
        echo -e "  ${YELLOW}10${NC})  ${WHITE}Instance/availabilityDomain${NC}"
        echo -e "  ${YELLOW}11${NC})  ${WHITE}Instance/faultDomain${NC}"
        echo -e "  ${YELLOW}12${NC})  ${WHITE}Instance/timeCreated${NC}"
        echo -e "  ${YELLOW}13${NC})  ${WHITE}Instance/agentConfig${NC}   - Oracle Cloud Agent config"
        echo -e "  ${YELLOW}14${NC})  ${WHITE}VNIC${NC}                   - VNIC attachment info"
        echo -e "  ${YELLOW}15${NC})  ${WHITE}VNICs (all)${NC}            - All VNIC details"
        echo -e "  ${YELLOW}16${NC})  ${WHITE}Identity${NC}               - Identity token/certs endpoint"
        echo -e "  ${YELLOW}17${NC})  ${WHITE}Host/rdmaTopologyData${NC}  - RDMA topology (GPU nodes)"
        echo -e "  ${YELLOW}18${NC})  ${WHITE}Custom path${NC}            - Enter a custom IMDS path"
        echo ""
        echo -e "  ${GREEN}a${NC})   Fetch ALL common metadata (dump)"
        echo -e "  ${GREEN}v${NC})   Populate variables.sh from metadata"
        echo -e "  ${RED}b${NC})   Back to main menu"
        echo ""
        _ui_prompt "Metadata" "1-18, a, v, b"
        read -r choice
        
        local endpoint=""
        case "$choice" in
            1)  endpoint="instance/" ;;
            2)  endpoint="instance/metadata/" ;;
            3)  endpoint="instance/region" ;;
            4)  endpoint="instance/canonicalRegionName" ;;
            5)  endpoint="instance/id" ;;
            6)  endpoint="instance/displayName" ;;
            7)  endpoint="instance/shape" ;;
            8)  endpoint="instance/tenantId" ;;
            9)  endpoint="instance/compartmentId" ;;
            10) endpoint="instance/availabilityDomain" ;;
            11) endpoint="instance/faultDomain" ;;
            12) endpoint="instance/timeCreated" ;;
            13) endpoint="instance/agentConfig" ;;
            14) endpoint="vnics/" ;;
            15) endpoint="vnics" ;;
            16) endpoint="identity/cert.pem" ;;
            17) endpoint="host/rdmaTopologyData" ;;
            18)
                echo -n -e "${CYAN}Enter IMDS path (after /opc/v2/): ${NC}"
                read -r endpoint
                ;;
            a|A) _metadata_dump_all; continue ;;
            v|V) _metadata_populate_variables; continue ;;
            b|B|"") break ;;
            env*|ENV*) _env_dispatch "$choice"; continue ;;
            show|SHOW) continue ;;
            *) echo -e "${RED}Invalid selection${NC}"; continue ;;
        esac
        
        [[ -z "$endpoint" ]] && continue
        
        _metadata_fetch "$endpoint"
    done
}

_metadata_fetch() {
    local endpoint="$1"
    local url="${IMDS_BASE}/${endpoint}"
    local cmd="curl -sH \"Authorization: Bearer Oracle\" -m ${IMDS_TIMEOUT} -L \"${url}\""
    
    echo ""
    _ui_subheader "IMDS: ${endpoint}" 0
    echo -e "  ${GRAY}${cmd}${NC}"
    echo ""
    
    local result
    result=$(_imds_get "$endpoint")
    
    if [[ -z "$result" ]]; then
        echo -e "  ${RED}No response — IMDS may not be available (not on OCI instance?)${NC}"
    elif echo "$result" | jq . > /dev/null 2>&1; then
        echo "$result" | jq -C .
    else
        echo -e "  ${WHITE}$result${NC}"
    fi
    echo ""
    _ui_pause
}

_metadata_dump_all() {
    echo ""
    _ui_subheader "Full Metadata Dump" 0
    echo ""
    
    local endpoints=("instance/" "vnics/" "host/rdmaTopologyData")
    
    for ep in "${endpoints[@]}"; do
        echo -e "  ${BOLD}${CYAN}── ${ep} ──${NC}"
        local result
        result=$(_imds_get "$ep")
        if [[ -n "$result" ]] && echo "$result" | jq . > /dev/null 2>&1; then
            echo "$result" | jq -C . | head -40
            local lines
            lines=$(echo "$result" | jq . | wc -l)
            [[ $lines -gt 40 ]] && echo -e "  ${GRAY}... (${lines} total lines, truncated)${NC}"
        elif [[ -n "$result" ]]; then
            echo -e "  ${WHITE}$result${NC}"
        else
            echo -e "  ${GRAY}(no data)${NC}"
        fi
        echo ""
    done
    _ui_pause
}

_metadata_populate_variables() {
    local variables_file="${VARIABLES_FILE:-./variables.sh}"
    
    echo ""
    _ui_subheader "Populate variables.sh from IMDS" 0
    echo ""
    echo -e "${GRAY}Querying IMDS for tenantId, compartmentId, region, AD...${NC}"
    echo ""
    
    local md_tenancy md_compartment md_region md_ad md_shape md_display
    md_tenancy=$(_imds_get "instance/tenantId")
    md_compartment=$(_imds_get "instance/compartmentId")
    md_region=$(_imds_get "instance/canonicalRegionName")
    md_ad=$(_imds_get "instance/availabilityDomain")
    md_shape=$(_imds_get "instance/shape")
    md_display=$(_imds_get "instance/displayName")
    
    _ui_kv "Tenancy ID" "${md_tenancy:-${RED}unavailable${NC}}"
    _ui_kv "Compartment ID" "${md_compartment:-${RED}unavailable${NC}}"
    _ui_kv "Region" "${md_region:-${RED}unavailable${NC}}"
    _ui_kv "AD" "${md_ad:-${RED}unavailable${NC}}"
    _ui_kv "Shape" "${md_shape:-${RED}unavailable${NC}}"
    _ui_kv "Display Name" "${md_display:-${RED}unavailable${NC}}"
    echo ""
    
    if [[ -z "$md_tenancy" && -z "$md_region" ]]; then
        echo -e "${RED}IMDS not available. Cannot populate variables.sh.${NC}"
        _ui_pause
        return
    fi
    
    _ui_kv "Target" "$variables_file"
    echo ""
    
    if ! _ui_confirm "y" "write variables.sh" "$YELLOW"; then
        echo -e "${YELLOW}Cancelled${NC}"
        _ui_pause
        return
    fi
    
    local cmd="Writing ${variables_file} from IMDS metadata"
    log_action "VARIABLES_POPULATE" "$cmd" --context "IMDS auto-populate"
    
    cat > "$variables_file" <<EOF
#!/bin/bash
#===============================================================================
# OCI Environment Configuration
# Auto-populated from IMDS on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Host: ${md_display:-unknown} (${md_shape:-unknown})
#===============================================================================

REGION="${md_region}"
TENANCY_ID="${md_tenancy}"
COMPARTMENT_ID="${md_compartment}"
AD="${md_ad}"

# OKE Cluster (set manually or via env menu)
OKE_CLUSTER_ID=""
CLUSTER_NAME=""

# Instance filter
INSTANCE_FILTER="all"
EOF
    
    chmod +x "$variables_file"
    echo -e "${GREEN}✓ variables.sh populated from IMDS${NC}"
    log_action_result "SUCCESS" "variables.sh populated from IMDS"
    
    # Re-source
    source "$variables_file"
    _focus_init "" ""
    echo -e "${GREEN}✓ Environment reloaded${NC}"
    _ui_pause
}

#===============================================================================
# MENU 5: COMPUTE HOSTS — Multi-Region Scan
#===============================================================================

# Fetch subscribed regions for the tenancy
_ch_fetch_regions() {
    local json
    json=$(_oci_call "Subscribed Regions" \
        oci iam region-subscription list \
            --tenancy-id "${TENANCY_ID}" \
            --all --output json 2>/dev/null)
    echo "$json"
}

# Fetch compute hosts for a single region (called in parallel)
# Accepts tenancy_id as $2 since this runs in backgrounded subshells
_ch_fetch_region_hosts() {
    local region="$1"
    local tenancy_id="$2"
    local json
    json=$(oci compute compute-host list \
        --compartment-id "$tenancy_id" \
        --region "$region" \
        --all --output json 2>/dev/null)
    local count
    count=$(jq '.data.items | length' <<< "$json" 2>/dev/null)
    [[ -z "$count" || "$count" == "null" ]] && count=0
    echo "$count"
}

# Scan all regions for compute hosts with progress bar
# Writes results to COMPUTE_HOST_SCAN_CACHE and sets _CH_SCAN_RESULTS
# UI output goes directly to terminal (not captured)
_ch_scan_all_regions() {
    local force="${1:-false}"
    local scan_cache="$COMPUTE_HOST_SCAN_CACHE"

    # Check cache unless forced
    if [[ "$force" != "true" ]] && is_cache_fresh "$scan_cache" 600; then
        echo -e "  ${GREEN}✓${NC} Using cached scan results"
        _CH_SCAN_RESULTS=$(cat "$scan_cache")
        return 0
    fi

    _step_init
    _step_active "Fetching subscribed regions"

    local regions_json
    regions_json=$(_ch_fetch_regions)
    local region_count
    region_count=$(jq '.data | length' <<< "$regions_json" 2>/dev/null)
    [[ -z "$region_count" || "$region_count" == "null" ]] && region_count=0

    if [[ $region_count -eq 0 ]]; then
        _step_complete "Regions(0)"
        _step_finish
        _CH_SCAN_RESULTS="[]"
        return 1
    fi

    _step_complete "Regions(${region_count})"

    # Build region list
    local -a region_names=()
    while IFS= read -r rname; do
        region_names+=("$rname")
    done < <(jq -r '.data[]."region-name"' <<< "$regions_json" 2>/dev/null)

    # Kill step spinner before progress bar
    _step_phase_end

    # Scan each region in parallel with progress bar
    local tmpdir
    tmpdir=$(mktemp -d "${TEMP_DIR}/ch_scan.XXXXXXXX")
    local start_time
    start_time=$(date +%s)
    local completed=0

    local tenancy_id="${TENANCY_ID}"
    local -a pids=()
    local -a pid_regions=()
    for region in "${region_names[@]}"; do
        (
            local count
            count=$(_ch_fetch_region_hosts "$region" "$tenancy_id")
            echo "$count" > "${tmpdir}/${region}"
        ) &
        pids+=($!)
        pid_regions+=("$region")

        # Throttle parallel requests
        if [[ ${#pids[@]} -ge $OCI_MAX_PARALLEL ]]; then
            wait "${pids[0]}" 2>/dev/null
            pids=("${pids[@]:1}")
            pid_regions=("${pid_regions[@]:1}")
            completed=$((completed + 1))
            _ch_progress_bar "$completed" "$region_count" "$start_time"
        fi
    done

    # Wait for remaining with progress updates
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
        completed=$((completed + 1))
        _ch_progress_bar "$completed" "$region_count" "$start_time"
    done

    local elapsed=$(( $(date +%s) - start_time ))
    printf "${CLEAR_LINE}"

    # Build results JSON
    local results="[]"
    local total_hosts=0
    local regions_with_hosts=0
    for region in "${region_names[@]}"; do
        local count=0
        [[ -f "${tmpdir}/${region}" ]] && count=$(cat "${tmpdir}/${region}")
        [[ -z "$count" || "$count" == "null" ]] && count=0
        results=$(jq --arg r "$region" --argjson c "$count" \
            '. += [{"region": $r, "count": $c}]' <<< "$results")
        total_hosts=$((total_hosts + count))
        [[ $count -gt 0 ]] && regions_with_hosts=$((regions_with_hosts + 1))
    done

    rm -rf "$tmpdir" 2>/dev/null

    # Final summary line
    _STEP_COMPLETED_TEXT=""
    _step_complete "Regions(${region_count})"
    _step_complete "Hosts(${total_hosts} in ${regions_with_hosts} regions)"
    _step_complete "${elapsed}s"
    _step_finish

    # Cache the results
    echo "$results" | _cache_write "$scan_cache"
    _CH_SCAN_RESULTS="$results"
}

# Progress bar for region scanning
_ch_progress_bar() {
    local done_count="$1" total="$2" start_time="$3"
    local bar_width=40
    local pct=0
    [[ $total -gt 0 ]] && pct=$(( (done_count * 100) / total ))
    local filled=$(( (done_count * bar_width) / total ))
    local empty=$(( bar_width - filled ))
    local elapsed=$(( $(date +%s) - start_time ))

    local bar=""
    [[ $filled -gt 0 ]] && bar=$(printf '█%.0s' $(seq 1 "$filled"))
    local remaining=""
    [[ $empty -gt 0 ]] && remaining=$(printf '░%.0s' $(seq 1 "$empty"))

    printf "${CLEAR_LINE}  ${CYAN}Scanning:${NC} [${GREEN}%s${GRAY}%s${NC}] %3d%% (%d/%d regions, %ds) " \
        "$bar" "$remaining" "$pct" "$done_count" "$total" "$elapsed"
}

# Display the region summary table
_ch_display_region_summary() {
    local results="$1"

    echo ""
    _ui_section "Compute Host Distribution by Region"
    echo ""

    local total_regions
    total_regions=$(jq 'length' <<< "$results")
    local total_hosts
    total_hosts=$(jq '[.[].count] | add // 0' <<< "$results")
    local regions_with
    regions_with=$(jq '[.[] | select(.count > 0)] | length' <<< "$results")

    echo -e "  ${CYAN}Regions Scanned:${NC}  ${WHITE}${total_regions}${NC}    ${CYAN}With Hosts:${NC}  ${WHITE}${regions_with}${NC}    ${CYAN}Total Hosts:${NC}  ${WHITE}${total_hosts}${NC}"
    echo ""

    if [[ $regions_with -eq 0 ]]; then
        echo -e "  ${GRAY}No compute hosts found in any subscribed region${NC}"
        echo ""
        return
    fi

    # Table header — only regions with hosts
    _ui_table_header "    %-4s  %-28s  %8s" "#" "Region" "Hosts"
    echo ""

    local idx=0
    while IFS='|' read -r region count; do
        [[ $count -eq 0 ]] && continue
        ((idx++))
        printf "    ${YELLOW}%-4s${NC}  %-28s  ${GREEN}%8s${NC}\n" \
            "$idx" "$region" "$count"
    done < <(jq -r '.[] | "\(.region)|\(.count)"' <<< "$results")

    echo ""
    echo -e "  ${CYAN}Total:${NC} ${WHITE}${total_hosts} compute host(s)${NC} across ${WHITE}${regions_with}${NC} of ${WHITE}${total_regions}${NC} region(s)"
    echo ""
}

# Display detailed hosts for a selected region
_ch_display_region_hosts() {
    local region="$1"

    echo ""
    _step_init
    _step_active "Fetching compute hosts in ${region}"

    local hosts_json
    hosts_json=$(_oci_call "Compute Hosts (${region})" \
        oci compute compute-host list \
            --compartment-id "${TENANCY_ID}" \
            --region "$region" \
            --all --output json)

    local host_count
    host_count=$(_jq_count "$hosts_json" ".data.items")
    _step_complete "Hosts(${host_count})"
    _step_finish

    if [[ $host_count -eq 0 ]]; then
        echo -e "  ${GRAY}No compute hosts found in ${region}${NC}"
        _ui_pause
        return
    fi

    echo ""
    _ui_section "Compute Hosts — ${region}"
    echo ""

    _ui_table_header "    %-4s  %-30s  %-12s  %-10s  %-20s  %-14s  %s" \
        "#" "Name" "State" "Health" "Shape" "Fault Domain" "Has Impacted"
    echo ""

    local hidx=0
    while IFS='|' read -r name state health shape fd impacted host_id; do
        ((hidx++))

        # Color coding for state
        local state_color="$WHITE"
        case "$state" in
            ACTIVE|OCCUPIED) state_color="$GREEN" ;;
            AVAILABLE)       state_color="$CYAN" ;;
            INACTIVE|*)      state_color="$GRAY" ;;
        esac

        # Color coding for health
        local health_color="$GREEN"
        case "$health" in
            HEALTHY)                    health_color="$GREEN" ;;
            DEGRADED)                   health_color="$YELLOW" ;;
            IMPAIRED|UNHEALTHY|FAILED)  health_color="$RED" ;;
        esac

        # Color for impacted
        local imp_color="$GRAY"
        local imp_text="No"
        if [[ "$impacted" == "true" ]]; then
            imp_color="$RED"
            imp_text="Yes"
        fi

        # Shorten FD for display
        local fd_short="${fd##*-}"
        [[ "$fd_short" == "$fd" ]] && fd_short="$fd"

        printf "    ${YELLOW}%-4s${NC}  %-30s  ${state_color}%-12s${NC}  ${health_color}%-10s${NC}  %-20s  %-14s  ${imp_color}%s${NC}\n" \
            "$hidx" "$(truncate_string "${name:-N/A}" 30)" \
            "${state:-N/A}" "${health:-N/A}" \
            "$(truncate_string "${shape:-N/A}" 20)" \
            "$fd_short" "$imp_text"
    done < <(jq -r '.data.items[] | "\(.["display-name"] // "N/A")|\(.["lifecycle-state"] // "N/A")|\(.health // "N/A")|\(.shape // "N/A")|\(.["fault-domain"] // "N/A")|\(.["has-impacted-components"] // false)|\(.id)"' <<< "$hosts_json" 2>/dev/null)

    echo ""

    # Detail drill-down
    local -a host_ids=()
    while IFS= read -r hid; do
        host_ids+=("$hid")
    done < <(jq -r '.data.items[].id' <<< "$hosts_json" 2>/dev/null)

    while true; do
        echo -e "  ${CYAN}Enter host # for details, or ${YELLOW}b${CYAN} to go back${NC}"
        _ui_prompt "Compute Hosts - ${region}" "#, b"
        local hchoice
        read -r hchoice

        case "$hchoice" in
            b|B|back) break ;;
            "")       break ;;
            *[!0-9]*) echo -e "  ${RED}Invalid selection${NC}"; continue ;;
        esac

        if [[ $hchoice -lt 1 || $hchoice -gt ${#host_ids[@]} ]]; then
            echo -e "  ${RED}Selection out of range (1-${#host_ids[@]})${NC}"
            continue
        fi

        local selected_id="${host_ids[$((hchoice-1))]}"
        _ch_display_host_detail "$selected_id" "$region"
    done
}

# Display detailed view of a single compute host
_ch_display_host_detail() {
    local host_id="$1"
    local region="$2"

    echo ""
    _step_init
    _step_active "Fetching host details"

    local detail_json
    detail_json=$(_oci_call "Host Detail" \
        oci compute compute-host get \
            --compute-host-id "$host_id" \
            --region "$region" \
            --output json)

    _step_complete "Details"
    _step_finish

    if [[ -z "$detail_json" || "$detail_json" == "null" ]]; then
        echo -e "  ${RED}Failed to fetch host details${NC}"
        _ui_pause
        return
    fi

    local data
    data=$(jq '.data' <<< "$detail_json")

    local name state health shape ad fd platform
    local host_ocid instance_id cap_res_id hpc_island net_block local_block
    local host_group gpu_fabric impacted created updated compartment

    name=$(jq -r '.["display-name"] // "N/A"' <<< "$data")
    state=$(jq -r '.["lifecycle-state"] // "N/A"' <<< "$data")
    health=$(jq -r '.health // "N/A"' <<< "$data")
    shape=$(jq -r '.shape // "N/A"' <<< "$data")
    ad=$(jq -r '.["availability-domain"] // "N/A"' <<< "$data")
    fd=$(jq -r '.["fault-domain"] // "N/A"' <<< "$data")
    platform=$(jq -r '.platform // "N/A"' <<< "$data")
    host_ocid=$(jq -r '.id // "N/A"' <<< "$data")
    instance_id=$(jq -r '.["instance-id"] // "N/A"' <<< "$data")
    cap_res_id=$(jq -r '.["capacity-reservation-id"] // "N/A"' <<< "$data")
    hpc_island=$(jq -r '.["hpc-island-id"] // "N/A"' <<< "$data")
    net_block=$(jq -r '.["network-block-id"] // "N/A"' <<< "$data")
    local_block=$(jq -r '.["local-block-id"] // "N/A"' <<< "$data")
    host_group=$(jq -r '.["compute-host-group-id"] // "N/A"' <<< "$data")
    gpu_fabric=$(jq -r '.["gpu-memory-fabric-id"] // "N/A"' <<< "$data")
    impacted=$(jq -r '.["has-impacted-components"] // "N/A"' <<< "$data")
    created=$(jq -r '.["time-created"] // "N/A"' <<< "$data")
    updated=$(jq -r '.["time-updated"] // "N/A"' <<< "$data")
    compartment=$(jq -r '.["compartment-id"] // "N/A"' <<< "$data")

    echo ""
    _ui_detail_banner "Compute Host - ${name}"
    echo ""

    # Health color
    local health_color="$GREEN"
    case "$health" in
        DEGRADED)                   health_color="$YELLOW" ;;
        IMPAIRED|UNHEALTHY|FAILED)  health_color="$RED" ;;
    esac

    _ui_kv "Name"             "$name"
    _ui_kv "State"            "$state"
    _ui_kv "Health"           "${health}" "${health_color}"
    _ui_kv "Shape"            "$shape"
    _ui_kv "Platform"         "$platform"
    _ui_kv "Region"           "$region"
    _ui_kv "AD"               "$ad"
    _ui_kv "Fault Domain"     "$fd"
    echo ""
    _ui_subheader "Instance & Reservation" 2
    _ui_kv "Instance ID"      "$(_short_ocid "$instance_id")"
    _ui_kv "Cap Reservation"  "$(_short_ocid "$cap_res_id")"
    _ui_kv "Host Group"       "$(_short_ocid "$host_group")"
    echo ""
    _ui_subheader "Topology" 2
    _ui_kv "HPC Island"       "$(_short_ocid "$hpc_island")"
    _ui_kv "Network Block"    "$(_short_ocid "$net_block")"
    _ui_kv "Local Block"      "$(_short_ocid "$local_block")"
    _ui_kv "GPU Fabric"       "$(_short_ocid "$gpu_fabric")"
    echo ""
    _ui_subheader "Maintenance" 2
    local imp_color="$GREEN" imp_text="No"
    if [[ "$impacted" == "true" ]]; then
        imp_color="$RED"
        imp_text="Yes"

        # Show impacted component details if available
        local imp_details
        imp_details=$(jq -r '.["impacted-component-details"] // empty' <<< "$data" 2>/dev/null)
        if [[ -n "$imp_details" && "$imp_details" != "null" ]]; then
            _ui_kv "Impacted" "$imp_text" "$imp_color"
            echo ""
            echo -e "    ${YELLOW}Impacted Components:${NC}"
            jq -r '
                if .impactedComponents then
                    .impactedComponents | to_entries[] |
                    "      \(.key): \(.value | if type == "array" then (. | join(", ")) elif type == "object" then (. | tostring) else . end)"
                else
                    "      (no details available)"
                end
            ' <<< "$imp_details" 2>/dev/null
        else
            _ui_kv "Impacted" "$imp_text" "$imp_color"
        fi
    else
        _ui_kv "Impacted" "$imp_text" "$imp_color"
    fi

    # Recycle details
    local recycle_level
    recycle_level=$(jq -r '.["recycle-details"]["recycle-level"] // "N/A"' <<< "$data" 2>/dev/null)
    [[ "$recycle_level" != "N/A" && "$recycle_level" != "null" ]] && \
        _ui_kv "Recycle Level" "$recycle_level"

    echo ""
    _ui_subheader "Timestamps" 2
    _ui_kv "Created"          "$created"
    _ui_kv "Updated"          "$updated"
    echo ""
    _ui_kv "Host OCID"        "$host_ocid" "$GRAY"
    _ui_kv "Compartment"      "$(_short_ocid "$compartment")" "$GRAY"
    echo ""

    _ui_pause
}

# Main compute hosts menu
_menu_compute_hosts() {
    _CH_SCAN_RESULTS=""

    while true; do
        _ui_menu_header "COMPUTE HOSTS — Multi-Region Scan" \
            --breadcrumb "Compute Hosts" \
            --color "$BLUE" \
            --env \
            --cmd "oci compute compute-host list --compartment-id \$TENANCY_ID --region <region>"

        echo ""
        _ui_actions
        _ui_action_group "Actions"
        echo -e "  ${YELLOW}1${NC})  ${WHITE}Scan All Regions${NC}     - Discover compute hosts across all subscribed regions"
        echo -e "  ${YELLOW}2${NC})  ${WHITE}View Region Hosts${NC}    - View hosts in a specific region"
        echo -e "  ${YELLOW}r${NC})  ${WHITE}Refresh${NC}              - Force rescan (ignore cache)"
        echo ""
        echo -e "  ${RED}b${NC})  ${WHITE}Back${NC}"
        echo ""
        _ui_prompt "Compute Hosts" "1, 2, r, b"
        local choice
        read -r choice

        case "$choice" in
            1)
                _ch_scan_all_regions false
                if [[ -n "$_CH_SCAN_RESULTS" && "$_CH_SCAN_RESULTS" != "[]" ]]; then
                    _ch_display_region_summary "$_CH_SCAN_RESULTS"
                    _ui_pause
                else
                    echo -e "  ${RED}No subscribed regions found or scan failed${NC}"
                    _ui_pause
                fi
                ;;
            2)
                # If we haven't scanned yet, scan first
                if [[ -z "$_CH_SCAN_RESULTS" || "$_CH_SCAN_RESULTS" == "[]" ]]; then
                    _ch_scan_all_regions false
                fi
                if [[ -z "$_CH_SCAN_RESULTS" || "$_CH_SCAN_RESULTS" == "[]" ]]; then
                    echo -e "  ${RED}No regions available. Run scan first.${NC}"
                    _ui_pause
                    continue
                fi

                # Show summary (only regions with hosts) and let user pick
                _ch_display_region_summary "$_CH_SCAN_RESULTS"

                # Build filtered list (only regions with count > 0)
                local filtered_regions
                filtered_regions=$(jq '[.[] | select(.count > 0)]' <<< "$_CH_SCAN_RESULTS")
                local filtered_count
                filtered_count=$(jq 'length' <<< "$filtered_regions")

                if [[ $filtered_count -eq 0 ]]; then
                    echo -e "  ${GRAY}No regions with compute hosts found${NC}"
                    _ui_pause
                    continue
                fi

                echo -e "  ${CYAN}Enter region # to view hosts, or ${YELLOW}b${CYAN} to go back${NC}"
                _ui_prompt "Select Region" "#, b"
                local rchoice
                read -r rchoice

                case "$rchoice" in
                    b|B|back|"") continue ;;
                    *[!0-9]*) echo -e "  ${RED}Invalid selection${NC}"; _ui_pause; continue ;;
                esac

                if [[ $rchoice -lt 1 || $rchoice -gt $filtered_count ]]; then
                    echo -e "  ${RED}Selection out of range (1-${filtered_count})${NC}"
                    _ui_pause
                    continue
                fi

                local selected_region
                selected_region=$(jq -r ".[$((rchoice-1))].region" <<< "$filtered_regions")

                _ch_display_region_hosts "$selected_region"
                ;;
            r|R|refresh)
                _ch_scan_all_regions true
                if [[ -n "$_CH_SCAN_RESULTS" && "$_CH_SCAN_RESULTS" != "[]" ]]; then
                    _ch_display_region_summary "$_CH_SCAN_RESULTS"
                    _ui_pause
                else
                    echo -e "  ${RED}Scan failed or no regions found${NC}"
                    _ui_pause
                fi
                ;;
            b|B|back)
                return
                ;;
            show|SHOW) continue ;;
            "")  return ;;
            *)   echo -e "  ${RED}Invalid selection. Enter 1, 2, r, or b.${NC}" ;;
        esac
    done
}

#===============================================================================
# MAIN MENU
#===============================================================================

interactive_main_menu() {
    local direct_choice="${1:-}"
    
    while true; do
        local choice
        if [[ -n "$direct_choice" ]]; then
            choice="$direct_choice"
            direct_choice=""
        else
            echo ""
            _ui_banner "GPU OPERATIONAL TESTING" "$MAGENTA"
            echo ""
            _ui_env_info
            echo ""
            
            _ui_actions
            _ui_action_group "Categories"
            echo -e "  ${YELLOW}p${NC})  ${WHITE}POCs${NC}              - Deploy OKE/Slurm stack POC environments"
            echo -e "  ${YELLOW}t${NC})  ${WHITE}OKE Testing${NC}       - Node creation, health checks, NCCL tests"
            echo -e "  ${YELLOW}i${NC})  ${WHITE}Images${NC}            - Import, create, and manage custom images"
            echo -e "  ${YELLOW}m${NC})  ${WHITE}Metadata${NC}          - Browse instance metadata service (IMDS)"
            echo -e "  ${YELLOW}h${NC})  ${WHITE}Compute Hosts${NC}     - Multi-region compute host scan & details"
            echo ""
            _ui_action_group "Utilities"
            echo -e "  ${CYAN}env${NC})   ${WHITE}Change Focus${NC}    - Change region, compartment, OKE cluster"
            echo -e "  ${RED}q${NC})     ${WHITE}Quit${NC}"
            echo ""
            echo -e "  ${GRAY}Shortcuts: p1=OKE Stack, p2=Slurm 2.x, p3=Slurm 3.x${NC}"
            echo -e "  ${GRAY}Quick env: env c (compartment), env r (region), env oke${NC}"
            echo ""
            _ui_prompt "GPU Ops" "p, t, i, m, h, env, q"
            
            read -r choice
        fi
        
        [[ -z "$choice" ]] && { echo -e "${GREEN}Exiting${NC}"; break; }
        
        # Parse shortcuts: p1, p2, t3, etc.
        local category="" item=""
        if [[ "$choice" =~ ^([ptimhPTIMH])([0-9]+)?$ ]]; then
            category="${BASH_REMATCH[1],,}"
            item="${BASH_REMATCH[2]}"
        fi
        
        case "${category:-$choice}" in
            p) _menu_pocs "$item" ;;
            t) _menu_oke_testing "$item" ;;
            i) _menu_images ;;
            m) _menu_metadata ;;
            h) _menu_compute_hosts ;;
            env*|ENV*) _env_dispatch "$choice" ;;
            q|Q|quit|QUIT|exit|EXIT)
                echo ""
                echo -e "${GREEN}Exiting GPU Operational Testing${NC}"
                break
                ;;
            show|SHOW) continue ;;
            *) echo -e "${RED}Invalid selection. Enter p, t, i, m, h, env, or q.${NC}" ;;
        esac
    done
}

#===============================================================================
# HELP
#===============================================================================

show_help() {
    cat <<EOF
${BOLD}GPU Operational Testing Tool${NC}

${BOLD}USAGE:${NC}
  ./gpu_ops_testing.sh [OPTIONS]

${BOLD}OPTIONS:${NC}
  --manage [shortcut]   Launch interactive menu (e.g., --manage p1)
  --setup               Run initial setup to create variables.sh
  --debug               Enable debug output
  --compartment-id ID   Override compartment from variables.sh
  --region REGION        Override region from variables.sh
  --help, -h            Show this help

${BOLD}MENU CATEGORIES:${NC}
  p) POCs               Deploy OKE/Slurm stack POC environments
  t) OKE Testing        Node creation, health checks, NCCL templates
  i) Images             Custom image import, create, management
  m) Metadata           Instance Metadata Service (IMDS) browser
  h) Compute Hosts      Multi-region compute host scan & details

${BOLD}SHORTCUTS:${NC}
  p1  OKE Stack POC         p2  Slurm 2.x POC      p3  Slurm 3.x POC
  ps  POC Setup Wizard      t1  Add Node (Config)   t2  Add Node (Manual)
  t3  List Clusters          t4  List Node Pools     t8  Create Node Pool

${BOLD}ENVIRONMENT:${NC}
  env       Full environment menu
  env c     Quick compartment change
  env r     Quick region change
  env oke   Quick OKE cluster change

${BOLD}CONFIGURATION:${NC}
  Uses variables.sh for REGION, TENANCY_ID, COMPARTMENT_ID, OKE_CLUSTER_ID.
  Run --setup or use the Metadata > Populate option to create variables.sh.
EOF
}

#===============================================================================
# VARIABLES.SH CHECK
#===============================================================================

check_variables_populated() {
    [[ -z "${REGION:-}" || -z "${TENANCY_ID:-}" || -z "${COMPARTMENT_ID:-}" ]] && return 1
    return 0
}

_validate_config() {
    local errors=0

    if [[ -z "${COMPARTMENT_ID:-}" ]]; then
        log_error "COMPARTMENT_ID not set in variables.sh"
        ((errors++))
    elif [[ ! "$COMPARTMENT_ID" == ocid1.compartment.* && ! "$COMPARTMENT_ID" == ocid1.tenancy.* ]]; then
        log_error "COMPARTMENT_ID doesn't look like a valid OCID"
        ((errors++))
    fi

    if [[ -z "${REGION:-}" ]]; then
        log_error "REGION not set in variables.sh"
        ((errors++))
    fi

    if [[ -z "${TENANCY_ID:-}" ]]; then
        log_error "TENANCY_ID not set in variables.sh"
        ((errors++))
    fi

    [[ $errors -gt 0 ]] && return 1
    return 0
}

#===============================================================================
# MAIN ENTRY POINT
#===============================================================================

main() {
    check_dependencies || exit 1
    
    # Source variables file
    local variables_file="${VARIABLES_FILE:-}"
    local variables_found=false
    if [[ -n "$variables_file" && -f "$variables_file" ]]; then
        # shellcheck source=/dev/null
        source "$variables_file"
        variables_found=true
    elif [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
        variables_file="$SCRIPT_DIR/variables.sh"
        # shellcheck source=/dev/null
        source "$variables_file"
        variables_found=true
    elif [[ -f "./variables.sh" ]]; then
        variables_file="./variables.sh"
        # shellcheck source=/dev/null
        source "$variables_file"
        variables_found=true
    fi
    
    if [[ "$variables_found" == "false" ]]; then
        echo -e "${YELLOW}variables.sh not found.${NC}"
        echo ""
        echo -e "${CYAN}Options:${NC}"
        echo -e "  ${YELLOW}1${NC}) Auto-populate from IMDS metadata (if running on OCI instance)"
        echo -e "  ${YELLOW}2${NC}) Enter values manually"
        echo -e "  ${YELLOW}3${NC}) Exit"
        echo ""
        echo -n -e "${CYAN}Choice [1]: ${NC}"
        read -r setup_choice
        
        case "${setup_choice:-1}" in
            1)
                # Try IMDS
                local _t _r _c _a
                _t=$(_imds_get "instance/tenantId")
                _r=$(_imds_get "instance/canonicalRegionName")
                _c=$(_imds_get "instance/compartmentId")
                _a=$(_imds_get "instance/availabilityDomain")
                
                if [[ -n "$_t" && -n "$_r" ]]; then
                    cat > "./variables.sh" <<EOF
#!/bin/bash
# Auto-populated from IMDS on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
REGION="$_r"
TENANCY_ID="$_t"
COMPARTMENT_ID="$_c"
AD="$_a"
OKE_CLUSTER_ID=""
CLUSTER_NAME=""
INSTANCE_FILTER="all"
EOF
                    chmod +x "./variables.sh"
                    source "./variables.sh"
                    echo -e "${GREEN}✓ variables.sh created from IMDS${NC}"
                else
                    echo -e "${RED}IMDS not available. Use option 2 instead.${NC}"
                    exit 1
                fi
                ;;
            2)
                echo -n -e "${CYAN}TENANCY_ID: ${NC}"; read -r TENANCY_ID
                echo -n -e "${CYAN}COMPARTMENT_ID: ${NC}"; read -r COMPARTMENT_ID
                echo -n -e "${CYAN}REGION: ${NC}"; read -r REGION
                echo -n -e "${CYAN}AD: ${NC}"; read -r AD
                
                cat > "./variables.sh" <<EOF
#!/bin/bash
# Manually configured on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
REGION="$REGION"
TENANCY_ID="$TENANCY_ID"
COMPARTMENT_ID="$COMPARTMENT_ID"
AD="$AD"
OKE_CLUSTER_ID=""
CLUSTER_NAME=""
INSTANCE_FILTER="all"
EOF
                chmod +x "./variables.sh"
                source "./variables.sh"
                echo -e "${GREEN}✓ variables.sh created${NC}"
                ;;
            *) exit 0 ;;
        esac
    elif ! check_variables_populated; then
        echo -e "${YELLOW}variables.sh exists but required values are not set.${NC}"
        echo -e "${YELLOW}Edit variables.sh to set REGION, TENANCY_ID, and COMPARTMENT_ID.${NC}"
        exit 1
    fi
    
    # Create directories
    ( umask 077 && mkdir -p "$CACHE_DIR" "$TEMP_DIR" )
    
    # Parse global options
    local custom_compartment=""
    local custom_region=""
    local args=("$@")
    local new_args=()
    local i=0
    
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --compartment-id)
                if [[ $((i + 1)) -lt ${#args[@]} ]]; then
                    custom_compartment="${args[$((i + 1))]}"
                    i=$((i + 2))
                else
                    log_error "--compartment-id requires a value"; exit 1
                fi
                ;;
            --region)
                if [[ $((i + 1)) -lt ${#args[@]} ]]; then
                    custom_region="${args[$((i + 1))]}"
                    i=$((i + 2))
                else
                    log_error "--region requires a value"; exit 1
                fi
                ;;
            --debug)
                DEBUG_MODE=true
                i=$((i + 1))
                ;;
            *)
                new_args+=("${args[$i]}")
                i=$((i + 1))
                ;;
        esac
    done
    
    _focus_init "$custom_compartment" "$custom_region"
    _validate_config || exit 1
    _detect_tool_versions
    
    set -- "${new_args[@]}"
    
    case "${1:-}" in
        ""|--manage)
            shift 2>/dev/null || true
            interactive_main_menu "${1:-}"
            ;;
        --setup)
            _metadata_populate_variables
            ;;
        --help|-h)
            show_help
            ;;
        *)
            interactive_main_menu "$1"
            ;;
    esac
}

main "$@"
