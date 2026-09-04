#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/.lab"
ARTIFACT_ROOT="$ROOT_DIR/artifacts"
SSH_CONFIG="$RUNTIME_DIR/ssh_config"
KNOWN_HOSTS="$RUNTIME_DIR/known_hosts"
DBF_HOME="$RUNTIME_DIR/home"
OWNERSHIP_FILE="$RUNTIME_DIR/ownership.json"
LOCK_FILE="$ROOT_DIR/.mptcp-lab.lock"
WIREGUARD_DIR="$RUNTIME_DIR/wireguard"
WIREGUARD_VAR_FILE="$WIREGUARD_DIR/public-keys.dbfvars.json"

SKILL_SCRIPT="${VIRSH_TEST_HOST_SCRIPT:-/root/.codex/skills/virsh-test-host/scripts/virsh-test-host.sh}"
LIBVIRT_URI="${DBF_LIBVIRT_URI:-${VIRSH_DEFAULT_CONNECT_URI:-${LIBVIRT_DEFAULT_URI:-}}}"
POOL="${DBF_TEST_POOL:-vm}"
MANAGEMENT_NETWORK="${DBF_TEST_NETWORK:-default}"
HYPERVISOR="${DBF_TEST_HYPERVISOR:-}"
DEBIANFORM_SOURCE="${DEBIANFORM_SOURCE:-/root/debianform}"
USER_SSH_CONFIG="${DBF_TEST_USER_SSH_CONFIG:-/root/.ssh/config}"

CLIENT_VM="dbf-test-mptcp-client"
SERVER_VM="dbf-test-mptcp-server"
LINK_A_NETWORK="dbf-test-mptcp-link-a"
LINK_B_NETWORK="dbf-test-mptcp-link-b"
LINK_A_BRIDGE="dbf-mptcp-a"
LINK_B_BRIDGE="dbf-mptcp-b"
CLIENT_LINK_A_MAC="52:54:00:ca:01:01"
CLIENT_LINK_B_MAC="52:54:00:cb:01:01"
SERVER_LINK_A_MAC="52:54:00:ca:02:01"
SERVER_LINK_B_MAC="52:54:00:cb:02:01"
BANDWIDTH="12500,12500,1250"
BANDWIDTH_AVERAGE="12500"
CLIENT_UNDERLAY_A="10.203.1.1"
SERVER_UNDERLAY_A="10.203.1.2"
CLIENT_UNDERLAY_B="10.203.2.1"
SERVER_UNDERLAY_B="10.203.2.2"
CLIENT_WG_A="10.204.1.1"
SERVER_WG_A="10.204.1.2"
CLIENT_WG_B="10.204.2.1"
SERVER_WG_B="10.204.2.2"
WG_A_INTERFACE="wg-a"
WG_B_INTERFACE="wg-b"
CLIENT_RESTART_REQUIRED=0
SERVER_RESTART_REQUIRED=0
CANONICAL_URI=""
POOL_UUID=""
POOL_TARGET_PATH=""
MANAGEMENT_NETWORK_UUID=""
VERIFY_PID=""
MEASURED_BASELINE_BPS=""

log() {
  printf '[mptcp-lab] %s\n' "$*"
}

