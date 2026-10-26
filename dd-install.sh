#!/bin/bash
# Debian 13 极简 DD 镜像一键写入脚本（带预检 + 自动收尾）
# 用法（救援模式或现有 Linux，root 运行）：
#   curl -fsSL https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/dd-install.sh -o dd-install.sh
#   bash dd-install.sh /dev/vda [--force]
#   不知道盘名时直接运行 bash dd-install.sh，不给盘名，脚本会列出本机磁盘让你选。
# 注意：会清空目标盘全部数据；--force 仅跳过 UEFI 启动方式检查，不跳过确认。
set -euo pipefail

PARTS_URL="https://github.com/snnae998/debian13-minimal-dd/releases/download/v1.0"
IMAGE_SHA256="a6b8edc0ba979caf9e53f8db6dae035a37442e67accd1c33daeecb0851c7e45a"
IMAGE_SIZE_MIN=1073741824  # 1 GiB

FORCE=0
DISK="${1:-}"
if [ "${2:-}" = "--force" ]; then
    FORCE=1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行本脚本" >&2
    exit 1
fi

show_disks() {
    echo "本机磁盘如下（选和你机器配置相符的那块整盘，不要选带数字的分区）："
    lsblk -d -o NAME,SIZE,MODEL -e 1,7,11 2>/dev/null || lsblk -d -o NAME,SIZE,MODEL 2>/dev/null || true
    echo "常见盘名：KVM virtio 是 vda，SATA/SCSI 是 sda，NVMe 是 nvme0n1；"
    echo "不要选带数字的分区，如 sda1、vda1、nvme0n1p1。"
}

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
# 1. 启动方式（查当前救援/现有系统的启动方式，绝大多数 VPS 上与硬盘启动方式一致）
BOOT_MODE="BIOS"
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="UEFI"
elif [ ! -d /sys/firmware ]; then
    BOOT_MODE="未知"
fi
echo "启动方式：$BOOT_MODE"
if [ "$BOOT_MODE" = "UEFI" ] && [ "$FORCE" -ne 1 ]; then
    echo "中止：本镜像只能 BIOS/Legacy 启动，你的机器是 UEFI，DD 后固件找不到启动项会掉进 UEFI Shell。" >&2
    echo "办法：① 在商家面板把启动方式切到 BIOS/Legacy/CSM 再跑；② 或等双启动版镜像。" >&2
    echo "--force 只是跳过这项检查，写完一样启动不了，不要用它硬上。" >&2
    exit 1
fi
if [ "$BOOT_MODE" = "UEFI" ]; then
    echo "警告：已用 --force 跳过 UEFI 检查，DD 后很可能无法启动（镜像无 EFI 分区）。"
fi
if [ "$BOOT_MODE" = "未知" ]; then
    echo "警告：无法判断启动方式，将按 BIOS 处理；如 DD 后无法启动请进 VNC 核对开机画面。"
fi

# 2. 磁盘容量
DISK_SIZE="$(lsblk -b -d -n -o SIZE "$DISK" 2>/dev/null || blockdev --getsize64 "$DISK" 2>/dev/null || echo "")"
NEED_EXPAND=0
if [ -n "$DISK_SIZE" ]; then
    echo "目标盘容量：$((DISK_SIZE / 1024 / 1024)) MiB"
    if [ "$DISK_SIZE" -lt "$IMAGE_SIZE_MIN" ]; then
        echo "中止：目标盘小于 1 GiB，镜像写不下。" >&2
        exit 1
    fi
    if [ "$DISK_SIZE" -gt "$IMAGE_SIZE_MIN" ]; then
        NEED_EXPAND=1
    fi
else
    echo "警告：无法读取目标盘容量，跳过容量检查。"
fi
if [ "$NEED_EXPAND" -eq 1 ]; then
    echo "大盘：DD 后将自动扩容到整盘。"
fi

# 3. 网卡（取默认路由网卡名，与镜像内的 ens3 对比）
NIC="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
if [ -z "$NIC" ]; then
    NIC="$(ls /sys/class/net/ 2>/dev/null | grep -v '^lo$' | head -n 1)"
fi
NEED_NIC_FIX=0
if [ -n "$NIC" ]; then
    echo "本机主网卡：$NIC（镜像内为 ens3）"
    if [ "$NIC" != "ens3" ]; then
        NEED_NIC_FIX=1
    fi
else
    echo "警告：未能识别主网卡，DD 后如无网络请进 VNC 检查网卡名。"
fi
if [ "$NEED_NIC_FIX" -eq 1 ]; then
    echo "网卡不一致：DD 后将自动把配置改成 $NIC。"
fi

# 4. 收尾工具
HAVE_BTRFS=0
HAVE_GROWPART=0
if command -v btrfs >/dev/null 2>&1; then
    HAVE_BTRFS=1
fi
if command -v growpart >/dev/null 2>&1; then
    HAVE_GROWPART=1
fi
if [ "$NEED_NIC_FIX" -eq 1 ] && [ "$HAVE_BTRFS" -ne 1 ]; then
    echo "警告：本环境没有 btrfs 工具，DD 后无法自动修正网卡，需进 VNC 手动改 /etc/network/interfaces。"
fi
if [ "$NEED_EXPAND" -eq 1 ] && { [ "$HAVE_GROWPART" -ne 1 ] || [ "$HAVE_BTRFS" -ne 1 ]; }; then
    echo "警告：本环境缺少 growpart 或 btrfs 工具，DD 后无法自动扩容，需手动执行：growpart $DISK 2 && btrfs filesystem resize max /"
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
echo "正在下载镜像分卷（共 6 个）..."
for i in 00 01 02 03 04 05; do
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
    *[0-9]) PART="${DISK}p2" ;;
    *)      PART="${DISK}2" ;;
