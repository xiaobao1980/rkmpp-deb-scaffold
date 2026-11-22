#!/usr/bin/env bash
#===============================================================================
# build-rk-hwaccel-local.sh  v2.3
# 在 openEuler 24.03 (RK3576, vendor 内核 6.1.x) 一键编译：
#   libdrm + rockchip-mpp + rockchip-rga + dav1d + libdisplay-info + libplacebo
#   + ffmpeg-rockchip + mpv （+ mesa 作为 GL 兜底层）
# 全部装到 /usr/local（自闭环，与系统 ffmpeg 并行），打成可跨发行版分发的 tar：
#   目标：openEuler 24.03 / deepin 25 / Debian trixie / Ubuntu noble / Ubuntu resolute
#         （Rockchip rk35xx vendor 内核；mainline 请走 V4L2 Request 线）
# 产物：$OUT/rk-hwaccel-local-<时间戳>.tar.gz  + 同名 .sha256 + install.sh + VERIFY.txt
#       tar 内：usr/local/...（自闭环）+ install.sh + VERIFY.txt
#       开机自适应（tar 内，见第 5 条变更）：
#         /usr/local/bin/rk-hwaccel-env            环境探针（单一事实源）
#         /usr/local/bin/rk-hwaccel-tune           按探针结论落地优化（开机/热插拔/装机）
#         /usr/local/lib/systemd/system/rk-hwaccel-tune.service  开机触发
#         /usr/local/share/rk-hwaccel/*.rules      热插拔触发 + mpp 设备权限补位
#         /usr/local/bin/mpv-auto                  每次播放的会话×片源细化
#       GL 兜底层（见 v2.3 变更）：
#         /usr/local/share/rk-hwaccel/glfallback/    自带 mesa(libgbm/EGL/GLES/Vulkan+闭包)
#           仅当系统自己给不出 GBM/EGL 时由探针判定、mpv-auto 与 profile.d 挂载；
#           刻意不进 /usr/local/lib——mesa 的 gbm/egl/dri 必须同源，混版本比没 GL 更糟
#
# 设计原则：
#   * glibc 就低不就高——在 openEuler(glibc 2.38) 构建，新 glibc 目标可直接跑（反向不行）
#   * 版本按上游锁定：ffmpeg 8.1 分支 + mpv 0.41 + libplacebo 6.338.2
#     （mpv≥0.37 起 libplacebo 是硬依赖，vo=gpu-next 需要它；0.36/ffmpeg6.1 是死路）
#   * 组件双写：先装进真实 /usr/local（后续组件的 pkg-config/头文件自然可见，
#     CI 干净容器同样成立），再用 DESTDIR 同步一份到 staging 作为打包内容
#     ——tar 里只会有本次构建的产物，不会混进构建机 /usr/local 的历史残留
#   * 目标机不依赖 LD_LIBRARY_PATH：--enable-rpath + patchelf 写 RUNPATH（lib+lib64）
#
# v2.0 变更（2026-11-22，对齐上游文档）：
#   1) RGA 改用上游 meson 构建（jellyfin-rga 的 meson.build 自带 pkgconfig.generate
#      + install_headers(subdir:'rga') + -DLINUX=1）→ 删掉 sed 翻 RGA_SAMPLES_ENABLE、
#      手写 librga.pc、以及"要求构建机 /usr/local 已有 rga 头文件"这三处补丁；
#      librga_demo 上游默认 false，不再打包 rgaImDemo。
#      参考 https://github.com/nyanmisaka/ffmpeg-rockchip/wiki/Compilation
#   2) MPP 加 -DBUILD_TEST=OFF（不再打包 mpi_*_test），并对齐上游 cmake 参数
#   3) 新增 libdisplay-info（mpv 0.41 的 vo=drm 依赖 libdisplay-info>=0.1.1）
#      与 libplacebo（-Dvulkan=disabled 免拖 glslang/shaderc 全链）
#   4) ffmpeg 8.1 + --enable-rpath；mpv v0.41.0（libplacebo 开启，gpu-next 可用）
#   5) 目标机环境自适应（三层，探测逻辑只在 rk-hwaccel-env 一处）：
#      * 开机时 rk-hwaccel-tune.service 重新探测并生效——发行版(openEuler/deepin/
#        trixie/noble/resolute)、vendor 内核、有无桌面、X11/Wayland、GNOME/XFCE/KDE、
#        GPU+GBM+Xv 能力、当前接的显示器是 1080p 还是 4K，据此生成 mpv 配置、
#        补 udev 规则与设备权限、补非 root 用户组（video,render,input,audio）
#      * HDMI 热插拔由 udev 触发重算（换显示器不用重装、不用重启）
#      * 每次播放 mpv-auto 再按"当时所在会话"细化（SSH 里跑与接屏跑结论不同）
#
# v2.1 变更（2026-11-22，RK3576/Armbian noble + GNOME Wayland 真机实测回灌）：
#   1) GPU 判定改以内核绑定在 renderD* 上的驱动名为准：mesa 25 的 gallium-loader 让
#      swrast/panfrost/panthor_dri.so 全是指向 libdril_dri.so 的软链，旧的"比 inode"
#      在 noble 上失真（openEuler 的硬链接场景仍适用，作次级判据保留）。
#   2) 开机实测已装 mpv 的能力面（--gpu-context/--vo），档位只发它支持的写法：
#      mpv 0.41 已删掉 --gpu-context=drm（实测是致命解析错误，整份配置作废）。
#      【v2.3 修正】当时由此推出"tty 的 GPU 直出只能走 displayvk"是错的：gpu-context
#      只约束 vo=gpu/gpu-next，vo=drm 自带 EGL/GBM 上下文，GLES 就够。
#   3) 删掉生成的 profile-allow 行：0.41 无此选项，写了会让整份 mpv.conf 解析失败。
#   4) 10bit 分叉：桌面会话内 10bit 用 rkmpp-copy（实测比零拷贝快 3 倍：0.58 vs 0.18x）；
#      无 GPU 的 tty 直出才用 AFBC+RGA（它是"能否显示"的正确性开关，不是提速开关）。
#   5) ffprobe 取片源属性改按字段名取（裸值顺序会变，实测把 60fps 读成 0、
#      pix_fmt 读成 "60/1"，导致高帧率/10bit 判定全错）；新增 8K 档识别。
#   6) 芯片能力事实（写进装机输出）：RK3576 无 AV1 硬解（回落 dav1d，4K60 约 0.9x）；
#      HEVC/VP9 4K60-10bit 的 VDU 纯解码上限约 0.42x，属芯片限制。
#   7) CI 可直接跑：MIRROR 默认空=直连 github（内网镜像显式传 MIRROR=...），
#      meson 版本不足 mpv 要求时自动用 pip 升级，产物附带 sha256
#
# v2.2 变更（2026-11-22，openEuler 24.03 SP4 vendor 裸板实测回灌）：
#   1) 装机解包不再死依赖 tar：openEuler 最小镜像连 tar 都没有，改用 python3 tarfile 兜底。
#   2) 新增系统库预检：裸板 ldd mpv 缺 libass/libdrm/libEGL/libgbm/libXpresent/libXss
#      六个系统库，装上也在运行时报 error while loading shared libraries。现在解包后立即
#      点名缺哪个、给出发行版对应的安装命令再退出（幂等，补完依赖重跑即可）。
#      预检带 LD_LIBRARY_PATH 指向包内 lib：此刻 ld.so.conf.d 还没写，不带会把
#      自家 libplacebo/libdav1d/librockchip_mpp 误报成系统缺库。
#   3) 结论：无 mesa 用户态（无 GBM/EGL）的 vendor 裸板跑不了任何 mpv 显示路径，
#      包括 vo=drm——探针把 GPU 降为 no 只影响档位选择，不影响这条硬事实。
#
# v2.3 变更（2026-11-22，把上一条结论变成可交付能力：包内自带 GL 兜底层）：
#   1) 新增 Step 2 libdrm 源码构建（进 /usr/local/lib）：这是纯 superset，RUNPATH 天然
#      覆盖，让所有目标机有一个确定的 libdrm 下限；其余芯片的 KMS API 与 udev 全关。
#   2) 新增 Step 10 mesa 兜底层（panfrost+softpipe、GBM/EGL/GLES、Vulkan ICD）：
#      只 DESTDIR 进 staging 的 share/rk-hwaccel/glfallback，一个字节都不进 /usr/local/lib。
#      GBM 在 mesa 里而不在 libdrm 里（2.4.124 已确认无 gbm/ 目录），所以只能自建 mesa。
#      prefix 就设成兜底目录本身，mesa 编译期写死的 DRI 搜索路径与 ICD json 的相对
#      library_path 才会自洽指向兜底目录。
#   3) 依赖闭包：把 mpv/ffmpeg 在构建机上"由系统提供"的 .so（libass/libX11/…）一并收进
#      兜底目录，裸镜像挂上它就能独立加载；glibc/libstdc++ 例外，必须跟系统走。
#   4) 探针新增 GL_SRC=system|bundle|none 与 GL_LIBDIR/GL_DRIDIR/GL_VKICD：系统在 GBM
#      缺失但包内有兜底时不再降级 GPU=no，mpv 能力面查询也改成带兜底环境再跑（裸机上
#      不带兜底连 --help 都会加载失败）。
#   5) 启用点只有两处且互斥于系统 mesa：mpv-auto 播放前 export；tune 另写
#      /etc/profile.d/rk-hwaccel-glfallback.sh 覆盖手工敲 mpv 的场景。系统日后装了 mesa，
#      下次开机自动撤销。
#   6) install.sh 预检改为两次 ldd 求差集：兜底能覆盖的只提示不拦，覆盖不到的才报错。
#   7) 打包新增毒判：glfallback 的 .so 出现在 usr/local/lib 直接 die（防 shadow 系统 mesa）。
#   8) mesa 取不到/编失败一律降级为"不带兜底"并写明原因，不拖垮整包构建（GLBUNDLE=0 可显式关）。
#   9) 【纠正 v2.1 的推论】tty 的 GPU 直出主档改为 vo=drm（GLES），新增档位 rk-drm-gl：
#      PanVK 只覆盖 Valhall 及以后，Bifrost（G52/G31：RK3528/3566/3568/3576）与
#      Midgard（T 系）上 displayvk 永远起不来，而 vo=drm 自带 EGL/GBM 上下文不需要
#      Vulkan。探针据 DT 的 arm,mali-* 定代际（GPU_MODEL/GPU_ARCH/VK_CAP），并有
#      libvulkan.so.1 存在性硬闸（VK_LD）；代际认不出即按"无 Vulkan"处理，不做乐观猜测。
#      displayvk 只在 mpv 真编了它（新增开关 PLACEBO_VULKAN=1，默认 0）+ 有 ICD +
#      Valhall+ 时才发。mesa 兜底层默认不带 loader，置 1 时才从构建机补一份。
#  10) 修真实缺陷：mpv-auto 从探针 eval 的键表里没有 GL_SRC/GL_LIBDIR/VO_DRM，
#      兜底层判定与 GLES 档拿不到值，裸机的包内 mesa 等于白装。
#  11) tty+GLES 的零拷贝（rkmpp→drm_prime→GBM）没有板上数字，所以开机配置仍发
#      rkmpp-copy，只由 mpv-auto 单次试错验证：5 秒内非零退出才退回 copy 重放并打印原因
#      （关掉：MPV_ZC_TRIAL=0）。10bit 不试（桌面实测零拷贝慢 3 倍）。
#  12) 离线仿真（14 例代际 + 7 例 Vulkan 闸门 + 9 例档位 + 11 例端到端）踩到的四个真缺陷：
#      a. ffprobe 的 r_frame_rate 没有斜杠时 ${RATE##*/} 把分子当分母，60fps 片算成
#         1000m/1000fps → 判成低帧率、降帧滤镜不发（现按 x/1 处理）；
#      b. MPV_ZC_TRIAL=0 只关掉了"试错"，HW 还停在未验证的 rkmpp（现在两处一起关）；
#      c. mpv-auto 在跑探针之前就要定 MPV，探针导出的 MPV_BIN 永远用不上，非标准
#         PREFIX 的机器只能撞 /usr/local/bin/mpv；ffprobe 同理改为跟着 mpv 的前缀走；
#      d. 生成的 mpv.conf 里档位菜单是全量的，Bifrost 板也能 --profile=rk-drm-gpu
#         选中一条必然黑屏的 displayvk 档 → 菜单保留（方便拷配置），但按探针给
#         本机用不了的档位逐条标注原因。
#  13) RK3576 裸 openEuler 实板复核（探针只读跑通，结论与离线仿真一致）带来的两处修正：
#      a. vendor DTS 的 GPU 节点 compatible 只写 arm,mali-bifrost，没有 gXX 型号名 →
#         代际挪进 GPU_ARCH、型号留空，机型用顶层 compatible 的 rockchip,rk3576 补位，
#         对外统一成 GPU_TAG（型号优先、其次 SoC），免得日志把代际当型号打出来；
#      b. 该发行版的 mesa 24.03 里根本没有 panfrost_dri.so（dri 只有 kms_swrast/swrast，
#         rockchip_dri.so 是 tinydrm 面板驱动；mesa-vulkan-drivers 只带 lvp+radeon ICD），
#         但 /usr/lib64/gbm 与 libEGL 齐备——只看 libgbm 会判成"有 GL"， GLES 档落到
#         kms_swrast 纯 CPU 光栅，比 KMS 拷帧更慢却看起来像 GPU 生效。新增 GL_GPU/
#         GL_DRIVER/GL_WHY：dri 目录里必须有"能用且不是 swrast 别名"的 GPU 驱动才算数；
#         系统层不满足而包内兜底层满足时，整包换成兜底层（同源，绝不跨版本混用）。
#  14) 配套把 GATE-GL 收紧：兜底层必须指名产出 panfrost_dri.so（mesa 换了安装库名时先
#      链接成标准名，链接不出来直接 die）——否则"兜底只编出 swrast"等于白装，探针照旧
#      判 GL_GPU=no，而构建期本该拦下这个问题。
#  15) CI 实测（mpv 编到 292/298 断）挖出 mpv 0.41 的门禁不自洽：video/out/meson.build
#      要 wayland-protocols>=1.41 才生成 color-management-v1.xml，而 wayland_common.c 的
#      hdr_metadata_valid() 没被 #if HAVE_WAYLAND_PROTOCOLS_1_41 包住就调
#      wp_color_manager_v1_get_version()。openEuler 24.03 只有 1.33，而 mpv 自己带
#      -Werror=implicit-function-declaration（CI 实测 GCC 12.3.1 也炸）→ 必然中断。
#      Step 9 现在只在系统版本不足时构建期补装协议包（纯 XML+pc、
#      不产运行库、不进产物），补不上就明确降级 -Dwayland=disabled 而不是让整包失败。
#  16) 同理拦下 Step 10 的两处：swrast 在 mesa 24.2 里是 softpipe,llvmpipe 的别名，
#      llvm=disabled 时 llvmpipe 是硬错误（改用 softpipe，也避免兜底层链上裸板没有的
#      libLLVM.so）；且 mesa 24 的 gallium 只有一个 libgallium-<版本>.so，驱动名靠
#      链接，上游只给 va/vdpau 建链接 → 构建后按 loader 要的名字自补。CI 又实测：
#      mesa 把实体装进 glfallback/lib，而 configure 的 "Driver dir" 指 glfallback/lib/dri
#      且该目录根本不创建，所以自补要自己 mkdir + 相对软链；libgallium 整体缺失时
#      撤回兜底层而不是 die（硬解照出，直出退到 KMS 拷帧档）。
#  17) CI 实测 Step 10 还差 PyYAML（mesa meson.build:967 是硬 error，不是可选依赖）：
#      补装按 openEuler 的包名 python3-pyyaml 走，候选名逐个试并逐个回验 import，
#      全都不上才降级为"不带兜底层"。同时修掉 Step 11 自检的误判——它拿固定路径
#      ^#!/bin/bash 比对，而内嵌脚本一律是 #!/usr/bin/env bash，任何构建都会 die。
#  18) CI 第四轮"驱动名就位"之后无提示 exit 1：依赖闭包那段在 set -e + pipefail 下
#      被 ldd 的非 0 退出码击穿——find -type f 把 lib/pkgconfig/*.pc 也交给 ldd，
#      ldd 撞非 ELF 返回 1，这个 1 顺着 while 循环体传到外层管道，整包构建连 GATE-GL
#      都没跑到就死了（第三轮其实是同一个坑，被上面临近的自补失败掩盖了）。
#      改为只扫 *.so* 且让 gl_scan 显式吞掉非 0；cp 失败也只记降级不 die。
#  19) CI 第五轮 Step 10 全绿（兜底层 84 个 .so / 78M 入包）后死在收尾毒判：名单里放了
#      libdrm.so.2，而 Step 2 恰恰用 die 强制它进 $PREFIX/lib（mpv 直接链接、RUNPATH
#      指向这里），两条门禁互斥，任何带 GL 兜底的构建都必死。名单收窄为 mesa 自家的
#      gbm/EGL/GLESv2 + libgallium* 前缀：这几个与系统 libdrm/X11 编译期 ABI 耦合，
#      才是真会 shadow 系统 mesa 的东西；libdrm 无符号版本、新版向后兼容，被系统
#      gbm 引用到也不会错配。
#  20) 板上装机预检抓到闭包漏抄：gl_scan 的"核心库跟系统走"排除式写成
#      (libc|libm|librt|…)[^/]*\.so，前缀匹配把 libmp3lame/libmpg123/libmount/libcom_err
#      全当成 libm/libc 家人跳过了。包内 libsndfile（mpv→libpulse→libsndfile）正好要
#      前两个，裸 openEuler 没装 lame/mpg123 → mpv 一 ldd 就缺件。排除式改为"名字后紧跟
#      .so 才算核心库"；老那条还有个副产物：[^/] 只有 GNU awk 认，BSD awk 直接报
#      nonterminated character class，现在两边都能跑。install.sh 的 rpm 包名映射同步补
#      lame/mpg123——照 SONAME 拼出来的 libmp3lame 在 openEuler 上不存在。
#  21) RK3576 裸 openEuler 实板装机（v2.3 首个产物）抓到的两个真缺陷：
#      a. 补用户组用的是空格分隔，usermod 把 "video render input audio" 当成一个组名
#         直接报错，四个组一个都没加进去（非 root 跑 mpv 就拿不到 renderD/mpp_service）
#         → 改逗号列表；
#      b. 装机 5/5 自检的 mpv/ffmpeg 能力查询没带包内 GL 兜底：裸板系统无 libgbm/libEGL，
#         连 --help 都加载失败，于是报"0 个解码器 / 0 项 hwdec / 未解析依赖 9"——全是假
#         阴性（手工带 $GLF 复查是 10 解码器、3 rkrga、20 hwdec、ldd 零缺件）。探针在
#         v2.3 第 4 条已改过，验证段漏了 → 统一走 VLD（含 $GLF）。
#  22) 板上跑分日志里每次启动都打三行伪报错（"Option gpu-context: 'displayvk' isn't
#      supported / Error parsing option / mpv.conf:28: setting option failed"）：档位
#      菜单第 12.d 条只做了"标注原因"，值本身照样发出去。放在 [profile] 段里不致命
#      （档没选中不影响播放，本轮 8K 空白行另有原因，见 23），但选中就是黑屏，且日志
#      不该有假错误 → 本机用不了的 gpu-context 值改为注释行，说明"换板子重生成时自动
#      放开"（本文件每次开机/热插拔重生成，Valhall 板自然拿到可用值）。x11egl/wayland
#      同闸：按 CTX_X11/CTX_WL 判定，本 mpv 没编的上下文不再裸发。
#  23) 跑分表里 "AFBC+RGA" 与 "GLES零拷贝" 五只片子数字一字不差——查出来 MPV_AFBC=1
#      这条"强制"开关在有机型的板子上根本进不去：闸门写的是 [ "$GPU" = no ] && ...，
#      而本板 GL=bundle 判成 GPU=yes，于是整个 RGA 分支被跳过，测的还是 GLES 路径。
#      改为 MPV_AFBC=1 可穿透 GPU=yes（默认行为不变，仍只在无 GPU 时自动启用），并在
#      强制时打一行说明，免得日志里看不出这条是用户按出来的。补 7 例端到端用例：
#      有/无 GPU × 10/8bit × 强制/不强制 × 缺 /dev/rga，覆盖"默认不发、强制必发"。
#  24) 承 23 继续查 AFBC/RGA：强制能穿透之后，四档数字仍然一模一样。板上真跑定位到
#      根因——scale_rkrga 在这套 vendor 内核 + 本包 mpv 上根本建立不起来：
#        [ffmpeg] Impossible to convert between the formats supported by the filter
#                 'mpv_src_default_in' and the filter 'auto_scale_0'
#        [lavfi]  failed to configure the filter graph
#        Disabling filter scale_rkrga.00 because it has failed.
#      copy/零拷贝/8bit/10bit/加不加 afbc=on 五种组合 5/5 全灭，ffmpeg CLI 直接喂
#      nv12、nv15 也同样接不上（"Unrecognised hwaccel output format: rkmpp"）。也就是说
#      我们只是把参数发出去，mpv 随即静默退回 CPU 的 swscale，日志却像走了硬件。
#      新增开机探针 RGA_FILTER（真跑 3 帧判定，结论缓存一天，RK_RGA_FILTER=yes|no 可
#      手工覆盖）：判不可用就不发 --vf/--vd-lavc-o，并把原因和"怎么强行试/怎么重探"打出来。
#  25) 顺带更正 23 里引用的一条旧结论（"瓶颈在 VDU，10bit 4K 约 25fps 上限"是桌面时代
#      的数据）：同一支 4K60-10bit HEVC 用本包 ffmpeg 纯硬解实测 81fps（1.35x），VDU
#      有余量；真正卡住的是 mpv 的取帧+GLES 送显——按 (已播×源fps−丢帧)/墙钟 算实际送显
#      帧率：1080p→1080p 11.5fps、4K8bit→1080p 7.2fps、4K8bit→4K 3.9fps、
#      4K10bit→1080p 3.5fps、4K10bit→4K 接近 0。--profile=fast 对这几档无差别。
#      另修 install.sh 的"生效档位"：它扫全文件，把档位菜单里的 vo=gpu-next/hwdec=rkmpp
#      也算成生效配置，现在只读第一个 [xxx] 之前的全局段。
#  26) 开机主线真跑一次才发现的大问题：rk-hwaccel-tune.service 从来没成功过。
#      journalctl 里是这两行：
#        rk-hwaccel-env: line 230: HOME: unbound variable
#        rk-hwaccel-tune: line 37: DISTRO_ID: unbound variable
#      根因：探针扫用户级 Vulkan ICD 目录时写了裸 $HOME，而 systemd 服务环境里没有 HOME，
#      脚本又是 set -u，于是探针整段死掉；tune 拿到空输出后在下一个变量上再崩，报错完全
#      指不到根因。此前看到的 mpv.conf 全是 install.sh 那一次生成的，"开机重算"其实一直
#      没生效——而这正是本次交付要验证的那条。修法两层：
#        a. 用户级目录一律 ${HOME:+…}，HOME 不存在就跳过该候选项；
#        b. tune 先把探针输出收进变量，查退出码与有没有 PROFILE=，探针挂了要明确报
#           "探针 X 退出码 N / 没给出结论"，而不是崩在无关变量上。
#      同类裸读已全量排查：$DISPLAY 那处本来就有 ${DISPLAY:-} 保护，其余没有。
#===============================================================================
set -euo pipefail

