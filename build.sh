#!/usr/bin/env bash
# rkmpp 栈构建脚本（在 Debian 12 bookworm arm64 容器内执行）
# 产出：/stack（rkmpp-stack 包 staging）、/mpvstage（mpv-rkmpp 包 staging）、/VERSION
#
# 配方基线对齐实机验证（neardi-lz200 / Armbian noble / RK35xx 6.1 vendor 内核）：
#   mpp ca9b2db9 + rkrga 1d330cc2 + ffmpeg-rockchip e6fd228e（9.0 分支）
#   + mpv v0.41.0 + rkmpp hwdec 补丁 + libplacebo v6.338.2 + libdisplay-info 0.1.1
#   + wayland-protocols 1.44（仅构建期，mpv 的 wayland 后端需要 >= 1.41 的协议 XML）
# 三个没有 tag 的上游（mpp/rga/ffmpeg）默认钉 commit SHA，分支头前进不会污染产物。
set -euo pipefail

# 断言辅助：不要用 `| grep -q`。本脚本开了 pipefail，而 grep -q 命中即退出，
# 上游（ffmpeg -decoders 约 60KB 输出）会收到 SIGPIPE 被杀，pipeline 状态变成 141，
# 于是「断言明明通过」却被判失败——实编时真撞上过，且是否触发取决于输出是否刚好
# 塞满 64KB 管道缓冲，属随机失败。grep 不带 -q 会读到 EOF，不会产生 SIGPIPE。
has() { grep -e "$1" >/dev/null; }

PREFIX=/usr/local
STACK=/stack
MPVST=/mpvstage
JOBS="$(nproc)"

# ffmpeg 独立 libdir：不落进 /usr/local/lib 的 ldconfig 路径，避免与发行版 ffmpeg
# 或用户自建的 /usr/local ffmpeg 互相顶包；只靠 rpath 暴露给本包的 ffmpeg/mpv。
FFMPEG_LIBDIR="$PREFIX/lib/ffmpeg-rkmpp"

MPP_REF="${MPP_REF:-ca9b2db9bd37f7b77f181bb3601ec71a4a41d330}"
RGA_REF="${RGA_REF:-1d330cc28551943bed3380261a5a9c6fbd58ff53}"
FFMPEG_REF="${FFMPEG_REF:-e6fd228e1e2be00f9a4e1f003b287a72d252a55d}"
MPV_TAG="${MPV_TAG:-v0.41.0}"
LIBPLACEBO_TAG="${LIBPLACEBO_TAG:-v6.338.2}"
LDI_TAG="${LDI_TAG:-0.1.1}"
WLP_TAG="${WLP_TAG:-1.44}"

# 上游源：mpp/ffmpeg-rockchip 在 GitHub；rga 的 GitHub 仓库已被删除（404），只能走 gitee。
MPP_URL="${MPP_URL:-https://github.com/nyanmisaka/mpp.git}"
RGA_URL="${RGA_URL:-https://gitee.com/nyanmisaka/rga.git}"
FFMPEG_URL="${FFMPEG_URL:-https://github.com/nyanmisaka/ffmpeg-rockchip.git}"
# libdisplay-info：只有 gitlab.freedesktop.org 有，GitHub 上没有官方镜像。
LDI_URL="${LDI_URL:-https://gitlab.freedesktop.org/emersion/libdisplay-info.git}"
# wayland-protocols：同上，只用于构建（mpv 需要 >= 1.41 的协议 XML）。
WLP_URL="${WLP_URL:-https://gitlab.freedesktop.org/wayland/wayland-protocols.git}"

# librga 源码：nyanmisaka/rga 只在 gitee，GitHub 上同名仓库已 404；而 gitee 对境外 IP
# 返回 401（不是 404），GitHub Actions 的 runner 全在境外，clone 会报
#   fatal: could not read Username for 'https://gitee.com'
# 国内机器拉得通，所以实编时暴露不出这个故障——它是境外 CI 独有的坑。
# 处置：把 jellyfin-rga@1d330cc 的源码树内置到 vendor/（7.6MB），存在则直接解压，
# 不存在才回退 clone（国内手工构建仍可用）。详见 vendor/README.md。
RGA_TARBALL="${RGA_TARBALL:-/src/vendor/rga-jellyfin-rga.tar.gz}"