die() {
  printf '[mptcp-lab] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

virsh_cmd() {
  virsh --connect "$LIBVIRT_URI" "$@"
}

infer_hypervisor() {
  python3 - "$LIBVIRT_URI" <<'PY'
import sys
from urllib.parse import urlparse

uri = urlparse(sys.argv[1])
if uri.scheme in {"qemu+ssh", "qemu+libssh", "qemu+libssh2"} and uri.hostname:
    value = uri.hostname
    if uri.username:
        value = f"{uri.username}@{value}"
    print(value)
PY
}

remote_exec() {
  if [[ -n "$HYPERVISOR" ]]; then
    local remote_command
    remote_command="$(python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "$@")"
    ssh -- "$HYPERVISOR" "$remote_command"
  else
    "$@"
  fi
}

pool_path() {
  virsh_cmd pool-dumpxml "$POOL" | python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
path = root.findtext("./target/path")
if not path:
    raise SystemExit("pool target path not found")
print(path)
'
}

private_key_file() {
  if [[ -n "${DBF_TEST_SSH_PRIVATE_KEY_FILE:-}" ]]; then
    printf '%s\n' "$DBF_TEST_SSH_PRIVATE_KEY_FILE"
  elif [[ -f /root/.ssh/id_ed25519 ]]; then
    printf '%s\n' /root/.ssh/id_ed25519
  elif [[ -f /root/.ssh/id_rsa ]]; then
    printf '%s\n' /root/.ssh/id_rsa
  else
    die "set DBF_TEST_SSH_PRIVATE_KEY_FILE"
  fi
}

ensure_wireguard_private_key() {
  local path=$1
  local temporary
  [[ ! -L "$path" ]] || die "refusing symlinked WireGuard private key: $path"
  if [[ ! -e "$path" ]]; then
    temporary="$(mktemp "$WIREGUARD_DIR/.private-key.XXXXXX")"
    chmod 0600 "$temporary"
    if ! wg genkey >"$temporary"; then
      rm -f -- "$temporary"
      die "failed to generate WireGuard private key"
    fi
    mv -- "$temporary" "$path"
  fi
  [[ -f "$path" && ! -L "$path" ]] || die "invalid WireGuard private key path: $path"
  chmod 0600 "$path"
  wg pubkey <"$path" >/dev/null || die "invalid WireGuard private key: $path"
}

wireguard_public_key() {
  local path=$1
  local public_key
  public_key="$(wg pubkey <"$path")" || die "failed to derive WireGuard public key"
  [[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "invalid derived WireGuard public key"
  printf '%s\n' "$public_key"
}

ensure_wireguard_keys() {
  local client_a_public client_b_public server_a_public server_b_public
  require_command wg
  [[ ! -L "$WIREGUARD_DIR" && ! -L "$WIREGUARD_VAR_FILE" ]] || \
    die "refusing symlinked WireGuard runtime path"
  mkdir -p "$WIREGUARD_DIR"
  chmod 0700 "$WIREGUARD_DIR"

  ensure_wireguard_private_key "$WIREGUARD_DIR/client-wg-a.key"
  ensure_wireguard_private_key "$WIREGUARD_DIR/client-wg-b.key"
  ensure_wireguard_private_key "$WIREGUARD_DIR/server-wg-a.key"
  ensure_wireguard_private_key "$WIREGUARD_DIR/server-wg-b.key"
  client_a_public="$(wireguard_public_key "$WIREGUARD_DIR/client-wg-a.key")"
  client_b_public="$(wireguard_public_key "$WIREGUARD_DIR/client-wg-b.key")"
  server_a_public="$(wireguard_public_key "$WIREGUARD_DIR/server-wg-a.key")"
  server_b_public="$(wireguard_public_key "$WIREGUARD_DIR/server-wg-b.key")"

  python3 - "$WIREGUARD_VAR_FILE" \
    "$client_a_public" "$client_b_public" "$server_a_public" "$server_b_public" <<'PY'
import json
import os
import sys

path, client_a, client_b, server_a, server_b = sys.argv[1:]
payload = {
    "client_wg_a_public_key": client_a,
    "client_wg_b_public_key": client_b,
    "server_wg_a_public_key": server_a,
    "server_wg_b_public_key": server_b,
}
temporary = f"{path}.tmp.{os.getpid()}"
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
fd = os.open(temporary, flags, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
  chmod 0600 "$WIREGUARD_VAR_FILE"
  log "WireGuard test keys are ready in the ignored runtime directory"
}

validate_environment() {
  local access_mode uri_hypervisor
  require_command virsh
  require_command ssh
  require_command python3
  require_command flock
  [[ -n "$LIBVIRT_URI" ]] || die "set DBF_LIBVIRT_URI or LIBVIRT_DEFAULT_URI"
  [[ ! -L "$RUNTIME_DIR" && ! -L "$OWNERSHIP_FILE" ]] || die "refusing symlinked lab runtime or ownership path"
  [[ "$CLIENT_VM" == dbf-test-* && "$SERVER_VM" == dbf-test-* ]] || die "unsafe VM name"
  [[ "$LINK_A_NETWORK" == dbf-test-* && "$LINK_B_NETWORK" == dbf-test-* ]] || die "unsafe network name"

  access_mode="$(python3 - "$LIBVIRT_URI" <<'PY'
import sys
from urllib.parse import urlparse

uri = urlparse(sys.argv[1])
if uri.query or uri.fragment:
    raise SystemExit(f"URI options are not supported: {sys.argv[1]}")
if uri.scheme == "qemu" and not uri.netloc and uri.path == "/system":
    print("local")
elif uri.scheme == "qemu+ssh" and uri.hostname and uri.path == "/system" and uri.port is None:
    print("ssh")
else:
    raise SystemExit(f"unsupported libvirt URI for VM filesystem access: {sys.argv[1]}")
PY
  )" || die "use local qemu or an SSH-backed qemu URI"
  if [[ "$access_mode" == "ssh" ]]; then
    uri_hypervisor="$(infer_hypervisor)"
    if [[ -n "$HYPERVISOR" && "$HYPERVISOR" != "$uri_hypervisor" ]]; then
      die "DBF_TEST_HYPERVISOR must match the libvirt URI host: $uri_hypervisor"
    fi
    HYPERVISOR="$uri_hypervisor"
  elif [[ "$access_mode" == "local" && -n "$HYPERVISOR" ]]; then
    die "DBF_TEST_HYPERVISOR must be empty for local libvirt URI $LIBVIRT_URI"
  fi
  if [[ -n "$HYPERVISOR" && ! "$HYPERVISOR" =~ ^[A-Za-z0-9][A-Za-z0-9._:@-]*$ ]]; then
    die "unsafe or unsupported hypervisor SSH destination: $HYPERVISOR"
  fi
  CANONICAL_URI="$(virsh_cmd uri)"
  POOL_UUID="$(virsh_cmd pool-uuid "$POOL")" || die "storage pool not found: $POOL"
  POOL_TARGET_PATH="$(pool_path)"
  [[ "$POOL_TARGET_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$POOL_TARGET_PATH" != "/" ]] || \
    die "unsafe or unsupported storage pool path: $POOL_TARGET_PATH"
  MANAGEMENT_NETWORK_UUID="$(virsh_cmd net-uuid "$MANAGEMENT_NETWORK" 2>/dev/null || true)"
}

acquire_lock() {
  exec 9>>"$LOCK_FILE"
  flock -n 9 || die "another mptcp lab command is already running"
}

manifest_tool() {
  local operation=$1
  shift
  python3 - "$OWNERSHIP_FILE" "$operation" "$@" <<'PY'
import json
import os
import sys
import uuid

path, operation, *args = sys.argv[1:]
domain_names = {"dbf-test-mptcp-client", "dbf-test-mptcp-server"}
network_bridges = {
    "dbf-test-mptcp-link-a": "dbf-mptcp-a",
    "dbf-test-mptcp-link-b": "dbf-mptcp-b",
}

def valid_uuid(value):
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False

def validate(data):
    if not isinstance(data, dict):
        raise ValueError("ownership manifest must be a JSON object")
    expected_keys = {
        "version", "libvirt_uri", "pool", "pool_uuid", "pool_path",
        "management_network", "management_network_uuid", "domains", "networks",
    }
    if set(data) != expected_keys or data.get("version") != 1:
        raise ValueError("ownership manifest has an unsupported schema")
    for field in ("libvirt_uri", "pool", "pool_path", "management_network"):
        if not isinstance(data.get(field), str) or not data[field]:
            raise ValueError(f"ownership field {field} must be a non-empty string")
    for field in ("pool_uuid", "management_network_uuid"):
        if not valid_uuid(data.get(field)):
            raise ValueError(f"ownership field {field} must be a canonical UUID")
    domains = data.get("domains")
    if not isinstance(domains, dict) or not set(domains).issubset(domain_names):
        raise ValueError("ownership domains contain invalid resource names")
    for name, value in domains.items():
        if value != "pending" and not valid_uuid(value):
            raise ValueError(f"ownership domain {name} must be pending or a canonical UUID")
    networks = data.get("networks")
    if not isinstance(networks, dict) or not set(networks).issubset(network_bridges):
        raise ValueError("ownership networks contain invalid resource names")
    for name, value in networks.items():
        if not isinstance(value, dict) or set(value) != {"uuid", "bridge"}:
            raise ValueError(f"ownership network {name} has an invalid record")
        if not valid_uuid(value.get("uuid")) or value.get("bridge") != network_bridges[name]:
            raise ValueError(f"ownership network {name} has an invalid identity")

def load():
    with open(path, encoding="utf-8") as stream:
        data = json.load(stream)
    validate(data)
    return data

def write(data):
    validate(data)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = f"{path}.tmp.{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)

if operation == "init":
    uri, pool, pool_uuid, pool_path, management_network, management_network_uuid = args
    if os.path.exists(path):
        raise SystemExit("ownership manifest already exists")
    write({
        "version": 1,
        "libvirt_uri": uri,
        "pool": pool,
        "pool_uuid": pool_uuid,
        "pool_path": pool_path,
        "management_network": management_network,
        "management_network_uuid": management_network_uuid,
        "domains": {},
        "networks": {},
    })
elif operation == "context":
    uri, pool, pool_uuid, pool_path, management_network, management_network_uuid = args
    data = load()
    expected = (1, uri, pool, pool_uuid, pool_path, management_network, management_network_uuid)
    actual = (
        data.get("version"),
        data.get("libvirt_uri"),
        data.get("pool"),
        data.get("pool_uuid"),
        data.get("pool_path"),
        data.get("management_network"),
        data.get("management_network_uuid"),
    )
    if actual != expected:
        raise SystemExit(f"ownership context mismatch: recorded={actual!r} selected={expected!r}")
elif operation == "destroy-context":
    uri, pool, pool_uuid, pool_path = args
    data = load()
    expected = (1, uri, pool, pool_uuid, pool_path)
    actual = (
        data.get("version"),
        data.get("libvirt_uri"),
        data.get("pool"),
        data.get("pool_uuid"),
        data.get("pool_path"),
    )
    if actual != expected:
        raise SystemExit(f"ownership destroy context mismatch: recorded={actual!r} selected={expected!r}")
elif operation == "get-domain":
    print(load().get("domains", {}).get(args[0], ""))
elif operation == "get-network-uuid":
    print(load().get("networks", {}).get(args[0], {}).get("uuid", ""))
elif operation == "get-network-bridge":
    print(load().get("networks", {}).get(args[0], {}).get("bridge", ""))
elif operation == "record-domain":
    name, uuid = args
    data = load()
    data.setdefault("domains", {})[name] = uuid
    write(data)
elif operation == "record-network":
    name, uuid, bridge = args
    data = load()
    data.setdefault("networks", {})[name] = {"uuid": uuid, "bridge": bridge}
    write(data)
else:
    raise SystemExit(f"unknown manifest operation: {operation}")
PY
}

assert_manifest_context() {
  [[ -f "$OWNERSHIP_FILE" ]] || die "ownership manifest is missing; refusing to use fixed-name resources"
  manifest_tool context \
    "$CANONICAL_URI" "$POOL" "$POOL_UUID" "$POOL_TARGET_PATH" \
    "$MANAGEMENT_NETWORK" "$MANAGEMENT_NETWORK_UUID" || \
    die "ownership manifest does not match the selected libvirt environment"
}

assert_manifest_destroy_context() {
  [[ -f "$OWNERSHIP_FILE" ]] || die "ownership manifest is missing; refusing to destroy fixed-name resources"
  manifest_tool destroy-context "$CANONICAL_URI" "$POOL" "$POOL_UUID" "$POOL_TARGET_PATH" || \
    die "ownership manifest does not match the selected libvirt storage environment"
}

assert_owned_domain() {
  local name=$1
  local expected actual
  expected="$(manifest_tool get-domain "$name")"
  [[ -n "$expected" ]] || die "domain is not recorded as owned: $name"
  actual="$(virsh_cmd domuuid "$name" 2>/dev/null)" || die "owned domain is missing: $name"
  [[ "$actual" == "$expected" ]] || die "domain UUID mismatch for $name; refusing to modify it"
}

assert_owned_network() {
  local name=$1
  local expected_uuid expected_bridge actual_uuid actual_bridge
  expected_uuid="$(manifest_tool get-network-uuid "$name")"
  expected_bridge="$(manifest_tool get-network-bridge "$name")"
  [[ -n "$expected_uuid" && -n "$expected_bridge" ]] || die "network is not recorded as owned: $name"
  actual_uuid="$(virsh_cmd net-uuid "$name" 2>/dev/null)" || die "owned network is missing: $name"
  actual_bridge="$(network_bridge "$name")"
  [[ "$actual_uuid" == "$expected_uuid" && "$actual_bridge" == "$expected_bridge" ]] || \
    die "network identity mismatch for $name; refusing to modify it"
}

assert_complete_ownership() {
  assert_manifest_context
  assert_owned_domain "$CLIENT_VM"
  assert_owned_domain "$SERVER_VM"
  assert_owned_network "$LINK_A_NETWORK"
  assert_owned_network "$LINK_B_NETWORK"
}

domain_paths_exist() {
  local name=$1
  local path status
  for path in \
    "$POOL_TARGET_PATH/$name.qcow2" \
    "$POOL_TARGET_PATH/$name-seed.img" \
    "$POOL_TARGET_PATH/$name-console.log" \
    "$POOL_TARGET_PATH/.dbf-test-$name"; do
    if remote_exec test -e "$path"; then
      return 0
    else
      status=$?
      (( status == 1 )) || return 2
    fi
  done
  return 1
}

prepare_up_ownership() {
  [[ -n "$MANAGEMENT_NETWORK_UUID" ]] || die "management network not found: $MANAGEMENT_NETWORK"
  mkdir -p "$RUNTIME_DIR"
  if [[ -f "$OWNERSHIP_FILE" ]]; then
    assert_manifest_context
    return
  fi
  if virsh_cmd dominfo "$CLIENT_VM" >/dev/null 2>&1 || \
     virsh_cmd dominfo "$SERVER_VM" >/dev/null 2>&1 || \
     virsh_cmd net-info "$LINK_A_NETWORK" >/dev/null 2>&1 || \
     virsh_cmd net-info "$LINK_B_NETWORK" >/dev/null 2>&1; then
    die "fixed-name resources already exist without ownership proof; run '$0 adopt' only if they belong to this lab"
  fi
  for name in "$CLIENT_VM" "$SERVER_VM"; do
    if domain_paths_exist "$name"; then
      die "unclaimed VM files already exist for $name; refusing to overwrite them"
    else
      case $? in
        1) ;;
        *) die "could not verify VM file absence for $name" ;;
      esac
    fi
  done
  manifest_tool init \
    "$CANONICAL_URI" "$POOL" "$POOL_UUID" "$POOL_TARGET_PATH" \
    "$MANAGEMENT_NETWORK" "$MANAGEMENT_NETWORK_UUID"
}

print_selection() {
  log "libvirt URI: $LIBVIRT_URI"
  log "hypervisor: ${HYPERVISOR:-local}"
  log "pool: $POOL"
  log "management network: $MANAGEMENT_NETWORK"
  log "domains: $CLIENT_VM, $SERVER_VM"
  log "WireGuard underlay networks: $LINK_A_NETWORK, $LINK_B_NETWORK"
  log "per-interface limit: 100 Mbit/s in each direction"
}

network_bridge() {
  virsh_cmd net-dumpxml "$1" | python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
bridge = root.find("bridge")
print(bridge.get("name", "") if bridge is not None else "")
'
}

ensure_network() {
  local name=$1
  local bridge=$2
  local active uuid xml
  if virsh_cmd net-info "$name" >/dev/null 2>&1; then
    assert_owned_network "$name"
    [[ "$(network_bridge "$name")" == "$bridge" ]] || die "network $name exists with an unexpected bridge"
    active="$(virsh_cmd net-info "$name" | awk '$1 == "Active:" { print $2 }')"
    [[ "$active" == "yes" ]] || virsh_cmd net-start "$name" >/dev/null
    log "network already present: $name"
    return
  fi

  if remote_exec ip link show "$bridge" >/dev/null 2>&1; then
    die "bridge $bridge already exists without network $name"
  fi

  xml="$(mktemp "${TMPDIR:-/tmp}/mptcp-network.XXXXXX.xml")"
  cat >"$xml" <<EOF
<network>
  <name>$name</name>
  <bridge name='$bridge' stp='off' delay='0'/>
</network>
EOF
  if ! virsh_cmd net-create "$xml" --validate >/dev/null; then
    rm -f "$xml"
    die "failed to create isolated network: $name"
  fi
  rm -f "$xml"
  uuid="$(virsh_cmd net-uuid "$name")"
  if ! manifest_tool record-network "$name" "$uuid" "$bridge"; then
    if ! virsh_cmd net-destroy "$uuid" >/dev/null; then
      die "ownership recording and rollback both failed for network: $name"
    fi
    die "failed to record ownership for network: $name"
  fi
  log "created isolated network: $name ($bridge)"
}

ensure_vm() {
  local name=$1
  local uuid previous path_usage_status candidate
  if virsh_cmd dominfo "$name" >/dev/null 2>&1; then
    previous="$(manifest_tool get-domain "$name")"
    if [[ "$previous" == "pending" ]]; then
      uuid="$(virsh_cmd domuuid "$name")"
      if [[ "$name" == "$CLIENT_VM" ]]; then
        validate_adoptable_domain "$name" "$uuid" "$CLIENT_LINK_A_MAC" "$CLIENT_LINK_B_MAC"
      else
        validate_adoptable_domain "$name" "$uuid" "$SERVER_LINK_A_MAC" "$SERVER_LINK_B_MAC"
      fi
      [[ "$(virsh_cmd domuuid "$name")" == "$uuid" ]] || die "domain changed while recovering pending ownership: $name"
      manifest_tool record-domain "$name" "$uuid"
      log "recovered pending ownership for domain: $name"
    fi
    assert_owned_domain "$name"
    if [[ "$(virsh_cmd domstate "$name" | tr -d '\r')" != "running" ]]; then
      virsh_cmd start "$name" >/dev/null
    fi
    log "domain already present: $name"
    return
  fi

  [[ -x "$SKILL_SCRIPT" ]] || die "virsh-test-host helper not found: $SKILL_SCRIPT"
  previous="$(manifest_tool get-domain "$name")"
  if [[ -z "$previous" ]]; then
    if domain_paths_exist "$name"; then
      die "unclaimed VM files already exist for $name; refusing to overwrite them"
    else
      case $? in
        1) ;;
        *) die "could not verify VM file absence for $name" ;;
      esac
    fi
  fi
  for candidate in \
    "$POOL_TARGET_PATH/$name.qcow2" \
    "$POOL_TARGET_PATH/$name-seed.img" \
    "$POOL_TARGET_PATH/$name-console.log"; do
    if path_used_by_another_domain "$candidate"; then
      die "expected VM path for $name is used by another domain: $candidate"
    else
      path_usage_status=$?
      (( path_usage_status == 1 )) || die "could not verify VM path ownership for $name"
    fi
  done
  manifest_tool record-domain "$name" pending
  if ! DBF_LIBVIRT_URI="$LIBVIRT_URI" \
    DBF_TEST_HYPERVISOR="$HYPERVISOR" \
    DBF_TEST_POOL="$POOL" \
    DBF_TEST_NETWORK="$MANAGEMENT_NETWORK" \
    DBF_TEST_NAME="$name" \
    DBF_TEST_MEMORY_MIB=1024 \
    DBF_TEST_VCPUS=2 \
    DBF_TEST_WAIT_IP_TIMEOUT=0 \
    "$SKILL_SCRIPT" create; then
    log "domain creation failed for $name; pending ownership was preserved for recovery"
    return 1
  fi
  uuid="$(virsh_cmd domuuid "$name")" || {
    log "domain was created but its UUID could not be recorded: $name"
    return 1
  }
  manifest_tool record-domain "$name" "$uuid"
}

