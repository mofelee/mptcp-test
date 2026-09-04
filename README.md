# Debian 13 MPTCP 双链路实验

这个实验使用 `virsh-test-host` 创建两台一次性 Debian 13 虚拟机，再由 DebianForm 完成虚拟机内配置。两条数据链路在 libvirt 层分别双向限速为 100 Mbit/s；一条独立 NAT 管理链路只用于 SSH，不注册为 MPTCP endpoint，也不承载吞吐测试。

```text
                           link-a: 100 Mbit/s
                    10.203.1.1/30 ---------------- 10.203.1.2/30
                   +--------------+                +--------------+
default NAT (SSH) -| mptcp-client |                | mptcp-server |- default NAT (SSH)
                   +--------------+                +--------------+
                    10.203.2.1/30 ---------------- 10.203.2.2/30
                           link-b: 100 Mbit/s
```

服务端只通告 link-b 的地址。客户端从 link-a 发起连接，收到 `ADD_ADDR` 后由内核 path manager 建立 link-b 子流，因此一个 MPTCP/iperf3 流可以同时使用两条路径。预期两个普通 TCP 基线各约 90-100 Mbit/s，MPTCP 聚合约 180-200 Mbit/s。

## 运行

环境默认使用：

- libvirt URI：`qemu+ssh://ks/system`
- storage pool：`vm`
- management network：`default`
- DebianForm 源码：`/root/debianform`（当前要求 v0.11.0 DSL）

```bash
make up       # 创建拓扑、应用 DebianForm、完成验证
make status   # 查看 VM、网卡限速、地址和 MPTCP endpoint
make verify   # 重跑双单链路基线与 MPTCP 聚合测试
make apply    # 重跑 DebianForm plan/apply/check
make destroy  # 只删除本实验精确命名的 VM、磁盘和网络
```

实验运行后可直接进入两端：

```bash
ssh -F .lab/ssh_config mptcp-client
ssh -F .lab/ssh_config mptcp-server
```

测试 JSON 和诊断文件写入 `artifacts/<UTC timestamp>/`。运行期 SSH 配置、资源所有权清单和构建出的 `dbf` 放在 `.lab/`，这些内容均不提交。所有生命周期命令通过项目锁串行执行。

可以通过环境变量覆盖 `DBF_LIBVIRT_URI`、`DBF_TEST_HYPERVISOR`、`DBF_TEST_POOL`、`DBF_TEST_NETWORK`、`DBF_TEST_SSH_PRIVATE_KEY_FILE` 和 `DEBIANFORM_SOURCE`。资源名与实验 MAC/IP 固定；脚本以规范化 URI、pool UUID/path 和资源 UUID 校验所有权，不会仅凭名称复用或删除资源。

若资源由旧版脚本创建但尚无 `.lab/ownership.json`，先人工确认它们确属本实验，再运行一次 `make adopt`。这是唯一允许接管无清单固定名称资源的显式操作。

## 验收条件

- 两台 guest 均为 Debian 13，并启用内核 MPTCP。
- 四张数据网卡在 libvirt 中都有 `inbound.average=12500` 和 `outbound.average=12500` KB/s。
- link-a 与 link-b 的普通 TCP 单流都在 70-115 Mbit/s。
- iperf3 数据连接对应的单个 MPTCP meta socket 达到 `subflows_total=2`，两张客户端数据网卡都有显著 TX 字节增量，并出现新的 `MP_JOIN`。
- MPTCP 单流至少 150 Mbit/s，且至少达到较快单链路基线的 1.5 倍。
- 测试期间 `MPTcpExtMPCapableFallback*` 计数不增加。