#------------------------- 可调版本（全部锁死，勿漂） -------------------------
# ref 均已用 git ls-remote 核实存在
MPP_REPO="https://github.com/nyanmisaka/mpp.git"
MPP_BRANCH="jellyfin-mpp"          # 分支（非 tag）；ffmpeg 要求 rockchip_mpp >= 1.3.9
RGA_REPO="https://github.com/nyanmisaka/rk-mirrors.git"
RGA_BRANCH="jellyfin-rga"          # 分支（非 tag）；meson 构建，产出 librga.pc
FF_REPO="https://github.com/nyanmisaka/ffmpeg-rockchip.git"
FF_BRANCH="8.1"                    # 上游 rkmpp/rkrga 全支持；master 已是 ffmpeg 9.1(lavc 63)，切换前先看 GATE
MPV_REPO="https://github.com/mpv-player/mpv.git"
MPV_TAG="v0.41.0"                  # meson>=1.3.0；libplacebo>=6.338.2 为硬依赖
LIBPLACEBO_VER="6.338.2"           # mpv 0.41 的下限；与板上已验证产物同版本
LIBDISPLAY_INFO_VER="0.2.0"
DAV1D_VER="1.5.4"                  # AV1 软解兜底
MPV_MESON_MIN="1.3.0"
# mpv 0.41 对 wayland-protocols 的真实下限是 1.41（不是它 meson 里写的 1.31，原因见 Step 9）；
# 补装取 1.47=mpv 自身门禁的最高档，已逐条核对 mpv 要的全部 XML 在该版目录里都存在
# （1.41+ 把 linux-dmabuf/tablet 提升进 stable，但 unstable 副本照样安装，mpv 的老路径不会断）
WAYLAND_PROTOCOLS_MIN="1.41"
WAYLAND_PROTOCOLS_VER="1.47"

# ---------------- GL 兜底包（裸 vendor 镜像用）------------------------------
# 现场实测：openEuler 24.03 SP4 vendor 板全盘无 libdrm/libgbm/libEGL，mpv 连加载都失败
# （error while loading shared libraries），vo=drm 之类的直出档位在这种板上无从谈起。
# 构建机上 dnf 装得到这些包不等于目标机有，所以把 GL 用户态随包带一份：
#   * 只落在 $PREFIX/$GLFALL_DIR，不进 /usr/local/lib —— 有 mesa 的桌面机完全不受影响，
#     不会出现"我们的 gbm 配上系统更新版 libEGL/驱动"这种跨版本错配
#   * 探针判定系统确有 GBM+EGL 时不启用；缺了才由 mpv-auto / profile.d 挂上
#   * libdrm 源码构建进 /usr/local（mpp/ffmpeg/mpv 的 RUNPATH 天然覆盖，是纯 superset）
#     GBM 不在 libdrm 里（2.4.124 已确认无 gbm/ 目录），libgbm 由 mesa 出
GLBUNDLE="${GLBUNDLE:-1}"          # 0=不附带 GL 兜底包
GLFALL_DIR="share/rk-hwaccel/glfallback"
LIBDRM_VER="2.4.124"               # URL 已核实 200；含 panfrost uapi 头
LIBDRM_URL="https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz"
MESA_VER="24.2.8"                  # src/gbm + src/panfrost(GLES/Vulkan) 均已核实存在
MESA_URL="https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
# tty 直出的 GPU 档默认走 vo=drm（自带 GBM/EGL，只要 GLES），不需要 Vulkan。
# 只有 Valhall 及以后的 Mali（RK3588 的 G610 等）有可用的 PanVK，才谈得上 displayvk；
# Bifrost（RK3566/3568/3576 的 G52）、Midgard（RK3288/3399 的 T 系）没有。
# 需要 displayvk 档位时显式 PLACEBO_VULKAN=1 重建（额外拖 glslang/shaderc 全链，
# 且目标机还得有 libvulkan.so.1——兜底层默认不带 loader，裸机请用 vo=drm 档）。
PLACEBO_VULKAN="${PLACEBO_VULKAN:-0}"

# 本地镜像源：构建机无法直连 github 时（内网透明代理拦截），由另一台机器预拉源码
# 起 http 服务提供。默认空=直连 github（CI 友好）；内网构建时显式传
#   MIRROR=http://192.0.2.10:8000 ./build-rk-hwaccel-local.sh   # 示例用文档专用地址，换成实际镜像机
# 注意用 ${MIRROR-}（不带冒号）：显式置空表示直连，未设置才取默认值
MIRROR="${MIRROR-}"

#------------------------- 路径与开关 -----------------------------------------
WORK="/opt/rk-local-build"        # 源码与中间产物
STAGE="$WORK/root"                # staging 根，内含 usr/local
PREFIX="/usr/local"               # 所有组件统一前缀
OUT="/opt/rk-local-out"           # 最终 tar 输出目录
JOBS="${JOBS:-$(nproc)}"          # 远程监控构建时建议 nproc-1，留 1 核给 ssh
KEEP_STAGE="${KEEP_STAGE:-0}"     # 1=不清空 staging 重建（增量调试用）