validate_adoptable_domain() {
  local name=$1
  local expected_uuid=$2
  local link_a_mac=$3
  local link_b_mac=$4
  local expected_disk
  expected_disk="$(pool_path)/$name.qcow2"
  virsh_cmd dumpxml "$name" --inactive | python3 -c '
import sys
import xml.etree.ElementTree as ET

name, uuid, disk, management, mac_a, network_a, mac_b, network_b = sys.argv[1:]
root = ET.fromstring(sys.stdin.read())
if root.findtext("name") != name:
    raise SystemExit(f"unexpected domain name for {name}")
if root.findtext("uuid") != uuid:
    raise SystemExit(f"unexpected domain UUID for {name}")

disk_sources = {
    source.get("file")
    for source in root.findall("./devices/disk/source")
    if source.get("file")
}
if disk not in disk_sources:
    raise SystemExit(f"{name} does not use expected owned disk {disk}")

interfaces = {}
management_found = False
for interface in root.findall("./devices/interface"):
    mac_node = interface.find("mac")
    source_node = interface.find("source")
    mac = mac_node.get("address", "").lower() if mac_node is not None else ""
    source = source_node.get("network", "") if source_node is not None else ""
    if source == management:
        management_found = True
    if mac:
        interfaces[mac] = source
if not management_found:
    raise SystemExit(f"{name} has no interface on management network {management}")
for mac, expected in ((mac_a.lower(), network_a), (mac_b.lower(), network_b)):
    if mac in interfaces and interfaces[mac] != expected:
        raise SystemExit(f"{name} interface {mac} belongs to {interfaces[mac]}, expected {expected}")
' "$name" "$expected_uuid" "$expected_disk" "$MANAGEMENT_NETWORK" \
    "$link_a_mac" "$LINK_A_NETWORK" "$link_b_mac" "$LINK_B_NETWORK"
}

adopt_lab() {
  local found=0 recorded
  local link_a_uuid="" link_b_uuid="" client_uuid="" server_uuid=""
  [[ -n "$MANAGEMENT_NETWORK_UUID" ]] || die "management network not found: $MANAGEMENT_NETWORK"
  if [[ -f "$OWNERSHIP_FILE" ]]; then
    assert_manifest_context
  fi

  if virsh_cmd net-info "$LINK_A_NETWORK" >/dev/null 2>&1; then
    link_a_uuid="$(virsh_cmd net-uuid "$LINK_A_NETWORK")"
    [[ "$(network_bridge "$LINK_A_NETWORK")" == "$LINK_A_BRIDGE" ]] || die "unexpected bridge for $LINK_A_NETWORK"
    if [[ -f "$OWNERSHIP_FILE" ]]; then
      recorded="$(manifest_tool get-network-uuid "$LINK_A_NETWORK")"
      [[ -z "$recorded" || "$recorded" == "$link_a_uuid" ]] || die "recorded network UUID mismatch for $LINK_A_NETWORK"
    fi
    found=1
  fi
  if virsh_cmd net-info "$LINK_B_NETWORK" >/dev/null 2>&1; then
    link_b_uuid="$(virsh_cmd net-uuid "$LINK_B_NETWORK")"
    [[ "$(network_bridge "$LINK_B_NETWORK")" == "$LINK_B_BRIDGE" ]] || die "unexpected bridge for $LINK_B_NETWORK"
    if [[ -f "$OWNERSHIP_FILE" ]]; then
      recorded="$(manifest_tool get-network-uuid "$LINK_B_NETWORK")"
      [[ -z "$recorded" || "$recorded" == "$link_b_uuid" ]] || die "recorded network UUID mismatch for $LINK_B_NETWORK"
    fi
    found=1
  fi
  if virsh_cmd dominfo "$CLIENT_VM" >/dev/null 2>&1; then
    client_uuid="$(virsh_cmd domuuid "$CLIENT_VM")"
    if [[ -f "$OWNERSHIP_FILE" ]]; then
      recorded="$(manifest_tool get-domain "$CLIENT_VM")"
      [[ -z "$recorded" || "$recorded" == "pending" || "$recorded" == "$client_uuid" ]] || die "recorded domain UUID mismatch for $CLIENT_VM"
    fi
    validate_adoptable_domain "$CLIENT_VM" "$client_uuid" "$CLIENT_LINK_A_MAC" "$CLIENT_LINK_B_MAC"
    found=1
  fi
  if virsh_cmd dominfo "$SERVER_VM" >/dev/null 2>&1; then
    server_uuid="$(virsh_cmd domuuid "$SERVER_VM")"
    if [[ -f "$OWNERSHIP_FILE" ]]; then
      recorded="$(manifest_tool get-domain "$SERVER_VM")"
      [[ -z "$recorded" || "$recorded" == "pending" || "$recorded" == "$server_uuid" ]] || die "recorded domain UUID mismatch for $SERVER_VM"
    fi
    validate_adoptable_domain "$SERVER_VM" "$server_uuid" "$SERVER_LINK_A_MAC" "$SERVER_LINK_B_MAC"
    found=1
  fi
  (( found == 1 )) || die "no fixed-name lab resources exist; run '$0 up'"

  if [[ -n "$link_a_uuid" ]]; then
    [[ "$(virsh_cmd net-uuid "$LINK_A_NETWORK")" == "$link_a_uuid" ]] || die "$LINK_A_NETWORK changed during adoption"
    [[ "$(network_bridge "$LINK_A_NETWORK")" == "$LINK_A_BRIDGE" ]] || die "$LINK_A_NETWORK bridge changed during adoption"
  fi
  if [[ -n "$link_b_uuid" ]]; then
    [[ "$(virsh_cmd net-uuid "$LINK_B_NETWORK")" == "$link_b_uuid" ]] || die "$LINK_B_NETWORK changed during adoption"
    [[ "$(network_bridge "$LINK_B_NETWORK")" == "$LINK_B_BRIDGE" ]] || die "$LINK_B_NETWORK bridge changed during adoption"
  fi
  if [[ -n "$client_uuid" ]]; then
    [[ "$(virsh_cmd domuuid "$CLIENT_VM")" == "$client_uuid" ]] || die "$CLIENT_VM changed during adoption"
    validate_adoptable_domain "$CLIENT_VM" "$client_uuid" "$CLIENT_LINK_A_MAC" "$CLIENT_LINK_B_MAC"
  fi
  if [[ -n "$server_uuid" ]]; then
    [[ "$(virsh_cmd domuuid "$SERVER_VM")" == "$server_uuid" ]] || die "$SERVER_VM changed during adoption"
    validate_adoptable_domain "$SERVER_VM" "$server_uuid" "$SERVER_LINK_A_MAC" "$SERVER_LINK_B_MAC"
  fi

  if [[ ! -f "$OWNERSHIP_FILE" ]]; then
    manifest_tool init \
      "$CANONICAL_URI" "$POOL" "$POOL_UUID" "$POOL_TARGET_PATH" \
      "$MANAGEMENT_NETWORK" "$MANAGEMENT_NETWORK_UUID"
  fi
  [[ -z "$link_a_uuid" ]] || manifest_tool record-network "$LINK_A_NETWORK" "$link_a_uuid" "$LINK_A_BRIDGE"
  [[ -z "$link_b_uuid" ]] || manifest_tool record-network "$LINK_B_NETWORK" "$link_b_uuid" "$LINK_B_BRIDGE"
  [[ -z "$client_uuid" ]] || manifest_tool record-domain "$CLIENT_VM" "$client_uuid"
  [[ -z "$server_uuid" ]] || manifest_tool record-domain "$SERVER_VM" "$server_uuid"
  [[ -z "$link_a_uuid" ]] || assert_owned_network "$LINK_A_NETWORK"
  [[ -z "$link_b_uuid" ]] || assert_owned_network "$LINK_B_NETWORK"
  [[ -z "$client_uuid" ]] || assert_owned_domain "$CLIENT_VM"
  [[ -z "$server_uuid" ]] || assert_owned_domain "$SERVER_VM"
  log "adopted the inspected fixed-name resources into $OWNERSHIP_FILE"
  log "run '$0 up' to create or repair any missing topology"
}

