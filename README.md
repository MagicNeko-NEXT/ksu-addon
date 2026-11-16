# ksu-addon — multi-backend SU + SUSFS sandbox build tooling

Build both a **rootless** and a **rooted** PixelOS/LineageOS package from one
ROM tree, with the patches and the build output confined to copy-on-write
overlay sandboxes.

The kernel checkout and `out/` are never written: every patch lands in the
overlay upper layer, every build artifact likewise, and unmounting the sandbox
restores the physical tree byte for byte.

---

## 1. Supported SU backends (variants)

| variant | upstream | reference commit | SUSFS | status |
| --- | --- | --- | --- | --- |
| `bakasu-susfs` (default) | <https://github.com/Baka-SU/BakaSU> | `5d6d184` | KSU-side hooks included; kernel side from `0002` | built + verified on device |
| `kernelsu-susfs` | <https://github.com/tiann/KernelSU> | `64833c0` | **not included upstream**; added via `0003` (susfs4ksu `10_enable_susfs_for_ksu.patch`) | built |
| `sukisu-susfs` | <https://github.com/SukiSU-Nova/SukiSU-Nova> | `builtin` `4bec532` | included in `builtin` (21 `KSU_SUSFS` entries) | built |
| `kernelsu-next-susfs` | <https://github.com/KernelSU-Next/KernelSU-Next> | `dev` `7ccf614` | **LKM design**: susfs ships as `susfs.ko` and is loaded at runtime | root built; `susfs.ko` not included |

Upstream manual-integration entry points (reference only — this repo turns them
into patches, nothing is fetched at build time):

```bash
# BakaSU (the ReSukiSU project moved to BakaSU)
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash
# KernelSU
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
# KernelSU-Next
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -
# SukiSU-Ultra (setup.sh clones SukiSU-Nova and checks out the given ref)
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
```

**SUSFS source**: the kernel-side implementation (`fs/susfs.c`,
`include/linux/susfs*.h`, fs/mm/selinux hooks) comes from
[susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu), branch
`gki-android15-6.6` (v2.4.0). KernelSU upstream does not apply SUSFS on its own.

---

## 2. Layout

```
ksu-addon/
├── bin/
│   ├── sandbox.sh   # overlay sandbox: up/down out|kernel, status, selftest
│   ├── ksu.sh       # prepare (apply patches + local commit) / cleanup / check
│   ├── build.sh     # build entry: non-root and rooted passes
│   └── verify.sh    # validate an artifact directory
├── variants/
│   └── <name>/{variant.env, series/*.patch}
├── ksu-addon.sh     # unified entry point
├── install.sh       # deploy into a ROM tree
└── README.md
```

---

## 3. Usage

```bash
cd /home/icecat/data/pixelos-6.6
D=vendor/oneplus/ksu-addon

# non-root + current variant (default bakasu-susfs)
WITH_KSU=true JOBS=64 bash -l $D/bin/build.sh

# switch backend
KSU_VARIANT=kernelsu-susfs WITH_KSU=true JOBS=64 bash -l $D/bin/build.sh

# every variant, one after another
WITH_KSU=true JOBS=64 bash -l $D/bin/build.sh --all-variants

# subset, or a single rooted pass
WITH_KSU=true bash -l $D/bin/build.sh --variants bakasu-susfs,kernelsu-susfs
KSU_VARIANT=kernelsu-susfs WITH_KSU=true ONLY=rooted bash -l $D/bin/build.sh

# preflight / health checks
bash $D/bin/ksu.sh check
KSU_VARIANT=kernelsu-susfs bash $D/bin/ksu.sh check
bash $D/bin/sandbox.sh status
```

Artifacts go to **`<ROM>/outrom/`** (created on demand):

```
<ROM>/outrom/<timestamp>-non-root/PixelOS-ovaltine-<timestamp>-non-root.zip
<ROM>/outrom/<timestamp>-<variant>/PixelOS-ovaltine-<timestamp>-<variant>.zip
```

