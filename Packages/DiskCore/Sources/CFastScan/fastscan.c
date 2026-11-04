#include "CFastScan.h"

#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>

#define CHUNK_BITS 16
#define CHUNK_SIZE (1u << CHUNK_BITS)
#define MAX_CHUNKS (1u << 16)
#define BULK_BUF (128 * 1024)
#define ARENA_BLOCK (1u << 20)
#define SHARDS 64
#define HL_TAG (1ull << 63)

#ifndef SF_DATALESS
#define SF_DATALESS 0x40000000
#endif

// ---------------------------------------------------------------- arenas

typedef struct arena_block {
    struct arena_block *next;
    size_t used, cap;
    char data[];
} arena_block;

// ---------------------------------------------------------------- tree

struct sm_tree {
    _Atomic(sm_node *) chunks[MAX_CHUNKS];
    _Atomic uint32_t count;
    pthread_mutex_t lock;          // chunk allocation + arena list
    arena_block *arenas;
    sm_shared_rec *shared;
    size_t shared_n;
    sm_tree_stats stats;
    void *blob;                    // set when loaded from a snapshot
};

static sm_tree *tree_new(void) {
    sm_tree *t = calloc(1, sizeof(sm_tree));
    if (!t) return NULL;
    pthread_mutex_init(&t->lock, NULL);
    return t;
}

uint32_t sm_tree_count(const sm_tree *t) { return atomic_load(&((sm_tree *)t)->count); }

sm_node *sm_tree_node(const sm_tree *t, uint32_t i) {
    sm_node *c = atomic_load(&((sm_tree *)t)->chunks[i >> CHUNK_BITS]);
    return &c[i & (CHUNK_SIZE - 1)];
}

static uint32_t tree_alloc_node(sm_tree *t) {
    uint32_t i = atomic_fetch_add(&t->count, 1);
    uint32_t c = i >> CHUNK_BITS;
    if (c >= MAX_CHUNKS) abort();
    if (!atomic_load(&t->chunks[c])) {
        pthread_mutex_lock(&t->lock);
        if (!atomic_load(&t->chunks[c])) {
            sm_node *chunk = calloc(CHUNK_SIZE, sizeof(sm_node));
            if (!chunk) abort();
            atomic_store(&t->chunks[c], chunk);
        }
        pthread_mutex_unlock(&t->lock);
    }
    sm_node *n = sm_tree_node(t, i);
    n->first_child = SM_NONE;
    n->next_sibling = SM_NONE;
    return i;
}

void sm_tree_get_stats(const sm_tree *t, sm_tree_stats *out) {
    *out = t->stats;
    out->node_count = sm_tree_count(t);
}

size_t sm_tree_shared_count(const sm_tree *t) { return t->shared_n; }
const sm_shared_rec *sm_tree_shared(const sm_tree *t) { return t->shared; }

size_t sm_tree_path(const sm_tree *t, uint32_t i, char *buf, size_t cap) {
    if (cap == 0) return 0;
    uint32_t stack[512];
    int depth = 0;
    while (i != 0 && i != SM_NONE && depth < 512) {
        stack[depth++] = i;
        i = sm_tree_node(t, i)->parent;
    }
    size_t len = 0;
    for (int d = depth - 1; d >= 0; d--) {
        const sm_node *n = sm_tree_node(t, stack[d]);
        if (d != depth - 1 && len + 1 < cap) buf[len++] = '/';
        size_t l = n->name_len;
        if (len + l >= cap) l = cap - 1 - len;
        memcpy(buf + len, n->name, l);
        len += l;
    }
    buf[len] = 0;
    return len;
}

void sm_tree_free(sm_tree *t) {
    if (!t) return;
    if (t->blob) {
        free(t->blob);
    } else {
        for (uint32_t c = 0; c < MAX_CHUNKS; c++) {
            sm_node *ch = atomic_load(&t->chunks[c]);
            if (!ch) break;
            free(ch);
        }
    }
    arena_block *a = t->arenas;
    while (a) { arena_block *n = a->next; free(a); a = n; }
    free(t->shared);
    pthread_mutex_destroy(&t->lock);
    free(t);
}

// ---------------------------------------------------------------- shared map

typedef struct { uint64_t key; } sh_entry;
typedef struct {
    pthread_mutex_t m;
    uint64_t *keys;   // 0 = empty
    size_t cap, n;
} shard;

static inline uint64_t mix64(uint64_t x) {
    x ^= x >> 33; x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33; return x;
}

// Returns 1 if the key was not present.
static int shard_insert(shard *s, uint64_t key) {
    if (key == 0) key = 1;
    pthread_mutex_lock(&s->m);
    if ((s->n + 1) * 10 >= s->cap * 7) {
        size_t ncap = s->cap ? s->cap * 2 : 1024;
        uint64_t *nk = calloc(ncap, sizeof(uint64_t));
        if (!nk) abort();
        for (size_t i = 0; i < s->cap; i++) {
            uint64_t k = s->keys[i];
            if (!k) continue;
            size_t j = mix64(k) & (ncap - 1);
            while (nk[j]) j = (j + 1) & (ncap - 1);
            nk[j] = k;
        }
        free(s->keys);
        s->keys = nk;
        s->cap = ncap;
    }
    size_t j = mix64(key) & (s->cap - 1);
    while (s->keys[j]) {
        if (s->keys[j] == key) { pthread_mutex_unlock(&s->m); return 0; }
        j = (j + 1) & (s->cap - 1);
    }
    s->keys[j] = key;
    s->n++;
    pthread_mutex_unlock(&s->m);
    return 1;
}

