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
 * A profile is a set of files, each carrying the pages of it that matter, when
 * each was last seen, and how often. Held in memory as one path with a sorted
 * array of pages; written to disk as one path with its runs of pages, so a
 * path appears once however many regions it has.
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

long page_size;

/* One page of one file, and what is known about it. Kept per page rather than
 * per region because that is the granularity the counts mean anything at: two
 * samples rarely fault exactly the same span, and splitting regions to fit
 * would lose the counts at every boundary. Runs are recovered on the way out. */
struct Page {
    public uint64 index;
    public uint32 hits;
    public int64  seen;
}

/* A run of consecutive pages agreeing on hits and last-seen, which is what a
 * profile line holds and what warm and lock operate on. */
struct Run {
    public uint64 off;
    public uint64 len;
    public uint32 hits;
    public int64  seen;
}

class Profile : Object {
    public GenericArray<string> order = new GenericArray<string> ();
    public HashTable<string, GenericArray<Page?>> files =
        new HashTable<string, GenericArray<Page?>> (str_hash, str_equal);

    public GenericArray<Page?> pages_for (string path) {
        var existing = files.lookup (path);
        if (existing != null) {
            return existing;
        }

        var fresh = new GenericArray<Page?> ();
        files.insert (path, fresh);
        order.add (path);
        return fresh;
    }

    public void add_run (string path, uint64 off, uint64 len, uint32 hits, int64 seen) {
        if (len == 0) {
            return;
        }

        var pages = pages_for (path);
        var first = off / page_size;
        var count = (len + page_size - 1) / page_size;

        for (uint64 i = 0; i < count; i++) {
            pages.add (Page () { index = first + i, hits = hits, seen = seen });
        }
    }

    /* Sort by page and fold duplicates, adding their hits and keeping the most
     * recent sighting. This is what turns "seen again" into a count: a sample
     * contributes its pages, and the pages already present absorb them. */
    public void consolidate () {
        foreach (var path in order) {
            var pages = files.lookup (path);

            pages.sort ((a, b) => {
                if (a.index < b.index) return -1;
                if (a.index > b.index) return 1;
                return 0;
            });

            var folded = new GenericArray<Page?> ();
            for (int i = 0; i < pages.length; i++) {
                var cur = pages[i];

                while (i + 1 < pages.length && pages[i + 1].index == cur.index) {
                    var hits = (uint64) cur.hits + pages[i + 1].hits;
                    cur.hits = (uint32) uint64.min (hits, uint32.MAX);
                    if (pages[i + 1].seen > cur.seen) {
                        cur.seen = pages[i + 1].seen;
                    }
                    i++;
                }

                folded.add (cur);
            }

            files.replace (path, folded);
        }
    }

    /* Anything not seen since `cutoff` is dropped, and a file with nothing left
     * goes with it. This is the whole of the ageing policy -- there are no
     * generations to rotate, just a last-seen stamp per page. */
    public void prune (int64 cutoff) {
        var kept_order = new GenericArray<string> ();

        foreach (var path in order) {
            var pages = files.lookup (path);
            var kept = new GenericArray<Page?> ();

            foreach (var p in pages) {
                if (p.seen >= cutoff) {
                    kept.add (p);
                }
            }

            if (kept.length == 0) {
                files.remove (path);
                continue;
            }

            files.replace (path, kept);
            kept_order.add (path);
        }

        order = kept_order;
    }

    /* Consecutive pages agreeing on hits and last-seen collapse into one run,
     * which is what gets written and what warm and lock iterate. */
    public GenericArray<Run?> runs_for (string path) {
        var runs = new GenericArray<Run?> ();
        var pages = files.lookup (path);

        for (int i = 0; i < pages.length; i++) {
            var first = pages[i];
            uint64 count = 1;

            while (i + 1 < pages.length
                   && pages[i + 1].index == first.index + count
                   && pages[i + 1].hits == first.hits
                   && pages[i + 1].seen == first.seen) {
                count++;
                i++;
            }

            runs.add (Run () {
                off = first.index * page_size,
                len = count * page_size,
                hits = first.hits,
                seen = first.seen
            });
        }

        return runs;
    }