ensure_data_interface() {
  local domain=$1
  local network=$2
  local mac=$3
  local alias=$4
  local config_source live_source
  config_source="$(virsh_cmd domiflist "$domain" --inactive | awk -v wanted="${mac,,}" 'tolower($5) == wanted { print $3; exit }')"
  if [[ -z "$config_source" ]]; then
    virsh_cmd attach-interface "$domain" network "$network" \
      --model virtio \
      --mac "$mac" \
      --alias "$alias" \
      --inbound "$BANDWIDTH" \
      --outbound "$BANDWIDTH" \
      --config >/dev/null
    if [[ "$domain" == "$CLIENT_VM" ]]; then
      CLIENT_RESTART_REQUIRED=1
    else
      SERVER_RESTART_REQUIRED=1
    fi
    log "added $domain $alias to its persistent configuration"
  else
    [[ "$config_source" == "$network" ]] || die "$domain interface $mac belongs to $config_source, expected $network"
  fi

  live_source="$(virsh_cmd domiflist "$domain" | awk -v wanted="${mac,,}" 'tolower($5) == wanted { print $3; exit }')"
  if [[ "$live_source" != "$network" ]]; then
    if [[ "$domain" == "$CLIENT_VM" ]]; then
      CLIENT_RESTART_REQUIRED=1
    else
      SERVER_RESTART_REQUIRED=1
    fi
  fi
}

restart_domain_for_topology() {
  local domain=$1
  local deadline
  if [[ "$(virsh_cmd domstate "$domain" | tr -d '\r')" == "running" ]]; then
    virsh_cmd shutdown "$domain" >/dev/null
    deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
      [[ "$(virsh_cmd domstate "$domain" | tr -d '\r')" == "shut off" ]] && break
      sleep 2
    done
    if [[ "$(virsh_cmd domstate "$domain" | tr -d '\r')" != "shut off" ]]; then
      log "graceful shutdown timed out for $domain; forcing this disposable lab VM off"
      virsh_cmd destroy "$domain" >/dev/null
    fi
  fi
  virsh_cmd start "$domain" >/dev/null
  log "restarted $domain with its complete three-interface topology"
}

apply_data_bandwidth() {
  local domain=$1
  local mac=$2
  virsh_cmd domiftune "$domain" "$mac" \
    --inbound "$BANDWIDTH" \
    --outbound "$BANDWIDTH" \
    --live --config >/dev/null
  log "rate-limited $domain $mac to 100 Mbit/s bidirectionally"
}

guest_ip() {
  DBF_LIBVIRT_URI="$LIBVIRT_URI" "$SKILL_SCRIPT" wait-ip "$1"
}

write_ssh_config() {
  local client_ip server_ip key proxy_line=""
  client_ip="$(guest_ip "$CLIENT_VM")" || die "no management address for $CLIENT_VM"
  server_ip="$(guest_ip "$SERVER_VM")" || die "no management address for $SERVER_VM"
  key="$(private_key_file)"
  mkdir -p "$RUNTIME_DIR" "$DBF_HOME"
  : >"$KNOWN_HOSTS"
  if [[ -n "$HYPERVISOR" ]]; then
    [[ -f "$USER_SSH_CONFIG" ]] || die "SSH config for hypervisor alias not found: $USER_SSH_CONFIG"
    proxy_line="  ProxyCommand ssh -F $USER_SSH_CONFIG -W %h:%p $HYPERVISOR"
  fi
  cat >"$SSH_CONFIG" <<EOF
Host mptcp-client
  HostName $client_ip
  User root
  IdentityFile $key
$proxy_line
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $KNOWN_HOSTS

Host mptcp-server
  HostName $server_ip
  User root
  IdentityFile $key
$proxy_line
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $KNOWN_HOSTS
EOF
  chmod 0600 "$SSH_CONFIG" "$KNOWN_HOSTS"
  log "client management address: $client_ip"
  log "server management address: $server_ip"
}

ssh_host() {
  local host=$1
  shift
  ssh -F "$SSH_CONFIG" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 \
    "$host" "$@"
}

wait_for_guest() {
  local alias=$1
  local deadline=$((SECONDS + 240))
  while (( SECONDS < deadline )); do
    if ssh_host "$alias" 'test -f /run/debianform-cloud-init-ready || cloud-init status --long | grep -q "^status: done$"' >/dev/null 2>&1; then
      log "guest ready: $alias"
      return
    fi
    sleep 3
  done
  die "guest did not become ready: $alias"
}

build_dbf() {
  local output="$RUNTIME_DIR/bin/dbf"
  if [[ -n "${DBF_BIN:-}" ]]; then
    [[ -x "$DBF_BIN" ]] || die "DBF_BIN is not executable: $DBF_BIN"
    printf '%s\n' "$DBF_BIN"
    return
  fi
  require_command make
  [[ -d "$DEBIANFORM_SOURCE/.git" ]] || die "DebianForm source not found: $DEBIANFORM_SOURCE"
  mkdir -p "$RUNTIME_DIR/bin"
  if ! GOCACHE="${GOCACHE:-/tmp/mptcp-test-go-cache}" \
    make -s -C "$DEBIANFORM_SOURCE" build BINARY="$output"; then
    die "failed to build DebianForm from $DEBIANFORM_SOURCE"
  fi
  printf '%s\n' "$output"
}

dbf_cmd() {
  local dbf_bin=$1
  shift
  HOME="$DBF_HOME" DBF_SSH_CONFIG="$SSH_CONFIG" "$dbf_bin" "$@"
}

refresh_access() {
  [[ -x "$SKILL_SCRIPT" ]] || die "virsh-test-host helper not found: $SKILL_SCRIPT"
  write_ssh_config
  wait_for_guest mptcp-client
  wait_for_guest mptcp-server
}

apply_lab() {
  local dbf_bin artifact_dir host key status
  assert_complete_ownership
  ensure_wireguard_keys
  refresh_access
  dbf_bin="$(build_dbf)"
  artifact_dir="$ARTIFACT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-apply"
  mkdir -p "$artifact_dir"
  "$dbf_bin" version | tee "$artifact_dir/dbf-version.txt"
  dbf_cmd "$dbf_bin" validate -f "$ROOT_DIR/lab.dbf.hcl" -var-file "$WIREGUARD_VAR_FILE"
  dbf_cmd "$dbf_bin" plan -f "$ROOT_DIR/lab.dbf.hcl" -var-file "$WIREGUARD_VAR_FILE" --color never | tee "$artifact_dir/plan.txt"
  dbf_cmd "$dbf_bin" apply -f "$ROOT_DIR/lab.dbf.hcl" -var-file "$WIREGUARD_VAR_FILE" --auto-approve --parallel 2 --color never | tee "$artifact_dir/apply.txt"
  dbf_cmd "$dbf_bin" check -f "$ROOT_DIR/lab.dbf.hcl" -var-file "$WIREGUARD_VAR_FILE" --color never | tee "$artifact_dir/check.txt"
  for key in "$WIREGUARD_DIR"/*.key; do
    if grep -R -F -q -f "$key" "$artifact_dir"; then
      die "a WireGuard private key leaked into DebianForm artifacts"
    fi
  done
  for host in mptcp-client mptcp-server; do
    for key in "$WIREGUARD_DIR"/*.key; do
      if ssh_host "$host" 'grep -R -F -q -f - /var/lib/debianform/state' <"$key"; then
        die "a WireGuard private key leaked into remote DebianForm state"
      else
        status=$?
        (( status == 1 )) || die "failed to scan remote DebianForm state for private-key leakage"
      fi
    done
  done
  log "DebianForm artifacts: $artifact_dir"
}

assert_guest() {
  local host=$1
  local description=$2
  local command=$3
  log "assert [$host]: $description"
  ssh_host "$host" "$command" >/dev/null || die "$description"
}

assert_bandwidth() {
  local domain=$1
  local mac=$2
  local artifact_file=$3
  local output inbound outbound
  output="$(virsh_cmd domiftune "$domain" "$mac")"
  printf '%s\n' "$output" >"$artifact_file"
  inbound="$(awk '$1 == "inbound.average:" { print $2 }' <<<"$output")"
  outbound="$(awk '$1 == "outbound.average:" { print $2 }' <<<"$output")"
  [[ "$inbound" == "$BANDWIDTH_AVERAGE" && "$outbound" == "$BANDWIDTH_AVERAGE" ]] || \
    die "$domain $mac is not limited to $BANDWIDTH_AVERAGE KB/s in both directions"
}

iperf_bits_per_second() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
if result.get("error"):
    raise SystemExit(result["error"])
print(int(result["end"]["sum_sent"]["bits_per_second"]))
PY
}

iperf_sent_bytes() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(int(json.load(stream)["end"]["sum_sent"]["bytes"]))
PY
}

assert_iperf_connection() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

path, expected_local, expected_remote = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    result = json.load(stream)
connections = result.get("start", {}).get("connected", [])
if len(connections) != 1:
    raise SystemExit(f"expected one iperf data connection, found {len(connections)}")
connection = connections[0]
observed = (str(connection.get("local_host")), str(connection.get("remote_host")))
expected = (expected_local, expected_remote)
if observed != expected:
    raise SystemExit(f"iperf data connection is {observed}, expected {expected}")
PY
}

extract_mptcp_data_meta() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import re
import sys
from pathlib import Path

iperf_path, samples_path, output_path = map(Path, sys.argv[1:4])
expected_local, expected_remote = sys.argv[4:6]
with iperf_path.open(encoding="utf-8") as stream:
    iperf = json.load(stream)
connections = iperf.get("start", {}).get("connected", [])
if len(connections) != 1:
    raise SystemExit(f"expected one iperf data connection, found {len(connections)}")
connection = connections[0]
observed_hosts = (str(connection["local_host"]), str(connection["remote_host"]))
if observed_hosts != (expected_local, expected_remote):
    raise SystemExit(
        f"MPTCP initial path is {observed_hosts}, expected "
        f"{(expected_local, expected_remote)}"
    )
expected = (
    str(connection["local_host"]),
    int(connection["local_port"]),
    str(connection["remote_host"]),
    int(connection["remote_port"]),
)

socket_re = re.compile(
    r"^\s*\d+\s+\d+\s+"
    r"(?P<local_host>\S+):(?P<local_port>\d+)\s+"
    r"(?P<remote_host>\S+):(?P<remote_port>\d+)"
    r"(?:\s+(?P<info>.*))?$"
)
matches = []
with samples_path.open(encoding="utf-8") as stream:
    for line_number, raw_line in enumerate(stream, start=1):
        match = socket_re.match(raw_line.strip())
        if not match:
            continue
        observed = (
            match.group("local_host").strip("[]"),
            int(match.group("local_port")),
            match.group("remote_host").strip("[]"),
            int(match.group("remote_port")),
        )
        if observed != expected:
            continue
        info = match.group("info") or ""
        token_match = re.search(r"(?<!\S)token:([0-9A-Fa-f]+)(?=\s|$)", info)
        subflows_match = re.search(r"(?<!\S)subflows_total:(\d+)(?=\s|$)", info)
        bytes_match = re.search(r"(?<!\S)bytes_sent:(\d+)(?=\s|$)", info)
        if not token_match or not subflows_match:
            continue
        matches.append({
            "line_number": line_number,
            "token": token_match.group(1).lower(),
            "subflows_total": int(subflows_match.group(1)),
            "bytes_sent": int(bytes_match.group(1)) if bytes_match else 0,
        })

if not matches:
    raise SystemExit("iperf data connection was not found in MPTCP socket samples")
tokens = {record["token"] for record in matches}
if len(tokens) != 1:
    raise SystemExit(f"data connection changed MPTCP token: {sorted(tokens)}")
two_subflow_samples = [record for record in matches if record["subflows_total"] == 2]
if not two_subflow_samples:
    observed = sorted({record["subflows_total"] for record in matches})
    raise SystemExit(f"data connection never reached two subflows; observed {observed}")
chosen = max(two_subflow_samples, key=lambda record: record["bytes_sent"])
if chosen["bytes_sent"] < 1024 * 1024:
    raise SystemExit("sampled MPTCP data connection sent less than 1 MiB")

normalized = {
    "bytes_sent": chosen["bytes_sent"],
    "connection": {
        "local_host": expected[0],
        "local_port": expected[1],
        "remote_host": expected[2],
        "remote_port": expected[3],
    },
    "matched_samples": len(matches),
    "selected_sample_line": chosen["line_number"],
    "subflows_total": chosen["subflows_total"],
    "token": chosen["token"],
}
output_path.write_text(json.dumps(normalized, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(chosen["token"], chosen["subflows_total"], chosen["bytes_sent"])
PY
}

link_tx_sample() {
  local host=$1
  local destination=$2
  local source=$3
  ssh_host "$host" "interface=\$(ip -o -4 route get $destination from $source | sed -n 's/.* dev \([^ ]*\).*/\1/p'); test -n \"\$interface\"; printf '%s ' \"\$interface\"; cat \"/sys/class/net/\$interface/statistics/tx_bytes\""
}