// ---------------------------------------------------------------- scanner

enum { MODE_NORMAL = 0, MODE_SELF_COLLAPSE = 1, MODE_COLLAPSED = 2 };

// An open directory shared by its pending children, which openat() relative to
// it. Path-based open() makes every thread re-resolve the same ancestors and the
// kernel spends most of its time on vnode lock contention.
typedef struct dirref {
    int fd;
    _Atomic int refs;
} dirref;

static void dirref_release(dirref *d) {
    if (d && atomic_fetch_sub(&d->refs, 1) == 1) {
        close(d->fd);
        free(d);
    }
}

typedef struct task {
    char *path;
    dirref *parent;    // NULL for scan roots
    uint32_t name_off; // leaf name = path + name_off
    uint32_t node;     // own node, or collapse target in MODE_COLLAPSED
    uint32_t dev;
    uint8_t mode;
} task;

typedef struct worker worker;

struct sm_scanner {
    sm_scan_opts opts;
    struct attrlist al;
    sm_tree *tree;

    pthread_mutex_t qm;
    pthread_cond_t qc;
    task *stack;
    size_t stack_n, stack_cap;
    size_t pending;

    shard shards[SHARDS];
    _Atomic uint64_t shared_unique;

    _Atomic uint64_t p_files, p_dirs, p_bytes, p_denied;
    _Atomic bool cancel;
};

struct worker {
    sm_scanner *s;
    char *buf;
    arena_block *arena;
    sm_shared_rec *recs;
    size_t recs_n, recs_cap;
    // child scratch
    task *kids;
    size_t kids_n, kids_cap;
};

int sm_default_threads(void) {
    int p = 0;
    size_t len = sizeof(p);
    if (sysctlbyname("hw.perflevel0.physicalcpu", &p, &len, NULL, 0) != 0 || p <= 0) {
        len = sizeof(p);
        if (sysctlbyname("hw.physicalcpu", &p, &len, NULL, 0) != 0 || p <= 0) p = 4;
    }
    int n = p;  // more threads only add kernel lock contention on APFS
    if (n < 4) n = 4;
    if (n > 64) n = 64;
    return n;
}

uint64_t sm_volume_space_used(const char *path) {
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.volattr = ATTR_VOL_INFO | ATTR_VOL_SPACEUSED;
    struct __attribute__((packed)) { uint32_t len; off_t used; } buf;
    if (getattrlist(path, &al, &buf, sizeof buf, 0) != 0) return 0;
    return buf.used > 0 ? (uint64_t)buf.used : 0;
}

int sm_disable_dataless_materialization(void) {
#if defined(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
    return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                          IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
#else
    return 0;
#endif
}

sm_scanner *sm_scanner_create(const sm_scan_opts *opts) {
    sm_scanner *s = calloc(1, sizeof(sm_scanner));
    if (!s) return NULL;
    if (opts) s->opts = *opts;
    if (s->opts.threads <= 0) s->opts.threads = sm_default_threads();
    if (s->opts.big_file_threshold == 0) s->opts.big_file_threshold = 1u << 20;
    pthread_mutex_init(&s->qm, NULL);
    pthread_cond_init(&s->qc, NULL);
    for (int i = 0; i < SHARDS; i++) pthread_mutex_init(&s->shards[i].m, NULL);

    memset(&s->al, 0, sizeof(s->al));
    s->al.bitmapcount = ATTR_BIT_MAP_COUNT;
    s->al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE |
                       ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
    s->al.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH;
    s->al.forkattr = ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT;
    if (s->opts.want_private) s->al.forkattr |= ATTR_CMNEXT_PRIVATESIZE;
    return s;
}

void sm_scanner_progress(sm_scanner *s, sm_progress *out) {
    out->files = atomic_load(&s->p_files);
    out->dirs = atomic_load(&s->p_dirs);
    out->bytes = atomic_load(&s->p_bytes);
    out->denied = atomic_load(&s->p_denied);
}

void sm_scanner_cancel(sm_scanner *s) {
    atomic_store(&s->cancel, true);
    pthread_mutex_lock(&s->qm);
    pthread_cond_broadcast(&s->qc);
    pthread_mutex_unlock(&s->qm);
}

void sm_scanner_free(sm_scanner *s) {
    if (!s) return;
    for (size_t i = 0; i < s->stack_n; i++) { free(s->stack[i].path); dirref_release(s->stack[i].parent); }
    free(s->stack);
    for (int i = 0; i < SHARDS; i++) { free(s->shards[i].keys); pthread_mutex_destroy(&s->shards[i].m); }
    pthread_mutex_destroy(&s->qm);
    pthread_cond_destroy(&s->qc);
    free(s);
}