log()  { printf '\033[1;32m[BUILD]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
gate() { printf '\033[1;34m[GATE]\033[0m %s\n' "$*"; }

# 双写安装：先装进真实 $PREFIX（供后续组件发现头文件/库/.pc），再同步到 staging
do_install() {
  "$@"
  DESTDIR="$STAGE" "$@"
}

# 拉取源码：优先本地镜像 tar；镜像不可用则回落 git clone（镜像 IP 漂移不再致命）
fetch_src() {
  local dir="$1" tarball="$2" ref="$3" repo="$4"
  [ -d "$WORK/$dir" ] && return 0
  cd "$WORK"
  if [ -n "$MIRROR" ] && curl -fSL --max-time 300 "$MIRROR/$tarball" | tar xz; then
    log "  已用镜像源拉取 $dir ($MIRROR/$tarball)"
    return 0
  fi
  [ -n "$MIRROR" ] && log "  镜像源不可用，回落 github 直连：$dir"
  log "  从 github 拉取 $dir ($ref)"
  git clone --depth 1 --branch "$ref" "$repo" "$dir" || die "拉取失败：$repo ($ref)"
  # tar 包解出的目录名可能与 $dir 不同，做一次对齐
  [ -d "$WORK/$dir" ] || die "源码目录 $WORK/$dir 未生成（检查 tarball 顶层目录名）"
}

# freedesktop 官方 release tar.xz（不在 github，fetch_src 那套 git/tar.gz 不适用）
fetch_xz() {  # $1=目标目录 $2=下载 URL；已存在则跳过
  local dir="$1" url="$2"
  [ -d "$WORK/$dir" ] && return 0
  cd "$WORK" || return 1
  if [ -n "$MIRROR" ] && curl -fSL --max-time 600 "$MIRROR/${url##*/}" -o "$dir.tar.xz" 2>/dev/null; then
    log "  已用镜像源取 ${url##*/}"
  elif ! curl -fSL --max-time 600 "$url" -o "$dir.tar.xz"; then
    rm -f "$dir.tar.xz"; log "  下载失败：$url"; return 1
  fi
  rm -rf "$dir.tmp" && mkdir "$dir.tmp"
  if ! tar -xJf "$dir.tar.xz" -C "$dir.tmp" --strip-components=1; then
    rm -rf "$dir.tmp" "$dir.tar.xz"; log "  解包失败：${url##*/}"; return 1
  fi
  rm -f "$dir.tar.xz" && mv "$dir.tmp" "$dir"
  return 0
}

# 源码包地址：给了 MIRROR 就按"镜像根/文件名"拼，没给就用官方 URL。
# 不要再写 "${MIRROR:+$MIRROR/}dav1d-1.5.4.tar.gz" 那种拼接：MIRROR 为空时它产出的
# 是一个【非空】的相对名，后面 ${VAR:-官方URL} 的兜底永远不触发，curl 便把文件名当
# 主机名解析——CI 上 Step 5 就是死在 "Could not resolve host: dav1d-1.5.4.tar.gz"。
src_url() {  # $1=镜像内的文件名 $2=官方 URL
  if [ -n "$MIRROR" ]; then printf '%s/%s' "${MIRROR%/}" "$1"; else printf '%s' "$2"; fi
}

# 版本号比较：ver_ge 实际 最低要求 —— 缺包时传 "0"，恒小于任何真实版本
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

# Python 模块探针：mesa 的 meson setup 对 mako/yaml 是硬 error（见 Step 10），先探再装
py_mod() { python3 -c "import $1" 2>/dev/null; }
# py_mod_install import名 pip名 [dnf包名...]：各家发行版的 python3-* 包名大小写不统一，
# 逐个试；dnf 装完必须再 import 一次确认（包在但模块名不同也算失败），最后才退 pip3
py_mod_install() {
  local imp=$1 pip=$2 p
  shift 2
  py_mod "$imp" && return 0
  for p in "$@"; do
    dnf install -y "$p" >/dev/null 2>&1 && py_mod "$imp" && return 0
  done
  pip3 install --quiet "$pip" >/dev/null 2>&1 && py_mod "$imp"
}

# meson 版本门禁：mpv 0.41 要求 meson>=1.3.0，openEuler/Debian 老仓库可能不满足
ensure_meson() {
  local need="$1" have
  have=$(meson --version 2>/dev/null || echo 0)
  ver_ge "$have" "$need" && { log "  meson $have 满足要求"; return 0; }
  log "  meson $have < $need，用 pip 升级"
  dnf install -y python3-pip >/dev/null 2>&1 || apt-get install -y python3-pip >/dev/null 2>&1 || true
  pip3 install --quiet --upgrade "meson>=$need" || die "meson 升级失败（手动 pip3 install meson）"
  hash -r
  ver_ge "$(meson --version)" "$need" || die "meson 升级后仍为 $(meson --version)"
}

#------------------------- Step 0 前置检查 ------------------------------------
log "Step 0/11 前置检查"
[ "$(uname -m)" = "aarch64" ] || die "仅支持 arm64 原生构建（无交叉编译）"
if [ "${SKIP_MPP_CHECK:-0}" != "1" ]; then
  ls /dev/mpp_service >/dev/null 2>&1 || die "无 /dev/mpp_service，本机不是 vendor 内核；纯编译（CI）请 SKIP_MPP_CHECK=1"
fi
command -v dnf >/dev/null || die "本脚本按 openEuler/dnf 编写"
[ "$(id -u)" = 0 ] || die "需要 root：写 /usr/local、/opt 与装系统依赖（sudo ./build-rk-hwaccel-local.sh）"
# 注意：本脚本 set -o pipefail，取首行一律用 awk 'NR==1'，不用 head（大输出会触发 SIGPIPE）
glibc_ver=$(ldd --version | awk 'NR==1{print $NF}' | grep -oE '[0-9]+\.[0-9]+' | awk 'NR==1')
log "构建机 glibc = ${glibc_ver:-未知}（须为各目标中最低，openEuler 24.03 = 2.38）"
mkdir -p "$WORK" "$OUT"
if [ "$KEEP_STAGE" = "1" ]; then
  mkdir -p "$STAGE$PREFIX"
else
  rm -rf "$STAGE"; mkdir -p "$STAGE$PREFIX"
  # staging 从空开始 → tar 内容只含本次构建产物；真实 /usr/local 的历史残留不会混入
fi
# openEuler 是 lib64 体系，pkg-config 默认不搜 /usr/local/lib{,64}/pkgconfig；
# share/pkgconfig 也要给——wayland-protocols 的 .pc 按上游就装在 $datadir/pkgconfig 下
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:${LD_LIBRARY_PATH:-}"
ensure_meson "$MPV_MESON_MIN"

#------------------------- Step 1 依赖 ----------------------------------------
log "Step 1/11 安装编译依赖"
# 逐个探测可用性再安装：openEuler 各 SP 的 -devel 包名有出入，一次运行暴露全部缺失，
# 避免"一个错包名整批中断"
dnf_install() {
  local avail=() missing=() p
  for p in "$@"; do
    if dnf -q list --available "$p" >/dev/null 2>&1; then avail+=("$p"); else
      missing+=("$p"); log "  [缺失] $p"
    fi
  done
  [ ${#avail[@]} -gt 0 ] && dnf install -y "${avail[@]}" >/dev/null 2>&1 \
    || die "dnf install 失败：${avail[*]:-}"
  [ ${#missing[@]} -gt 0 ] && printf '%s\n' "${missing[@]}" > "$WORK/missing-deps.txt"
  return 0
}
# hwdata 不是 -devel 包，但 libdisplay-info 编 EDID 厂商表要读 /usr/share/hwdata/pnp.ids
dnf_install \
  gcc gcc-c++ make cmake meson ninja-build git pkgconf patch \
  nasm yasm perl python3 python3-pip patchelf \
  bison flex python3-packaging \
  curl tar gzip which diffutils \
  zlib-devel bzip2-devel xz-devel \
  alsa-lib-devel \
  gnutls-devel libass-devel freetype-devel fribidi-devel harfbuzz-devel fontconfig-devel \
  libpng-devel libjpeg-turbo-devel lcms2-devel \
  libdrm-devel mesa-libEGL-devel mesa-libGL-devel mesa-libgbm-devel \
  hwdata \
  libxkbcommon-devel wayland-devel wayland-protocols-devel \
  libX11-devel libXext-devel libXinerama-devel libXrandr-devel libXv-devel \
  libXScrnSaver-devel libXpresent-devel libXfixes-devel \
  lua-devel
# 可选：openEuler 有则用（libplacebo 的杜比视界重塑、mpv 的 cdda 与音频后端），缺了不致命
# pipewire/pulse 编进去后 mpv 在桌面会话能直接用系统音频服务；无桌面时
# rk-hwaccel-tune 生成的 mpv.conf 显式 ao=alsa 绕开探测
# vulkan-headers 只决定能否编出 displayvk 上下文（且需 PLACEBO_VULKAN=1）；
# tty 直出的主力档 vo=drm 靠 libdrm/gbm/egl，与 Vulkan 无关。
for p in libdovi-devel libcdio-paranoia-devel uchardet-devel \
         pipewire-devel pulseaudio-libs-devel vulkan-headers; do
  dnf -q list --available "$p" >/dev/null 2>&1 && dnf install -y "$p" >/dev/null 2>&1 \
    && log "  已装可选包 $p" || log "  [跳过] 可选包 $p"
done

#------------------------- Step 2 libdrm（GL 兜底的地基）---------------------
# 装进 $PREFIX/lib：mpp/ffmpeg/mpv 的 RUNPATH 天然覆盖它，是所有目标机的下限保证。
# 关掉其余芯片的 KMS API 与 udev——RK3576 的 panfrost 只用 libdrm 核心 + panfrost uapi
# 头，多余驱动只增大 shadow 面。GBM 不在 libdrm 里（2.4.124 无 gbm/ 目录），由 Step 10 出。
# 选项类型别混：udev/tests/install-test-programs 在 meson_options.txt 里是 boolean，只能
# 写 =true/=false；芯片 KMS API 与 cairo-tests/man-pages/valgrind 是 feature，才用 disabled。
# 写错直接 "value disabled is not boolean" 中止，CI 上就是这一步第一次踩到的原因。
log "Step 2/11 编译 libdrm ($LIBDRM_VER)"
cd "$WORK"
if fetch_xz "libdrm-$LIBDRM_VER" "$LIBDRM_URL"; then
  rm -rf build-libdrm
  meson setup build-libdrm "libdrm-$LIBDRM_VER" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=shared \
    -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
    -Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
    -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled \
    -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled \
    -Dudev=false -Dtests=false -Dinstall-test-programs=false \
    || die "libdrm meson setup 失败（选项名随版本变动，核对 $WORK/libdrm-$LIBDRM_VER/meson_options.txt）"
  ninja -C build-libdrm && do_install ninja -C build-libdrm install
  pkg-config --exists libdrm || die "pkg-config 找不到 libdrm——libdrm.pc 未生成"
  [ -e "$PREFIX/lib/libdrm.so.2" ] || die "$PREFIX/lib/libdrm.so.2 未就位"
  log "  libdrm $(pkg-config --modversion libdrm) → $PREFIX/lib"
elif [ "$GLBUNDLE" = "1" ]; then
  die "GLBUNDLE=1 但 libdrm 源码未取到：无网目标机会连 libdrm 都没有。修网络，或 GLBUNDLE=0 明确放弃兜底"
else
  log "  [跳过] libdrm 源码未取到，且 GLBUNDLE=0：继续用构建机系统 libdrm"
fi

#------------------------- Step 3 MPP -----------------------------------------
log "Step 3/11 编译 rockchip-mpp ($MPP_BRANCH)"
cd "$WORK"
fetch_src jellyfin-mpp jellyfin-mpp.tar.gz "$MPP_BRANCH" "$MPP_REPO"
rm -rf build-mpp
cmake -S jellyfin-mpp -B build-mpp \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release -DRKPLATFORM=ON -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF
cmake --build build-mpp -j"$JOBS"
do_install cmake --install build-mpp

#------------------------- Step 4 RGA（上游 meson 线，自带 librga.pc）---------
log "Step 4/11 编译 rockchip-rga ($RGA_BRANCH)"
cd "$WORK"
fetch_src jellyfin-rga jellyfin-rga.tar.gz "$RGA_BRANCH" "$RGA_REPO"
rm -rf build-rga
# -Dlibdrm=false：不链板上的 libdrm 3rdparty（用系统 libdrm-devel 即可）
# -Dlibrga_demo=false：显式关闭 rgaImDemo（上游默认亦为 false）
meson setup jellyfin-rga build-rga \
  --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=shared \
  -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false
ninja -C build-rga
do_install ninja -C build-rga install

gate "GATE-RGA：librga.pc 与 rga/im2d.h 就位（ffmpeg --enable-rkrga 的前提）"
pkg-config --exists librga || die "pkg-config 找不到 librga——meson 未产出 librga.pc"
log "  librga $(pkg-config --modversion librga)"
[ -f "$PREFIX/include/rga/im2d.h" ] || die "$PREFIX/include/rga/im2d.h 缺失"
[ -f "$PREFIX/include/rga/RgaApi.h" ] || die "$PREFIX/include/rga/RgaApi.h 缺失"

#------------------------- Step 5 dav1d ---------------------------------------
log "Step 5/11 编译 dav1d ($DAV1D_VER)"
cd "$WORK"
[ -d "dav1d-$DAV1D_VER" ] || {
  DAV1D_URL=$(src_url "dav1d-$DAV1D_VER.tar.gz" \
    "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VER/dav1d-$DAV1D_VER.tar.gz")
  curl -fSL "$DAV1D_URL" -o "/tmp/dav1d-$DAV1D_VER.tar.gz" || die "dav1d 源码拉取失败：$DAV1D_URL"
  tar xf "/tmp/dav1d-$DAV1D_VER.tar.gz"
  # gitlab archive 顶层目录就是 dav1d-<tag>
  [ -d "dav1d-$DAV1D_VER" ] || die "dav1d 解包后没有 dav1d-$DAV1D_VER 目录（检查 tar 顶层名）"
}
rm -rf build-dav1d
meson setup build-dav1d "dav1d-$DAV1D_VER" \
  --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=shared \
  -Denable_tools=false -Denable_tests=false
ninja -C build-dav1d
do_install ninja -C build-dav1d install

#------------------------- Step 6 libdisplay-info（mpv 的 EDID/DisplayID 解析）--
log "Step 6/11 编译 libdisplay-info ($LIBDISPLAY_INFO_VER)"
cd "$WORK"
[ -d "libdisplay-info-$LIBDISPLAY_INFO_VER" ] || {
  # 发布资产名是 libdisplay-info-<ver>.tar.xz（不是 <ver>.tar.xz），镜像里同名
  LDI_URL=$(src_url "libdisplay-info-$LIBDISPLAY_INFO_VER.tar.xz" \
    "https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/$LIBDISPLAY_INFO_VER/downloads/libdisplay-info-$LIBDISPLAY_INFO_VER.tar.xz")
  if curl -fSL "$LDI_URL" -o "/tmp/libdisplay-info.tar.xz"; then
    mkdir -p "libdisplay-info-$LIBDISPLAY_INFO_VER"
    tar xf /tmp/libdisplay-info.tar.xz -C "libdisplay-info-$LIBDISPLAY_INFO_VER" --strip-components=1
  else
    log "  发布包拉取失败（$LDI_URL），回落 git clone tag $LIBDISPLAY_INFO_VER"
    git -C "$WORK" clone --depth 1 --branch "$LIBDISPLAY_INFO_VER" \
      https://gitlab.freedesktop.org/emersion/libdisplay-info.git "libdisplay-info-$LIBDISPLAY_INFO_VER"
  fi
  [ -d "libdisplay-info-$LIBDISPLAY_INFO_VER" ] || die "libdisplay-info 源码未就位：tar 与 git 两条路都不通"
}
# libdisplay-info 的 meson.build 会用 hwdata.pc 或直接读 /usr/share/hwdata/pnp.ids 生成
# PNP 厂商表；两样都没有时 meson 只甩一句 "File /usr/share/hwdata/pnp.ids does not exist"，
# 看不出是缺数据包。这里先补装再断言，报错说清该装什么。
if [ ! -e /usr/share/hwdata/pnp.ids ]; then
  dnf install -y hwdata >/dev/null 2>&1 || apt-get install -y hwdata >/dev/null 2>&1 || true
fi
[ -e /usr/share/hwdata/pnp.ids ] || die "缺 /usr/share/hwdata/pnp.ids：装 hwdata 包（libdisplay-info 生成显示器厂商表的输入）"
rm -rf build-libdisplay-info
meson setup build-libdisplay-info "libdisplay-info-$LIBDISPLAY_INFO_VER" \
  --prefix="$PREFIX" --libdir=lib --buildtype=release
ninja -C build-libdisplay-info
do_install ninja -C build-libdisplay-info install

#------------------------- Step 7 libplacebo（mpv gpu-next 硬依赖）------------
log "Step 7/11 编译 libplacebo ($LIBPLACEBO_VER)"
cd "$WORK"
if [ ! -d "libplacebo-$LIBPLACEBO_VER" ]; then
  # GL 头文件是构建期由 vendored glad 现生成的，而 glad/jinja/markupsafe 都是 git
  # submodule：gitlab 的 archive tarball 里它们是空目录，meson 会在
  # src/opengl/include/glad/meson.build 报 "glad (required: >= 2.0, found: none)
  # was not found in PYTHONPATH or 3rdparty"（CI 上 Step 7 首次就死在这）。
  # 所以首选带子模块的 git 拉取；只有离线镜像才回退 tar，且回退后必须本机已有 glad。
  LP_GIT="https://code.videolan.org/videolan/libplacebo.git"
  [ -n "$MIRROR" ] && LP_GIT="${MIRROR%/}/libplacebo.git"
  if git clone --depth 1 --branch "v$LIBPLACEBO_VER" "$LP_GIT" "libplacebo-$LIBPLACEBO_VER" 2>/dev/null; then
    git -C "libplacebo-$LIBPLACEBO_VER" submodule update --init --depth 1 \
      3rdparty/glad 3rdparty/jinja 3rdparty/markupsafe 3rdparty/fast_float \
      || log "  [提示] 子模块未全部就位，下面按实际缺的再判"
  else
    log "  git 拉取失败，回落 tarball（$MIRROR 或官方 archive）"
    LP_URL=$(src_url "libplacebo-v$LIBPLACEBO_VER.tar.gz" \
      "https://code.videolan.org/videolan/libplacebo/-/archive/v$LIBPLACEBO_VER/libplacebo-v$LIBPLACEBO_VER.tar.gz")
    curl -fSL "$LP_URL" -o /tmp/libplacebo.tar.gz || die "libplacebo 源码拉取失败：$LP_URL"
    tar xf /tmp/libplacebo.tar.gz
    [ -d "libplacebo-$LIBPLACEBO_VER" ] || mv -f "libplacebo-v$LIBPLACEBO_VER" "libplacebo-$LIBPLACEBO_VER"
  fi
fi
# 判据与 libplacebo 自己一致：要么 3rdparty/glad 里有包，要么系统 python 能 import glad
if [ ! -s "libplacebo-$LIBPLACEBO_VER/3rdparty/glad/glad/__init__.py" ] \
   && ! python3 -c 'import glad; assert glad.__version__ >= "2.0"' 2>/dev/null; then
  die "libplacebo 缺 GL 头文件生成器 glad：子模块没拉下来（离线镜像的 tarball 不含 submodule）。
      修法一：git -C $WORK/libplacebo-$LIBPLACEBO_VER submodule update --init --depth 1 3rdparty/glad 3rdparty/jinja 3rdparty/markupsafe
      修法二：pip3 install 'glad>=2.0'（要有网）；两者都不行就只能放弃 GLES 档"
fi
rm -rf build-libplacebo
# vulkan 默认关：省掉 glslang/shaderc 全链，代价是 mpv 没有 displayvk 上下文。
# 这不是损失——tty 的 GPU 直出用 vo=drm（自带 GBM/EGL，GLES 即可），displayvk 只在
# Valhall+ 板上有意义，需要时 PLACEBO_VULKAN=1 重建。
# opengl=enabled 显式要求 EGL/GL 后端（gpu-next 在本硬件上走的就是它），
# 缺了就构建失败而不是静默降级
# 6.338.2 的 meson_options.txt 里没有 vkd3d（旧 4.x 才有），多写的 -D 一律算
# "Unknown options" 直接中止 setup；demos/tests 是 boolean 只能 true/false。
VKOPT=disabled; [ "$PLACEBO_VULKAN" = 1 ] && VKOPT=enabled
meson setup build-libplacebo "libplacebo-$LIBPLACEBO_VER" \
  --prefix="$PREFIX" --libdir=lib --buildtype=release \
  -Dvulkan="$VKOPT" -Dopengl=enabled -Dd3d11=disabled \
  -Ddemos=false -Dtests=false
ninja -C build-libplacebo
do_install ninja -C build-libplacebo install
pkg-config --exists libplacebo || die "libplacebo.pc 未生成"
log "  libplacebo $(pkg-config --modversion libplacebo)"

#------------------------- Step 8 ffmpeg-rockchip -----------------------------
log "Step 8/11 编译 ffmpeg-rockchip ($FF_BRANCH)"
cd "$WORK"
fetch_src ffmpeg-rockchip ffmpeg-rockchip.tar.gz "$FF_BRANCH" "$FF_REPO"
cd ffmpeg-rockchip
./configure \
  --prefix="$PREFIX" \
  --enable-shared --disable-static --enable-rpath \
  --enable-gpl --enable-version3 \
  --enable-gnutls --enable-libdav1d --enable-libass \
  --enable-rkmpp --enable-rkrga --enable-libdrm \
  --arch=aarch64 --target-os=linux || die "ffmpeg configure 失败"
make -j"$JOBS"
do_install make install
# 真实 /usr/local 的库纳入链接器缓存（openEuler 默认不搜 /usr/local/lib）
[ -f /etc/ld.so.conf.d/rk-hwaccel-build.conf ] || echo "$PREFIX/lib" > /etc/ld.so.conf.d/rk-hwaccel-build.conf
echo "$PREFIX/lib64" >> /etc/ld.so.conf.d/rk-hwaccel-build.conf
sort -u -o /etc/ld.so.conf.d/rk-hwaccel-build.conf /etc/ld.so.conf.d/rk-hwaccel-build.conf
ldconfig || true

FF_DECODERS="h264_rkmpp hevc_rkmpp vp9_rkmpp av1_rkmpp vp8_rkmpp mpeg1_rkmpp mpeg2_rkmpp mpeg4_rkmpp h263_rkmpp mjpeg_rkmpp"
gate "GATE-1：ffmpeg 硬解解码器 + rkrga 滤镜齐全"
ff_dec=$("$PREFIX/bin/ffmpeg" -hide_banner -decoders 2>/tmp/ff-dec.err) \
  || { sed 's/^/    /' /tmp/ff-dec.err | tail -20; die "ffmpeg 无法运行（多半是链接闭包不全）"; }
ff_fil=$("$PREFIX/bin/ffmpeg" -hide_banner -filters 2>/dev/null)
miss=""
for d in $FF_DECODERS; do printf '%s\n' "$ff_dec" | grep -qw "$d" || miss="$miss $d"; done
[ -n "$miss" ] && die "缺 rkmpp 解码器:$miss——检查 --enable-rkmpp 与 PKG_CONFIG_PATH"
printf '%s\n' "$ff_fil" | grep -q scale_rkrga || die "缺 scale_rkrga 滤镜——检查 --enable-rkrga"
log "GATE-1 通过（10 个 *_rkmpp 解码器 + scale_rkrga）"

#------------------------- Step 9 mpv -----------------------------------------
log "Step 9/11 编译 mpv ($MPV_TAG，三显示后端 + alsa + gpu-next)"
cd "$WORK"
fetch_src mpv mpv.tar.gz "$MPV_TAG" "$MPV_REPO"
rm -rf build-mpv

# 为什么这里要管 wayland-protocols（CI 上曾死在 mpv 的 292/298）：
#   mpv 的 video/out/meson.build 只有当协议包 >= 1.41 时才生成
#   staging/color-management/color-management-v1.xml（它 meson 里写的下限是 1.31，是假的），
#   可 wayland_common.c 的 hdr_metadata_valid()（v0.41.0 第 3285 行）漏了没包在
#   #if HAVE_WAYLAND_PROTOCOLS_1_41 里，直接调只存在于生成头的 wp_color_manager_v1_get_version()。
#   协议包偏旧的发行版（openEuler 24.03 实测 1.33）里这个符号根本不存在，而 GCC 14 起
#   implicit-function-declaration 默认按错误处理，编到最后一个 wayland 文件必然中断。
#   补的这份只有 XML 和 .pc，不产生任何运行库，因此只装在构建机、不进产物 tar。
bundle_wayland_protocols() {
  local have d url xml
  have=$(pkg-config --modversion wayland-protocols 2>/dev/null || echo 0)
  if ver_ge "$have" "$WAYLAND_PROTOCOLS_MIN"; then
    log "  系统 wayland-protocols $have 已满足 mpv（>= $WAYLAND_PROTOCOLS_MIN），不动它"
    return 0
  fi
  log "  系统 wayland-protocols $have 过旧（mpv $MPV_TAG 需 >= $WAYLAND_PROTOCOLS_MIN），构建期补装 $WAYLAND_PROTOCOLS_VER"
  d="wayland-protocols-$WAYLAND_PROTOCOLS_VER"
  if [ ! -d "$WORK/$d" ]; then
    cd "$WORK" || return 1
    # 只给 archive 地址：freedesktop 上 wayland-protocols 的 release 没有 downloads 资产
    # （和 libdisplay-info 那次 404 同一类坑），archive 才是稳定的取包路径
    url=$(src_url "$d.tar.gz" \
      "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/$WAYLAND_PROTOCOLS_VER/$d.tar.gz")
    curl -fSL --max-time 300 "$url" -o /tmp/wp.tar.gz \
      || { log "  拉取失败：$url"; return 1; }
    rm -rf /tmp/wp && mkdir -p /tmp/wp
    tar xzf /tmp/wp.tar.gz -C /tmp/wp || { rm -rf /tmp/wp /tmp/wp.tar.gz; log "  解包失败"; return 1; }
    [ -d "/tmp/wp/$d" ] || { log "  顶层目录不是 $d"; rm -rf /tmp/wp; return 1; }
    rm -rf "$WORK/$d" && mv "/tmp/wp/$d" "$WORK/$d"
  fi
  # 它的 meson 用 dependency('wayland-scanner') 取扫描器；有的发行版只装程序不给 .pc，
  # 就按实测版本补一个只在构建期生效的 pc 文件（同样只写进 $PREFIX，不改系统目录）
  if ! pkg-config --exists wayland-scanner 2>/dev/null; then
    local sv
    sv=$(wayland-scanner --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
    [ -n "$sv" ] || { log "  找不到 wayland-scanner 或读不到它的版本"; return 1; }
    if ! ver_ge "$sv" "1.20.0"; then
      log "  wayland-scanner $sv 过旧（补装的协议包在关掉自带测试时要求 >= 1.20）"
      return 1
    fi
    mkdir -p "$PREFIX/share/pkgconfig"
    printf 'prefix=%s\nwayland_scanner=%s\n\nName: Wayland Scanner\nDescription: Wayland scanner\nVersion: %s\n' \
      "$PREFIX" "$(command -v wayland-scanner)" "$sv" \
      > "$PREFIX/share/pkgconfig/wayland-scanner.pc"
    log "  已生成构建期用的 wayland-scanner.pc（版本 $sv）"
  fi
  rm -rf "build-$d"
  # -Dtests=false：跳过协议包自带的测试（那会额外要求 wayland-scanner>=1.23），
  # 协议文件的安装不受这个开关影响
  meson setup "build-$d" "$d" --prefix="$PREFIX" -Dtests=false \
    || { log "  wayland-protocols meson 配置失败"; return 1; }
  ninja -C "build-$d" || { log "  wayland-protocols 构建失败"; return 1; }
  # 这里刻意不用 do_install：产物 tar 里没有它的运行库，把协议文件收进去只是几百 KB 噪音
  ninja -C "build-$d" install || { log "  wayland-protocols 安装失败"; return 1; }
  have=$(pkg-config --modversion wayland-protocols 2>/dev/null || echo 0)
  ver_ge "$have" "$WAYLAND_PROTOCOLS_MIN" \
    || { log "  补装后 pkg-config 仍报 $have（$PREFIX/share/pkgconfig 没被优先取到）"; return 1; }
  xml="$(pkg-config --variable=pkgdatadir wayland-protocols)/staging/color-management/color-management-v1.xml"
  [ -f "$xml" ] || { log "  缺 $xml"; return 1; }
  log "  补装生效：wayland-protocols $have，color-management 协议就位"
}

# 补装失败就关 Wayland，而不是让整包构建断在最后一步：无桌面 tty 直出（vo=drm）不受影响，
# Wayland 桌面会话里 mpv 退化成走 XWayland——比"没有可用 mpv"好，且日志里写明白原因
WOPT=enabled
bundle_wayland_protocols || {
  WOPT=disabled
  log "  [降级] mpv 按 -Dwayland=disabled 构建：Wayland 会话将走 XWayland；"
  log "          要两全就装 $WAYLAND_PROTOCOLS_MIN+ 的 wayland-protocols-devel 再重编"
}
# RUNPATH 两目录都给：libav*/librockchip_mpp/librga/dav1d 在 lib，libmpv/libplacebo
# 由各自 meson 决定，openEuler 上常见 lib64 —— 只写一个会漏
# 0.41 的 meson.options 已无 libplacebo 选项（它变成硬依赖），再传 -Dlibplacebo 会
# 被判成 "Unknown options" 而中止，所以这里只给显示后端与音频开关。
meson setup build-mpv mpv \
  --prefix="$PREFIX" --libdir=lib --buildtype=release \
  -Dcdda=disabled -Ddvdnav=disabled -Dlibbluray=disabled \
  -Ddrm=enabled -Dgbm=enabled -Dwayland="$WOPT" -Dx11=enabled \
  -Dalsa=enabled \
  -Dmanpage-build=disabled \
  -Dc_link_args="-Wl,-rpath,$PREFIX/lib:$PREFIX/lib64"
ninja -C build-mpv
do_install ninja -C build-mpv install

MPV="$STAGE$PREFIX/bin/mpv"
gate "GATE-2：mpv 链接闭包与 RUNPATH"
mpv_ldd() { LD_LIBRARY_PATH="$STAGE$PREFIX/lib:$STAGE$PREFIX/lib64" ldd "$@"; }
mpv_ldd "$MPV" | grep 'not found' && die "mpv 有未解析依赖" || true
mpv_ldd "$MPV" | grep -v "$PREFIX/lib" | grep -Ev 'linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread|librt|libresolv|libnsl' \
  | grep '=> /' && log "注意：上列库来自系统（预期仅限 mesa/X11/wayland 运行时）" || true
readelf -d "$MPV" | grep -qE '(RUNPATH|RPATH).*'"$PREFIX"'/lib' || die "mpv 未写入 RUNPATH（检查 -Dc_link_args）"
readelf -d "$MPV" | grep -qE '(RUNPATH|RPATH).*'"$PREFIX"'/lib64' \
  || log "注意：RUNPATH 未含 $PREFIX/lib64（本次构建的 meson 库若落在此目录，目标机需 ld.so.conf.d 兜底）"
log "GATE-2 通过"

gate "GATE-3：mpv 功能面——rkmpp 硬解 / alsa 音频 / gpu-next 渲染"
run_mpv() { LD_LIBRARY_PATH="$STAGE$PREFIX/lib:$STAGE$PREFIX/lib64" "$MPV" --no-config "$@"; }
run_mpv --hwdec=help 2>/dev/null | grep -q rkmpp || die "mpv 未列出 rkmpp 硬解——检查 ffmpeg rkmpp 解码器"
# rkmpp-copy 是 tune/mpv-auto 的默认档（无 GPU 场景唯一可靠路径），必须真的可选
run_mpv --hwdec=help 2>/dev/null | grep -qw rkmpp-copy || die "mpv 未列出 rkmpp-copy——默认 hwdec 会失效"
# alsa 后端断言：AO 后端编译期定死，无声事故防回归（v1.1 教训）
run_mpv --ao=help 2>&1 | grep -Eq '(^|[[:space:]])alsa([[:space:]]|$)' \
  || die "mpv 无 alsa 音频后端——检查 alsa-lib-devel 与 -Dalsa=enabled"
# gpu-next 需要 libplacebo；缺了说明 libplacebo 没链上，mpv-auto 的 GPU 分支会变死代码
VOS=$(run_mpv --vo=help 2>/dev/null)
# vo=drm 是 tty 直出的主力档：它自带 GBM/EGL 上下文（只需 GLES），不依赖 gpu-context。
# 缺了它无桌面机型就没有任何 GPU 直出路径，所以硬失败（-Ddrm/-Dgbm 见上）
printf '%s\n' "$VOS" | grep -qw gpu-next || die "mpv 无 gpu-next VO——0.41 把 libplacebo 设成硬依赖（没有 -Dlibplacebo 开关了），检查 Step 7 是否装成功、pkg-config 能否找到 libplacebo"
printf '%s\n' "$VOS" | grep -qw drm || die "mpv 无 drm VO——检查 -Ddrm=enabled 与 libdrm/gbm/egl 开发包"
# 注意：mpv 0.41 的 --gpu-context 里【没有 drm】（RK3576 板上实测传 drm 是致命解析错误），
# 但这不影响 vo=drm——gpu-context 只约束 vo=gpu/gpu-next，vo=drm 走自己的 EGL/GBM 路径。
# displayvk 是 gpu-next 在 tty 上的另一个选项，只有 Valhall+ 的 Mali 有 PanVK 才可用，
# 默认构建（PLACEBO_VULKAN=0）不带；两者都缺时开机调优退回 vo=drm + rkmpp-copy。
run_mpv --gpu-context=help 2>/dev/null | grep -qw displayvk \
  && log "  本 mpv 支持 displayvk：Valhall+ 板（RK3588）可选 gpu-next/Vulkan 直出档" \
  || log "  本 mpv 无 displayvk（预期：libplacebo 关了 Vulkan）——无桌面机型走 vo=drm(GLES) 档"
# mpv-auto 的桌面分支（无 GPU 时用软件合成/overlay），缺了只是相应环境退化成默认回退
for v in wlshm xv x11 gpu; do
  printf '%s\n' "$VOS" | grep -qw "$v" || log "注意：本 mpv 未含 vo=$v——对应环境的自动分支会失效（检查 wayland/x11 依赖）"
done
mpv_ver=$(run_mpv --version 2>/dev/null)
printf '%s\n' "$mpv_ver" | grep -q -- '-LUA' && log "注意：本 mpv 未含 lua——OSC 进度条不可用（装 lua-devel 后重编）" || true
log "GATE-3 通过"

#------------------------- Step 10 GL 兜底包（mesa）---------------------------
# 目标：让"系统里根本没有 GL 用户态"的 vendor 裸板也能硬解+直出。
# 关键取舍——只写 staging 的 $GLFALL_DIR，一个字节都不进 $PREFIX/lib：
#   * 有 mesa 的目标机继续用系统版本，绝不会出现"我们的 libgbm 配系统新版 libEGL/驱动"
#     这种跨版本错配（mesa 的 gbm/egl/dri 三者必须同源）
#   * 缺 mesa 的裸镜像才由 rk-hwaccel-env 判定、mpv-auto 挂 LD_LIBRARY_PATH 启用
# prefix 直接设成 $PREFIX/$GLFALL_DIR：mesa 自算的 DRI 驱动搜索路径、Vulkan ICD json 里的
# 相对 library_path 都落在兜底目录内，整块可搬走。
log "Step 10/11 GL 兜底包（mesa $MESA_VER：libgbm + EGL/GLES + panfrost + Vulkan ICD）"
FB="$STAGE$PREFIX/$GLFALL_DIR"
GL_BUILT=0
GL_NOTE="（未附带：目标机需自备 libdrm/mesa/libass）"
if [ "$GLBUNDLE" = "1" ]; then
  # mesa 的代码生成器与 XML 依赖：装不上就降级为"不带兜底"，不拖垮整包构建
  py_mod_install mako Mako python3-mako python3-Mako || true
  # PyYAML 是 mesa meson.build:967 的硬 error（"Python (3.x) yaml module (PyYAML) required
  # to build mesa"），openEuler 的包名是 python3-pyyaml；这一条 CI 实测会卡在 setup 阶段
  py_mod_install yaml PyYAML python3-pyyaml python3-PyYAML python3-yaml || true
  dnf install -y expat-devel >/dev/null 2>&1 || true
  # 两个模块少任何一个都会在 meson setup 阶段中止，与其等它报错不如先查齐
  MESA_PY_MISS=""
  for _m in mako yaml; do py_mod "$_m" || MESA_PY_MISS="$MESA_PY_MISS $_m"; done
fi
if [ "$GLBUNDLE" != "1" ]; then
  log "  [跳过] GLBUNDLE=0：产物不含 GL 兜底（目标机需自备 libdrm/mesa/libass）"
elif [ "${MESA_PY_MISS:-}" != "" ]; then
  log "  [降级] 构建机缺 python3 模块$MESA_PY_MISS（mesa 的代码生成器）：不带 GL 兜底"
elif ! fetch_xz "mesa-$MESA_VER" "$MESA_URL"; then
  log "  [降级] mesa 源码未取到：不带 GL 兜底"
else
  rm -rf build-mesa
  # 选项类型/取值全部对过 mesa-24.2.8 的 meson_options.txt 与 meson.build（这一版有 5 个坑）：
  #  * gallium-drivers 的合法值里没有 surfaceless（那是 platforms 时代的老词），只有
  #    panfrost/swrast/softpipe/llvmpipe…；写错 meson 直接 "is not in the choices" 中止。
  #  * 别写 swrast：meson.build 169-180 行里 swrast 是 softpipe,llvmpipe 的别名，而
  #    llvmpipe 在 LLVM 关闭时是硬错误（1851 行 "llvmpipe requires LLVM and is enabled,
  #    but LLVM is disabled"）。退一步用 llvmpipe 也不对——它要么链系统 libLLVM.so（裸板
  #    没有这个库，兜底层一 dlopen 就废），要么 -Dshared-llvm=disabled 要求静态 LLVM 库。
  #    兜底层是给"系统连 GL 用户态都没有"的机器用的，自洽比软景快更重要，所以取 softpipe。
  #  * platforms 同样不接受 surfaceless/drm——但不用手填：EGL 一旦开起来 mesa 自动
  #    += surfaceless，GBM 再自动 += drm（meson.build 458-462）。这里显式给空数组，
  #    是为了躲开默认 auto 在 Linux 上选出 x11+wayland、把 X/Wayland 依赖拖进兜底层。
  #  * glvnd=disabled：直接产 libEGL.so.1，免得目标机还要有 glvnd 的 vendor 派发。
  #    video-codecs 留空：只当 GPU 驱动，不抢解码活。
  #  * opengl=false 必须配 glx=disabled（meson.build 430 行：不建桌面 GL 又留 glx 会报错）。
  #  * flex/bison 是硬性依赖（meson.build 1975：needs_flex_bison = with_any_opengl or
  #    with_gallium），已在 Step 1 的依赖清单里。
  if meson setup build-mesa "mesa-$MESA_VER" \
      --prefix="$PREFIX/$GLFALL_DIR" --libdir=lib --bindir=bin --datadir=share --includedir=include \
      --buildtype=release --default-library=shared -Db_ndebug=true -Db_lto=false \
      -Dgallium-drivers=panfrost,softpipe \
      -Dvulkan-drivers=panfrost \
      -Dplatforms= \
      -Dgbm=enabled -Degl=enabled -Dgles1=disabled -Dgles2=enabled \
      -Dopengl=false -Dglx=disabled -Dglvnd=disabled -Dllvm=disabled \
      -Dxmlconfig=disabled -Dbuild-tests=false -Dvideo-codecs= \
     && ninja -C build-mesa -j"$JOBS" \
     && DESTDIR="$STAGE" ninja -C build-mesa install; then
    GL_BUILT=1
  else
    log "  [降级] mesa 构建失败：产物不带 GL 兜底（正常发行版不受影响）"
  fi
fi

# Mesa 24 的 gallium 把各驱动都链进同一个 libgallium-<版本>.so，靠 loader 按
# "<驱动名>_dri.so" 去开它——openEuler 自带 mesa 里 swrast_dri.so 与 kms_swrast_dri.so
# 同 inode 就是这份证据。而我在上游源码里只查到 va/vdpau 前端调用 install_megadrivers.py，
# 没找到给 DRI 名字建链接的地方，所以按 loader 实际会请求的名字补齐链接：兜底层若只有
# libgallium-*.so，下面 GATE-GL 的 "缺 lib/dri/*_dri.so" 会当场 die，比到目标机上
# 才发现强。上游哪天自己把链接建了，这里逐名判存在、自动跳过。
if [ "$GL_BUILT" = 1 ]; then
  # CI 实测的安装布局：实体在 glfallback/lib/libgallium-<版本>.so，configure 打出的
  # "Driver dir" 却是 glfallback/lib/dri——上游根本不往那里装东西，目录压根不存在
  # （第一版自补逻辑用 find 找现成的 dri 目录，于是必然找不到）。改成按编译进去的
  # 路径自己建目录 + 相对软链；$prefix 是绝对路径，loader 的默认搜索路径已指向这里，
  # 不依赖 LIBGL_DRIVERS_PATH（探针仍然设它，属双保险）。
  GALLIUM=$(find "$FB/lib" -maxdepth 1 -name 'libgallium*.so*' -type f 2>/dev/null | head -1)
  DRI_DIR="$FB/lib/dri"
  if [ -z "$GALLIUM" ]; then
    # 连 libgallium 都没有 = gallium 的 DRI 前端没产出，这块兜底是废铁（loader 只会静默
    # 回落软 raster）。与其让 GATE-GL 把 25 分钟的整包构建拖死，不如明确撤回：产物照出，
    # 无桌面直出退回 KMS 拷帧档（rk-drm），硬解仍然生效。
    log "  [降级] 兜底层里没有 libgallium*.so：撤回 GL 兜底，产物照常出（直出退到 rk-drm 档）"
    rm -rf "$FB"
    GL_BUILT=0
    GL_NOTE="（未附带：mesa 的 DRI 前端未产出 libgallium）"
  else
    mkdir -p "$DRI_DIR"
    for n in panfrost swrast kms_swrast; do
      if [ -e "$DRI_DIR/${n}_dri.so" ]; then continue; fi   # 上游哪天自己建了就跳过
      ln -sfn "../$(basename "$GALLIUM")" "$DRI_DIR/${n}_dri.so" 2>/dev/null \
        || ln -f "$GALLIUM" "$DRI_DIR/${n}_dri.so" \
        || log "  [降级] 建不出 ${n}_dri.so"
    done
    # 建完回读：断链 dlopen 只会静默回落成软 raster，比缺文件难查得多
    for n in panfrost swrast kms_swrast; do
      if [ ! -e "$DRI_DIR/${n}_dri.so" ]; then
        log "  [降级] ${n}_dri.so 指不到实体文件（相对软链目标丢了？）"
      fi
    done
    log "  驱动名就位：$(cd "$DRI_DIR" && ls | tr '\n' ' ')→ $(basename "$GALLIUM")"
  fi
fi

if [ "$GL_BUILT" = 1 ]; then
  # 依赖闭包：把 mpv/ffmpeg 在构建机上"由系统提供"的那部分 .so 一并收进兜底层，
  # 这样在连 libass/libX11 都没有的最小镜像上，挂上这个目录就能独立加载。
  # glibc/libstdc++ 之类必须跟系统走，永不打包（否则和内核 ABI 打架）。
  gl_seed() { for b in mpv ffmpeg ffprobe; do [ -e "$STAGE$PREFIX/bin/$b" ] && printf '%s\n' "$STAGE$PREFIX/bin/$b"; done; }
  gl_scan() {  # 把 ldd 输出里"解析到 $PREFIX 之外"的依赖路径打出来
    # 结尾的 || true 是必需的：构建脚本开了 set -e + pipefail，而 ldd 撞上非 ELF 文件
    # （兜底目录里的 *.pc、meson 生成的脚本）会返回 1，这个 1 会顺着 while 循环体的
    # 状态一路传到外层管道，把整包构建静默带走——CI 上"驱动名就位"之后无提示 exit 1
    # 就是这么来的（连 GATE-GL 都没跑到）。
    { LD_LIBRARY_PATH="$FB/lib:$STAGE$PREFIX/lib" ldd "$1" 2>/dev/null | awk -v pfx="$STAGE$PREFIX/" '
      NF>=4 && $2=="=>" && $3 !~ /^\/$/ && $3 !~ /^not/ {
        if ($3 ~ "^"pfx) next
        # 只排"glibc 家族必须跟系统走"的那几个，且必须紧贴 .so：早先写成
        # (libc|libm|librt|...)[^/]*\.so，前缀匹配把 libmp3lame/libmpg123/libmount/
        # librtmp/libcom_err 全当成 libm/libc/librt 家人给跳过了——闭包因此缺件，
        # 裸 openEuler 板上 mpv 一 ldd 就报缺 libmp3lame.so.0（libsndfile 的真依赖）。
        if ($3 ~ /\/(libc|libcrypt|libm|libdl|libpthread|librt|libresolv|libutil|libanl|libnsl|libstdc\+\+|libgcc_s)\.so/) next
        if ($3 ~ /\/ld-linux/) next
        print $3
      }'; } || true
  }
  round=0
  while [ "$round" -lt 20 ]; do
    round=$((round+1)); changed=0
    # 只扫共享对象：-type f 会把 lib/pkgconfig/*.pc 也算进来，那些不是 ELF
    { gl_seed; find "$FB/lib" -maxdepth 2 -type f -name '*.so*' 2>/dev/null; } \
      | while read -r f; do gl_scan "$f"; done | sort -u > "$WORK/gl-want.txt"
    while read -r src; do
      [ -e "$src" ] || continue
      dst="$FB/lib/$(basename "$src")"
      if [ ! -e "$dst" ]; then
        cp -L "$src" "$FB/lib/" && changed=1 || log "  [降级] 依赖闭包抄不进 $dst"
      fi
    done < "$WORK/gl-want.txt"
    [ "$changed" = 1 ] || break
  done
  rm -f "$FB/lib/"*.py "$FB"/lib/*.a

  gate "GATE-GL：兜底层自洽性"
  for need in lib/libgbm.so.1 lib/libEGL.so.1 lib/libGLESv2.so.2; do
    [ -e "$FB/$need" ] || die "GL 兜底缺 $need（mesa 选项没编出来：libgbm 看 -Dgbm，EGL/GLES 看 -Degl/-Dgles2；platforms 留空即可，EGL 一开 mesa 自动补 surfaceless、GBM 再补 drm）"
  done
  ls "$FB"/lib/dri/*dri.so >/dev/null 2>&1 || die "GL 兜底缺 lib/dri/*_dri.so：无 GBM 后端可用的驱动"
  # 兜底层的存在意义就是"系统 mesa 给不出 Mali 驱动"（openEuler 裸 mesa 只有 swrast），
  # 所以要指名有 panfrost：只有 swrast 的兜底层等于没兜底，探针仍会判 GL_GPU=no。
  if [ ! -e "$FB/lib/dri/panfrost_dri.so" ]; then
    p=$(find "$FB/lib/dri" -name 'panfrost_dri.so' 2>/dev/null | awk 'NR==1')
    if [ -n "$p" ]; then
      ln -sf "$(basename "$p")" "$FB/lib/dri/panfrost_dri.so"
      log "  已按标准名链接 panfrost_dri.so ← ${p##*/}"
    else
      die "GL 兜底没有 panfrost_dri.so：检查 -Dgallium-drivers 是否含 panfrost（否则裸 mesa 的板子仍然用不了 GLES 档）"
    fi
  fi
  ls "$FB"/share/vulkan/icd.d/*.json >/dev/null 2>&1 \
    && log "  Vulkan ICD：$(ls "$FB"/share/vulkan/icd.d/ | awk '{printf "%s ", $1}')（仅 Valhall+ 有设备；Bifrost 的 G52/G31 由探针的代际闸挡掉）" \
    || warn "  未产出 Vulkan ICD：displayvk 档位在裸机上不会启用（不影响 GLES/vo=drm）"
  # ICD json 只是"驱动注册表"，跑起来还要 Vulkan loader（libvulkan.so.1，属 vulkan-loader
  # 项目、不在 mesa 里）。默认构建不带 displayvk，所以默认也不带 loader；PLACEBO_VULKAN=1
  # 时从构建机补一份进兜底目录，否则探针会因缺 loader 判定 Vulkan 不可用。
  if [ "$PLACEBO_VULKAN" = 1 ] && [ ! -e "$FB/lib/libvulkan.so.1" ]; then
    vkl=$(ldconfig -p 2>/dev/null | awk '/libvulkan\.so\.1/{print $NF; exit}')
    [ -n "$vkl" ] && [ -e "$vkl" ] && cp -L "$vkl" "$FB/lib/" \
      && log "  已随兜底层带上 Vulkan loader：${vkl##*/}" \
      || warn "  PLACEBO_VULKAN=1 但构建机没有 libvulkan.so.1：裸机将用不了 displayvk（有 mesa 的机器不受影响）"
  fi
  GL_NOTE=""
  log "  GL 兜底：$(find "$FB/lib" -type f | wc -l | awk '{print $1}') 个 .so，$(du -sh "$FB" | awk '{print $1}')（不进 /usr/local/lib，只在系统缺 GL 时启用）"
fi

#------------------------- Step 11 打包 ---------------------------------------
log "Step 11/11 生成跨发行版分发 tar"
TS="$(date +%Y%m%d-%H%M)"
TARBALL="rk-hwaccel-local-$TS.tar.gz"

#============== 目标机脚本：环境探针（install.sh 与 mpv-auto 共用的事实源）=====
rk_hwaccel_env() { cat <<'ENV_EOF'
#!/usr/bin/env bash
# rk-hwaccel-env —— RK35xx 硬解栈的系统环境探针
# 输出 KEY=VALUE（可 eval 复用）。装机、排障、播放决策都用同一份判定，避免各说各话。
# 用法：rk-hwaccel-env            打印全部 KEY="VALUE"（可 eval 载入）
#       rk-hwaccel-env --quiet    只做探测不输出（供脚本自检）
set -u

# ---------- 发行版（ID / 版本 / codename：openeuler、deepin、debian trixie、
#            ubuntu noble/resolute 等一律按同构处理，差异只在包管理与库路径）----------
DISTRO_ID=unknown; DISTRO_VER=unknown; DISTRO_CODENAME=unknown; DISTRO_NAME=unknown
[ -r /etc/os-release ] && . /etc/os-release && DISTRO_ID="${ID:-unknown}" \
  && DISTRO_VER="${VERSION_ID:-unknown}" && DISTRO_CODENAME="${VERSION_CODENAME:-unknown}" \
  && DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
case "$DISTRO_ID" in
  openEuler|openeuler) FAMILY=oe;   PKG=dnf  ;;
  deepin|debian|ubuntu|raspbian|linuxmint|armbian) FAMILY=deb; PKG=apt ;;
  *) FAMILY=other; PKG=unknown ;;
esac

# ---------- 内核：vendor(BSP) 与 mainline 的分水岭 ----------
KERNEL=$(uname -r)
MPP_NODE=no;  [ -e /dev/mpp_service ] && MPP_NODE=yes
RGA_NODE=no;  [ -e /dev/rga ] && RGA_NODE=yes
case "$KERNEL" in
  *vendor*|*bsp*|*rk35*|*rockchip*) KERNEL_VENDOR=yes ;;
  *) KERNEL_VENDOR=no ;;
esac
[ "$MPP_NODE" = yes ] && KERNEL_VENDOR=yes   # 设备节点比内核名更可信
# 芯片：设备树 compatible 里找 rk35xx / rk3288 之类
# 注意 2>/dev/null 挡不住"重定向打开失败"本身（那是 shell 报的），必须先 [ -r ]
CHIP=""
for dt in /proc/device-tree/soc/compatible /proc/device-tree/compatible /proc/cpuinfo; do
  [ -r "$dt" ] || continue
  c=$(tr '\0' ' ' < "$dt" | grep -oiE 'rk[0-9]{4,5}[a-z]*' | sort -u | awk 'END{print $1}')
  [ -n "$c" ] && { CHIP=$c; break; }
done
CHIP=${CHIP^^}
[ -n "${CHIP:-}" ] || CHIP=unknown

# ---------- 库目录（本包统一装 lib，但目标系统自身是 lib64 体系时要一并登记）----------
LIBDIRS="/usr/local/lib /usr/local/lib64"

# ---------- 真实 GPU 渲染能力 ----------
# 坑 1（openEuler 实测）：mesa-dri-drivers 把 swrast_dri.so 硬链接成 rockchip_dri.so
#   等几十个名字，只看文件名会把软件渲染误判成有 GPU。
# 坑 2（Armbian noble / mesa 25 实测）：gallium-loader 让 swrast/panfrost/panthor_dri.so
#   全是指向 libdril_dri.so 的符号链接，解引用后 inode 又全部相同——比 inode 反而失真。
# 结论：以内核绑定在 render 节点上的驱动名为准（sysfs 是唯一不会被打包技巧骗过的证据），
#   DRI 文件只在拿不到 render 节点时作辅助判据。
GPU=no; GPU_DRV=none; GPU_NODE=none; GBM=no; GPU_WHY="" 
for n in /sys/class/drm/renderD*; do
  [ -e "$n" ] || continue
  drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null)
  case "$drv" in
    panthor|panfrost|lima|vc4|etnaviv) GPU=yes; GPU_DRV=$drv; GPU_NODE=${n##*/}; break ;;
  esac
done
if [ "$GPU" != yes ]; then
  DRI_DIRS="/usr/lib64/dri /usr/lib/aarch64-linux-gnu/dri /usr/lib/dri"
  SW_INODE=""
  for d in $DRI_DIRS; do
    t=$(readlink -f "$d/swrast_dri.so" 2>/dev/null)   # 必须解引用：符号链接自身 inode 无意义
    [ -n "$t" ] && [ -f "$t" ] && { SW_INODE=$(stat -c %i "$t" 2>/dev/null); break; }
  done
  for drv in panthor panfrost lima vc4; do
    [ "$GPU" = yes ] && break
    for d in $DRI_DIRS; do
      t=$(readlink -f "$d/${drv}_dri.so" 2>/dev/null)
      [ -n "$t" ] && [ -f "$t" ] || continue
      inode=$(stat -c %i "$t" 2>/dev/null)
      [ -n "$inode" ] && [ "$inode" != "$SW_INODE" ] && { GPU=yes; GPU_DRV=$drv; break; }
    done
  done
fi
for d in /usr/lib64/gbm /usr/lib/aarch64-linux-gnu/gbm /usr/lib/gbm; do
  ls "$d"/*.so >/dev/null 2>&1 && { GBM=yes; break; }
done
# ---------- GL 用户态出处：系统 mesa 还是本包自带的兜底层 ----------
# 兜底层只在"系统自己给不出能用的 GBM+EGL"时启用；有 mesa 且带 Mali 驱动的桌面机继续用系统的。
# 刻意不塞进 /usr/local/lib：mesa 的 gbm/egl/dri 三者必须同源，我们的 libgbm 去配系统
# 更新版的 libEGL/驱动会直接崩——跨版本混染比"没有 GL"更糟。
GLFALL_DIR=${GLFALL_DIR:-/usr/local/share/rk-hwaccel/glfallback}
GLFALL=no
[ -e "$GLFALL_DIR/lib/libgbm.so.1" ] && [ -e "$GLFALL_DIR/lib/libEGL.so.1" ] && GLFALL=yes
SYS_DRIDIR="/usr/lib64/dri /usr/lib/aarch64-linux-gnu/dri /usr/lib/dri"
GL_LIBDIR=""; GL_DRIDIR=""; GL_VKICD=""
# "看到 libgbm"不等于"有 GPU 用户态"（openEuler 24.03 SP4 板上实测）：它的 mesa 24.0.3
# 里根本没有 panfrost_dri.so，dri 目录只有 kms_swrast/swrast，而那个 rockchip_dri.so 是
# tinydrm 的面板驱动、不是 GPU；mesa-vulkan-drivers 也只带 lvp+radeon 两个 ICD。这种机器
# 上 vo=drm 会经 kms_swrast 纯 CPU 光栅——比 KMS 拷帧直出更慢，日志里却像 GPU 在正常工作。
# 所以 GLES 档的真判据是"dri 目录里有能用、且不是 swrast 别名的 GPU 驱动"，
# 系统层不满足时整包换成自带 mesa（同源），绝不与系统 libEGL 混用。
GL_NAMES=""
case "$GPU_DRV" in
  panfrost|panthor) GL_NAMES="panfrost panthor" ;;   # panthor 只管 Vulkan，GLES 仍靠 panfrost_dri.so
  lima|vc4|etnaviv) GL_NAMES=$GPU_DRV ;;
  *)                GL_NAMES="panfrost panthor lima" ;;   # 内核证据缺失时按常见开源驱动名找
esac
GL_HIT=""
dri_has_gpu_driver() {   # $1=候选 dri 目录（空格分隔） $2=trust 时只认驱动名（包内兜底层用）
  local d n t i swi=""
  if [ "${2:-}" != trust ]; then
    for d in $1; do
      t=$(readlink -f "$d/swrast_dri.so" 2>/dev/null)   # 必须解引用：符号链接自身 inode 无意义
      [ -n "$t" ] && [ -f "$t" ] && { swi=$(stat -c %i "$t" 2>/dev/null); break; }
    done
  fi
  for d in $1; do
    for n in $GL_NAMES; do
      t=$(readlink -f "$d/${n}_dri.so" 2>/dev/null)
      [ -n "$t" ] && [ -f "$t" ] || continue
      # 兜底层是 mesa 24 的 megadrivers 形态：panfrost/swrast/kms_swrast 三个名字本来就
      # 是同一个 libgallium-<版本>.so 的链接，比 inode 会把自己编出来的兜底判成"没有 GPU
      # 驱动"。这个名字由 Step 10 的 -Dgallium-drivers=panfrost 真编出来（GATE-GL 指名
      # 校验过，缺了直接 die），所以这里认名字就是认构建事实。系统目录仍要防发行版的
      # 硬链接别名（openEuler 把 swrast 链成 rockchip_dri.so 那类），保持原判定。
      [ "${2:-}" = trust ] && { GL_HIT=$n; return 0; }
      i=$(stat -c %i "$t" 2>/dev/null)
      { [ -z "$i" ] || [ "$i" != "$swi" ]; } && { GL_HIT=$n; return 0; }
    done
  done
  return 1
}
GL_GPU=no; GL_DRIVER=none; GL_SRC=none; GL_WHY=""
if [ "$GBM" = yes ] && dri_has_gpu_driver "$SYS_DRIDIR"; then
  GL_SRC=system; GL_GPU=yes; GL_DRIVER=$GL_HIT
elif [ "$GLFALL" = yes ] && dri_has_gpu_driver "$GLFALL_DIR/lib/dri" trust; then
  GL_SRC=bundle; GL_GPU=yes; GL_DRIVER=$GL_HIT; GBM=yes   # 下游按"有 GBM"处理，出处由 GL_SRC 说明
  GL_LIBDIR="$GLFALL_DIR/lib"
  GL_DRIDIR="$GLFALL_DIR/lib/dri"
  GL_VKICD=$(ls "$GLFALL_DIR"/share/vulkan/icd.d/*.json 2>/dev/null | awk 'NR==1')
elif [ "$GBM" = yes ]; then
  GL_WHY="系统有 libgbm/libEGL 但 dri 目录里没有能用的 GPU 驱动（只有 swrast 软渲染，openEuler 裸 mesa 不带 panfrost_dri.so）"
  [ "$GLFALL" = yes ] && GL_WHY="$GL_WHY，包内兜底层也没带匹配的驱动"
else
  GL_WHY="系统无 GBM/mesa 用户态，包内 GL 兜底层也不可用"
fi
# EGL/GBM 真能建起渲染上下文才允许走 tty 直出的 gpu 后端：无 GBM backend 时 DRI 驱动也不算数
# （openeuler 裸 image 实测：内核 renderD130 已绑 panfrost，但 /usr/lib64/gbm 与 dri 目录
#   整个不存在——只看内核绑定会误判成有 GL，必须再要求用户态齐备。齐备的判据是 GL_GPU=yes：
#   系统 mesa 或包内兜底层的 dri 目录里有能用、且不是 swrast 别名的 GPU 驱动）
if [ "$GPU" = yes ] && [ "$GL_GPU" != yes ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  GPU_WHY="内核已绑 $GPU_DRV 但${GL_WHY:-GL 用户态不可用}，无桌面时 GPU 后端不可用"
  GPU=no
fi
[ -n "$GPU_WHY" ] || if [ "$GPU" = yes ]; then GPU_WHY="render 节点 $GPU_NODE 绑定 $GPU_DRV，GL 出处=$GL_SRC(驱动 $GL_DRIVER)"; else GPU_WHY="未发现 GPU 渲染驱动"; fi

# ---------- Mali 代际：决定开源 Vulkan（PanVK）在这颗 GPU 上到底存不存在 ----------
# 这不是可选项：mesa 会照样把 panvk 的 ICD json 装进 /usr/share/vulkan/icd.d，
# 但 PanVK 只覆盖 Valhall 及以后。Bifrost（G31/G51/G52/G71/G72/G76 —— RK3528/3566/
# 3568/3576 全是 G52/G31）与 Midgard（T 系 —— RK3288/3399）拿到的是"有 ICD、无设备"，
# mpv 传 displayvk 直接 fatal。所以代际判不出来时一律按"不能用 Vulkan"处理。
DT_BASE=""
for base in /proc/device-tree /sys/firmware/devicetree/base; do
  [ -d "$base" ] && { DT_BASE=$base; break; }
done
GPU_MODEL=""; GPU_ARCH=""; GPU_SOC=""
if [ -n "$DT_BASE" ]; then
  DT_GPU=$(grep -arhoE 'arm,(mali-[0-9a-z][0-9a-z-]*|midgard-gpu|bifrost-gpu|valhall-gpu|panthor)' \
             "$DT_BASE" 2>/dev/null | sort -u)
  GPU_MODEL=$(printf '%s\n' "$DT_GPU" | awk -F'arm,mali-' 'NF==2{print $2; exit}')
  GPU_ARCH=$(printf '%s\n' "$DT_GPU" | awk '{
      if ($0 ~ /valhall|panthor/) a="valhall";
      else if ($0 ~ /bifrost/) a="bifrost";
      else if ($0 ~ /midgard/) a="midgard" } END{print a}')
  # 板上实测（RK3576 + rk35xx vendor 内核）：GPU 节点的 compatible 只有 arm,mali-bifrost，
  # 没有 gXX 型号名。这种写法里"型号"位置装的是代际，所以把它挪进 GPU_ARCH、型号留空，
  # 免得日志打出 GPU=arm,mali-bifrost 这种看起来像型号的东西。
  case "$GPU_MODEL" in
    bifrost|valhall|midgard) GPU_ARCH=$GPU_MODEL; GPU_MODEL="" ;;
  esac
  # 顶层 compatible 的 rockchip,rkXXXX 是唯一能确定报出来的"机型"，用它补位
  GPU_SOC=$(tr '\0' '\n' < "$DT_BASE/compatible" 2>/dev/null | grep -oE '[a-z]+,rk[0-9]+' | head -1)
  # DT 只给了 arm,mali-gXX（panfrost 绑定的常见写法）时按型号名补出代际。
  # 顺序要紧：g310 会被 g31* 抢先匹中，所以 Valhall 的模式必须在 Bifrost 之前。
  # 认不出的一律留空（VK_CAP 停在 unknown → 不用 Vulkan），不做乐观猜测。
  if [ -z "$GPU_ARCH" ]; then
    case "$GPU_MODEL" in
      g57*|g68*|g77*|g78*|g[0-9]1[0-9]*)  GPU_ARCH=valhall ;;
      g31*|g51*|g52*|g71*|g72*|g76*)      GPU_ARCH=bifrost ;;
      t[0-9]*)                            GPU_ARCH=midgard ;;
    esac
  fi
fi
# 给人看的 GPU 标签：型号优先，型号没有（vendor DTS 只写代际）就用 SoC，都不认识才留未知
GPU_TAG="${GPU_MODEL:-${GPU_SOC:-未知}}/${GPU_ARCH:-代际未知}"
VK_CAP=unknown                              # yes|no|unknown：PanVK 是否覆盖本 GPU# 代际是主判据；panthor 驱动名只是补充证据（它只管 Valhall 之后的架构）。
# 认不出代际 → 停在 unknown，下游按"不能用 Vulkan"处理。
case "$GPU_DRV" in
  panthor) VK_CAP=yes ;;
  *) case "$GPU_ARCH" in
       valhall)          VK_CAP=yes ;;
       bifrost|midgard)  VK_CAP=no  ;;
     esac ;;
esac

# ---------- 已装 mpv 的能力面（跨版本必须实测，不能按文档假设）----------
# 实测：mpv 0.41 的 --gpu-context=help 只有 auto/wayland*/x11*/displayvk，
#   【没有 drm】——传 --gpu-context=drm 会 "Option gpu-context: 'drm' isn't supported"
#   直接致命退出。但这不等于 tty 上的 GPU 直出只剩 displayvk：gpu-context 只约束
#   vo=gpu/gpu-next，而 vo=drm 自带 GBM/EGL 上下文（只需 GLES），在 Bifrost 这类
#   没有 PanVK 的板子上就是唯一的 GPU 直出路径。所以 tty 档位的优先级是
#   vo=drm(GLES，普遍可用) > gpu-next+displayvk(Vulkan，仅 Valhall+ 且 mpv 编了它)。
# 实测：无 GPU 的机器上 gpu-next 会落到 llvmpipe，4K 反而比 vo=drm 慢 3 倍，
#   所以 GPU 与能力两项都要为 yes 才允许 gpu 后端。
MPV_BIN=${MPV_BIN:-}
if [ -z "$MPV_BIN" ]; then
  for c in mpv /usr/local/bin/mpv /usr/bin/mpv; do
    p=$(command -v "$c" 2>/dev/null)
    [ -n "$p" ] && [ -x "$p" ] && { MPV_BIN=$p; break; }
  done
fi
GPU_CTX=""; MPV_VO=""
# 兜底层启用时，mpv 在裸机上才加载得动（系统没有 libdrm/libEGL 时连 --help 都会失败）
mpvq() {
  if [ -n "$GL_LIBDIR" ]; then
    LD_LIBRARY_PATH="$GL_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$MPV_BIN" "$@" 2>/dev/null
  else
    "$MPV_BIN" "$@" 2>/dev/null
  fi
}
[ -n "$MPV_BIN" ] && { GPU_CTX=$(mpvq --gpu-context=help | tr '\n' ' ')
                       MPV_VO=$(mpvq --vo=help | tr '\n' ' '); }
hasw() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
CTX_DSVK=no; hasw displayvk "$GPU_CTX" && CTX_DSVK=yes    # gpu-next 的 tty Vulkan 直出（仅 Valhall+）
# 编译面支持还不够：displayvk 运行时要能用上的 Vulkan ICD（mesa 的 panfrost/panthor 是 panvk）。
# 系统目录没有、但包内兜底层带了一份时也算数——那时由 mpv-auto 用 VK_ICD_FILENAMES 指过去。
VK_ICD=no
[ -n "$GL_VKICD" ] && VK_ICD=yes
# 用户级 ICD 目录要 ${HOME:+…} 而不是 "$HOME/…"：systemd 服务环境里没有 HOME，
# 脚本是 set -u，裸 $HOME 会当场 "HOME: unbound variable" 让探针整段死掉
# （开机服务 rk-hwaccel-tune.service 实测就是这么失败的）
for d in /usr/share/vulkan/icd.d /etc/vulkan/icd.d ${HOME:+"$HOME/.local/share/vulkan/icd.d"}; do
  ls "$d"/*.json >/dev/null 2>&1 && { VK_ICD=yes; break; }
done
# ICD 文件在 ≠ 起得来设备：PanVK 只覆盖 Valhall 及以后，Bifrost（G52/G31）装了 json
# 也枚举不出物理设备，mpv 传 displayvk 即 fatal。所以代际判定（VK_CAP）是硬闸，
# 认不出代际时宁可放弃 Vulkan 走 vo=drm 的 GLES 路径。
# 另一道硬闸是 loader：ICD json 只是注册表，真正的入口 libvulkan.so.1 属 vulkan-loader
# 项目、不在 mesa 里——裸机兜底层不带它时 Vulkan 一样不可用。
VK_LD=no
ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so\.1' && VK_LD=yes
[ -e "${GL_LIBDIR:-/nonexistent}/libvulkan.so.1" ] && VK_LD=yes
VK_OK=no; VK_WHY="无可用 Vulkan：ICD 未安装"
if [ "$VK_ICD" = yes ]; then
  [ "$VK_LD" = no ] && VK_WHY="有 ICD 但缺 libvulkan.so.1（Vulkan loader）→ 不走 displayvk"
  [ "$VK_LD" = yes ] && { [ "$VK_CAP" = yes ] && { VK_OK=yes; VK_WHY=""; } \
      || VK_WHY="有 ICD 但 GPU=$GPU_TAG，PanVK 覆盖情况=$VK_CAP → 不走 displayvk"; }
fi
CTX_WL=no;   hasw wayland "$GPU_CTX" && CTX_WL=yes        # Wayland 桌面
CTX_X11=no;  hasw x11egl "$GPU_CTX" && CTX_X11=yes        # X11 桌面
VO_GN=no;    hasw gpu-next "$MPV_VO" && VO_GN=yes         # libplacebo 新 VO
VO_DRM=no;   hasw drm "$MPV_VO" && VO_DRM=yes             # tty 直出（有 GBM 时自带 EGL/GLES）
VO_WLSHM=no; hasw wlshm "$MPV_VO" && VO_WLSHM=yes
VO_XV=no;    hasw xv "$MPV_VO" && VO_XV=yes
# 硬解能力：RK3576 无 AV1 硬件解码器（板上实测：ffmpeg 报 "platform doesn't support
# hardware accelerated AV1 decoding"，mpv 静默回落 dav1d 软解，4K60 只能跑到 0.4~0.9x）。
# 开机路径不起解码器（要几秒且需要片源），这里只标 unknown 交给 VERIFY.txt 说明。
AV1_HW=unknown

# ---------- 会话与桌面环境 ----------
SESSION=tty
[ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/run/user/0}/${WAYLAND_DISPLAY:-}" ] && SESSION=wayland
if [ "$SESSION" = tty ] && [ -n "${DISPLAY:-}" ]; then SESSION=x11; fi
# SSH/无图形变量时，退而看 seat0 上活动的登录会话（装机与开机调优都走这条路：
# 开机时 systemd 服务里没有 DISPLAY/WAYLAND_DISPLAY，必须从 logind 读控制台会话）
CONSOLE_SESSION=tty; CONSOLE_DE=none; CONSOLE_TYPE=""
sid=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4=="seat0"{print $1; exit}')
if [ -n "${sid:-}" ]; then
  CONSOLE_TYPE=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
  CONSOLE_DE=$(loginctl show-session "$sid" -p Desktop --value 2>/dev/null)
  case "$CONSOLE_TYPE" in x11) CONSOLE_SESSION=x11 ;; wayland) CONSOLE_SESSION=wayland ;; esac
fi
[ -n "${CONSOLE_DE:-}" ] || CONSOLE_DE=none
# 无 logind（例如没装 seatd/systemd 的极简镜像）时，用进程名兜底。
# 只读 /proc/*/comm，不用 pgrep -f：pgrep -f 会匹配到本探针自己的命令行
# （awk 的程序文本里含 gnome-shell 等关键字），裸 openEuler 上实测误报 DE=GNOME。
# comm 是 15 字符截断的进程名，故 cinnamon 用前缀匹配。
COMMS=$(cat /proc/[0-9]*/comm 2>/dev/null)
de_of() { printf '%s\n' "$COMMS" | awk -v n="$1" '$1==n{f=1} END{exit !f}' && echo yes || echo no; }
if [ "$CONSOLE_DE" = none ] || [ "$CONSOLE_SESSION" = tty ]; then
  PROBE_DE=$(printf '%s\n' "$COMMS" | awk '{
      if ($1=="gnome-shell") print "GNOME";
      else if ($1=="xfce4-session") print "Xfce";
      else if ($1=="plasmashell") print "KDE";
      else if ($1=="mate-session") print "MATE";
      else if ($1 ~ /^cinnamon-sessio/) print "X-Cinnamon";
      else if ($1=="lxqt-session") print "LXQt";
      else if ($1=="lxsession") print "LXDE";
    }' | awk 'NR==1')
  [ "$CONSOLE_DE" = none ] && [ -n "${PROBE_DE:-}" ] && CONSOLE_DE=$PROBE_DE
  if [ "$CONSOLE_SESSION" = tty ] && [ -n "${PROBE_DE:-}" ]; then
    [ "$(de_of Xorg)" = yes ] && CONSOLE_SESSION=x11
  fi
  if [ "$CONSOLE_SESSION" = tty ] && [ -n "${PROBE_DE:-}" ]; then
    for w in mutter-x11-wrapp kwin_wayland gnome-shell weston; do
      # GNOME/KDE 的 Wayland 主进程名各异：Xorg 不在而桌面在，按 Wayland 处理
      [ "$(de_of $w)" = yes ] && { CONSOLE_SESSION=wayland; break; }
    done
    [ "$(de_of Xorg)" = yes ] && CONSOLE_SESSION=x11
  fi
fi
[ "$SESSION" = tty ] && [ "$CONSOLE_SESSION" != tty ] && SESSION="$CONSOLE_SESSION"
# 当前有图形变量时以自己的为准，否则用 seat0 上活动会话的桌面名
DE="${XDG_CURRENT_DESKTOP:-$CONSOLE_DE}"
[ -n "$DE" ] || DE=none
DM=none
for u in gdm sddm lightdm lxdm ly lxdm; do
  systemctl is-enabled "$u" >/dev/null 2>&1 && { DM=$u; break; }
done
[ "$DM" = none ] && systemctl is-active graphical.target >/dev/null 2>&1 && DM="active(未识别管理器)"

# ---------- Xv（X Video Overlay）可用性：X11 无 GPU 时的关键分叉 ----------
XV=unknown
if [ "$SESSION" = x11 ] && [ -n "${DISPLAY:-}" ]; then
  if command -v xdpyinfo >/dev/null 2>&1; then
    xdpyinfo -display "$DISPLAY" 2>/dev/null | grep -qiE 'XVideo|X-Video' && XV=yes || XV=no
  fi
fi

# ---------- 当前接的显示器：决定 DRM 直出的输出模式与缩放预算 ----------
# /sys/class/drm/<cardN>-<接口>/status 为 connected 时，modes 首行即 EDID 首选模式。
# 换显示器会重算（udev 触发 tune），所以这里必须是"实时读"而不是装机时的快照。
SCREEN_CONN=none; SCREEN_W=0; SCREEN_H=0; SCREEN_MAX_W=0; SCREEN_NATIVE=""
for c in /sys/class/drm/card*-*/; do
  [ -d "$c" ] || continue
  name=${c%/}; name=${name##*/}
  st=$(cat "$c/status" 2>/dev/null)
  [ "$st" = connected ] || continue
  # 只要带 EDID 输出能力的物理接口（card0 这类纯渲染节点没有 -接口 后缀，已被 glob 排除）
  modes=$(cat "$c/modes" 2>/dev/null)
  [ -n "$modes" ] || continue
  first=$(printf '%s\n' "$modes" | awk 'NR==1')
  w=${first%%x*}; h=${first#*x}; h=${h%%/*}
  case "$w" in ''|*[!0-9]*) continue ;; esac
  [ "$SCREEN_CONN" = none ] && { SCREEN_CONN=$name; SCREEN_NATIVE=$first; SCREEN_W=$w; SCREEN_H=$h; }
  # 多接口时取最大的一块屏作为缩放预算
  if [ "$w" -gt "$SCREEN_MAX_W" ]; then SCREEN_MAX_W=$w; fi
done
SCREEN_4K=no; [ "$SCREEN_MAX_W" -ge 3000 ] && SCREEN_4K=yes
if [ "$SCREEN_MAX_W" -ge 7000 ]; then SCREEN_TIER=8K
elif [ "$SCREEN_MAX_W" -ge 3000 ]; then SCREEN_TIER=4K
elif [ "$SCREEN_MAX_W" -ge 2000 ]; then SCREEN_TIER=2K
elif [ "$SCREEN_MAX_W" -ge 1200 ]; then SCREEN_TIER=1080p
else SCREEN_TIER=unknown; fi

# ---------- 档位决策：把探测结果收敛成一个可直接用的 profile 名 ----------
# tty 直出按可用性分三档：
#   rk-drm-gpu  vo=gpu-next + displayvk：要 mpv 真编了 Vulkan（PLACEBO_VULKAN=1）、
#               有 ICD，且 GPU 是 Valhall 及以后（RK3588 的 G610）三者齐备
#   rk-drm-gl   vo=drm 的 GBM/EGL(GLES) 档：要 GPU + GL_GPU=yes（dri 目录里有真 GPU 驱动，
#               不是 swrast 别名）——RK3528/3566/3568/3576 这些 Bifrost（G31/G52）没有 PanVK，
#               tty 的 GPU 直出只有这一条
#   rk-drm      没有可用的 GL 用户态：vo=drm 只能 CPU 拷帧送显
#               （"看得见 libgbm 但没有 Mali DRI"也算这里，否则 kms_swrast 会更慢还更像 GPU）
# 板上实测：mpv 0.41 的 --gpu-context 没有 drm，硬写是致命解析错误，所以 GLES 档
# 用 vo=drm（它自带 EGL/GBM 上下文）而不是 gpu-next。
PROFILE=rk-drm          # 默认：无桌面、无 GL 的 DRM 直出
if [ "$GPU" = yes ] && [ "$GBM" = yes ]; then
  case "$SESSION" in
    x11)     PROFILE=rk-x11-gpu ;;
    wayland) PROFILE=rk-wayland-gpu ;;
    *)       PROFILE=rk-drm-gl
             [ "$CTX_DSVK" = yes ] && [ "$VK_OK" = yes ] && PROFILE=rk-drm-gpu ;;
  esac
