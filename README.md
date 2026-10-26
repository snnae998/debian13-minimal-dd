# Debian 13 极简 DD 镜像

基于上游 [ninjayo/debian13-minimal-for1gdisk](https://github.com/ninjayo/debian13-minimal-for1gdisk) v1.0 的 qcow2 转制的 raw DD 镜像（`.img.gz`），可直接 `dd` 到 VPS 硬盘。

## 规格

- 系统：Debian 13 trixie，内核 6.12.73 cloud
- 文件系统：btrfs（zstd:3 压缩）
- 引导：GPT + BIOS 启动（GRUB i386-pc，**无 UEFI 分区**）
- 虚拟盘：1 GiB
- 网络：网卡 `ens3` + DHCP
- SSH：root 密码登录开启
- 其他：无 swap、无 cloud-init

## 一键 DD（救援模式或现有 Linux，root 运行）

```bash
curl -fsSL https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/dd-install.sh -o dd-install.sh
bash dd-install.sh /dev/vda
```

脚本流程：先预检（启动方式、磁盘容量、主网卡名、收尾工具），汇总报告并经你确认后才写入；写入后、重启前自动收尾（网卡不一致时修正配置、大盘自动扩容）；全程校验 SHA256。UEFI 机器预检会直接中止，可用 `bash dd-install.sh /dev/vda --force` 强行继续（但可能无法启动）。

## 手动 DD

```bash
cd /tmp
for i in 00 01 02 03 04 05; do
  wget https://github.com/snnae998/debian13-minimal-dd/releases/download/v1.0/debian13-minimal-dd.img.gz.part$i
done
cat debian13-minimal-dd.img.gz.part* > debian13-minimal-dd.img.gz
gzip -dc debian13-minimal-dd.img.gz | dd of=/dev/vda bs=4M status=progress conv=fsync
sync
```

## 启动后必做

1. 首次启动 btrfs balance 约 1–3 分钟，这段时间内 `df -h` 显示的可用空间偏小属正常；
2. 首次登录后立即修改 root 密码（默认密码见上游项目说明）；
3. 大盘扩容：脚本已在 DD 后、重启前自动做完；仅当救援环境缺少 growpart 或 btrfs 工具时需手动执行（脚本会打印命令）：

```bash
growpart /dev/vda 2 && btrfs filesystem resize max /
```

## 适用与不适用

- 适合：1G 盘 + 512M 内存小鸡，跑轻量服务；
- 256M 内存：能跑，但建议加一个 256–512MB 的 swapfile，别上 Docker、数据库；
- 不适合：UEFI-only 的机子（本镜像无 EFI 分区，无法启动；脚本预检会中止）；网卡名不是 `ens3` 的机子脚本会自动修正配置，仅救援环境不支持 btrfs 时需进 VNC 修改 `/etc/network/interfaces`。

## 校验

- 文件：`debian13-minimal-dd.img.gz.part00`～`part05`（6 个分卷，共约 259MB，见 Releases；合并后即为 `debian13-minimal-dd.img.gz`）
- 合并后 SHA256：`a6b8edc0ba979caf9e53f8db6dae035a37442e67accd1c33daeecb0851c7e45a`

## 来源

上游：https://github.com/ninjayo/debian13-minimal-for1gdisk（v1.0）
