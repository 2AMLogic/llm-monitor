#!/usr/bin/env bash
# Exercise upgrades without touching the user's home or systemd session.
set -euo pipefail
installer="$(dirname "$0")/install-linux.sh"
fixture=$(mktemp -d)
test_home="$fixture/home"
cleanup() {
    if [[ -f "$test_home/service.pid" ]]; then
        pid=$(cat "$test_home/service.pid" 2>/dev/null || true)
        if [[ -n "${pid:-}" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
    rm -rf "$fixture"
}
trap cleanup EXIT

bin="$test_home/.local/bin"
data="$test_home/.llm-monitor"
legacy="$test_home/.claude-monitor"
mkdir -p "$bin" "$data" "$fixture/stubs"

cat > "$fixture/stubs/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$HOME/systemctl.log"
start_daemon() {
    "$HOME/.local/bin/llm-monitor" </dev/null >/dev/null 2>&1 &
    echo "$!" > "$HOME/service.pid"
}
stop_daemon() {
    if [ -f "$HOME/service.pid" ]; then
        pid=$(cat "$HOME/service.pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            while kill -0 "$pid" 2>/dev/null; do
                sleep 0.01
            done
        fi
        rm -f "$HOME/service.pid"
    fi
}
live_pid() {
    if [ -f "$HOME/service.pid" ]; then
        pid=$(cat "$HOME/service.pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return
        fi
    fi
    echo 0
}
case "$*" in
    "--user show-environment")
        [ ! -f "$HOME/deny-systemd" ]
        ;;
    "--user show -p MainPID --value llm-monitor.service")
        live_pid
        ;;
    "--user enable --now llm-monitor.service")
        if [ "$(live_pid)" = "0" ]; then
            start_daemon
        fi
        ;;
    "--user restart llm-monitor.service")
        stop_daemon
        start_daemon
        ;;
    "--user status llm-monitor.service --no-pager")
        echo "Active: active (running) ( MainPID=$(live_pid) )"
        ;;
esac
STUB

cat > "$fixture/stubs/loginctl" <<'STUB'
#!/bin/sh
echo yes
STUB
chmod +x "$fixture/stubs/"*

cat > "$fixture/candidate.c" <<'CSRC'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

__attribute__((used)) static const char build_tag[] = BUILD_TAG;

int main(int argc, char **argv) {
    if (argc == 1) {
        for (;;) pause();
    }
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("llm-monitor 2.2.0");
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "selftest") == 0) {
        return 0;
    }
    return 1;
}
CSRC

build_candidate() {
    local tag="$1"
    if command -v cc >/dev/null 2>&1; then
        cc -O0 -DBUILD_TAG="\"$tag\"" "$fixture/candidate.c" -o "$fixture/candidate"
    else
        cat > "$fixture/candidate" <<STUB
#!/bin/sh
# build: $tag
if [ "\$#" -eq 0 ]; then
    exec sleep 300
fi
case "\$1" in
    --version) echo 'llm-monitor 2.2.0' ;;
    selftest) exit 0 ;;
    *) exit 1 ;;
esac
STUB
        chmod +x "$fixture/candidate"
    fi
}

