# prewarm

<a href="https://liberapay.com/BeatLink/donate"><img alt="Donate using Liberapay" src="https://liberapay.com/assets/widgets/donate.svg"></a> <a href="https://ko-fi.com/I4V52ANK6N"><img alt="Support me on Ko-fi" src="https://ko-fi.com/img/githubbutton_sm.svg"></a>

Keeps the pages your applications need resident, so starting them does not wait
on storage.

Useful anywhere launch time is dominated by I/O rather than CPU: slow or
contended disks, SD cards, network-backed storage, or a machine with enough RAM
to hold a working set that keeps getting evicted anyway.

## What it does

`prewarm` learns which pages of which files your applications actually touch,
and then keeps those pages in memory.

It works in **regions**, not whole files. A shared library is demand-paged: a
process maps the whole file but faults in only the parts it executes, often a
small fraction. Reading the rest wastes I/O, and pinning it wastes RAM. So a
profile records the pages that were really used, and everything downstream
operates on those.

Two ways to keep them:

| | mechanism | costs | guarantees |
| --- | --- | --- | --- |
| `warm` | reads pages into the page cache | I/O when it runs, nothing to hold | nothing — pages stay evictable |
| `lock` | `mmap` + `mlock` | RAM, until the process exits | residency |

Warming is nearly free and usually enough. Locking is for the set you never want
to lose, and is bounded by a configurable ceiling.

Profiles merge. A page used by several applications is stored, warmed and locked
once — which is most of the benefit on a system where everything shares a
toolkit.

## Getting a profile

**Automatically.** `prewarm watch` samples every running process on an interval
and writes what it finds. Nothing has to be anticipated, and it repairs itself
when packages change, because paths that stop existing stop appearing in
samples.

Samples rotate through a fixed number of generations. The union of them is the
profile, so anything that stops being touched ages out on its own.

**By hand.** `prewarm record <name> <pid>...` captures one moment deliberately —
useful for a named, per-application profile, for a specific workflow you want
covered, or to get started without running a daemon.

**By declaration.** A profile can just be a list of paths, one per line, `#` for
comments:

```
# epiphany.files
/usr/lib/libwebkitgtk-6.0.so.4
/usr/bin/epiphany
```

Each named path is covered whole. Use this when you already know what matters,
or when generating the list from configuration management.

All three produce files in the same directory and are read together.

## Usage

```sh
prewarm watch     # sample running processes on an interval
prewarm record epiphany $(pgrep 'epiphany|WebKit')
prewarm warm      # read the profiles into the page cache
prewarm lock      # hold them with mlock; runs until stopped
prewarm status    # what is covered, per profile and merged
```

```
$ prewarm status
profile             files  regions       size  held
epiphany              412     3774       161M  warm+lock
weblaunch             388     3509       108M  warm+lock
auto-0                875     5402       166M  warm
= merged             1104     6810       243M  (shared pages counted once)
```

## Configuration

Entirely by environment, so the same binary works under a service manager or
from a shell:

| variable | default | meaning |
| --- | --- | --- |
| `PREWARM_STATE_DIR` | `/var/lib/prewarm` | where `record` and `watch` write |
| `PREWARM_PROFILE_DIRS` | state dir | `:`-separated dirs to warm **and** lock |
| `PREWARM_WARM_ONLY_DIRS` | — | `:`-separated dirs to warm but never lock |
| `PREWARM_WARM_DIRS` | — | `:`-separated directories to warm whole |
| `PREWARM_MIN_SIZE` | `0` | smallest file to record regions for |
| `PREWARM_PREFIX` | — | only record paths under this prefix |
| `PREWARM_MAX_LOCKED` | `0` | ceiling on locked bytes, 0 for none |
| `PREWARM_WATCH_INTERVAL` | `300` | seconds between samples |
| `PREWARM_WATCH_GENERATIONS` | `6` | samples kept before one ages out |

### Warming directories

`warmDirs` covers data an application *reads* rather than maps — profiles,
caches, databases. Recording cannot see those, because nothing about them
appears in a process's page tables. They are walked live rather than recorded,
since an application rewrites its own cache and a stored file list would go
stale.

## NixOS

```nix
{
    inputs.prewarm.url = "github:BeatLink/Prewarm";

    imports = [ inputs.prewarm.nixosModules.default ];

    services.prewarm = {
        enable = true;
        maxLocked = 384 * 1024 * 1024;

        watch.enable = true;

        profiles.epiphany = {
            files = [ "${pkgs.epiphany}/bin/epiphany" ];
            dirs = [ "/home/someone/.local/share/epiphany" ];
            lock = false;
        };
    };
}
```

`profiles.<name>.lock = false` warms without pinning. That suits whole shared
libraries: warming one covers every page an application might reach and costs
only I/O, where locking it would charge RAM for the part nothing executes.

The warm timer repeats, because warmed pages are evictable and nothing else
would put them back.

## Notes

**Filesystem support varies, and failures are quiet.** Some filesystems ignore
`posix_fadvise`, and on ZFS a plain read populates the ARC rather than the page
cache — either can appear to succeed while leaving nothing resident. `prewarm`
maps and touches pages, and reports what `mincore` confirms is present, never
what was requested.

**Sampling has a floor.** `watch` sees pages that are resident when it looks, so
a page faulted and dropped between two samples is missed. Shorter intervals
catch more and cost more; a sample walks every process's page tables.

**Locked memory is not reclaimable.** Keep `PREWARM_MAX_LOCKED` within what the
machine can spare — the ceiling drops whatever sorts last, so overrunning it
loses arbitrary pages rather than the least useful ones.

## Building

```sh
make && sudo make install
```

Needs `valac` and glib. There is a flake too, if you want it:

```sh
nix build
nix run . -- status
```

Written in Vala, which compiles to C: a preloader that spends noticeable time or
memory starting up defeats its own purpose.

## Portability

Linux only — it reads `/proc/PID/pagemap`, and `mincore`, `mlock` and `mmap` do
the rest. No filesystem, distribution or package manager is assumed.

Warming maps and touches pages because that is the one method that works
everywhere. On filesystems that honour it, `posix_fadvise(WILLNEED)` would be
considerably cheaper; on others it is silently ignored, and on ZFS a plain read
populates the ARC rather than the page cache, so neither leaves anything
resident. Correctness everywhere was worth more than speed on some, and
`mincore` verification means a filesystem that ignores the request is reported
rather than assumed to have worked.

## Licence

GPL-3.0-or-later.
