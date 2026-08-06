/*
 * prewarm -- keep the pages applications need resident.
 *
 * Two jobs, deliberately separate because they have different costs:
 *
 *   warm   reads pages into the page cache. Evictable, so it costs nothing to
 *          hold, but nothing guarantees it stays.
 *   lock   mmaps and mlocks regions. Guaranteed resident, and unevictable, so
 *          it is charged against RAM for as long as the process lives.
 *
 * Regions come from /proc/PID/pagemap rather than from file sizes: a shared
 * library is demand-paged, so the pages a process actually faults in are a
 * small fraction of the file. Measured on a PinePhone, six large libraries
 * were 449 MiB of file against 58 MiB touched.
 *
 * A profile is a set of files, each with the regions of it that matter, and
 * everything here works on that shape: one path, an array of regions, and one
 * file descriptor opened per file no matter how many regions it has.
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

struct Region {
    public uint64 off;
    public uint64 len;
}

/* Insertion-ordered so a profile written back out keeps the shape it was read
 * in, which makes the files diffable between runs. */
class Profile : Object {
    public GenericArray<string> order = new GenericArray<string> ();
    public HashTable<string, GenericArray<Region?>> files =
        new HashTable<string, GenericArray<Region?>> (str_hash, str_equal);

    public GenericArray<Region?> regions_for (string path) {
        var existing = files.lookup (path);
        if (existing != null) {
            return existing;
        }

        var fresh = new GenericArray<Region?> ();
        files.insert (path, fresh);
        order.add (path);
        return fresh;
    }

    public void add (string path, uint64 off, uint64 len) {
        if (len != 0) {
            regions_for (path).add (Region () { off = off, len = len });
        }
    }

    public uint64 total_bytes () {
        uint64 total = 0;
        foreach (var path in order) {
            foreach (var r in files.lookup (path)) {
                total += r.len;
            }
        }
        return total;
    }

    public uint region_count () {
        uint n = 0;
        foreach (var path in order) {
            n += files.lookup (path).length;
        }
        return n;
    }

    /* Sort each file's regions and fold overlapping and adjacent ones together,
     * so a page covered by several profiles is stored, warmed and locked once.
     * Per file rather than globally: nothing ever needs to compare regions of
     * different files, and this way the sort is over a handful of entries
     * rather than every entry in the system. */
    public void merge () {
        foreach (var path in order) {
            var regions = files.lookup (path);

            regions.sort ((a, b) => {
                if (a.off < b.off) return -1;
                if (a.off > b.off) return 1;
                return 0;
            });

            var merged = new GenericArray<Region?> ();
            for (int i = 0; i < regions.length; i++) {
                var off = regions[i].off;
                var end = off + regions[i].len;

                while (i + 1 < regions.length && regions[i + 1].off <= end) {
                    var next_end = regions[i + 1].off + regions[i + 1].len;
                    if (next_end > end) {
                        end = next_end;
                    }
                    i++;
                }

                merged.add (Region () { off = off, len = end - off });
            }

            files.replace (path, merged);
        }
    }
}

long page_size;

/* ---------------------------------------------------------------- recording */

void record_pid (Profile profile, string pid, uint64 min_size, string? prefix) {
    var maps_path = "/proc/%s/maps".printf (pid);
    var pagemap_path = "/proc/%s/pagemap".printf (pid);

    FileStream maps = FileStream.open (maps_path, "r");
    if (maps == null) {
        return;
    }

    int pagemap = Posix.open (pagemap_path, Posix.O_RDONLY);
    if (pagemap < 0) {
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
                    add_clamped (profile, path, run_off, run_len, st.st_size);
                    run_off = foff;
                    run_len = page_size;
                }
            }

            i += have;
        }

        add_clamped (profile, path, run_off, run_len, st.st_size);
    }

    Posix.close (pagemap);
}

void add_clamped (Profile profile, string path, uint64 off, uint64 len, uint64 fsize) {
    if (len == 0 || off >= fsize) {
        return;
    }

    profile.add (path, off, (off + len > fsize) ? fsize - off : len);
}

/* ----------------------------------------------------------------- profiles */

/* On disk a profile is a path followed by its regions, one per line and
 * indented, so a path appears once however many regions it has:
 *
 *     /nix/store/…/libwebkitgtk-6.0.so.4
 *     <TAB>4096<TAB>81920
 *     <TAB>102400<TAB>8192
 *     /nix/store/…/libgtk-4.so.1
 *     <TAB>0<TAB>2306048
 *
 * A path on its own, with no indented lines under it, means the whole file --
 * which is how a profile can be declared by hand rather than recorded. That
 * form survives what recording cannot: a recorded profile names exact store
 * paths and is invalidated by the next update, whereas a list generated from
 * the expression that builds the system is rewritten along with it.
 *
 * The flat `path<TAB>off<TAB>len` form older versions wrote is still read.
 */