    public uint64 total_bytes () {
        uint64 total = 0;
        foreach (var path in order) {
            total += (uint64) files.lookup (path).length * page_size;
        }
        return total;
    }

    public uint page_count () {
        uint n = 0;
        foreach (var path in order) {
            n += files.lookup (path).length;
        }
        return n;
    }
}

/* ---------------------------------------------------------------- recording */

/* Split on runs of spaces, stopping after `limit` fields so the last one keeps
 * whatever is left -- which for a maps line is the path, spaces and all. */
string[] split_fields (string line, int limit) {
    var fields = new GenericArray<string> ();
    int i = 0;
    var len = line.length;

    while (i < len && fields.length < limit - 1) {
        while (i < len && line[i] == ' ') {
            i++;
        }

        var start = i;
        while (i < len && line[i] != ' ') {
            i++;
        }

        if (i > start) {
            fields.add (line.slice (start, i));
        }
    }

    while (i < len && line[i] == ' ') {
        i++;
    }

    if (i < len) {
        fields.add (line.substring (i).chomp ());
    }

    return fields.data;
}

void record_pid (Profile profile, string pid, uint64 min_size, string? prefix, int64 now) {
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
        /* address perms offset dev inode path
         *
         * Split by hand rather than with a regex. A sample reads the maps of
         * every process on the system, so this runs tens of thousands of times
         * per pass, and Regex.split_simple was the only part of sampling that
         * was not a syscall. */
        var parts = split_fields (line, 6);
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
                if (foff < (uint64) st.st_size) {
                    profile.add_run (path, foff, page_size, 1, now);
                }
            }

            i += have;
        }
    }

    Posix.close (pagemap);
}

/* ----------------------------------------------------------------- profiles */

/* On disk a profile is a path followed by its runs, indented, so a path appears
 * once however many runs it has:
 *
 *     /usr/lib/libwebkitgtk-6.0.so.4
 *     <TAB>offset<TAB>length<TAB>hits<TAB>last-seen
 *
 * hits is how many samples have found the pages of that run mapped, and
 * last-seen is when the most recent of those was, as a unix time. Together they
 * are what lets a profile age -- pages stop being refreshed and eventually fall
 * past the retention window -- and what lets the lock budget spend itself on
 * the most used pages rather than on whichever happened to sort first.
 *
 * A path alone, with nothing indented under it, means the whole file, which is
 * how a profile can be declared by hand rather than recorded.
 *
 * Older forms are still read: runs of `offset<TAB>length` without the counts,
 * and flat `path<TAB>offset<TAB>length` lines.
 */
string profile_to_string (Profile profile) {
    var buf = new StringBuilder ();

    foreach (var path in profile.order) {
        var runs = profile.runs_for (path);
        if (runs.length == 0) {
            continue;
        }

        buf.append (path);
        buf.append_c ('\n');

        foreach (var r in runs) {
            buf.append_printf ("\t%" + uint64.FORMAT + "\t%" + uint64.FORMAT + "\t%u\t%" + int64.FORMAT + "\n",
                               r.off, r.len, r.hits, r.seen);
        }
    }

    return buf.str;
}

