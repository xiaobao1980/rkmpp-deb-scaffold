# syntax=docker/dockerfile:1
# rkmpp 双 deb 构建环境：Debian 12 (bookworm) arm64 基底
# 用法（GHA 或板端本地均可）：
#   docker buildx build --output type=local,dest=./out .
# 产物：./out/rkmpp-stack_<版本>_arm64.deb 和 ./out/mpv-rkmpp_<版本>_arm64.deb
#
# 基座选择：glibc 2.36 → 覆盖 Debian 12/13、Ubuntu 24.04/26.04、deepin 25。
# 不再用 Ubuntu 22.04（jammy）：多它一个只为 glibc 2.35，却要把 wayland 1.20 自编到 1.22。
#
# wayland 的实际情况（依据实编，见说明书 §10/§11）：
#   - libwayland-client/cursor/egl：bookworm 自带 1.21，满足 mpv 的 >=1.21，直接链系统库；
#   - wayland-protocols：mpv 的 meson 写 >=1.31 是过时的，实际要 >=1.41
#     （wayland_common.c 无条件调 wp_color_manager_v1_get_version()，该 XML 从 1.41 才进列表）。
#     bookworm 的 1.31 会报 implicit declaration 直接编挂，所以 build.sh [6/8] 自编 1.44，
#     只用于构建期产头文件，不进 deb、不改 Depends。
#
# 基础镜像按 digest 钉死（不打浮动 tag）：
#   arm64v8/debian:12 是 OCI image index，digest 一变说明 upstream 重推了镜像，
#   而 gcc/dpkg/xz 任一版本变化都会让产物字节跟着变。钉住后「同 commit 出同字节」
#   才真正成立。index 内 linux/arm64 子清单 = sha256:a6db089d0e65…（2026-11-03 取）。
#   升级方式：docker buildx imagetools inspect arm64v8/debian:12 取新 digest 后改本行。
FROM arm64v8/debian:12@sha256:488b6b1d593bd744a457fc5ce30cea150bedb13b6072bed5046d963eb1aaba0e AS build
ARG DEBIAN_FRONTEND=noninteractive

# 上游版本 pin（可在 docker buildx build --build-arg 覆盖，详见说明书第 6 章）
#
# 注意 mpp / rga / ffmpeg 三个上游根本**没有发布 tag**，只有长期分支
# （jellyfin-mpp / jellyfin-rga / 9.0），分支头随时前进 → 不改本文件、不改任何代码，
# 第二次构建就可能编出不同东西，而且日志里查不到原来编的是哪份源码。
# 故这三个一律钉到完整 commit SHA（2026-11-03 解析自各自分支头，与当时产物同源）。
# 想追上游就显式换 SHA，diff 里看得见；不想追就永远不动，构建结果恒等。
ARG MPP_REF=ca9b2db9bd37f7b77f181bb3601ec71a4a41d330
ARG RGA_REF=1d330cc28551943bed3380261a5a9c6fbd58ff53
ARG FFMPEG_REF=e6fd228e1e2be00f9a4e1f003b287a72d252a55d
# 下面四个是真 tag（annotated），上游不会重打；build.sh 会把解析到的 commit SHA
# 打进日志，真要复现某个历史包时按日志里的 SHA 覆盖即可。
ARG MPV_TAG=v0.41.0
ARG LIBPLACEBO_TAG=v6.338.2
# libdisplay-info：bookworm 源里没有（Debian 13 才进），而 mpv 的 drm 特性硬依赖 >=0.1.1
ARG LDI_TAG=0.1.1
# wayland-protocols：必须 >=1.41（见上方注释），1.44 是当前稳定 tag
ARG WLP_TAG=1.44