string profile_to_string (Profile profile) {
    var buf = new StringBuilder ();

    foreach (var path in profile.order) {
        var regions = profile.files.lookup (path);
        if (regions.length == 0) {
            continue;
        }

        buf.append (path);
        buf.append_c ('\n');

        foreach (var r in regions) {
            buf.append_printf ("\t%" + uint64.FORMAT + "\t%" + uint64.FORMAT + "\n", r.off, r.len);
        }
    }

    return buf.str;
}

Profile read_profiles (string[] paths) {
    var profile = new Profile ();

    foreach (var p in paths) {
        FileStream f = FileStream.open (p, "r");
        if (f == null) {
            printerr ("prewarm: %s: %s\n", p, Posix.strerror (Posix.errno));
            continue;
        }

        string? pending = null;
        var pending_used = false;
        string line;

        while ((line = f.read_line ()) != null) {
            if (line == "" || line.has_prefix ("#")) {
                continue;
            }

            if (line[0] == '\t') {
                if (pending == null) {
                    continue;
                }

                var parts = line.substring (1).split ("\t");
                if (parts.length != 2) {
                    continue;
                }

                uint64 off, len;
                if (!uint64.try_parse (parts[0], out off)) continue;
                if (!uint64.try_parse (parts[1], out len)) continue;

                profile.add (pending, off, len);
                pending_used = true;
                continue;
            }

            /* A path with no regions under it covers the whole file. */
            if (pending != null && !pending_used) {
                whole_file (profile, pending);
            }

            var parts = line.strip ().split ("\t");

            if (parts.length == 3) {
                uint64 off = 0, len = 0;
                if (uint64.try_parse (parts[1], out off) && uint64.try_parse (parts[2], out len)) {
                    profile.add (parts[0], off, len);
                }
                pending = null;
                pending_used = false;
                continue;
            }

            pending = parts[0];
            pending_used = false;
        }

        if (pending != null && !pending_used) {
            whole_file (profile, pending);
        }
    }

    return profile;
}

void whole_file (Profile profile, string path) {
    Posix.Stat st;
    if (Posix.stat (path, out st) != 0 || !Posix.S_ISREG (st.st_mode) || st.st_size == 0) {
        return;
    }

    profile.add (path, 0, st.st_size);
}

/* --------------------------------------------------------------- warm / lock */

/* mmap, touch every page, and then check with mincore.
 *
 * Every cheaper approach fails on ZFS, and fails quietly, which is the
 * dangerous part. Measured against a 5504-file profile on an SD card, each
 * followed by an independent residency check:
 *
 *   posix_fadvise(WILLNEED)    4.6s     0% resident   -- ignored outright
 *   pread of every byte      118.8s     0% resident   -- fills the ARC, and
 *                                                        primarycache=metadata
 *                                                        throws it away
 *   mmap with MAP_POPULATE   457.5s   100% resident   -- correct but 5x slower
 *   mmap and touch each page  83.5s    98% resident   -- what this does
 *
 * Only mmap creates page cache pages on ZFS; reads go to the ARC instead, so on
 * a dataset caching metadata only they leave nothing behind. Touching the
 * mapping sequentially is what engages the kernel's readahead, and that
 * batching is worth more than prefaulting the mapping in one call.
 *
 * Returns bytes mincore reports as actually resident, never bytes requested, so
 * a filesystem that ignores all of this cannot report success.
 */
uint8 touch_sink;

uint64 map_region (int fd, uint64 off, uint64 len) {
    var addr = mmap (null, (size_t) len, MMAP_PROT_READ, MMAP_MAP_SHARED, fd, (Posix.off_t) off);
    if ((long) addr == -1) {
        return 0;
    }

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

uint64 warm_profile (Profile profile) {
    uint64 total = 0;

    foreach (var path in profile.order) {
        int fd = Posix.open (path, Posix.O_RDONLY);
        if (fd < 0) {
            continue;
        }

        foreach (var r in profile.files.lookup (path)) {
            total += map_region (fd, r.off, r.len);
        }

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
            if (Posix.stat (path, out st) != 0 || !Posix.S_ISREG (st.st_mode) || st.st_size == 0) {
                continue;
            }

            int fd = Posix.open (path, Posix.O_RDONLY);
            if (fd < 0) {
                continue;
            }

            total += map_region (fd, 0, st.st_size);
            Posix.close (fd);
        }
    } catch (FileError e) {
        printerr ("prewarm: %s: %s\n", dir, e.message);
    }

    return total;
}