# mpv 的 rkmpp hwdec 补丁（boogie/nyanmisaka 系列，上游 mpv 未合并）。
# 不打这个补丁，mpv 里根本没有 --hwdec=rkmpp，整个包等于白做。
MPV_RKMPP_PATCH="${MPV_RKMPP_PATCH:-/src/patches/mpv-rkmpp-hwdec.patch}"

# wayland：libwayland-client/cursor/egl 用发行版自带的（bookworm 1.21，满足 mpv 的 >=1.21）。
# 但 wayland-protocols 必须 >= 1.41（mpv 的 meson 写 1.31 是过时的：wayland_common.c 无条件
# 调 wp_color_manager_v1_get_version()，该 XML 从 1.41 才进协议列表），bookworm 的 1.31 会
# 报 implicit declaration 直接编挂，故 [6/8] 单独编 1.44——只产构建期头文件，不进包。

# 兼容 branch / tag / commit-SHA 的浅取。
#
# 为什么要分三条路：`git clone -b` 只认 branch/tag，传 commit SHA 会直接失败；而按
# `clone 默认分支 + fetch <sha>` 取又会把整个仓库拉下来（mpp/ffmpeg 全历史几十 MB，
# CI 每次白等）。故先判形态：像 SHA 就走 init+fetch+specific-sha（GitHub 开了
# uploadpack.allowAnySHA1InWant，非默认分支上的 commit 也取得到，已实测 mpp 可行）。
#
# 另外：mpp/rga/ffmpeg 上游根本没有 tag，只有长期分支，分支头会自己往前走。
# 所以 Dockerfile 里这三个默认钉成完整 commit SHA —— 否则「不改代码也会编出不同字节」。
is_sha() {
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]
}

# 带 3 次重试：GitHub 偶发 `fetch-pack: invalid index-pack output`（实机日志里真出现过），
# 一次失败就整体中断太脆。
git_clone_ref() {
  local url="$1" ref="$2" dir="$3" recurse="${4:-}"
  local rec_flag="" try sha
  [ "$recurse" = recursive ] && rec_flag="--recursive"

  if is_sha "$ref"; then
    for try in 1 2 3; do
      rm -rf "$dir"; mkdir -p "$dir"
      if git -C "$dir" init -q . &&
         git -C "$dir" remote add origin "$url" &&
         git -C "$dir" fetch -q --depth=1 origin "$ref" &&
         git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD &&
         { [ "$recurse" != recursive ] || \
           git -C "$dir" submodule update --init --recursive --depth=1 -q; }; then
        sha="$(git -C "$dir" rev-parse HEAD)"
        # 取到的必须就是请求的那个 SHA，否则静默给了别的东西，比报错更危险
        [ "$sha" = "$ref" ] || {
          echo "FATAL: $dir 取到的 HEAD=$sha ≠ 请求的 $ref"; return 1; }
        return 0
      fi
      echo "[重试 $try/3] $url ($ref) 按 commit 浅取失败，5s 后重来"
      sleep 5
    done
    echo "FATAL: 无法按 commit $ref 取 $url"
    return 1
  fi

  for try in 1 2 3; do
    rm -rf "$dir"
    if git clone -q --depth=1 -b "$ref" $rec_flag "$url" "$dir"; then
      return 0
    fi
    echo "[重试 $try/3] $url ($ref) 克隆失败，5s 后重来"
    sleep 5
  done
  echo "FATAL: 无法克隆 $url ($ref)"
  return 1
}

# 记录每个上游实际落到哪个 commit。之前只记 ffmpeg 一个，其余六个编完就不知道是
# 哪份源码——出了问题无法回溯，也无法判断两次产物差异是不是同一份输入。
PINS=()
pin_record() {
  local name="$1" dir="$2" ref="$3" sha="${4:-}"
  [ -n "$sha" ] || sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf '[pin] %-15s ref=%-42s sha=%s\n' "$name" "$ref" "$sha"
  PINS+=("$name $sha")
}

