#!/usr/bin/env bash
# 双 deb 组装：rkmpp-stack（运行栈）+ mpv-rkmpp（播放器）
# 输入：/stack /mpvstage /VERSION /src/packaging /src/scripts/rkmpp-verify
# 输出：/out/*.deb
set -euo pipefail

VER="$(cat /VERSION)"
OUT=/out
PKG=/src/packaging
# staging 目录由 build.sh 产出；这里给默认值，避免 set -u 下直接 unbound 中断
STACK="${STACK:-/stack}"
MPVST="${MPVST:-/mpvstage}"
mkdir -p "$OUT"

[ -d "$STACK/usr/local" ] || { echo "FATAL: $STACK 为空，构建阶段未产出 staging"; exit 1; }
[ -d "$MPVST/usr/local" ] || { echo "FATAL: $MPVST 为空，构建阶段未产出 staging"; exit 1; }

# 可复现构建：把 mtime 钉死到「版本日期」（= ffmpeg 上游 commit 日）。
# 不设的后果是实测到的：同样 pin、同样内容，两次构建出两个不同 SHA256 的 deb——
# 因为 dpkg-deb 会把 staging 里的文件 mtime（= 构建时刻）和 ar 成员头时间写进包里，
# 于是 xz 压缩后的字节数也跟着变（实测 9248224 vs 9253320，解包 diff 逐字节相同）。
# 设了 SOURCE_DATE_EPOCH 后 dpkg-deb 把所有 mtime 钳到该时刻，同 pin 必出同字节。
VER_DATE="${VER%%-*}"                                # 2026.10.25-1 → 2026.10.25
SOURCE_DATE_EPOCH="$(date -u -d "$VER_DATE 00:00:00" +%s)" || {
  echo "FATAL: 无法从版本号 $VER 推出 SOURCE_DATE_EPOCH（期望 <YYYY.MM.DD>-<rev>）"; exit 1; }
export SOURCE_DATE_EPOCH
echo "[打包] SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH（$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')）"

# xz 多线程会按块切分输入，-T1 与 -T4 的输出字节数不同 → 跨机器不可复现，必须锁 1 线程。
# --threads-max 是 dpkg 1.21.10+ 的开关，老版本没有，探测后再加，避免硬编依赖。
DPKG_BUILD_OPTS=(--root-owner-group)
if dpkg-deb --help 2>&1 | grep -q -- '--threads-max'; then
  DPKG_BUILD_OPTS+=(--threads-max=1)
fi

assemble() {
  local name="$1" stage="$2"
  local root="/tmp/debroot-$name"
  rm -rf "$root"
  mkdir -p "$root/DEBIAN"
  cp -a "$stage/." "$root/"

  sed "s/@VERSION@/$VER/g" "$PKG/$name/DEBIAN/control" > "$root/DEBIAN/control"
  cp "$PKG/$name/DEBIAN/postinst" "$root/DEBIAN/postinst"
  chmod 755 "$root/DEBIAN/postinst"
  # 可选的 conffiles（mpv-rkmpp 用它声明 /etc/mpv/mpv.conf）
  if [ -f "$PKG/$name/DEBIAN/conffiles" ]; then
    cp "$PKG/$name/DEBIAN/conffiles" "$root/DEBIAN/conffiles"
    chmod 644 "$root/DEBIAN/conffiles"
  fi

  # dpkg-deb --build 不会自己算 Installed-Size（那是 dpkg-gencontrol 的活），
  # 缺这个字段 apt 会把安装体积显示成 0，这里按 staging 实际占用（KB）补上。
  local ksize
  ksize="$(du -sk "$root" | cut -f1)"
  awk -v s="$ksize" '/^Description:/{print "Installed-Size: " s} {print}' \
    "$root/DEBIAN/control" > "$root/DEBIAN/control.tmp"
  mv "$root/DEBIAN/control.tmp" "$root/DEBIAN/control"

  dpkg-deb "${DPKG_BUILD_OPTS[@]}" --build "$root" "$OUT/${name}_${VER}_arm64.deb"
  echo "[打包] $OUT/${name}_${VER}_arm64.deb"
}

# rkmpp-stack：附带板端验机脚本
install -Dm755 /src/scripts/rkmpp-verify "$STACK/usr/local/sbin/rkmpp-verify"
# rkmpp-stack：udev 权限规则（rockchip-multimedia-config 缺失时补齐 MPP/RGA 的 video 组授权）
install -Dm644 "$PKG/rkmpp-stack/99-rkmpp-permissions.rules" \
  "$STACK/etc/udev/rules.d/99-rkmpp-permissions.rules"
# mpv-rkmpp：附带系统级默认配置（唯一来源 = 仓库根目录 mpv-rk35xx.conf，
# 它同时是给用户参考的通用版；装成 /etc/mpv/mpv.conf 并声明为 conffile）
MPV_CONF=/src/mpv-rk35xx.conf
[ -f "$MPV_CONF" ] || { echo "FATAL: 缺少 $MPV_CONF（唯一来源配置）"; exit 1; }
install -Dm644 "$MPV_CONF" "$MPVST/etc/mpv/mpv.conf"
assemble rkmpp-stack "$STACK"
assemble mpv-rkmpp  "$MPVST"

echo "$VER" > "$OUT/VERSION"
echo "============================================================"
ls -lh "$OUT"
echo "产物 SHA256（同 pin 重编应逐字节一致，不一致说明可复现性被破坏）："
sha256sum "$OUT"/*.deb
echo "版本一致性检查（两包必须同号）："
dpkg-deb -f "$OUT/rkmpp-stack_${VER}_arm64.deb" Package Version
dpkg-deb -f "$OUT/mpv-rkmpp_${VER}_arm64.deb"  Package Version Depends