Each directory contains `MD5SUMS`, `kernel-<tag>.config`, `kernel-release.txt`
and `ksu-version.txt`.

> One ROM tree has exactly one `out/`. Running several kernel recipes
> concurrently would corrupt each other, so `--all-variants` builds the
> variants **sequentially**, each in its own sandbox that is torn down
> before the next one starts.

---

## 4. Sandbox model and the "-dirty" fix

| layer | lower (read-only) | upper (writes) | mount point |
| --- | --- | --- | --- |
| out | `out/` (existing build cache) | `$KSU_OVL_DIR/out-upper` | `out/` (unchanged path) |
| kernel | `kernel/oneplus/sm8450` pristine checkout | `$KSU_OVL_DIR/kernel-upper` | unchanged path |

- Mount options: `redirect_dir=on,index=on`. Without them overlayfs cannot
  rename a lower-layer directory and soong fails with
  `Failed to rename out/soong/metrics_aggregation`.
- **No `-dirty` in version strings**: `prepare` commits the patches as a local
  commit that is never pushed, so HEAD matches the worktree and both
  `scripts/setlocalversion` and the KSU `Kbuild` report a clean tree.
  Verified output: `6.6.144-4k-g4a542d60a2d1` (keeps `-g<hash>`, no `-dirty`).
  The commit lives in `.repo/.../.git`, which is **not** on the overlay, so
  `cleanup` explicitly resets to the base SHA recorded by `prepare`.
- When a build finishes, `sandbox.sh down all` runs and the local commit is
  rolled back; the kernel checkout stays at its base SHA with a clean
  `git status`.

---

## 5. Known pitfalls (all handled in the scripts)

1. ReSukiSU/BakaSU `Kbuild` requires a `.git` or `.vendored` marker next to
   `KernelSU/`. Dotfiles cannot be carried by patches, so `prepare` creates it
   (`: > KernelSU/.vendored`), inside the upper layer only.
2. `git apply --3way` writes to the index, and the index lives in `.repo`
   (outside the overlay). All patches are applied with plain `git apply`, and
   `cleanup` still runs `git reset` as a safety net.
3. A brand-new out directory breaks siso bootstrap with
   `@config//main.star: no such file`. This tooling reuses the existing `out/`
   through an overlay, so it never creates a fresh one. (If you ever need one:
   relative `OUT_DIR` plus `SOONG_NINJA=ninja` works.)
4. The kernel headers genrule declares an incomplete `dep_files` list (missing
   `scripts/**/*`), which only shows up on the **ninja + sbox** path. This
   tooling uses the default siso backend, so it is not triggered.
5. `ksu.sh check` must apply the series **in order for real** (not with
   `--check`), because later patches touch files that earlier ones create.

---

## 6. Self-test and validation

```bash
./ksu-addon.sh selftest          # overlay round trip (mount/write/delete/rename/unmount)
./ksu-addon.sh status            # current sandbox state
./ksu-addon.sh check <variant>   # patches apply on the current kernel HEAD?
./ksu-addon.sh build --dry-run   # preflight only, print the build plan
./ksu-addon.sh verify <dir>      # artifact checks: no -dirty, CONFIG_KSU, zip MD5
```

## 7. Publishing scope

This repository contains **build tooling and patches only**:

- included: `bin/`, `variants/*/series/*.patch`, `variant.env`, `install.sh`,
  `ksu-addon.sh`, `README.md`
- excluded: any kernel source, patched kernel tree, or build output
  (`out/`, zips, images)

Patches are diffs against upstream SU sources and susfs4ksu. They are applied
inside an overlay sandbox at build time and destroyed on unmount; no mainline or
testing branch is ever modified.

## 8. Install into a ROM tree

```bash
bash install.sh /path/to/rom/tree     # default: /home/icecat/data/pixelos-6.6
```

The script rsyncs into `vendor/oneplus/ksu-addon/` and prints the next commands.
It does not write to any repository history.
