#!/bin/bash
# Debian 13 极简 DD 镜像一键写入脚本
# 用法（救援模式或现有 Linux，root 运行）：
#   curl -fsSL https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/dd-install.sh -o dd-install.sh
#   bash dd-install.sh /dev/vda
# 注意：会清空目标盘全部数据，脚本会再次要求确认。
set -euo pipefail

PARTS_URL="https://github.com/snnae998/debian13-minimal-dd/releases/download/v1.0"
IMAGE_SHA256="a6b8edc0ba979caf9e53f8db6dae035a37442e67accd1c33daeecb0851c7e45a"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行本脚本" >&2
    exit 1
fi

DISK="${1:-}"
if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
    echo "用法: bash dd-install.sh /dev/vda" >&2
    echo "本机磁盘：" >&2
    lsblk -d -o NAME,SIZE,MODEL 2>/dev/null || true
    exit 1
fi

if lsblk -ln -o MOUNTPOINT "$DISK" 2>/dev/null | grep -q '[^[:space:]]'; then
    echo "目标盘 $DISK 上有已挂载的分区，请在救援模式下运行，或先卸载" >&2
    exit 1
fi

echo "目标盘：$DISK"
lsblk "$DISK"
echo
echo "警告：写入后目标盘全部数据将被清空！"
read -rp "确认请完整输入 YES： " CONF
if [ "$CONF" != "YES" ]; then
    echo "已取消"
    exit 1
fi

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

echo
echo "写入完成！接下来："
echo "  1. 重启进入新系统（需要 BIOS/Legacy 启动，UEFI-only 的机子无法启动）"
echo "  2. 网卡为 ens3 + DHCP，首次启动 btrfs balance 约 1-3 分钟"
echo "  3. 首次登录后立即修改 root 密码"
echo "  4. 大盘扩容：growpart ${DISK} 2 && btrfs filesystem resize max /"
