#!/usr/bin/env bash
# Exercise upgrades without touching the user's home or systemd session.
set -euo pipefail
installer="$(dirname "$0")/install-linux.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
test_home="$fixture/home"
bin="$test_home/.local/bin"
data="$test_home/.llm-monitor"
legacy="$test_home/.claude-monitor"
mkdir -p "$bin" "$data" "$fixture/stubs"

cat > "$fixture/stubs/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$HOME/systemctl.log"
STUB
cat > "$fixture/stubs/loginctl" <<'STUB'
#!/bin/sh
echo yes
STUB
cat > "$fixture/candidate" <<'STUB'
#!/bin/sh
case "$1" in
    --version) echo 'llm-monitor 2.2.0' ;;
    selftest) exit 0 ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$fixture/stubs/"* "$fixture/candidate"
run_install() {
    HOME="$test_home" PATH="$fixture/stubs:$PATH" bash "$installer" --binary "$fixture/candidate" > "$fixture/output" 2>&1 || {
        cat "$fixture/output" >&2
        return 1
    }
}

# An older executable can have the same version and still require replacement.
cp "$fixture/candidate" "$bin/llm-monitor"
echo '# older build' >> "$bin/llm-monitor"
ln -s llm-monitor "$bin/claude-monitor"
ln -s .llm-monitor "$legacy"
echo marker > "$data/marker"
run_install
cmp "$fixture/candidate" "$bin/llm-monitor"
test ! -L "$bin/claude-monitor"
test ! -L "$legacy"
test "$(cat "$data/marker")" = marker

# A different build restarts an already-configured unit. An identical one skips both steps.
echo '# next build, same version' >> "$fixture/candidate"
: > "$test_home/systemctl.log"
run_install
cmp "$fixture/candidate" "$bin/llm-monitor"
grep -Fxq -- '--user restart llm-monitor.service' "$test_home/systemctl.log"
: > "$test_home/systemctl.log"
before=$(stat -c %i "$bin/llm-monitor")
run_install
test "$(stat -c %i "$bin/llm-monitor")" = "$before"
grep -Fq 'skipping reinstall' "$fixture/output"
if grep -Fq -- '--user restart' "$test_home/systemctl.log"; then
    echo 'Identical binary triggered a restart' >&2
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