wireguard_tx_sample() {
  local host=$1
  local interface=$2
  ssh_host "$host" "wg show $interface transfer | awk 'NF == 3 { count += 1; sent += \$3 } END { if (count != 1) exit 1; print sent }'"
}

interface_tx_sample() {
  local host=$1
  local interface=$2
  ssh_host "$host" "cat /sys/class/net/$interface/statistics/tx_bytes"
}

wireguard_safe_snapshot() {
  local host=$1
  ssh_host "$host" 'set -eu
    for interface in wg-a wg-b; do
      printf "[%s]\n" "$interface"
      wg show "$interface" public-key
      wg show "$interface" listen-port
      wg show "$interface" endpoints
      wg show "$interface" allowed-ips
      wg show "$interface" latest-handshakes
      wg show "$interface" transfer
    done'
}

measure_tcp_baseline() {
  local label=$1
  local client_address=$2
  local server_address=$3
  local selected_wg=$4
  local other_wg=$5
  local selected_outer=$6
  local other_outer=$7
  local json_file=$8
  local counter_file=$9
  local selected_wg_before selected_wg_after selected_outer_before selected_outer_after
  local other_wg_before other_wg_after other_outer_before other_outer_after
  local selected_wg_delta selected_outer_delta other_wg_delta other_outer_delta
  local sent_bytes minimum_selected maximum_noise

  selected_wg_before="$(wireguard_tx_sample mptcp-client "$selected_wg")"
  other_wg_before="$(wireguard_tx_sample mptcp-client "$other_wg")"
  selected_outer_before="$(interface_tx_sample mptcp-client "$selected_outer")"
  other_outer_before="$(interface_tx_sample mptcp-client "$other_outer")"
  log "measuring plain TCP through $label"
  ssh_host mptcp-client \
    "iperf3 --version4 --client $server_address --bind $client_address%$selected_wg --port 5201 --parallel 1 --time 20 --omit 2 --json" \
    >"$json_file"
  assert_iperf_connection "$json_file" "$client_address" "$server_address"
  selected_wg_after="$(wireguard_tx_sample mptcp-client "$selected_wg")"
  other_wg_after="$(wireguard_tx_sample mptcp-client "$other_wg")"
  selected_outer_after="$(interface_tx_sample mptcp-client "$selected_outer")"
  other_outer_after="$(interface_tx_sample mptcp-client "$other_outer")"
  (( selected_wg_after >= selected_wg_before )) || die "$label $selected_wg TX counter decreased"
  (( other_wg_after >= other_wg_before )) || die "$label $other_wg TX counter decreased"
  (( selected_outer_after >= selected_outer_before )) || die "$label $selected_outer TX counter decreased"
  (( other_outer_after >= other_outer_before )) || die "$label $other_outer TX counter decreased"
  selected_wg_delta=$((selected_wg_after - selected_wg_before))
  other_wg_delta=$((other_wg_after - other_wg_before))
  selected_outer_delta=$((selected_outer_after - selected_outer_before))
  other_outer_delta=$((other_outer_after - other_outer_before))
  sent_bytes="$(iperf_sent_bytes "$json_file")"
  minimum_selected=$((sent_bytes * 8 / 10))
  (( minimum_selected >= 10485760 )) || minimum_selected=10485760
  maximum_noise=$((2 * 1024 * 1024))
  (( selected_wg_delta >= minimum_selected )) || die "$label WireGuard counter carried too little baseline traffic"
  (( selected_outer_delta >= minimum_selected )) || die "$label underlay carried too little baseline traffic"
  (( other_wg_delta <= maximum_noise )) || die "$label baseline leaked onto $other_wg"
  (( other_outer_delta <= maximum_noise )) || die "$label baseline leaked onto $other_outer"

  cat >"$counter_file" <<EOF
selected WireGuard interface: $selected_wg
selected WireGuard TX delta: $selected_wg_delta
selected underlay interface: $selected_outer
selected underlay TX delta: $selected_outer_delta
other WireGuard interface: $other_wg
other WireGuard TX delta: $other_wg_delta
other underlay interface: $other_outer
other underlay TX delta: $other_outer_delta
minimum selected delta: $minimum_selected
maximum other-path noise: $maximum_noise
EOF
  MEASURED_BASELINE_BPS="$(iperf_bits_per_second "$json_file")"
}

assert_wireguard_peer() {
  local host=$1
  local interface=$2
  local interface_public_key=$3
  local peer_public_key=$4
  local endpoint=$5
  local allowed_ip=$6
  assert_guest "$host" "$interface has the expected WireGuard peer and a recent handshake" \
    "set -eu
     test \"\$(wg show $interface public-key)\" = '$interface_public_key'
     set -- \$(wg show $interface peers); test \"\$#\" -eq 1; test \"\$1\" = '$peer_public_key'
     set -- \$(wg show $interface endpoints); test \"\$#\" -eq 2; test \"\$1\" = '$peer_public_key'; test \"\$2\" = '$endpoint'
     set -- \$(wg show $interface allowed-ips); test \"\$#\" -eq 2; test \"\$1\" = '$peer_public_key'; test \"\$2\" = '$allowed_ip'
     set -- \$(wg show $interface latest-handshakes); test \"\$#\" -eq 2; test \"\$1\" = '$peer_public_key'; test \"\$2\" -gt 0
     now=\$(date +%s); age=\$((now - \$2)); test \"\$age\" -ge 0; test \"\$age\" -le 180"
}

nstat_value() {
  local host=$1
  local name=$2
  local value
  value="$(ssh_host "$host" "nstat -az $name | awk '\$1 == \"$name\" { print \$2 }'")" || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || {
    printf '[mptcp-lab] ERROR: missing or invalid nstat counter %s on %s\n' "$name" "$host" >&2
    return 1
  }
  printf '%s\n' "$value"
}

mptcp_fallback_count() {
  local host=$1
  local ack synack
  ack="$(nstat_value "$host" MPTcpExtMPCapableFallbackACK)" || return 1
  synack="$(nstat_value "$host" MPTcpExtMPCapableFallbackSYNACK)" || return 1
  printf '%d\n' "$((ack + synack))"
}

cleanup_verify_process() {
  if [[ -n "$VERIFY_PID" ]] && kill -0 "$VERIFY_PID" >/dev/null 2>&1; then
    kill "$VERIFY_PID" >/dev/null 2>&1 || true
    wait "$VERIFY_PID" >/dev/null 2>&1 || true
  fi
}