Profile read_profiles (string[] paths, int64 now) {
    var profile = new Profile ();

    foreach (var p in paths) {
        FileStream f = FileStream.open (p, "r");
        if (f == null) {
            /* Not yet written is the normal state on a first run, and not
             * worth a line of output every time. */
            if (Posix.errno != Posix.ENOENT) {
                printerr ("prewarm: %s: %s\n", p, Posix.strerror (Posix.errno));
            }
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
                if (parts.length < 2) {
                    continue;
                }

                uint64 off = 0, len = 0;
                if (!uint64.try_parse (parts[0], out off)) continue;
                if (!uint64.try_parse (parts[1], out len)) continue;

                uint32 hits = 1;
                int64 seen = now;

                if (parts.length >= 4) {
                    uint64 h = 1;
                    int64 s = now;
                    if (uint64.try_parse (parts[2], out h)) {
                        hits = (uint32) uint64.min (h, uint32.MAX);
                    }
                    if (int64.try_parse (parts[3], out s)) {
                        seen = s;
                    }
                }

                profile.add_run (pending, off, len, hits, seen);
                pending_used = true;
                continue;
            }

            /* A path with no runs under it covers the whole file. */
            if (pending != null && !pending_used) {
                whole_file (profile, pending, now);
            }

            var parts = line.strip ().split ("\t");

            if (parts.length == 3) {
                uint64 off = 0, len = 0;
                if (uint64.try_parse (parts[1], out off) && uint64.try_parse (parts[2], out len)) {
                    profile.add_run (parts[0], off, len, 1, now);
                }
                pending = null;
                pending_used = false;
                continue;
            }

            pending = parts[0];
            pending_used = false;
        }

        if (pending != null && !pending_used) {
            whole_file (profile, pending, now);
        }
    }

    profile.consolidate ();
    return profile;
}

/* Declared whole files are stamped with the current time every read, so a
 * declaration never ages out. It is a statement about what matters, not an
 * observation that might stop being true. */