# 源地址也做成 build-arg：国内构建或镜像失效时不用改 Dockerfile / build.sh，
# 直接 --build-arg RGA_URL=... 换源即可（rga 的 GitHub 仓库已 404，只能走 gitee）。
ARG MPP_URL=https://github.com/nyanmisaka/mpp.git
ARG RGA_URL=https://gitee.com/nyanmisaka/rga.git
ARG FFMPEG_URL=https://github.com/nyanmisaka/ffmpeg-rockchip.git
ARG LDI_URL=https://gitlab.freedesktop.org/emersion/libdisplay-info.git
ARG WLP_URL=https://gitlab.freedesktop.org/wayland/wayland-protocols.git

# 说明：bookworm 自带 meson 1.0.1，而 mpv 0.41 要求 >= 1.3.0，故用 pip 装新版；
# Debian 12 起 python 标了 EXTERNALLY-MANAGED，pip 装系统前缀必须带 --break-system-packages。
# libxkbcommon-dev 不能省：mpv 的 meson 把 xkbcommon 的 required 绑在 wayland 选项上
# （dependency('xkbcommon', required: get_option('wayland'))），-Dwayland=enabled 时缺它就硬失败。
# libwayland-dev 会顺带装 libwayland-bin（wayland-scanner），mpv 用它生成协议代码。
# libxpresent-dev 不能省：mpv 的 x11 特性要求 x11/xscrnsaver/xext/xpresent/xrandr 五个
# pkg-config 全命中，缺 xpresent 就静默关掉整个 X11 后端（只有 wayland，deepin 25 X11 黑屏）。
# hwdata：libdisplay-info 的 meson 要读 /usr/share/hwdata/pnp.ids 生成 PNP 厂商表，
# 缺这个包会在 custom_target 阶段直接失败（bookworm 官方源没有 libdisplay-info，只能自编）。
# libpulse-dev：不开 pulse 时 mpv 只剩 ALSA 输出，在 PipeWire/PulseAudio 桌面上会没声；
# pipewire 音频经 pipewire-pulse 走 pulse 后端即可，不必再编一个后端。
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates curl xz-utils cmake ninja-build pkg-config \
      python3 python3-pip python3-setuptools python3-jinja2 \
      dpkg-dev file binutils hwdata \
      libdrm-dev libasound2-dev zlib1g-dev libgnutls28-dev libpulse-dev \
      libass-dev liblua5.2-dev \
      libegl1-mesa-dev libgl1-mesa-dev libgbm-dev libepoxy-dev \
      libwayland-dev wayland-protocols libxkbcommon-dev \
      libx11-dev libxext-dev libxss-dev libxrandr-dev libxpresent-dev \
      libffi-dev libexpat1-dev \
 && pip3 install --no-cache-dir --break-system-packages "meson>=1.3" \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
ENV MPP_REF=${MPP_REF} RGA_REF=${RGA_REF} FFMPEG_REF=${FFMPEG_REF} \
    MPV_TAG=${MPV_TAG} LIBPLACEBO_TAG=${LIBPLACEBO_TAG} \
    LDI_TAG=${LDI_TAG} WLP_TAG=${WLP_TAG} \
    MPP_URL=${MPP_URL} RGA_URL=${RGA_URL} FFMPEG_URL=${FFMPEG_URL} \
    LDI_URL=${LDI_URL} WLP_URL=${WLP_URL}

COPY build.sh ./
COPY patches ./patches
# vendor/：内置 librga(jellyfin-rga) 源码。gitee 对境外 IP 返回 401，GitHub Actions 的
# runner 全在境外，无法 clone；国内机器却拉得通，所以这个故障只有 CI 会暴露。
COPY vendor ./vendor
RUN chmod +x build.sh && ./build.sh

COPY packaging ./packaging
COPY scripts ./scripts
# mpv 系统级配置的唯一来源（打包时装成 /etc/mpv/mpv.conf）
COPY mpv-rk35xx.conf ./
RUN chmod +x scripts/*.sh scripts/rkmpp-verify packaging/*/DEBIAN/postinst \
 && ./scripts/package-debs.sh

# 最终镜像只含 deb，--output type=local 直接导出到宿主 ./out
FROM scratch
COPY --from=build /out /
