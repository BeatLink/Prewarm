# prewarm

Keeps the pages an application needs at startup resident, so launching it does
not wait on storage.

Built for a PinePhone, where a cold app launch is almost entirely I/O wait, but
nothing in it is phone-specific.

## What it does

Two mechanisms, kept separate because they cost different things:

| | how | cost | guarantee |
| --- | --- | --- | --- |
| `warm` | `mmap` + `MAP_POPULATE` | free to hold | none, pages are evictable |
| `lock` | `mmap` + `mlock` | charged against RAM | resident until the process exits |

Both work from the same profiles.

### Why mmap, and not something cheaper

Both obvious shortcuts fail on ZFS, and fail *quietly*, which is the dangerous
part -- they return success having done nothing. Measured against a 5504-file
profile on an SD card, each followed by an independent residency check:

| approach | time | resident after |
| --- | --- | --- |
| `posix_fadvise(WILLNEED)` | 4.6s | **0%** -- ignored outright |
| `pread` of every byte | 118.8s | **0%** -- fills the ARC, which `primarycache=metadata` discards |
| `mmap` + touch each page | 83.5s | 98% |

Only `mmap` creates page cache pages on ZFS; reads go to the ARC instead, so on
a dataset caching metadata only they leave nothing behind. `MAP_POPULATE` asks
the kernel to prefault the mapping rather than driving it a page at a time from
userspace, as `vmtouch` does.

`warm` reports bytes `mincore` confirms are resident, never bytes requested, so
a filesystem that ignores all of this cannot report success.

## Why page ranges rather than files

A shared library is demand-paged. The process maps the whole file but faults in
only the pages it executes, so warming or locking whole files pays for a great
deal that is never read. Measured on a PinePhone with a warm Epiphany:

| library | on disk | actually resident |
| --- | --- | --- |
| `libwebkitgtk-6.0` | 132.4 MiB | 26.8 MiB |
| `libjavascriptcoregtk` | 37.8 MiB | 8.2 MiB |
| `libLLVM` | 176.8 MiB | 14.0 MiB |
| `libgallium` | 56.4 MiB | 3.7 MiB |
| `libgtk-4` | 14.2 MiB | 5.4 MiB |
| `libicudata` | 31.6 MiB | ~0 |

449 MiB of file, 58 MiB touched. `prewarm record` reads the present bit out of
`/proc/PID/pagemap` for every file-backed mapping, so a profile describes the
pages that process actually faulted in.

Profiles merge. Pages shared between applications are stored, warmed and locked
once, which is most of the value on a system where everything is GTK: recording
Epiphany gave 109 MiB, and adding Files, Secrets and Settings on top cost only
16 MiB more, because they land on pages already covered.

## Two ways to say what matters

**Record it**, when you do not already know:

```sh
# Start the app, use it, then record what it touched.
prewarm record epiphany $(pgrep 'epiphany|WebKit')
```

**Declare it**, when you do. A profile can be a plain list of paths, one per
line, `#` for comments -- no recording step, and whole files rather than ranges:

```
# /etc/prewarm/epiphany.files
/nix/store/…-epiphany-50.4/bin/epiphany
/nix/store/…-webkitgtk-2.52.5/lib/libwebkitgtk-6.0.so.4
```

Declaring is the better default where the answer is obvious, because it is the
only one that survives an update: a recorded profile names exact store paths and
is silently invalidated the next time they change, whereas a declared list
generated from the same expression that builds the system is rewritten with it.

Recording still wins where the answer is not obvious -- it captures the pages
actually faulted in rather than whole files. Both formats are read by the same
parser and merged together, so a system can use each where it fits.

## Usage

```sh
prewarm warm      # read the profiles back into the page cache
prewarm lock      # hold them with mlock; runs until killed
prewarm status    # what is covered, per profile and merged
```

Configured by environment, so the same binary works under systemd or by hand:

| variable | default | meaning |
| --- | --- | --- |
| `PREWARM_STATE_DIR` | `/var/lib/prewarm` | where profiles live |
| `PREWARM_MIN_SIZE` | `0` | smallest file to record ranges for |
| `PREWARM_PREFIX` | unset | only record mappings under this path |
| `PREWARM_MAX_LOCKED` | `0` | ceiling on locked bytes, 0 for none |
| `PREWARM_WARM_DIRS` | unset | `:`-separated dirs to warm whole |

## Warm directories

`warmDirs` is for data an app *reads* rather than maps -- browser profiles,
caches, anything the pagemap recorder cannot see because it was never mapped.
They are walked live rather than recorded, because an app rewrites its own cache
and a recorded file list goes stale in a way `/nix/store` paths never do.

This is worth more than it sounds. On a phone whose application data sits on an
SD card, warming Home Assistant's 55 MiB profile took a cold start from 11.5s to
4.5s -- a larger win than all the library work above.

## NixOS

```nix
{
    inputs.prewarm.url = "github:BeatLink/Prewarm";

    # ...

    imports = [ inputs.prewarm.nixosModules.default ];

    services.prewarm = {
        enable = true;
        group = "someone";
        maxLocked = 224 * 1024 * 1024;
        warmDirs = [ "/home/someone/.local/share/weblaunch" ];
    };
}
```

The warm timer repeats, because warmed pages are evictable and nothing else
would put them back. That is affordable because only the first pass is
expensive: over an SD-card profile of 5504 files, warming from cold took 83.5s
with a mmap-and-touch approach against 2.3s once resident. `posix_fadvise` is
used instead precisely to avoid that first-pass cost -- it queues the read in
the kernel rather than faulting each page in from userspace.

## Building

```sh
nix build
nix run . -- status
```

Written in Vala. It compiles to C, which matters when the whole point is not
spending time or memory: a Python equivalent took 839-1810 ms merely to print
its help on the target device, against 21 ms for a native binary.

## Licence

GPL-3.0-or-later.