mkdir -p "$STACK" "$MPVST"
cd /src

# /usr/local 的库（mpp/rga/libplacebo）以及 ffmpeg 的独立 libdir 都要能被 pkg-config 找到。
# 显式置顶，避免最小化镜像的 pkg-config 默认搜索路径不含 /usr/local/lib/pkgconfig 时，
# ffmpeg --enable-rkmpp/--enable-rkrga 或 mpv 找 libav* 时硬失败。
export PKG_CONFIG_PATH="$FFMPEG_LIBDIR/pkgconfig:$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "============================================================"
echo "[1/8] MPP ($MPP_REF)"
echo "============================================================"
git_clone_ref "$MPP_URL" "$MPP_REF" rkmpp
pin_record mpp rkmpp "$MPP_REF"
cmake -S rkmpp -B rkmpp/build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TEST=OFF
cmake --build rkmpp/build -j"$JOBS"
cmake --install rkmpp/build
DESTDIR="$STACK" cmake --install rkmpp/build

echo "============================================================"
echo "[2/8] librga ($RGA_REF)"
echo "============================================================"
if [ -n "$RGA_TARBALL" ] && [ -f "$RGA_TARBALL" ]; then
  echo "[info] 用内置源码 $RGA_TARBALL（跳过 gitee：境外 IP 会被 401）"
  rm -rf rkrga && mkdir -p rkrga
  tar xzf "$RGA_TARBALL" -C rkrga --strip-components=1
  # 内置 tar 里没有 .git，rev-parse 查不到；RGA_REF 是 SHA 时它同时就是校验基准。
  # 打包命令与来源 commit 记在 vendor/README.md。
  if is_sha "$RGA_REF"; then
    pin_record rga rkrga "vendor/rga-jellyfin-rga.tar.gz" "$RGA_REF"
  else
    pin_record rga rkrga "vendor tarball（RGA_REF 非 SHA，实际 commit 无法校验）" unknown
  fi
else
  echo "[info] 未找到内置源码，回退从 $RGA_URL 克隆"
  git_clone_ref "$RGA_URL" "$RGA_REF" rkrga
  pin_record rga rkrga "$RGA_REF"
fi
meson setup rkrga/build rkrga \
  --prefix="$PREFIX" --libdir=lib \
  --buildtype=release --default-library=shared \
  -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false
ninja -C rkrga/build
meson install -C rkrga/build
DESTDIR="$STACK" meson install -C rkrga/build

ldconfig

echo "============================================================"
echo "[3/8] ffmpeg-rockchip ($FFMPEG_REF → $FFMPEG_LIBDIR)"
echo "============================================================"
git_clone_ref "$FFMPEG_URL" "$FFMPEG_REF" ffmpeg
pin_record ffmpeg ffmpeg "$FFMPEG_REF"
FFDATE="$(git -C ffmpeg log -1 --format=%cd --date=format:%Y.%m.%d)"
FFHASH="$(git -C ffmpeg rev-parse --short HEAD)"
echo "${FFDATE}-1" > /VERSION
echo "ffmpeg 上游提交: $FFHASH ($FFDATE) → 包版本 $(cat /VERSION)"

