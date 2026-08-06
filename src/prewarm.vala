/*
 * prewarm -- keep the pages applications need resident.
 *
 * Two jobs, deliberately separate because they have different costs:
 *
 *   warm   asks the kernel to read pages into the page cache. Evictable, so
 *          it costs nothing to hold, but nothing guarantees it stays.
 *   lock   mmaps and mlocks ranges. Guaranteed resident, and unevictable, so
 *          it is charged against RAM for as long as the process lives.
 *
 * Ranges come from /proc/PID/pagemap rather than from file sizes: a shared
 * library is demand-paged, so the pages a process actually faults in are a
 * small fraction of the file. Measured on a PinePhone, six large libraries
 * were 449 MiB of file against 58 MiB touched.
 */

using GLib;



[CCode (cheader_filename = "sys/mman.h")]
extern void *mmap (void *addr, size_t length, int prot, int flags, int fd, Posix.off_t offset);

[CCode (cheader_filename = "sys/mman.h")]
extern int mlock (void *addr, size_t len);

[CCode (cheader_filename = "sys/mman.h")]
extern int munmap (void *addr, size_t length);

[CCode (cname = "PROT_READ", cheader_filename = "sys/mman.h")]
extern const int MMAP_PROT_READ;

[CCode (cname = "MAP_SHARED", cheader_filename = "sys/mman.h")]
extern const int MMAP_MAP_SHARED;

/* vec as a pointer, not uint8[]: Vala passes an implicit length alongside an
 * array parameter, which gives mincore a fourth argument it does not have. */
[CCode (cheader_filename = "sys/mman.h")]
extern int mincore (void *addr, size_t length, uint8 *vec);

const uint64 PAGEMAP_PRESENT = 1UL << 63;
const uint64 PAGEMAP_SWAPPED = 1UL << 62;

struct Range {
    public string path;
    public uint64 off;
    public uint64 len;
}

long page_size;

/* Accumulates the bytes read while touching, so the loop cannot be optimised
 * away as having no effect. */
uint8 touch_sink;

/* ---------------------------------------------------------------- recording */

void emit (StringBuilder buf, string path, uint64 off, uint64 len, uint64 fsize) {
    if (len == 0 || off >= fsize) {
        return;
    }

    var clamped = (off + len > fsize) ? fsize - off : len;
    buf.append_printf ("%s\t%" + uint64.FORMAT + "\t%" + uint64.FORMAT + "\n", path, off, clamped);
}

void record_pid (StringBuilder buf, string pid, uint64 min_size, string? prefix) {
    var maps_path = "/proc/%s/maps".printf (pid);
    var pagemap_path = "/proc/%s/pagemap".printf (pid);

    FileStream maps = FileStream.open (maps_path, "r");
    if (maps == null) {
        printerr ("prewarm: %s: %s\n", maps_path, Posix.strerror (Posix.errno));
        return;
    }

    int pagemap = Posix.open (pagemap_path, Posix.O_RDONLY);
    if (pagemap < 0) {
        printerr ("prewarm: %s: %s\n", pagemap_path, Posix.strerror (Posix.errno));
        return;
    }

    string line;
    while ((line = maps.read_line ()) != null) {
        /* address perms offset dev inode path */
        var parts = Regex.split_simple ("\\s+", line.strip ());
        if (parts.length < 6) {
            continue;
        }

        var addrs = parts[0].split ("-");
        if (addrs.length != 2) {
            continue;
        }

        uint64 start, end, pgoff;
        if (!uint64.try_parse (addrs[0], out start, null, 16)) continue;
        if (!uint64.try_parse (addrs[1], out end, null, 16)) continue;
        if (!uint64.try_parse (parts[2], out pgoff, null, 16)) continue;

        if (parts[1][0] != 'r' || parts[4] == "0") {
            continue;
        }

        var path = parts[5];
        for (int i = 6; i < parts.length; i++) {
            path += " " + parts[i];
        }

        if (!path.has_prefix ("/") || path.contains ("(deleted)")) {
            continue;
        }
        if (prefix != null && !path.has_prefix (prefix)) {
            continue;
        }

        Posix.Stat st;
        if (Posix.stat (path, out st) != 0 || !Posix.S_ISREG (st.st_mode)) {
            continue;
        }
        if ((uint64) st.st_size < min_size) {
            continue;
        }

        var npages = (end - start) / page_size;
        uint64 run_off = 0, run_len = 0;
        var chunk = new uint64[1024];

        for (uint64 i = 0; i < npages; ) {
            var want = uint64.min (npages - i, chunk.length);
            var at = (Posix.off_t) ((start / page_size + i) * 8);
            var got = Posix.pread (pagemap, chunk, (size_t) (want * 8), at);

            if (got <= 0) {
                break;
            }

            var have = (uint64) got / 8;
            for (uint64 k = 0; k < have; k++) {
                if ((chunk[k] & (PAGEMAP_PRESENT | PAGEMAP_SWAPPED)) == 0) {
                    continue;
                }

                var foff = pgoff + (i + k) * page_size;
                if (run_len != 0 && run_off + run_len == foff) {
                    run_len += page_size;
                } else {
                    emit (buf, path, run_off, run_len, st.st_size);
                    run_off = foff;
                    run_len = page_size;
                }
            }

            i += have;
        }

        emit (buf, path, run_off, run_len, st.st_size);
    }

    Posix.close (pagemap);
}