static const char *arena_put(worker *w, const char *str, size_t len) {
    arena_block *a = w->arena;
    if (!a || a->used + len + 1 > a->cap) {
        size_t cap = len + 1 > ARENA_BLOCK ? len + 1 : ARENA_BLOCK;
        a = malloc(sizeof(arena_block) + cap);
        if (!a) abort();
        a->used = 0;
        a->cap = cap;
        sm_tree *t = w->s->tree;
        pthread_mutex_lock(&t->lock);
        a->next = t->arenas;
        t->arenas = a;
        pthread_mutex_unlock(&t->lock);
        w->arena = a;
    }
    char *dst = a->data + a->used;
    memcpy(dst, str, len);
    dst[len] = 0;
    a->used += len + 1;
    return dst;
}

static void push_tasks(sm_scanner *s, task *ts, size_t n) {
    if (n == 0) return;
    pthread_mutex_lock(&s->qm);
    if (s->stack_n + n > s->stack_cap) {
        size_t nc = s->stack_cap ? s->stack_cap * 2 : 4096;
        while (nc < s->stack_n + n) nc *= 2;
        task *ns = realloc(s->stack, nc * sizeof(task));
        if (!ns) abort();
        s->stack = ns;
        s->stack_cap = nc;
    }
    memcpy(s->stack + s->stack_n, ts, n * sizeof(task));
    s->stack_n += n;
    s->pending += n;
    if (n == 1) pthread_cond_signal(&s->qc); else pthread_cond_broadcast(&s->qc);
    pthread_mutex_unlock(&s->qm);
}

// ---- name classification

static bool name_eq(const char *n, size_t len, const char *lit) {
    size_t l = strlen(lit);
    return len == l && memcmp(n, lit, l) == 0;
}

static const char *ext_of(const char *name, size_t len, size_t *elen) {
    for (size_t i = len; i > 0; i--) {
        if (name[i - 1] == '.') {
            if (i - 1 == 0) return NULL;  // dotfile
            *elen = len - i;
            return name + i;
        }
    }
    return NULL;
}

static bool ext_in(const char *e, size_t el, const char *const *list) {
    if (!e || el == 0 || el > 15) return false;
    char low[16];
    for (size_t i = 0; i < el; i++) low[i] = (char)((e[i] >= 'A' && e[i] <= 'Z') ? e[i] + 32 : e[i]);
    low[el] = 0;
    for (const char *const *p = list; *p; p++) if (strcmp(low, *p) == 0) return true;
    return false;
}

