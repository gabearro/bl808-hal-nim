#!/bin/bash
# Recover working-tree files lost between session start and the latest APFS local snapshot.
# REQUIRES SUDO (mount_apfs needs root).
#
# Usage:
#   sudo ./.recover_from_snapshot.sh           # interactive — preview, then prompt before restoring
#   sudo ./.recover_from_snapshot.sh --apply   # restore without prompt
#   sudo ./.recover_from_snapshot.sh --dry-run # show what would change, no writes
#
# Snapshots used: latest "*.local" snapshot on the Data volume (per `tmutil listlocalsnapshots /System/Volumes/Data`)
# Mounts to: /tmp/bl808_snapshot_mount
# Inspects:  /tmp/bl808_snapshot_mount/Users/gabriel/Documents/nimlang/bl808-hal
# Restores:  to current working dir (/Users/gabriel/Documents/nimlang/bl808-hal)
#
# Safe-by-default behavior:
#   - Does NOT touch any committed-tracked file that's identical between snapshot and working tree
#   - Does NOT touch git index / objects / refs
#   - Restores only files where snapshot version differs from working tree version
#   - Defaults to interactive mode (you confirm each restore)

set -euo pipefail

REPO=/Users/gabriel/Documents/nimlang/bl808-hal
MOUNT=/tmp/bl808_snapshot_mount

if [ "$(id -u)" != "0" ]; then
  echo "Error: this script must run as root (mount_apfs requires it)."
  echo "Re-run as: sudo $0 $*"
  exit 1
fi

MODE=interactive
SNAPSHOT=""
for arg in "$@"; do
  case "$arg" in
    --apply) MODE=apply ;;
    --dry-run) MODE=dry ;;
    --snapshot=*) SNAPSHOT="${arg#--snapshot=}" ;;
    com.apple.TimeMachine.*) SNAPSHOT="$arg" ;;
    *) echo "Unknown arg: $arg"; echo "Usage: $0 [--dry-run|--apply] [--snapshot=NAME]"; exit 1 ;;
  esac
done

if [ -n "$SNAPSHOT" ]; then
  LATEST="$SNAPSHOT"
  # Verify it exists
  if ! tmutil listlocalsnapshots /System/Volumes/Data 2>&1 | grep -q "^${LATEST}$"; then
    echo "Error: snapshot $LATEST not found on Data volume."
    echo "Available snapshots:"
    tmutil listlocalsnapshots /System/Volumes/Data 2>&1 | grep '^com.apple.TimeMachine'
    exit 1
  fi
else
  # Pick the latest local snapshot on the Data volume
  LATEST=$(tmutil listlocalsnapshots /System/Volumes/Data 2>&1 | grep '^com.apple.TimeMachine' | tail -1)
  if [ -z "$LATEST" ]; then
    echo "Error: no local APFS snapshots found on /System/Volumes/Data"
    exit 1
  fi
fi
echo "Using snapshot: $LATEST"

mkdir -p "$MOUNT"
# Unmount if previously mounted
mount | grep -q " on $MOUNT " && umount "$MOUNT" || true

# Mount the snapshot read-only
echo "Mounting $LATEST -> $MOUNT (read-only)..."
mount_apfs -s "$LATEST" -o ro,nobrowse /System/Volumes/Data "$MOUNT"
trap 'umount "$MOUNT" 2>/dev/null || true' EXIT

SNAP_REPO="$MOUNT/Users/gabriel/Documents/nimlang/bl808-hal"
if [ ! -d "$SNAP_REPO" ]; then
  echo "Error: $SNAP_REPO not found in snapshot. Wrong snapshot?"
  exit 1
fi

cd "$REPO"

# Find candidates: every regular file in the snapshot that exists in the snapshot AND
#   - is missing from working tree, OR
#   - has different content than working tree
# Excludes: build/, .git/, anything under .recover_*