/* ----------------------------------------------------------------- profiles */

/* Two profile formats, read by the same parser because everything downstream
 * only ever sees ranges.
 *
 *   path \t offset \t length    a recorded range, from `prewarm record`
 *   path                        a whole file, written by hand or generated
 *
 * The second is there so a list of files known to matter can be declared
 * outright, with no recording step. That also survives what recording cannot: a
 * profile of /nix/store paths is invalidated by the next update, whereas a list
 * generated from the same expression that builds the system is rewritten with
 * it.
 */
Array<Range?> read_profiles (string[] paths) {
    var all = new Array<Range?> ();

    foreach (var p in paths) {
        FileStream f = FileStream.open (p, "r");
        if (f == null) {
            printerr ("prewarm: %s: %s\n", p, Posix.strerror (Posix.errno));
            continue;
        }

        string line;
        while ((line = f.read_line ()) != null) {
            var trimmed = line.strip ();
            if (trimmed == "" || trimmed.has_prefix ("#")) {
                continue;
            }

            var parts = trimmed.split ("\t");

            if (parts.length == 1) {
                Posix.Stat st;
                if (Posix.stat (parts[0], out st) != 0 || !Posix.S_ISREG (st.st_mode)) {
                    continue;
                }
                if (st.st_size == 0) {
                    continue;
                }

                all.append_val (Range () { path = parts[0], off = 0, len = st.st_size });
                continue;
            }

            if (parts.length != 3) {
                continue;
            }

            uint64 off, len;
            if (!uint64.try_parse (parts[1], out off)) continue;
            if (!uint64.try_parse (parts[2], out len)) continue;
            if (len == 0) continue;

            all.append_val (Range () { path = parts[0], off = off, len = len });
        }
    }

    return all;
}

/* Sort by path then offset, then fold overlapping and adjacent ranges together
 * so a page shared by several apps is only ever counted, warmed or locked once.
 */
Array<Range?> merge (Array<Range?> input) {
    var sorted = new GenericArray<Range?> ();
    for (uint i = 0; i < input.length; i++) {
        sorted.add (input.index (i));
    }

    sorted.sort ((a, b) => {
        var c = strcmp (a.path, b.path);
        if (c != 0) {
            return c;
        }
        if (a.off < b.off) return -1;
        if (a.off > b.off) return 1;
        return 0;
    });

    var merged = new Array<Range?> ();
    for (int i = 0; i < sorted.length; i++) {
        var cur = sorted[i];
        var end = cur.off + cur.len;

        while (i + 1 < sorted.length
               && sorted[i + 1].path == cur.path
               && sorted[i + 1].off <= end) {
            var next_end = sorted[i + 1].off + sorted[i + 1].len;
            if (next_end > end) {
                end = next_end;
            }
            i++;
        }

        merged.append_val (Range () { path = cur.path, off = cur.off, len = end - cur.off });
    }

    return merged;
}