# 可复现构建的关键一步：编译期也要 SOURCE_DATE_EPOCH，不能只在打包阶段设。
# 实测（run 41595714259 vs 41596349126）：两包里 rkmpp-stack 逐字节相同，唯独
# mpv-rkmpp 不同，逐字节比对下来只有 24 字节差异 —— 20 字节 ELF build-id +
# 4 字节来自二进制里内嵌的 __DATE__/__TIME__ 字符串（"Nov  3 2026 07:25:32" vs "07:31:05"）。
# 内容变了，ld 算出来的 build-id 自然跟着变，所以 build-id 只是「果」不是「因」。
# GCC 7+ / Clang 都认 SOURCE_DATE_EPOCH 来固定 __DATE__/__TIME__，钉到版本日期即可。
# 注意：打包脚本在另一个 RUN 层里执行，环境变量不跨层，故 package-debs.sh 里也各自设了一份。
# 这里用 python3 strptime 而不是 `date -d`：点分日期在 GNU date 上实测会返回非零。
SOURCE_DATE_EPOCH="$(python3 -c \
  'import sys,datetime as D; t=D.datetime.strptime(sys.argv[1].replace(".","-"),"%Y-%m-%d").replace(tzinfo=D.timezone.utc); print(int(t.timestamp()))' \
  "$FFDATE")" || {
  echo "FATAL: 无法从 ffmpeg 提交日期 $FFDATE 推出 SOURCE_DATE_EPOCH"; exit 1; }
export SOURCE_DATE_EPOCH
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH（编译期 __DATE__/__TIME__ 随之固定）"

cd ffmpeg
./configure --prefix="$PREFIX" --libdir="$FFMPEG_LIBDIR" \
  --enable-shared --disable-static \
  --enable-gpl --enable-version3 \
  --enable-libdrm --enable-rkmpp --enable-rkrga \
  --enable-gnutls \
  --disable-doc --disable-debug --disable-ffplay \
  --disable-xlib --disable-libxcb \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$FFMPEG_LIBDIR -Wl,-rpath,$FFMPEG_LIBDIR -Wl,-rpath,$PREFIX/lib"
make -j"$JOBS"
make install
make install DESTDIR="$STACK"
cd /src

# ---- ffmpeg 构建断言（不满足立即失败，不产出坏包）----
"$PREFIX/bin/ffmpeg" -hide_banner -decoders | has h264_rkmpp   || { echo "FATAL: 缺 h264_rkmpp"; exit 1; }
"$PREFIX/bin/ffmpeg" -hide_banner -decoders | has hevc_rkmpp   || { echo "FATAL: 缺 hevc_rkmpp"; exit 1; }
"$PREFIX/bin/ffmpeg" -hide_banner -encoders | has hevc_rkmpp   || { echo "FATAL: 缺 hevc_rkmpp 编码器"; exit 1; }
"$PREFIX/bin/ffmpeg" -hide_banner -filters  | has scale_rkrga  || { echo "FATAL: 缺 scale_rkrga"; exit 1; }
# 隔离布局断言：库必须落在独立 libdir，且二进制不能悄悄链到系统 ffmpeg
ldd "$PREFIX/bin/ffmpeg" | has "$FFMPEG_LIBDIR/libavcodec" || { echo "FATAL: ffmpeg 未链接到 $FFMPEG_LIBDIR"; ldd "$PREFIX/bin/ffmpeg" | grep avcodec; exit 1; }
echo "[断言通过] rkmpp 解码/编码/rkrga 滤镜在位，库位于 $FFMPEG_LIBDIR"
"$PREFIX/bin/ffmpeg" -hide_banner -decoders | grep rkmpp
"$PREFIX/bin/ffmpeg" -hide_banner -filters  | grep rkrga

echo "============================================================"
echo "[4/8] libplacebo ($LIBPLACEBO_TAG，mpv 0.41 要求 >= 6.338.2)"
echo "============================================================"
git_clone_ref https://github.com/haasn/libplacebo.git "$LIBPLACEBO_TAG" libplacebo recursive
pin_record libplacebo libplacebo "$LIBPLACEBO_TAG"
meson setup libplacebo/build libplacebo \
  --prefix="$PREFIX" --libdir=lib \
  --buildtype=release --default-library=shared \
  -Dvulkan=disabled -Dopengl=enabled \
  -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled \
  -Ddemos=false -Dtests=false
ninja -C libplacebo/build
meson install -C libplacebo/build
DESTDIR="$MPVST" meson install -C libplacebo/build   # libplacebo 只服务 mpv，打进 mpv 包

ldconfig

