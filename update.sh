#!/bin/bash
# Upgrade brave-origin-nightly from apt first, then from the latest GitHub
# release asset when the apt repo is stale. Called by control.py for
# POST /api/update; output is captured in /root/.vnc/update.log.

set +e
export DEBIAN_FRONTEND=noninteractive

version_from_output() {
    # "Brave Origin Nightly 150.1.93.75 nightly" -> "1.93.75"
    echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+( nightly)?$' | sed -E 's/ nightly$//'
}

github_latest_deb() {
    curl -fsSL "https://api.github.com/repos/brave/brave-browser/releases?per_page=30" \
        | grep -oE 'https://[^"]+brave-origin-nightly_[0-9.]+_amd64\.deb' \
        | head -1
}

version_from_deb_url() {
    echo "$1" | sed -nE 's|.*/brave-origin-nightly_([0-9.]+)_amd64\.deb.*|\1|p'
}

try_github_fallback() {
    reason="$1"
    current_output="$2"
    current_version=$(version_from_output "$current_output")

    echo "[update] checking GitHub fallback ($reason)..."
    BRAVE_URL=$(github_latest_deb)
    latest_version=$(version_from_deb_url "$BRAVE_URL")

    if [ -z "$BRAVE_URL" ] || [ -z "$latest_version" ]; then
        echo "[update] could not locate a GitHub .deb"
        return 1
    fi

    echo "[update] GitHub latest: $latest_version"
    if [ -n "$current_version" ] && ! dpkg --compare-versions "$latest_version" gt "$current_version"; then
        echo "[update] GitHub is not newer than installed $current_version"
        return 2
    fi

    echo "[update] downloading $BRAVE_URL"
    if curl -fL --progress-bar -o /tmp/brave-upgrade.deb "$BRAVE_URL" 2>&1; then
        apt-get install -y /tmp/brave-upgrade.deb 2>&1
        apt_rc=$?
        rm -f /tmp/brave-upgrade.deb
        installed_after=$(brave-origin-nightly --version 2>/dev/null || echo unknown)
        echo "[update] installed after fallback: $installed_after"
        if [ $apt_rc -ne 0 ]; then
            echo "[update] fallback install failed with exit $apt_rc"
            return $apt_rc
        fi
        return 0
    else
        echo "[update] download failed"
        return 1
    fi
}

installed_before=$(brave-origin-nightly --version 2>/dev/null || echo unknown)
echo "[update] installed before: $installed_before"

echo "[update] apt-get update..."
apt-get update -qq 2>&1

candidate=$(apt-cache policy brave-origin-nightly 2>/dev/null | awk '/Candidate:/ {print $2}')
echo "[update] apt candidate: ${candidate:-none}"

echo "[update] apt-get install --only-upgrade brave-origin-nightly..."
apt-get install -y --only-upgrade brave-origin-nightly 2>&1
apt_rc=$?
echo "[update] apt-get exit: $apt_rc"

installed_after=$(brave-origin-nightly --version 2>/dev/null || echo unknown)
echo "[update] installed after: $installed_after"

update_failed=0
if [ $apt_rc -ne 0 ]; then
    try_github_fallback "apt exited $apt_rc" "$installed_after"
    fallback_rc=$?
    if [ $fallback_rc -ne 0 ] && [ $fallback_rc -ne 2 ]; then
        update_failed=1
    fi
elif [ "$installed_before" = "$installed_after" ]; then
    try_github_fallback "apt reported no upgrade" "$installed_after"
    fallback_rc=$?
    if [ $fallback_rc -ne 0 ] && [ $fallback_rc -ne 2 ]; then
        update_failed=1
    fi
fi

if [ "$installed_before" = "$installed_after" ]; then
    if [ $update_failed -ne 0 ]; then
        echo "[update] update failed"
        exit 1
    fi
    echo "[update] no newer version available"
    exit 0
fi

if [ $update_failed -ne 0 ]; then
    echo "[update] update failed after version changed; check package manager output above"
    exit 1
fi

echo "[update] upgraded: $installed_before  ->  $installed_after"
echo "[update] NOTE: the running Brave is still the old version - shut down"
echo "[update]       the app and relaunch Brave.exe to pick up the new one."
exit 0