void whole_file (Profile profile, string path, int64 now) {
    Posix.Stat st;
    if (Posix.stat (path, out st) != 0 || !Posix.S_ISREG (st.st_mode) || st.st_size == 0) {
        return;
    }

    profile.add_run (path, 0, st.st_size, 1, now);
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

        foreach (var r in profile.runs_for (path)) {
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

struct Candidate {
    public string path;
    public uint64 off;
    public uint64 len;
    public uint32 hits;
}

int lock_profile (Profile profile, uint64 max_total) {
    var candidates = new GenericArray<Candidate?> ();

    foreach (var path in profile.order) {
        foreach (var r in profile.runs_for (path)) {
            candidates.add (Candidate () { path = path, off = r.off, len = r.len, hits = r.hits });
        }
    }

    /* Most used first, so a budget too small for everything spends itself on
     * the pages most likely to be wanted. Sorting by path instead -- which is
     * what happens without the counts -- drops whatever sorts last, which has
     * nothing to do with how useful it is. */
    candidates.sort ((a, b) => {
        if (a.hits != b.hits) {
            return (b.hits > a.hits) ? 1 : -1;
        }
        return strcmp (a.path, b.path);
    });

    uint64 locked = 0, skipped = 0;
    uint mapped = 0, failed = 0;
    string? open_path = null;
    int fd = -1;

    foreach (var c in candidates) {
        if (max_total != 0 && locked + c.len > max_total) {
            skipped += c.len;
            continue;
        }

        if (open_path != c.path) {
            if (fd >= 0) {
                Posix.close (fd);
            }
            fd = Posix.open (c.path, Posix.O_RDONLY);
            open_path = c.path;
        }

        if (fd < 0) {
            failed++;
            continue;
        }

        var addr = mmap (null, (size_t) c.len, MMAP_PROT_READ, MMAP_MAP_SHARED,
                         fd, (Posix.off_t) c.off);
        if ((long) addr == -1) {
            failed++;
            continue;
        }

        if (mlock (addr, (size_t) c.len) != 0) {
            printerr ("prewarm: mlock %s: %s\n", c.path, Posix.strerror (Posix.errno));
            munmap (addr, (size_t) c.len);
            failed++;
            continue;
        }

        locked += c.len;
        mapped++;
    }

    if (fd >= 0) {
        Posix.close (fd);
    }

    /* The mappings are deliberately never unmapped -- the lock lasts exactly as
     * long as this process, which is why it runs as a service that does nothing
     * else. */
    stdout.printf ("locked %" + uint64.FORMAT + " KiB across %u regions in %u files",
                   locked / 1024, mapped, profile.order.length);
    if (skipped != 0) {
        stdout.printf (", skipped %" + uint64.FORMAT + " KiB least used", skipped / 1024);
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
       prewarm watch                   keep recording, ageing out what stops being used
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
  PREWARM_WATCH_RETENTION seconds a page is kept after it was last seen
                          (default 86400)
""");
}

int main (string[] args) {
    page_size = Posix.sysconf (Posix._SC_PAGESIZE);

    var now = new DateTime.now_utc ().to_unix ();

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
            record_pid (profile, args[i], min_size, prefix, now);
        }
        profile.consolidate ();

        if (DirUtils.create_with_parents (state_dir, 0775) != 0) {
            printerr ("prewarm: cannot create %s: %s\n", state_dir, Posix.strerror (Posix.errno));
            return 1;
        }

        write_profile (Path.build_filename (state_dir, args[2] + ".pages"), profile);

        stdout.printf ("%s: %u pages in %u files, %" + uint64.FORMAT + " MiB\n",
                       args[2], profile.page_count (), profile.order.length,
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

        /* How long a page is kept after the last sample that saw it. This is
         * the only ageing knob, and it is independent of how often samples are
         * taken -- sampling often to catch short-lived processes should not
         * mean forgetting a library nothing has touched for an hour. */
        int64 retention = 86400;
        var ret_raw = Environment.get_variable ("PREWARM_WATCH_RETENTION");
        if (ret_raw != null) {
            retention = int64.parse (ret_raw);
        }
        if (retention < interval) {
            retention = interval;
        }

        if (DirUtils.create_with_parents (state_dir, 0775) != 0) {
            printerr ("prewarm: cannot create %s: %s\n", state_dir, Posix.strerror (Posix.errno));
            return 1;
        }

        /* How long after a new process appears to wait before sampling. A
         * launch is exactly when a profile is most wrong and most worth
         * fixing, but sampling immediately catches a process that has not
         * finished mapping its libraries or drawing its window. */
        var settle = 20;
        var settle_raw = Environment.get_variable ("PREWARM_WATCH_SETTLE");
        if (settle_raw != null) {
            settle = int.parse (settle_raw);
        }
        if (settle < 1) {
            settle = 1;
        }

        /* Floor on how often a sample can be taken, so a shell loop or a build
         * spawning processes cannot turn this into a busy loop. */
        var min_gap = 60;
        var gap_raw = Environment.get_variable ("PREWARM_WATCH_MIN_GAP");
        if (gap_raw != null) {
            min_gap = int.parse (gap_raw);
        }
        if (min_gap < 1) {
            min_gap = 1;
        }

        var auto_path = Path.build_filename (state_dir, "auto.pages");

        stdout.printf ("watching every %ds, %ds after a launch, keeping pages for %"
                       + int64.FORMAT + "h\n", interval, settle, retention / 3600);
        stdout.flush ();

        var seen_pids = new GenericSet<string> (str_hash, str_equal);
        int64 next_scheduled = 0;
        int64 armed = 0;
        var armed_pids = new GenericArray<string> ();
        var first_pass = true;

        while (true) {
            var stamp = new DateTime.now_utc ().to_unix ();

            /* Watching /proc rather than subscribing to anything: a new process
             * is the one signal available on every system, with no session bus,
             * compositor or desktop environment assumed. Reading the directory
             * costs nothing next to the sample it schedules. */
            var live = new GenericSet<string> (str_hash, str_equal);
            var fresh = new GenericArray<string> ();

            try {
                var scan = Dir.open ("/proc");
                string? name;
                while ((name = scan.read_name ()) != null) {
                    if (!(name[0] >= '0' && name[0] <= '9')) {
                        continue;
                    }
                    live.add (name);
                    if (!first_pass && !seen_pids.contains (name)) {
                        fresh.add (name);
                    }
                }
            } catch (FileError e) {
                printerr ("prewarm: /proc: %s\n", e.message);
            }

            seen_pids = live;

            if (fresh.length > 0 && armed == 0) {
                armed = stamp + settle;
                armed_pids = fresh;
            }

            var due = (armed != 0 && stamp >= armed) || stamp >= next_scheduled;

            if (!due) {
                Posix.sleep (5);
                continue;
            }

            if (stamp < next_scheduled - interval + min_gap) {
                Posix.sleep (5);
                continue;
            }

            var by_launch = (armed != 0 && stamp >= armed);

            /* Only sample for a launch if something that triggered it is still
             * running. Most new processes on a busy system are short-lived --
             * a shell command, a helper, a timer -- and sampling for those
             * would turn the interval floor into the sampling rate. Anything
             * that outlives the settle period is the kind of thing worth
             * recording, and has had time to map its libraries. */
            if (by_launch) {
                var survivor = false;
                foreach (var candidate in armed_pids) {
                    if (FileUtils.test ("/proc/" + candidate, FileTest.EXISTS)) {
                        survivor = true;
                        break;
                    }
                }

                armed = 0;
                armed_pids = new GenericArray<string> ();

                if (!survivor && stamp < next_scheduled) {
                    Posix.sleep (5);
                    continue;
                }
            }

            var why = by_launch ? "launch" : "interval";
            armed = 0;
            first_pass = false;

            /* Start from what is already known, so a page seen before keeps its
             * count and its history rather than looking new every time. */
            var profile = read_profiles ({ auto_path }, stamp);
            var known = profile.page_count ();
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

                    record_pid (profile, entry, min_size, prefix, stamp);
                    sampled++;
                }
            } catch (FileError e) {
                printerr ("prewarm: /proc: %s\n", e.message);
            }

            profile.consolidate ();
            profile.prune (stamp - retention);
            write_profile (auto_path, profile);

            stdout.printf ("%s: %u processes, %u pages in %u files, %" + uint64.FORMAT
                           + " MiB (%+d pages)\n",
                           why, sampled, profile.page_count (), profile.order.length,
                           profile.total_bytes () / (1024 * 1024),
                           (int) profile.page_count () - (int) known);
            stdout.flush ();

            next_scheduled = new DateTime.now_utc ().to_unix () + interval;
        }

    case "warm":
        var profile = read_profiles (profiles_in (profile_dirs + ":" + warm_only_dirs), now);
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

        var to_lock = read_profiles (profiles_in (profile_dirs), now);
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

        stdout.printf ("%-14s %7s %8s %9s %7s  %s\n",
                       "profile", "files", "pages", "size", "hits", "held");

        foreach (var p in profiles) {
            var one = read_profiles ({ p }, now);

            uint64 hits = 0;
            uint pages = 0;
            foreach (var path in one.order) {
                foreach (var pg in one.files.lookup (path)) {
                    hits += pg.hits;
                    pages++;
                }
            }

            stdout.printf ("%-14s %7u %8u %8" + uint64.FORMAT + "M %7.1f  %s\n",
                           Path.get_basename (p).replace (".pages", "").replace (".files", ""),
                           one.order.length, one.page_count (),
                           one.total_bytes () / (1024 * 1024),
                           pages > 0 ? (double) hits / pages : 0.0,
                           locked_set.contains (p) ? "warm+lock" : "warm");
        }

        var all = read_profiles (profiles, now);
        stdout.printf ("%-14s %7u %8u %8" + uint64.FORMAT + "M %7s  (shared pages counted once)\n",
                       "= merged", all.order.length, all.page_count (),
                       all.total_bytes () / (1024 * 1024), "");
        return 0;

    default:
        usage ();
        return 1;
    }
}
