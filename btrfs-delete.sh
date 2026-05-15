#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

DRY_RUN=true
MEASURE_SPACE=false
SNAPSHOTS_ONLY=false
VOLUME=""
TARGET_INPUT=""

declare -a SNAPSHOT_SELECTORS=()
declare -a SELECTED_SNAPSHOT_IDS=()
declare -a TARGET_PATHS=()
declare -a TARGET_SNAPSHOT_ROOTS=()
declare -a RESTORE_RO=()

MATCHES=0
DELETED=0
FAILURES=0

usage() {
    cat <<'EOF'
Usage: btrfs-delete.sh [OPTIONS] PATH

Delete PATH from a live Btrfs subvolume and from Snapper-style snapshots
under MOUNTPOINT/.snapshots/*/snapshot.

Default mode is --dry-run. Nothing is removed unless --execute is used.

Options:
  -n, --dry-run             Show planned actions without deleting anything.
  -x, --execute             Delete matching files/directories.
      --measure-space       Report pre-delete btrfs du totals for matched paths.
                            With --execute, also report actual used-space delta.
      --snapshots-only      Delete only from snapshots, keep the live path.
      --snapshot ID|A-B     Delete only from selected Snapper snapshot ID/range.
                            Can be repeated. Selected snapshots keep live path.
  -v, --volume PATH         Use this Btrfs mountpoint instead of auto-detecting it.
  -h, --help                Show this help.
EOF
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

progress() {
    printf '%s\n' "$*" >&2
}

human_bytes() {
    local bytes=$1
    local sign=""
    local scaled whole tenth unit_index
    local -a units=("B" "KiB" "MiB" "GiB" "TiB" "PiB")

    if ((bytes < 0)); then
        sign="-"
        scaled=$((-bytes))
    else
        scaled=$bytes
    fi

    unit_index=0
    if ((scaled < 1024)); then
        printf '%s%d %s\n' "$sign" "$scaled" "${units[$unit_index]}"
        return 0
    fi

    scaled=$((scaled * 10))
    while ((scaled >= 10240 && unit_index < ${#units[@]} - 1)); do
        scaled=$(((scaled + 512) / 1024))
        ((unit_index += 1))
    done

    whole=$((scaled / 10))
    tenth=$((scaled % 10))
    printf '%s%d.%d %s\n' "$sign" "$whole" "$tenth" "${units[$unit_index]}"
}

format_bytes() {
    local bytes=$1

    printf '%s bytes (%s)\n' "$bytes" "$(human_bytes "$bytes")"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

restore_readonly_stack() {
    local path

    set +e
    for path in "${RESTORE_RO[@]}"; do
        if [[ -n "$path" ]]; then
            if ! btrfs property set "$path" ro true >/dev/null 2>&1; then
                printf 'warning: failed to restore read-only snapshot: %s\n' "$path" >&2
            fi
        fi
    done
    RESTORE_RO=()
}

trap restore_readonly_stack EXIT
trap 'restore_readonly_stack; exit 130' INT
trap 'restore_readonly_stack; exit 143' TERM

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

canonical_path() {
    realpath -m -s -- "$1"
}

strip_trailing_slash() {
    local path=$1

    if [[ "$path" != "/" ]]; then
        path=${path%/}
    fi

    printf '%s\n' "$path"
}

nearest_existing_ancestor() {
    local path=$1

    while [[ "$path" != "/" && ! -e "$path" && ! -L "$path" ]]; do
        path=${path%/*}
        [[ -n "$path" ]] || path="/"
    done

    printf '%s\n' "$path"
}

findmnt_field() {
    local path=$1
    local field=$2

    findmnt -T "$path" -n -o "$field" 2>/dev/null | sed -n '1p'
}

mount_for_path() {
    local path=$1
    local mountpoint

    mountpoint=$(findmnt_field "$path" TARGET)
    [[ -n "$mountpoint" ]] || return 1
    canonical_path "$mountpoint"
}

fstype_for_path() {
    local path=$1

    findmnt_field "$path" FSTYPE
}

relative_to_mountpoint() {
    local path=$1
    local mountpoint=$2

    if [[ "$mountpoint" == "/" ]]; then
        printf '%s\n' "${path#/}"
        return 0
    fi

    case "$path" in
        "$mountpoint")
            printf '\n'
            ;;
        "$mountpoint"/*)
            printf '%s\n' "${path#"$mountpoint"/}"
            ;;
        *)
            return 1
            ;;
    esac
}

join_path() {
    local base=$1
    local rel=$2

    if [[ "$base" == "/" ]]; then
        printf '/%s\n' "$rel"
    else
        printf '%s/%s\n' "$base" "$rel"
    fi
}

join_by_space() {
    local IFS=' '

    printf '%s\n' "$*"
}

has_symlink_ancestor() {
    local mountpoint=$1
    local rel=$2
    local current=$mountpoint
    local -a parts
    local last_index
    local i

    IFS=/ read -r -a parts <<<"$rel"
    last_index=$((${#parts[@]} - 1))

    for ((i = 0; i < last_index; i++)); do
        [[ -n "${parts[$i]}" ]] || continue
        current=$(join_path "$current" "${parts[$i]}")

        if [[ -L "$current" ]]; then
            return 0
        fi

        [[ -e "$current" ]] || break
    done

    return 1
}

snapshot_id_seen() {
    local id=$1
    local existing

    for existing in "${SELECTED_SNAPSHOT_IDS[@]}"; do
        [[ "$existing" == "$id" ]] && return 0
    done

    return 1
}

add_snapshot_id() {
    local id=$1

    if ! snapshot_id_seen "$id"; then
        SELECTED_SNAPSHOT_IDS+=("$id")
    fi
}

expand_snapshot_selectors() {
    local selector start end id

    for selector in "${SNAPSHOT_SELECTORS[@]}"; do
        if [[ "$selector" =~ ^[0-9]+$ ]]; then
            add_snapshot_id "$((10#$selector))"
        elif [[ "$selector" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}

            if ((10#$start > 10#$end)); then
                die "invalid snapshot range: $selector"
            fi

            for ((id = 10#$start; id <= 10#$end; id++)); do
                add_snapshot_id "$id"
            done
        else
            die "invalid snapshot selector: $selector"
        fi
    done
}

add_target_if_exists() {
    local target=$1
    local snapshot_root=${2:-}

    if [[ -e "$target" || -L "$target" ]]; then
        TARGET_PATHS+=("$target")
        TARGET_SNAPSHOT_ROOTS+=("$snapshot_root")
    fi
}

collect_snapshot_targets() {
    local snapshot_dir=$1
    local rel_path=$2
    local snapshot_root snapshot_target id

    if ((${#SNAPSHOT_SELECTORS[@]} > 0)); then
        [[ -d "$snapshot_dir" ]] || die "snapshot directory not found: $snapshot_dir"

        expand_snapshot_selectors

        for id in "${SELECTED_SNAPSHOT_IDS[@]}"; do
            snapshot_root="$snapshot_dir/$id/snapshot"
            [[ -d "$snapshot_root" ]] || die "selected snapshot not found: $id ($snapshot_root)"
            snapshot_target=$(join_path "$snapshot_root" "$rel_path")
            add_target_if_exists "$snapshot_target" "$snapshot_root"
        done
        return 0
    fi

    if [[ -d "$snapshot_dir" ]]; then
        while IFS= read -r -d '' snapshot_root; do
            snapshot_target=$(join_path "$snapshot_root" "$rel_path")
            add_target_if_exists "$snapshot_target" "$snapshot_root"
        done < <(find "$snapshot_dir" -mindepth 2 -maxdepth 2 -type d -name snapshot -print0)
    else
        warn "snapshot directory not found: $snapshot_dir"
    fi
}

get_ro_state() {
    local subvolume=$1
    local output

    if ! output=$(btrfs property get "$subvolume" ro 2>/dev/null); then
        return 1
    fi

    case "$output" in
        *ro=true*)
            printf 'true\n'
            ;;
        *ro=false*)
            printf 'false\n'
            ;;
        *)
            return 1
            ;;
    esac
}

remove_restore_path() {
    local path_to_remove=$1
    local path
    local -a kept=()

    for path in "${RESTORE_RO[@]}"; do
        if [[ "$path" != "$path_to_remove" ]]; then
            kept+=("$path")
        fi
    done

    RESTORE_RO=("${kept[@]}")
}

delete_target() {
    local target=$1

    if [[ "$DRY_RUN" == true ]]; then
        log "would delete: $target"
        return 0
    fi

    if rm -rf --one-file-system -- "$target"; then
        log "deleted: $target"
        ((DELETED += 1))
        return 0
    fi

    warn "failed to delete: $target"
    ((FAILURES += 1))
    return 1
}

restore_snapshot_ro() {
    local snapshot_root=$1

    if btrfs property set "$snapshot_root" ro true; then
        remove_restore_path "$snapshot_root"
        log "restored read-only: $snapshot_root"
        return 0
    fi

    warn "failed to restore read-only snapshot: $snapshot_root"
    ((FAILURES += 1))
    return 1
}

process_target() {
    local target=$1
    local snapshot_root=${2:-}
    local ro_state=""
    local changed_ro=false

    ((MATCHES += 1))

    if [[ -n "$snapshot_root" ]]; then
        if ro_state=$(get_ro_state "$snapshot_root"); then
            if [[ "$DRY_RUN" == true && "$ro_state" == true ]]; then
                log "would set writable: $snapshot_root"
            fi

            if [[ "$DRY_RUN" == false && "$ro_state" == true ]]; then
                if btrfs property set "$snapshot_root" ro false; then
                    RESTORE_RO+=("$snapshot_root")
                    changed_ro=true
                    log "set writable: $snapshot_root"
                else
                    warn "failed to set snapshot writable: $snapshot_root"
                    ((FAILURES += 1))
                    return 0
                fi
            fi
        else
            warn "cannot read read-only state for snapshot: $snapshot_root"
            if [[ "$DRY_RUN" == false ]]; then
                ((FAILURES += 1))
                return 0
            fi
        fi
    fi

    delete_target "$target" || true

    if [[ "$changed_ro" == true ]]; then
        restore_snapshot_ro "$snapshot_root" || true
    fi
}

btrfs_used_bytes() {
    local mountpoint=$1
    local output used

    if ! output=$(btrfs filesystem usage -b "$mountpoint" 2>/dev/null); then
        return 1
    fi

    used=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*Used:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sed -n '1p')
    [[ -n "$used" ]] || return 1
    printf '%s\n' "$used"
}

measure_used_after_sync() {
    local mountpoint=$1

    btrfs filesystem sync "$mountpoint" >/dev/null || return 1
    btrfs_used_bytes "$mountpoint"
}

print_space_delta() {
    local before=$1
    local after=$2
    local delta freed

    delta=$((after - before))
    if ((delta < 0)); then
        freed=$((-delta))
    else
        freed=0
    fi

    log "actual space used before: $(format_bytes "$before")"
    log "actual space used after: $(format_bytes "$after")"
    log "actual space used delta: $(format_bytes "$delta")"
    log "actual freed bytes: $(format_bytes "$freed")"
}

du_value_to_bytes() {
    local value=$1

    if [[ "$value" == "-" ]]; then
        printf '0\n'
    else
        printf '%s\n' "$value"
    fi
}

warn_zero_du_target() {
    local target=$1
    local mount_target=""
    local first_entry=""

    if btrfs subvolume show "$target" >/dev/null 2>&1; then
        warn "btrfs du returned 0 for a Btrfs subvolume target: $target"
        warn "snapshots of a parent subvolume can contain only subvolume stubs; this script deletes paths, not nested subvolume contents"
        return 0
    fi

    mount_target=$(findmnt_field "$target" TARGET || true)
    if [[ -n "$mount_target" && "$(strip_trailing_slash "$(canonical_path "$mount_target")")" == "$(strip_trailing_slash "$(canonical_path "$target")")" ]]; then
        warn "btrfs du returned 0 for a mountpoint target: $target"
        warn "btrfs filesystem du does not recurse into mountpoints"
        return 0
    fi

    if [[ -d "$target" ]]; then
        first_entry=$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
        if [[ -n "$first_entry" ]]; then
            warn "btrfs du returned 0 for a non-empty directory: $target"
            warn "contents may be nested subvolumes, mountpoints, or metadata-only entries; inspect with btrfs subvolume show/list"
        fi
    fi
}

measure_targets_du() {
    local target output row total exclusive set_shared index count
    local measured=0
    local failed=0
    local zero_du=0
    local total_sum=0
    local exclusive_sum=0
    local set_shared_sum=0

    count=${#TARGET_PATHS[@]}

    for index in "${!TARGET_PATHS[@]}"; do
        target=${TARGET_PATHS[$index]}
        progress "measuring btrfs du $((index + 1))/$count: $target"

        if ! output=$(btrfs filesystem du -s --raw -- "$target" 2>/dev/null); then
            warn "cannot measure btrfs du for: $target"
            ((failed += 1))
            continue
        fi

        row=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]\+\([0-9][0-9]*\|-\)[[:space:]]\+\([0-9][0-9]*\|-\)[[:space:]]\+.*$/\1 \2 \3/p' | sed -n '1p')
        if [[ -z "$row" ]]; then
            warn "cannot parse btrfs du output for: $target"
            ((failed += 1))
            continue
        fi

        IFS=' ' read -r total exclusive set_shared <<<"$row"
        total=$(du_value_to_bytes "$total")
        exclusive=$(du_value_to_bytes "$exclusive")
        set_shared=$(du_value_to_bytes "$set_shared")

        total_sum=$((total_sum + total))
        exclusive_sum=$((exclusive_sum + exclusive))
        set_shared_sum=$((set_shared_sum + set_shared))
        ((measured += 1))
        progress "measured btrfs du $((index + 1))/$count: total=$(format_bytes "$total") exclusive=$(format_bytes "$exclusive") set_shared=$(format_bytes "$set_shared")"

        if ((total == 0 && exclusive == 0 && set_shared == 0)); then
            ((zero_du += 1))
            warn_zero_du_target "$target"
        fi
    done

    log "btrfs du measured paths: $measured"
    log "btrfs du per-path referenced sum: $(format_bytes "$total_sum")"
    log "btrfs du exclusive now: $(format_bytes "$exclusive_sum")"
    log "btrfs du per-path shared sum: $(format_bytes "$set_shared_sum")"
    log "estimated cleanup lower bound: $(format_bytes "$exclusive_sum")"

    if ((measured > 1)); then
        log "note: per-path referenced/shared sums can double-count extents shared between snapshots"
        log "note: exact freed space is only measured with --execute --measure-space"
    fi

    if ((measured > 0 && zero_du == measured)); then
        warn "all measured paths reported 0 bytes from btrfs du"
        warn "that usually means empty snapshot stubs, nested subvolumes, mountpoints, or paths with no file extents"
    fi

    if ((failed > 0)); then
        warn "btrfs du failed paths: $failed"
        ((FAILURES += failed))
    fi
}

parse_args() {
    while (($#)); do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -x|--execute)
                DRY_RUN=false
                shift
                ;;
            --measure-space)
                MEASURE_SPACE=true
                shift
                ;;
            --snapshots-only)
                SNAPSHOTS_ONLY=true
                shift
                ;;
            --snapshot)
                (($# >= 2)) || die "--snapshot requires an ID or range"
                SNAPSHOT_SELECTORS+=("$2")
                shift 2
                ;;
            -v|--volume)
                (($# >= 2)) || die "--volume requires a path"
                VOLUME=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                if [[ -n "$TARGET_INPUT" ]]; then
                    die "only one PATH argument is supported"
                fi
                TARGET_INPUT=$1
                shift
                ;;
        esac
    done

    while (($#)); do
        if [[ -n "$TARGET_INPUT" ]]; then
            die "only one PATH argument is supported"
        fi
        TARGET_INPUT=$1
        shift
    done

    [[ -n "$TARGET_INPUT" ]] || die "missing PATH argument"

}

main() {
    local input_abs probe mountpoint fstype rel_path live_target snapshot_dir
    local explicit_mount input_mount target snapshot_root
    local used_before="" used_after=""

    parse_args "$@"

    require_tool btrfs
    require_tool findmnt
    require_tool realpath
    require_tool sed
    require_tool rm
    require_tool find

    input_abs=$(canonical_path "$TARGET_INPUT")
    probe=$(nearest_existing_ancestor "$input_abs")

    if [[ -n "$VOLUME" ]]; then
        explicit_mount=$(strip_trailing_slash "$(canonical_path "$VOLUME")")
        [[ -e "$explicit_mount" || -L "$explicit_mount" ]] || die "--volume does not exist: $explicit_mount"

        mountpoint=$(strip_trailing_slash "$(mount_for_path "$explicit_mount")") || die "cannot find mountpoint for --volume: $explicit_mount"
        [[ "$mountpoint" == "$explicit_mount" ]] || die "--volume must be a mounted Btrfs filesystem: $explicit_mount"

        input_mount=$(strip_trailing_slash "$(mount_for_path "$probe")") || die "cannot find mountpoint for PATH: $probe"
        [[ "$input_mount" == "$mountpoint" ]] || die "PATH belongs to $input_mount, not --volume $mountpoint"
    else
        mountpoint=$(strip_trailing_slash "$(mount_for_path "$probe")") || die "cannot find mountpoint for PATH: $probe"
    fi

    fstype=$(fstype_for_path "$mountpoint")
    [[ "$fstype" == "btrfs" ]] || die "target mountpoint is not Btrfs: $mountpoint ($fstype)"

    rel_path=$(relative_to_mountpoint "$input_abs" "$mountpoint") || die "PATH is outside mountpoint $mountpoint: $input_abs"
    [[ -n "$rel_path" ]] || die "refusing to delete mountpoint root: $mountpoint"
    [[ "$rel_path" != "." ]] || die "refusing to delete mountpoint root: $mountpoint"
    [[ "$rel_path" != ".snapshots" && "$rel_path" != .snapshots/* ]] || die "refusing to delete inside .snapshots directly; pass the live filesystem path"
    if has_symlink_ancestor "$mountpoint" "$rel_path"; then
        die "refusing path with a symlink ancestor: $input_abs"
    fi

    live_target=$(join_path "$mountpoint" "$rel_path")
    snapshot_dir=$(join_path "$mountpoint" ".snapshots")

    collect_snapshot_targets "$snapshot_dir" "$rel_path"

    if [[ "$SNAPSHOTS_ONLY" == false && ${#SNAPSHOT_SELECTORS[@]} -eq 0 ]]; then
        add_target_if_exists "$live_target"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "mode: dry-run"
    else
        log "mode: execute"
    fi
    log "mountpoint: $mountpoint"
    log "relative path: $rel_path"

    if ((${#SNAPSHOT_SELECTORS[@]} > 0)); then
        log "snapshot scope: $(join_by_space "${SELECTED_SNAPSHOT_IDS[@]}")"
        log "live path: kept"
    elif [[ "$SNAPSHOTS_ONLY" == true ]]; then
        log "snapshot scope: all snapshots"
        log "live path: kept"
    else
        log "snapshot scope: all snapshots"
        log "live path: included"
    fi

    if [[ "$MEASURE_SPACE" == true ]]; then
        measure_targets_du
        if [[ "$DRY_RUN" == false ]]; then
            used_before=$(measure_used_after_sync "$mountpoint") || die "cannot measure Btrfs used space before deletion"
        fi
    fi

    for i in "${!TARGET_PATHS[@]}"; do
        target=${TARGET_PATHS[$i]}
        snapshot_root=${TARGET_SNAPSHOT_ROOTS[$i]}
        process_target "$target" "$snapshot_root"
    done

    if [[ "$MEASURE_SPACE" == true && "$DRY_RUN" == false ]]; then
        used_after=$(measure_used_after_sync "$mountpoint") || {
            warn "cannot measure Btrfs used space after deletion"
            ((FAILURES += 1))
            used_after=""
        }

        if [[ -n "$used_after" ]]; then
            print_space_delta "$used_before" "$used_after"
        fi
    fi

    if ((MATCHES == 0)); then
        log "no matching live or snapshot paths found"
    elif [[ "$DRY_RUN" == true ]]; then
        log "matched paths: $MATCHES"
    else
        log "deleted paths: $DELETED"
    fi

    if ((FAILURES > 0)); then
        exit 1
    fi
}

main "$@"
