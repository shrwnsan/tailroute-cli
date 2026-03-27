#!/usr/bin/env bash
# tailroute.sh — Main daemon and CLI entry point
# tailroute v0.2.1
#
# Usage:
#   tailroute daemon        Run as daemon (for launchd)
#   tailroute status        Show daemon status and state
#   tailroute proxy         Manage SOCKS5 proxy (start/stop/status/install)
#   tailroute proxy-config  Generate proxy configuration helpers
#   tailroute --version     Show version
#   tailroute --dry-run     Single reconcile without modifying DNS
#   tailroute --help        Show help
#   tailroute install       Install daemon (requires root)
#   tailroute uninstall     Uninstall daemon (requires root)

set -euo pipefail

# Version
readonly VERSION="0.2.1"

# Absolute path to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all required libraries
# shellcheck source=lib-log.sh
source "$SCRIPT_DIR/lib-log.sh"
# shellcheck source=lib-event-loop.sh
source "$SCRIPT_DIR/lib-event-loop.sh"

# =============================================================================
# show_help — Print usage information
# =============================================================================
show_help() {
    cat <<'EOF'
tailroute — Automatic MagicDNS manager for Tailscale + VPN

Usage:
  tailroute daemon              Run as daemon (default, for launchd)
  tailroute status              Show daemon status and proxy state
  tailroute proxy <command>     Manage SOCKS5 proxy:
                                  start    Start proxy (downloads if needed)
                                  stop     Stop proxy
                                  status   Show proxy status
                                  install  Download proxy binary (~20MB)
                                  uninstall Remove proxy binary
  tailroute proxy-config ssh    Generate SSH config for Tailscale peers
  tailroute proxy-config shell  Generate shell helpers (sshproxy/curlproxy)
  tailroute --version           Show version
  tailroute --dry-run           Preview actions without modifying DNS
  tailroute install             Install daemon (requires sudo)
  tailroute uninstall           Uninstall daemon (requires sudo)
  tailroute --help              Show this help

Decision matrix:
  • Tailscale + VPN active → Disable MagicDNS, start proxy
  • Tailscale active, no VPN → Enable MagicDNS, stop proxy
  • No Tailscale → No action

Log location: /var/log/tailroute.log (daemon) or ~/Library/Logs/Tailroute/ (app)

EOF
}

# =============================================================================
# show_version — Print version
# =============================================================================
show_version() {
    echo "tailroute $VERSION"
}

# =============================================================================
# do_daemon — Run event loop (main daemon operation)
# =============================================================================
do_daemon() {
    log_info "tailroute daemon starting (PID $$)"
    
    if ! run_event_loop; then
        log_error "Event loop failed"
        exit 1
    fi
    
    # If we get here, shutdown signal was received
    log_info "tailroute daemon exiting"
    exit 0
}

# =============================================================================
# do_status — Show daemon status and current state
# =============================================================================
# This command does NOT require root — all data is world-readable.
do_status() {
    echo "tailroute v$VERSION"
    echo "=================="
    echo ""
    
    # Check if daemon is loaded (try user-level first, then system-level via process check)
    local daemon_info daemon_pid

    # User-level daemon
    daemon_info=$(launchctl list 2>/dev/null | grep com.tailroute.daemon) || daemon_info=""

    if [[ -n "$daemon_info" ]]; then
        daemon_pid=$(echo "$daemon_info" | awk '{print $1}')
        echo "Daemon:         Running (PID $daemon_pid)"
    else
        # Check for running daemon process (system-level services may not appear in user launchctl)
        daemon_pid=$(pgrep -f "tailroute daemon" 2>/dev/null | head -1) || daemon_pid=""
        if [[ -n "$daemon_pid" ]]; then
            echo "Daemon:         Running (PID $daemon_pid)"
        else
            echo "Daemon:         Not running"
        fi
    fi
    
    echo ""
    
    # Show detected interfaces (from detection functions)
    local ts_interface vpn_interface ts_ip
    ts_interface=$(find_tailscale_interface 2>/dev/null) || ts_interface=""
    vpn_interface=$(find_vpn_default_route "$ts_interface" 2>/dev/null) || vpn_interface=""
    
    if [[ -n "$ts_interface" ]]; then
        ts_ip=$(get_tailscale_ip "$ts_interface" 2>/dev/null) || ts_ip=""
        echo "Tailscale:      $ts_interface${ts_ip:+ ($ts_ip)}"
    else
        echo "Tailscale:      Not active"
    fi
    
    if [[ -n "$vpn_interface" ]]; then
        echo "VPN:            $vpn_interface (active)"
    else
        echo "VPN:            Inactive"
    fi
    
    echo ""
    
    # Show current MagicDNS state from state manifest
    if [[ -f "${STATE_MANIFEST:-}" ]]; then
        local last_state
        last_state=$(state_read 2>/dev/null) || last_state=""
        
        if [[ -n "$last_state" ]]; then
            local timestamp action magicdns_enabled
            IFS='|' read -r timestamp action magicdns_enabled <<< "$last_state"
            
            echo "Last action:    $action at $timestamp"
            echo "MagicDNS state: $magicdns_enabled (as set by daemon)"
        fi
    fi
    
    # Show proxy status
    local proxy_pid proxy_addr="127.0.0.1:1055"
    proxy_pid=$(pgrep -f "tailroute-proxy" 2>/dev/null | head -1) || proxy_pid=""
    
    echo ""
    if [[ -n "$proxy_pid" ]]; then
        echo "SOCKS5 Proxy:   Running (pid $proxy_pid, $proxy_addr)"
    else
        echo "SOCKS5 Proxy:   Stopped"
    fi
    
    echo ""
}

