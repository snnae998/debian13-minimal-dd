#!/bin/bash
# Debian 13 极简 DD 镜像 v2 一键写入脚本
# v2 变化：BIOS + UEFI 双启动；网络改 systemd-networkd 自动匹配网卡（不写死网卡名）；
# 分区：p1 BIOS 启动（1MB）、p2 root btrfs（926MB，可扩）、p3 ESP FAT32（75MB）。
# 用法（救援模式或现有 Linux，root 运行）：
#   curl -fsSL https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/dd-install.sh -o dd-install.sh
#   bash dd-install.sh /dev/vda
#   不知道盘名时直接运行 bash dd-install.sh，不给盘名，脚本会列出本机磁盘让你选。
# 用法（一键模式，运行系统中直接跑，root 运行，需 kexec + DHCP）：
#   bash dd-install.sh --oneclick /dev/sda
#   不知道盘名时直接运行 bash dd-install.sh --oneclick，脚本会列出本机磁盘让你选。
#   跳过确认：bash dd-install.sh --oneclick /dev/sda --yes
#   内存阶段静态网络（DHCP 失败时备用）：--static-ip 1.2.3.4/24 --static-gw 1.2.3.4 --static-dns "8.8.8.8,1.1.1.1"
# 一键模式前提：内核支持 kexec 且已装 kexec-tools；内存阶段与新系统均需 DHCP；
# kexec 触发后旧系统即消失，失败时需面板/VNC/救援恢复；先在测试机上试。
# 注意：会清空目标盘全部数据；--force 在 v2 已无作用（UEFI 已支持），保留仅为兼容旧命令。
set -euo pipefail

PARTS_URL="https://github.com/snnae998/debian13-minimal-dd/releases/download/v2.0"
IMAGE_SHA256="b0710e997638268b2c8fccb03f2f86475cf04936e4564cff6ef5657cb2535493"
IMAGE_SIZE_MIN=1073741824  # 1 GiB
# v2 分卷 SHA（逗号分隔，供一键模式内存阶段逐卷校验）
PART_SHAS="b293011b6cbfba60746887a080755cc1e426962e7e4f2a63af6dafe03a0f6cc0,577d8e1a43a4d044c8f2c7698f0c3b7c5fa60a23a0e523f37440ebaa1d8f280d,64b6f43335455b664ff431e82e19ef51d18c4280e73ccb1bfae27528e6c94dcd,9764fa83042d3aba6ca40d149a02103c8d080f827567527c46b58151e17ea980,8b1442a511c5ac601dab27ebdd147cf55518d33c2e0ff7c16ae51aaf474dbb4a"
# 一键模式内存系统（initramfs）地址与 SHA
INITRAMFS_URL_DEFAULT="https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/initramfs-dd-v2.cpio.gz"
INITRAMFS_SHA256="418933b1ba03ad72632ea52b2d098da82f29fa026de1294debbd27ec9bddb25b"

# v2 固定布局（1 GiB 镜像内，单位：512 字节扇区）
ESP_START=1900544
ESP_SECTORS=153600  # 75MB
ROOT_PART=2
ESP_PART=3
IMG_SECTORS=2097152  # 1 GiB / 512

show_disks() {
    echo "本机磁盘如下（选和你机器配置相符的那块整盘，不要选带数字的分区）："
    lsblk -d -o NAME,SIZE,MODEL -e 1,7,11 2>/dev/null || lsblk -d -o NAME,SIZE,MODEL 2>/dev/null || true
    echo "常见盘名：KVM virtio 是 vda，SATA/SCSI 是 sda，NVMe 是 nvme0n1；"
    echo "不要选带数字的分区，如 sda1、vda1、nvme0n1p1。"
}