else
  case "$SESSION" in
    x11)     PROFILE=rk-x11-sw ;;
    wayland) PROFILE=rk-wayland-sw ;;
  esac
fi

# ---------- RGA 滤镜能力探针（RGA_FILTER）----------
# 有 /dev/rga、ffmpeg 也列出 rkrga 滤镜，都不等于 mpv 能用上它。
# RK3576 vendor 6.1 + 本包 mesa/mpv 实测：--vf=scale_rkrga=… 在 mpv 的滤镜图里 100%
# 建立失败（"Impossible to convert between the formats supported by the filter
# 'mpv_src_default_in' and the filter 'auto_scale_0'" → "Disabling filter
# scale_rkrga.00"），ffmpeg CLI 直接喂 nv12/nv15 同样接不上；结果就是参数发出去了、
# 实际静默退回 CPU 的 swscale——日志看着像走了 RGA，比不发更糟。所以这里真跑 3 帧判定，
# 结论缓存一天（探针要起 mpv，不能每次播放都跑）。
# 手工覆盖：RK_RGA_FILTER=yes|no|auto（auto=按探针；测试与排障用）
RGA_FILTER=unknown; RGA_FILTER_WHY=""
rga_filter_probe() {
  local cache="" d out ff mp tmpf
  case "${RK_RGA_FILTER:-auto}" in
    yes) RGA_FILTER=yes; RGA_FILTER_WHY="手工指定 RK_RGA_FILTER=yes"; return 0 ;;
    no)  RGA_FILTER=no;  RGA_FILTER_WHY="手工指定 RK_RGA_FILTER=no";  return 0 ;;
  esac
  [ "$RGA_NODE" = yes ] || { RGA_FILTER=no; RGA_FILTER_WHY="无 /dev/rga"; return 0; }
  for d in /run/lock /var/tmp /tmp; do [ -w "$d" ] && { cache="$d/rk-hwaccel-rga-filter"; break; }; done
  if [ -n "$cache" ] && [ -r "$cache" ]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    [ "$age" -ge 0 ] && [ "$age" -lt 86400 ] && {
      RGA_FILTER=$(cat "$cache" 2>/dev/null); RGA_FILTER_WHY="缓存(${age}s 前)"
      case "$RGA_FILTER" in yes|no) return 0 ;; esac
    }
  fi
  mp=${MPV_BIN:-mpv}; ff=${MPV_BIN%mpv}/ffmpeg; [ -x "$ff" ] || ff=ffmpeg
  command -v "$mp" >/dev/null 2>&1 || command -v "$ff" >/dev/null 2>&1 || {
    RGA_FILTER=unknown; RGA_FILTER_WHY="找不到 mpv/ffmpeg"; return 0; }
  # 32x32、半秒的探针片：只关心滤镜图能不能连上，画质与编解码器都无所谓
  tmpf=$(mktemp "${TMPDIR:-/tmp}/rkrga-probe.XXXXXX.mp4") || {
    RGA_FILTER=unknown; RGA_FILTER_WHY="建不了临时文件"; return 0; }
  if ! "$ff" -v error -y -f lavfi -i "color=c=gray:s=32x32:r=10:d=0.5" \
        -c:v libx264 -pix_fmt yuv420p -an "$tmpf" 2>/dev/null; then
    "$ff" -v error -y -f lavfi -i "color=c=gray:s=32x32:r=10:d=0.5" \
        -c:v mpeg4 -q:v 8 -an "$tmpf" 2>/dev/null || {
      rm -f "$tmpf"; RGA_FILTER=unknown; RGA_FILTER_WHY="探针片生成失败（无可用编码器）"; return 0; }
  fi
  # --vo=null/--ao=null：不碰 DRM master，开机或别人正在播放都能探
  out=$(LD_LIBRARY_PATH="${GL_LIBDIR:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        timeout 15 "$mp" --no-config --really-quiet --vo=null --ao=null \
        --hwdec=rkmpp-copy --frames=3 --msg-level=vf=v \
        --vf=scale_rkrga=force_yuv=8bit "$tmpf" 2>&1)
  rm -f "$tmpf"
  if grep -q 'Disabling filter scale_rkrga' <<<"$out"; then
    RGA_FILTER=no;  RGA_FILTER_WHY="scale_rkrga 滤镜图建立失败，mpv 会静默退回 CPU 缩放"
  elif grep -q 'scale_rkrga' <<<"$out"; then
    RGA_FILTER=yes; RGA_FILTER_WHY="滤镜图建立成功"
  else
    RGA_FILTER=unknown; RGA_FILTER_WHY="探针无结论（可能缺 rkmpp 解码器）"
  fi
  [ -n "$cache" ] && printf '%s\n' "$RGA_FILTER" > "$cache" 2>/dev/null
  return 0
}
rga_filter_probe

