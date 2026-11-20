# OpenWrt VM service

> The project name is written `SymbiOS`; the OpenWrt router VM is the `openwrt-vm`
> SymbiOS service, deployed from `services/openwrt-vm.yml`.

## What this service is

Deploys an OpenWrt router as a QEMU/KVM virtual machine and applies a **minimal
first-boot preconfiguration** so the VM is reachable over the network (SSH and
HTTP/HTTPS via Traefik) and the host stays present in every internal segment.

Service and router configuration beyond reachability is **not** baked in here.
The WebUI offers only two playbooks for it:

| Topic | Playbook |
|-------|----------|
| Master router, like `openwrt-og` | `external-services/openwrt_master.yml` |
| Secondary access point, like `openwrt-ab` | `external-services/openwrt_slave.yml` |

All other OpenWrt playbooks are hidden from the catalog. The reusable component
plays live under `external-services/tasks/openwrt/`, and the remaining per-item
tools (DNS records, DHCP hosts, DDNS, firewall rules, wireless, WireGuard
clients) stay runnable via `symbios-run-remote-playbook.sh` on the CLI.

`openwrt_master.yml` installs the foundation in every run and can optionally
include the system services via its `services` parameter (comma separated):
`asterisk`, `smtp`, `netboot`, `dnscrypt`, `openvpn-lan`, `openvpn-iot`,
`openvpn-tor`, `wireguard-lan`, `wireguard-tor`, `uplink-ftth`, `uplink-vdsl`,
`fritzbox`. An empty value (the default, and the right choice for the lab VM)
runs only the foundation. The fields for every service are part of the master
form; a skipped service never evaluates its required-parameter asserts. Values
saved under the old playbook names are still merged via `_playbook-compat.json`.

`openwrt_slave.yml` bundles the same foundation, IoT/Tor segments, log
forwarding and autoupdate as the master, then converts the router into a dumb
access point (gateway, DNS, no WAN, no local DHCP/DNS). Its form carries the
parameters of all those components.

There is no standalone OpenVPN client playbook. The OpenVPN server components
under `external-services/tasks/openwrt/` generate an inline
`.ovpn` file for every host listed in `lan_clients`, `iot_clients` and
`tor_clients`, copy it to that host over SSH and set its
`openvpn.<segment>vpn` UCI section. The physical slaves are IoT/Tor clients
because they are named in `iot_clients` / `tor_clients` on the master; the
LAN server currently pushes only to end devices, not to the slaves.
`openwrt_slave.yml` therefore needs no client import. To reproduce the client
side, enable `openvpn-iot` / `openvpn-tor` in `services` and fill in the
matching `iot_clients` / `tor_clients` field of the master form. A fresh VM has
no client certificate until the master server playbook runs.

The foundation components live under `external-services/tasks/openwrt/` and are
not listed in the catalog. They are used only by the bundles. Physical routers
are untouched by this reorganisation: their existing saved variables and
managed-state ids are kept via `external-services/_playbook-compat.json`.

A full uninstall of this service also removes the `openwrt-vm` entry from
external systems and all `... @ openwrt-vm` install markers, so the master and
slave bundles stop showing as installed. `Uninstall (keep data)` deliberately
keeps saved variables and remote-run state.

The VM owns the `.1` / `::1` gateway on every internal segment; the host
bridges are L2 switches that additionally take a DHCP address from the
segment's dnsmasq, so the host is directly reachable inside every segment.

## Topology

```
WAN   eth0  192.168.41.201/24   base-services bridge (same L2 as Docker/Traefik)
                                    gw 192.168.41.1 (host), NAT to uplink,
                                    IPv4 only (no bogus IPv6 default route)
LAN   br-lan (port eth1) 172.18.0.1/24   openwrt-lan bridge (L2 + host DHCP)  ULA fd00:18::/64
IOT   br-iot (port eth2) 172.18.1.1/24   openwrt-iot bridge (L2 + host DHCP)  ULA fd00:18:1::/64
TOR   br-tor (port eth3) 172.18.2.1/24   openwrt-tor bridge (L2 + host DHCP)  ULA fd00:18:2::/64
MISC  eth4  172.18.3.1/24       openwrt-misc bridge (L2 + host DHCP)  ULA fd00:18:3::/64
```