# =============================================================================
# do_dry_run — Preview reconciliation without modifying DNS
# =============================================================================
do_dry_run() {
    log_info "Dry-run reconciliation"
    
    if ! reconcile_dry_run; then
        exit 1
    fi
    
    exit 0
}

# =============================================================================
# do_install — Install daemon (requires root)
# =============================================================================
# Copies binary and plist to system locations, sets permissions, loads daemon.
do_install() {
    # Verify root
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: install requires root (use 'sudo tailroute install')"
        exit 1
    fi
    
    echo "Installing tailroute daemon..."
    echo ""
    
    # Find script directory (works for both direct run and installed copy)
    local script_path="$0"
    local script_dir
    if [[ "$script_path" == "/"* ]]; then
        # Absolute path
        script_dir="$(dirname "$script_path")"
    else
        # Relative path — resolve it
        script_dir="$(cd "$(dirname "$script_path")" && pwd)"
    fi
    
    # Find project root (go up from bin/ to project root)
    local project_root="$(cd "$script_dir/.." && pwd)"
    
    # Copy binary to /usr/local/bin (only if newer)
    echo "  Installing /usr/local/bin/tailroute..."
    if [[ ! -f /usr/local/bin/tailroute ]] || [[ "$script_path" -nt /usr/local/bin/tailroute ]]; then
        cp -f "$script_path" /usr/local/bin/tailroute
    else
        echo "  /usr/local/bin/tailroute is up to date"
    fi
    chown root:wheel /usr/local/bin/tailroute
    chmod 0755 /usr/local/bin/tailroute

    # Copy proxy binary if it exists
    if [[ -f "$project_root/proxy/build/tailroute-proxy" ]]; then
        echo "  Installing /usr/local/bin/tailroute-proxy..."
        cp -f "$project_root/proxy/build/tailroute-proxy" /usr/local/bin/tailroute-proxy
        chown root:wheel /usr/local/bin/tailroute-proxy
        chmod 0755 /usr/local/bin/tailroute-proxy
    else
        echo "  Note: tailroute-proxy not built (run 'cd proxy && ./build.sh')"
    fi
    
    # Copy library files to /usr/local/bin (only if newer)
    echo "  Installing library files..."
    local lib_name
    for lib in "$script_dir"/lib-*.sh; do
        if [[ -f "$lib" ]]; then
            lib_name="$(basename "$lib")"
            if [[ ! -f "/usr/local/bin/$lib_name" ]] || [[ "$lib" -nt "/usr/local/bin/$lib_name" ]]; then
                cp -f "$lib" /usr/local/bin/
            fi
            chown root:wheel "/usr/local/bin/$lib_name"
            chmod 0644 "/usr/local/bin/$lib_name"
        fi
    done
    
    # Copy plist to /Library/LaunchDaemons
    if [[ -f "$project_root/etc/com.tailroute.daemon.plist" ]]; then
        echo "  Installing launchd plist..."
        cp "$project_root/etc/com.tailroute.daemon.plist" /Library/LaunchDaemons/
        chown root:wheel /Library/LaunchDaemons/com.tailroute.daemon.plist
        chmod 0644 /Library/LaunchDaemons/com.tailroute.daemon.plist
    else
        echo "ERROR: plist not found at $project_root/etc/com.tailroute.daemon.plist"
        exit 1
    fi
    
    # Copy newsyslog config if it exists
    if [[ -f "$project_root/etc/newsyslog.d/tailroute.conf" ]]; then
        echo "  Installing newsyslog config..."
        mkdir -p /etc/newsyslog.d
        cp "$project_root/etc/newsyslog.d/tailroute.conf" /etc/newsyslog.d/
        chown root:wheel /etc/newsyslog.d/tailroute.conf
        chmod 0644 /etc/newsyslog.d/tailroute.conf
    fi
    
    # Create state directory
    echo "  Creating state directory..."
    mkdir -p /var/db/tailroute
    chown root:wheel /var/db/tailroute
    chmod 0755 /var/db/tailroute
    
    # Load daemon
    echo "  Loading launchd daemon..."

    # Check if already loaded
    local already_loaded=false
    if launchctl list 2>/dev/null | grep -q "com.tailroute.daemon"; then
        already_loaded=true
    elif pgrep -f "tailroute daemon" >/dev/null 2>&1; then
        already_loaded=true
    fi

    if $already_loaded; then
        echo "  Daemon already running (use 'tailroute status' to verify)"
    else
        launchctl bootstrap system /Library/LaunchDaemons/com.tailroute.daemon.plist 2>/dev/null || {
            local bootstrap_err=$?
            # Bootstrap may fail with I/O error if already loaded
            if pgrep -f "tailroute daemon" >/dev/null 2>&1; then
                echo "  Daemon already running"
            else
                echo "  Warning: Failed to load daemon (exit code: $bootstrap_err)"
                echo "  Try: sudo launchctl bootstrap system /Library/LaunchDaemons/com.tailroute.daemon.plist"
            fi
        }
    fi

    # Verify loaded
    echo ""
    sleep 1

    if pgrep -f "tailroute daemon" >/dev/null 2>&1; then
        echo "✓ tailroute daemon installed and running"
        echo ""
        echo "  Check status: tailroute status"
        echo "  View logs: tail -f /var/log/tailroute.log"
    else
        echo "⚠ Warning: daemon may not have started yet"
        echo "  Run 'tailroute status' to verify"
    fi

    echo ""
}