/* --------------------------------------------------------------- warm / lock */

/* mmap, touch every page, and then check with mincore.
 *
 * The two obvious cheaper approaches both fail on ZFS, and fail quietly, which
 * is the dangerous part. Measured against a 5504-file profile on an SD card,
 * each followed by a residency check:
 *
 *   posix_fadvise(WILLNEED)    4.6s     0% resident   -- ignored outright
 *   pread of every byte      118.8s     0% resident   -- fills the ARC, and
 *                                                        primarycache=metadata
 *                                                        throws it away
 *   mmap and touch each page  83.5s    98% resident   -- works
 *
 * Only mmap creates page cache pages on ZFS; reads go to the ARC instead, so on
 * a dataset that caches metadata only they leave nothing behind. Reading the
 * mapping sequentially is also what engages the kernel readahead that makes it
 * bearable -- MAP_POPULATE, which prefaults without that, took 457.5s.
 *
 * Returns bytes mincore reports as actually resident, never bytes requested, so
 * a filesystem that ignores all of this cannot report success.
 */
uint64 map_range (int fd, uint64 off, uint64 len) {
    var addr = mmap (null, (size_t) len, MMAP_PROT_READ,
                     MMAP_MAP_SHARED, fd, (Posix.off_t) off);

    if ((long) addr == -1) {
        return 0;
    }

    /* Touched a page at a time from here rather than handed to MAP_POPULATE.
     * Reading the mapping sequentially is what trips the kernel's readahead
     * heuristic, and that batching is worth more than prefaulting in one call:
     * MAP_POPULATE over the same 5504-file profile took 457.5s to this loop's
     * 83.5s, for 100% residency against 98%. */
    uint8 *bytes = (uint8 *) addr;
    for (uint64 i = 0; i < len; i += page_size) {
        touch_sink |= bytes[i];
    }

    var pages = (len + page_size - 1) / page_size;
    var vec = new uint8[pages];
    uint64 resident = 0;

    if (mincore (addr, (size_t) len, vec) == 0) {
        for (uint64 i = 0; i < pages; i++) {
            if ((vec[i] & 1) != 0) {
                resident += page_size;
            }
        }
    }

    munmap (addr, (size_t) len);
    return uint64.min (resident, len);
}

uint64 warm_ranges (Array<Range?> ranges) {
    uint64 total = 0;
    string? open_path = null;
    int fd = -1;

    for (uint i = 0; i < ranges.length; i++) {
        var r = ranges.index (i);

        if (open_path != r.path) {
            if (fd >= 0) {
                Posix.close (fd);
            }
            fd = Posix.open (r.path, Posix.O_RDONLY);
            open_path = r.path;
        }

        if (fd < 0) {
            continue;
        }

        total += map_range (fd, r.off, r.len);
    }

    if (fd >= 0) {
        Posix.close (fd);
    }

    return total;
}

uint64 warm_dir (string dir) {
    uint64 total = 0;

    try {
        var d = Dir.open (dir);
        string? name;

        while ((name = d.read_name ()) != null) {
            var path = Path.build_filename (dir, name);

            if (FileUtils.test (path, FileTest.IS_SYMLINK)) {
                continue;
            }

            if (FileUtils.test (path, FileTest.IS_DIR)) {
                total += warm_dir (path);
                continue;
            }

            Posix.Stat st;
            if (Posix.stat (path, out st) != 0 || !Posix.S_ISREG (st.st_mode)) {
                continue;
            }

            int fd = Posix.open (path, Posix.O_RDONLY);
            if (fd < 0) {
                continue;
            }

            total += map_range (fd, 0, st.st_size);
            Posix.close (fd);
        }
    } catch (FileError e) {
        printerr ("prewarm: %s: %s\n", dir, e.message);
    }

    return total;
}