verify_lab() {
  local artifact_dir baseline_a_json baseline_b_json mptcp_json meta_samples meta_json
  local baseline_a baseline_b baseline_fast mptcp_bps mptcp_bytes ratio
  local join_before join_after join_delta fallback_before fallback_after
  local underlay_a_interface underlay_b_interface interface_after initial_counter
  local wg_a_before wg_a_after wg_a_delta wg_b_before wg_b_after wg_b_delta
  local underlay_a_before underlay_a_after underlay_a_delta
  local underlay_b_before underlay_b_after underlay_b_delta minimum_link_bytes
  local data_meta_token data_subflows sampled_bytes
  local client_wg_a_public client_wg_b_public server_wg_a_public server_wg_b_public
  ensure_wireguard_keys
  client_wg_a_public="$(wireguard_public_key "$WIREGUARD_DIR/client-wg-a.key")"
  client_wg_b_public="$(wireguard_public_key "$WIREGUARD_DIR/client-wg-b.key")"
  server_wg_a_public="$(wireguard_public_key "$WIREGUARD_DIR/server-wg-a.key")"
  server_wg_b_public="$(wireguard_public_key "$WIREGUARD_DIR/server-wg-b.key")"
  assert_complete_ownership
  refresh_access
  artifact_dir="$ARTIFACT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-verify"
  mkdir -p "$artifact_dir"

  assert_guest mptcp-client "client is Debian 13" ". /etc/os-release; test \"\$ID\" = debian && test \"\$VERSION_ID\" = 13"
  assert_guest mptcp-server "server is Debian 13" ". /etc/os-release; test \"\$ID\" = debian && test \"\$VERSION_ID\" = 13"
  assert_guest mptcp-client "client underlay and WireGuard addresses are configured" \
    "ip -4 addr show to $CLIENT_UNDERLAY_A/30 | grep -q . && ip -4 addr show to $CLIENT_UNDERLAY_B/30 | grep -q . && ip -4 addr show dev $WG_A_INTERFACE to $CLIENT_WG_A/30 | grep -q . && ip -4 addr show dev $WG_B_INTERFACE to $CLIENT_WG_B/30 | grep -q ."
  assert_guest mptcp-server "server underlay and WireGuard addresses are configured" \
    "ip -4 addr show to $SERVER_UNDERLAY_A/30 | grep -q . && ip -4 addr show to $SERVER_UNDERLAY_B/30 | grep -q . && ip -4 addr show dev $WG_A_INTERFACE to $SERVER_WG_A/30 | grep -q . && ip -4 addr show dev $WG_B_INTERFACE to $SERVER_WG_B/30 | grep -q ."
  assert_guest mptcp-client "client MPTCP is enabled" "test \"\$(sysctl -n net.mptcp.enabled)\" = 1 && systemctl is-active --quiet mptcp-lab-setup.service"
  assert_guest mptcp-client "client has no explicit management or underlay MPTCP endpoint" \
    "set -eu
     endpoints=\$(ip mptcp endpoint show)
     printf '%s\\n' \"\$endpoints\" | awk '
       NF {
         if (NF != 4 || (\$1 != \"10.204.1.1\" && \$1 != \"10.204.2.1\") ||
             \$2 != \"id\" || \$3 !~ /^[0-9]+\$/ || \$4 != \"implicit\" || ++seen[\$1] > 1) {
           exit 1
         }
       }'"
  assert_guest mptcp-server "server advertises only WireGuard link-b" \
    "endpoints=\$(ip mptcp endpoint show); printf '%s\\n' \"\$endpoints\" | grep -Eq '^10\\.204\\.2\\.2 id 2 signal dev wg-b$'; test \"\$(printf '%s\\n' \"\$endpoints\" | awk 'NF { count++ } END { print count + 0 }')\" -eq 1; systemctl is-active --quiet mptcp-lab-setup.service"
  assert_guest mptcp-server "both iperf3 services are active" "systemctl is-active --quiet iperf3-tcp.service && systemctl is-active --quiet iperf3-mptcp.service"
  assert_guest mptcp-client "WireGuard link-a is reachable" "ping -I $WG_A_INTERFACE -c 2 -W 2 $SERVER_WG_A"
  assert_guest mptcp-client "WireGuard link-b is reachable" "ping -I $WG_B_INTERFACE -c 2 -W 2 $SERVER_WG_B"
  assert_wireguard_peer mptcp-client "$WG_A_INTERFACE" "$client_wg_a_public" "$server_wg_a_public" "$SERVER_UNDERLAY_A:51820" "$SERVER_WG_A/32"
  assert_wireguard_peer mptcp-client "$WG_B_INTERFACE" "$client_wg_b_public" "$server_wg_b_public" "$SERVER_UNDERLAY_B:51821" "$SERVER_WG_B/32"
  assert_wireguard_peer mptcp-server "$WG_A_INTERFACE" "$server_wg_a_public" "$client_wg_a_public" "$CLIENT_UNDERLAY_A:51820" "$CLIENT_WG_A/32"
  assert_wireguard_peer mptcp-server "$WG_B_INTERFACE" "$server_wg_b_public" "$client_wg_b_public" "$CLIENT_UNDERLAY_B:51821" "$CLIENT_WG_B/32"

  assert_bandwidth "$CLIENT_VM" "$CLIENT_LINK_A_MAC" "$artifact_dir/client-link-a-domiftune.txt"
  assert_bandwidth "$CLIENT_VM" "$CLIENT_LINK_B_MAC" "$artifact_dir/client-link-b-domiftune.txt"
  assert_bandwidth "$SERVER_VM" "$SERVER_LINK_A_MAC" "$artifact_dir/server-link-a-domiftune.txt"
  assert_bandwidth "$SERVER_VM" "$SERVER_LINK_B_MAC" "$artifact_dir/server-link-b-domiftune.txt"
  log "assert: all four data interfaces have 100 Mbit/s bidirectional limits"

  read -r underlay_a_interface initial_counter < <(link_tx_sample mptcp-client "$SERVER_UNDERLAY_A" "$CLIENT_UNDERLAY_A")
  read -r underlay_b_interface initial_counter < <(link_tx_sample mptcp-client "$SERVER_UNDERLAY_B" "$CLIENT_UNDERLAY_B")
  [[ "$underlay_a_interface" != "$underlay_b_interface" ]] || die "both WireGuard underlays use $underlay_a_interface"
  [[ "$underlay_a_interface" != "$WG_A_INTERFACE" && "$underlay_a_interface" != "$WG_B_INTERFACE" ]] || die "link-a endpoint route is not on a physical underlay"
  [[ "$underlay_b_interface" != "$WG_A_INTERFACE" && "$underlay_b_interface" != "$WG_B_INTERFACE" ]] || die "link-b endpoint route is not on a physical underlay"
  assert_guest mptcp-client "WireGuard link-a maps to the shaped link-a MAC" \
    "test \"\$(cat /sys/class/net/$underlay_a_interface/address)\" = '$CLIENT_LINK_A_MAC'"
  assert_guest mptcp-client "WireGuard link-b maps to the shaped link-b MAC" \
    "test \"\$(cat /sys/class/net/$underlay_b_interface/address)\" = '$CLIENT_LINK_B_MAC'"

  ssh_host mptcp-client 'ip -brief address; ip route; ip mptcp limits show; ip mptcp endpoint show' >"$artifact_dir/client-network.txt"
  ssh_host mptcp-server 'ip -brief address; ip route; ip mptcp limits show; ip mptcp endpoint show' >"$artifact_dir/server-network.txt"
  ssh_host mptcp-client \
    "ip -4 route get $SERVER_WG_A from $CLIENT_WG_A; ip -4 route get $SERVER_WG_B from $CLIENT_WG_B; ip -4 route get $SERVER_UNDERLAY_A from $CLIENT_UNDERLAY_A; ip -4 route get $SERVER_UNDERLAY_B from $CLIENT_UNDERLAY_B; ip -o link show" \
    >"$artifact_dir/client-path-routes.txt"
  wireguard_safe_snapshot mptcp-client >"$artifact_dir/client-wireguard-before.txt"
  wireguard_safe_snapshot mptcp-server >"$artifact_dir/server-wireguard-before.txt"
  ssh_host mptcp-client '. /etc/os-release; printf "distribution=%s version=%s\\n" "$ID" "$VERSION_ID"; uname -srvo; wg --version; iperf3 --version | head -2' >"$artifact_dir/client-environment.txt"
  ssh_host mptcp-server '. /etc/os-release; printf "distribution=%s version=%s\\n" "$ID" "$VERSION_ID"; uname -srvo; wg --version; iperf3 --version | head -2' >"$artifact_dir/server-environment.txt"
  sha256sum "$ROOT_DIR/lab.dbf.hcl" "$ROOT_DIR/scripts/lab.sh" >"$artifact_dir/configuration-sha256.txt"
  for domain in "$CLIENT_VM" "$SERVER_VM"; do
    virsh_cmd domiflist "$domain" >"$artifact_dir/$domain-interfaces.txt"
  done

  baseline_a_json="$artifact_dir/tcp-link-a.json"
  baseline_b_json="$artifact_dir/tcp-link-b.json"
  mptcp_json="$artifact_dir/mptcp.json"
  meta_samples="$artifact_dir/mptcp-meta-samples.txt"
  meta_json="$artifact_dir/mptcp-data-meta.json"
  measure_tcp_baseline "WireGuard link-a" "$CLIENT_WG_A" "$SERVER_WG_A" \
    "$WG_A_INTERFACE" "$WG_B_INTERFACE" "$underlay_a_interface" "$underlay_b_interface" \
    "$baseline_a_json" "$artifact_dir/tcp-link-a-isolation.txt"
  baseline_a="$MEASURED_BASELINE_BPS"
  measure_tcp_baseline "WireGuard link-b" "$CLIENT_WG_B" "$SERVER_WG_B" \
    "$WG_B_INTERFACE" "$WG_A_INTERFACE" "$underlay_b_interface" "$underlay_a_interface" \
    "$baseline_b_json" "$artifact_dir/tcp-link-b-isolation.txt"
  baseline_b="$MEASURED_BASELINE_BPS"

  wg_a_before="$(wireguard_tx_sample mptcp-client "$WG_A_INTERFACE")"
  wg_b_before="$(wireguard_tx_sample mptcp-client "$WG_B_INTERFACE")"
  underlay_a_before="$(interface_tx_sample mptcp-client "$underlay_a_interface")"
  underlay_b_before="$(interface_tx_sample mptcp-client "$underlay_b_interface")"
  ssh_host mptcp-client 'nstat -asz | sed -n "/^MPTcpExt/p"' >"$artifact_dir/client-mptcp-counters-before.txt"
  join_before="$(nstat_value mptcp-client MPTcpExtMPJoinSynTx)"
  fallback_before="$(mptcp_fallback_count mptcp-client)"
  log "measuring one MPTCP flow across both WireGuard links"
  ssh_host mptcp-client \
    "mptcpize run iperf3 --version4 --client $SERVER_WG_A --port 5202 --parallel 1 --time 30 --omit 3 --json" \
    >"$mptcp_json" &
  VERIFY_PID=$!
  trap cleanup_verify_process EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  : >"$meta_samples"
  for _ in $(seq 1 12); do
    sleep 1
    printf '%s\n' "--- sample $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >>"$meta_samples"
    ssh_host mptcp-client "ss -H -MnOi state established '( dport = :5202 )'" >>"$meta_samples" || true
    printf '%s\n' "--- sample $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >>"$artifact_dir/socket-samples-server.txt"
    ssh_host mptcp-server 'ss -MnOi' >>"$artifact_dir/socket-samples-server.txt" || true
  done
  wait "$VERIFY_PID"
  VERIFY_PID=""
  trap - EXIT INT TERM
  join_after="$(nstat_value mptcp-client MPTcpExtMPJoinSynTx)"
  fallback_after="$(mptcp_fallback_count mptcp-client)"
  ssh_host mptcp-client 'nstat -asz | sed -n "/^MPTcpExt/p"' >"$artifact_dir/client-mptcp-counters-after.txt"
  join_delta=$((join_after - join_before))
  mptcp_bps="$(iperf_bits_per_second "$mptcp_json")"
  mptcp_bytes="$(iperf_sent_bytes "$mptcp_json")"
  read -r data_meta_token data_subflows sampled_bytes < <(
    extract_mptcp_data_meta "$mptcp_json" "$meta_samples" "$meta_json" "$CLIENT_WG_A" "$SERVER_WG_A"
  )
  wg_a_after="$(wireguard_tx_sample mptcp-client "$WG_A_INTERFACE")"
  wg_b_after="$(wireguard_tx_sample mptcp-client "$WG_B_INTERFACE")"
  read -r interface_after underlay_a_after < <(link_tx_sample mptcp-client "$SERVER_UNDERLAY_A" "$CLIENT_UNDERLAY_A")
  [[ "$interface_after" == "$underlay_a_interface" ]] || die "link-a underlay route changed during verification"
  read -r interface_after underlay_b_after < <(link_tx_sample mptcp-client "$SERVER_UNDERLAY_B" "$CLIENT_UNDERLAY_B")
  [[ "$interface_after" == "$underlay_b_interface" ]] || die "link-b underlay route changed during verification"
  (( wg_a_after >= wg_a_before )) || die "$WG_A_INTERFACE TX counter decreased during MPTCP verification"
  (( wg_b_after >= wg_b_before )) || die "$WG_B_INTERFACE TX counter decreased during MPTCP verification"
  (( underlay_a_after >= underlay_a_before )) || die "$underlay_a_interface TX counter decreased during MPTCP verification"
  (( underlay_b_after >= underlay_b_before )) || die "$underlay_b_interface TX counter decreased during MPTCP verification"
  wg_a_delta=$((wg_a_after - wg_a_before))
  wg_b_delta=$((wg_b_after - wg_b_before))
  underlay_a_delta=$((underlay_a_after - underlay_a_before))
  underlay_b_delta=$((underlay_b_after - underlay_b_before))
  minimum_link_bytes=$((mptcp_bytes / 10))
  (( minimum_link_bytes >= 10485760 )) || minimum_link_bytes=10485760

  baseline_fast=$baseline_a
  (( baseline_b > baseline_fast )) && baseline_fast=$baseline_b
  ratio="$(python3 - "$mptcp_bps" "$baseline_fast" <<'PY'
import sys
print(f"{int(sys.argv[1]) / int(sys.argv[2]):.2f}")
PY
)"

  python3 - "$baseline_a" "$baseline_b" "$mptcp_bps" <<'PY'
import sys

link_a, link_b, mptcp = map(int, sys.argv[1:])
for name, value in (("link-a", link_a), ("link-b", link_b)):
    if not 70_000_000 <= value <= 115_000_000:
        raise SystemExit(f"{name} baseline outside 70-115 Mbit/s: {value / 1e6:.2f}")
fastest = max(link_a, link_b)
if mptcp < 150_000_000:
    raise SystemExit(f"MPTCP throughput below 150 Mbit/s: {mptcp / 1e6:.2f}")
if mptcp < fastest * 1.5:
    raise SystemExit(f"MPTCP gain below 1.5x: {mptcp / fastest:.2f}x")
if mptcp > 230_000_000:
    raise SystemExit(f"MPTCP throughput unexpectedly exceeds two shaped paths: {mptcp / 1e6:.2f}")
PY
  (( data_subflows == 2 )) || die "the iperf3 data connection did not have exactly two MPTCP subflows"
  (( sampled_bytes >= 1048576 )) || die "the sampled MPTCP data connection carried too little data"
  (( wg_a_delta >= minimum_link_bytes )) || die "wg-a carried too little MPTCP traffic: $wg_a_delta bytes"
  (( wg_b_delta >= minimum_link_bytes )) || die "wg-b carried too little MPTCP traffic: $wg_b_delta bytes"
  (( underlay_a_delta >= minimum_link_bytes )) || die "link-a underlay carried too little MPTCP traffic: $underlay_a_delta bytes"
  (( underlay_b_delta >= minimum_link_bytes )) || die "link-b underlay carried too little MPTCP traffic: $underlay_b_delta bytes"
  (( join_delta >= 1 )) || die "no new MP_JOIN was observed"
  (( fallback_after == fallback_before )) || die "an MPTCP fallback was observed"

  cat >"$artifact_dir/client-link-tx-bytes.txt" <<EOF
wg-a transfer TX before: $wg_a_before
wg-a transfer TX after:  $wg_a_after
wg-a transfer TX delta:  $wg_a_delta
wg-b transfer TX before: $wg_b_before
wg-b transfer TX after:  $wg_b_after
wg-b transfer TX delta:  $wg_b_delta
link-a underlay interface: $underlay_a_interface
link-a underlay TX before: $underlay_a_before
link-a underlay TX after:  $underlay_a_after
link-a underlay TX delta:  $underlay_a_delta
link-b underlay interface: $underlay_b_interface
link-b underlay TX before: $underlay_b_before
link-b underlay TX after:  $underlay_b_after
link-b underlay TX delta:  $underlay_b_delta
minimum per-path delta:    $minimum_link_bytes
EOF

  wireguard_safe_snapshot mptcp-client >"$artifact_dir/client-wireguard-after.txt"
  wireguard_safe_snapshot mptcp-server >"$artifact_dir/server-wireguard-after.txt"

  cat >"$artifact_dir/summary.txt" <<EOF
WireGuard link-a TCP: $(python3 -c "print(f'{$baseline_a / 1000000:.2f} Mbit/s')")
WireGuard link-b TCP: $(python3 -c "print(f'{$baseline_b / 1000000:.2f} Mbit/s')")
WireGuard MPTCP:       $(python3 -c "print(f'{$mptcp_bps / 1000000:.2f} Mbit/s')")
gain over fastest link: ${ratio}x
initial data path: $CLIENT_WG_A -> $SERVER_WG_A
data token: $data_meta_token
data subflows_total: $data_subflows
MP_JOIN (host-global): +$join_delta
wg-a transfer TX: +$wg_a_delta bytes
wg-b transfer TX: +$wg_b_delta bytes
link-a underlay TX: +$underlay_a_delta bytes
link-b underlay TX: +$underlay_b_delta bytes
fallback: +$((fallback_after - fallback_before))
EOF
  cat "$artifact_dir/summary.txt"
  log "verification artifacts: $artifact_dir"
}

