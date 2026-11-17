// Read-only folder walker behind the space map. It opens directories for
// listing only and never writes, moves or deletes.
//
// Sizes are allocated bytes, so compressed and sparse files count what they
// occupy on disk. A hard-linked file is counted once, its bytes split evenly
// between its names. Junctions and symbolic links are never followed.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Winnow
{
    public sealed class WalkOptions
    {
        public string Root;
        public string[] Skip = new string[0];
        public string[] BlockPatterns = new string[0];
        public string[] DocumentPatterns = new string[0];
        public string[] NotablePatterns = new string[0];
        public long NotableMinBytes = 64L << 20;
        public long KeepMinBytes = 1L << 20;
        public int KeepDepth = 3;
        public int Threads = 8;
        // Off for FAT and ReFS, whose 64-bit file ids are not unique.
        public bool DedupeHardLinks = true;
    }

    public sealed class DirSize
    {
        public string Path;
        public int Depth;
        public long Bytes;
        // What deleting the folder would free: files with a single name, and
        // hard-linked files whose every name is inside the folder.
        public long FreeableBytes;
        public long Files;
        public DateTime NewestWriteUtc;
        public int BlockedFiles;
        public int DocumentFiles;
    }

    public sealed class FileHit
    {
        public string Path;
        public long Bytes;
        public long Length;
        public DateTime LastWriteUtc;
    }

    public sealed class SpaceWalk
    {
        public string Root;
        public bool Exists;
        public long Bytes;
        public long Files;
        public long FolderCount;
        public long LinksSkipped;
        public long HardLinkNames;
        public double Seconds;
        public List<DirSize> Folders = new List<DirSize>();
        public List<FileHit> Notable = new List<FileHit>();
        public List<string> BlockedPaths = new List<string>();
        public List<string> Denied = new List<string>();
        public List<string> Skipped = new List<string>();

        Dictionary<string, DirSize> index;

        // Null when the folder was not kept: under KeepMinBytes, or not walked.
        public DirSize Find(string path)
        {
            if (index == null)
            {
                var d = new Dictionary<string, DirSize>(StringComparer.OrdinalIgnoreCase);
                foreach (var f in Folders) d[f.Path] = f;
                index = d;
            }
            DirSize hit;
            return index.TryGetValue(path, out hit) ? hit : null;
        }

        public List<DirSize> FoldersUnder(string folder)
        {
            var prefix = folder.TrimEnd('\\') + "\\";
            var list = new List<DirSize>();
            foreach (var f in Folders)
                if (f.Path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) list.Add(f);
            return list;
        }

        public List<string> BlockedUnder(string path)
        {
            var prefix = path.TrimEnd('\\') + "\\";
            var list = new List<string>();
            foreach (var p in BlockedPaths)
                if (p.Equals(path, StringComparison.OrdinalIgnoreCase) ||
                    p.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) list.Add(p);
            return list;
        }

        public List<string> DeniedUnder(string folder)
        {
            var prefix = folder.TrimEnd('\\') + "\\";
            var list = new List<string>();
            foreach (var p in Denied)
                if (p.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) list.Add(p);
            return list;
        }
    }

    public static class SpaceWalker
    {
        public static System.Threading.Tasks.Task<SpaceWalk> Start(WalkOptions options)
        {
            return System.Threading.Tasks.Task.Factory.StartNew(() => Walk(options),
                System.Threading.Tasks.TaskCreationOptions.LongRunning);
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
                                                 uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, IntPtr buffer, uint size);

        const uint FILE_LIST_DIRECTORY = 0x1;
        const uint FILE_SHARE_ALL = 0x7;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const int FileIdBothDirectoryInfo = 10;
        const uint ATTR_DIRECTORY = 0x10;
        const uint ATTR_REPARSE_POINT = 0x400;
        const int BufferSize = 64 * 1024;
        const int Shards = 64;
        const int MaxListed = 20000;

        sealed class Frame
        {
            public string Name;
            public int Parent;
            public int Depth;
            public long Own;
            public long OwnFreeable;
            public long Files;
            public long Newest;
            public int Blocked;
            public int Documents;
            // Aggregates, filled after the walk
            public long Bytes;
            public long Freeable;
            public long AllFiles;
            public long AllNewest;
            public int AllBlocked;
            public int AllDocuments;
        }

        struct Slot
        {
            public int Frame;
            public long Alloc;
        }

        sealed class Matcher
        {
            readonly string[] exact, prefix, suffix;

            public Matcher(string[] patterns)
            {
                var e = new List<string>(); var p = new List<string>(); var s = new List<string>();
                foreach (var raw in patterns ?? new string[0])
                {
                    if (string.IsNullOrEmpty(raw)) continue;
                    if (raw.StartsWith("*")) s.Add(raw.Substring(1));
                    else if (raw.EndsWith("*")) p.Add(raw.Substring(0, raw.Length - 1));
                    else e.Add(raw);
                }
                exact = e.ToArray(); prefix = p.ToArray(); suffix = s.ToArray();
            }

            public bool Match(string name)
            {
                foreach (var x in suffix) if (name.EndsWith(x, StringComparison.OrdinalIgnoreCase)) return true;
                foreach (var x in prefix) if (name.StartsWith(x, StringComparison.OrdinalIgnoreCase)) return true;
                foreach (var x in exact) if (name.Equals(x, StringComparison.OrdinalIgnoreCase)) return true;
                return false;
            }
        }

        public static SpaceWalk Walk(WalkOptions o)
        {
            var started = DateTime.UtcNow;
            var walk = new SpaceWalk();
            string root = (o.Root ?? "").TrimEnd('\\');
            walk.Root = root;
            if (root.Length < 2 || root[1] != ':') return walk;

            var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var s in o.Skip ?? new string[0]) if (!string.IsNullOrEmpty(s)) skip.Add(s.TrimEnd('\\'));

            var block = new Matcher(o.BlockPatterns);
            var docs = new Matcher(o.DocumentPatterns);
            var notable = new Matcher(o.NotablePatterns);

            var frames = new List<Frame>();
            var paths = new List<string>();
            var seen = new Dictionary<long, Slot>[Shards];
            for (int i = 0; i < Shards; i++) seen[i] = new Dictionary<long, Slot>();
            var extraNames = new List<KeyValuePair<long, int>>();

            if (!IsDirectory(root))
            {
                MeasureFile(root, walk, block, docs);
                walk.Seconds = (DateTime.UtcNow - started).TotalSeconds;
                return walk;
            }
            walk.Exists = true;

            frames.Add(new Frame { Name = root, Parent = -1 });
            paths.Add(root);
            var work = new Stack<int>();
            work.Push(0);
            int outstanding = 1;
            var gate = new object();

            ThreadStart body = delegate
            {
                IntPtr buffer = Marshal.AllocHGlobal(BufferSize);
                var children = new List<string>();
                try
                {
                    while (true)
                    {
                        int index; string path; Frame frame;
                        lock (gate)
                        {
                            while (work.Count == 0 && outstanding > 0) Monitor.Wait(gate);
                            if (outstanding == 0) { Monitor.PulseAll(gate); return; }
                            index = work.Pop();
                            frame = frames[index];
                            path = paths[index];
                            paths[index] = null;
                        }

                        children.Clear();
                        try
                        {
                            ListFolder(path, index, frame, buffer, children, walk, seen, extraNames,
                                       block, docs, notable, o.NotableMinBytes, o.DedupeHardLinks);
                        }
                        catch (Exception)
                        {
                            lock (walk.Denied) if (walk.Denied.Count < MaxListed) walk.Denied.Add(path);
                        }

                        lock (gate)
                        {
                            foreach (var child in children)
                            {
                                if (skip.Contains(child))
                                {
                                    walk.Skipped.Add(child);
                                    continue;
                                }
                                int ci = frames.Count;
                                frames.Add(new Frame
                                {
                                    Name = child.Substring(path.Length + 1),
                                    Parent = index,
                                    Depth = frame.Depth + 1
                                });
                                paths.Add(child);
                                work.Push(ci);
                                outstanding++;
                            }
                            outstanding--;
                            Monitor.PulseAll(gate);
                        }
                    }
                }
                finally { Marshal.FreeHGlobal(buffer); }
            };

            int count = Math.Max(1, o.Threads);
            var threads = new Thread[count];
            for (int i = 0; i < count; i++)
            {
                threads[i] = new Thread(body);
                threads[i].IsBackground = true;
                threads[i].Start();
            }
            foreach (var t in threads) t.Join();

            ShareHardLinks(frames, seen, extraNames, walk);
            Aggregate(frames);
            Export(frames, walk, o.KeepMinBytes, o.KeepDepth);

            var top = frames[0];
            walk.Bytes = top.Bytes;
            walk.Files = top.AllFiles;
            walk.FolderCount = frames.Count - 1;
            walk.Seconds = (DateTime.UtcNow - started).TotalSeconds;
            return walk;
        }

        static void ListFolder(string path, int index, Frame frame, IntPtr buffer, List<string> children,
                               SpaceWalk walk, Dictionary<long, Slot>[] seen, List<KeyValuePair<long, int>> extraNames,
                               Matcher block, Matcher docs, Matcher notable, long notableMin, bool dedupe)
        {
            using (var h = CreateFileW(@"\\?\" + path + @"\", FILE_LIST_DIRECTORY, FILE_SHARE_ALL, IntPtr.Zero,
                                       OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
            {
                if (h.IsInvalid)
                {
                    lock (walk.Denied) if (walk.Denied.Count < MaxListed) walk.Denied.Add(path);
                    return;
                }
                while (GetFileInformationByHandleEx(h, FileIdBothDirectoryInfo, buffer, BufferSize))
                {
                    int offset = 0;
                    while (true)
                    {
                        // FILE_ID_BOTH_DIR_INFO
                        IntPtr p = IntPtr.Add(buffer, offset);
                        int next = Marshal.ReadInt32(p, 0);
                        long lastWrite = Marshal.ReadInt64(p, 24);
                        long length = Marshal.ReadInt64(p, 40);
                        long alloc = Marshal.ReadInt64(p, 48);
                        uint attributes = (uint)Marshal.ReadInt32(p, 56);
                        int nameBytes = Marshal.ReadInt32(p, 60);
                        uint reparseTag = (uint)Marshal.ReadInt32(p, 64);   // EaSize holds the tag on reparse points
                        long fileId = Marshal.ReadInt64(p, 96);
                        string name = Marshal.PtrToStringUni(IntPtr.Add(p, 104), nameBytes / 2);

                        if (name != "." && name != "..")
                        {
                            if ((attributes & ATTR_DIRECTORY) != 0)
                            {
                                // Cloud-file folders (OneDrive) are reparse points that hold real files.
                                bool cloud = (reparseTag & 0xFFFF0FFF) == 0x9000001A;
                                if ((attributes & ATTR_REPARSE_POINT) != 0 && !cloud)
                                    Interlocked.Increment(ref walk.LinksSkipped);
                                else
                                    children.Add(path + "\\" + name);
                            }
                            else
                            {
                                bool first = true;
                                if (dedupe && fileId != 0)
                                {
                                    var shard = seen[(int)((ulong)fileId % Shards)];
                                    lock (shard)
                                    {
                                        if (shard.ContainsKey(fileId)) first = false;
                                        else shard[fileId] = new Slot { Frame = index, Alloc = alloc };
                                    }
                                    if (!first)
                                    {
                                        lock (extraNames) extraNames.Add(new KeyValuePair<long, int>(fileId, index));
                                        Interlocked.Increment(ref walk.HardLinkNames);
                                    }
                                }
                                if (first)
                                {
                                    frame.Own += alloc;
                                    frame.OwnFreeable += alloc;
                                }
                                frame.Files++;
                                if (lastWrite > frame.Newest) frame.Newest = lastWrite;

                                string full = null;
                                if (block.Match(name))
                                {
                                    frame.Blocked++;
                                    full = path + "\\" + name;
                                    lock (walk.BlockedPaths) if (walk.BlockedPaths.Count < MaxListed) walk.BlockedPaths.Add(full);
                                }
                                else if (docs.Match(name))
                                {
                                    frame.Documents++;
                                }
                                if (alloc >= notableMin && notable.Match(name))
                                {
                                    if (full == null) full = path + "\\" + name;
                                    var hit = new FileHit { Path = full, Bytes = alloc, Length = length, LastWriteUtc = ToUtc(lastWrite) };
                                    lock (walk.Notable) walk.Notable.Add(hit);
                                }
                            }
                        }
                        if (next == 0) break;
                        offset += next;
                    }
                }
            }
        }

        static void ShareHardLinks(List<Frame> frames, Dictionary<long, Slot>[] seen,
                                   List<KeyValuePair<long, int>> extraNames, SpaceWalk walk)
        {
            if (extraNames.Count == 0) return;
            var names = new Dictionary<long, List<int>>();
            foreach (var kv in extraNames)
            {
                List<int> list;
                if (!names.TryGetValue(kv.Key, out list)) { list = new List<int>(); names[kv.Key] = list; }
                list.Add(kv.Value);
            }
            foreach (var kv in names)
            {
                var slot = seen[(int)((ulong)kv.Key % Shards)][kv.Key];
                int count = kv.Value.Count + 1;
                long share = slot.Alloc / count;

                var first = frames[slot.Frame];
                first.Own -= share * (count - 1);
                first.OwnFreeable -= slot.Alloc;

                int common = slot.Frame;
                foreach (int f in kv.Value)
                {
                    frames[f].Own += share;
                    common = CommonAncestor(frames, common, f);
                }
                // Deleting the folder holding every name frees the file.
                frames[common].OwnFreeable += slot.Alloc;
            }
        }

        static int CommonAncestor(List<Frame> frames, int a, int b)
        {
            while (a != b)
            {
                if (frames[a].Depth >= frames[b].Depth) a = frames[a].Parent;
                else b = frames[b].Parent;
            }
            return a;
        }

        static void Aggregate(List<Frame> frames)
        {
            foreach (var f in frames)
            {
                f.Bytes = f.Own; f.Freeable = f.OwnFreeable; f.AllFiles = f.Files; f.AllNewest = f.Newest;
                f.AllBlocked = f.Blocked; f.AllDocuments = f.Documents;
            }
            // A child is always added after its parent.
            for (int i = frames.Count - 1; i > 0; i--)
            {
                var f = frames[i];
                var p = frames[f.Parent];
                p.Bytes += f.Bytes;
                p.Freeable += f.Freeable;
                p.AllFiles += f.AllFiles;
                if (f.AllNewest > p.AllNewest) p.AllNewest = f.AllNewest;
                p.AllBlocked += f.AllBlocked;
                p.AllDocuments += f.AllDocuments;
            }
        }

        static void Export(List<Frame> frames, SpaceWalk walk, long keepMin, int keepDepth)
        {
            var fullPath = new string[frames.Count];
            fullPath[0] = frames[0].Name;
            for (int i = 1; i < frames.Count; i++)
            {
                var f = frames[i];
                if (f.Depth > keepDepth && f.Bytes < keepMin) continue;
                fullPath[i] = Path(frames, fullPath, i);
            }
            for (int i = 0; i < frames.Count; i++)
            {
                if (fullPath[i] == null) continue;
                var f = frames[i];
                string shown = fullPath[i];
                if (i == 0 && shown.Length == 2) shown += "\\";
                walk.Folders.Add(new DirSize
                {
                    Path = shown, Depth = f.Depth, Bytes = f.Bytes, FreeableBytes = f.Freeable,
                    Files = f.AllFiles, NewestWriteUtc = ToUtc(f.AllNewest),
                    BlockedFiles = f.AllBlocked, DocumentFiles = f.AllDocuments
                });
            }
        }

        static string Path(List<Frame> frames, string[] cache, int i)
        {
            if (cache[i] != null) return cache[i];
            var f = frames[i];
            string p = Path(frames, cache, f.Parent) + "\\" + f.Name;
            cache[i] = p;
            return p;
        }

        static bool IsDirectory(string path)
        {
            try { return System.IO.Directory.Exists(@"\\?\" + path + @"\"); } catch { return false; }
        }

        // A file is measured from its folder's listing, which works even for
        // files no one may open, such as pagefile.sys.
        static void MeasureFile(string path, SpaceWalk walk, Matcher block, Matcher docs)
        {
            int cut = path.LastIndexOf('\\');
            if (cut < 2) return;
            string parent = path.Substring(0, cut);
            string leaf = path.Substring(cut + 1);
            IntPtr buffer = Marshal.AllocHGlobal(BufferSize);
            try
            {
                using (var h = CreateFileW(@"\\?\" + parent + @"\", FILE_LIST_DIRECTORY, FILE_SHARE_ALL, IntPtr.Zero,
                                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
                {
                    if (h.IsInvalid) return;
                    while (GetFileInformationByHandleEx(h, FileIdBothDirectoryInfo, buffer, BufferSize))
                    {
                        int offset = 0;
                        while (true)
                        {
                            IntPtr p = IntPtr.Add(buffer, offset);
                            int next = Marshal.ReadInt32(p, 0);
                            uint attributes = (uint)Marshal.ReadInt32(p, 56);
                            int nameBytes = Marshal.ReadInt32(p, 60);
                            string name = Marshal.PtrToStringUni(IntPtr.Add(p, 104), nameBytes / 2);
                            if ((attributes & ATTR_DIRECTORY) == 0 && name.Equals(leaf, StringComparison.OrdinalIgnoreCase))
                            {
                                long alloc = Marshal.ReadInt64(p, 48);
                                long lastWrite = Marshal.ReadInt64(p, 24);
                                walk.Exists = true;
                                walk.Bytes = alloc;
                                walk.Files = 1;
                                walk.Folders.Add(new DirSize
                                {
                                    Path = path, Bytes = alloc, FreeableBytes = alloc, Files = 1,
                                    NewestWriteUtc = ToUtc(lastWrite),
                                    BlockedFiles = block.Match(name) ? 1 : 0,
                                    DocumentFiles = docs.Match(name) ? 1 : 0
                                });
                                return;
                            }
                            if (next == 0) break;
                            offset += next;
                        }
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        static DateTime ToUtc(long fileTime)
        {
            if (fileTime <= 0) return DateTime.MinValue;
            try { return DateTime.FromFileTimeUtc(fileTime); } catch { return DateTime.MinValue; }
        }
    }
}
