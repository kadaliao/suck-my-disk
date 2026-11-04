// CFastScan: parallel getattrlistbulk walker that builds a compact size tree.
//
// Node 0 is a synthetic root; its children are the scan roots (named by their
// absolute path). Children always have larger indices than their parents.

#ifndef CFASTSCAN_H
#define CFASTSCAN_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define SM_NONE 0xFFFFFFFFu

// Node flags.
#define SM_F_DIR             0x00000001u
#define SM_F_FILE            0x00000002u
#define SM_F_COLLAPSED       0x00000004u // whole subtree folded into this node
#define SM_F_PACKAGE         0x00000008u // .app, .framework, ... shown as a leaf
#define SM_F_DENIED          0x00000010u // could not be read (permissions)
#define SM_F_DATALESS        0x00000020u // iCloud placeholder, not descended
#define SM_F_SPARSE          0x00000040u
#define SM_F_MOUNTPOINT      0x00000080u // another volume, not descended
#define SM_F_PURGEABLE       0x00000100u
#define SM_F_SHARED          0x00000200u // file data is a clone / hard link
#define SM_F_SYMLINK         0x00000400u

// Marker bits: well-known names found directly inside a directory.
#define SM_M_GIT             0x00000001u
#define SM_M_PACKAGE_JSON    0x00000002u
#define SM_M_PYPROJECT       0x00000004u
#define SM_M_CARGO_TOML      0x00000008u
#define SM_M_GO_MOD          0x00000010u
#define SM_M_PACKAGE_SWIFT   0x00000020u
#define SM_M_XCODEPROJ       0x00000040u
#define SM_M_CACHEDIR_TAG    0x00000080u
#define SM_M_PYVENV_CFG      0x00000100u
#define SM_M_LOCK_PNPM       0x00000200u
#define SM_M_LOCK_NPM        0x00000400u
#define SM_M_LOCK_YARN       0x00000800u
#define SM_M_LOCK_BUN        0x00001000u
#define SM_M_LOCK_UV         0x00002000u
#define SM_M_LOCK_POETRY     0x00004000u
#define SM_M_LOCK_CARGO      0x00008000u
#define SM_M_REQUIREMENTS    0x00010000u
#define SM_M_POM_XML         0x00020000u
#define SM_M_GRADLE          0x00040000u
#define SM_M_GITIGNORE       0x00080000u
#define SM_M_SETUP_PY        0x00100000u
#define SM_M_GEMFILE         0x00200000u
#define SM_M_PUBSPEC         0x00400000u
#define SM_M_CMAKE           0x00800000u
#define SM_M_BLEND           0x01000000u
#define SM_M_VIDEO_FILE      0x02000000u // at least one video file directly inside

typedef struct sm_node {
    uint32_t parent;
    uint32_t flags;
    uint32_t markers;
    uint32_t name_len;
    const char *name;
    uint64_t ino;

    // Own values. For a directory: its small files (below the big-file
    // threshold) plus, if collapsed, everything beneath it.
    uint64_t alloc;      // allocated bytes not shared with other files
    uint64_t shared;     // this node's even share of clone / hard link data
    uint64_t logical;    // logical (data length) bytes
    int64_t  mtime;      // file: mtime; dir: newest mtime of own entries
    uint32_t nfiles;
    uint32_t img_count;
    uint64_t img_bytes;
    uint64_t vid_bytes;
    uint64_t aud_bytes;
    uint64_t model_bytes;

    // Subtree totals, filled in after the scan.
    uint64_t t_alloc;
    uint64_t t_shared;
    uint64_t t_logical;
    int64_t  t_newest;
    uint64_t t_files;

    uint32_t first_child;
    uint32_t next_sibling;
} sm_node;

// One clone / hard link member, collected only when collect_shared is set.
typedef struct sm_shared_rec {
    uint64_t key;     // clone id, or inode | (1<<63) for plain hard links
    uint64_t ino;
    uint64_t alloc;
    uint64_t priv;    // ATTR_CMNEXT_PRIVATESIZE when want_private is set
    uint32_t refs;    // CLONE_REFCNT (distinct inodes) or link count (names)
    uint32_t node;    // node the bytes are attributed to
} sm_shared_rec;

typedef struct sm_scan_opts {
    int threads;                 // 0 = auto
    uint64_t big_file_threshold; // files >= this get their own node (0 = 1 MiB)
    bool want_private;           // request ATTR_CMNEXT_PRIVATESIZE
    bool collect_shared;         // record every clone / hard link member
    bool no_collapse;            // never fold subtrees (for targeted scans)
} sm_scan_opts;

typedef struct sm_tree sm_tree;
typedef struct sm_scanner sm_scanner;

typedef struct sm_progress {
    uint64_t files;
    uint64_t dirs;
    uint64_t bytes;
    uint64_t denied;
} sm_progress;

typedef struct sm_tree_stats {
    uint32_t node_count;
    uint64_t shared_unique;  // bytes of clone / hard link groups, counted once
    uint64_t denied_dirs;
    uint64_t files;
    uint64_t dirs;
    double   scan_seconds;
    double   created_at;     // unix time
    int      threads;
} sm_tree_stats;

// Scanning. The scanner may be polled for progress / cancelled from another thread.
sm_scanner *sm_scanner_create(const sm_scan_opts *opts);
// Blocking. Returns the tree (owned by caller) or NULL if cancelled.
sm_tree *sm_scanner_run(sm_scanner *s, const char *const *roots, int nroots);
void sm_scanner_progress(sm_scanner *s, sm_progress *out);
void sm_scanner_cancel(sm_scanner *s);
void sm_scanner_free(sm_scanner *s);

// Tree access.
uint32_t sm_tree_count(const sm_tree *t);
sm_node *sm_tree_node(const sm_tree *t, uint32_t i);
void sm_tree_get_stats(const sm_tree *t, sm_tree_stats *out);
// Writes the absolute path of node i; returns its length (truncated to cap-1).
size_t sm_tree_path(const sm_tree *t, uint32_t i, char *buf, size_t cap);
size_t sm_tree_shared_count(const sm_tree *t);
const sm_shared_rec *sm_tree_shared(const sm_tree *t);
void sm_tree_free(sm_tree *t);

// Snapshot persistence (atomic write). Return 0 or an errno value.
int sm_tree_save(const sm_tree *t, const char *path);
int sm_tree_load(const char *path, sm_tree **out);

// Small helpers.
// Bytes used by this volume alone (APFS volumes share their container's free space).
uint64_t sm_volume_space_used(const char *path);
int sm_default_threads(void);
int sm_disable_dataless_materialization(void);

#endif