int lock_profile (Profile profile, uint64 max_total) {
    uint64 locked = 0, skipped = 0;
    uint mapped = 0, failed = 0;

    foreach (var path in profile.order) {
        int fd = Posix.open (path, Posix.O_RDONLY);
        if (fd < 0) {
            failed++;
            continue;
        }

        foreach (var r in profile.files.lookup (path)) {
            if (max_total != 0 && locked + r.len > max_total) {
                skipped += r.len;
                continue;
            }

            var addr = mmap (null, (size_t) r.len, MMAP_PROT_READ, MMAP_MAP_SHARED,
                             fd, (Posix.off_t) r.off);
            if ((long) addr == -1) {
                failed++;
                continue;
            }

            if (mlock (addr, (size_t) r.len) != 0) {
                printerr ("prewarm: mlock %s: %s\n", path, Posix.strerror (Posix.errno));
                munmap (addr, (size_t) r.len);
                failed++;
                continue;
            }

            locked += r.len;
            mapped++;
        }

        /* The mappings outlive the descriptor, and are deliberately never
         * unmapped -- the lock lasts exactly as long as this process. */
        Posix.close (fd);
    }

    stdout.printf ("locked %" + uint64.FORMAT + " KiB across %u regions in %u files",
                   locked / 1024, mapped, profile.order.length);
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

void write_profile (string path, Profile profile) {
    var tmp = path + ".tmp";

    try {
        FileUtils.set_contents (tmp, profile_to_string (profile));
        FileUtils.rename (tmp, path);
        FileUtils.chmod (path, 0664);
    } catch (FileError e) {
        printerr ("prewarm: %s: %s\n", path, e.message);
    }
}

void usage () {
    printerr ("""usage: prewarm record <name> <pid>...  record the pages those processes touched
       prewarm watch                   keep recording every running process
       prewarm warm                    read the recorded regions and dirs back in
       prewarm lock                    mlock the recorded regions, then hold them
       prewarm status                  report what is covered

environment:
  PREWARM_STATE_DIR       where record and watch write (default /var/lib/prewarm)
  PREWARM_PROFILE_DIRS    :-separated dirs of profiles to warm and lock
  PREWARM_WARM_ONLY_DIRS  :-separated dirs of profiles to warm but never lock
  PREWARM_MIN_SIZE        smallest file to record regions for, bytes (default 0)
  PREWARM_PREFIX          only record paths under this prefix
  PREWARM_MAX_LOCKED      ceiling on locked bytes, 0 for no limit
  PREWARM_WARM_DIRS       :-separated directories to warm whole
  PREWARM_WATCH_INTERVAL  seconds between samples (default 300)
  PREWARM_WATCH_GENERATIONS  samples kept before one ages out (default 6)
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

    uint64 min_size = 0;
    var min_raw = Environment.get_variable ("PREWARM_MIN_SIZE");
    if (min_raw != null) {
        uint64.try_parse (min_raw, out min_size);
    }

    var prefix = Environment.get_variable ("PREWARM_PREFIX");

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

        var profile = new Profile ();
        for (int i = 3; i < args.length; i++) {
            record_pid (profile, args[i], min_size, prefix);
        }
        profile.merge ();

        if (DirUtils.create_with_parents (state_dir, 0775) != 0) {
            printerr ("prewarm: cannot create %s: %s\n", state_dir, Posix.strerror (Posix.errno));
            return 1;
        }

        write_profile (Path.build_filename (state_dir, args[2] + ".pages"), profile);

        stdout.printf ("%s: %u regions in %u files, %" + uint64.FORMAT + " MiB\n",
                       args[2], profile.region_count (), profile.order.length,
                       profile.total_bytes () / (1024 * 1024));
        return 0;

    case "watch":
        var interval = 300;
        var interval_raw = Environment.get_variable ("PREWARM_WATCH_INTERVAL");
        if (interval_raw != null) {
            interval = int.parse (interval_raw);
        }
        if (interval < 10) {
            interval = 10;
        }

        var generations = 6;
        var gens_raw = Environment.get_variable ("PREWARM_WATCH_GENERATIONS");
        if (gens_raw != null) {
            generations = int.parse (gens_raw);
        }
        if (generations < 1) {
            generations = 1;
        }

        if (DirUtils.create_with_parents (state_dir, 0775) != 0) {
            printerr ("prewarm: cannot create %s: %s\n", state_dir, Posix.strerror (Posix.errno));
            return 1;
        }

        stdout.printf ("watching every %ds, %d generations\n", interval, generations);
        stdout.flush ();

        for (int cycle = 0; ; cycle++) {
            var sample = new Profile ();
            uint sampled = 0;

            try {
                var proc = Dir.open ("/proc");
                string? entry;

                while ((entry = proc.read_name ()) != null) {
                    if (!(entry[0] >= '0' && entry[0] <= '9')) {
                        continue;
                    }

                    /* Never sample ourselves. `prewarm lock` maps every locked
                     * region into its own address space and faults it in, so
                     * its pagemap is the locked set -- recording that would
                     * feed the profile back into itself and nothing would ever
                     * age out. An application has no such problem: locking
                     * fills the page cache, but a process only gets a page
                     * table entry for a page it actually touched. */
                    string comm;
                    try {
                        FileUtils.get_contents ("/proc/%s/comm".printf (entry), out comm);
                    } catch (FileError e) {
                        continue;
                    }

                    if (comm.strip () == "prewarm") {
                        continue;
                    }

                    record_pid (sample, entry, min_size, prefix);
                    sampled++;
                }
            } catch (FileError e) {
                printerr ("prewarm: /proc: %s\n", e.message);
            }

            sample.merge ();

            /* Generations rather than one file that only ever grows. warm and
             * lock merge every profile in the directory, so the union of the
             * generations is what gets used, and a page that stops being
             * touched simply stops being rewritten and falls out after this
             * many cycles. Decay with no bookkeeping -- and it is also what
             * makes this survive an update, since paths that no longer exist
             * stop appearing in samples. */
            write_profile (Path.build_filename (state_dir,
                                                "auto-%d.pages".printf (cycle % generations)),
                           sample);

            stdout.printf ("generation %d: %u processes, %u regions in %u files, %"
                           + uint64.FORMAT + " MiB\n",
                           cycle % generations, sampled, sample.region_count (),
                           sample.order.length, sample.total_bytes () / (1024 * 1024));
            stdout.flush ();

            Posix.sleep (interval);
        }

    case "warm":
        var profile = read_profiles (profiles_in (profile_dirs + ":" + warm_only_dirs));
        profile.merge ();

        var bytes = warm_profile (profile);
        stdout.printf ("warmed %" + uint64.FORMAT + " MiB of recorded regions\n",
                       bytes / (1024 * 1024));

        foreach (var dir in warm_dirs_raw.split (":")) {
            if (dir == "" || !FileUtils.test (dir, FileTest.IS_DIR)) {
                continue;
            }
            stdout.printf ("warmed %" + uint64.FORMAT + " MiB from %s\n",
                           warm_dir (dir) / (1024 * 1024), dir);
        }
        return 0;

    case "lock":
        uint64 max_total = 0;
        var max_raw = Environment.get_variable ("PREWARM_MAX_LOCKED");
        if (max_raw != null) {
            uint64.try_parse (max_raw, out max_total);
        }

        var to_lock = read_profiles (profiles_in (profile_dirs));
        to_lock.merge ();

        if (to_lock.order.length == 0) {
            printerr ("prewarm: nothing recorded to lock\n");
            return 0;
        }

        return lock_profile (to_lock, max_total);

    case "status":
        var profiles = profiles_in (profile_dirs + ":" + warm_only_dirs);
        var locked_set = new GenericSet<string> (str_hash, str_equal);
        foreach (var lp in profiles_in (profile_dirs)) {
            locked_set.add (lp);
        }

        stdout.printf ("%-16s %8s %8s %10s  %s\n", "profile", "files", "regions", "size", "held");

        foreach (var p in profiles) {
            var one = read_profiles ({ p });
            one.merge ();

            stdout.printf ("%-16s %8u %8u %9" + uint64.FORMAT + "M  %s\n",
                           Path.get_basename (p).replace (".pages", "").replace (".files", ""),
                           one.order.length, one.region_count (),
                           one.total_bytes () / (1024 * 1024),
                           locked_set.contains (p) ? "warm+lock" : "warm");
        }

        var all = read_profiles (profiles);
        all.merge ();
        stdout.printf ("%-16s %8u %8u %9" + uint64.FORMAT + "M  (shared pages counted once)\n",
                       "= merged", all.order.length, all.region_count (),
                       all.total_bytes () / (1024 * 1024));
        return 0;

    default:
        usage ();
        return 1;
    }
}