# ---------- 输出：KEY="VALUE"，可直接 . / eval 载入 ----------
[ "${1:-}" = "--quiet" ] && exit 0
for k in DISTRO_NAME DISTRO_ID DISTRO_VER DISTRO_CODENAME FAMILY PKG \
         KERNEL KERNEL_VENDOR CHIP MPP_NODE RGA_NODE RGA_FILTER RGA_FILTER_WHY LIBDIRS \
         SESSION DE DM XV GPU GPU_DRV GPU_NODE GPU_WHY GBM MPV_BIN \
         GPU_MODEL GPU_ARCH GPU_SOC GPU_TAG VK_CAP VK_OK VK_LD VK_WHY \
         GL_SRC GLFALL GLFALL_DIR GL_LIBDIR GL_DRIDIR GL_VKICD GL_GPU GL_DRIVER GL_WHY \
         CTX_DSVK CTX_WL CTX_X11 VK_ICD VO_GN VO_DRM VO_WLSHM VO_XV AV1_HW \
         SCREEN_CONN SCREEN_NATIVE SCREEN_MAX_W SCREEN_4K SCREEN_TIER PROFILE; do
  v=$(eval "printf '%s' \"\${$k:-}\""); v=${v//\"/}
  printf '%s="%s"\n' "$k" "$v"
done
exit 0
ENV_EOF
}

#============== 目标机脚本：安装器（环境自适应 + 自动补权限 + 按环境写档位）====
install_script() { cat <<'EOF'
#!/usr/bin/env bash
# install.sh —— RK35xx 硬解栈装机（openEuler 24.03 / deepin 25 / Debian trixie
#              / Ubuntu noble、resolute，均需 rk35xx vendor 内核）
# 用法：sudo bash install.sh [用户名 ...]
#       不带用户名时自动为所有非 root 可登录用户补组（见 STEP 3）
# 全程幂等：重复执行只是重新探测并覆盖档位配置，不会叠加内容。
set -euo pipefail
cd "$(dirname "$0")"

step()  { printf '\033[1;36m[安装]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[提示]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[终止]\033[0m %s\n' "$*" >&2; exit 1; }

step "1/5 前置检查"
[ "$(id -u)" = 0 ] || fail "请用 root 运行：sudo bash install.sh [用户名 ...]"
ls /dev/mpp_service >/dev/null 2>&1 \
  || fail "无 /dev/mpp_service：本机不是 rk35xx vendor 内核，本包不适用（mainline 请走 V4L2 Request 线）"
glibc=$(ldd --version | awk 'NR==1{print $NF}' | grep -oE '[0-9]+\.[0-9]+' | awk 'NR==1')
[ -n "$glibc" ] || glibc=0
awk -v v="$glibc" 'BEGIN{exit !(v+0 >= 2.38)}' \
  || fail "glibc $glibc < 2.38（构建基线）；请在 openEuler 24.03 上重构建或换更新的系统"

# 解包目录里有多个 tar 时 glob 会展开成多参数（第二个被 tar 当成员名报错）；取最新一个。
# 另注意：本脚本在 set -o pipefail 下运行，禁止对大输出源用 head（必触发 SIGPIPE 141）。
TARBALL=$(ls -t rk-hwaccel-local-*.tar.gz 2>/dev/null | awk 'NR==1')
[ -n "$TARBALL" ] || fail "当前目录找不到 rk-hwaccel-local-*.tar.gz（与本脚本放同一目录）"

step "2/5 解包到 / （/usr/local 自闭环，不动系统 ffmpeg）"
# openEuler 24.03 SP4 最小镜像连 tar 都没有（板上实测），有 python3 就用它解同一份 tar.gz
if command -v tar >/dev/null 2>&1; then
  tar --numeric-owner -xzf "$TARBALL" -C / usr
elif command -v python3 >/dev/null 2>&1; then
  warn "本机无 tar，改用 python3 解包"
  python3 - "$TARBALL" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    t.extractall("/", members=[m for m in t.getmembers() if m.name.startswith("usr/")])
PY
else
  fail "本机既无 tar 也无 python3，无法解包；先装 tar（openEuler：dnf install -y tar）再重跑"
fi
[ -x /usr/local/bin/rk-hwaccel-env ] || fail "解包后未找到 /usr/local/bin/rk-hwaccel-env"

# 系统级依赖预检：本包只带自研库（mpp/rga/dav1d/placebo）与一层 GL 兜底，其余用系统的。
# 裸 openEuler 板上实测 mpv 缺 6 个系统库直接起不来（error while loading shared
# libraries），与其让它运行时崩，不如现在点名要装什么。
# 两次 ldd 的差集就是"兜底层能不能救回来"：
#   带兜底仍缺 → 真的没救，报错并列安装命令；只在不带兜底时缺 → 由 mpv-auto 自动启用兜底层。
# LD_LIBRARY_PATH 里必须先给 /usr/local/lib{,64}：此刻 ld.so.conf.d 还没写（那是 tune 的活），
# 不给就会把自家 libplacebo/libdav1d/librockchip_mpp 误报成系统缺库。
GLF=/usr/local/share/rk-hwaccel/glfallback/lib
BASE_LD="/usr/local/lib:/usr/local/lib64"
MISS_SYS=$(LD_LIBRARY_PATH="$BASE_LD" ldd /usr/local/bin/mpv 2>/dev/null | awk '/not found/{print $1}' | sort -u)
MISS=$(LD_LIBRARY_PATH="$BASE_LD:$GLF" ldd /usr/local/bin/mpv 2>/dev/null | awk '/not found/{print $1}' | sort -u)
OSID=$(. /etc/os-release 2>/dev/null && echo "${ID:-}")
case "$OSID" in
  ubuntu|debian|deepin|raspbian) PM="apt-get install -y"
    pkg() { case "$1" in
      libdrm.so.2) echo libdrm2 ;; libgbm.so.1) echo libgbm1 ;; libEGL.so.1) echo libegl1 ;;
      libGL.so.1) echo libgl1 ;; libasound.so.2) echo libasound2 ;;
      *) echo "lib${1%%.so*}" ;; esac; } ;;
  *) PM="dnf install -y"
    pkg() { case "$1" in
      libdrm.so.2) echo libdrm ;; libgbm.so.1) echo mesa-libgbm ;; libEGL.so.1) echo mesa-libEGL ;;
      libGL.so.1) echo mesa-libGL ;; libasound.so.2) echo alsa-lib ;; libXss.so.1) echo libXScrnSaver ;;
      # SONAME 与包名不同名的坑（板上实测：照 ${1%%.so*} 拼出来的 libmp3lame/libmpg123
      # 在 openEuler 上根本不存在）；认不出的用 dnf whatprovides '*/<soname>' 查
      libmp3lame.so.0) echo lame ;; libmpg123.so.0) echo mpg123 ;;
      *) echo "${1%%.so*}" ;; esac; } ;;