running_exe_id() {
    local pid
    pid=$(cat "$test_home/service.pid")
    if [[ "$(LC_ALL=C head -c 2 "$bin/llm-monitor")" == '#!' ]]; then
        local fd target
        for fd in "/proc/$pid/fd"/*; do
            [[ -L "$fd" ]] || continue
            target=$(readlink -- "$fd" 2>/dev/null || true)
            if [[ "$target" == "$bin/llm-monitor" || "$target" == "$bin/llm-monitor (deleted)" ]]; then
                stat -Lc '%d:%i' "$fd"
                return
            fi
        done
    fi
    stat -Lc '%d:%i' "/proc/$pid/exe"
}

run_install() {
    HOME="$test_home" PATH="$fixture/stubs:$PATH" bash "$installer" --binary "$fixture/candidate" > "$fixture/output" 2>&1 || {
        cat "$fixture/output" >&2
        return 1
    }
}

run_install_expect_fail() {
    if HOME="$test_home" PATH="$fixture/stubs:$PATH" bash "$installer" --binary "$fixture/candidate" > "$fixture/output" 2>&1; then
        echo "Expected installer to fail, but it succeeded:" >&2
        cat "$fixture/output" >&2
        exit 1
    fi
}

# An older executable can have the same version and still require replacement.
build_candidate "older-build"
cp "$fixture/candidate" "$bin/llm-monitor"
build_candidate "build-1"
ln -s llm-monitor "$bin/claude-monitor"
ln -s .llm-monitor "$legacy"
echo marker > "$data/marker"
run_install
cmp "$fixture/candidate" "$bin/llm-monitor"
test ! -L "$bin/claude-monitor"
test ! -L "$legacy"
test "$(cat "$data/marker")" = marker
test "$(running_exe_id)" = "$(stat -Lc '%d:%i' "$bin/llm-monitor")"

# A different build restarts an already-configured unit. An identical one skips both steps.
build_candidate "build-2"
: > "$test_home/systemctl.log"
run_install
cmp "$fixture/candidate" "$bin/llm-monitor"
grep -Fxq -- '--user restart llm-monitor.service' "$test_home/systemctl.log"
test "$(running_exe_id)" = "$(stat -Lc '%d:%i' "$bin/llm-monitor")"
: > "$test_home/systemctl.log"
before_inode=$(stat -Lc '%d:%i' "$bin/llm-monitor")
before_pid=$(cat "$test_home/service.pid")
run_install
test "$(stat -Lc '%d:%i' "$bin/llm-monitor")" = "$before_inode"
test "$(cat "$test_home/service.pid")" = "$before_pid"
grep -Fq 'skipping reinstall' "$fixture/output"
grep -Fq 'Nothing changed this run' "$fixture/output"
if grep -Fq -- '--user restart' "$test_home/systemctl.log"; then
    echo 'Identical binary triggered a restart' >&2
    exit 1
fi

# An upgrade interrupted when the user systemd session is unreachable finishes
# restarting the active service on retry, then returns to a no-op when healthy.
build_candidate "build-3-interrupted"
old_pid=$(cat "$test_home/service.pid")
old_inode=$(stat -Lc '%d:%i' "$bin/llm-monitor")
touch "$test_home/deny-systemd"
run_install_expect_fail
cmp "$fixture/candidate" "$bin/llm-monitor"
new_inode=$(stat -Lc '%d:%i' "$bin/llm-monitor")
test "$new_inode" != "$old_inode"
test "$(cat "$test_home/service.pid")" = "$old_pid"
test "$(running_exe_id)" = "$old_inode"

rm -f "$test_home/deny-systemd"
: > "$test_home/systemctl.log"
run_install
grep -Fq 'skipping reinstall' "$fixture/output"
grep -Fxq -- '--user restart llm-monitor.service' "$test_home/systemctl.log"
restarted_pid=$(cat "$test_home/service.pid")
test "$restarted_pid" != "$old_pid"
test "$(running_exe_id)" = "$new_inode"

: > "$test_home/systemctl.log"
run_install
test "$(cat "$test_home/service.pid")" = "$restarted_pid"
grep -Fq 'Nothing changed this run' "$fixture/output"
if grep -Fq -- '--user restart' "$test_home/systemctl.log"; then
    echo 'Healthy post-retry service triggered a restart' >&2
    exit 1
fi

# Even without a pending-restart marker (e.g. an earlier installer or manual
# copy replaced the binary while the service kept running), a rerun detects the
# stale running executable and restarts the unit once.
build_candidate "build-4-external-swap"
cp "$fixture/candidate" "$bin/llm-monitor.swap"
mv -fT "$bin/llm-monitor.swap" "$bin/llm-monitor"
test ! -e "$test_home/.config/systemd/user/.llm-monitor.service.restart-pending"
test "$(running_exe_id)" = "$new_inode"
swap_inode=$(stat -Lc '%d:%i' "$bin/llm-monitor")
test "$swap_inode" != "$new_inode"
: > "$test_home/systemctl.log"
run_install
grep -Fq 'skipping reinstall' "$fixture/output"
grep -Fxq -- '--user restart llm-monitor.service' "$test_home/systemctl.log"
test "$(running_exe_id)" = "$swap_inode"

: > "$test_home/systemctl.log"
run_install
if grep -Fq -- '--user restart' "$test_home/systemctl.log"; then
    echo 'Healthy post-swap service triggered a restart' >&2
    exit 1
fi

# An interrupted unit-file update also finishes restarting on retry.
printf '\n# local comment\n' >> "$test_home/.config/systemd/user/llm-monitor.service"
touch "$test_home/deny-systemd"
run_install_expect_fail
rm -f "$test_home/deny-systemd"
: > "$test_home/systemctl.log"
run_install
grep -Fxq -- '--user restart llm-monitor.service' "$test_home/systemctl.log"
: > "$test_home/systemctl.log"
run_install
if grep -Fq -- '--user restart' "$test_home/systemctl.log"; then
    echo 'Healthy post-unit-retry service triggered a restart' >&2
    exit 1
fi

# Preserve a working canonical path that reaches external storage via the old name.
mv "$data" "$test_home/storage"
ln -s storage "$legacy"
ln -s .claude-monitor "$data"
run_install
grep -Fq "Data directory conflict at $legacy" "$fixture/output"
test "$(readlink "$legacy")" = storage
test "$(cat "$data/marker")" = marker