int lock_ranges (Array<Range?> ranges, uint64 max_total) {
    uint64 locked = 0, skipped = 0;
    uint mapped = 0, failed = 0;
    string? open_path = null;
    int fd = -1;

    for (uint i = 0; i < ranges.length; i++) {
        var r = ranges.index (i);

        if (max_total != 0 && locked + r.len > max_total) {
            skipped += r.len;
            continue;
        }

        if (open_path != r.path) {
            if (fd >= 0) {
                Posix.close (fd);
            }
            fd = Posix.open (r.path, Posix.O_RDONLY);
            open_path = r.path;
        }

        if (fd < 0) {
            failed++;
            continue;
        }

        var addr = mmap (null, (size_t) r.len, MMAP_PROT_READ, MMAP_MAP_SHARED,
                         fd, (Posix.off_t) r.off);
        if ((long) addr == -1) {
            failed++;
            continue;
        }

        if (mlock (addr, (size_t) r.len) != 0) {
            printerr ("prewarm: mlock %s: %s\n", r.path, Posix.strerror (Posix.errno));
            munmap (addr, (size_t) r.len);
            failed++;
            continue;
        }

        locked += r.len;
        mapped++;
    }

    /* The mappings are deliberately never unmapped -- the lock lasts exactly as
     * long as this process does, which is why it is run as a simple service. */
    stdout.printf ("locked %" + uint64.FORMAT + " KiB across %u ranges", locked / 1024, mapped);
    if (skipped != 0) {
        stdout.printf (", skipped %" + uint64.FORMAT + " KiB over the budget", skipped / 1024);
    }
    if (failed != 0) {
        stdout.printf (", %u failed", failed);
    }
    stdout.printf ("\n");
    stdout.flush ();

    while (true) {
        Posix.pause ();
    }
}

/* --------------------------------------------------------------------- main */

/* Profiles are gathered from every directory named, so a read-only set built
 * with the system can sit alongside the mutable one that recording writes to.
 */
string[] profiles_in (string dirs) {
    var found = new GenericArray<string> ();

    foreach (var dir in dirs.split (":")) {
        if (dir == "") {
            continue;
        }

        try {
            var d = Dir.open (dir);
            string? name;
            while ((name = d.read_name ()) != null) {
                if (name.has_suffix (".pages") || name.has_suffix (".files")) {
                    found.add (Path.build_filename (dir, name));
                }
            }
        } catch (FileError e) {
            /* A directory that does not exist yet just has nothing in it. */
        }
    }

    found.sort ((a, b) => strcmp (a, b));
    return found.data;
}

void usage () {
    printerr ("""usage: prewarm record <name> <pid>...   record the pages those processes touched
       prewarm warm                     read the recorded pages and dirs back in
       prewarm lock                     mlock the recorded pages, then hold them
       prewarm status                   report what is recorded and resident

environment:
  PREWARM_STATE_DIR    where `record` writes profiles (default /var/lib/prewarm)\n  PREWARM_PROFILE_DIRS :-separated dirs of profiles to warm and lock
  PREWARM_WARM_ONLY_DIRS :-separated dirs of profiles to warm but never lock
  PREWARM_MIN_SIZE     smallest file to record ranges for, bytes (default 0)
  PREWARM_PREFIX       only record paths under this prefix
  PREWARM_MAX_LOCKED   ceiling on locked bytes, 0 for no limit
  PREWARM_WARM_DIRS    colon-separated directories to warm whole
""");
}