up_lab() {
  print_selection
  prepare_up_ownership
  [[ -x "$SKILL_SCRIPT" ]] || die "virsh-test-host helper not found: $SKILL_SCRIPT"
  DBF_LIBVIRT_URI="$LIBVIRT_URI" DBF_TEST_HYPERVISOR="$HYPERVISOR" "$SKILL_SCRIPT" probe
  ensure_network "$LINK_A_NETWORK" "$LINK_A_BRIDGE"
  ensure_network "$LINK_B_NETWORK" "$LINK_B_BRIDGE"
  ensure_vm "$CLIENT_VM"
  ensure_vm "$SERVER_VM"
  ensure_data_interface "$CLIENT_VM" "$LINK_A_NETWORK" "$CLIENT_LINK_A_MAC" mptcp-link-a
  ensure_data_interface "$CLIENT_VM" "$LINK_B_NETWORK" "$CLIENT_LINK_B_MAC" mptcp-link-b
  ensure_data_interface "$SERVER_VM" "$LINK_A_NETWORK" "$SERVER_LINK_A_MAC" mptcp-link-a
  ensure_data_interface "$SERVER_VM" "$LINK_B_NETWORK" "$SERVER_LINK_B_MAC" mptcp-link-b
  if (( CLIENT_RESTART_REQUIRED == 1 )); then
    restart_domain_for_topology "$CLIENT_VM"
  fi
  if (( SERVER_RESTART_REQUIRED == 1 )); then
    restart_domain_for_topology "$SERVER_VM"
  fi
  apply_data_bandwidth "$CLIENT_VM" "$CLIENT_LINK_A_MAC"
  apply_data_bandwidth "$CLIENT_VM" "$CLIENT_LINK_B_MAC"
  apply_data_bandwidth "$SERVER_VM" "$SERVER_LINK_A_MAC"
  apply_data_bandwidth "$SERVER_VM" "$SERVER_LINK_B_MAC"
  apply_lab
  verify_lab
}

status_lab() {
  assert_complete_ownership
  print_selection
  virsh_cmd list --all | grep -E "Name|$CLIENT_VM|$SERVER_VM" || true
  virsh_cmd net-list --all | grep -E "Name|$LINK_A_NETWORK|$LINK_B_NETWORK" || true
  for domain in "$CLIENT_VM" "$SERVER_VM"; do
    if virsh_cmd dominfo "$domain" >/dev/null 2>&1; then
      printf '\n[%s interfaces]\n' "$domain"
      virsh_cmd domiflist "$domain"
    fi
  done
  printf '\n[underlay interface bandwidth]\n'
  for pair in \
    "$CLIENT_VM $CLIENT_LINK_A_MAC" \
    "$CLIENT_VM $CLIENT_LINK_B_MAC" \
    "$SERVER_VM $SERVER_LINK_A_MAC" \
    "$SERVER_VM $SERVER_LINK_B_MAC"; do
    read -r domain mac <<<"$pair"
    if virsh_cmd dominfo "$domain" >/dev/null 2>&1; then
      printf '%s %s\n' "$domain" "$mac"
      virsh_cmd domiftune "$domain" "$mac" | awk '/^(inbound|outbound)\.average:/ { print "  " $0 }'
    fi
  done
  if virsh_cmd dominfo "$CLIENT_VM" >/dev/null 2>&1 && virsh_cmd dominfo "$SERVER_VM" >/dev/null 2>&1; then
    refresh_access
    printf '\n[client]\n'
    ssh_host mptcp-client 'ip -brief -4 address; ip mptcp limits show; ip mptcp endpoint show'
    if ssh_host mptcp-client 'command -v wg >/dev/null && ip link show wg-a >/dev/null 2>&1 && ip link show wg-b >/dev/null 2>&1'; then
      printf '\n[client WireGuard]\n'
      wireguard_safe_snapshot mptcp-client
    fi
    printf '\n[server]\n'
    ssh_host mptcp-server 'ip -brief -4 address; ip mptcp limits show; ip mptcp endpoint show'
    if ssh_host mptcp-server 'command -v wg >/dev/null && ip link show wg-a >/dev/null 2>&1 && ip link show wg-b >/dev/null 2>&1'; then
      printf '\n[server WireGuard]\n'
      wireguard_safe_snapshot mptcp-server
    fi
  fi
}

