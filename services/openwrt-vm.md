# OpenWrt VM service

> The project name is written `SymbiOS`; the OpenWrt router VM is the `openwrt-vm`
> SymbiOS service, deployed from `services/openwrt-vm.yml`.

## What this service is

Deploys an OpenWrt router as a QEMU/KVM virtual machine and **preconfigures** it
on first boot so it behaves like the linux-setups OpenWrt router at
`/data-crypt/share/github/linux-setups/openwrt/`, adapted to the VM context and
to OpenWrt 25.x (apk package manager).

The VM owns the `.1` / `::1` gateway on every internal segment; the host
bridges are L2 switches that additionally take a DHCP address from the
segment's dnsmasq, so the host is directly reachable inside every segment.
This mirrors the linux-setups controller role where the OpenWrt box is the
router for dedicated LAN/VLAN segments.

## Topology

```
WAN   eth0  192.168.41.201/24   base-services bridge (same L2 as Docker/Traefik)
                                    gw 192.168.41.1 (host), NAT to uplink,
                                    IPv6 GUA ::201/64 (host NDP-proxies ::1)
LAN   eth1  172.18.0.1/24       openwrt-lan bridge (L2 + host DHCP)   ULA fd00:18:0::/64
IOT   br-iot (port eth2) 172.18.1.1/24   openwrt-iot bridge (L2 + host DHCP)  ULA fd00:18:1::/64
TOR   br-tor (port eth3) 172.18.2.1/24   openwrt-tor bridge (L2 + host DHCP)  ULA fd00:18:2::/64
MISC  eth4  172.18.3.1/24       openwrt-misc bridge (L2 + host DHCP)  ULA fd00:18:3::/64
```

- iot/tor are **bridged inside the VM** (`br-iot`/`br-tor` with `eth2`/`eth3` as
  bridge ports) so the OpenVPN `tap1`/`tap2` devices can be attached - the same
  layout as linux-setups. lan/misc use `eth1`/`eth4` directly.
- Host bridges (`openwrt-lan/-iot/-tor/-misc`) use Deterministic MACs
  (`02:ac:00:00:00:01`-`04`) and are managed by ifupdown in
  `inet manual` / `inet6 manual` mode and persist across reboots. The v4 DHCP
  lease comes from the segment's dnsmasq (host presence in every segment); a
  systemd timer (`symbios-ow-bridge-dhcp.timer`) retries the lease while the
  VM is still down after boot. The timer unit runs with `KillMode=process` so
  the spawned `dhclient` daemons survive the oneshot unit's exit.
- Clients on a segment use the VM as gateway + DHCP/DNS. All DNS is hijacked:
  lan + misc go through the router's dnscrypt-proxy (+Tor), iot + tor through
  dnscrypt-proxy-max (heavier blocklists).

## First-boot scripts (injected into the image)

Three files are injected into the root filesystem at build time and run on the
VM's first boot:

| File | Phase | What it does |
|------|-------|--------------|
| `/etc/uci-defaults/98-openwrt-network` | offline | WAN + internal interfaces/bridges, static IPv4 + IPv6, DAD off |
| `/etc/uci-defaults/99-openwrt-preconfig` | offline | firewall (wan/lan/iot/tor zones + rules + redirects), DHCP/DNS (4 dnsmasq instances), dnscrypt-proxy(+max), Tor, privoxy, bridged OpenVPN + easy-rsa, WireGuard uci, SSH/dropbear, remote syslog, avahi, netboot, msmtp (if inventory SMTP set) |
| `/etc/hotplug.d/iface/80-openwrt-postconfig` + `/etc/openwrt-postconfig.sh` | online (first `wan` ifup) | apk/opkg package install, WireGuard keys, `dh.pem` + easy-rsa PKI, service enable/restart, blocklist + netboot first-run |

Templates live in `services/openwrt-vm/templates/` and are rendered by the
playbook from `ow_networks` + `openwrt_*`/`openwrt_*` variables.

### linux-setups playbook mapping

The preconfig script is the consolidated first-boot equivalent of the
`/data-crypt/share/github/linux-setups/openwrt/` playbooks. Each section header
names the playbook(s) it consolidates:

| linux-setups playbook | preconfig section |
|-----------------------|-------------------|
| `basics.yml` | §1 (timezone/hostname + `irqbalance`) |
| `logserver.yml` | §2 (remote syslog to `{{ vm_gateway }}`) |
| `ssh.yml` | §3 (dropbear lan 22 / wan 44, key-only) |
| `firewall.yml` | §4 (zones, forwardings, wan exposes) |
| `firewall_allow_internet.yml` | §4 (`rule_forward_internet_all`: lan->wan 1-65535) |
| `firewall_hijack_connections.yml` | §4 (lan dns/ntp to self, iot/tor to their dnsmasq) |
| `iot.yml` | §5 (br-iot 172.18.1.1, DHCP/DNS via 127.0.0.56) |
| `tor.yml` | §6 + §13 (br-tor 172.18.2.1, Tor, privoxy, routing) |
| `avahi.yml` | §7 (mDNS reflector eth1/br-iot/br-tor/eth4) |
| `wireguard-lan.yml` + `wireguard-tor.yml` | §8 (wg_lan 192.168.44.1 / wg_tor 192.168.45.1) |
| `openvpn-tor.yml` + `openvpn-iot.yml` | §9 + §16 (bridged VPN + easy-rsa + cron) |
| `dhcp.yml` | §10 (lan + misc pools on the main dnsmasq instance) |
| `netboot.yml` | §11 (netboot.xyz via dnsmasq tftp + cron update) |
| `dnscrypt-proxy.yml` | §12 (6 DoH resolvers through Tor) |
| `firewall.yml` (port-forward duplication) | §14 (dup wan redirects to iot/tor) |
| `smtp.yml` | §15 (msmtp only when inventory SMTP set) |

### DNS design (adaptation to the VM)

The router mirrors linux-setups `dhcp.yml`: each dnsmasq instance uses its own
resolver file. On the VM those are:

| Resolver file | Upstream | Used by |
|---------------|----------|---------|
| `/etc/resolv.dnsmasq.lan` | `127.0.0.55` (dnscrypt-proxy via Tor) | lan + misc dnsmasq |
| `/etc/resolv.dnsmasq.iot` / `.tor` | `127.0.0.56` (dnscrypt-proxy-max via Tor) | iot / tor dnsmasq |

`openwrt_upstream_lan_dns` (default `127.0.0.55`) only drives the lan resolver
file; the WAN interface resolver and the postconfig package-install bootstrap
use `vm_dns` (`network.wan.dns` + the temporary `/etc/resolv.conf`), so the
router itself never depends on its own Tor/DNSCrypt chain for the initial
package install. `network.lan.dns` is intentionally left unset - netifd would
otherwise merge it with `wan.dns` into `/etc/resolv.conf` on every boot.

The postconfig only writes `/etc/openwrt-postconfig.done` when the package
phase succeeded. On package errors it logs to `/var/log/openwrt-package-errors.log`
and retries on the next `wan` ifup (`ifdown wan && ifup wan` or
`ubus call network.interface.wan up` to force it).

## Services / ports exposed

| Service | Port | Scope |
|---------|------|-------|
| LuCI (Traefik, Authelia) | 80/443 | internet |
| dropbear SSH | 22 (lan) / 44 (wan) | key-only, root password auth disabled |
| dnscrypt-proxy (lan/misc DNS) | 127.0.0.55:53 | router local |
| dnscrypt-proxy-max (iot/tor DNS) | 127.0.0.56:53 | router local |
| dnsmasq lan/misc | 53 + DHCP | lan + misc segments |
| dnsmasq iot | 53 + DHCP on 172.18.1.x | iot segment |
| dnsmasq tor | 53 + DHCP on 172.18.2.x | tor segment |
| Tor | SOCKS 9050, TransPort 9040, DNS 9053 | router local |
| privoxy | 8118 | tor segment |
| OpenVPN torvpn | 1194 udp (wan) | bridged into br-tor (tap2) |
| OpenVPN iotvpn | 1195 udp (wan) | bridged into br-iot (tap1) |
| WireGuard wg_lan | 59666 udp (wan) | lan VPN |
| WireGuard wg_tor | 59667 udp (wan) | tor VPN |
| TFTP netboot (netboot.xyz) | 69 | lan segment |
| avahi mDNS reflector | 5353 | between eth1, br-iot, br-tor, eth4 |
| remote syslog | udp to 192.168.41.1 | VM -> host logserver |

## Config files / directories inside the VM

| Path | Purpose |
|------|---------|
| `/etc/dnscrypt-proxy2/dnscrypt-proxy.toml` (+ `-max.toml`) | DoH proxy configs (through Tor) |
| `/etc/tor/torrc` | Tor relay/exit-policy config |
| `/etc/nftables.d/10-tor_routing.sh` | fw4 transparent-proxy include for br-tor |
| `/etc/scripts/dnscrypt-proxy-blocklist-update.sh` | blocklist updater (writes doh_/tor_ ipsets) |
| `/etc/scripts/tor-nodes-blocklist-update.sh` | Tor node blocklist updater |
| `/etc/scripts/tor_whitelist.sh` | destination whitelist for direct (non-Tor) access |
| `/etc/scripts/netboot.sh` | downloads netboot.xyz images to /srv/tftp |
| `/etc/scripts/firewall_port_forwards_from_wan_to_newzone.sh` | re-opens wan redirects for iot/tor |
| `/etc/scripts/openvpn-{tor,iot}-easyrsa.sh` | PKI regeneration (restarts openvpn) |
| `/etc/scripts/openvpn-{tor,iot}-tap-in-bridge.sh` | keeps tap devices in the bridges |
| `/etc/wg_lan/` `/etc/wg_tor/` | WireGuard server keypairs (`server_privatekey`/`server_publickey`) |
| `/etc/openvpn/{tor,iot}-dev2bridge.sh` | openvpn up-scripts attaching taps to br-tor/br-iot |
| `/etc/openvpn/{tor,iot}-easy-rsa/` | easy-rsa PKI (CA + server + client certs) |
| `/etc/msmtprc` | SMTP relay config (only when inventory SMTP is set) |
| `/etc/avahi/avahi-daemon.conf` | mDNS reflector scope |
| `/etc/scripts/*` | first-boot + cron helper scripts |
| `/srv/tftp/` | netboot.xyz boot files |