# =============================================================================
# do_uninstall — Uninstall daemon (requires root)
# =============================================================================
# Unloads daemon, restores MagicDNS if needed, removes files.
do_uninstall() {
    # Verify root
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: uninstall requires root (use 'sudo tailroute uninstall')"
        exit 1
    fi
    
    echo "Uninstalling tailroute daemon..."
    echo ""
    
    # Unload daemon
    if launchctl list | grep -q "com.tailroute.daemon"; then
        echo "  Unloading launchd daemon..."
        launchctl bootout system/com.tailroute.daemon 2>/dev/null || true
        sleep 1
    fi
    
    # Restore MagicDNS if we disabled it
    if [[ -f "/var/db/tailroute/state.manifest" ]]; then
        local last_line
        last_line=$(tail -n 1 /var/db/tailroute/state.manifest 2>/dev/null) || last_line=""
        
        if [[ "$last_line" == *"disable"* ]]; then
            echo "  Restoring MagicDNS..."
            /usr/local/bin/tailscale set --accept-dns=true 2>/dev/null || true
        fi
    fi
    
    # Remove installed files
    echo "  Removing installed files..."
    rm -f /usr/local/bin/tailroute
    rm -f /usr/local/bin/lib-*.sh
    rm -f /Library/LaunchDaemons/com.tailroute.daemon.plist
    rm -f /etc/newsyslog.d/tailroute.conf
    rm -rf /var/db/tailroute
    rm -f /var/run/tailroute.lock
    
    # Preserve log file (inform user)
    if [[ -f "/var/log/tailroute.log" ]]; then
        echo "  Log file preserved: /var/log/tailroute.log"
    fi
    
    echo ""
    echo "✓ tailroute daemon uninstalled"
    echo ""
}

# =============================================================================
# Proxy binary management
# =============================================================================
PROXY_BIN_NAME="tailroute-proxy"
PROXY_INSTALL_DIR="$HOME/.tailroute/bin"
PROXY_BIN_PATH="$PROXY_INSTALL_DIR/$PROXY_BIN_NAME"
PROXY_STATE_DIR="$HOME/.tailroute/proxy-state"
PROXY_SOCKS_ADDR="127.0.0.1:1055"
PROXY_PID_FILE="$HOME/.tailroute/proxy.pid"
PROXY_VERSION="${VERSION}"

