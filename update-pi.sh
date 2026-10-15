#!/bin/bash
#
# Bring an AlarmDecoder Pi up to date with the -E patches in this repo.
#
# Run as the pi user (not with sudo) from a clone of this repo:
#   ~/alarmdecoder-e/update-pi.sh            pull this repo, then patch and restart
#   ~/alarmdecoder-e/update-pi.sh --check    report what would change, change nothing
#
# Each patch is cumulative (upstream -> current -E build).  If an older version
# of a patch is installed it is reversed first, then the new one applied.  If
# anything does not apply cleanly the script stops and puts back what it took
# off, so the Pi is never left half patched.

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.alarmdecoder-e"
WEBAPP_DIR=/opt/alarmdecoder-webapp
PYTHON=python          # the webapp runs on Python 2.7

CHECK=0
NO_PULL=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1 ;;
        --no-pull) NO_PULL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as pi, not root (it uses sudo where needed)"

# Update this repo first, then re-run the (possibly new) copy of this script.
if [ "$NO_PULL" -eq 0 ]; then
    say "Pulling $REPO_DIR"
    git -C "$REPO_DIR" pull --ff-only
    exec bash "$REPO_DIR/update-pi.sh" --no-pull "$@"
fi

LIB_DIR="$($PYTHON -c 'import alarmdecoder, os; print(os.path.dirname(os.path.dirname(alarmdecoder.__file__)))')" \
    || die "could not import the alarmdecoder library with $PYTHON"
[ -d "$WEBAPP_DIR/.git" ] || die "$WEBAPP_DIR is not a git checkout"

mkdir -p "$STATE_DIR"

# --- patch helpers: <kind> <check|apply> <fwd|rev> <patch> -------------------
# kind "lib" patches the installed library with patch(1) as root,
# kind "web" patches the webapp checkout with git apply as pi.
run_patch() {
    local kind=$1 mode=$2 dir=$3 file=$4 rev=()
    if [ "$kind" = lib ]; then
        [ "$dir" = rev ] && rev=(-R)
        if [ "$mode" = check ]; then
            sudo patch --dry-run -s -f -p1 "${rev[@]}" -d "$LIB_DIR" -i "$file" >/dev/null 2>&1
        else
            sudo patch -s -f -p1 --no-backup-if-mismatch "${rev[@]}" -d "$LIB_DIR" -i "$file"
        fi
    else
        [ "$dir" = rev ] && rev=(-R)
        if [ "$mode" = check ]; then
            git -C "$WEBAPP_DIR" apply --check "${rev[@]}" "$file" >/dev/null 2>&1
        else
            git -C "$WEBAPP_DIR" apply "${rev[@]}" "$file"
        fi
    fi
}

# update_component <kind> <name> <new patch> <older patches...>
# Sets CHANGED=1 when it modified something.
CHANGED=0
update_component() {
    local kind=$1 name=$2 new=$3; shift 3
    local record="$STATE_DIR/$name.patch" old=""

    if run_patch "$kind" check rev "$new"; then
        say "$name: up to date"
        [ "$CHECK" -eq 1 ] || cp "$new" "$record"
        return 0
    fi

    # Find which older version is installed, if any.
    local candidate
    for candidate in "$record" "$@"; do
        if [ -f "$candidate" ] && run_patch "$kind" check rev "$candidate"; then
            old=$candidate
            break
        fi
    done

    if [ "$CHECK" -eq 1 ]; then
        if [ -n "$old" ]; then
            say "$name: would replace installed patch ($(basename "$old")) with the new one"
        elif run_patch "$kind" check fwd "$new"; then
            say "$name: would apply patch"
        else
            say "$name: patch does NOT apply cleanly; an update would stop here"
        fi
        return 0
    fi

    if [ -n "$old" ]; then
        say "$name: removing installed patch ($(basename "$old"))"
        run_patch "$kind" apply rev "$old"
    fi

    if ! run_patch "$kind" check fwd "$new"; then
        if [ -n "$old" ]; then
            say "$name: new patch does not apply; restoring the previous one"
            run_patch "$kind" apply fwd "$old"
        fi
        die "$name: $(basename "$new") does not apply cleanly to this Pi's files"
    fi

    say "$name: applying $(basename "$new")"
    run_patch "$kind" apply fwd "$new"
    cp "$new" "$record"
    CHANGED=1

    # Python 2 trusts a .pyc whose recorded source mtime matches to the second,
    # so a patch made right after an install can be ignored.  Recompile.
    if [ "$kind" = lib ]; then
        sudo $PYTHON -m compileall -q -f "$LIB_DIR/alarmdecoder" >/dev/null
    else
        $PYTHON -m compileall -q -f "$WEBAPP_DIR/ad2web" >/dev/null
    fi
}

# --- webapp ----------------------------------------------------------------
if [ -n "$(git -C "$WEBAPP_DIR" status --porcelain --untracked-files=no)" ]; then
    git -C "$WEBAPP_DIR" status --short --untracked-files=no
    die "$WEBAPP_DIR has uncommitted changes; commit or discard them first"
fi

WEB_BEFORE=$CHANGED
update_component web webapp "$REPO_DIR/patches/webapp.patch" \
    "$REPO_DIR/patches/legacy/email-throttle.patch"

if [ "$CHANGED" -ne "$WEB_BEFORE" ]; then
    # Committed so the webapp's own Update button (git merge) keeps working.
    git -C "$WEBAPP_DIR" -c user.name=pi -c user.email=pi@localhost \
        commit -q -am "AlarmDecoder -E patches ($(git -C "$REPO_DIR" rev-parse --short HEAD))"
fi

# --- library ---------------------------------------------------------------
say "Library installed at $LIB_DIR"
update_component lib library "$REPO_DIR/patches/library.patch" \
    "$REPO_DIR/patches/legacy/zone-expire-scaling.patch"

# --- finish ----------------------------------------------------------------
LIB_VERSION="$($PYTHON -c 'import alarmdecoder; print(getattr(alarmdecoder, "__version__", "unknown"))')"
WEB_VERSION="$(sed -n "s/^WEBAPP_VERSION = '\(.*\)'/\1/p" "$WEBAPP_DIR/ad2web/updater/models.py")"
say "Library version: $LIB_VERSION   Webapp version: ${WEB_VERSION:-unknown}"

if [ "$CHECK" -eq 1 ]; then
    say "Check only; nothing was changed"
elif [ "$CHANGED" -eq 1 ]; then
    say "Restarting gunicorn"
    sudo systemctl restart gunicorn
    sleep 3
    systemctl is-active --quiet gunicorn || die "gunicorn did not start; see: sudo journalctl -u gunicorn -n 50"
    say "Done; gunicorn is running"
else
    say "Nothing to do"
fi
