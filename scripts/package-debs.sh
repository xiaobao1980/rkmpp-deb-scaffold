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

  dpkg-deb --root-owner-group --build "$root" "$OUT/${name}_${VER}_arm64.deb"
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
echo "版本一致性检查（两包必须同号）："
dpkg-deb -f "$OUT/rkmpp-stack_${VER}_arm64.deb" Package Version
dpkg-deb -f "$OUT/mpv-rkmpp_${VER}_arm64.deb"  Package Version Depends