DIFFLIST=$(mktemp)
diff -rq --no-dereference \
  --exclude='.git' --exclude='build' --exclude='.recover_*' --exclude='.venv' \
  --exclude='__pycache__' --exclude='.pytest_cache' \
  "$SNAP_REPO" "$REPO" 2>&1 | grep -E '^(Only in '"$SNAP_REPO"'|Files .* differ)$' || true > "$DIFFLIST"

# Re-run the diff and capture properly
diff -rq --no-dereference \
  --exclude='.git' --exclude='build' --exclude='.recover_*' --exclude='.venv' \
  --exclude='__pycache__' --exclude='.pytest_cache' \
  "$SNAP_REPO" "$REPO" 2>&1 | grep -E '(^Only in|^Files .* differ)' > "$DIFFLIST" || true

if [ ! -s "$DIFFLIST" ]; then
  echo "No differences between snapshot and working tree. Nothing to recover."
  exit 0
fi

# Build a list of (snapshot_path, repo_path, status) tuples
RESTORE_LIST=$(mktemp)
while IFS= read -r line; do
  if [[ "$line" =~ ^Only\ in\ ${SNAP_REPO}(.*):\ (.+)$ ]]; then
    DIR="${BASH_REMATCH[1]}"
    NAME="${BASH_REMATCH[2]}"
    SRC="$SNAP_REPO$DIR/$NAME"
    DST="$REPO$DIR/$NAME"
    if [ -d "$SRC" ]; then
      # Recurse into directory
      while IFS= read -r f; do
        rel="${f#$SNAP_REPO/}"
        echo -e "MISSING_FROM_WT\t$f\t$REPO/$rel"
      done < <(find "$SRC" -type f)
    else
      echo -e "MISSING_FROM_WT\t$SRC\t$DST"
    fi
  elif [[ "$line" =~ ^Files\ (.+)\ and\ (.+)\ differ$ ]]; then
    SRC="${BASH_REMATCH[1]}"
    DST="${BASH_REMATCH[2]}"
    echo -e "MODIFIED_IN_WT\t$SRC\t$DST"
  fi
done < "$DIFFLIST" > "$RESTORE_LIST"

# Show summary
TOTAL=$(wc -l < "$RESTORE_LIST" | tr -d ' ')
MISSING=$(grep -c '^MISSING_FROM_WT' "$RESTORE_LIST" || echo 0)
MODIFIED=$(grep -c '^MODIFIED_IN_WT' "$RESTORE_LIST" || echo 0)
echo ""
echo "============================================================"
echo "Recovery candidates: $TOTAL files"
echo "  Missing from working tree (snapshot has them):  $MISSING"
echo "  Modified in working tree (snapshot has older):  $MODIFIED"
echo "============================================================"
echo ""
echo "Per-file size diff (snapshot vs working tree, in bytes):"
echo ""
printf "%-12s  %12s  %12s  %s\n" "STATUS" "SNAPSHOT_B" "WT_B" "PATH"
while IFS=$'\t' read -r status src dst; do
  src_size=$(stat -f%z "$src" 2>/dev/null || echo 0)
  dst_size=$(stat -f%z "$dst" 2>/dev/null || echo 0)
  rel="${dst#$REPO/}"
  printf "%-12s  %12s  %12s  %s\n" "$status" "$src_size" "$dst_size" "$rel"
done < "$RESTORE_LIST"

if [ "$MODE" = "dry" ]; then
  echo ""
  echo "Dry run; no files written."
  exit 0
fi

if [ "$MODE" = "interactive" ]; then
  echo ""
  read -p "Restore all $TOTAL files from snapshot? [y/N] " yn
  case "$yn" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# Apply
RESTORED=0
while IFS=$'\t' read -r status src dst; do
  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"
  # Match working-dir owner so user can edit afterwards
  chown gabriel:staff "$dst"
  RESTORED=$((RESTORED + 1))
done < "$RESTORE_LIST"

echo ""
echo "Restored $RESTORED files. Unmounting snapshot."
echo ""
echo "Verify with: cd $REPO && git status --short | head -20"
