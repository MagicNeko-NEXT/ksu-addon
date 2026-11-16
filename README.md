# ksu-addon —— 多 SU 后端的 root 附加层（BakaSU / KernelSU / KernelSU-Next / SukiSU）

一条命令产出 **无 root** 与 **带 root** 两个 PixelOS 包，且：
**补丁打在 overlay 沙盒里，编译输出也写在 overlay 沙盒里，编完卸载即还原。**
内核 checkout 永远保持无补丁的原始状态，`out/` 物理层也不被写。

---

## 1. 支持的 SU 后端（variant）

| variant | 上游 | 参考提交 | SUSFS | 状态 |
| --- | --- | --- | --- | --- |
| `bakasu-susfs`（默认） | <https://github.com/Baka-SU/BakaSU> | `5d6d184` | 自带 KSU 侧钩子 + `0002` 提供内核实现 | **已实机验证** |
| `kernelsu-susfs` | <https://github.com/tiann/KernelSU> | `64833c0` | 官方**不带**，用 `0003`（susfs4ksu 的 `10_enable_susfs_for_ksu.patch`）补 | 补丁已生成并按序校验通过，待构建验证 |
| `kernelsu-next-susfs` | <https://github.com/KernelSU-Next/KernelSU-Next> | `dev` `7ccf614` | 设计为 **SUSFS LKM**（`susfs.ko`，运行时加载；仓库含 `kernel/susfs/` LKM 侧源码），不是静态内核补丁 | KSU 本体编译验证中 |
| `sukisu-susfs` | <https://github.com/SukiSU-Nova/SukiSU-Nova> | `builtin` `4bec532` | **builtin 分支自带**（Kconfig 21 条 `KSU_SUSFS`、`susfs_init` 4 处）；内核实现仍由 `0002` 提供 | 补丁已生成并按序校验通过，构建中 |

> 上游对应的“手动集成”入口（供换源时参考，本目录把它固化成补丁，构建时不联网执行）：
>
> ```bash
> # BakaSU（ReSukiSU 项目已迁至 BakaSU）
> curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash
> # KernelSU 官方
> curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
> # KernelSU-Next
> curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -
> # SukiSU-Ultra
> curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s main
> ```

**SUSFS 来源**：内核实现（`fs/susfs.c`、`include/linux/susfs*.h`、fs/mm/selinux 钩子）来自
[susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) 的 `gki-android15-6.6` 分支（v2.4.0）。
KernelSU 原版自身不会应用 SUSFS；BakaSU 与 SukiSU 自带 KSU 侧钩子。

---

## 2. 目录结构

```
ksu-addon/
├── bin/
│   ├── sandbox.sh   # overlay 沙盒：up/down out|kernel、status
│   ├── ksu.sh       # prepare（打补丁 + 本地提交）/ cleanup（卸载 + 回滚）/ check
│   └── build.sh     # 构建入口：non-root 与 rooted 各一遍
├── variants/
│   ├── bakasu-susfs/{variant.env, series/*.patch}
│   ├── kernelsu-susfs/{variant.env, series/*.patch}
│   ├── kernelsu-next-susfs/variant.env
│   └── sukisu-susfs/variant.env
├── install.sh       # 一键部署到 ROM 树
└── README.md
```

---

## 3. 用法

```bash
cd /home/icecat/data/pixelos-6.6
D=vendor/oneplus/ksu-addon

# 两个包（默认 bakasu-susfs）
WITH_KSU=true JOBS=64 bash -l $D/bin/build.sh

# 换 SU 后端
KSU_VARIANT=kernelsu-susfs WITH_KSU=true JOBS=64 bash -l $D/bin/build.sh

# 只出无 root / 只重出带 root
bash -l $D/bin/build.sh
KSU_VARIANT=kernelsu-susfs WITH_KSU=true ONLY=rooted JOBS=64 bash -l $D/bin/build.sh

# 体检
bash $D/bin/ksu.sh check                        # 补丁能否在当前 HEAD 上按序应用
KSU_VARIANT=kernelsu-susfs bash $D/bin/ksu.sh check
bash $D/bin/sandbox.sh status                   # 沙盒是否残留
```

产物（`OUTPUT_TAG` 随变体走）：

```
/home/icecat/data/ovaltine-debug/ksu/<时间戳>-non-root/PixelOS-ovaltine-<时间戳>-non-root.zip
/home/icecat/data/ovaltine-debug/ksu/<时间戳>-<variant>/PixelOS-ovaltine-<时间戳>-<variant>.zip
```

每个目录带 `MD5SUMS`、`kernel-<标签>.config`、`kernel-release.txt`（版本串）、`ksu-version.txt`。

---

## 4. 沙盒模型与“脏”标记处理

| 层 | lower（只读） | upper（写入） | 挂载点 |
| --- | --- | --- | --- |
| out | `out/`（non-root 编译缓存） | `$KSU_OVL_DIR/out-upper` | `out/` 原路径 |
| kernel | `kernel/oneplus/sm8450` 原始 checkout | `$KSU_OVL_DIR/kernel-upper` | 原路径 |

- 挂载参数：`redirect_dir=on,index=on`（否则 overlay 不能重命名 lower 目录，
  soong 报 `Failed to rename out/soong/metrics_aggregation`）。
- **版本串不带 `-dirty`**：`prepare` 把补丁提交成本地 commit（**不 push**），
  HEAD 与工作区一致，`scripts/setlocalversion` 与 KSU `Kbuild` 都不标脏。
  实测产物：`6.6.144-4k-g4a542d60a2d1`（保留 `-g<hash>`，无 `-dirty`）。
  ⚠️ 该 commit 在 `.repo/.../objects` 里、**不在 overlay 上**，因此 `cleanup`
  用 `git reset --mixed <基线SHA>` 显式回滚（基线记在 `$KSU_OVL_DIR/base-head`）。
- 编完自动 `sandbox.sh down all` 并回滚；内核 checkout 保持基线 SHA、`git status` 为空。

---

## 5. 已知坑（脚本已处理）

1. ReSukiSU/BakaSU 的 `Kbuild` 要求 `KernelSU/` 旁有 `.git` 或 `.vendored`；点文件打不进补丁
   → prepare 时 `: > KernelSU/.vendored` 现创（只在 upper 层）。
2. `git apply --3way` 会写 index（index 在 `.repo`，不在 overlay）→ 补丁一律纯 `git apply`。
3. 全新 out 目录的 siso bootstrap 会死在 `@config//main.star` → 本方案复用现有 `out/`，不新建目录。
4. 内核头 genrule 的 `dep_files` 不全（缺 `scripts/**/*` 等），只在 **ninja+sbox** 路径暴露；
   本方案走 siso 默认后端，不触发。
5. `ksu.sh check` 必须**按序真实应用**补丁（后面的补丁依赖前面新建的文件），不能用 `--check` 逐个验。