esac
# 逐行读，不用 for x in $var（IFS 被上游脚本改过时会整串当一个词）
pkg_list() { printf '%s\n' "$1" | while read -r so; do [ -n "$so" ] && printf '%s ' "$(pkg "$so")"; done; }
if [ -z "$MISS" ] && [ -n "$MISS_SYS" ]; then
  warn "系统缺 mpv 的运行库：$(printf '%s ' $MISS_SYS)"
  warn "  本包自带的 GL 兜底层已覆盖这些：mpv-auto 与开机调优会自动挂载，不必装系统包"
  warn "  想用系统版本：$PM $(pkg_list "$MISS_SYS") —— 装完重跑本脚本即自动切回"
elif [ -n "$MISS" ]; then
  fail "本包已解到 /usr/local，但 mpv 仍缺运行库（包内 GL 兜底层也没覆盖到）：$(printf '%s ' $MISS)
      请先装依赖（$OSID）：  $PM $(pkg_list "$MISS")
      装完重跑 sudo bash install.sh —— 全流程幂等，不会装坏。"
fi

step "3/5 登记开机自适应（本机环境每次开机/热插拔都会重新判定）"
mkdir -p /etc/systemd/system
if command -v systemctl >/dev/null 2>&1; then
  for u in rk-hwaccel-tune.service; do
    [ -f "/usr/local/lib/systemd/system/$u" ] || { warn "缺 $u 单元文件，跳过开机调优登记"; continue; }
    systemctl enable "$u" >/dev/null 2>&1 || warn "systemctl enable $u 失败（可手动 ln -s）"
  done
  echo "  已启用 rk-hwaccel-tune.service（开机在 graphical.target 之前调优）"
  if [ -f /usr/local/share/rk-hwaccel/85-rk-hwaccel-hotplug.rules ]; then
    install -m 0644 /usr/local/share/rk-hwaccel/85-rk-hwaccel-hotplug.rules /etc/udev/rules.d/85-rk-hwaccel-hotplug.rules
    udevadm control --reload-rules 2>/dev/null || true
    echo "  已安装 HDMI/DP 热插拔触发规则（插拔后自动重算参数，无需重启）"
  fi
else
  warn "本机无 systemd：跳过开机调优登记，请手动执行 /usr/local/bin/rk-hwaccel-tune"
fi

step "4/5 立即按当前环境调优一次（同样的逻辑此后每次开机自动跑）"
# 权限组、设备节点、ld.so.conf.d、mpv 参数全部由 tune 负责——装机不单独做一套，
# 避免"装机时判对、开机后被自己覆盖"或两处逻辑漂移。
# tune 默认覆盖所有可登录非 root 用户（含命令行指定的这些），无需单独传参。
rk-hwaccel-tune --reason=install || warn "首次调优未完成，稍后手动执行：sudo rk-hwaccel-tune"
ENV_SNAP=/var/lib/rk-hwaccel/env
mkdir -p "$(dirname "$ENV_SNAP")"; /usr/local/bin/rk-hwaccel-env > "$ENV_SNAP" || true
if [ $# -ge 1 ]; then
  for u in "$@"; do
    id "$u" >/dev/null 2>&1 || warn "用户 $u 不存在（拼写？），其余可登录用户已按 uid 自动处理"
  done
  warn "组变更对已登录会话不生效：请注销重登，或临时用 newgrp video"
fi

step "5/5 验证"
# 查询必须和探针一样带上包内 GL 兜底：裸板系统没有 libgbm/libEGL，不带兜底连 mpv --help
# 都加载失败，于是"0 项 rkmpp hwdec / 0 个解码器 / 未解析依赖 9"全是假阴性（板上实测：
# 同一台机器手工带上 $GLF 再查是 10 个解码器、3 个 rkrga 滤镜、20 项 hwdec、ldd 零缺件）。
VLD="/usr/local/lib:/usr/local/lib64"
[ -d "$GLF" ] && VLD="$VLD:$GLF"
mpv_flags() { LD_LIBRARY_PATH="$VLD" /usr/local/bin/mpv --no-config "$@"; }
ff_flags()  { LD_LIBRARY_PATH="$VLD" /usr/local/bin/ffmpeg -hide_banner "$@"; }
# 注意：本段在 set -o pipefail 下执行，一律用 awk 收敛输出，不用 head（避免 SIGPIPE 141）
echo "  发行版      : $(awk -F'"' '/^DISTRO_NAME=/{print $2}' "$ENV_SNAP" 2>/dev/null)"
echo "  内核/芯片   : $(awk -F'"' '/^KERNEL=/{print $2}' "$ENV_SNAP") / $(awk -F'"' '/^CHIP=/{print $2}' "$ENV_SNAP")"
echo "  会话/桌面   : $(awk -F'"' '/^SESSION=/{print $2}' "$ENV_SNAP") / $(awk -F'"' '/^DE=/{print $2}' "$ENV_SNAP")"
echo "  GPU/GBM/Xv  : $(awk -F'"' '/^GPU=/{print $2}' "$ENV_SNAP") / $(awk -F'"' '/^GBM=/{print $2}' "$ENV_SNAP") / $(awk -F'"' '/^XV=/{print $2}' "$ENV_SNAP")"
echo "  显示器      : $(awk -F'"' '/^SCREEN_CONN=/{print $2}' "$ENV_SNAP") $(awk -F'"' '/^SCREEN_NATIVE=/{print $2}' "$ENV_SNAP")"
echo "  ffmpeg      : $(ff_flags -decoders 2>/dev/null | grep -c '_rkmpp') 个 *_rkmpp 解码器, $(ff_flags -filters 2>/dev/null | grep -c rkrga) 个 rkrga 滤镜"
echo "  mpv         : $(mpv_flags --hwdec=help 2>/dev/null | grep -c rkmpp) 项 rkmpp hwdec；ao=$(mpv_flags --ao=help 2>&1 | tr '\n' ' ' | grep -ow alsa | awk 'NR==1')；vo=$(mpv_flags --vo=help 2>/dev/null | tr '\n' ' ' | awk '{for(i=1;i<=NF;i++) if($i=="drm"||$i=="gpu-next"||$i=="wlshm"||$i=="xv") printf "%s ",$i}')"
echo "  GPU 依据    : 渲染节点 $(awk -F'"' '/^GPU_NODE=/{print $2}' "$ENV_SNAP") 驱动 $(awk -F'"' '/^GPU_DRV=/{print $2}' "$ENV_SNAP")（sysfs 绑定，mesa25 的 gallium-loader 让 DRI 文件 inode 判断不可信）"
echo "  mpv 能力面  : $(awk -F'"' '/^VO_DRM=/{printf "tty直出vo=drm=%s ",$2}' "$ENV_SNAP")$(awk -F'"' '/^CTX_DSVK=/{printf "displayvk=%s ",$2}' "$ENV_SNAP")$(awk -F'"' '/^CTX_WL=/{printf "wayland=%s ",$2}' "$ENV_SNAP")$(awk -F'"' '/^VK_CAP=/{printf "PanVK代际=%s ",$2}' "$ENV_SNAP")$(awk -F'"' '/^VO_GN=/{printf "gpu-next=%s",$2}' "$ENV_SNAP")"
echo "  GL 用户态   : $(awk -F'"' '/^GL_SRC=/{print $2}' "$ENV_SNAP") 可用DRI=$(awk -F'"' '/^GL_DRIVER=/{print $2}' "$ENV_SNAP")$(awk -F'"' '/^GL_GPU=/{g=$2} /^GL_WHY=/{if(g=="no"&&$2)printf "（原因：%s）",$2}' "$ENV_SNAP")$(awk -F'"' '/^GL_SRC=/{d=$2} /^GL_LIBDIR=/{if(d=="bundle")printf "，包内兜底：%s",$2}' "$ENV_SNAP")  GPU=$(awk -F'"' '/^GPU_TAG=/{print $2}' "$ENV_SNAP")  档位=$(awk -F'"' '/^PROFILE=/{print $2}' "$ENV_SNAP")"
echo "  未解析依赖  : $(LD_LIBRARY_PATH="$VLD" ldd /usr/local/bin/mpv 2>/dev/null | grep -c 'not found')（已把包内 GL 兜底算进搜索路径）"
# 只读档位段之前的全局段：碰到第一个 [xxx] 就停。早先扫全文件，把"手工覆盖用的档位"
# 菜单里的 vo=gpu-next/hwdec=rkmpp 也算进"生效档位"，看着像同时生效了四五种配置。
echo "  生效档位    : $(awk '/^\[/{exit} /^(vo|hwdec|drm-mode|ao|profile|scale|drm-format)=/{printf "%s ",$0}' /usr/local/etc/mpv/mpv.conf 2>/dev/null)"

cat <<MSG

安装完成。此后每次开机（及插拔显示器）都会按当时的 会话/桌面/GPU/屏幕 自动重算参数，
不需要重装；手动重算：sudo rk-hwaccel-tune    查看探测依据：rk-hwaccel-env
日常直接：
  mpv-auto <片源>      # 再叠加 分辨率×帧率×位深 与当前会话，逐次最优
  mpv <片源>           # 走开机调优生成的默认配置
芯片解码能力（板上实测）：
  RK3576 无 AV1 硬解——AV1 一律回落 dav1d 软解（4K60 约 0.9x，8K 不可用）；AV1 硬解需 RK3588。
  10bit 片在桌面会话里 copy 比 dmabuf 零拷贝快 3 倍（0.58x vs 0.18x），mpv-auto 已按位深分叉。
  桌面合成器持有 DRM master：vo=drm/displayvk 直出只在无桌面（server/掌机/kiosk）时可用。
上游口径的手动档（https://github.com/nyanmisaka/ffmpeg-rockchip/wiki/Rendering#mpv）：
  零拷贝直出(需 GPU) : mpv-auto <片源>          # tty 用 vo=drm(GLES)，桌面用会话上下文；
                                                 # 仅 Valhall+ 且构建时 PLACEBO_VULKAN=1 才用 displayvk
  10bit 无 GPU 直出: MPV_AFBC=1 mpv-auto <片源>   # 让 RGA 把 10bit 转成 KMS 能显示的 8bit；
                                                 # 是否真能走 RGA 由开机探针判定（rk-hwaccel-env 里
                                                 # RGA_FILTER），本机用不上时会明说并退回原路径
硬解负载观察：
  echo 1000 > /proc/mpp_service/load_interval ; watch -n 1 cat /proc/mpp_service/load
MSG
EOF
}

#============== 目标机脚本：智能播放入口 =====================================
mpv_auto() { cat <<'MPV_AUTO_EOF'
#!/usr/bin/env bash
# mpv-auto —— RK35xx 智能硬解播放入口（在开机调优结论之上，按本片再细化一层）
# 决策输入：环境探针(rk-hwaccel-env) 的 会话×GPU×GBM×Xv×显示器 × 片源 分辨率/帧率/位深
# 用法：mpv-auto [任意 mpv 参数] <片源>          用户参数在后，始终覆盖自动决策
# 开关：MPV_AUTO_DEBUG=1 打印决策过程；MPV_HWDEC=rkmpp 走零拷贝 EGL；
#       MPV_NATIVE_4K=1 原生 4K 输出；MPV_FULLFPS=1 不降帧；MPV_AFBC=1 强制 AFBC+RGA
#       长期开关读 /etc/rk-hwaccel-tune.conf（与开机调优同一份，避免两处漂移）
set -u
# mpv 可执行文件的位置以探针为准（非标准 PREFIX 的机器上不是 /usr/local/bin/mpv），
# 环境变量 MPV_BIN 优先，方便仿真与手工指定；两者都没有才回退默认路径
MPV=${MPV_BIN:-}
FFPROBE=${FFPROBE:-/usr/local/bin/ffprobe}
DBG="${MPV_AUTO_DEBUG:-0}"
dlog() { [ "$DBG" = 1 ] && echo "[mpv-auto] $*" >&2; return 0; }

# ---------- 1. 环境（探针缺失时退回内置探测，保证单独可用）----------
RK_ENV=${RK_ENV:-/usr/local/bin/rk-hwaccel-env}
if [ -x "$RK_ENV" ]; then
  # 键必须列全：GL_SRC/GL_LIBDIR 这些不在里面的话，兜底层判定永远读不到，
  # 裸机（系统无 mesa）的 mpv 连加载都失败（v2.3 之前的真实缺陷）
  eval "$("$RK_ENV" 2>/dev/null | grep -E '^(SESSION|GPU|GPU_DRV|GPU_MODEL|GPU_ARCH|GPU_SOC|GPU_TAG|GBM|XV|RGA_NODE|RGA_FILTER|RGA_FILTER_WHY|SCREEN_4K|SCREEN_NATIVE|PROFILE|VO_GN|VO_DRM|CTX_WL|CTX_DSVK|VK_ICD|VK_OK|VK_WHY|GL_SRC|GL_LIBDIR|GL_DRIDIR|GL_VKICD|GL_GPU|GL_DRIVER|GL_WHY|MPV_BIN)=' )" || true
  [ -n "${MPV_BIN:-}" ] && MPV="$MPV_BIN"
fi
[ -n "$MPV" ] && [ -x "$MPV" ] || MPV=/usr/local/bin/mpv
if [ ! -x "$MPV" ]; then
  echo "[mpv-auto] 未找到可执行的 mpv（探针 MPV_BIN=\"${MPV_BIN:-}\"，回退 $MPV 也不存在）——请先跑 install.sh" >&2
  exit 127
fi
# ffprobe 与本包同前缀：默认路径没有就取 mpv 旁边那份（非标准 PREFIX 的机器）
[ -x "$FFPROBE" ] || FFPROBE="$(dirname "$MPV")/ffprobe"
: "${SESSION:=tty}"; : "${GPU:=no}"; : "${GBM:=no}"; : "${XV:=unknown}"
: "${SCREEN_4K:=no}"; : "${RGA_NODE:=unknown}"
[ "$RGA_NODE" = unknown ] && { [ -e /dev/rga ] && RGA_NODE=yes || RGA_NODE=no; }
# 会话以"此刻真实所在"为准（探针在开机时读到的 SSH 会话里没有图形变量）：
# 这里重新判定，避免在桌面终端里跑 mpv-auto 却拿到无桌面的 DRM 结论
if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/run/user/0}/${WAYLAND_DISPLAY}" ]; then
  SESSION=wayland
elif [ -n "${DISPLAY:-}" ]; then
  SESSION=x11
else
  SESSION=tty
fi
dlog "环境: SESSION=$SESSION GPU=$GPU/${GPU_DRV:-none}(${GPU_TAG:-代际未知}) GBM=$GBM GL=${GL_SRC:-none}/驱动=${GL_DRIVER:-none} Xv=$XV 屏4K=$SCREEN_4K RGA=节点${RGA_NODE:-?}/滤镜${RGA_FILTER:-?} 档位=${PROFILE:-未探测}"
[ "${GL_GPU:-yes}" = no ] && [ -n "${GL_WHY:-}" ] && dlog "  GL 不可用原因：$GL_WHY"

# 开机调优的长期开关在这里同样生效，避免"mpv.conf 被 tune 设成 1080p、mpv-auto 却各自为政"
FORCE_1080P=1
[ -r /etc/rk-hwaccel-tune.conf ] && . /etc/rk-hwaccel-tune.conf

# ---------- 2. 片源属性（分辨率/帧率/位深一次 ffprobe 取齐）----------
SRC=""
for a in "$@"; do
  case "$a" in -*) continue ;; *) [ -f "$a" ] && { SRC="$a"; break; } ;; esac
done
W=0; H=0; SRCFPS=0; PIXFMT=""; RATE=""; CODEC=""
if [ -n "$SRC" ] && [ -x "$FFPROBE" ]; then
  # 必须按字段名取值：-nk=1 的裸值顺序由 ffprobe 内部结构决定（板上实测把
  # r_frame_rate 读成 pix_fmt，导致 60fps 片被判成低帧率、档位选错）
  KV=$($FFPROBE -v error -select_streams v:0 \
        -show_entries stream=width,height,r_frame_rate,avg_frame_rate,pix_fmt,codec_name \
        -of default=nw=1 "$SRC" 2>/dev/null)
  gval() { printf '%s\n' "$KV" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }
  W=$(gval width); H=$(gval height); PIXFMT=$(gval pix_fmt); CODEC=$(gval codec_name)
  RATE=$(gval r_frame_rate)
  case "${RATE:-0/0}" in 0/0|'') RATE=$(gval avg_frame_rate) ;; esac
fi
case "${W:-}" in ''|*[!0-9]*) W=0; H=0 ;; esac
if [ "$W" -ge 7000 ]; then TIER=8K        # 超 RK3576/3588 硬解上限，只能软解，必然不满速
elif [ "$W" -ge 3400 ]; then TIER=4K
elif [ "$W" -ge 2000 ]; then TIER=2K
elif [ "$W" -ge 1200 ]; then TIER=1080p
else TIER=sd; fi
RN=${RATE%%/*}
# 分母只在真的写了 "30/1" 时才有意义：没有斜杠时 ${RATE##*/} 会把分子自己当分母，
# 60fps 片算成 1000m/1000fps → 判成低帧率、档位选错
case "$RATE" in */*) RD=${RATE##*/} ;; *) RD=1 ;; esac
case "${RN:-}" in ''|*[!0-9]*) RN=0 ;; esac
case "${RD:-}" in ''|*[!0-9]*) RD=1 ;; esac
[ "${RD:-0}" -gt 0 ] 2>/dev/null && SRCFPS=$((RN*1000/RD))
HIGHFPS=no; [ "$SRCFPS" -ge 50000 ] && HIGHFPS=yes
# 10bit：rkmpp 解 10bit 出 p010（HEVC/VP9 的 10bit 半平面）与 nv15/nv20（AFBC 压缩帧），
# 片源本身可能是 yuv420p10le 之类。注意 p010 里【没有】"p10" 这个子串，
# 只写 *p10* 会把 rkmpp 的 10bit 输出整类漏掉（仿真实测踩到）。
IS10=no
case "${PIXFMT:-}" in p010|p012|nv15|nv20|*p10*|*10le*|*10be*|*12le*|*12be*) IS10=yes ;; esac
dlog "片源: ${SRC:-未识别} ${W}x${H} ${SRCFPS}m/1000fps ${PIXFMT:-?} → $TIER 高帧率=$HIGHFPS 10bit=$IS10"

# ---------- 3. 决策 ----------
HW="${MPV_HWDEC:-rkmpp-copy}"   # copy 模式兼容性最好；GPU 就绪可 rkmpp 零拷贝
VO_ARGS=""; VFS=""; ZC_TRIAL=no   # ZC_TRIAL：tty 上"先试零拷贝、失败退回 copy"
# gpu-next 需 libplacebo；探针若发现本 mpv 没编进去，退回老 vo=gpu（板间版本差异）
VON=gpu; [ "${VO_GN:-no}" = yes ] && VON=gpu-next
# mpv 的 --vf 是"整表覆盖"语义（追加要用 --vf-append），所以滤镜一律攒成一条 --vf=a,b
add_vf() { [ -n "$VFS" ] && VFS="$VFS,$1" || VFS="$1"; }
case "$SESSION" in
  tty)
    # 两条 tty 直出共用的部分：4K 屏 + yuyv 每帧 16MB 会压垮 RK3576 的 VOP，默认把输出
    # 降到 1080p 交给 plane 硬件缩放保流畅（屏本身 1080p 时不必传）；高帧率片降 30fps。
    DRM_MODE=""
    if [ "$SCREEN_4K" = yes ] && [ "$FORCE_1080P" = 1 ] && [ "${MPV_NATIVE_4K:-0}" != 1 ]; then
      DRM_MODE=" --drm-mode=1920x1080"
      dlog "4K 屏→1080p 输出（带宽降 4 倍保流畅；MPV_NATIVE_4K=1 看原生 4K）"
    fi
    if [ "$HIGHFPS" = yes ] && [ "${MPV_FULLFPS:-0}" != 1 ]; then
      add_vf fps=30; dlog "高帧率→降帧30fps（MPV_FULLFPS=1 关闭）"
    fi
    if [ "${PROFILE:-}" = rk-drm-gpu ]; then
      # 探针已确认：mpv 编了 displayvk + 有 Vulkan ICD + GPU 是 Valhall 及以后
      VO_ARGS="--vo=$VON --gpu-context=displayvk$DRM_MODE"
      [ -z "${MPV_HWDEC:-}" ] && HW=rkmpp
      dlog "tty+${GPU_TAG:-GPU}：$VON/displayvk Vulkan 直出，零拷贝"
    elif [ "${PROFILE:-}" = rk-drm-gl ] && [ "${VO_DRM:-no}" = yes ]; then
      # Bifrost（G52/G31 —— RK3528/3566/3568/3576）与 Midgard 上没有 PanVK，
      # tty 的 GPU 直出只有 vo=drm：它自带 EGL/GBM 上下文，缩放合成都在 GPU 上做，
      # 不需要也不能传 --gpu-context（0.41 的 gpu-context 里根本没有 drm，传了致命退出）。
      # 零拷贝（rkmpp→drm_prime→GBM）在 tty 上没有实测数字，所以"先试、几秒内非零退出
      # 就退回 copy 重放"，而不是把一个没验证过的档位直接写进开机配置。
      VO_ARGS="--vo=drm$DRM_MODE"
      # 10bit 例外：桌面实测零拷贝比 copy 慢 3 倍（mesa 对 nv15/nv20 的 modifier 支持不全，
      # 导入即退化成逐帧 CPU 转换），tty 没有理由更好 → 直接 copy，交给下面的 RGA 转 8bit
      # MPV_ZC_TRIAL=0 同理：既然不打算试，就不该把没验证过的 rkmpp 当默认值发出去
      if [ -z "${MPV_HWDEC:-}" ] && [ "$IS10" != yes ] && [ "${MPV_ZC_TRIAL:-1}" = 1 ]; then
        HW=rkmpp; ZC_TRIAL=yes
      fi
      dlog "tty+GPU(${GPU_TAG:-未知})：vo=drm GLES 直出；10bit=$IS10 零拷贝试错=$ZC_TRIAL"
    else
      # 没有任何 GL 用户态：vo=drm 只剩 KMS 拷帧。rkmpp 解出的 nv12/yuv 必须 yuyv 直通，
      # 否则 CPU 逐帧做 4K YUV→RGB（实测单核满载、0.4x 卡顿）；box 缩放最省。
      VO_ARGS="--vo=drm --drm-format=yuyv --scale=box --dscale=box$DRM_MODE"
      dlog "tty 无 GL 用户态：vo=drm 纯 KMS 送显 + rkmpp-copy"
    fi
    ;;
  x11)
    if [ "$GPU" = yes ]; then
      VO_ARGS="--vo=$VON --gpu-context=x11egl"; [ "${MPV_HWDEC:-}" != rkmpp-copy ] && HW=rkmpp
    elif [ "$XV" = no ]; then
      # modesetting 驱动一般不带 Xv：显式退回 x11 软拷贝，别等 mpv 报错
      VO_ARGS="--vo=x11"; dlog "X11 无GPU且无Xv → vo=x11"
    else
      VO_ARGS="--vo=xv"; dlog "X11 无GPU：Xv overlay（Xv 未确认时 mpv 会自行回退）"
    fi
    [ "$TIER" = 4K ] && [ "$GPU" = no ] && VO_ARGS="$VO_ARGS --scale=box --dscale=box"
    ;;
  wayland)
    # 板测（RK3576+Panfrost+GNOME Wayland，VP9 4K60）：零拷贝 0.74x vs rkmpp-copy 0.46x
    # → 有 GPU 的桌面会话必须走 rkmpp 零拷贝；copy 路径的每帧回拷在桌面下是净损失
    if [ "$GPU" = yes ]; then
      VO_ARGS="--vo=$VON"; [ "${MPV_HWDEC:-}" != rkmpp-copy ] && HW=rkmpp
      # 上下文交给 mpv 自动选（wayland/x11vk 视编译面而定）；显式指定反而在非标准合成器上失败
      [ "${CTX_WL:-no}" = yes ] && VO_ARGS="$VO_ARGS --gpu-context=wayland"
    else
      VO_ARGS="--vo=wlshm"
      [ "$TIER" = 4K ] && VO_ARGS="$VO_ARGS --scale=box --dscale=box"
    fi
    ;;
