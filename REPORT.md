# Debian 13 双 WireGuard 链路上的 MPTCP 实验报告

实验日期：2026-09-04（UTC）

## 1. 结论

实验通过。两条各自受限为约 100 Mbit/s 的 virtio 链路现在作为独立 WireGuard underlay，iperf 和 MPTCP 数据面只使用 `10.204.*` tunnel 地址。本次最终单次测量中：

- `wg-a` 普通 TCP：91.49 Mbit/s
- `wg-b` 普通 TCP：91.49 Mbit/s
- 单个 MPTCP 流：179.58 Mbit/s
- 相对较快单 tunnel 的聚合增益：1.96x
- 数据 meta socket：`subflows_total=2`
- MPTCP fallback：0

这说明 MPTCP 在两条 WireGuard tunnel 上同时传输，获得了接近两条单链路之和的吞吐。相对改造前的历史直连单次参考，WireGuard 模式的 MPTCP 吞吐低 9.09 Mbit/s（-4.82%）；该差值是本实验两次运行的观测差异，不能单独解释为 WireGuard 的精确加密开销。

## 2. 拓扑与边界

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

管理网 `192.168.122.0/24` 只承载 SSH。`10.203.1.0/30` 和 `10.203.2.0/30` 只承载 WireGuard UDP 外层报文；MPTCP 初始连接和附加子流都使用 `10.204.*`。

本实验是同一台 libvirt hypervisor 上的两台 VM 和两条逻辑隔离链路，不等同于两条独立物理 WAN。每个 VM 为 2 vCPU、1 GiB RAM；四张数据 NIC 均由 libvirt 设置 `inbound.average=12500`、`outbound.average=12500` KiB/s，约等于 100 Mbit/s。

## 3. 软件与配置

| 项目 | 值 |
| --- | --- |
| Guest | Debian 13 (trixie), amd64 |
| Kernel | `6.12.100+deb13-cloud-amd64` |
| DebianForm | v0.11.0, commit `64b8f9b28d27` |
| WireGuard tools | `v1.0.20210914` |
| iperf3 | `3.18` |
| libvirt URI | `qemu+ssh://ks/system` |
| VM | `dbf-test-mptcp-client`, `dbf-test-mptcp-server` |

每条 tunnel 使用独立 client/server 密钥对，共四个测试私钥：

| Tunnel | Client overlay | Server overlay | Client peer endpoint | Server peer endpoint | MTU |
| --- | --- | --- | --- | --- | ---: |
| `wg-a` | `10.204.1.1/30` | `10.204.1.2/30` | `10.203.1.2:51820` | `10.203.1.1:51820` | 1420 |
| `wg-b` | `10.204.2.1/30` | `10.204.2.2/30` | `10.203.2.2:51821` | `10.203.2.1:51821` | 1420 |

每个 peer 的 `AllowedIPs` 只有对端 overlay `/32`，`RouteTable=off`。两条 connected overlay route 分别指向 `wg-a` 和 `wg-b`；两个 UDP endpoint 的 connected underlay route 分别指向 MAC `52:54:00:ca:01:01` 的 `enp5s0` 和 MAC `52:54:00:cb:01:01` 的 `enp6s0`。

私钥只存在于被 Git 忽略的 `.lab/wireguard/` 和 guest `/etc/wireguard/`，不会写入 HCL、var-file、plan、state 或实验 artifact。DebianForm 用 sensitive file source 部署私钥，networkd 通过 `PrivateKeyFile` 读取。

## 4. 方法

普通 TCP 基线分别运行：

```text
iperf3 -c <peer-overlay> -B <local-overlay>%<wg-interface> -p 5201 -P 1 -t 20 -O 2 -J
```

绑定 overlay 地址和设备可确保每次基线只走指定 tunnel。测试同时比较两条 WireGuard peer TX 计数和两张 underlay NIC TX 计数；选中路径至少承载 iperf payload 的 80%，未选路径允许最多 2 MiB 的 keepalive、ARP 等背景噪声。

MPTCP 聚合测试运行：

```text
mptcpize run iperf3 -c 10.204.1.2 -p 5202 -P 1 -t 30 -O 3 -J
```

这里不使用 `SO_BINDTODEVICE`，避免把整个 MPTCP meta socket 限制在 `wg-a`。服务端只通告 `10.204.2.2 id 2 signal dev wg-b`；客户端允许一个附加 subflow。验收同时采样精确 iperf 数据四元组对应的 `ss -MnOi` meta socket、WireGuard transfer、underlay NIC、`MP_JOIN` 和 fallback 计数。

所有吞吐值取 iperf JSON 的发送端 `end.sum_sent.bits_per_second`。本次吞吐测试方向均为 client-to-server；libvirt 的限速为双向，但没有运行反向或双向并发吞吐测试。直连参考和 WireGuard 结果都是顺序执行的单次运行，不是多轮统计均值。

## 5. 结果

| 模式 | TCP A | TCP B | MPTCP | 模式内增益 | MPTCP / (A+B) | 子流 | fallback |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 历史直连参考 | 96.05 | 95.58 | 188.67 Mbit/s | 1.96x | 98.46% | 2 | +0 |
| WireGuard | 91.49 | 91.49 | 179.58 Mbit/s | 1.96x | 98.15% | 2 | +0 |