# Download URL (update for public releases)
PROXY_DOWNLOAD_BASE="https://github.com/shrwnsan/tailroute/releases/download"

get_proxy_download_url() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64) arch="amd64" ;;
        *) echo ""; return 1 ;;
    esac
    echo "${PROXY_DOWNLOAD_BASE}/v${PROXY_VERSION}/${PROXY_BIN_NAME}-darwin-${arch}"
}

is_proxy_installed() {
    [[ -x "$PROXY_BIN_PATH" ]]
}

is_proxy_running() {
    if [[ -f "$PROXY_PID_FILE" ]]; then
        local pid
        pid=$(cat "$PROXY_PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Fallback: check by process name
    pgrep -f "$PROXY_BIN_NAME" >/dev/null 2>&1
}

get_proxy_pid() {
    if [[ -f "$PROXY_PID_FILE" ]]; then
        local pid
        pid=$(cat "$PROXY_PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    pgrep -f "$PROXY_BIN_NAME" 2>/dev/null | head -1
}

# =============================================================================
# do_proxy — Manage SOCKS5 proxy
# =============================================================================
do_proxy() {
    local subcommand="${1:-}"
    
    case "$subcommand" in
        ""|--help|-h)
            echo "Usage: tailroute proxy <command>"
            echo ""
            echo "Commands:"
            echo "  auth       Authenticate proxy with Tailscale (get auth URL)"
            echo "  start      Start SOCKS5 proxy (downloads if not installed)"
            echo "  stop       Stop running proxy"
            echo "  status     Show proxy status"
            echo "  install    Download proxy binary (~20MB)"
            echo "  uninstall  Remove proxy binary"
            echo ""
            echo "The proxy routes traffic through Tailscale mesh while VPN is active."
            echo "Listen address: $PROXY_SOCKS_ADDR"
            ;;
        start)
            do_proxy_start
            ;;
        stop)
            do_proxy_stop
            ;;
        status)
            do_proxy_status
            ;;
        auth)
            do_proxy_auth
            ;;
        install)
            do_proxy_install
            ;;
        uninstall)
            do_proxy_uninstall
            ;;
        *)
            echo "ERROR: unknown proxy command '$subcommand'"
            echo "Run 'tailroute proxy --help' for usage."
            exit 1
            ;;
    esac
}

do_proxy_auth() {
    # Check if already authenticated
    if [[ -f "$PROXY_STATE_DIR/tailscaled.state" ]]; then
        echo "✓ Proxy already authenticated."
        echo "Start the proxy with: tailroute proxy start"
        return 0
    fi
    
    # If proxy is running (stray process), stop it
    if is_proxy_running; then
        echo "Stopping stray proxy process..."
        do_proxy_stop
    fi
    
    # Find the binary (same logic as do_proxy_start)
    local bin_path
    if is_proxy_installed; then
        bin_path="$PROXY_BIN_PATH"
    elif [[ -x "/usr/local/bin/$PROXY_BIN_NAME" ]]; then
        bin_path="/usr/local/bin/$PROXY_BIN_NAME"
    else
        echo "ERROR: Proxy binary not installed."
        echo "Run 'tailroute proxy install' first."
        exit 1
    fi
    
    echo "Open the URL below to authenticate with your Tailscale account:"
    echo ""
    echo "Starting proxy for authentication..."
    echo "(Press Ctrl+C after approving in your browser)"
    echo ""
    
    # Run proxy in foreground
    mkdir -p "$PROXY_STATE_DIR"
    "$bin_path" \
        --socks-addr "$PROXY_SOCKS_ADDR" \
        --state-dir "$PROXY_STATE_DIR"
    
    echo ""
    echo "✓ Authentication complete!"
    echo "Start the proxy with: tailroute proxy start"
}