echo "============================================================"
echo "[5/8] libdisplay-info ($LDI_TAG，mpv 的 drm 功能硬依赖)"
echo "============================================================"
# mpv 0.41 的 meson 把 libdisplay-info 与 libdrm 并列绑在 drm 选项上
# （meson.build:958 `dependency('libdisplay-info', version: '>= 0.1.1', required: get_option('drm'))`），
# 而 Debian 12 bookworm 归档里根本没有这个包（Debian 13 才进），-Ddrm=enabled 会直接
# 卡在 meson 阶段；drm 功能又恰恰是 rkmpp hwdec（video/out/hwdec、drmprime）的编译开关，
# 不能退成 auto。故自编后随 mpv 包分发：顺带绕开各发行版 soname 不一致
# （bookworm 无 / trixie .so.2 / noble .so.1 / resolute .so.3），一包通吃，无需 Depends。
git_clone_ref "$LDI_URL" "$LDI_TAG" libdisplay-info
pin_record libdisplay-info libdisplay-info "$LDI_TAG"
meson setup libdisplay-info/build libdisplay-info \
  --prefix="$PREFIX" --libdir=lib \
  --buildtype=release --default-library=shared
ninja -C libdisplay-info/build
meson install -C libdisplay-info/build
DESTDIR="$MPVST" meson install -C libdisplay-info/build   # 只服务 mpv，打进 mpv 包
# 上游会顺手装个 di-edid-decode 调试工具，不进包
rm -f "$MPVST$PREFIX/bin/di-edid-decode"
ldconfig
pkg-config --modversion libdisplay-info
ldconfig -p | grep libdisplay-info || { echo "FATAL: libdisplay-info 未进 ldconfig 缓存"; exit 1; }

echo "============================================================"
echo "[6/8] wayland-protocols ($WLP_TAG，mpv 实际门槛 >= 1.41)"
echo "============================================================"
# mpv 的 meson 只写 `dependency('wayland-protocols', version: '>= 1.31')`，
# 但它的 video/out/wayland_common.c **无条件**调用 wp_color_manager_v1_get_version()，
# 而 color-management-v1.xml 只有 wayland-protocols >= 1.41 才会被加进协议列表
# （video/out/meson.build 里按 1.32/1.38/1.39/1.41/1.44/1.47 分级 gate）。
# bookworm 自带 1.31 → 实测直接编译失败：
#   error: implicit declaration of function 'wp_color_manager_v1_get_version'
# 所以这里自编一份只用于构建（XML/头文件，不参与运行期，不进任何 deb，不改 Depends）。
git_clone_ref "$WLP_URL" "$WLP_TAG" wayland-protocols
pin_record wayland-protocols wayland-protocols "$WLP_TAG"
meson setup wayland-protocols/build wayland-protocols \
  --prefix="$PREFIX" --libdir=lib --buildtype=release \
  -Dtests=false           # tests 要求 wayland-scanner >= 1.23，bookworm 只有 1.21
ninja -C wayland-protocols/build
meson install -C wayland-protocols/build
WLP_VER="$(pkg-config --modversion wayland-protocols)"
echo "[wayland-protocols] 生效版本: $WLP_VER（必须 >= 1.41，否则 mpv 编不过）"
[ "$(printf '%s\n1.41\n' "$WLP_VER" | sort -V | head -1)" = "1.41" ] \
  || { echo "FATAL: wayland-protocols $WLP_VER 低于 mpv 需要的 1.41"; exit 1; }
[ -f "$PREFIX/share/wayland-protocols/staging/color-management/color-management-v1.xml" ] \
  || { echo "FATAL: 缺 color-management-v1.xml，mpv 会编不过"; exit 1; }

echo "============================================================"
echo "[7/8] mpv ($MPV_TAG + rkmpp 补丁)"
echo "============================================================"
git_clone_ref https://github.com/mpv-player/mpv.git "$MPV_TAG" mpv
pin_record mpv mpv "$MPV_TAG"

