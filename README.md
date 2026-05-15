# btrfs-delete

Delete a file or directory from a live Btrfs subvolume and from its
Snapper-style snapshots.

The default mode is a dry run. Nothing is removed unless `--execute` is used.

## Usage

```sh
sudo ./btrfs-delete.sh /path/to/file
sudo ./btrfs-delete.sh --measure-space /path/to/file
sudo ./btrfs-delete.sh --execute /path/to/file
sudo ./btrfs-delete.sh --volume /home --execute /home/user/big-file.img
sudo ./btrfs-delete.sh --snapshots-only --execute /path/to/file
sudo ./btrfs-delete.sh --snapshot 12 --snapshot 20-25 --execute /path/to/file
sudo ./btrfs-delete.sh --measure-space --execute /path/to/file
```

Options:

```text
-n, --dry-run             Show planned actions without deleting anything.
-x, --execute             Delete matching files/directories.
    --measure-space       Report pre-delete btrfs du totals for matched paths.
                          With --execute, also report actual used-space delta.
    --snapshots-only      Delete only from snapshots, keep the live path.
    --snapshot ID|A-B     Delete only from selected Snapper snapshot ID/range.
                          Can be repeated. Selected snapshots keep live path.
-v, --volume PATH         Use this Btrfs mountpoint instead of auto-detecting it.
-h, --help                Show help.
```

## How It Works

The script:

1. Canonicalizes the requested path.
2. Finds the Btrfs mountpoint containing that path with `findmnt`.
3. Computes the path relative to that mountpoint.
4. Deletes matching files from:
   - the live mounted subvolume;
   - `MOUNTPOINT/.snapshots/*/snapshot/RELATIVE_PATH`.

This handles separate mounted subvolumes such as `/home`. For example, deleting
`/home/user/file` from a `/home` mount checks:

```text
/home/user/file
/home/.snapshots/*/snapshot/user/file
```

It does not treat the path as `/home/.snapshots/*/snapshot/home/user/file`.

By default, matching copies are removed from the live filesystem and all
snapshots. Use `--snapshots-only` to keep the live copy.

Use `--snapshot` to target specific Snapper snapshots by numeric ID:

```sh
sudo ./btrfs-delete.sh --snapshot 12 --execute /path/to/file
sudo ./btrfs-delete.sh --snapshot 20-25 --execute /path/to/file
sudo ./btrfs-delete.sh --snapshot 12 --snapshot 20-25 --execute /path/to/file
```

When any `--snapshot` selector is used, the live filesystem copy is kept by
default. Missing selected snapshot IDs are treated as errors.

`--measure-space` reports pre-delete `btrfs filesystem du -s --raw` totals for
the matched paths:

```text
measuring btrfs du 1/2: /path/to/file
measured btrfs du 1/2: total=1000000 bytes (976.5 KiB) exclusive=250000 bytes (244.1 KiB) set_shared=750000 bytes (732.4 KiB)
btrfs du measured paths: 2
btrfs du per-path referenced sum: 2000000 bytes (1.9 MiB)
btrfs du exclusive now: 500000 bytes (488.2 KiB)
btrfs du per-path shared sum: 1500000 bytes (1.4 MiB)
estimated cleanup lower bound: 500000 bytes (488.2 KiB)
note: per-path referenced/shared sums can double-count extents shared between snapshots
note: exact freed space is only measured with --execute --measure-space
```

`btrfs filesystem du` can be slow on large directories or many snapshots. The
script prints progress before and after each path measurement so a long run
shows which path is being scanned.

If `btrfs du` returns `0/0/0` for every matched path, the script prints warnings.
This usually means the paths are empty snapshot stubs, nested subvolumes,
mountpoints, or metadata-only directories. In that case deleting the path may
not free the data you expected; inspect the target with:

```sh
btrfs subvolume show /path/to/target
findmnt -T /path/to/target
```

With `--execute`, it also reports actual Btrfs used-space delta:

```text
actual space used before: 1000000 bytes (976.5 KiB)
actual space used after: 700000 bytes (683.5 KiB)
actual space used delta: -300000 bytes (-292.9 KiB)
actual freed bytes: 300000 bytes (292.9 KiB)
```

## Safety

The script refuses to delete:

- an empty path;
- `/`;
- the selected mountpoint root;
- paths inside `.snapshots` directly;
- paths outside the selected Btrfs mountpoint;
- paths with a symlink in an existing parent directory;
- paths on non-Btrfs filesystems.

When a matching snapshot is read-only, `--execute` temporarily sets it writable,
removes the requested path, and restores the previous read-only state. A trap
attempts to restore read-only snapshots if the script is interrupted.

Deletion uses:

```sh
rm -rf --one-file-system -- "$target"
```

## Risks

This tool mutates snapshots. After running it, those snapshots are no longer
exact rollback points.

Space accounting on Btrfs is subtle because extents can be shared between live
files and snapshots. `btrfs filesystem du` reports `Total`, `Exclusive`, and
`Set shared` per measured argument. When many snapshots are selected, the
referenced/shared sums can count the same shared extents many times. The dry-run
cleanup estimate is therefore only a lower bound based on currently exclusive
bytes. With `--execute`, the script also measures the filesystem before and
after deletion with `btrfs filesystem usage -b`, so actual freed bytes are
reported separately.

This is not secure erasure. On SSDs, COW filesystems, backups, send/receive
targets, and logs, deleted bytes or secrets can still exist elsewhere. Rotate or
revoke leaked credentials after deletion.

Deletion is not atomic. A crash, signal, permission error, or concurrent
filesystem change can leave some copies deleted and others still present.

The script supports Snapper-style `.snapshots` layouts. It does not search all
subvolumes in the whole Btrfs filesystem, because that can delete unrelated
data with the same relative path.