do_proxy_install() {
    if is_proxy_installed; then
        echo "Proxy already installed at $PROXY_BIN_PATH"
        "$PROXY_BIN_PATH" --version 2>/dev/null || true
        return 0
    fi
    
    local url
    url=$(get_proxy_download_url)
    
    if [[ -z "$url" ]]; then
        echo "ERROR: Unsupported architecture: $(uname -m)" >&2
        echo "Build from source: cd proxy && ./build.sh" >&2
        exit 1
    fi
    
    echo "Downloading tailroute-proxy (~20MB)..."
    echo "From: $url"
    
    mkdir -p "$PROXY_INSTALL_DIR"
    
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fSL --progress-bar "$url" -o "$PROXY_BIN_PATH"; then
            echo "ERROR: Download failed. Release may not exist yet." >&2
            echo "For local development, build from source:" >&2
            echo "  cd proxy && ./build.sh" >&2
            echo "  cp build/tailroute-proxy $PROXY_BIN_PATH" >&2
            exit 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q --show-progress "$url" -O "$PROXY_BIN_PATH"; then
            echo "ERROR: Download failed." >&2
            exit 1
        fi
    else
        echo "ERROR: curl or wget required for download" >&2
        exit 1
    fi
    
    chmod +x "$PROXY_BIN_PATH"
    echo "Installed: $PROXY_BIN_PATH"
    "$PROXY_BIN_PATH" --version 2>/dev/null || true
}

do_proxy_uninstall() {
    if is_proxy_running; then
        echo "Stopping proxy first..."
        do_proxy_stop
    fi
    
    if [[ -f "$PROXY_BIN_PATH" ]]; then
        rm -f "$PROXY_BIN_PATH"
        echo "Removed: $PROXY_BIN_PATH"
    else
        echo "Proxy not installed."
    fi
    
    # Optionally clean state
    if [[ -d "$PROXY_STATE_DIR" ]]; then
        read -p "Remove proxy state (Tailscale auth)? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$PROXY_STATE_DIR"
            echo "Removed: $PROXY_STATE_DIR"
        fi
    fi
}

do_proxy_start() {
    if is_proxy_running; then
        local pid
        pid=$(get_proxy_pid)
        echo "Proxy already running (pid $pid)"
        echo "Listen: $PROXY_SOCKS_ADDR"
        # Check if installed binary is newer than running process
        local installed_ver running_ver
        installed_ver=$("$PROXY_BIN_PATH" --version 2>/dev/null | awk '{print $2}')
        running_ver=$(cat "$HOME/.tailroute/proxy.log" 2>/dev/null | grep -m1 "tailroute-proxy" | awk '{print $NF}')
        if [[ -n "$installed_ver" && -n "$running_ver" && "$installed_ver" != "$running_ver" ]]; then
            echo ""
            echo "⚠️  Version mismatch: running $running_ver, installed $installed_ver"
            echo "   Restart to use the new version:"
            echo "   tailroute proxy stop && tailroute proxy start"
        fi
        return 0
    fi
    
    # Check if installed, offer to download
    if ! is_proxy_installed; then
        # Check for system-wide install
        if [[ -x "/usr/local/bin/$PROXY_BIN_NAME" ]]; then
            PROXY_BIN_PATH="/usr/local/bin/$PROXY_BIN_NAME"
        else
            echo "Proxy binary not installed."
            read -p "Download tailroute-proxy (~20MB)? [Y/n] " confirm
            if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                do_proxy_install
            else
                echo "Skipped. Run 'tailroute proxy install' to download later."
                exit 1
            fi
        fi
    fi
    
    # Create state directory
    mkdir -p "$PROXY_STATE_DIR"
    
    echo "Starting proxy on $PROXY_SOCKS_ADDR..."
    
    # Start proxy in background
    "$PROXY_BIN_PATH" \
        --socks-addr "$PROXY_SOCKS_ADDR" \
        --state-dir "$PROXY_STATE_DIR" \
        >"$HOME/.tailroute/proxy.log" 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PROXY_PID_FILE"
    
    # Wait for port to be ready
    local ready=false
    for _ in $(seq 1 30); do
        if nc -z 127.0.0.1 1055 >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 0.5
    done
    
    if $ready; then
        echo "Proxy started (pid $pid)"
        echo "Listen: $PROXY_SOCKS_ADDR"
        echo ""
        echo "Usage:"
        echo "  ssh -o ProxyCommand='nc -X 5 -x $PROXY_SOCKS_ADDR %h %p' <host>"
        echo "  curl -x socks5h://$PROXY_SOCKS_ADDR <url>"
    else
        echo "WARNING: Proxy started but port not ready yet."
        echo "Check logs: cat ~/.tailroute/proxy.log"
        echo "First run may require Tailscale auth - check log for auth URL."
    fi
}