static const char *const IMG_EXT[] = {"jpg", "jpeg", "png", "webp", "tif", "tiff", "exr", "dpx", "bmp", "heic", "tga", NULL};
static const char *const VID_EXT[] = {"mp4", "mov", "mkv", "webm", "avi", "m4v", "mxf", "prores", NULL};
static const char *const AUD_EXT[] = {"wav", "mp3", "m4a", "aac", "flac", "aif", "aiff", "ogg", "caf", NULL};
static const char *const MODEL_EXT[] = {"gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "mlmodel", "npz", "h5", NULL};
static const char *const PKG_EXT[] = {"app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "xcarchive",
                                      "dsym", "photoslibrary", "musiclibrary", "imovielibrary", "fcpbundle",
                                      "tvlibrary", "logicx", "xcframework", "sparsebundle", "lrdata", "docarchive",
                                      "playground", "xcassets", NULL};

static bool is_collapse_name(const char *n, size_t l) {
    static const char *const names[] = {"node_modules", ".git", "__pycache__", ".venv", ".tox", ".nox",
                                        ".next", ".nuxt", ".turbo", ".gradle", ".build", ".mypy_cache",
                                        ".pytest_cache", ".ruff_cache", ".parcel-cache", "_cacache",
                                        ".svelte-kit", ".angular", ".dart_tool", "Pods", NULL};
    for (const char *const *p = names; *p; p++) if (name_eq(n, l, *p)) return true;
    return false;
}

static bool is_children_collapse_name(const char *n, size_t l) {
    return name_eq(n, l, "DerivedData");
}

static uint32_t marker_for(const char *n, size_t l, bool is_dir) {
    switch (n[0]) {
    case '.':
        if (name_eq(n, l, ".git")) return SM_M_GIT;
        if (!is_dir && name_eq(n, l, ".gitignore")) return SM_M_GITIGNORE;
        break;
    case 'p':
        if (name_eq(n, l, "package.json")) return SM_M_PACKAGE_JSON;
        if (name_eq(n, l, "pyproject.toml")) return SM_M_PYPROJECT;
        if (name_eq(n, l, "pyvenv.cfg")) return SM_M_PYVENV_CFG;
        if (name_eq(n, l, "pnpm-lock.yaml")) return SM_M_LOCK_PNPM;
        if (name_eq(n, l, "package-lock.json")) return SM_M_LOCK_NPM;
        if (name_eq(n, l, "poetry.lock")) return SM_M_LOCK_POETRY;
        if (name_eq(n, l, "pom.xml")) return SM_M_POM_XML;
        if (name_eq(n, l, "pubspec.yaml")) return SM_M_PUBSPEC;
        break;
    case 'C':
        if (name_eq(n, l, "Cargo.toml")) return SM_M_CARGO_TOML;
        if (name_eq(n, l, "Cargo.lock")) return SM_M_LOCK_CARGO;
        if (name_eq(n, l, "CACHEDIR.TAG")) return SM_M_CACHEDIR_TAG;
        if (name_eq(n, l, "CMakeLists.txt")) return SM_M_CMAKE;
        break;
    case 'g':
        if (name_eq(n, l, "go.mod")) return SM_M_GO_MOD;
        break;
    case 'P':
        if (name_eq(n, l, "Package.swift")) return SM_M_PACKAGE_SWIFT;
        break;
    case 'y':
        if (name_eq(n, l, "yarn.lock")) return SM_M_LOCK_YARN;
        break;
    case 'b':
        if (name_eq(n, l, "bun.lockb") || name_eq(n, l, "bun.lock")) return SM_M_LOCK_BUN;
        if (name_eq(n, l, "build.gradle") || name_eq(n, l, "build.gradle.kts")) return SM_M_GRADLE;
        break;
    case 'u':
        if (name_eq(n, l, "uv.lock")) return SM_M_LOCK_UV;
        break;
    case 'r':
        if (name_eq(n, l, "requirements.txt")) return SM_M_REQUIREMENTS;
        break;
    case 's':
        if (name_eq(n, l, "setup.py")) return SM_M_SETUP_PY;
        break;
    case 'G':
        if (name_eq(n, l, "Gemfile")) return SM_M_GEMFILE;
        break;
    }
    if (is_dir && l > 10) {
        if (memcmp(n + l - 10, ".xcodeproj", 10) == 0) return SM_M_XCODEPROJ;
        if (l > 12 && memcmp(n + l - 12, ".xcworkspace", 12) == 0) return SM_M_XCODEPROJ;
    }
    return 0;
}

// ---- directory processing

typedef struct {
    uint64_t alloc, shared, logical, files, img_bytes, vid_bytes, aud_bytes, model_bytes;
    uint32_t img_count;
    int64_t mtime;
} acc;

static void atomic_max64(int64_t *p, int64_t v) {
    int64_t cur = __atomic_load_n(p, __ATOMIC_RELAXED);
    while (v > cur && !__atomic_compare_exchange_n(p, &cur, v, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {}
}

static void add_rec(worker *w, sm_shared_rec r) {
    if (w->recs_n == w->recs_cap) {
        size_t nc = w->recs_cap ? w->recs_cap * 2 : 4096;
        sm_shared_rec *nr = realloc(w->recs, nc * sizeof(sm_shared_rec));
        if (!nr) abort();
        w->recs = nr;
        w->recs_cap = nc;
    }
    w->recs[w->recs_n++] = r;
}

static void add_kid(worker *w, task t) {
    if (w->kids_n == w->kids_cap) {
        size_t nc = w->kids_cap ? w->kids_cap * 2 : 256;
        task *nk = realloc(w->kids, nc * sizeof(task));
        if (!nk) abort();
        w->kids = nk;
        w->kids_cap = nc;
    }
    w->kids[w->kids_n++] = t;
}

static char *join_path(const char *dir, const char *name, size_t nlen) {
    size_t dl = strlen(dir);
    bool slash = dl > 0 && dir[dl - 1] == '/';
    char *p = malloc(dl + nlen + 2);
    if (!p) abort();
    memcpy(p, dir, dl);
    size_t o = dl;
    if (!slash) p[o++] = '/';
    memcpy(p + o, name, nlen);
    p[o + nlen] = 0;
    return p;
}

typedef struct {
    const char *name;
    uint32_t len;
    uint32_t flags;
    uint64_t ino;
    int64_t mtime;
} subdir;

static void process_dir(worker *w, task *tk) {
    sm_scanner *s = w->s;
    sm_tree *t = s->tree;
    bool collapsed = tk->mode == MODE_COLLAPSED;
    sm_node *own = sm_tree_node(t, tk->node);

    const int oflags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    int fd;
    if (tk->parent) {
        fd = openat(tk->parent->fd, tk->path + tk->name_off, oflags);
        if (fd < 0 && (errno == EMFILE || errno == ENFILE)) fd = open(tk->path, oflags);
        dirref_release(tk->parent);
        tk->parent = NULL;
    } else {
        fd = open(tk->path, oflags);
    }
    if (fd < 0) {
        atomic_fetch_add(&s->p_denied, 1);
        if (!collapsed) own->flags |= SM_F_DENIED;
        return;
    }
    struct stat st;
    if (fstat(fd, &st) == 0 && (uint32_t)st.st_dev != tk->dev) {
        close(fd);
        if (!collapsed) own->flags |= SM_F_MOUNTPOINT;
        return;
    }
    atomic_fetch_add(&s->p_dirs, 1);

    acc a = {0};
    uint32_t markers = 0;
    uint64_t big_threshold = s->opts.big_file_threshold;
    bool collect = s->opts.collect_shared;

    // Subdirectories are buffered (names live in w->buf only until the next call),
    // so copy them into a scratch arena.
    subdir *subs = NULL;
    size_t subs_n = 0, subs_cap = 0;
    char *names = NULL;
    size_t names_n = 0, names_cap = 0;

    // Big file nodes are created after we know whether this dir collapses.
    typedef struct { const char *name; uint32_t len; uint64_t ino, alloc, shared, logical; int64_t mtime; uint32_t flags; } bigfile;
    bigfile *bigs = NULL;
    size_t bigs_n = 0, bigs_cap = 0;

    for (;;) {
        int n = getattrlistbulk(fd, &s->al, w->buf, BULK_BUF, FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW);
        if (n <= 0) break;
        char *e = w->buf;
        for (int i = 0; i < n; i++) {
            char *f = e;
            uint32_t elen;
            memcpy(&elen, f, 4);
            f += 4;
            e += elen;
            attribute_set_t rs;
            memcpy(&rs, f, sizeof rs);
            f += sizeof rs;
            uint32_t err = 0;
            if (rs.commonattr & ATTR_CMN_ERROR) { memcpy(&err, f, 4); f += 4; }
            const char *name = NULL;
            uint32_t nlen = 0;
            if (rs.commonattr & ATTR_CMN_NAME) {
                attrreference_t r;
                memcpy(&r, f, sizeof r);
                name = f + r.attr_dataoffset;
                nlen = r.attr_length ? r.attr_length - 1 : 0;
                f += sizeof r;
            }
            if (err || !name || nlen == 0) continue;
            uint32_t type = 0;
            if (rs.commonattr & ATTR_CMN_OBJTYPE) { memcpy(&type, f, 4); f += 4; }
            int64_t mtime = 0;
            if (rs.commonattr & ATTR_CMN_MODTIME) { struct timespec ts; memcpy(&ts, f, sizeof ts); mtime = ts.tv_sec; f += sizeof ts; }
            uint32_t bsdflags = 0;
            if (rs.commonattr & ATTR_CMN_FLAGS) { memcpy(&bsdflags, f, 4); f += 4; }
            uint64_t ino = 0;
            if (rs.commonattr & ATTR_CMN_FILEID) { memcpy(&ino, f, 8); f += 8; }
            uint32_t nlink = 1;
            uint64_t alloc = 0, dlen = 0;
            if (rs.fileattr & ATTR_FILE_LINKCOUNT) { memcpy(&nlink, f, 4); f += 4; }
            if (rs.fileattr & ATTR_FILE_ALLOCSIZE) { int64_t v; memcpy(&v, f, 8); alloc = (uint64_t)v; f += 8; }
            if (rs.fileattr & ATTR_FILE_DATALENGTH) { int64_t v; memcpy(&v, f, 8); dlen = (uint64_t)v; f += 8; }
            uint64_t priv = 0, cloneid = 0, ef = 0;
            uint32_t refcnt = 0;
            if (rs.forkattr & ATTR_CMNEXT_PRIVATESIZE) { int64_t v; memcpy(&v, f, 8); priv = (uint64_t)v; f += 8; }
            if (rs.forkattr & ATTR_CMNEXT_CLONEID) { memcpy(&cloneid, f, 8); f += 8; }
            if (rs.forkattr & ATTR_CMNEXT_EXT_FLAGS) { memcpy(&ef, f, 8); f += 8; }
            if (rs.forkattr & ATTR_CMNEXT_CLONE_REFCNT) { memcpy(&refcnt, f, 4); f += 4; }

            bool is_dir = type == VDIR;
            if (!collapsed) markers |= marker_for(name, nlen, is_dir);

            if (is_dir) {
                if (subs_n == subs_cap) {
                    subs_cap = subs_cap ? subs_cap * 2 : 64;
                    subs = realloc(subs, subs_cap * sizeof(subdir));
                    if (!subs) abort();
                }
                if (names_n + nlen + 1 > names_cap) {
                    size_t nc = names_cap ? names_cap * 2 : 4096;
                    while (nc < names_n + nlen + 1) nc *= 2;
                    char *nn = realloc(names, nc);
                    if (!nn) abort();
                    // Fix up earlier pointers.
                    for (size_t k = 0; k < subs_n; k++) subs[k].name = nn + (subs[k].name - names);
                    names = nn;
                    names_cap = nc;
                }
                memcpy(names + names_n, name, nlen);
                names[names_n + nlen] = 0;
                subdir sd = {names + names_n, nlen, 0, ino, mtime};
                if (bsdflags & SF_DATALESS) sd.flags |= SM_F_DATALESS;
                subs[subs_n++] = sd;
                names_n += nlen + 1;
                if (mtime > a.mtime) a.mtime = mtime;
                continue;
            }

            if (type != VREG && type != VLNK) continue;
            a.files++;
            if (mtime > a.mtime) a.mtime = mtime;
            a.logical += dlen;

            bool shared = false;
            uint64_t key = 0;
            uint32_t refs = 0;
            if (type == VREG && (ef & EF_SHARES_ALL_BLOCKS) && cloneid) {
                shared = true; key = cloneid; refs = refcnt;
            } else if (type == VREG && nlink > 1) {
                shared = true; key = ino | HL_TAG; refs = nlink;
            }
            // Shared data is split evenly across its members, so subtree sizes
            // add up to real disk usage and don't depend on scan order.
            // A clone that is also hard-linked appears once per name.
            uint64_t parts = refs > 1 ? refs : 1;
            if ((ef & EF_SHARES_ALL_BLOCKS) && cloneid && nlink > 1) parts *= nlink;
            uint64_t share = shared ? alloc / parts : 0;
            if (shared) {
                if (shard_insert(&s->shards[mix64(key) & (SHARDS - 1)], key))
                    atomic_fetch_add(&s->shared_unique, alloc);
                if (collect) {
                    sm_shared_rec r = {key, ino, alloc, priv, refs, tk->node};
                    add_rec(w, r);
                }
            }

            size_t el = 0;
            const char *ext = ext_of(name, nlen, &el);
            if (ext) {
                if (ext_in(ext, el, IMG_EXT)) { a.img_count++; a.img_bytes += alloc; }
                else if (ext_in(ext, el, VID_EXT)) { a.vid_bytes += alloc; if (!collapsed) markers |= SM_M_VIDEO_FILE; }
                else if (ext_in(ext, el, AUD_EXT)) a.aud_bytes += alloc;
                else if (ext_in(ext, el, MODEL_EXT)) a.model_bytes += alloc;
                else if (!collapsed && el == 5 && strncasecmp(ext, "blend", 5) == 0) markers |= SM_M_BLEND;
            }

            if (!collapsed && alloc >= big_threshold) {
                if (bigs_n == bigs_cap) {
                    bigs_cap = bigs_cap ? bigs_cap * 2 : 32;
                    bigs = realloc(bigs, bigs_cap * sizeof(bigfile));
                    if (!bigs) abort();
                }
                uint32_t fl = SM_F_FILE;
                if (shared) fl |= SM_F_SHARED;
                if ((ef & EF_IS_SPARSE) || (dlen > (64u << 20) && alloc < dlen / 2)) fl |= SM_F_SPARSE;
                if (ef & EF_IS_PURGEABLE) fl |= SM_F_PURGEABLE;
                if (type == VLNK) fl |= SM_F_SYMLINK;
                bigfile bf = {arena_put(w, name, nlen), nlen, ino, shared ? 0 : alloc, share, dlen, mtime, fl};
                bigs[bigs_n++] = bf;
            } else {
                if (shared) a.shared += share; else a.alloc += alloc;
            }
        }
    }
    atomic_fetch_add(&s->p_files, a.files);
    atomic_fetch_add(&s->p_bytes, a.alloc);

    bool collapse_self = !collapsed && (tk->mode == MODE_SELF_COLLAPSE ||
                                        (!s->opts.no_collapse && (markers & SM_M_PYVENV_CFG)));
    bool children_collapse = !collapsed && !collapse_self && !s->opts.no_collapse &&
                             ((markers & SM_M_CACHEDIR_TAG) || is_children_collapse_name(own->name, own->name_len));

    if (collapsed) {
        // Fold everything into the collapse target.
        __atomic_fetch_add(&own->alloc, a.alloc, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->shared, a.shared, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->logical, a.logical, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->nfiles, (uint32_t)a.files, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->img_count, a.img_count, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->img_bytes, a.img_bytes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->vid_bytes, a.vid_bytes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->aud_bytes, a.aud_bytes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->model_bytes, a.model_bytes, __ATOMIC_RELAXED);
        atomic_max64(&own->mtime, a.mtime);
    } else {
        // Big files become nodes, unless this dir folds its subtree.
        for (size_t k = 0; k < bigs_n; k++) {
            if (collapse_self) {
                a.alloc += bigs[k].alloc;
                a.shared += bigs[k].shared;
                continue;
            }
            uint32_t ci = tree_alloc_node(t);
            sm_node *c = sm_tree_node(t, ci);
            c->parent = tk->node;
            c->flags = bigs[k].flags;
            c->name = bigs[k].name;
            c->name_len = bigs[k].len;
            c->ino = bigs[k].ino;
            c->alloc = bigs[k].alloc;
            c->shared = bigs[k].shared;
            c->logical = bigs[k].logical;
            c->mtime = bigs[k].mtime;
            c->nfiles = 1;
        }
        // Collapsed dirs may already have collapsed children writing into them,
        // so accumulate atomically.
        __atomic_fetch_add(&own->alloc, a.alloc, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->shared, a.shared, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->logical, a.logical, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->nfiles, (uint32_t)a.files, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->img_count, a.img_count, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->img_bytes, a.img_bytes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->vid_bytes, a.vid_bytes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->aud_bytes, a.aud_bytes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&own->model_bytes, a.model_bytes, __ATOMIC_RELAXED);
        atomic_max64(&own->mtime, a.mtime);
        own->markers |= markers;
        if (collapse_self) own->flags |= SM_F_COLLAPSED;
    }

    // Children.
    w->kids_n = 0;
    for (size_t k = 0; k < subs_n; k++) {
        subdir *sd = &subs[k];
        if (sd->flags & SM_F_DATALESS) {
            if (!collapsed && !collapse_self) {
                uint32_t ci = tree_alloc_node(t);
                sm_node *c = sm_tree_node(t, ci);
                c->parent = tk->node;
                c->flags = SM_F_DIR | SM_F_DATALESS;
                c->name = arena_put(w, sd->name, sd->len);
                c->name_len = sd->len;
                c->ino = sd->ino;
                c->mtime = sd->mtime;
            }
            continue;
        }
        size_t plen = strlen(tk->path);
        uint32_t noff = (uint32_t)(plen + ((plen > 0 && tk->path[plen - 1] == '/') ? 0 : 1));
        task ct = {join_path(tk->path, sd->name, sd->len), NULL, noff, tk->node, tk->dev, MODE_COLLAPSED};
        if (!collapsed && !collapse_self) {
            uint32_t ci = tree_alloc_node(t);
            sm_node *c = sm_tree_node(t, ci);
            c->parent = tk->node;
            c->flags = SM_F_DIR;
            c->name = arena_put(w, sd->name, sd->len);
            c->name_len = sd->len;
            c->ino = sd->ino;
            ct.node = ci;
            ct.mode = MODE_NORMAL;
            if (!s->opts.no_collapse) {
                size_t el = 0;
                const char *ext = ext_of(sd->name, sd->len, &el);
                bool pkg = ext && ext_in(ext, el, PKG_EXT);
                if (pkg) c->flags |= SM_F_PACKAGE;
                if (children_collapse || pkg || is_collapse_name(sd->name, sd->len)) {
                    ct.mode = MODE_SELF_COLLAPSE;
                    c->flags |= SM_F_COLLAPSED;
                }
            }
        }
        add_kid(w, ct);
    }
    if (w->kids_n) {
        dirref *d = malloc(sizeof(dirref));
        if (!d) abort();
        d->fd = fd;
        atomic_store(&d->refs, (int)w->kids_n);
        for (size_t k = 0; k < w->kids_n; k++) w->kids[k].parent = d;
        push_tasks(s, w->kids, w->kids_n);
    } else {
        close(fd);
    }
    free(subs);
    free(names);
    free(bigs);
}

static void *worker_main(void *arg) {
    worker *w = arg;
    sm_scanner *s = w->s;
    for (;;) {
        pthread_mutex_lock(&s->qm);
        while (s->stack_n == 0 && s->pending > 0 && !atomic_load(&s->cancel))
            pthread_cond_wait(&s->qc, &s->qm);
        if (s->stack_n == 0 || atomic_load(&s->cancel)) {
            pthread_cond_broadcast(&s->qc);
            pthread_mutex_unlock(&s->qm);
            break;
        }
        task tk = s->stack[--s->stack_n];
        pthread_mutex_unlock(&s->qm);

        process_dir(w, &tk);
        free(tk.path);

        pthread_mutex_lock(&s->qm);
        s->pending--;
        if (s->pending == 0) pthread_cond_broadcast(&s->qc);
        pthread_mutex_unlock(&s->qm);
    }
    return NULL;
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void finalize(sm_tree *t) {
    uint32_t n = sm_tree_count(t);
    for (uint32_t i = 0; i < n; i++) {
        sm_node *x = sm_tree_node(t, i);
        x->t_alloc = x->alloc;
        x->t_shared = x->shared;
        x->t_logical = x->logical;
        x->t_newest = x->mtime;
        x->t_files = x->nfiles;
        x->first_child = SM_NONE;
        x->next_sibling = SM_NONE;
    }
    for (uint32_t i = n; i-- > 1;) {
        sm_node *x = sm_tree_node(t, i);
        if (x->parent == SM_NONE) continue;
        sm_node *p = sm_tree_node(t, x->parent);
        p->t_alloc += x->t_alloc;
        p->t_shared += x->t_shared;
        p->t_logical += x->t_logical;
        p->t_files += x->t_files;
        if (x->t_newest > p->t_newest) p->t_newest = x->t_newest;
        x->next_sibling = p->first_child;
        p->first_child = i;
    }
}

sm_tree *sm_scanner_run(sm_scanner *s, const char *const *roots, int nroots) {
    double t0 = now_seconds();
    sm_disable_dataless_materialization();
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < 65536) {
        rlim_t want = rl.rlim_max < 65536 ? rl.rlim_max : 65536;
        rl.rlim_cur = want;
        if (setrlimit(RLIMIT_NOFILE, &rl) != 0) { rl.rlim_cur = 10240; setrlimit(RLIMIT_NOFILE, &rl); }
    }
    sm_tree *t = tree_new();
    if (!t) return NULL;
    s->tree = t;

    uint32_t root = tree_alloc_node(t);
    sm_node *r = sm_tree_node(t, root);
    r->parent = SM_NONE;
    r->flags = SM_F_DIR;
    r->name = "";
    r->name_len = 0;

    worker *ws = calloc((size_t)s->opts.threads, sizeof(worker));
    // Root tasks.
    worker boot = {.s = s};
    for (int i = 0; i < nroots; i++) {
        struct stat st;
        if (lstat(roots[i], &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        uint32_t ci = tree_alloc_node(t);
        sm_node *c = sm_tree_node(t, ci);
        c->parent = root;
        c->flags = SM_F_DIR;
        size_t l = strlen(roots[i]);
        while (l > 1 && roots[i][l - 1] == '/') l--;
        c->name = arena_put(&boot, roots[i], l);
        c->name_len = (uint32_t)l;
        c->ino = st.st_ino;
        char *p = malloc(l + 1);
        memcpy(p, roots[i], l);
        p[l] = 0;
        task tk = {p, NULL, 0, ci, (uint32_t)st.st_dev, MODE_NORMAL};
        push_tasks(s, &tk, 1);
    }

    pthread_t *th = calloc((size_t)s->opts.threads, sizeof(pthread_t));
    for (int i = 0; i < s->opts.threads; i++) {
        ws[i].s = s;
        ws[i].buf = malloc(BULK_BUF);
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setstacksize(&at, 1u << 20);
        pthread_create(&th[i], &at, worker_main, &ws[i]);
        pthread_attr_destroy(&at);
    }
    for (int i = 0; i < s->opts.threads; i++) pthread_join(th[i], NULL);

    // Merge shared records.
    size_t total = 0;
    for (int i = 0; i < s->opts.threads; i++) total += ws[i].recs_n;
    if (total) {
        t->shared = malloc(total * sizeof(sm_shared_rec));
        for (int i = 0; i < s->opts.threads; i++) {
            memcpy(t->shared + t->shared_n, ws[i].recs, ws[i].recs_n * sizeof(sm_shared_rec));
            t->shared_n += ws[i].recs_n;
        }
    }
    for (int i = 0; i < s->opts.threads; i++) { free(ws[i].buf); free(ws[i].recs); free(ws[i].kids); }
    free(ws);
    free(th);

    if (atomic_load(&s->cancel)) {
        sm_tree_free(t);
        s->tree = NULL;
        return NULL;
    }
    finalize(t);
    t->stats.shared_unique = atomic_load(&s->shared_unique);
    t->stats.denied_dirs = atomic_load(&s->p_denied);
    t->stats.files = atomic_load(&s->p_files);
    t->stats.dirs = atomic_load(&s->p_dirs);
    t->stats.scan_seconds = now_seconds() - t0;
    t->stats.created_at = (double)time(NULL);
    t->stats.threads = s->opts.threads;
    s->tree = NULL;
    return t;
}

// ---------------------------------------------------------------- snapshots

#define SNAP_MAGIC "SMDIDX02"

typedef struct {
    char magic[8];
    uint32_t node_size;
    uint32_t node_count;
    uint64_t names_len;
    sm_tree_stats stats;
} snap_header;

int sm_tree_save(const sm_tree *t, const char *path) {
    uint32_t n = sm_tree_count(t);
    // Names blob.
    uint64_t names_len = 0;
    for (uint32_t i = 0; i < n; i++) names_len += sm_tree_node(t, i)->name_len + 1;
    char *names = malloc(names_len ? names_len : 1);
    sm_node *nodes = malloc((size_t)n * sizeof(sm_node));
    if (!names || !nodes) { free(names); free(nodes); return ENOMEM; }
    uint64_t off = 0;
    for (uint32_t i = 0; i < n; i++) {
        const sm_node *x = sm_tree_node(t, i);
        nodes[i] = *x;
        memcpy(names + off, x->name, x->name_len);
        names[off + x->name_len] = 0;
        nodes[i].name = (const char *)(uintptr_t)off;
        off += x->name_len + 1;
    }
    snap_header h;
    memset(&h, 0, sizeof h);
    memcpy(h.magic, SNAP_MAGIC, 8);
    h.node_size = sizeof(sm_node);
    h.node_count = n;
    h.names_len = names_len;
    sm_tree_get_stats(t, &h.stats);

    size_t pl = strlen(path);
    char *tmp = malloc(pl + 8);
    snprintf(tmp, pl + 8, "%s.tmp", path);
    int rc = 0;
    FILE *fp = fopen(tmp, "wb");
    if (!fp) rc = errno;
    else {
        if (fwrite(&h, sizeof h, 1, fp) != 1 ||
            (n && fwrite(nodes, sizeof(sm_node), n, fp) != n) ||
            (names_len && fwrite(names, 1, names_len, fp) != names_len)) rc = errno ? errno : EIO;
        if (fclose(fp) != 0 && !rc) rc = errno ? errno : EIO;
        if (!rc && rename(tmp, path) != 0) rc = errno;
        if (rc) unlink(tmp);
    }
    free(tmp);
    free(names);
    free(nodes);
    return rc;
}

int sm_tree_load(const char *path, sm_tree **out) {
    *out = NULL;
    FILE *fp = fopen(path, "rb");
    if (!fp) return errno;
    snap_header h;
    if (fread(&h, sizeof h, 1, fp) != 1 || memcmp(h.magic, SNAP_MAGIC, 8) != 0 || h.node_size != sizeof(sm_node)) {
        fclose(fp);
        return EINVAL;
    }
    size_t nodes_bytes = (size_t)h.node_count * sizeof(sm_node);
    char *blob = malloc(nodes_bytes + h.names_len + 1);
    if (!blob) { fclose(fp); return ENOMEM; }
    if ((nodes_bytes && fread(blob, 1, nodes_bytes, fp) != nodes_bytes) ||
        (h.names_len && fread(blob + nodes_bytes, 1, h.names_len, fp) != h.names_len)) {
        free(blob);
        fclose(fp);
        return EIO;
    }
    fclose(fp);
    sm_tree *t = tree_new();
    if (!t) { free(blob); return ENOMEM; }
    t->blob = blob;
    sm_node *nodes = (sm_node *)blob;
    const char *names = blob + nodes_bytes;
    for (uint32_t i = 0; i < h.node_count; i++) nodes[i].name = names + (uintptr_t)nodes[i].name;
    for (uint32_t c = 0; (size_t)c * CHUNK_SIZE < h.node_count; c++)
        atomic_store(&t->chunks[c], nodes + (size_t)c * CHUNK_SIZE);
    atomic_store(&t->count, h.node_count);
    t->stats = h.stats;
    *out = t;
    return 0;
}