int main (string[] args) {
    page_size = Posix.sysconf (Posix._SC_PAGESIZE);


    var state_dir = Environment.get_variable ("PREWARM_STATE_DIR") ?? "/var/lib/prewarm";
    var profile_dirs = Environment.get_variable ("PREWARM_PROFILE_DIRS") ?? state_dir;

    /* Profiles worth reading in but not worth pinning. Whole shared libraries
     * belong here: warming them costs I/O once and covers every page an app
     * might reach, where locking them would charge RAM for the large fraction
     * no app ever executes. */
    var warm_only_dirs = Environment.get_variable ("PREWARM_WARM_ONLY_DIRS") ?? "";
    var warm_dirs_raw = Environment.get_variable ("PREWARM_WARM_DIRS") ?? "";

    if (args.length < 2) {
        usage ();
        return 1;
    }

    switch (args[1]) {
    case "record":
        if (args.length < 4) {
            usage ();
            return 1;
        }

        uint64 min_size = 0;
        var min_raw = Environment.get_variable ("PREWARM_MIN_SIZE");
        if (min_raw != null) {
            uint64.try_parse (min_raw, out min_size);
        }

        var prefix = Environment.get_variable ("PREWARM_PREFIX");
        var buf = new StringBuilder ();

        for (int i = 3; i < args.length; i++) {
            record_pid (buf, args[i], min_size, prefix);
        }

        if (DirUtils.create_with_parents (state_dir, 0775) != 0) {
            printerr ("prewarm: cannot create %s: %s\n", state_dir, Posix.strerror (Posix.errno));
            return 1;
        }

        var out_path = Path.build_filename (state_dir, args[2] + ".pages");
        try {
            FileUtils.set_contents (out_path, buf.str);
        } catch (FileError e) {
            printerr ("prewarm: %s: %s\n", out_path, e.message);
            return 1;
        }

        var recorded = merge (read_profiles ({ out_path }));
        uint64 bytes = 0;
        for (uint i = 0; i < recorded.length; i++) {
            bytes += recorded.index (i).len;
        }

        stdout.printf ("%s: %u ranges, %" + uint64.FORMAT + " MiB\n",
                       args[2], recorded.length, bytes / (1024 * 1024));
        return 0;

    case "warm":
        var ranges = merge (read_profiles (profiles_in (profile_dirs + ":" + warm_only_dirs)));
        var bytes = warm_ranges (ranges);
        stdout.printf ("warmed %" + uint64.FORMAT + " MiB of recorded pages\n",
                       bytes / (1024 * 1024));

        foreach (var dir in warm_dirs_raw.split (":")) {
            if (dir == "" || !FileUtils.test (dir, FileTest.IS_DIR)) {
                continue;
            }
            var dir_bytes = warm_dir (dir);
            stdout.printf ("warmed %" + uint64.FORMAT + " MiB from %s\n",
                           dir_bytes / (1024 * 1024), dir);
        }
        return 0;

    case "lock":
        uint64 max_total = 0;
        var max_raw = Environment.get_variable ("PREWARM_MAX_LOCKED");
        if (max_raw != null) {
            uint64.try_parse (max_raw, out max_total);
        }

        var to_lock = merge (read_profiles (profiles_in (profile_dirs)));
        if (to_lock.length == 0) {
            printerr ("prewarm: nothing recorded to lock\n");
            return 0;
        }

        return lock_ranges (to_lock, max_total);

    case "status":
        var profiles = profiles_in (profile_dirs + ":" + warm_only_dirs);
        var locked_set = new GenericSet<string> (str_hash, str_equal);
        foreach (var lp in profiles_in (profile_dirs)) {
            locked_set.add (lp);
        }
        stdout.printf ("%-16s %8s %10s  %s\n", "profile", "ranges", "size", "held");

        foreach (var p in profiles) {
            var one = merge (read_profiles ({ p }));
            uint64 bytes = 0;
            for (uint i = 0; i < one.length; i++) {
                bytes += one.index (i).len;
            }
            stdout.printf ("%-16s %8u %9" + uint64.FORMAT + "M  %s\n",
                           Path.get_basename (p).replace (".pages", "").replace (".files", ""),
                           one.length, bytes / (1024 * 1024),
                           locked_set.contains (p) ? "warm+lock" : "warm");
        }

        var all = merge (read_profiles (profiles));
        uint64 total = 0;
        for (uint i = 0; i < all.length; i++) {
            total += all.index (i).len;
        }
        stdout.printf ("%-16s %8u %9" + uint64.FORMAT + "M  (shared pages counted once)\n",
                       "= merged", all.length, total / (1024 * 1024));
        return 0;

    default:
        usage ();
        return 1;
    }
}