do_proxy_stop() {
    local pid
    pid=$(get_proxy_pid)
    
    if [[ -z "$pid" ]]; then
        echo "Proxy not running."
        rm -f "$PROXY_PID_FILE"
        return 0
    fi
    
    echo "Stopping proxy (pid $pid)..."
    kill -TERM "$pid" 2>/dev/null || true
    
    # Wait for exit
    for _ in $(seq 1 10); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    
    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    
    rm -f "$PROXY_PID_FILE"
    echo "Proxy stopped."
}

do_proxy_status() {
    echo "SOCKS5 Proxy"
    echo "============"
    
    if is_proxy_installed; then
        echo "Binary:   $PROXY_BIN_PATH"
    elif [[ -x "/usr/local/bin/$PROXY_BIN_NAME" ]]; then
        echo "Binary:   /usr/local/bin/$PROXY_BIN_NAME (system)"
    else
        echo "Binary:   Not installed"
        echo "          Run 'tailroute proxy install' to download"
    fi
    
    echo ""
    
    if is_proxy_running; then
        local pid
        pid=$(get_proxy_pid)
        echo "Status:   Running (pid $pid)"
        echo "Listen:   $PROXY_SOCKS_ADDR"
        
        # Check if port is actually listening
        if nc -z 127.0.0.1 1055 >/dev/null 2>&1; then
            echo "Port:     Open"
        else
            echo "Port:     Not responding (may be starting)"
        fi
    else
        echo "Status:   Stopped"
    fi
    
    echo ""
    if [[ -f "$HOME/.tailroute/proxy.log" ]]; then
        echo "Recent log:"
        tail -5 "$HOME/.tailroute/proxy.log" 2>/dev/null
    fi
}

# =============================================================================
# do_proxy_config — Generate proxy configuration helpers
# =============================================================================
do_proxy_config() {
    local subcommand="${1:-}"
    local socks_addr="127.0.0.1:1055"
    
    case "$subcommand" in
        ssh)
            shift
            do_proxy_config_ssh "$socks_addr" "$@"
            ;;
        shell)
            shift
            do_proxy_config_shell "$socks_addr" "$@"
            ;;
        "")
            echo "ERROR: proxy-config requires subcommand (ssh or shell)"
            echo ""
            echo "Usage:"
            echo "  tailroute proxy-config ssh [user@]<peer> [--identity <key>] [--append <file>]"
            echo "  tailroute proxy-config shell [--append]"
            exit 1
            ;;
        *)
            echo "ERROR: unknown proxy-config subcommand '$subcommand'"
            echo "Valid subcommands: ssh, shell"
            exit 1
            ;;
    esac
}