# 汇总七个上游的实际 commit。复现历史产物时照这张表覆盖对应变量即可；
# 排查「同 pin 不同字节」时也先看这张表——输入真的相同，才轮到怀疑构建环境。
echo "------------------------------------------------------------"
echo "[上游 pin 汇总]（本包源码基线，日志可直接回溯）"
for _p in "${PINS[@]}"; do
  printf '  %-28s %s\n' "${_p%% *}" "${_p##* }"
done
echo "------------------------------------------------------------"

# rkmpp hwdec 补丁：给 mpv 注册 AV_HWDEVICE_TYPE_RKMPP（--hwdec=rkmpp）+ nv15/nv20 支持。
[ -f "$MPV_RKMPP_PATCH" ] || { echo "FATAL: 找不到 mpv rkmpp 补丁 $MPV_RKMPP_PATCH"; exit 1; }
if ! git -C mpv apply --check "$MPV_RKMPP_PATCH" 2>/dev/null; then
  echo "FATAL: rkmpp 补丁打不到 $MPV_TAG 上（上游代码变动，需 rebase 补丁）"
  git -C mpv apply --check --verbose "$MPV_RKMPP_PATCH" || true
  exit 1
fi
git -C mpv apply "$MPV_RKMPP_PATCH"
echo "[补丁] rkmpp hwdec 已应用"

# 去掉 .git：mpv 的 meson 用 vcs_tag 生成 version.h，有 .git 时会变成
# "v0.41.0-dev-gxxxxxxx-dirty"（打了补丁必然 dirty）；无 .git 时回退 MPV_VERSION，
# 得到干净的 "v0.41.0"，顺带让构建可复现。
rm -rf mpv/.git

cd mpv
# 注意：mpv 0.41 起 cplayer/libmpv 是 boolean 选项（0.40 为 feature），
# 写成 =enabled/=disabled 会在 meson 第一行报 "Value enabled is not boolean"。
# wayland=enabled：强制把 wayland 后端编进去（基座 bookworm 自带 1.21/protocols 1.31，
# 满足 mpv 的 >=1.21 / >=1.31 下限），编不上直接失败，而不是静默退回 X11-only。
# drm=enabled：drmprime / rkmpp hwdec 的编译开关，同时硬性要求 libdrm >= 2.4.105
# 与 libdisplay-info >= 0.1.1（后者已自编，见 [5/8]）。
# x11=enabled：mpv 的 x11 特性是 5 个 pkg-config 全在才算数
# （x11/xscrnsaver/xext/xpresent/xrandr），缺一个就静默关掉整个 X11 后端；
# 提前在 Dockerfile 装了 libxpresent-dev，这里再次强制，避免又退回「只有 wayland」。
# pulse=enabled：只编 ALSA 时 PipeWire/PulseAudio 桌面上没声（pipewire 走 pipewire-pulse 即可）。
PKG_CONFIG_PATH="$FFMPEG_LIBDIR/pkgconfig:$PREFIX/lib/pkgconfig" \
meson setup build \
  --prefix="$PREFIX" --libdir=lib --buildtype=release \
  -Dcplayer=true -Dlibmpv=false -Dwayland=enabled -Ddrm=enabled -Dx11=enabled \
  -Dpulse=enabled \
  -Dc_link_args="-Wl,-rpath,$FFMPEG_LIBDIR -Wl,-rpath,$PREFIX/lib"
ninja -C build
meson install -C build
DESTDIR="$MPVST" meson install -C build
cd /src