| 指标 | WireGuard - 直连 | 相对变化 |
| --- | ---: | ---: |
| TCP A | -4.56 Mbit/s | -4.75% |
| TCP B | -4.09 Mbit/s | -4.28% |
| MPTCP | -9.09 Mbit/s | -4.82% |

发送端重传计数本次为 A/B/MPTCP = `24/23/40`，历史直连参考为 `1715/1703/599`。两次运行的宿主负载和网络时序不同，因此只能记录这个现象，不能据此声称 WireGuard 降低了重传。

## 6. MPTCP 与路径证据

WireGuard 模式的数据 meta socket：

```text
10.204.1.1:36504 -> 10.204.1.2:5202
token: d9c3dbe1
subflows_total: 2
sampled bytes_sent: 426449133
```

客户端主机全局 `MPTcpExtMPJoinSynTx` 在测试期间增加 2，两个 `MPTcpExtMPCapableFallback*` 计数之和不变。`MP_JOIN +2` 也可能包含同阶段其他 MPTCP socket，只作为辅助证据；精确数据 socket 的 `subflows_total=2` 才是核心证明。

MPTCP 阶段发送计数：

| 层 | A 路径 | B 路径 | A/B 占比 |
| --- | ---: | ---: | ---: |
| WireGuard peer TX | 401,121,208 B | 401,121,248 B | 50.0000% / 50.0000% |
| underlay NIC TX | 412,822,996 B | 412,826,816 B | 49.9998% / 50.0002% |

外层计数高于 tunnel peer 计数符合 UDP/IP 封装开销预期。两条路径均远高于验收下限 67,344,793 B，且 underlay 接口已通过 MAC 映射到对应的 libvirt 100 Mbit/s 限速项。

普通 TCP 路径隔离也通过：A 基线期间 `wg-a/enp5s0` 增加约 267/275 MB，`wg-b/enp6s0` 仅增加 0/42 B；B 基线期间 `wg-b/enp6s0` 增加约 267/275 MB，`wg-a/enp5s0` 仅增加 124/250 B。

## 7. 与直连参考的解释

WireGuard 单 tunnel 吞吐下降约 4.3%-4.8%，双 tunnel MPTCP 下降约 4.9%，但模式内聚合比例几乎不变：两种模式都约为较快单链路的 1.96 倍。就本次实验而言，隧道并未妨碍 MPTCP 同时利用两条路径。

不能把 -4.82% 直接称为加密开销。该差值同时包含 WireGuard 封装与加密、MTU 从 1500 降到 1420、TCP 重传、VM 调度、hypervisor 负载和两次测试时序差异。要估算可推广的 overhead，需要交替运行 direct/WireGuard、多轮重复，报告均值、标准差、CPU 使用率和置信区间。

## 8. 收敛与密钥轮换

对 client `wg-a` 做过一次真实私钥轮换。`artifacts/20260904T065116Z-apply/` 显示 DebianForm 更新一个 sensitive 私钥文件及 server peer 配置，执行 3 个声明式 activation；随后 check 回到 `50 no-op / 0 operations`。最终验收又逐一比较本地推导公钥、两端 interface 公钥和唯一 peer 公钥，并要求握手不超过 180 秒，因此轮换后的 tunnel 身份和连通性均已闭环验证。

最终 no-op apply 位于 `artifacts/20260904T070008Z-apply/`，plan、apply、check 均为 `No changes` 和 `50 no-op / 0 operations`。同目录的 `service-activation-timestamps.txt` 记录了 apply 前后 client 的 `mptcp-lab-setup.service` 激活时间均为 `4015648929`，server 均为 `4009911955`，证明无配置变化时不会额外 reload、reconfigure 或重启服务。

最终验收 artifact 记录的配置 SHA-256 与工作区一致：

```text
c5a98bcef7b823e4a65d132aefe9cbe65f3e036ffafaf5e0b53aabaeee6c5942  lab.dbf.hcl
49f8f9e3abbc4a3e70ae94361714db643a932e630089962ef3407fd609dec245  scripts/lab.sh
```

## 9. 复现

```bash
cd /root/mptcp-test
make up
make status
make verify
```

进入 guest：

```bash
ssh -F .lab/ssh_config mptcp-client
ssh -F .lab/ssh_config mptcp-server
```

实验结束后如需删除：

```bash
make destroy
```

本报告交付时 VM 和两个 libvirt underlay network 保持运行，便于复核。`destroy` 会先核对 URI、pool、UUID、bridge、MAC 和精确磁盘路径，再删除本实验资源。

## 10. 证据索引

- DebianForm 初次收敛：`artifacts/20260904T064322Z-apply/`
- client `wg-a` 私钥轮换：`artifacts/20260904T065116Z-apply/`
- 当前配置幂等重跑：`artifacts/20260904T070008Z-apply/`
- 当前配置 WireGuard 验收：`artifacts/20260904T070036Z-verify/`
- 历史直连参考：`artifacts/20260904T062057Z-verify/`

关键文件包括 `summary.txt`、三个 iperf JSON、`mptcp-data-meta.json`、`mptcp-meta-samples.txt`、`client-link-tx-bytes.txt`、两个 baseline isolation 文件、四个 `domiftune` 文件、路由/MAC 快照和脱敏 WireGuard 快照。`artifacts/` 被 Git 忽略，属于本机实验记录，不是公开远端归档；本报告内嵌了复核结论所需的核心数值。