# =============================================================================
# do_proxy_config_ssh — Generate SSH config for Tailscale peers
# =============================================================================
do_proxy_config_ssh() {
    local socks_addr="$1"
    shift
    local peer_filter=""
    local user_name=""
    local append_file=""
    local identity_file=""
    local ts_status
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --peer)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --peer requires a value" >&2
                    exit 1
                fi
                peer_filter="$2"
                shift 2
                ;;
            --user)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --user requires a value" >&2
                    exit 1
                fi
                user_name="$2"
                shift 2
                ;;
            --identity)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --identity requires a file path" >&2
                    exit 1
                fi
                identity_file="$2"
                shift 2
                ;;
            --append)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --append requires a file path" >&2
                    exit 1
                fi
                append_file="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: tailroute proxy-config ssh [user@]<peer> [--identity <key>] [--append <file>]"
                echo "       tailroute proxy-config ssh [--peer <name>] [--user <name>] [--identity <key>] [--append <file>]"
                return 0
                ;;
            -*)
                echo "ERROR: unknown flag '$1'" >&2
                exit 1
                ;;
            *)
                # Positional arg: [user@]peer
                if [[ -z "$peer_filter" ]]; then
                    if [[ "$1" == *@* ]]; then
                        user_name="${1%%@*}"
                        peer_filter="${1#*@}"
                    else
                        peer_filter="$1"
                    fi
                    shift
                else
                    echo "ERROR: unexpected argument '$1'" >&2
                    exit 1
                fi
                ;;
        esac
    done

    # Get Tailscale status
    ts_status=$(tailscale status --json 2>/dev/null) || {
        echo "ERROR: Failed to get Tailscale status" >&2
        echo "Make sure Tailscale is installed and running." >&2
        exit 1
    }
    
    # Check if logged in
    if ! echo "$ts_status" | grep -q '"Self"'; then
        echo "ERROR: Not logged into Tailscale" >&2
        echo "Run 'tailscale up' to connect." >&2
        exit 1
    fi
    
    local output
    if ! output=$(PEER_FILTER="$peer_filter" USER_NAME="$user_name" IDENTITY_FILE="$identity_file" SOCKS_ADDR="$socks_addr" APPEND_FILE="$append_file" TS_STATUS="$ts_status" python3 - <<'PY'
import os
import sys
import json

peer_filter = os.environ.get("PEER_FILTER", "").strip()
user_name = os.environ.get("USER_NAME", "").strip()
identity_file = os.environ.get("IDENTITY_FILE", "").strip()
socks_addr = os.environ.get("SOCKS_ADDR", "127.0.0.1:1055").strip()
append_file = os.environ.get("APPEND_FILE", "").strip()
ts_status = os.environ.get("TS_STATUS", "")

def parse_proxy_hostnames(path):
    if not path or not os.path.exists(path):
        return set()
    proxy_hosts = set()
    current_hosts = set()
    current_has_proxy = False
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            lower = line.lower()
            if lower.startswith("host "):
                if current_has_proxy:
                    proxy_hosts.update(current_hosts)
                current_hosts = set()
                current_has_proxy = False
                continue
            if lower.startswith("hostname "):
                parts = line.split(None, 1)
                if len(parts) == 2:
                    current_hosts.add(parts[1])
            if lower.startswith("proxycommand "):
                current_has_proxy = True
    if current_has_proxy:
        proxy_hosts.update(current_hosts)
    return proxy_hosts

try:
    data = json.loads(ts_status)
except Exception:
    sys.exit(1)

peers = data.get("Peer", {}) or {}
selected = []

for peer in peers.values():
    hostname = peer.get("HostName", "") or ""
    tailscale_ips = peer.get("TailscaleIPs", []) or []
    # Get first IPv4 address
    tailscale_ip = ""
    for ip in tailscale_ips:
        if ":" not in ip:  # Skip IPv6
            tailscale_ip = ip
            break
    dns_name = (peer.get("DNSName", "") or "").rstrip(".")
    if not hostname or not tailscale_ip:
        continue
    safe_hostname = hostname.replace(" ", "-").lower()
    if peer_filter:
        pf = peer_filter.lower()
        if pf.startswith("proxy-"):
            pf = pf[6:]
        if pf not in {safe_hostname, hostname.lower(), dns_name.lower()}:
            continue
    selected.append((safe_hostname, tailscale_ip))

if peer_filter and not selected:
    print(f"ERROR: peer '{peer_filter}' not found", file=sys.stderr)
    sys.exit(1)

if append_file:
    existing = parse_proxy_hostnames(append_file)
    duplicates = [ip for _, ip in selected if ip in existing]
    if duplicates:
        print("WARNING: ProxyCommand already defined for IP(s): " + ", ".join(sorted(set(duplicates))), file=sys.stderr)

lines = [
    "",
    "# Generated by: tailroute proxy-config ssh",
    "# Append: tailroute proxy-config ssh >> ~/.ssh/config",
    "# Then use: ssh proxy-<hostname> (e.g., ssh proxy-nanoclaw)",
    "# ⚠️  Running twice will create duplicates — check before appending.",
    "",
]

if not selected:
    lines.append("# No peers found")
    lines.append("")
else:
    for safe_hostname, tailscale_ip in selected:
        lines.append(f"Host proxy-{safe_hostname}")
        lines.append(f"    HostName {tailscale_ip}")
        if user_name:
            lines.append(f"    User {user_name}")
        if identity_file:
            home = os.path.expanduser("~")
            display_path = identity_file.replace(home, "~", 1) if identity_file.startswith(home) else identity_file
            lines.append(f"    IdentityFile {display_path}")
            lines.append(f"    IdentitiesOnly yes")
        lines.append(f"    ServerAliveInterval 60")
        lines.append(f"    ServerAliveCountMax 3")
        lines.append(f"    ProxyCommand nc -X 5 -x {socks_addr} %h %p")
        lines.append("")

print("\n".join(lines))
PY
); then
        echo "# Error parsing Tailscale status" >&2
        echo "# Make sure Tailscale is running and you have peers." >&2
        exit 1
    fi

    if [[ -n "$append_file" ]]; then
        touch "$append_file"
        printf "%s\n" "$output" >> "$append_file"
        echo "Appended proxy config to $append_file"
    else
        printf "%s\n" "$output"
    fi
}