## Cron jobs (root crontab)

| Time | Job |
|------|-----|
| `15 4 * * *` | netboot.xyz update |
| `15 5 * * *` | Tor node blocklist update |
| `15 6 * * *` | dnscrypt blocklist update (+ ipsets) |
| `1 4 * * *` / `1 5 * * *` | dup wan port-forwards to iot / tor zones |
| `*/5 * * * *` | keep tap1/tap2 in br-iot/br-tor |
| `*/15 * * * *` | tor whitelist ipset refresh |
| `15 9 * * *` / `15 10 * * *` | easy-rsa PKI regeneration (tor / iot) |

## Firewall summary (preconfig)

- Zones: `wan` (ACCEPT in, masq, no offload - virtio NIC), `lan` (+misc, ACCEPT),
  `iot` (REJECT), `tor` (REJECT). Forwardings lan->wan, lan->iot, lan->tor.
- Redirects hijack DNS (53) + NTP (123) from every zone to the router itself
  (lan/misc) or to the iot/tor dnsmasq addresses.
- wan exposed: 80/443, ssh 22 + 44, icmp, openvpn 1194/1195, wireguard 59666/59667.
- `rule_forward_internet_all`: lan -> wan tcp/udp 1-65535 ACCEPT.
- DOH server IPs and Tor node IPs are filled into `doh_ipv4/6` + `tor_ipv4/6`
  nft sets by the blocklist cron scripts; `tor_whitelist` (from
  `/etc/tor_whitelist`) bypasses Tor for whitelisted destinations.
- `10-tor_routing.sh` transparently DNATs tor-segment TCP (except local ranges,
  Tor nodes, whitelisted 443) to `172.18.2.1:9040`.

## Fresh install / reset

- The VM's root password is generated by the playbook into
  `/symbios/services/openwrt-vm/env` (`OPENWRT_ROOT_PASSWORD=...`); the host SSH
  public key is added to `/etc/dropbear/authorized_keys`.
- LuCI: `https://openwrt.<base_domain>` (Authelia group `openwrt-vm`), serial:
  `virsh console openwrt`.
- To rebuild from scratch: uninstall the service via the WebUI or remove
  `services_root/openwrt-vm/images/openwrt.qcow2` + `virsh undefine openwrt --nvram`
  and re-run the playbook.

## Notes and caveats

- Package install uses `apk` on OpenWrt 25.x (opkg fallback); bootstrap DNS
  temporarily points at `{{ vm_dns }}` and is restored right after.
- Two package-install clobber cases are handled in the templates: the dnsmasq
  package ships `/etc/config/dhcp` with `enabled`/factory defaults, so the
  offline preconfig cannot rely on its own UCI values surviving apk; the
  postconfig re-asserts `irqbalance.irqbalance.enabled='1'` after the package
  phase (the preconfig commit is overwritten by the installed package config).
  The DHCP/DNS reset (`while uci delete dhcp.@dnsmasq[0] / @dhcp[0]`) must run
  *before* the iot/tor sections in the preconfig - placed at the start of §5.
  Verify after a fresh build: `uci show dhcp | grep =dnsmasq` shows
  `lan_dnsmasq`, `iot_dnsmasq`, `tor_dnsmasq`, and `ps w | grep 'dnsmasq -C'`
  shows the three instances plus a running `irqbalance`.
- `kmod-wireguard` may not exist on every target/version - failures are logged
  and retried (WireGuard interfaces only come up once the kernel module exists).
- `openwrt_timezone` defaults to the tzdb name (musl maps it directly); override
  with a POSIX string for glibc images.
- The remaining feature playbooks under `services/openwrt-vm/features/`
  (`ddns-ipv6.yml`, `dhcp-hosts.yml`, `dns_a.yml`) cover only user-specific
  DNS entries that are **not** baked into the build-time preconfig. The former
  VM features (iot, wireless, wireguard, dnscrypt, ssh, logserver, smtp,
  host-bridge/passthrough, DynDNS IPv4) were removed because the playbook now
  bakes the network/router setup into the VM at build time or they are no
  longer needed.