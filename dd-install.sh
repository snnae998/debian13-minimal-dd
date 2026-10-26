#!/bin/bash
# Debian 13 极简 DD 镜像 v2 一键写入脚本
# v2 变化：BIOS + UEFI 双启动；网络改 systemd-networkd 自动匹配网卡（不写死网卡名）；
# 分区：p1 BIOS 启动（1MB）、p2 root btrfs（926MB，可扩）、p3 ESP FAT32（75MB）。
# 用法（救援模式或现有 Linux，root 运行）：
#   curl -fsSL https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/dd-install.sh -o dd-install.sh
#   bash dd-install.sh /dev/vda
#   不知道盘名时直接运行 bash dd-install.sh，不给盘名，脚本会列出本机磁盘让你选。
# 注意：会清空目标盘全部数据；--force 在 v2 已无作用（UEFI 已支持），保留仅为兼容旧命令。
set -euo pipefail

PARTS_URL="https://github.com/snnae998/debian13-minimal-dd/releases/download/v2.0"
IMAGE_SHA256="b0710e997638268b2c8fccb03f2f86475cf04936e4564cff6ef5657cb2535493"
IMAGE_SIZE_MIN=1073741824  # 1 GiB

# v2 固定布局（1 GiB 镜像内，单位：512 字节扇区）
ESP_START=1900544
ESP_SECTORS=153600  # 75MB
ROOT_PART=2
ESP_PART=3

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
    NEW_ESP_START=$(( (DISK_SECTORS - ESP_SECTORS - 2048) / 2048 * 2048 ))
    NEW_ESP_END=$((NEW_ESP_START + ESP_SECTORS - 1))
    if [ "$NEW_ESP_START" -ge $((ESP_END + 2048)) ]; then
        echo "正在把 ESP 从 $ESP_START 挪到盘尾 $NEW_ESP_START ..."
        if dd if="$DISK" of="$DISK" bs=512 skip="$ESP_START" seek="$NEW_ESP_START" count="$ESP_SECTORS" conv=fsync 2>/dev/null; then
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
        echo "磁盘仅比镜像大一点，ESP 挪动会重叠，放弃扩容（root 保持约 926MB，系统仍可启动）。"
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