# =============================================================================
# do_proxy_config_shell — Generate shell helpers
# =============================================================================
do_proxy_config_shell() {
    local socks_addr="$1"
    shift
    local shell_name
    local append_to_rc="false"
    local socks_host="${socks_addr%:*}"
    local socks_port="${socks_addr##*:}"
    local ts_status
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --append)
                append_to_rc="true"
                shift
                ;;
            --help|-h)
                echo "Usage: tailroute proxy-config shell [--append]"
                return 0
                ;;
            *)
                echo "ERROR: unknown flag '$1'" >&2
                exit 1
                ;;
        esac
    done

    # Detect shell
    case "${SHELL:-}" in
        */zsh) shell_name="zsh" ;;
        */bash) shell_name="bash" ;;
        *) shell_name="bash" ;;
    esac
    
    local peer_list=""
    if ts_status=$(tailscale status --json 2>/dev/null); then
        peer_list=$(echo "$ts_status" | python3 - <<'PY'
import sys
import json

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

peers = data.get("Peer", {}) or {}
suffix = ""
tailnet = data.get("CurrentTailnet") or {}
suffix = tailnet.get("MagicDNSSuffix", "") or data.get("MagicDNSSuffix", "")

names = set()
for peer in peers.values():
    dns = (peer.get("DNSName", "") or "").rstrip(".")
    if dns:
        names.add(dns)
        continue
    hostname = peer.get("HostName", "") or ""
    if hostname and suffix:
        names.add(f"{hostname}.{suffix}".rstrip("."))

if names:
    print(" ".join(sorted(names)))
PY
        ) || peer_list=""
    fi

    local rc_file="$HOME/.${shell_name}rc"

    render_proxy_shell_config() {
        echo "# Generated by: tailroute proxy-config shell"
        echo "# Append: tailroute proxy-config shell >> ~/${shell_name}rc"
        echo "# Then use: sshproxy <hostname> (e.g., sshproxy nanoclaw) or curlproxy <url>"
        if [[ -n "$peer_list" ]]; then
            echo "# Available peers: ${peer_list}"
        else
            echo "# Available peers: see 'tailscale status'"
        fi
        echo ""
        echo "# Check if proxy is running"
        echo "proxy_running() {"
        echo "  nc -z ${socks_host} ${socks_port} >/dev/null 2>&1"
        echo "}"
        echo ""
        echo "# SSH through tailroute SOCKS5 proxy"
        echo "sshproxy() {"
        echo "  if ! proxy_running; then"
        echo "    echo \"Proxy not running - ensure VPN is active, or use direct connections: ssh <hostname>, curl https://<hostname>.ts.net\" >&2"
        echo "    return 1"
        echo "  fi"
        echo "  ssh -o ProxyCommand='nc -X 5 -x ${socks_addr} %h %p' \"\$@\""
        echo "}"
        echo ""
        echo "# curl through tailroute SOCKS5 proxy (socks5h = proxy resolves DNS)"
        echo "curlproxy() {"
        echo "  if ! proxy_running; then"
        echo "    echo \"Proxy not running - ensure VPN is active, or use direct connections: ssh <hostname>, curl https://<hostname>.ts.net\" >&2"
        echo "    return 1"
        echo "  fi"
        echo "  curl -x socks5h://${socks_addr} \"\$@\""
        echo "}"
    }

    if [[ "$append_to_rc" == "true" ]]; then
        if [[ -f "$rc_file" ]]; then
            if grep -q "sshproxy()" "$rc_file" || grep -q "curlproxy()" "$rc_file"; then
                echo "ERROR: sshproxy/curlproxy already defined in $rc_file" >&2
                exit 1
            fi
        fi
        render_proxy_shell_config >> "$rc_file"
        echo "Appended shell helpers to $rc_file"
    else
        render_proxy_shell_config
    fi
}

# =============================================================================
# Main entry point
# =============================================================================
main() {
    local command="${1:---help}"
    
    case "$command" in
        daemon)
            do_daemon
            ;;
        status)
            do_status
            ;;
        --dry-run)
            do_dry_run
            ;;
        --version|-V)
            show_version
            exit 0
            ;;
        install)
            do_install
            ;;
        uninstall)
            do_uninstall
            ;;
        proxy)
            shift
            do_proxy "$@"
            ;;
        proxy-config)
            shift
            do_proxy_config "$@"
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "ERROR: unknown command '$command'"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