esac
partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
if { [ "$NEED_NIC_FIX" -eq 1 ] || [ "$NEED_EXPAND" -eq 1 ]; } && [ "$HAVE_BTRFS" -eq 1 ]; then
    if [ "$NEED_EXPAND" -eq 1 ] && [ "$HAVE_GROWPART" -eq 1 ]; then
        if growpart "$DISK" 2 2>/dev/null; then
            echo "分区已扩到整盘。"
        else
            echo "growpart 失败，扩容需手动做：growpart $DISK 2 && btrfs filesystem resize max /"
            NEED_EXPAND=0
        fi
    fi
    mkdir -p /tmp/ddfix
    if mount -t btrfs "$PART" /tmp/ddfix 2>/dev/null; then
        if [ "$NEED_NIC_FIX" -eq 1 ] && grep -q "ens3" /tmp/ddfix/etc/network/interfaces 2>/dev/null; then
            sed -i "s/ens3/$NIC/g" /tmp/ddfix/etc/network/interfaces
            echo "网卡配置已改成 $NIC。"
        fi
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
        # 静态网络（可选；镜像无 dhclient，DHCP 不一定能拿到地址）
        if [ -n "$NIC" ]; then
            echo "镜像内没有 dhclient，DHCP 可能拿不到地址；如需静态配置请选 y（直接回车保持 DHCP）。"
            read -rp "是否写入静态网络配置？(y/N): " SET_STATIC || true
            if [ "${SET_STATIC:-}" = "y" ] || [ "${SET_STATIC:-}" = "Y" ]; then
                read -rp "IP 地址（如 38.147.165.150）: " STATIC_IP || true
                if [ -n "${STATIC_IP:-}" ]; then
                    STATIC_GW_DEFAULT="$(echo "$STATIC_IP" | awk -F. '{print $1"."$2"."$3".1"}')"
                    read -rp "子网掩码（默认 255.255.255.0）: " STATIC_MASK || true
                    read -rp "网关（默认 $STATIC_GW_DEFAULT）: " STATIC_GW || true
                    read -rp "DNS（默认 8.8.8.8 1.1.1.1）: " STATIC_DNS || true
                    STATIC_MASK="${STATIC_MASK:-255.255.255.0}"
                    STATIC_GW="${STATIC_GW:-$STATIC_GW_DEFAULT}"
                    STATIC_DNS="${STATIC_DNS:-8.8.8.8 1.1.1.1}"
                    {
                        echo "auto lo"
                        echo "iface lo inet loopback"
                        echo "auto $NIC"
                        echo "iface $NIC inet static"
                        echo "address $STATIC_IP"
                        echo "netmask $STATIC_MASK"
                        echo "gateway $STATIC_GW"
                        echo "dns-nameservers $STATIC_DNS"
                    } > /tmp/ddfix/etc/network/interfaces
                    echo "静态网络已写入，内容如下："
                    cat /tmp/ddfix/etc/network/interfaces
                else
                    echo "未输入 IP，跳过静态配置，保持 DHCP。"
                fi
            fi
        else
            echo "未能识别网卡，跳过静态配置；首次启动后请进 VNC 按 README 排查章节处理网络。"
        fi
        umount /tmp/ddfix 2>/dev/null || true
        rmdir /tmp/ddfix 2>/dev/null || true
    else
        echo "无法挂载新系统分区（本环境可能不支持 btrfs），以下步骤请首次启动后手动做："
        if [ "$NEED_NIC_FIX" -eq 1 ]; then
            echo "  网卡：进 VNC，把 /etc/network/interfaces 里的 ens3 改成 $NIC"
        fi
        if [ "$NEED_EXPAND" -eq 1 ]; then
            echo "  扩容：growpart $DISK 2 && btrfs filesystem resize max /"
        fi
    fi
elif [ "$NEED_NIC_FIX" -eq 1 ] || [ "$NEED_EXPAND" -eq 1 ]; then
    echo "缺少 btrfs 工具，收尾步骤请首次启动后手动做："
    if [ "$NEED_NIC_FIX" -eq 1 ]; then
        echo "  网卡：进 VNC，把 /etc/network/interfaces 里的 ens3 改成 $NIC"
    fi
    if [ "$NEED_EXPAND" -eq 1 ]; then
        echo "  扩容：growpart $DISK 2 && btrfs filesystem resize max /"
    fi
else
    echo "无需收尾：网卡与磁盘均与镜像一致。"
fi
sync

echo
echo "写入完成！接下来："
echo "  1. 重启进入新系统（需要 BIOS/Legacy 启动；若是救援模式，先在面板切回硬盘启动）"
echo "  2. 首次启动 btrfs balance 约 1-3 分钟（会把元数据转 single，期间 df 显示偏小属正常）"
echo "  3. 首次登录后立即修改 root 密码"
echo "  4. 核对：ip a（确认 IP）、btrfs filesystem usage /（确认容量；df 在 btrfs 上显示偏小，以 usage 为准）"
echo "  5. 若 SSH 报主机密钥变更（DD 后密钥变了），先清理旧密钥再连：ssh-keygen -R <IP>"
echo "  6. 网络起不来时不要反复重装，先按 README 排查章节走（网卡名、静态配置、DNS）"
