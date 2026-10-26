# Debian 13 极简 DD 镜像

基于上游 [ninjayo/debian13-minimal-for1gdisk](https://github.com/ninjayo/debian13-minimal-for1gdisk) v1.0 的 qcow2 转制的 raw DD 镜像（`.img.gz`），可直接 `dd` 到 VPS 硬盘。

当前版本 **v2.0**：BIOS + UEFI 双启动；网络改 systemd-networkd 自动匹配网卡（不再写死网卡名）。

## 规格

- 系统：Debian 13 trixie，内核 6.12.73 cloud
- 文件系统：btrfs（zstd:3 压缩；v2 出厂数据与元数据已是 single）
- 引导：GPT 双启动——p1 BIOS 启动区（1MB，GRUB i386-pc）、p2 root（926MB）、p3 ESP（75MB FAT32，含 BOOTX64.EFI）；BIOS 与 UEFI 机器均可启动
- 虚拟盘：1 GiB
- 网络：systemd-networkd，按网卡类型自动匹配所有以太网卡（ens3、ens18、enp*、eth0 均可），内置 DHCP 客户端（镜像内无 dhclient、无 resolved、无 ifupdown）；resolv.conf 静态为 8.8.8.8 / 1.1.1.1（DHCP 时也用它；选静态时脚本同时写 networkd 文件与 resolv.conf）
- SSH：root 密码登录开启
- 其他：无 swap、无 cloud-init
- 首启：自动 btrfs resize max（大盘扩容）+ balance（v2 出厂已是 single，balance 很快完成；期间以 `btrfs filesystem usage /` 为准）

## 一键 DD（救援模式或现有 Linux，root 运行）

```bash
curl -fsSL https://raw.githubusercontent.com/snnae998/debian13-minimal-dd/main/dd-install.sh -o dd-install.sh
bash dd-install.sh /dev/vda
```

脚本流程：先确认目标盘（不知道盘名时直接运行 `bash dd-install.sh`，不给盘名，脚本会列出本机磁盘让你选；不要选带数字的分区，DD 必须写整盘），再预检（启动方式、磁盘容量、主网卡名、收尾工具），汇总报告并经你确认后才写入；写入后、重启前自动收尾（大盘先把 ESP 挪到盘尾再扩 root，并可按提示设置主机名与静态网络）；全程校验 SHA256。UEFI 与 BIOS 均可（v2 双启动，不再因 UEFI 中止）。目标盘有已挂载分区时脚本会拒绝并打印救援模式步骤，不要在运行系统里后台 DD。

## 手动 DD

```bash
cd /tmp
for i in 00 01 02 03 04; do
  wget https://github.com/snnae998/debian13-minimal-dd/releases/download/v2.0/debian13-minimal-dd.img.gz.part$i
done
cat debian13-minimal-dd.img.gz.part* > debian13-minimal-dd.img.gz
gzip -dc debian13-minimal-dd.img.gz | dd of=/dev/vda bs=4M status=progress conv=fsync
sync
```

手动收尾（DD 后、重启前，救援环境里做；root 是第 2 分区、ESP 是第 3 分区）：

```bash
# 大盘（>1GiB）：先把 ESP 挪到盘尾再扩 root（NEW_START/NEW_END 按实际盘算；嫌麻烦直接用一键脚本，它会自动算）
# sgdisk -d 3 -n 3:${NEW_START}:${NEW_END} -t 3:EF00 /dev/vda
growpart /dev/vda 2 && btrfs filesystem resize max /
# 主机名：echo <名字> > /etc/hostname（需挂载 p2 后写）
# 静态（networkd）：写 /etc/systemd/network/10-static.network（Match Type=ether，Address/Gateway/DNS），删 10-dhcp.network，并同步写 /etc/resolv.conf
```

## 启动后必做

1. 首次登录后立即修改 root 密码（默认密码见上游项目说明）；
2. 确认网络：`ip a` 看到正确的 IP，`networkctl status` 看 networkd 状态；只有 169.254 开头时说明 DHCP 失败，按排查章节改静态配置（networkd 文件 + resolv.conf，不再改 interfaces）；
3. 确认扩容：以 `btrfs filesystem usage /` 为准（Device size 应为整盘；`df -h` 在 btrfs 上显示偏小属正常，不要以 df 为准）；
4. 确认 balance：`btrfs filesystem df /` 里应全是 single、没有 DUP（v2 出厂即 single）；仍有 DUP 时可手动跑 `btrfs balance start --force -dconvert=single -mconvert=single -sconvert=single /`（mixed 块组必须三项同转，system 须加 `--force`）；
5. 大盘扩容：脚本已在 DD 后、重启前自动做完（ESP 挪盘尾 + growpart + resize）；仅当救援环境缺少 sgdisk/sfdisk 时无法挪 ESP，root 保持约 926MB 但系统仍可启动，之后装好 gdisk 再手动挪 ESP 并扩容（脚本会打印命令）；
6. SSH 首次连接报主机密钥变更属正常（DD 后密钥变了），先清理旧密钥再连：`ssh-keygen -R <IP>`。

## 适用与不适用

- 适合：1G 盘 + 512M 内存小鸡，跑轻量服务；BIOS 与 UEFI 机器均可；任何网卡名（networkd 自动匹配）；
- 256M 内存：能跑，但建议加一个 256–512MB 的 swapfile，别上 Docker、数据库；
- 不适合：小于 1 GiB 的盘（十进制 1GB 不够，镜像是 1 GiB）；大盘扩容需要救援环境有 sgdisk 或 sfdisk，否则 root 保持约 926MB（仍可启动）。
- 注意：镜像内无 dhclient、无 resolved；DHCP 由 networkd 内置客户端做，DNS 静态为 8.8.8.8 / 1.1.1.1；如你网络屏蔽 8.8.8.8，DD 收尾时选静态并填可用 DNS，或进系统改 `/etc/resolv.conf`。

## 排查（实测踩过的坑）

- **不要在运行系统里后台 DD**：写盘会覆盖正在运行的系统，sshd 先死、文件系统变只读、SSH 断线；之后面板的优雅重启/关机/重装可能全部无效。正道永远是救援模式（脚本拒绝挂载盘时会打印步骤）。
- **探针还在线 ≠ 没重启**：探针进程在内存里继续上报，SSH 断了、VNC 里旧系统日志还在刷，都不代表重启失败；以面板电源状态和新系统是否起来为准。
- **面板操作没反应**：先等几分钟（面板操作有延迟）；优雅操作对已死的系统无效，改用强制断电；仍无效就找商家工单，写明主机名、IP、请求宿主机强制断电。
- **VNC 粘贴命令变了形**：面板 VNC 的发送框会把多行粘贴合成一行、长命令截断（约 200 字）；一次只贴一条短命令，命令被合成一行时按 Ctrl+C 取消重贴，不要直接回车。
- **掉进 UEFI Shell**：v2 已带 ESP，正常不应再掉 Shell；若仍掉，说明 DD 不完整（ESP 没写进去或损坏）或固件启动顺序不对，先核对分区（救援里 `sgdisk -p` 应看到 EF00 的 p3）与 ESP 内容（挂载 p3 看 EFI/BOOT/BOOTX64.EFI），不行就重 DD 一次。
- **网络起不来**：先 `networkctl status` 与 `ip a`（v2 不再写死网卡名，不用改 ens3）；只有 169.254 说明 DHCP 失败，改静态最稳（写 `/etc/systemd/network/10-static.network`：Match Type=ether，Address/Gateway/DNS，并删 10-dhcp.network，同时把 DNS 写进 `/etc/resolv.conf`；DD 收尾时选静态可直接写好）。resolv.conf 没有 nameserver 时先写 `nameserver 8.8.8.8` 应急。
- **df 显示比实际小**：btrfs 的 statvfs 保守估计，以 `btrfs filesystem usage /` 的 Device size 为准；转全 single 后 df 才会显示正常（v2 出厂即 single，见“启动后必做”第 4 条）。
- **growpart 显示 NOCHANGE**：正常，说明分区已经扩过了，继续做 `btrfs filesystem resize max /` 即可。
- **大盘扩容没扩满**：救援环境没有 sgdisk/sfdisk 时脚本无法挪 ESP，root 保持约 926MB，系统仍可启动；装好 gdisk 后按脚本打印的命令手动挪 ESP 再扩容。
- **文件校验失败（如 hwdb.bin）**：v2 已重建干净的 hwdb.bin；若今后再遇，删文件后重建（`rm /usr/lib/udev/hwdb.bin && systemd-hwdb update`），但删完要重启占着已删文件的服务（如 `systemctl restart systemd-udevd`），再 `sync`、等一会儿复扫，不要立即下结论（坏块释放有延迟）；复扫干净后 balance 才能跑通。
- **SSH 密钥变更警告**：DD 后主机密钥变了，属正常，先 `ssh-keygen -R <IP>` 清理旧密钥再连。

## 校验

- 文件：`debian13-minimal-dd.img.gz.part00`～`part04`（5 个分卷，共约 239MB，见 Releases v2.0；合并后即为 `debian13-minimal-dd.img.gz`）
- 合并后 SHA256：`b0710e997638268b2c8fccb03f2f86475cf04936e4564cff6ef5657cb2535493`

## 来源

上游：https://github.com/ninjayo/debian13-minimal-for1gdisk（v1.0）

v2 相对 v1 的变化：BIOS + UEFI 双启动（新增 75MB ESP）；网络改 systemd-networkd（自动匹配网卡、内置 DHCP，resolv.conf 静态）；hwdb.bin 重建干净；根文件系统出厂即 single；一键脚本支持大盘 ESP 挪盘尾再扩容。v1.0（纯 BIOS）Release 仍保留，可回退。