- lan/iot/tor are **bridged inside the VM** (`br-lan`/`br-iot`/`br-tor` with
  `eth1`/`eth2`/`eth3` as bridge ports). This matches the physical OpenWrt
  routers (`network.lan.device=br-lan`) and the device assumptions of the
  `external-services/openwrt_*` playbooks; OpenVPN tap devices can be attached
  to those bridges later. misc uses `eth4` directly.
- Host bridges (`openwrt-lan/-iot/-tor/-misc`) use deterministic MACs
  (`02:ac:00:00:00:01`-`04`) and are managed by ifupdown in `inet manual` /
  `inet6 manual` mode and persist across reboots. The v4 DHCP lease comes from
  the segment's dnsmasq (host presence in every segment); a systemd timer
  (`symbios-ow-bridge-dhcp.timer`) retries the lease while the VM is still down
  after boot.
- Clients on a segment use the VM as gateway + DHCP/DNS.

## First-boot scripts (injected into the image)

Three files are injected into the root filesystem at build time and run once on
the VM's first boot. Because they run only via uci-defaults, **rerunning the
`openwrt-vm` playbook never overwrites settings applied by
`external-services/openwrt_*` playbooks** (a rerun only updates the host/Traefik
side and VM resources, not the VM's in-guest configuration).

| File | Phase | What it does |
|------|-------|--------------|
| `/etc/uci-defaults/98-openwrt-network` | offline | WAN + internal interfaces/bridges, static IPv4 + IPv6, DAD off |
| `/etc/uci-defaults/99-openwrt-preconfig` | offline | firewall (wan/lan/iot/tor zones, lan->wan forwarding), WAN reachability (dropbear SSH 22 lan + 44 wan, HTTP/HTTPS 80/443), DHCP/DNS for all four segments (host-bridge presence), suppress LuCI attended-sysupgrade first-login prompt |
| `/etc/hotplug.d/iface/80-openwrt-postconfig` + `/etc/openwrt-postconfig.sh` | online (first `wan` ifup) | minimal package install, baseline service enable/restart |

Templates live in `services/openwrt-vm/templates/` and are rendered by the
playbook from `ow_networks` + `openwrt_packages`.

## External playbook parameters

The VM is registered as external system `openwrt-vm` (SSH port 44, key-only).
Target-wide values are saved with `symbios-external-params.sh` in
`external-systems/host_vars/openwrt-vm.yml` so the `external-services/openwrt_*`
playbooks do not need them typed on every run:

```
lan_device=br-lan
lan_ip=172.18.0.1
lan_mask=255.255.255.0
lan_ip6=fd00:18::1/64
bridges=br-lan
upstream_dns=172.23.0.220
timezone=CET-1CEST,M3.5.0,M10.5.0/3
ntp_server=172.23.0.220
```

The namespaced `lan_*` keys avoid collisions with per-record playbooks that
also use `ip`/`ip6`; `openwrt_master.yml` and `openwrt_slave.yml` accept either
spelling. Save playbook-specific values on the playbook detail page in the
WebUI.

## Services / ports exposed (baseline)

| Service | Port | Scope |
|---------|------|-------|
| LuCI (Traefik, Authelia) | 80/443 | internet (via Traefik) |
| dropbear SSH | 22 (lan) / 44 (wan) | key-only, root password auth disabled |
| dnsmasq lan/misc | 53 + DHCP | lan + misc segments |
| dnsmasq iot | 53 + DHCP on 172.18.1.x | iot segment |
| dnsmasq tor | 53 + DHCP on 172.18.2.x | tor segment |

Additional ports and services (VPNs, DNSCrypt, Tor proxy, netboot, ...) are
opened and configured by the respective `external-services/openwrt_*` playbooks.

## External playbook compatibility

The VM is a resolver with a static RFC1918 WAN and no IPv6 uplink, and its
internal segments use `172.18.x` / `fd00:18::` instead of the physical routers'
`192.168.142/143` / `fd12:3456:...`. Compatibility with
`external-services/openwrt_*` therefore falls into three groups:

| Playbooks | Use on the VM |
|-----------|---------------|
| `openwrt_master.yml` (foundation), and the per-item tools for DNS records, DHCP hosts and firewall rules | Compatible. They read the saved host vars below; their built-in defaults still target the physical routers. |
| `openwrt_master.yml` with `smtp` or `asterisk` | Need their segment subnets/IPs passed as extra vars (defaults target the physical routers). |
| `openwrt_slave.yml`, the wireless tool, IPv6 DDNS/forwarding, and the `fritzbox`, `uplink-*` and WireGuard services of `openwrt_master.yml` | Do not run: wrong hardware or uplink model (static WAN, no radios, no v6 uplink). `openwrt_slave.yml` is for secondary physical APs only. |

Saved target-wide vars for `openwrt-vm` live in
`external-systems/host_vars/openwrt-vm.yml` and currently are:

```
lan_device=br-lan           lan_ip=172.18.0.1        lan_mask=255.255.255.0
lan_ip6=fd00:18::1/64       bridges=br-lan           upstream_dns=172.23.0.220
timezone=CET-1CEST,M3.5.0,M10.5.0/3                  ntp_server=172.23.0.220
ipv6_uplink=false
iot_device=br-iot           iot_ip=172.18.1.1        iot_netmask=255.255.255.0
iot_subnet=172.18.1.0/24    iot_v6=fd00:18:1::1      iot_ip6=fd00:18:1::1/64
iot_prefix=fd00:18:1::/64   iot_upstream_dns=172.23.0.220
iot_net_prefix=172.18.1.
tor_device=br-tor           tor_ip=172.18.2.1        tor_netmask=255.255.255.0
tor_subnet=172.18.2.0/24    tor_v6=fd00:18:2::1      tor_ip6=fd00:18:2::1/64
tor_prefix=fd00:18:2::/64   tor_dns=172.18.2.1       tor_upstream_dns=172.23.0.220
tor_printer_ip=172.18.1.1   tor_net_prefix=172.18.2.
```

`ipv6_uplink=false` keeps the foundation and segment components imported by
`openwrt_master.yml` from advertising an IPv6 default route that the VM cannot
provide; the default (`true`) is unchanged for physical routers. The segment
defaults (`192.168.142/143`, `fd12:3456:142/143`) remain valid for physical
routers; the VM host vars override them without touching those defaults.
Values are saved with `symbios-external-params.sh` and merged by
`symbios-run-remote-playbook.sh` before runtime stdin values.

## Fresh install / reset

- The VM's root password is generated by the playbook into
  `/symbios/services/openwrt-vm/env` (`OPENWRT_ROOT_PASSWORD=...`); the host SSH
  public key is added to `/etc/dropbear/authorized_keys`.
- LuCI: `https://openwrt.<base_domain>` (Authelia group `openwrt-vm`), serial:
  `virsh console openwrt`.
- To rebuild from scratch: uninstall the service via the WebUI or remove
  `services_root/openwrt-vm/images/openwrt.qcow2` + `virsh undefine openwrt --nvram`
  and re-run the playbook. A fresh image runs the minimal preconfig again on its
  first boot.

## Notes and caveats

- The minimal postconfig only writes `/etc/openwrt-postconfig.done` when the
  package phase succeeded. On package errors it logs to
  `/var/log/openwrt-package-errors.log` and retries on the next `wan` ifup.
- The DHCP/DNS reset (`while uci delete dhcp.@dnsmasq[0] / @dhcp[0]`) must run
  before the segment sections in the preconfig so the iot/tor instances survive.
  Verify after a fresh build: `uci show dhcp | grep =dnsmasq` shows
  `lan_dnsmasq`, `iot_dnsmasq`, `tor_dnsmasq`.
- The VM WAN deliberately has no IPv6 default route. The host may only have a
  ULA prefix or a delegated prefix without a reachable `::1` gateway; a bogus
  default route makes `wget` prefer IPv6 and fail with `Operation not
  permitted`. Internal ULA segments still provide IPv6 for the external
  OpenWrt playbooks.
- The preconfig leaves timezone/NTP, remote syslog, upstream DNS policy, mDNS
  reflection and advanced firewall policies to the external-services playbooks.
  The main lan/misc resolver initially forwards via `vm_dns`
  (`/etc/resolv.dnsmasq.lan`); the `dnscrypt` component of
  `openwrt_master.yml` repoints it to a local DoH proxy when selected.
- The remaining feature playbooks under `services/openwrt-vm/features/`
  (`ddns-ipv6.yml`, `dhcp-hosts.yml`, `dns_a.yml`) cover user-specific DNS
  entries. Configure them via the WebUI Features tab.