# 一键模式：预检 -> 下载内存系统 -> 确认 -> kexec 进内存写盘。
# 任何一步失败都在 kexec 之前中止，旧系统纹丝不动；kexec 触发后旧系统即消失。
run_oneclick() {
    echo "========== 一键 DD（kexec 模式） =========="
    echo "原理：先在运行系统里预检并下载内存系统，再 kexec 重启进内存，"
    echo "在内存里写盘（旧系统已不在，不会变僵尸），写完自动重启进新系统。"
    KERNEL=""
    # Prefer the kernel matching the running version, so that the storage
    # modules bundled below (from /lib/modules/$(uname -r)) match the
    # kexec'd kernel. The generic /boot/vmlinuz may point to a newer
    # kernel after an update without reboot, whose modules would mismatch.
    if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        KERNEL="/boot/vmlinuz-$(uname -r)"
    elif [ -f /boot/vmlinuz ]; then
        KERNEL="$(readlink -f /boot/vmlinuz)"
    else
        for k in /boot/vmlinuz-*; do
            [ -f "$k" ] && KERNEL="$k"
        done
    fi
    if [ -z "$KERNEL" ] || [ ! -f "$KERNEL" ]; then
        echo "中止：找不到本机内核文件（/boot/vmlinuz），无法 kexec，请改走救援模式。" >&2
        exit 1
    fi
    echo "本机内核：$KERNEL"
    if ! command -v kexec >/dev/null 2>&1; then
        echo "中止：未找到 kexec（请先安装 kexec-tools，如 apt install kexec-tools），无法一键。" >&2
        exit 1
    fi
    if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
        if [ -n "$DISK" ]; then
            echo "没有找到磁盘：$DISK" >&2
        fi
        echo "先看本机磁盘，选一块整盘："
        show_disks
        echo
        read -rp "输入目标盘名（例如 /dev/sda，直接回车退出）: " DISK_INPUT
        if [ -z "$DISK_INPUT" ]; then
            echo "已取消"
            exit 1
        fi
        DISK="$DISK_INPUT"
        if [ ! -b "$DISK" ]; then
            echo "错误：$DISK 不是块设备，请重新运行并输入上面列表里的盘名。" >&2
            exit 1
        fi
    fi
    DISK_TYPE="$(lsblk -n -o TYPE "$DISK" 2>/dev/null || echo "")"
    if [ "$DISK_TYPE" = "part" ]; then
        echo "错误：$DISK 是分区不是整盘，DD 必须写整盘（如 /dev/sda），请重新运行。" >&2
        show_disks
        exit 1
    fi
    DISK_SIZE="$(lsblk -b -d -n -o SIZE "$DISK" 2>/dev/null || blockdev --getsize64 "$DISK" 2>/dev/null || echo "")"
    if [ -n "$DISK_SIZE" ] && [ "$DISK_SIZE" -lt "$IMAGE_SIZE_MIN" ]; then
        echo "中止：目标盘小于 1 GiB，镜像写不下。" >&2
        exit 1
    fi
    if [ -n "$DISK_SIZE" ]; then
        echo "目标盘容量：$((DISK_SIZE / 1024 / 1024)) MiB"
    fi
    INITRAMFS_URL="${INITRAMFS_URL_OVERRIDE:-$INITRAMFS_URL_DEFAULT}"
    echo "正在下载内存系统（initramfs，约 6MB）..."
    cd /tmp
    if ! curl -L --retry 3 -o dd-initramfs.cpio.gz "$INITRAMFS_URL"; then
        echo "中止：内存系统下载失败，旧系统未动。" >&2
        exit 1
    fi
    echo "$INITRAMFS_SHA256  dd-initramfs.cpio.gz" | sha256sum -c - || {
        echo "中止：内存系统 SHA 校验失败，旧系统未动。" >&2
        exit 1
    }
    echo "正在预检镜像地址..."
    if ! curl -L -I --retry 2 -o /dev/null -w "%{http_code}" "$PARTS_URL/debian13-minimal-dd.img.gz.part00" 2>/dev/null | grep -q '^2'; then
        echo "中止：镜像地址预检未通过（可能网络问题），旧系统未动。" >&2
        exit 1
    fi
    # 把本机硬盘与网卡驱动打包进内存系统（修复 kexec 后内存系统认不出盘、
    # 认不出网卡的问题：内存系统自带无内核模块，而目标的 SATA/virtio/NVMe
    # 与网卡驱动通常是模块，平时从运行系统的 /lib/modules 加载，kexec 后
    # 该目录已不在）。
    # 若未找到可打包模块（驱动可能是内置的），则直接用原内存系统。
    # 打包失败会在 kexec 前中止（旧系统未动）。
    echo "正在把本机硬盘与网卡驱动打包进内存系统..."
    INITRD_PATH="/tmp/dd-initramfs.cpio.gz"
    MODDIR="/lib/modules/$(uname -r)"
    if [ -d "$MODDIR" ]; then
        DISK_BASE="$(basename "$DISK")"
        MOD_LIST_TMP="$(mktemp /tmp/dd-mods.XXXXXX)" || { echo "中止：无法创建临时文件，旧系统未动。" >&2; exit 1; }
        if command -v lsmod >/dev/null 2>&1; then
            for mod in $(lsmod 2>/dev/null | awk 'NR>1 {print $1}' || true); do
                KO_PATH=""
                if command -v modinfo >/dev/null 2>&1; then
                    KO_PATH="$(modinfo -F filename "$mod" 2>/dev/null || echo "")"
                fi
                case "$KO_PATH" in
                    */drivers/ata/*|*/drivers/scsi/*|*/drivers/virtio/*|*/drivers/block/*|*/drivers/nvme/*|*/drivers/message/*|*/drivers/net/*)
                        echo "$mod" >> "$MOD_LIST_TMP" ;;
                esac
                case "$mod" in
                    sd_mod|scsi_mod|libata|ata_piix|ahci|libahci|virtio_blk|virtio_scsi|virtio|virtio_ring|nvme_core|nvme|dm_mod|virtio_net|e1000|e1000e|r8169|igb|ixgbe|vmxnet3|hv_netvsc)
                        echo "$mod" >> "$MOD_LIST_TMP" ;;
                esac
            done
        fi
        if [ -e "/sys/block/$DISK_BASE/device/driver" ]; then
            DRV_NAME="$(basename "$(readlink "/sys/block/$DISK_BASE/device/driver")" 2>/dev/null || echo "")"
            [ -n "$DRV_NAME" ] && echo "$DRV_NAME" >> "$MOD_LIST_TMP"
        fi
        for m in sd_mod scsi_mod libata virtio_blk virtio_scsi virtio virtio_ring nvme_core nvme ata_piix ahci virtio_net e1000 e1000e r8169; do
            echo "$m" >> "$MOD_LIST_TMP"
        done
        sort -u "$MOD_LIST_TMP" -o "$MOD_LIST_TMP" 2>/dev/null || true
        KO_LIST_TMP="$(mktemp /tmp/dd-kos.XXXXXX)" || { echo "中止：无法创建临时文件，旧系统未动。" >&2; rm -f "$MOD_LIST_TMP" || true; exit 1; }
        for mod in $(cat "$MOD_LIST_TMP" 2>/dev/null || true); do
            if command -v modprobe >/dev/null 2>&1; then
                modprobe --show-depends "$mod" 2>/dev/null | awk '{print $2}' >> "$KO_LIST_TMP" 2>/dev/null || true
            fi
            if ! grep -q "/$mod\.ko" "$KO_LIST_TMP" 2>/dev/null; then
                find "$MODDIR" -name "$mod.ko*" 2>/dev/null >> "$KO_LIST_TMP" || true
            fi
        done
        awk '!seen[$0]++' "$KO_LIST_TMP" > "$KO_LIST_TMP.uniq" 2>/dev/null || cp "$KO_LIST_TMP" "$KO_LIST_TMP.uniq" 2>/dev/null || true
        rm -f "$MOD_LIST_TMP" "$KO_LIST_TMP" || true
        if [ -s "$KO_LIST_TMP.uniq" ]; then
            if ! command -v cpio >/dev/null 2>&1; then
                echo "正在安装 cpio（打包驱动需要）..."
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get install -y cpio >/dev/null 2>&1 || true
                fi
            fi
            if ! command -v cpio >/dev/null 2>&1; then
                echo "中止：需要 cpio 来打包驱动，但安装失败；请先 apt install cpio 后重试，旧系统未动。" >&2
                rm -f "$KO_LIST_TMP.uniq" || true
                exit 1
            fi
            BUNDLE_DIR="$(mktemp -d /tmp/dd-bundle.XXXXXX)" || { echo "中止：无法创建打包目录，旧系统未动。" >&2; rm -f "$KO_LIST_TMP.uniq" || true; exit 1; }
            if ! (cd "$BUNDLE_DIR" && gzip -dc /tmp/dd-initramfs.cpio.gz | cpio -id --quiet 2>/dev/null); then
                echo "中止：内存系统解包失败，旧系统未动。" >&2
                rm -rf "$BUNDLE_DIR" || true; rm -f "$KO_LIST_TMP.uniq" || true
                exit 1
            fi
            mkdir -p "$BUNDLE_DIR/lib/modules" || { echo "中止：无法创建模块目录，旧系统未动。" >&2; rm -rf "$BUNDLE_DIR" || true; rm -f "$KO_LIST_TMP.uniq" || true; exit 1; }
            : > "$BUNDLE_DIR/lib/modules/load_order.txt" || { echo "中止：无法写模块清单，旧系统未动。" >&2; rm -rf "$BUNDLE_DIR" || true; rm -f "$KO_LIST_TMP.uniq" || true; exit 1; }
            BUNDLED_N=0
            while IFS= read -r KO; do
                [ -n "$KO" ] || continue
                [ -f "$KO" ] || continue
                BASE="$(basename "$KO")"
                OUT_BASE="$BASE"
                case "$BASE" in
                    *.ko.zst) OUT_BASE="${BASE%.ko.zst}.ko"; zstd -dc "$KO" > "$BUNDLE_DIR/lib/modules/$OUT_BASE" 2>/dev/null || continue ;;
                    *.ko.xz) OUT_BASE="${BASE%.ko.xz}.ko"; xz -dc "$KO" > "$BUNDLE_DIR/lib/modules/$OUT_BASE" 2>/dev/null || continue ;;
                    *.ko.gz) OUT_BASE="${BASE%.ko.gz}.ko"; gzip -dc "$KO" > "$BUNDLE_DIR/lib/modules/$OUT_BASE" 2>/dev/null || continue ;;
                    *) cp "$KO" "$BUNDLE_DIR/lib/modules/$OUT_BASE" 2>/dev/null || continue ;;
                esac
                echo "$OUT_BASE" >> "$BUNDLE_DIR/lib/modules/load_order.txt"
                BUNDLED_N=$((BUNDLED_N + 1))
            done < "$KO_LIST_TMP.uniq"
            rm -f "$KO_LIST_TMP.uniq" || true
            awk '!seen[$0]++' "$BUNDLE_DIR/lib/modules/load_order.txt" > "$BUNDLE_DIR/load_order.uniq" 2>/dev/null && mv "$BUNDLE_DIR/load_order.uniq" "$BUNDLE_DIR/lib/modules/load_order.txt" 2>/dev/null || true
            if [ "$BUNDLED_N" -gt 0 ] && [ -s "$BUNDLE_DIR/lib/modules/load_order.txt" ]; then
                if (cd "$BUNDLE_DIR" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > /tmp/dd-initramfs-bundled.cpio.gz); then
                    if gzip -dc /tmp/dd-initramfs-bundled.cpio.gz | cpio -t 2>/dev/null | grep -q 'lib/modules/load_order.txt'; then
                        INITRD_PATH="/tmp/dd-initramfs-bundled.cpio.gz"
                        echo "已打包 $BUNDLED_N 个硬盘驱动模块进内存系统。"
                    else
                        echo "中止：打包后的内存系统校验失败，旧系统未动。" >&2
                        rm -rf "$BUNDLE_DIR" || true
                        exit 1
                    fi
                else
                    echo "中止：内存系统重打包失败，旧系统未动。" >&2
                    rm -rf "$BUNDLE_DIR" || true
                    exit 1
                fi
            else
                echo "警告：未打包到任何驱动模块，直接使用原内存系统（若驱动是内置的则仍可工作）。"
            fi
            rm -rf "$BUNDLE_DIR" || true
        else
            rm -f "$KO_LIST_TMP.uniq" || true
            echo "未找到可打包的硬盘驱动模块（可能是内置驱动），直接使用原内存系统。"
        fi
    else
        echo "警告：找不到本机模块目录 $MODDIR，无法打包驱动；若硬盘驱动是模块，内存系统可能认不出盘。"
    fi
    echo
    echo "目标盘：$DISK"
    lsblk "$DISK" || true
    echo
    echo "警告：一键 DD 将清空 $DISK 全部数据，且 kexec 触发后当前系统即消失！"
    echo "内存阶段需要 DHCP 能拿到地址（新系统也是 networkd DHCP）；"
    echo "若内存阶段联网或下载失败，机器会停在内存系统里，需面板/VNC/救援恢复。"
    echo "请确认你有面板/VNC/救援入口，且目标盘无重要数据。"
    if [ "$YES" -ne 1 ]; then
        read -rp "确认请完整输入 YES： " CONF
        if [ "$CONF" != "YES" ]; then
            echo "已取消"
            exit 1
        fi
    fi
    CMDLINE="console=tty0 dd.target=$DISK dd.parts_url=$PARTS_URL dd.nparts=5 dd.part_shas=$PART_SHAS dd.esp_start=$ESP_START dd.esp_sectors=$ESP_SECTORS dd.img_sectors=$IMG_SECTORS"
    if [ -n "$STATIC_IP" ]; then
        CMDLINE="$CMDLINE dd.static_ip=$STATIC_IP"
    fi
    if [ -n "$STATIC_GW" ]; then
        CMDLINE="$CMDLINE dd.static_gw=$STATIC_GW"
    fi
    if [ -n "$STATIC_DNS" ]; then
        CMDLINE="$CMDLINE dd.static_dns=$STATIC_DNS"
    fi
    echo "正在载入 kexec（内核 + 内存系统）..."
    if ! kexec -l "$KERNEL" --initrd="$INITRD_PATH" --append="$CMDLINE"; then
        echo "中止：kexec 载入失败，旧系统未动。" >&2
        exit 1
    fi
    sync
    echo "kexec 已触发，正在重启进内存系统写盘（SSH 会断开，属正常）..."
    echo "写盘完成后机器会自动重启进新系统；若长时间无响应，请进面板/VNC 查看内存系统输出。"
    sleep 2
    kexec -e
    echo "kexec 执行失败，旧系统未动。" >&2
    exit 1
}

ONECLICK=0
YES=0
FORCE=0
DISK=""
STATIC_IP=""
STATIC_GW=""
STATIC_DNS=""
INITRAMFS_URL_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --oneclick) ONECLICK=1; shift ;;
        --yes) YES=1; shift ;;
        --force) FORCE=1; shift ;;
        --static-ip) STATIC_IP="$2"; shift 2 ;;
        --static-ip=*) STATIC_IP="${1#--static-ip=}"; shift ;;
        --static-gw) STATIC_GW="$2"; shift 2 ;;
        --static-gw=*) STATIC_GW="${1#--static-gw=}"; shift ;;
        --static-dns) STATIC_DNS="$2"; shift 2 ;;
        --static-dns=*) STATIC_DNS="${1#--static-dns=}"; shift ;;
        --initramfs-url) INITRAMFS_URL_OVERRIDE="$2"; shift 2 ;;
        --initramfs-url=*) INITRAMFS_URL_OVERRIDE="${1#--initramfs-url=}"; shift ;;
        --) shift; break ;;
        -*) echo "未知参数：$1" >&2; exit 1 ;;
        *) if [ -z "$DISK" ]; then DISK="$1"; else echo "多余参数：$1" >&2; exit 1; fi; shift ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行本脚本" >&2
    exit 1
fi

if [ "$ONECLICK" -eq 1 ]; then
    run_oneclick
    exit 0
fi

# 磁盘参数：没给或给错时，列出磁盘并引导用户输入
if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
    if [ -n "$DISK" ]; then
        echo "没有找到磁盘：$DISK" >&2
    fi
    echo "先看本机磁盘，选一块整盘："
    show_disks
    echo
    read -rp "输入目标盘名（例如 /dev/sda，直接回车退出）: " DISK_INPUT
    if [ -z "$DISK_INPUT" ]; then
        echo "已取消"
        exit 1
    fi
    DISK="$DISK_INPUT"
    if [ ! -b "$DISK" ]; then
        echo "错误：$DISK 不是块设备，请重新运行并输入上面列表里的盘名。" >&2
        exit 1
    fi
fi

# 分区保护：DD 必须写整盘，写分区会破坏镜像自身的分区表
DISK_TYPE="$(lsblk -n -o TYPE "$DISK" 2>/dev/null || echo "")"
if [ "$DISK_TYPE" = "part" ]; then
    echo "错误：$DISK 是分区不是整盘，DD 必须写整盘（如 /dev/sda），请重新运行。" >&2
    show_disks
    exit 1
fi

if lsblk -ln -o MOUNTPOINT "$DISK" 2>/dev/null | grep -q '[^[:space:]]'; then
    {
        echo "目标盘 $DISK 上有已挂载的分区，运行系统不能直接 DD（会写坏正在运行的系统）。"
        echo "请走救援模式，不要用后台 nohup 在运行系统里直接 DD："
        echo "  1. 在商家面板切到救援模式（Rescue）并重启进救援系统；"
        echo "  2. 在救援系统里用 root 跑同一条命令：bash dd-install.sh $DISK；"
        echo "  3. 写完后在面板切回硬盘启动，再重启进新系统。"
    } >&2
    exit 1
fi

echo "========== 第一步：预检 =========="
# 1. 启动方式（v2 双启动，BIOS 与 UEFI 均可；仅作提示，不再中止）
BOOT_MODE="BIOS"
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="UEFI"
elif [ ! -d /sys/firmware ]; then
    BOOT_MODE="未知"
fi
echo "启动方式：$BOOT_MODE（v2 为 BIOS + UEFI 双启动，均可）"
if [ "$BOOT_MODE" = "未知" ]; then
    echo "警告：无法判断启动方式；如 DD 后无法启动请进 VNC 核对开机画面。"
fi

# 2. 磁盘容量
DISK_SIZE="$(lsblk -b -d -n -o SIZE "$DISK" 2>/dev/null || blockdev --getsize64 "$DISK" 2>/dev/null || echo "")"
NEED_EXPAND=0
DISK_SECTORS=0
if [ -n "$DISK_SIZE" ]; then
    echo "目标盘容量：$((DISK_SIZE / 1024 / 1024)) MiB"
    if [ "$DISK_SIZE" -lt "$IMAGE_SIZE_MIN" ]; then
        echo "中止：目标盘小于 1 GiB，镜像写不下。" >&2
        exit 1
    fi
    if [ "$DISK_SIZE" -gt "$IMAGE_SIZE_MIN" ]; then
        NEED_EXPAND=1
    fi
    DISK_SECTORS=$((DISK_SIZE / 512))
else
    echo "警告：无法读取目标盘容量，跳过容量检查。"
fi
if [ "$NEED_EXPAND" -eq 1 ]; then
    echo "大盘：DD 后将先把 ESP 挪到盘尾，再把 root 扩到整盘。"
fi

# 3. 网卡（仅作提示；v2 用 systemd-networkd 按类型自动匹配，不再写死网卡名）
NIC="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
if [ -z "$NIC" ]; then
    NIC="$(ls /sys/class/net/ 2>/dev/null | grep -v '^lo$' | head -n 1)"
fi
if [ -n "$NIC" ]; then
    echo "本机主网卡：$NIC（v2 由 systemd-networkd 自动匹配，无需手动改配置）"
else
    echo "警告：未能识别主网卡；v2 由 networkd 自动匹配，DD 后如无网络请进 VNC 检查。"
fi

# 4. 收尾工具
HAVE_BTRFS=0
HAVE_GROWPART=0
HAVE_SGDISK=0
HAVE_SFDISK=0
if command -v btrfs >/dev/null 2>&1; then
    HAVE_BTRFS=1
fi
if command -v growpart >/dev/null 2>&1; then
    HAVE_GROWPART=1
fi
if command -v sgdisk >/dev/null 2>&1; then
    HAVE_SGDISK=1
fi
if command -v sfdisk >/dev/null 2>&1; then
    HAVE_SFDISK=1
fi
if [ "$NEED_EXPAND" -eq 1 ] && { [ "$HAVE_GROWPART" -ne 1 ] || [ "$HAVE_BTRFS" -ne 1 ]; }; then
    echo "警告：本环境缺少 growpart 或 btrfs 工具，DD 后无法自动扩容，需手动执行：growpart $DISK $ROOT_PART && btrfs filesystem resize max /"
fi
if [ "$NEED_EXPAND" -eq 1 ] && [ "$HAVE_SGDISK" -ne 1 ] && [ "$HAVE_SFDISK" -ne 1 ]; then
    echo "警告：本环境没有 sgdisk 或 sfdisk，大盘无法挪 ESP，root 将无法扩满（系统仍可启动，root 保持约 926MB）。"
fi

echo
echo "目标盘：$DISK"
lsblk "$DISK"
echo
echo "警告：写入后目标盘全部数据将被清空！"
read -rp "确认请完整输入 YES： " CONF
if [ "$CONF" != "YES" ]; then
    echo "已取消"
    exit 1
fi

echo "========== 第二步：DD =========="
cd /tmp
echo "正在下载镜像分卷（共 5 个）..."
for i in 00 01 02 03 04; do
    curl -L --retry 3 -o "dd.img.gz.part$i" "$PARTS_URL/debian13-minimal-dd.img.gz.part$i"
done
cat dd.img.gz.part* > dd.img.gz
rm -f dd.img.gz.part*
echo "正在校验 SHA256..."
echo "$IMAGE_SHA256  dd.img.gz" | sha256sum -c -
echo "正在写入 $DISK ..."
gzip -dc dd.img.gz | dd of="$DISK" bs=4M status=progress conv=fsync
sync
rm -f dd.img.gz

echo "========== 第三步：收尾（DD 后、重启前） =========="
PART="$DISK"
case "$DISK" in
    *[0-9]) PART="${DISK}p${ROOT_PART}" ;;
    *)      PART="${DISK}${ROOT_PART}" ;;
esac
partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true

# 3a. 大盘：先把 ESP 挪到盘尾，再扩 root（ESP 在 root 后面会挡住扩容）
ESP_MOVED=0
if [ "$NEED_EXPAND" -eq 1 ] && [ "$DISK_SECTORS" -gt 0 ]; then
    ESP_END=$((ESP_START + ESP_SECTORS - 1))
    # sgdisk 路径：先把备份 GPT 移到盘尾，再读真实 LastUsable 定 ESP 位置
    # （-e 后 LastUsable 可能比 盘大小-34 少 2048，不能直接用盘大小算）。
    # sfdisk 路径不受此影响（它按盘大小重写整表），仍用盘大小算。
    NEW_ESP_START=0
    NEW_ESP_END=0
    if [ "$HAVE_SGDISK" -eq 1 ]; then
        # DD 后 GPT 头仍记录 1 GiB 盘，需先把备份 GPT 移到盘尾。
        sgdisk -e "$DISK" >/dev/null 2>&1 || true
        LAST_USABLE=$(sgdisk -p "$DISK" 2>/dev/null | grep 'last usable sector' | awk '{print $NF}')
        case "$LAST_USABLE" in ''|*[!0-9]*) LAST_USABLE="" ;; esac
        if [ -n "$LAST_USABLE" ]; then
            NEW_ESP_START=$(( (LAST_USABLE - ESP_SECTORS + 1) / 2048 * 2048 ))
            NEW_ESP_END=$((NEW_ESP_START + ESP_SECTORS - 1))
        fi
    else
        NEW_ESP_START=$(( (DISK_SECTORS - ESP_SECTORS - 2048) / 2048 * 2048 ))
        NEW_ESP_END=$((NEW_ESP_START + ESP_SECTORS - 1))
    fi
    if [ "$NEW_ESP_START" -ge $((ESP_END + 2048)) ]; then
        echo "正在把 ESP 从 $ESP_START 挪到盘尾 $NEW_ESP_START ..."
        if dd if="$DISK" of="$DISK" bs=512 skip="$ESP_START" seek="$NEW_ESP_START" count="$ESP_SECTORS" conv=fsync,notrunc 2>/dev/null; then
            sync
            GPT_OK=0
            if [ "$HAVE_SGDISK" -eq 1 ]; then
                if sgdisk -d "$ESP_PART" -n "$ESP_PART:${NEW_ESP_START}:${NEW_ESP_END}" -t "$ESP_PART:EF00" -c "$ESP_PART:EFI System" "$DISK" >/dev/null 2>&1; then
                    GPT_OK=1
                fi
            elif [ "$HAVE_SFDISK" -eq 1 ]; then
                if sfdisk -d "$DISK" 2>/dev/null | awk -v s="$NEW_ESP_START" '/^\/.*3 :/{sub(/start=[0-9]+/, "start="s)} {print}' > /tmp/dd-gpt.txt && sfdisk --force "$DISK" < /tmp/dd-gpt.txt >/dev/null 2>&1; then
                    GPT_OK=1
                fi
                rm -f /tmp/dd-gpt.txt
            fi
            if [ "$GPT_OK" -eq 1 ]; then
                partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
                echo "ESP 已挪到盘尾。"
                ESP_MOVED=1
            else
                echo "警告：GPT 改写失败，ESP 未挪动；为保启动，放弃扩容（root 保持约 926MB，系统仍可启动）。"
                echo "手动处理：装好 sgdisk 后跑 sgdisk -d $ESP_PART -n $ESP_PART:${NEW_ESP_START}:${NEW_ESP_END} -t $ESP_PART:EF00 $DISK，再 growpart $DISK $ROOT_PART && btrfs filesystem resize max /"
                NEED_EXPAND=0
            fi
        else
            echo "警告：ESP 复制失败，放弃扩容（root 保持约 926MB，系统仍可启动）。"
            NEED_EXPAND=0
        fi
    else
        echo "磁盘仅比镜像大一点，或 LastUsable 读不到，ESP 挪动会重叠，放弃扩容（root 保持约 926MB，系统仍可启动）。"
        NEED_EXPAND=0
    fi
fi

# 3b. 挂载 root：扩容 + 主机名 + 静态网络（networkd）
if [ "$HAVE_BTRFS" -eq 1 ]; then
    if [ "$NEED_EXPAND" -eq 1 ] && [ "$HAVE_GROWPART" -eq 1 ]; then
        if growpart "$DISK" "$ROOT_PART" 2>/dev/null; then
            echo "root 分区已扩到整盘（ESP 已在盘尾）。"
        else
            echo "growpart 失败，扩容需手动做：growpart $DISK $ROOT_PART && btrfs filesystem resize max /"
            NEED_EXPAND=0
        fi
    fi
    mkdir -p /tmp/ddfix
    if mount -t btrfs "$PART" /tmp/ddfix 2>/dev/null; then
        if [ "$NEED_EXPAND" -eq 1 ]; then
            if btrfs filesystem resize max /tmp/ddfix 2>/dev/null; then
                echo "文件系统已扩到整盘。"
            else
                echo "btrfs 扩容失败，首次启动后手动执行：btrfs filesystem resize max /"
            fi
        fi
        # 主机名（可选，留空保持默认）
        read -rp "主机名（留空保持默认，直接回车跳过）: " NEW_HOST || true
        if [ -n "${NEW_HOST:-}" ]; then
            echo "$NEW_HOST" > /tmp/ddfix/etc/hostname
            echo "主机名已设为 $NEW_HOST。"
        fi
        # 静态网络（可选；networkd 按类型匹配，不写网卡名）
        echo "默认走 DHCP（networkd 自动匹配网卡）；如需静态配置请选 y（直接回车保持 DHCP）。"
        read -rp "是否写入静态网络配置？(y/N): " SET_STATIC || true
        if [ "${SET_STATIC:-}" = "y" ] || [ "${SET_STATIC:-}" = "Y" ]; then
            read -rp "IP 地址（如 38.147.165.150）: " STATIC_IP || true
            if [ -n "${STATIC_IP:-}" ]; then
                STATIC_GW_DEFAULT="$(echo "$STATIC_IP" | awk -F. '{print $1"."$2"."$3".1"}')"
                read -rp "前缀长度（默认 24）: " STATIC_PREFIX || true
                read -rp "网关（默认 $STATIC_GW_DEFAULT）: " STATIC_GW || true
                read -rp "DNS（默认 8.8.8.8 1.1.1.1）: " STATIC_DNS || true
                STATIC_PREFIX="${STATIC_PREFIX:-24}"
                STATIC_GW="${STATIC_GW:-$STATIC_GW_DEFAULT}"
                STATIC_DNS="${STATIC_DNS:-8.8.8.8 1.1.1.1}"
                mkdir -p /tmp/ddfix/etc/systemd/network
                {
                    echo "[Match]"
                    echo "Type=ether"
                    echo ""
                    echo "[Network]"
                    echo "Address=$STATIC_IP/$STATIC_PREFIX"
                    echo "Gateway=$STATIC_GW"
                    echo "DNS=$STATIC_DNS"
                } > /tmp/ddfix/etc/systemd/network/10-static.network
                rm -f /tmp/ddfix/etc/systemd/network/10-dhcp.network
                # 镜像里没有 resolved，networkd 的 DNS= 不会写 resolv.conf；静态时必须同时写 resolv.conf。
                {
                    echo "# Static DNS (set by dd-install.sh)."
                    echo "$STATIC_DNS" | tr ' ' '\n' | sed 's/^/nameserver /'
                } > /tmp/ddfix/etc/resolv.conf
                echo "静态网络已写入，内容如下："
                cat /tmp/ddfix/etc/systemd/network/10-static.network
                cat /tmp/ddfix/etc/resolv.conf
            else
                echo "未输入 IP，跳过静态配置，保持 DHCP。"
            fi
        fi
        umount /tmp/ddfix 2>/dev/null || true
        rmdir /tmp/ddfix 2>/dev/null || true
    else
        echo "无法挂载新系统分区（本环境可能不支持 btrfs），以下步骤请首次启动后手动做："
        if [ "$NEED_EXPAND" -eq 1 ]; then
            echo "  扩容：growpart $DISK $ROOT_PART && btrfs filesystem resize max /"
        fi
        echo "  主机名：hostnamectl set-hostname <名字>"
        echo "  静态：写 /etc/systemd/network/10-static.network（Match Type=ether，Address/Gateway/DNS），并删 10-dhcp.network"
    fi
elif [ "$NEED_EXPAND" -eq 1 ]; then
    echo "缺少 btrfs 工具，收尾步骤请首次启动后手动做："
    echo "  扩容：growpart $DISK $ROOT_PART && btrfs filesystem resize max /"
else
    echo "无需收尾：磁盘与镜像一致，网络由 networkd 自动匹配。"
fi
sync

echo
echo "写入完成！接下来："
echo "  1. 重启进入新系统（BIOS 与 UEFI 均可；若是救援模式，先在面板切回硬盘启动）"
echo "  2. 首次启动 btrfs balance 约 1-3 分钟（会把元数据转 single，期间 df 显示偏小属正常）"
echo "  3. 首次登录后立即修改 root 密码"
echo "  4. 核对：ip a（确认 IP，networkd 自动匹配网卡）、btrfs filesystem usage /（确认容量；df 在 btrfs 上显示偏小，以 usage 为准）"
echo "  5. 若 SSH 报主机密钥变更（DD 后密钥变了），先清理旧密钥再连：ssh-keygen -R <IP>"
echo "  6. 网络起不来时不要反复重装，先按 README 排查章节走（networkd 状态、静态配置、DNS）"