# ---- mpv 构建断言 ----
ldd "$PREFIX/bin/mpv" | has "$FFMPEG_LIBDIR/libavcodec" || { echo "FATAL: mpv 未链接 bundled ffmpeg"; ldd "$PREFIX/bin/mpv"; exit 1; }
ldd "$PREFIX/bin/mpv" | has "$PREFIX/lib/libplacebo"     || { echo "FATAL: mpv 未链接 bundled libplacebo"; ldd "$PREFIX/bin/mpv"; exit 1; }
# 关键功能断言：补丁生效后 --hwdec=rkmpp 才存在（method_name 来自 AVHWDeviceType 名）
"$PREFIX/bin/mpv" --hwdec=help 2>&1 | has 'rkmpp' || { echo "FATAL: mpv 没有 rkmpp 硬解（补丁未生效）"; "$PREFIX/bin/mpv" --hwdec=help 2>&1 | head -20; exit 1; }
# lua 版本必须与 control 的 Depends（liblua5.2-0）一致
ldd "$PREFIX/bin/mpv" | has 'liblua5.2' || { echo "FATAL: mpv lua 版本不是 5.2（Depends 会错位）"; ldd "$PREFIX/bin/mpv" | grep -i lua; exit 1; }
# wayland 后端必须真的编进去并链上系统 libwayland（>= 1.21，Debian 12 起满足）
nm -D "$PREFIX/bin/mpv" 2>/dev/null | has ' U wl_display_connect' || { echo "FATAL: mpv 没编 wayland 后端"; exit 1; }
ldd "$PREFIX/bin/mpv" | has 'libwayland-client\.so' || { echo "FATAL: mpv 未链接 libwayland-client"; ldd "$PREFIX/bin/mpv" | grep -i wayland; exit 1; }
ldd "$PREFIX/bin/mpv" | has 'libxkbcommon\.so' || { echo "FATAL: mpv 未链接 libxkbcommon（Depends 会缺项）"; ldd "$PREFIX/bin/mpv" | grep -i xkb; exit 1; }
# X11 后端必须是真编进去的：x11 特性只要缺 xpresent 就整体静默关闭（deepin 25 X11 会直接没画面）
nm -D "$PREFIX/bin/mpv" 2>/dev/null | has ' U XOpenDisplay' || { echo "FATAL: mpv 没编 X11 后端（x11/xext/xrandr/xscrnsaver/xpresent 有缺）"; exit 1; }
ldd "$PREFIX/bin/mpv" | has 'libX11\.so'     || { echo "FATAL: mpv 未链接 libX11"; ldd "$PREFIX/bin/mpv" | grep -i 'libX'; exit 1; }
ldd "$PREFIX/bin/mpv" | has 'libXpresent\.so' || { echo "FATAL: mpv 未链接 libXpresent（Depends 会缺项）"; ldd "$PREFIX/bin/mpv" | grep -i 'libX'; exit 1; }
# libdisplay-info 必须解析到自编副本（/usr/local/lib）：各发行版 soname 不同
# （bookworm 无 / trixie .so.2 / noble .so.1 / resolute .so.3），链到系统库就无法跨发行版
ldd "$PREFIX/bin/mpv" | has "$PREFIX/lib/libdisplay-info" || { echo "FATAL: mpv 未链接自编 libdisplay-info"; ldd "$PREFIX/bin/mpv" | grep -i display; exit 1; }
# 音频后端：pulse 在位（Depends libpulse0），否则 PipeWire/PulseAudio 桌面没声
ldd "$PREFIX/bin/mpv" | has 'libpulse\.so' || { echo "FATAL: mpv 未链接 libpulse（Depends 会缺项）"; ldd "$PREFIX/bin/mpv" | grep -i pulse; exit 1; }
echo "[断言通过] mpv 链接 bundled ffmpeg/libplacebo/libdisplay-info + 系统 libwayland/libX11/libpulse，--hwdec=rkmpp 与 wayland/X11 双后端均在位"
pkg-config --modversion wayland-client wayland-protocols wayland-egl libdisplay-info
"$PREFIX/bin/mpv" --hwdec=help 2>&1 | grep rkmpp
ldd "$PREFIX/bin/mpv" | grep -E 'wayland|libavcodec|libplacebo|libdisplay-info|libX11|libXpresent'

echo "============================================================"
echo "[8/8] 清理编译树（控磁盘）"
echo "============================================================"
rm -rf /src/rkmpp/build /src/rkrga/build /src/ffmpeg /src/libplacebo/build \
       /src/libdisplay-info/build /src/wayland-protocols/build /src/mpv/build
du -sh "$STACK" "$MPVST"
echo "构建完成，版本 $(cat /VERSION)"
