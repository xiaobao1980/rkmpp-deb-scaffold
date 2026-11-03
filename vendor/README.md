# vendor/ —— 内置上游源码

## rga-jellyfin-rga.tar.gz

`librga` 的 `jellyfin-rga` 分支源码树，**为什么放在仓库里：**

nyanmisaka 的 rga 只托管在 gitee，GitHub 上的同名仓库已 404。而 **gitee 对境外 IP 会返回
401**（不是 404），GitHub Actions 的 runner 全在境外，`git clone` 会报：

```text
fatal: could not read Username for 'https://gitee.com': No such device or address
```

国内机器拉 gitee 没问题，所以在国内实编时完全暴露不出这个故障——它是境外 CI 才有的坑。
把源码树内置后，CI 与本地构建走同一条路径，不再依赖 gitee 可达性。

| 项 | 值 |
| --- | --- |
| 来源 | `https://gitee.com/nyanmisaka/rga.git` |
| 分支 | `jellyfin-rga` |
| commit | `1d330cc28551943bed3380261a5a9c6fbd58ff53` |
| 打包 | `git archive --format=tar.gz --prefix=rga/ -o rga-jellyfin-rga.tar.gz HEAD` |
| 大小 | 7.6 MB / 337 文件（未裁剪，避免漏掉 cmake 引用的子目录） |
| SHA256 | `990cc12b7cc2e32733d992b2909382e6675932f87114546721ad43f6ab7563e5` |
| 许可 | Apache-2.0（`COPYING` 在包内完整保留） |

## 更新方法

```bash
git clone --depth 1 -b jellyfin-rga https://gitee.com/nyanmisaka/rga.git /tmp/rgasrc
git -C /tmp/rgasrc archive --format=tar.gz --prefix=rga/ \
    -o vendor/rga-jellyfin-rga.tar.gz HEAD
git -C /tmp/rgasrc rev-parse HEAD    # 把新 commit 写回本文件
```

上游一旦更新 commit，只需替换本文件并同步 `RGA_REF`（`build.sh` 默认 `jellyfin-rga`），
`RGA_TARBALL` 指向的仍是这个路径，无需改构建逻辑。

## 构建时如何使用

`build.sh` 的 `[2/8] librga` 阶段：

- `vendor/rga-jellyfin-rga.tar.gz` 存在 → 直接解压到 `/src/rkrga`（CI 走这条）；
- 不存在 → 回退 `git_clone_ref "$RGA_URL" "$RGA_REF"`，即从 gitee 克隆（国内手工构建可用）。

可用 `RGA_TARBALL=/path/to/xxx.tar.gz` 覆盖，或设 `RGA_TARBALL=` 强制走 clone。