line_present() {
  local wanted=$1
  local lines=$2
  grep -Fxq -- "$wanted" <<<"$lines"
}

preflight_domain() {
  local name=$1
  local expected actual names uuids path_status
  expected="$(manifest_tool get-domain "$name")"
  names="$(virsh_cmd list --all --name)" || return 1
  uuids="$(virsh_cmd list --all --uuid)" || return 1
  if line_present "$name" "$names"; then
    if [[ -z "$expected" ]]; then
      log "ERROR: unowned fixed-name domain exists: $name"
      return 1
    fi
    actual="$(virsh_cmd domuuid "$name")" || return 1
    if [[ "$actual" != "$expected" ]]; then
      log "ERROR: domain UUID mismatch for $name"
      return 1
    fi
  elif [[ -n "$expected" ]] && line_present "$expected" "$uuids"; then
    log "ERROR: owned domain UUID $expected no longer has the expected name $name"
    return 1
  fi
  if [[ -z "$expected" ]]; then
    if domain_paths_exist "$name"; then
      log "ERROR: unowned fixed-name VM files exist for $name"
      return 1
    else
      path_status=$?
      (( path_status == 1 )) || return 1
    fi
  fi
}

preflight_network() {
  local name=$1
  local required_bridge=$2
  local expected_uuid expected_bridge actual_uuid names uuids
  expected_uuid="$(manifest_tool get-network-uuid "$name")"
  expected_bridge="$(manifest_tool get-network-bridge "$name")"
  names="$(virsh_cmd net-list --all --name)" || return 1
  uuids="$(virsh_cmd net-list --all --uuid)" || return 1
  if [[ -n "$expected_uuid" && "$expected_bridge" != "$required_bridge" ]]; then
    log "ERROR: manifest bridge mismatch for $name"
    return 1
  fi
  if line_present "$name" "$names"; then
    if [[ -z "$expected_uuid" ]]; then
      log "ERROR: unowned fixed-name network exists: $name"
      return 1
    fi
    actual_uuid="$(virsh_cmd net-uuid "$name")" || return 1
    if [[ "$actual_uuid" != "$expected_uuid" || "$(network_bridge "$name")" != "$required_bridge" ]]; then
      log "ERROR: network identity mismatch for $name"
      return 1
    fi
  elif [[ -n "$expected_uuid" ]] && line_present "$expected_uuid" "$uuids"; then
    log "ERROR: owned network UUID $expected_uuid no longer has the expected name $name"
    return 1
  fi
}

preflight_destroy() {
  local failed=0
  assert_manifest_destroy_context
  preflight_domain "$CLIENT_VM" || failed=1
  preflight_domain "$SERVER_VM" || failed=1
  preflight_network "$LINK_A_NETWORK" "$LINK_A_BRIDGE" || failed=1
  preflight_network "$LINK_B_NETWORK" "$LINK_B_BRIDGE" || failed=1
  (( failed == 0 )) || die "ownership preflight failed; no resources were changed"
}

path_used_by_another_domain() {
  local wanted=$1
  local domain names devices source chain_contains status xml
  names="$(virsh_cmd list --all --name)" || return 2
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    xml="$(virsh_cmd dumpxml "$domain")" || return 2
    if python3 -c '
import sys
import xml.etree.ElementTree as ET

wanted = sys.argv[1]
root = ET.fromstring(sys.stdin.read())
raise SystemExit(0 if any(wanted in element.attrib.values() for element in root.iter()) else 1)
' "$wanted" <<<"$xml"; then
      log "ERROR: $wanted is still referenced by domain $domain"
      return 0
    else
      status=$?
      (( status == 1 )) || return 2
    fi
    [[ "$wanted" == *.qcow2 ]] || continue
    devices="$(virsh_cmd domblklist "$domain" --details)" || return 2
    while IFS= read -r source; do
      [[ -n "$source" && "$source" != "-" ]] || continue
      chain_contains="$(remote_exec qemu-img info --force-share --backing-chain --output=json "$source" | python3 -c '
import json
import sys

wanted = sys.argv[1]
chain = json.load(sys.stdin)
found = any(
    image.get("filename") == wanted or image.get("full-backing-filename") == wanted
    for image in chain
)
print("yes" if found else "no")
' "$wanted")" || return 2
      if [[ "$chain_contains" == "yes" ]]; then
        log "ERROR: $wanted is in the backing chain used by domain $domain"
        return 0
      fi
    done < <(awk '($2 == "disk" || $2 == "cdrom") && $4 != "-" { print $4 }' <<<"$devices")
  done <<<"$names"
  return 1
}

destroy_domain_verified() {
  local name=$1
  local expected all_uuids active_uuids all_names disk seed console workdir file
  expected="$(manifest_tool get-domain "$name")"
  [[ -n "$expected" ]] || return 0
  all_uuids="$(virsh_cmd list --all --uuid)" || return 1
  if line_present "$expected" "$all_uuids"; then
    active_uuids="$(virsh_cmd list --uuid)" || return 1
    if line_present "$expected" "$active_uuids"; then
      if ! virsh_cmd destroy "$expected" >/dev/null; then
        log "ERROR: failed to stop domain $name; its files were not touched"
        return 1
      fi
    fi
    active_uuids="$(virsh_cmd list --uuid)" || return 1
    if line_present "$expected" "$active_uuids"; then
      log "ERROR: domain is still active after destroy: $name"
      return 1
    fi
    if ! virsh_cmd undefine "$expected" --nvram >/dev/null 2>&1 && \
       ! virsh_cmd undefine "$expected" >/dev/null 2>&1; then
      log "ERROR: failed to undefine domain $name; its files were not touched"
      return 1
    fi
  fi
  all_uuids="$(virsh_cmd list --all --uuid)" || return 1
  if line_present "$expected" "$all_uuids"; then
    log "ERROR: domain still exists after undefine: $name"
    return 1
  fi
  all_names="$(virsh_cmd list --all --name)" || return 1
  if line_present "$name" "$all_names"; then
    log "ERROR: a different domain now uses $name; owned files were not touched"
    return 1
  fi

  disk="$POOL_TARGET_PATH/$name.qcow2"
  seed="$POOL_TARGET_PATH/$name-seed.img"
  console="$POOL_TARGET_PATH/$name-console.log"
  workdir="$POOL_TARGET_PATH/.dbf-test-$name"
  for file in "$disk" "$seed" "$console"; do
    if path_used_by_another_domain "$file"; then
      return 1
    else
      case $? in
        1) ;;
        *) return 1 ;;
      esac
    fi
  done
  remote_exec rm -f -- "$disk" "$seed" "$console" || return 1
  remote_exec rm -rf -- "$workdir" || return 1
  for file in "$disk" "$seed" "$console" "$workdir"; do
    if ! remote_exec test ! -e "$file"; then
      log "ERROR: owned VM path still exists: $file"
      return 1
    fi
  done
  log "destroyed and verified domain: $name"
}

destroy_network_verified() {
  local name=$1
  local expected all_uuids active_uuids all_names
  expected="$(manifest_tool get-network-uuid "$name")"
  [[ -n "$expected" ]] || return 0
  all_uuids="$(virsh_cmd net-list --all --uuid)" || return 1
  if line_present "$expected" "$all_uuids"; then
    active_uuids="$(virsh_cmd net-list --uuid)" || return 1
    if line_present "$expected" "$active_uuids"; then
      if ! virsh_cmd net-destroy "$expected" >/dev/null; then
        log "ERROR: failed to stop network $name"
        return 1
      fi
    fi
    all_uuids="$(virsh_cmd net-list --all --uuid)" || return 1
    if line_present "$expected" "$all_uuids" && ! virsh_cmd net-undefine "$expected" >/dev/null; then
      log "ERROR: failed to undefine network $name"
      return 1
    fi
  fi
  all_uuids="$(virsh_cmd net-list --all --uuid)" || return 1
  if line_present "$expected" "$all_uuids"; then
    log "ERROR: network still exists after cleanup: $name"
    return 1
  fi
  all_names="$(virsh_cmd net-list --all --name)" || return 1
  if line_present "$name" "$all_names"; then
    log "ERROR: a different network now uses $name"
    return 1
  fi
  log "destroyed and verified network: $name"
}

destroy_lab() {
  local failed=0
  print_selection
  preflight_destroy
  destroy_domain_verified "$CLIENT_VM" || failed=1
  destroy_domain_verified "$SERVER_VM" || failed=1
  if (( failed != 0 )); then
    die "one or more domains could not be safely removed; networks and ownership manifest were preserved"
  fi
  destroy_network_verified "$LINK_A_NETWORK" || failed=1
  destroy_network_verified "$LINK_B_NETWORK" || failed=1
  if (( failed != 0 )); then
    die "one or more networks could not be safely removed; ownership manifest was preserved"
  fi
  rm -rf -- "$RUNTIME_DIR"
  log "lab resources were removed and verified; result artifacts were preserved"
}

usage() {
  cat <<'EOF'
Usage: scripts/lab.sh up|apply|verify|status|adopt|destroy
EOF
}

main() {
  local command
  if (( $# != 1 )); then
    usage >&2
    exit 2
  fi
  command=$1
  case "$command" in
    -h|--help|help) usage; return ;;
    up|apply|verify|status|adopt|destroy) ;;
    *) usage >&2; exit 2 ;;
  esac
  validate_environment
  acquire_lock
  case "$command" in
    up) up_lab ;;
    apply) apply_lab ;;
    verify) verify_lab ;;
    status) status_lab ;;
    adopt) adopt_lab ;;
    destroy) destroy_lab ;;
  esac
}

main "$@"
