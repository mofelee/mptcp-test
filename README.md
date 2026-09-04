# Debian 13 WireGuard + MPTCP 双链路实验

这个实验使用 `virsh-test-host` 管理两台 Debian 13 虚拟机，并由 DebianForm 配置两条独立 WireGuard tunnel。两张 virtio 数据网卡在 libvirt 层分别双向限速为 100 Mbit/s；独立 NAT 管理网只用于 SSH，不注册为 MPTCP endpoint，也不承载 iperf 数据。

```text
                             MPTCP overlay
              wg-a 10.204.1.1 ================= 10.204.1.2 wg-a
                       |                              |
              UDP 10.203.1.1:51820 ---------- 10.203.1.2:51820
                       link-a underlay: 100 Mbit/s

  mptcp-client                                                  mptcp-server
              wg-b 10.204.2.1 ================= 10.204.2.2 wg-b
                       |                              |
              UDP 10.203.2.1:51821 ---------- 10.203.2.2:51821
                       link-b underlay: 100 Mbit/s
```

客户端从 `10.204.1.1 -> 10.204.1.2` 发起连接。服务端只通过 MPTCP `ADD_ADDR` 通告 `10.204.2.2 dev wg-b`，内核随后在第二条 tunnel 上建立 `MP_JOIN` 子流。`10.203.*` 仅作为 WireGuard endpoint underlay；管理地址和 underlay 地址都不会成为 MPTCP endpoint。

## 运行

默认环境：

- libvirt URI：`qemu+ssh://ks/system`
- storage pool：`vm`
- management network：`default`
- DebianForm 源码：`/root/debianform`（要求 v0.11.0 DSL）
- 控制端依赖：`bash`、`python3`、`virsh`、`ssh`、`flock`、`wg`

```bash
make up       # 创建/修复拓扑、应用 DebianForm、运行完整验收
make apply    # 生成测试密钥并重跑 DebianForm plan/apply/check
make verify   # 重跑单 tunnel 基线与双 tunnel MPTCP 测试
make status   # 查看 VM、限速、tunnel 和 MPTCP endpoint
make destroy  # 只删除本实验精确匹配且 UUID 校验通过的资源
```

实验运行后可直接进入两端：

```bash
ssh -F .lab/ssh_config mptcp-client
ssh -F .lab/ssh_config mptcp-server
```

runner 首次 `apply` 时在 `.lab/wireguard/` 生成四个独立私钥，并通过只含公钥的 var-file 将 peer 身份交给 DebianForm。该目录权限为 `0700`、私钥为 `0600`，整个 `.lab/` 被 Git 忽略；不要归档私钥或运行会显示私钥的 `wg showconf` / `wg show all dump`。

测试 JSON 和脱敏诊断写入 `artifacts/<UTC timestamp>-verify/`。完整报告见 [REPORT.md](REPORT.md)。可以通过 `DBF_LIBVIRT_URI`、`DBF_TEST_HYPERVISOR`、`DBF_TEST_POOL`、`DBF_TEST_NETWORK`、`DBF_TEST_SSH_PRIVATE_KEY_FILE`、`DEBIANFORM_SOURCE` 和 `DBF_BIN` 覆盖环境。

## 验收条件

- 两台 guest 均为 Debian 13，内核 MPTCP 已启用，`wireguard-tools` 由 DebianForm 安装。
- `wg-a` / `wg-b` 各只有一个 peer，AllowedIPs 只包含对应远端 overlay `/32`，endpoint 固定到对应 `10.203.*` 链路，握手时间不超过 180 秒。
- 四张 underlay 数据网卡都有 `inbound.average=12500` 和 `outbound.average=12500` KiB/s，约等于 100 Mbit/s。
- 两个普通 TCP 单流都严格绑定各自 tunnel，吞吐在 70-115 Mbit/s，另一条 tunnel/underlay 仅允许 2 MiB 背景噪声。
- iperf3 数据连接对应的单个 MPTCP meta socket 初始四元组使用 `10.204.1.*`，达到 `subflows_total=2`；两条 WireGuard 及对应 underlay 都有显著 TX 增量。
- MPTCP 单流至少 150 Mbit/s，且至少为较快单 tunnel 基线的 1.5 倍；测试期间 fallback 计数不增加。

所有生命周期命令都持有项目锁，并以规范化 libvirt URI、pool UUID/path、resource UUID、bridge 和 MAC 校验归属。`destroy` 不会仅凭名称删除资源；若资源来自旧脚本且缺少 `.lab/ownership.json`，需人工确认后显式运行 `make adopt`。
