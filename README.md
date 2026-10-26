# Debian 13 极简 DD 镜像

基于上游 [ninjayo/debian13-minimal-for1gdisk](https://github.com/ninjayo/debian13-minimal-for1gdisk) v1.0 的 qcow2 转制的 raw DD 镜像（`.img.gz`），可直接 `dd` 到 VPS 硬盘。

## 规格

- 系统：Debian 13 trixie，内核 6.12.73 cloud
- 文件系统：btrfs（zstd:3 压缩）
- 引导：GPT + BIOS 启动（GRUB i386-pc，**无 UEFI 分区**）
- 虚拟盘：1 GiB
- 网络：网卡 `ens3` + DHCP（注意：镜像内无 dhclient，DHCP 不一定能拿到地址；DD 收尾时可直接选静态配置，见下）
- SSH：root 密码登录开启
- 其他：无 swap、无 cloud-init
- 首启：自动 btrfs resize + balance（balance 会把元数据转 single，约 1–3 分钟；期间 df 显示偏小属正常）

## 一键 DD（救援模式或现有 Linux，root 运行）

```bash
curl -fsSL https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/dd-install.sh -o dd-install.sh
bash dd-install.sh /dev/vda
```

脚本流程：先确认目标盘（不知道盘名时直接运行 `bash dd-install.sh`，不给盘名，脚本会列出本机磁盘让你选；不要选带数字的分区，DD 必须写整盘），再预检（启动方式、磁盘容量、主网卡名、收尾工具），汇总报告并经你确认后才写入；写入后、重启前自动收尾（网卡不一致时修正配置、大盘自动扩容，并可按提示设置主机名与静态网络）；全程校验 SHA256。UEFI 机器预检会直接中止（本镜像无 EFI 分区，硬上也会掉进 UEFI Shell，不要用 `--force` 硬上，见排查章节）。目标盘有已挂载分区时脚本会拒绝并打印救援模式步骤，不要在运行系统里后台 DD。

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

1. 首次登录后立即修改 root 密码（默认密码见上游项目说明）；
2. 确认网络：`ip a` 看到正确的 IP；只有 169.254 开头时说明 DHCP 失败，按排查章节改静态配置；
3. 确认扩容：以 `btrfs filesystem usage /` 为准（Device size 应为整盘；`df -h` 在 btrfs 上显示偏小属正常，不要以 df 为准）；
4. 确认首启 balance 已完成：`btrfs filesystem df /` 里应全是 single、没有 DUP；仍有 DUP 时可手动跑 `btrfs balance start --force -dconvert=single -mconvert=single -sconvert=single /`（mixed 块组必须三项同转，system 须加 `--force`）；
5. 大盘扩容：脚本已在 DD 后、重启前自动做完；仅当救援环境缺少 growpart 或 btrfs 工具时需手动执行（脚本会打印命令）：

```bash
growpart /dev/vda 2 && btrfs filesystem resize max /
```

6. SSH 首次连接报主机密钥变更属正常（DD 后密钥变了），先清理旧密钥再连：`ssh-keygen -R <IP>`。

## 适用与不适用

- 适合：1G 盘 + 512M 内存小鸡，跑轻量服务；
- 256M 内存：能跑，但建议加一个 256–512MB 的 swapfile，别上 Docker、数据库；
- 不适合：UEFI-only 的机子（本镜像无 EFI 分区，无法启动；脚本预检会中止；双启动版待出）；网卡名不是 `ens3` 的机子脚本会自动修正配置，仅救援环境不支持 btrfs 时需进 VNC 修改 `/etc/network/interfaces`。
- 注意：镜像内无 dhclient，DHCP 环境下可能拿不到地址；DD 收尾时选静态配置最稳。

## 排查（实测踩过的坑）

- **不要在运行系统里后台 DD**：写盘会覆盖正在运行的系统，sshd 先死、文件系统变只读、SSH 断线；之后面板的优雅重启/关机/重装可能全部无效。正道永远是救援模式（脚本拒绝挂载盘时会打印步骤）。
- **探针还在线 ≠ 没重启**：探针进程在内存里继续上报，SSH 断了、VNC 里旧系统日志还在刷，都不代表重启失败；以面板电源状态和新系统是否起来为准。
- **面板操作没反应**：先等几分钟（面板操作有延迟）；优雅操作对已死的系统无效，改用强制断电；仍无效就找商家工单，写明主机名、IP、请求宿主机强制断电。
- **VNC 粘贴命令变了形**：面板 VNC 的发送框会把多行粘贴合成一行、长命令截断（约 200 字）；一次只贴一条短命令，命令被合成一行时按 Ctrl+C 取消重贴，不要直接回车。
- **掉进 UEFI Shell**：本镜像纯 BIOS、无 EFI 分区，UEFI 固件找不到启动项就会这样；Shell 里修不了（认不出 btrfs）。办法：固件切 BIOS/Legacy/CSM，或等双启动版。
- **网络起不来**：先 `ls /sys/class/net` 对网卡名（镜像里写死 ens3，实际可能是 ens18 之类），把 `/etc/network/interfaces` 里的 ens3 改掉；只有 169.254 说明 DHCP 失败，镜像无 dhclient，改静态最稳（`iface <网卡> inet static` + address/netmask/gateway/dns-nameservers，DD 收尾时选静态可直接写好）。DNS 全空（`cat /etc/resolv.conf` 没有 nameserver）时先写 `nameserver 8.8.8.8` 应急，再固化到 interfaces。
- **df 显示比实际小**：btrfs 的 statvfs 保守估计，以 `btrfs filesystem usage /` 的 Device size 为准；转全 single 后 df 才会显示正常（见“启动后必做”第 4 条）。
- **growpart 显示 NOCHANGE**：正常，说明分区已经扩过了，继续做 `btrfs filesystem resize max /` 即可。
- **文件校验失败（如 hwdb.bin）**：删文件后重建（`rm /usr/lib/udev/hwdb.bin && systemd-hwdb update`），但删完要重启占着已删文件的服务（如 `systemctl restart systemd-udevd`），再 `sync`、等一会儿复扫，不要立即下结论（坏块释放有延迟）；复扫干净后 balance 才能跑通。
- **SSH 密钥变更警告**：DD 后主机密钥变了，属正常，先 `ssh-keygen -R <IP>` 清理旧密钥再连。

## 校验

- 文件：`debian13-minimal-dd.img.gz.part00`～`part05`（6 个分卷，共约 259MB，见 Releases；合并后即为 `debian13-minimal-dd.img.gz`）
- 合并后 SHA256：`a6b8edc0ba979caf9e53f8db6dae035a37442e67accd1c33daeecb0851c7e45a`

## 来源

上游：https://github.com/ninjayo/debian13-minimal-for1gdisk（v1.0）