esac

# 位深分叉（RK3576 + Panfrost + GNOME Wayland 实测）：10bit 帧走 dmabuf 零拷贝是负收益
#   HEVC 4K60-10bit：零拷贝 0.18x（45s 没跑完 8s，近乎卡死）vs copy 0.33x
#   VP9  4K60-10bit：零拷贝 0.18x vs copy 0.58x；而 8bit 相反（0.74 vs 0.46）
# 原因是 mesa 侧对 nv15/nv20 的 modifier 支持不全，导入即退化成逐帧 CPU 转换。
# 故：桌面会话里的 10bit 片一律 copy；tty 直出交给下面的 AFBC+RGA 硬件转换路径。
if [ "$GPU" = yes ] && [ "$SESSION" != tty ] && [ "$IS10" = yes ] && [ -z "${MPV_HWDEC:-}" ]; then
  HW=rkmpp-copy; dlog "10bit + 桌面会话：用 rkmpp-copy（零拷贝实测慢 3 倍）"
fi

# AFBC + RGA（上游 Rendering 文档）：10bit 帧由 RGA 硬件转成 8bit，让无 GPU 的 KMS 直出
# 能消费 nv15/nv20（不转换就是 "No such pixel type" 或 CPU 逐帧转，实测 0.4x 卡死）。
# 需要 /dev/rga；有 GPU 的桌面会话不走这条（见上面的位深分叉）。
# MPV_AFBC=1 是"强制"开关，得能穿透 GPU=yes：板上实测（RK3576 + 包内 mesa，GPU=yes）
# 只按 GPU=no 判的话，这一档静默退回 GLES 路径，跑分表里 "AFBC+RGA" 与 "GLES零拷贝"
# 五行数字一字不差——测的根本不是想测的东西。默认仍只在无 GPU 时启用。
# 但"发参数"不等于"走 RGA"：RK3576 vendor 6.1 实测 scale_rkrga 在 mpv 的滤镜图里
# 建立失败（详见探针 RGA_FILTER），mpv 会打 "Disabling filter scale_rkrga.00" 后静默
# 用 swscale，日志看着却像走了硬件。所以这条改由 RGA_FILTER 决定，探针说不能用就不发。
# 另更正一处旧结论：这里原先写"瓶颈在 VDU（10bit 4K 约 25fps 上限）"，是桌面时代的数据；
# 板上同一支 4K60-10bit HEVC 用本包 ffmpeg 纯硬解实测 81fps（1.35x），VDU 有余量，
# 真正卡住的是 mpv 的取帧+GLES 送显（满帧 5.6fps、降到 30fps 目标也只有 11.6fps）。
if { [ "$GPU" = no ] || [ "${MPV_AFBC:-0}" = 1 ]; } && { [ "$IS10" = yes ] || [ "${MPV_AFBC:-0}" = 1 ]; }; then
  if [ "${RGA_FILTER:-unknown}" = yes ]; then
    VO_ARGS="$VO_ARGS --vd-lavc-o=afbc=on"
    VFS="scale_rkrga=force_yuv=8bit${VFS:+,$VFS}"   # 先转格式，再降帧
    [ "$GPU" = yes ] && dlog "AFBC+RGA 由 MPV_AFBC=1 强制启用（本机有 GPU，默认不走这条）"
    dlog "AFBC+RGA：rkmpp 压帧 → RGA 转 NV12/NV16（10bit=$IS10）"
  else
    dlog "AFBC+RGA 跳过：RGA_FILTER=${RGA_FILTER:-unknown}（${RGA_FILTER_WHY:-未探测}）"
    dlog "  这条不是提速开关；探针判定本机 scale_rkrga 用不上，发出去只会静默退回 CPU 缩放"
    dlog "  想强行试：RK_RGA_FILTER=yes MPV_AFBC=1 mpv-auto <片源>；重探：删 /run/lock/rk-hwaccel-rga-filter"
  fi
fi
[ -n "$VFS" ] && VO_ARGS="$VO_ARGS --vf=$VFS"
# 滤镜链（fps 降帧 / RGA 转格式）本身就要求帧在系统内存里，零拷贝在这种场景没有意义，
# 也没有试的价值——dmabuf 帧进不了 --vf，mpv 会自己把帧拷出来，等于白跑一趟
if [ "$ZC_TRIAL" = yes ] && [ -n "$VFS" ]; then
  ZC_TRIAL=no; HW=rkmpp-copy
  dlog "有 --vf=$VFS：帧必经 CPU，取消零拷贝试错"
fi

dlog "执行: $MPV $VO_ARGS --hwdec=$HW $*"
# 参数顺序：探测出的档位在前，用户自带参数在后 → 用户显式选项始终覆盖自动决策
# GL 兜底层：系统自己给不出 GBM/EGL 时（裸 vendor 镜像实测）用本包自带的那份。
# 只有探针判定 GL_SRC=bundle 才挂——桌面机继续走系统 mesa，绝不跨版本混染。
if [ "${GL_SRC:-none}" = bundle ] && [ -n "${GL_LIBDIR:-}" ]; then
  export LD_LIBRARY_PATH="$GL_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LIBGL_DRIVERS_PATH="${GL_DRIDIR:-$GL_LIBDIR/dri}"
  if [ -n "${GL_VKICD:-}" ] && [ "${VK_OK:-no}" = yes ]; then
    export VK_DRIVER_FILES="$GL_VKICD" VK_ICD_FILENAMES="$GL_VKICD"
  fi
  dlog "启用包内 GL 兜底层：$GL_LIBDIR"
fi

if [ "$ZC_TRIAL" = yes ] && [ -z "${MPV_HWDEC:-}" ] && [ "${MPV_ZC_TRIAL:-1}" = 1 ]; then
  # 未经板测的档位不能盲跑：起播 5 秒内非零退出才认定是零拷贝路径不通（用户按 q、
  # 文件损坏之类的退出各有其因），此时退回已知能放的 rkmpp-copy 再放一次并留下记录。
  t0=$(date +%s)
  "$MPV" $VO_ARGS --hwdec=rkmpp "$@"; rc=$?
  el=$(( $(date +%s) - t0 ))
  if [ "$rc" = 0 ] || [ "$el" -ge 5 ]; then exit "$rc"; fi
  dlog "零拷贝 ${el}s 内失败(exit=$rc)：退回 rkmpp-copy 重放"
  # 这条不只给 debug 看：画面会重开一次，用户必须知道原因和怎么关掉
  echo "[mpv-auto] 零拷贝直出起播失败(exit=$rc ${el}s)，已退回 rkmpp-copy 重放；关掉试错：MPV_ZC_TRIAL=0" >&2
  exec "$MPV" $VO_ARGS --hwdec=rkmpp-copy "$@"
fi

exec "$MPV" $VO_ARGS --hwdec="$HW" "$@"
MPV_AUTO_EOF
}

#============== 目标机脚本：开机/热插拔自动调优（环境优化的唯一落点）==========
rk_hwaccel_tune() { cat <<'TUNE_EOF'
#!/usr/bin/env bash
# rk-hwaccel-tune —— 按当前系统环境补上对应的硬件加速优化
# 触发时机：① 开机（rk-hwaccel-tune.service，在 graphical.target 之前）
#          ② HDMI/DP 热插拔（85-rk-hwaccel-hotplug.rules → systemd-run 异步）
#          ③ 装机时跑第一遍（install.sh）
# 为什么必须开机跑而不是装机跑：换显示器、装卸桌面、内核更新带来 panfrost/GBM，
# 都会改变最优参数；装机那一刻的结论到下次开机就可能全是错的。
# 用法：rk-hwaccel-tune [--reason=boot|hotplug|install|manual] [--dry-run] [--quiet]
# 开关：/etc/rk-hwaccel-tune.conf  AUTO_GROUPS=1  WRITE_CONF=1  FORCE_1080P=1
set -u

CONF_DIR=/usr/local/etc/mpv
MPV_CONF="$CONF_DIR/mpv.conf"
LOCAL_CONF="$CONF_DIR/mpv.conf.local"
SWITCHES=/etc/rk-hwaccel-tune.conf
DRY=0; QUIET=0; REASON=manual
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --quiet) QUIET=1 ;;
    --reason=*) REASON=${a#--reason=} ;;
    --*) ;;                      # 其余未知开关忽略，别把它当触发原因
    *) REASON=$a ;;              # 位置参数视为触发原因（兼容 tune boot / tune hotplug）
  esac
done
say() { [ "$QUIET" = 1 ] && return 0; printf '[rk-hwaccel-tune] %s\n' "$*"; }

AUTO_GROUPS=1      # 自动把可登录非 root 用户加入 video,render,input,audio
WRITE_CONF=1       # 自动生成 mpv.conf（关掉就只修权限）
FORCE_1080P=1      # 4K 屏 + 无 GPU 时 DRM 强制 1080p 输出（实测流畅度换画质的取舍）
[ -r "$SWITCHES" ] && . "$SWITCHES"

RK_ENV=${RK_ENV:-/usr/local/bin/rk-hwaccel-env}
[ -x "$RK_ENV" ] || { say "探针缺失（$RK_ENV），跳过调优"; exit 1; }
[ -e /dev/mpp_service ] || { say "无 /dev/mpp_service：非 vendor 内核，不做任何改动"; exit 0; }
# 探针输出先收进变量再 eval：直接 eval "$(...)" 时探针若中途死掉（set -u 下踩到未设
# 变量、脚本被截断等），tune 会在下一行的 ${DISTRO_ID} 上再崩一次，报错完全指不到根因。
ENV_OUT=$("$RK_ENV" 2>&1); ENV_RC=$?
[ "$ENV_RC" = 0 ] || { say "探针 $RK_ENV 退出码 $ENV_RC：$(tail -1 <<<"$ENV_OUT")"; exit 1; }
grep -q '^PROFILE=' <<<"$ENV_OUT" || { say "探针 $RK_ENV 没给出结论（输出 $(wc -l <<<"$ENV_OUT") 行）：$(tail -2 <<<"$ENV_OUT" | tr '\n' ' ')"; exit 1; }
eval "$ENV_OUT"   # SESSION/GPU/GBM/XV/SCREEN_*/PROFILE/CTX_*/VK_ICD...（必须命令替换；直接 eval 路径等于只把探针打印出来）
say "触发=$REASON 发行版=$DISTRO_ID($FAMILY) 会话=$SESSION 桌面=$DE GPU=$GPU/${GPU_DRV:-none} GBM=$GBM GL=${GL_SRC:-none}/${GL_DRIVER:-none} 屏=${SCREEN_CONN:-未接}(${SCREEN_NATIVE:-无}) 档位=$PROFILE"

run() { [ "$DRY" = 1 ] && { say "  [dry-run] $*"; return 0; }; "$@"; }

# 只有 --dry-run 允许非 root 跑（纯读）；其余场景写 /etc、改组、改权限都需要 root
if [ "$(id -u)" != 0 ] && [ "$DRY" != 1 ]; then
  say "需要 root（写 /etc、改用户组、改设备权限）；只看结论请用：rk-hwaccel-tune --dry-run"
  exit 1
fi

# ---------- 1. 库搜索路径（openEuler 与 Debian 都不保证含 /usr/local/lib）----------
LDCONF=/etc/ld.so.conf.d/rk-hwaccel.conf
if ! grep -qs '/usr/local/lib64' "$LDCONF" 2>/dev/null; then
  if [ "$DRY" = 1 ]; then
    say "  [dry-run] 写 $LDCONF 并 ldconfig"
  else
    printf '%s\n%s\n' /usr/local/lib /usr/local/lib64 > "$LDCONF" && ldconfig
    say "已登记 /usr/local/lib{,64} 到 ld.so.conf.d"
  fi
fi

# 包内 GL 兜底层（裸 vendor 镜像系统里根本没有 GBM/EGL，实测 mpv 连加载都失败）。
# mpv-auto 自带这份环境；这里额外挂 profile.d 是为了"手工敲 mpv/ffprobe"也能跑。
# 只在探针判定该用时写；日后系统自己装了 mesa，下次开机自动撤掉。
GLPB=/etc/profile.d/rk-hwaccel-glfallback.sh
if [ "${GL_SRC:-}" = bundle ] && [ -n "${GL_LIBDIR:-}" ]; then
  if [ "$DRY" = 1 ]; then
    say "  [dry-run] 写 $GLPB（系统无 GL → 挂包内 mesa：$GL_LIBDIR）"
  else
    { printf '%s\n' \
        "# 由 rk-hwaccel-tune 生成：系统缺 GBM/EGL，改用本包自带的 mesa" \
        "LD_LIBRARY_PATH=\"$GL_LIBDIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"" \
        "export LD_LIBRARY_PATH" \
        "export LIBGL_DRIVERS_PATH=\"$GL_DRIDIR\""
      [ -n "${GL_VKICD:-}" ] && [ "${VK_CAP:-unknown}" != no ] \
        && printf 'export VK_DRIVER_FILES="%s" VK_ICD_FILENAMES="%s"\n' "$GL_VKICD" "$GL_VKICD"
      :; } > "$GLPB"
    say "系统无 GL 用户态：已挂包内 mesa（$GLPB）"
  fi
elif [ -f "$GLPB" ]; then
  run rm -f "$GLPB"
  say "系统已有 GL 用户态：撤掉包内 mesa 的 profile.d 挂载"
fi

# ---------- 2. 设备权限：udev 规则 + 现存节点 ----------
# 发行版差异就在这里：openEuler 镜像自带 50-rk-mpp.rules，Armbian/deepin 的厂商镜像
# 常常没有——缺规则就补，否则非 root 用户播放直接 permission denied。
if ! grep -rqs 'mpp_service' /etc/udev/rules.d /usr/lib/udev/rules.d 2>/dev/null; then
  if [ -f /usr/local/share/rk-hwaccel/99-rk-mpp.rules ]; then
    run install -m 0644 /usr/local/share/rk-hwaccel/99-rk-mpp.rules /etc/udev/rules.d/99-rk-mpp.rules
    run udevadm control --reload-rules
    say "系统缺 mpp 设备规则，已补 /etc/udev/rules.d/99-rk-mpp.rules"
  fi
fi
# 热插拔触发规则同样自愈（系统重置过 /etc/udev 时，下次开机自动补回）
# grep 用 tune 自身做标记，避免"规则里含 mpp_service"之类的误命中导致跳过
if [ -f /usr/local/share/rk-hwaccel/85-rk-hwaccel-hotplug.rules ] && \
   ! grep -rqs 'rk-hwaccel-tune' /etc/udev/rules.d 2>/dev/null; then
  run install -m 0644 /usr/local/share/rk-hwaccel/85-rk-hwaccel-hotplug.rules /etc/udev/rules.d/85-rk-hwaccel-hotplug.rules
  run udevadm control --reload-rules
  say "已补 HDMI/DP 热插拔触发规则（换屏后无需重启即重算参数）"
fi
# 规则管不到的当前会话：直接 chmod 已存在的节点（下次插拔由规则接管）
for n in /dev/mpp_service /dev/rga /dev/iep /dev/rkvdec /dev/rkvenc /dev/rkvip /dev/drmrga; do
  [ -e "$n" ] || continue
  grp=$(stat -c %G "$n" 2>/dev/null)
  [ "$grp" = video ] || run chgrp video "$n" 2>/dev/null || true
  mode=$(stat -c %a "$n" 2>/dev/null)
  [ "$mode" = 660 ] || run chmod 0660 "$n" 2>/dev/null || true
done

# ---------- 3. 非 root 用户组（新建用户后重启即生效，无需重装）----------
if [ "$AUTO_GROUPS" = 1 ]; then
  for g in video render input audio; do
    getent group "$g" >/dev/null 2>&1 || run groupadd -r "$g" || true
  done
  for u in $(awk -F: '$3>=1000 && $3<60000 && $7!~/(nologin|false)$/ {print $1}' /etc/passwd); do
    add=""
    for g in video render input audio; do
      # 逗号拼：usermod -aG 只吃"一个参数里的逗号列表"，空格分隔会被当成一个组名，
      # 板上实测报 usermod: group 'video render input audio' does not exist，四个组一个没加
      id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$g" || add="${add:+$add,}$g"
    done
    if [ -n "$add" ]; then
      run usermod -aG "$add" "$u" && say "用户 $u 补组: $add（已登录会话需重新登录生效）"
    fi
  done
fi

# ---------- 4. 按环境生成 mpv 配置 ----------
[ "$WRITE_CONF" = 1 ] || { say "WRITE_CONF=0，不改动 mpv 配置"; exit 0; }

# 本环境的最优显示参数（全部来自板上实测结论，非推断）：
#  · 无桌面+无 GL 用户态：vo=drm，rkmpp 解出的 nv12/yuv 必须 yuyv 直通，否则 CPU 逐帧
#    做 4K YUV→RGB（单核满载、0.4x 卡顿）；box 缩放最省
#  · 4K 屏 + yuyv 每帧 16MB 压垮 RK3576 VOP：强制 1080p 输出交给 plane 硬件缩放 → 满速
#    （屏是 1080p 时不写 drm-mode，原生即可）
#  · 有 GPU+GBM 的桌面：gpu-next 零拷贝，上下文按会话给 wayland / x11egl
#  · 有 GPU+GBM 的 tty（档位 rk-drm-gl）：用 vo=drm——它自带 EGL/GBM 上下文，只需 GLES，
#    且探针已确认 dri 里有真 GPU 驱动（GL_GPU）。
#    这条是 Bifrost（G52/G31，RK3528/3566/3568/3576）唯一的 tty GPU 直出路径：那些 GPU
#    没有 PanVK，displayvk 在这类板上永远起不来（见探针的 VK_CAP 代际闸）。
#  · tty 且 Valhall+ 且 mpv 真编了 displayvk（PLACEBO_VULKAN=1）才给 rk-drm-gpu。
#  注意 mpv 0.41 已删 --gpu-context=drm（RK3576 实测：传它是致命解析错误），所以
#  GLES 档写 vo=drm 而不是 gpu-context=drm；探针不支持 displayvk 时也不会误发该选项。
#  TODO(未实测)：tty+GLES 的零拷贝（hwdec=rkmpp 进 vo=drm）没有任何板上数字，
#    所以开机配置继续发 rkmpp-copy（已知能放），零拷贝只由 mpv-auto 单次试错验证。
drm_tier() {   # KMS 送显档（无 GL 用户态时的 tty 直出）
  VO_LINE="vo=drm"; HW_LINE=rkmpp-copy
  EXTRA_LINES="drm-format=yuyv"$'\n'"scale=box"$'\n'"dscale=box"
  if [ "$FORCE_1080P" = 1 ] && [ "${SCREEN_4K:-no}" = yes ]; then
    EXTRA_LINES="$EXTRA_LINES"$'\n'"drm-mode=1920x1080"
    say "4K 屏(${SCREEN_NATIVE})+KMS 直出：输出降到 1080p 保流畅（长期关：$SWITCHES 里 FORCE_1080P=0；单次：MPV_NATIVE_4K=1 mpv-auto）"
  elif [ "${SCREEN_4K:-no}" = yes ]; then
    say "FORCE_1080P=0：保留原生 4K 输出（可能卡顿）"
  fi
}
# tty 的 GLES 直出档：GL_GPU=yes（系统 mesa 或包内兜底层带真 GPU 驱动）就能用，不要求 Vulkan
gles_tier() {
  VO_LINE="vo=drm"; HW_LINE=rkmpp-copy; EXTRA_LINES=""
  [ "${VO_DRM:-yes}" = no ] && say "警告：已装 mpv 没有 vo=drm，本档位可能起不来（检查构建时 -Ddrm/-Dgbm）"
  if [ "$FORCE_1080P" = 1 ] && [ "${SCREEN_4K:-no}" = yes ]; then
    EXTRA_LINES="drm-mode=1920x1080"
    say "4K 屏(${SCREEN_NATIVE})：vo=drm 直出仍按 1080p 输出保流畅（长期关：$SWITCHES 里 FORCE_1080P=0）"
  fi
  say "tty+GPU(${GPU_TAG:-未知})：vo=drm 的 GLES 直出（PanVK=$VK_CAP，没有 Vulkan 也可用）"
}
VO_LINE="vo=drm"; EXTRA_LINES=""; HW_LINE=rkmpp-copy
# tty 直出完全按探针给的 PROFILE 走（探针是唯一的判定源，避免这里再推一遍推出两套结论）：
#   rk-drm-gpu  displayvk：已含"mpv 编了 Vulkan + 有 ICD + Valhall+ + 有 loader"
#   rk-drm-gl   vo=drm 的 GLES 档：有 GPU + GBM 用户态（系统 mesa 或包内兜底）
#   rk-drm      没有 GL 用户态：KMS 拷帧 + yuyv 直通
case "$SESSION:$PROFILE" in
  tty:rk-drm-gpu)
    HW_LINE=rkmpp
    VO_LINE="vo=gpu"; [ "${VO_GN:-no}" = yes ] && VO_LINE="vo=gpu-next"
    EXTRA_LINES="gpu-context=displayvk"
    say "tty+${GPU_TAG:-GPU}：$VO_LINE/displayvk Vulkan 零拷贝直出" ;;
  tty:rk-drm-gl) gles_tier ;;
  tty:*)         drm_tier ;;
esac
if [ "${PROFILE:-}" = rk-drm-gl ] && [ -n "${VK_WHY:-}" ]; then
  say "  （本板不走 displayvk：mpv=${CTX_DSVK:-?} ICD=${VK_ICD:-?} PanVK=${VK_CAP:-?} —— $VK_WHY）"
fi
# 裸 mesa 只带 swrast 的发行版（openEuler 实测）：libgbm 在位但不能当 GLES 档用——
# vo=drm 会落到 kms_swrast 纯 CPU 光栅，比这里的 KMS 拷帧更慢，却容易被当成"GPU 生效"。
if [ "${PROFILE:-}" = rk-drm ] && [ "${GL_GPU:-no}" = no ] && [ "${GBM:-no}" = yes ] && [ -n "${GL_WHY:-}" ]; then
  say "  （系统有 libgbm 但 GLES 档不可用：$GL_WHY —— 仍用 KMS 拷帧，不走 kms_swrast 软件光栅）"
fi
if [ "$GPU" = yes ] && [ "$GBM" = yes ]; then
  case "$SESSION" in
    x11|wayland)
      # 零拷贝：解码帧以 dmabuf 直接进 GPU，缩放/色彩合成都在 GPU 上（上游推荐口径）
      HW_LINE=rkmpp
      VO_LINE="vo=gpu"; [ "${VO_GN:-no}" = yes ] && VO_LINE="vo=gpu-next"
      [ "$SESSION" = x11 ] && EXTRA_LINES="gpu-context=x11egl" || EXTRA_LINES="gpu-context=wayland"
      say "GPU(${GPU_DRV})+GBM 可用：$VO_LINE 零拷贝路径（会话 $SESSION）" ;;
  esac
elif [ "$SESSION" = x11 ]; then
  # 无 GPU 的桌面：Xv overlay（modesetting 常不带 Xv，mpv 自己会回退 vo=x11）；
  # 运行时的 Xv 实测与细化由 mpv-auto 负责。tty 不进这里——上面已按 PROFILE 定完档，
  # 再跑 drm_tier 会把 GLES 档的结果覆盖成纯 KMS。
  VO_LINE="vo=xv"
elif [ "$SESSION" = wayland ]; then
  VO_LINE="vo=wlshm"     # 软件合成（GNOME/XFCE Wayland 无 GPU 驱动时唯一可用）
fi
# 音频：无桌面时显式 alsa，避免探测 pipewire 拖慢起播；桌面会话留 auto 让 pipewire/pulse 接管
AO_LINE=""
[ "$SESSION" = tty ] && AO_LINE="ao=alsa"

tmp=$(mktemp)
{
  echo "# 本文件由 rk-hwaccel-tune 自动生成，请勿手工编辑（每次开机/热插拔会被覆盖）"
  NOW=$(date '+%F %T'); [ "$(date +%Y)" -lt 2020 ] && NOW="$NOW（RTC 未对时）"
  echo "# 生成时间: $NOW  触发: $REASON  档位: $PROFILE"
  echo "# 自定义请写 $LOCAL_CONF：本文件的用户段在档位之前原样附加，避免落进 [profile] 里"
  echo "hwdec=$HW_LINE"
  echo "$VO_LINE"
  [ -n "$AO_LINE" ] && echo "$AO_LINE"
  printf '%s\n' "$EXTRA_LINES" | grep -v '^$' || true
  if [ -r "$LOCAL_CONF" ]; then
    echo
    echo "# ---- 以下为 $LOCAL_CONF 原样附加（用户自定义，必须在档位段之前）----"
    cat "$LOCAL_CONF"
  fi
  # 档位段必须放最后：mpv 配置里 [xxx] 之后的所有键值都属于该段
  # 注意不要加 profile-allow：mpv 0.41 已删掉该选项，写了会让整份 mpv.conf 解析失败
  # （RK3576 实测）。0.41 上配置文件里的 [profile] 可直接用 --profile=rk-xxx 选中。
  echo
  echo "# ---- 手工覆盖用的档位（mpv --profile=rk-xxx ...）----"
  # RGA 滤镜的实测结论直接写进配置，省得有人照着档位菜单试了半天其实没走硬件
  printf '# RGA 滤镜(AFBC+RGA 路径)本机判定: %s（%s）\n' "${RGA_FILTER:-unknown}" "${RGA_FILTER_WHY:-未探测}"
  # 全量菜单 + 本机可用性标注：留着别的板子的档位方便拷贝配置，但把在本机必然起不来的
  # 那条标出来——尤其 rk-drm-gpu，Bifrost（G52/G31）上没有 PanVK，选中就是黑屏。
  n_drm="";  [ "${VO_DRM:-yes}" = no ] && n_drm="已装 mpv 没有 vo=drm"
  # GLES 档的真判据是 GL_GPU（dri 里有非 swrast 的 GPU 驱动），不是"看得见 libgbm"：
  # openEuler 裸 mesa 只有 kms_swrast，选中这条会静默变成 CPU 光栅。旧探针没这键时退回 GBM。
  n_gl="";   { [ "${GPU:-no}" != yes ] || [ "${GL_GPU:-${GBM:-no}}" != yes ]; } && n_gl="无可用 GLES 驱动（${GL_WHY:-系统无 GBM/EGL 用户态}），vo=drm 只能 CPU 拷帧"
  n_gpu="";  { [ "${CTX_DSVK:-no}" != yes ] || [ "${VK_OK:-no}" != yes ]; } && n_gpu="${VK_WHY:-本 mpv 没编 displayvk}"
  # 档位菜单里的 gpu-context 值必须是"本机真能用"的，否则只写成注释：
  # 板上实测（RK3576 + 本包 mpv）mpv.conf 里 [rk-drm-gpu] 段的 gpu-context=displayvk
  # 每次启动都打三行 "Option gpu-context: 'displayvk' isn't supported / Error parsing
  # option gpu-context / mpv.conf:28: setting option ... failed"。profile 段里它不致命
  # （档没选中时不影响播放），但选中就是黑屏，而且没人该在日志里看到伪报错。
  # 本文件每次开机/热插拔重生成，所以本机不可用时先注释掉、换到能用的板子自动展开。
  L_DSVK='gpu-context=displayvk'
  [ -n "$n_gpu" ] && L_DSVK="# gpu-context=displayvk   ← 本机不可用（见上一行说明），故注释；换板子重生成时自动放开"
  L_X11='gpu-context=x11egl'
  [ "${CTX_X11:-yes}" = no ] && L_X11="# gpu-context=x11egl   ← 本 mpv 没编 x11 上下文"
  L_WL='gpu-context=wayland'
  [ "${CTX_WL:-yes}" = no ] && L_WL="# gpu-context=wayland   ← 本 mpv 没编 wayland 上下文"
  n_x11="";  n_wl=""
  { [ "${GPU:-no}" != yes ] || [ "${GBM:-no}" != yes ]; } && { n_x11="无 GPU/GBM，这条会退回软解"; n_wl="$n_x11"; }
  printf '%s\n' \
    "${n_drm:+# rk-drm 本机不可用：$n_drm}" \
    '[rk-drm]' 'vo=drm' 'drm-format=yuyv' 'scale=box' 'dscale=box' '' \
    '# tty + GBM/EGL（系统 mesa 或包内兜底层）：vo=drm 自带 GLES 上下文，Bifrost（G52/G31）' \
    '# 这类没有 PanVK 的 GPU 只能走这条。零拷贝交给 mpv-auto 试，长期配置留 copy。' \
    "${n_gl:+# rk-drm-gl 本机不可用：$n_gl}" \
    '[rk-drm-gl]' 'vo=drm' 'hwdec=rkmpp-copy' '' \
    "# gpu-context=displayvk 只给 vo=gpu/gpu-next，且要 Valhall 及以后的 Mali（PanVK 覆盖）" \
    "${n_gpu:+# rk-drm-gpu 本机不可用：$n_gpu}" \
    '[rk-drm-gpu]' 'vo=gpu-next' "$L_DSVK" 'hwdec=rkmpp' '' \
    "${n_x11:+# rk-x11-gpu 本机不可用：$n_x11}" \
    '[rk-x11-gpu]' 'vo=gpu-next' "$L_X11" 'hwdec=rkmpp' '' \
    '[rk-x11-sw]' 'vo=xv' '' \
    "${n_wl:+# rk-wayland-gpu 本机不可用：$n_wl}" \
    '[rk-wayland-gpu]' 'vo=gpu-next' "$L_WL" 'hwdec=rkmpp' '' \
    '[rk-wayland-sw]' 'vo=wlshm'
} > "$tmp"
if [ "$DRY" = 1 ]; then
  say "[dry-run] 将生成的 mpv.conf："; sed 's/^/    /' "$tmp"
  rm -f "$tmp"; exit 0
fi
mkdir -p "$CONF_DIR"
if [ -f "$MPV_CONF" ] && ! grep -q 'rk-hwaccel-tune 自动生成' "$MPV_CONF" 2>/dev/null; then
  cp -a "$MPV_CONF" "$MPV_CONF.pre-tune.bak" && say "已有的 mpv.conf 已备份为 mpv.conf.pre-tune.bak"
fi
mv "$tmp" "$MPV_CONF"; chmod 0644 "$MPV_CONF"
[ -e "$LOCAL_CONF" ] || printf '# 用户自定义 mpv 选项写在这里，开机调优不会覆盖本文件\n' > "$LOCAL_CONF"
say "已按当前环境生成 $MPV_CONF"
TUNE_EOF
}

#============== 开机调优服务 + 热插拔触发 =====================================
tune_service() { cat <<'EOF'
[Unit]
Description=RK35xx 硬解栈开机环境自适应调优（设备权限/用户组/mpv 参数）
Documentation=file:/usr/local/share/rk-hwaccel/README
# 在图形会话拉起之前完成：桌面启动时读到的 mpv.conf 已是本次探测的结论
# （display-manager 与 graphical.target 同属一个事务，显式 Before 它才保证先后）
After=systemd-udevd.service local-fs.target
Before=graphical.target display-manager.service
# 非 vendor 内核（无 mpp 设备）不跑，避免在别的机器上乱改配置
ConditionPathExists=/dev/mpp_service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rk-hwaccel-tune --reason=boot
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

hotplug_rules() { cat <<'EOF'
# HDMI/DP 插拔后重算硬件加速参数（换 4K/1080p 屏、接不接屏结论不同）
# RUN+= 必须快进快出，故用 systemd-run --no-block 异步派发给 tune
SUBSYSTEM=="drm", ACTION=="change", KERNEL=="card[0-9]*", RUN+="/usr/bin/systemd-run --quiet --no-block /usr/local/bin/rk-hwaccel-tune --reason=hotplug --quiet"
EOF
}

#============== udev 规则：仅在目标系统自身没有 mpp 规则时补 ==================
mpp_rules() { cat <<'EOF'
# rk35xx vendor 内核的媒体设备节点：无桌面 DRM 直跑需要 video 组可访问
# openEuler 镜像自带 50-rk-mpp.rules；Debian/Armbian 厂商镜像未必有，故随包提供
KERNEL=="mpp_service", MODE="0660", GROUP="video"
KERNEL=="rga",       MODE="0660", GROUP="video"
KERNEL=="iep",       MODE="0660", GROUP="video"
KERNEL=="rkvdec",    MODE="0660", GROUP="video"
KERNEL=="rkvenc",    MODE="0660", GROUP="video"
KERNEL=="rkvip",     MODE="0660", GROUP="video"
KERNEL=="drmrga",    MODE="0660", GROUP="video"
EOF
}

#------------------------- 写入 staging 并打包 --------------------------------
mkdir -p "$STAGE$PREFIX/bin" "$STAGE$PREFIX/share/rk-hwaccel" \
         "$STAGE$PREFIX/lib/systemd/system"
install_script   > "$STAGE/install.sh"
rk_hwaccel_env   > "$STAGE$PREFIX/bin/rk-hwaccel-env"
rk_hwaccel_tune  > "$STAGE$PREFIX/bin/rk-hwaccel-tune"
mpv_auto          > "$STAGE$PREFIX/bin/mpv-auto"
tune_service     > "$STAGE$PREFIX/lib/systemd/system/rk-hwaccel-tune.service"
hotplug_rules    > "$STAGE$PREFIX/share/rk-hwaccel/85-rk-hwaccel-hotplug.rules"
mpp_rules        > "$STAGE$PREFIX/share/rk-hwaccel/99-rk-mpp.rules"
# 说明文档：systemd 单元的 Documentation= 指向这里，同时也是装机后的速查
cat > "$STAGE$PREFIX/share/rk-hwaccel/README" <<EOF
rk35xx 硬件加速播放栈（mpv + ffmpeg-rockchip + MPP/RGA）  构建于 $TS

开机自适应：rk-hwaccel-tune.service 在每次开机（图形会话之前）重新探测环境并生成
  /usr/local/etc/mpv/mpv.conf；换显示器由 udev(85-rk-hwaccel-hotplug.rules) 触发重算。
  开关在 /etc/rk-hwaccel-tune.conf（AUTO_GROUPS/WRITE_CONF/FORCE_1080P）。
探测能力清单（发行版/内核/芯片/GPU/会话/桌面/显示器）：rk-hwaccel-env
按当前会话细化的播放包装器：mpv-auto <片源>；调试决策链：MPV_AUTO_DEBUG=1 mpv-auto …
EOF
chmod +x "$STAGE/install.sh" "$STAGE$PREFIX/bin/rk-hwaccel-env" \
         "$STAGE$PREFIX/bin/rk-hwaccel-tune" "$STAGE$PREFIX/bin/mpv-auto"

for sc in "$STAGE/install.sh" "$STAGE$PREFIX/bin/rk-hwaccel-env" \
          "$STAGE$PREFIX/bin/rk-hwaccel-tune" "$STAGE$PREFIX/bin/mpv-auto"; do
  bash -n "$sc" || die "生成的脚本语法错误：$sc"
done
# 三个探针脚本走 bash 语法（数组、[[ ]]），但 shebang 是发行版无关的
# "#!/usr/bin/env bash"——这里只认"首行是 shebang 且指向 bash"，别按固定路径比对
for sc in "$STAGE$PREFIX/bin/rk-hwaccel-env" "$STAGE$PREFIX/bin/rk-hwaccel-tune" "$STAGE$PREFIX/bin/mpv-auto"; do
  head -1 "$sc" | grep -q '^#!.*bash' || die "$sc 缺 bash shebang"
done

# 瘦身：目标机运行不需要头文件/静态库/libtool 文件与测试程序
rm -rf "$STAGE$PREFIX/include"
find "$STAGE$PREFIX/lib" "$STAGE$PREFIX/lib64" -maxdepth 1 -name '*.a' -delete 2>/dev/null || true
find "$STAGE$PREFIX/lib" "$STAGE$PREFIX/lib64" -maxdepth 1 -name '*.la' -delete 2>/dev/null || true
for junk in rgaImDemo; do rm -f "$STAGE$PREFIX/bin/$junk"; done

FF_REV=$(git -C "$WORK/ffmpeg-rockchip" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)
VK_BUILT=关; [ "$PLACEBO_VULKAN" = 1 ] && VK_BUILT=开
cat > "$STAGE/VERIFY.txt" <<EOF
rk-hwaccel-local  $TS
构建机: openEuler 24.03 glibc ${glibc_ver:-?} / kernel $(uname -r)
组件: jellyfin-mpp $MPP_BRANCH + jellyfin-rga $RGA_BRANCH(meson) + dav1d $DAV1D_VER
      + libdisplay-info $LIBDISPLAY_INFO_VER + libplacebo $LIBPLACEBO_VER(OpenGL后端；Vulkan=$VK_BUILT)
      + ffmpeg-rockchip $FF_BRANCH@$FF_REV + mpv $MPV_TAG
      + GL兜底层 libdrm $LIBDRM_VER + mesa $MESA_VER$GL_NOTE
目标: openEuler 24.03 / deepin 25 / Debian trixie / Ubuntu noble、resolute（均需 rk35xx vendor 内核）
限制: RK3576 无 AV1 硬解（RK3588 才有）——AV1 回落 dav1d 软解，4K60 约 0.9x、8K 不可用
      HEVC/VP9 4K60-10bit 纯解码上限约 0.42x（VDU 吞吐所限，与零拷贝/AFBC 无关）
      H264 4K 约 1.7x，4K30 满速有余
      tty 直出的 GPU 档默认是 vo=drm（自带 GBM/EGL，只要 GLES），不是 displayvk：
      PanVK 只覆盖 Valhall 及以后的 Mali（RK3588 的 G610 等），而 RK3528/3566/3568/3576
      的 Bifrost（G31/G52/G76…）与更早 Midgard 没有可用 Vulkan，Mesa 照样把 ICD json
      装进系统 → 探针认 GPU 代际而不是"有没有 ICD 文件"，否则 mpv 起 displayvk 直接黑屏。
      Valhall 板要 displayvk 需构建时 PLACEBO_VULKAN=1（额外带 glslang/shaderc 与 loader）
      GLES 档的判据不是"看得见 libgbm"而是"dri 目录里有能用的 GPU 驱动（GL_GPU）"：
      openEuler 24.03 裸 mesa 只带 kms_swrast/swrast（rockchip_dri.so 是 tinydrm 面板驱动，
      没有 panfrost_dri.so），这种机器上装系统 mesa 也不会得到 GPU GLES——vo=drm 会落到
      kms_swrast 纯 CPU 光栅，比 KMS 拷帧更慢还更像"GPU 生效"。所以该发行版要 GLES 直出
      只能靠本包的 glfallback（探针会自动整包换用它，不与系统 mesa 混染）。
安装: scp 本 tar 与 install.sh 同目录 → sudo bash install.sh [用户名 ...]
      install.sh 解包 + 检查系统库 + 登记开机自适应 + 跑第一遍；缺系统库只点名不代装
      （不动系统包管理状态）。真正的按环境优化在
      每次开机（rk-hwaccel-tune.service，图形会话之前）与显示器热插拔（udev）时重算：
      发行版、vendor 内核、有/无桌面、X11/Wayland、GNOME/XFCE/KDE、GPU+GBM+Xv 能力、
      当前接到的是 1080p 还是 4K 屏 → 生成对应 vo/hwdec/drm-format/drm-mode/scale/ao 与
      mpv profile 段；同时补 udev 规则、ld.so.conf.d，并把可登录非 root 用户加进
      video,render,input,audio 组。开关见 /etc/rk-hwaccel-tune.conf
探测依据: sudo rk-hwaccel-env（能力清单，含 GPU 型号/代际与"能不能走 displayvk"的判定理由）
          sudo rk-hwaccel-tune --dry-run（将要写入的内容）
运行: mpv-auto <片源>   在开机结论之上再按本片 分辨率×帧率×位深 与当前会话细化
      （MPV_AUTO_DEBUG=1 看决策链；MPV_NATIVE_4K/MPV_FULLFPS/MPV_HWDEC/MPV_AFBC 覆盖；
      tty+GLES 档会试一次 rkmpp 零拷贝直出，5s 内失败自动退回 rkmpp-copy，MPV_ZC_TRIAL=0 关掉）
自检: ffmpeg 10 个 *_rkmpp 解码器 + scale_rkrga；mpv 有 rkmpp hwdec、alsa ao、gpu-next vo、
      drm vo（tty 直出靠它，构建期 GATE 断言过，缺了就 die）、
      ldd 无 not found、RUNPATH 指向 /usr/local/lib{,64}——以上均在构建期 GATE 断言过
产物清单:
  /usr/local/bin/{mpv,ffmpeg,ffprobe,dav1d}   播放器与命令行工具（RUNPATH 自带，不依赖环境变量）
  /usr/local/bin/mpv-auto                     播放包装器：开机结论之上按本片与当前会话再细化
  /usr/local/bin/rk-hwaccel-env               环境探针（唯一事实源，可单独跑来看判定依据）
  /usr/local/bin/rk-hwaccel-tune              按探针落地优化（开机/热插拔/装机三处触发）
  /usr/local/lib{,64}/*.so                    运行时库（mpv 动态链这份）
  /usr/local/etc/mpv/mpv.conf                 由 rk-hwaccel-tune 开机生成，本包不预置
  /usr/local/share/rk-hwaccel/glfallback/     GL 兜底层（libgbm/libEGL/GLES/Vulkan + 依赖闭包）
                                              只在系统本身缺 GL 时启用，桌面机完全不碰
EOF

tar --numeric-owner -C "$STAGE" -czf "$OUT/$TARBALL" usr install.sh VERIFY.txt
( cd "$OUT" && sha256sum "$TARBALL" > "$TARBALL.sha256" )   # 相对文件名，目标机可直接 -c 校验
# install.sh/VERIFY.txt 单独放一份到产物目录：scp 整个目录到板子上即可直接 sudo bash install.sh
cp -f "$STAGE/install.sh" "$STAGE/VERIFY.txt" "$OUT/"

# 打包内容自检：开机自适应三件套必须在包里，且不能预置 mpv.conf（由 tune 开机生成）
LIST=$(tar tzf "$OUT/$TARBALL")
for need in usr/local/bin/mpv usr/local/bin/mpv-auto usr/local/bin/rk-hwaccel-env \
            usr/local/bin/rk-hwaccel-tune \
            usr/local/lib/systemd/system/rk-hwaccel-tune.service \
            usr/local/share/rk-hwaccel/85-rk-hwaccel-hotplug.rules \
            usr/local/share/rk-hwaccel/99-rk-mpp.rules; do
  printf '%s\n' "$LIST" | grep -qx "$need" || die "tar 内缺 $need"
done
if printf '%s\n' "$LIST" | grep -q 'usr/etc/mpv.conf'; then
  die "tar 内不应预置系统级 mpv.conf（开机由 rk-hwaccel-tune 生成）"
fi
if printf '%s\n' "$LIST" | grep -q '^usr/local/etc/mpv/mpv.conf$'; then
  die "tar 内不应预置 mpv.conf（开机由 rk-hwaccel-tune 生成）"
fi
# GL 兜底层：构建成功就必须完整入包，且不得污染 $PREFIX/lib（防跨版本混染）
if [ "$GL_BUILT" = 1 ]; then
  for need in usr/local/share/rk-hwaccel/glfallback/lib/libgbm.so.1 \
              usr/local/share/rk-hwaccel/glfallback/lib/libEGL.so.1; do
    printf '%s\n' "$LIST" | grep -qx "$need" || die "tar 内缺 $need（GL 兜底层未入包）"
  done
  # 黑名单只收 mesa 自家的东西：gbm/EGL/GLES 与系统 libdrm、X11、wayland 是编译期 ABI
  # 耦合的，落进 $PREFIX/lib 会 shadow 系统 mesa，跨目录混装最容易出"能加载但花屏"。
  # libdrm 故意不在名单里：它是本包刻意装进 $PREFIX/lib 的运行时依赖（Step 2 断言它必须
  # 就位、mpv 直接链接它、RUNPATH 指向这里），且 libdrm 不做符号版本化、新版向后兼容，
  # 被系统 mesa 引用到也不会错配。早先把它列进来等于和 Step 2 互相打架：CI 上
  # "GL 兜底：84 个 .so"全绿之后，就是被这条自相矛盾的检查在收尾处判死的。
  for poison in libgbm.so.1 libEGL.so.1 libGLESv2.so.2; do
    # 用 if 而不是 "grep && die"：set -e 下 grep 未命中（正是正常情况）会连带整脚本退出
    # lib64 也扫：发行版/构建参数不同，主目录可能落在这里，判据不该跟着变
    for dir in usr/local/lib usr/local/lib64; do
      if printf '%s\n' "$LIST" | grep -qx "$dir/$poison"; then
        die "$dir/$poison 不该存在：mesa 只允许落在 glfallback/，进主库目录会 shadow 系统 mesa"
      fi
      if [ "$poison" = libgbm.so.1 ] && printf '%s\n' "$LIST" | grep -q "^$dir/libgallium"; then
        # gallium 实体名带版本号（libgallium-24.2.8.so），只能前缀匹配
        die "$dir/libgallium-* 不该存在：mesa 只允许落在 glfallback/"
      fi
    done
  done
  log "  GL 兜底入包：$(printf '%s\n' "$LIST" | grep -c 'glfallback/.*\.so' || true) 个 .so"
fi

log "产物：$OUT/$TARBALL（$(du -h "$OUT/$TARBALL" | awk '{print $1}')）"
log "校验：$OUT/$TARBALL.sha256"
log "分发：scp tar 包与 install.sh 到目标机同目录 → sudo bash install.sh"
