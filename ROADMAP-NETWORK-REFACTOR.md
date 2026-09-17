# Network Architecture Refactor — Roadmap & Progress

Status legend: `[x]` done and validated as far as this environment allows · `[~]` done with a caveat (see notes) · `[ ]` not done.

**Important environment note (read first):** this implementation was done from a Windows development machine against the git repository, with no SSH access to the actual Ubuntu mini-PC gateway and no Linux kernel/nftables/Docker available locally to execute against. "Validated" below means: `bash -n` syntax check (a real bash binary is available via Git Bash) and careful manual review of nftables/systemd/Docker syntax against documented grammar. It does **not** mean the script has been run on real hardware. See "Phase 11" at the bottom for exactly what still needs a hardware pass, and by whom.

---

## Phase 0 — State model & safety net
**Status: [x] done**

- New state files added: `${STATE_DIR}/lan-allow.list`, `${STATE_DIR}/wan-allow.list` (allow-list semantics).
- Legacy `${STATE_DIR}/wan-block.list` kept on disk, read-only, purely informational during migration (`wanaccess_seed_defaults()` prints a notice if it's found).
- **Deviation from original plan:** `backup_once()` was *not* extended to snapshot `docker daemon.json`/compose.yaml, because `backup_once()` only runs during initial LAN/WAN network setup — before Docker is even installed, so `daemon.json` wouldn't exist yet. Instead, `configure_docker_daemon()` (Phase 7) backs up `/etc/docker/daemon.json` itself, at the point it first writes to it, following the same "back up only if pre-existing, only once" pattern already used by `configure_nftables()` for `/etc/nftables.conf`. Functionally equivalent, just relocated to the correct point in time.

## Phase 1 — IPv6 explicit disablement
**Status: [x] done**

- `configure_forwarding()` now writes `net.ipv6.conf.all.disable_ipv6=1` and `net.ipv6.conf.default.disable_ipv6=1` to `/etc/sysctl.d/99-router.conf`.
- `net.ipv4.ip_nonlocal_bind=1` removed — no longer needed once Zashboard binds `0.0.0.0` in host network mode (Phase 8) instead of a Docker-published `${LAN_IP}:80`.
- `full_diagnostics()` now shows live IPv6 status.

## Phase 2/3/4 — nftables rewrite (structural + atomic element sync + atomic cutover)
**Status: [x] done, [~] one caveat**

Implemented as a single pass since the three were tightly coupled in practice:

- **Consolidated into one table** (`table inet gateway`) holding both filtering (`input`/`forward`/`output`) and NAT (`postrouting`/`prerouting`), instead of the two tables (`inet gateway_filter` + `ip gateway_nat`) described in the original roadmap. Modern nftables (0.9.1+/kernel 5.2+, well below Ubuntu 20.04's baseline) supports NAT hook chains inside `inet`-family tables, so one table can hold everything and reference the same sets/maps from both filter and NAT chains, without duplicating `wan_if` across two tables. **This is a simplification over the original plan, not a scope change** — same single-owner guarantee, less duplication.
- `write_nft_structural()` renders `/etc/nftables.conf` from state files every time state changes (cheap — it's just a file write). Because of this, **the separate `gateway-nft-restore.service` unit from the original Phase 6 plan is no longer needed**: the on-disk file is always already correct, so a reboot or `systemctl restart nftables` reproduces the exact state through the standard `nftables.service` alone. This removes one whole moving part from the original design.
- `@wan_if`, `@lan_allow_tcp/udp`, `@wan_allow_tcp/udp` sets and `@portfwd_tcp/udp` maps hold the "data layer." `nft_add_port`/`nft_del_port`/`nft_add_portfwd`/`nft_del_portfwd`/`nft_set_wan_if` perform single `nft add/delete element` calls for routine additive menu edits — no reload, no window with rules missing.
- Structural changes and *removals* (which can reduce reachability, unlike additions) go through `nft_apply_with_confirm()` / `nft_confirm_or_rollback()` — **see "Post-review corrections #3" below for the current (revised) design**, which replaced the original systemd-timer-based mechanism with a synchronous inline countdown.
- WAN allow-list default: **TCP 22, TCP 80, TCP 9090** (everything else default-deny from WAN) — **see Post-review correction #2**.
- LAN allow-list default: **TCP 22, TCP 80, TCP+UDP 7890, TCP 9090, TCP+UDP 53** (everything else default-deny from LAN too, per your final decision — flip from the original roadmap's "LAN default-allow").
- `wan_out_iface()` is now used **only for display** (status screens, port-forward table); no firewall rule generation reads it directly — everything references the live `@wan_if` set instead.
- **Bug found and fixed during review:** the `forward` chain's MSS-clamp rules (`tcp option maxseg size set rt mtu`) were placed *after* the terminal `iifname "lan" accept` rule, making them unreachable dead code for every LAN-forwarded packet (nftables `accept` ends chain evaluation). This ordering bug was inherited from the pre-refactor ruleset, not introduced by this rewrite, but is fixed now — the clamp rules run first, `accept` last.
- **Real bug found via actual `nft` execution (not just review):** a fresh render produced `elements = {  }` (empty) for any set/map with no data yet (e.g. WAN UDP allow-list, port-forward maps on a clean install) — nftables rejects an empty `elements` clause as a syntax error. Fixed: `nft_elements_clause()` now omits the line entirely when there's no data. This was caught by you running the actual installer and pasting the real `nft` error, exactly the kind of check this environment cannot do on its own — see the "Environment note" at the top.

**Caveat:** I cannot run `nft -c -f` from this Windows environment (no nftables binary available here, and I did not start Docker Desktop to fabricate one). The nftables syntax was written against documented nftables grammar (concatenated maps for DNAT, `inet`-family NAT requiring explicit `dnat ip to ...`, implicit protocol dependency of `tcp dport`/`udp dport` matches) as carefully as I can without an executable check. **This must be verified with `nft -c -f /etc/nftables.conf` on the actual Ubuntu box before trusting it** — both `configure_nftables()` and `nft_apply_with_confirm()` already run this check automatically and refuse to load anything that fails it, so the worst case is "the script correctly refuses to apply a bad ruleset and tells you," not "a bad ruleset goes live."

## Phase 5 — Dynamic `@wan_if` wiring into WAN-mode switching
**Status: [x] done**

- `switch_wan_mode()` calls `nft_set_wan_if "$(wan_out_iface)"` after successfully reconfiguring the link — a single atomic set update, not a firewall reload.
- `pppoe_rollback_to_dhcp()`, `pppoe_enable()`, `pppoe_disable()` all call `write_nft_structural` after mode changes to keep the on-disk file in sync (the live kernel set is already updated by `switch_wan_mode()`).

## Phase 6 — Boot-time state restore & service ordering
**Status: [x] done (redesigned — see Phase 2/3/4 deviation)**

- The originally-planned separate `gateway-nft-restore.service` was dropped as unnecessary (see above) — its job is now done implicitly by `write_nft_structural()` always keeping `/etc/nftables.conf` current.
- `dnsmasq.service.d/override.conf` gained `After=nftables.service` (in addition to the existing `network-online.target`), so DHCP/DNS never serves LAN clients before the firewall's default-deny + allow-list is active. Defense-in-depth, not a functional dependency (dnsmasq works either way).

## Phase 7 — Docker daemon network model
**Status: [x] done, [~] one caveat**

- New `configure_docker_daemon()`: writes `/etc/docker/daemon.json` with `"iptables": false`, `"ip6tables": false`, `"live-restore": true`; backs up any pre-existing `daemon.json` first; restarts the daemon only if it's already running.
- Wired into `install_docker()`, runs after Docker Engine is confirmed working.

**Caveat / correction to the original roadmap's claim of "zero Mihomo impact":** `live-restore` protects a running container across a daemon restart *only if it was already active in the daemon that's shutting down*. The very first time an existing installation turns `live-restore` on, the daemon being restarted does **not** have it active yet — so on an **upgrade of an already-running gateway**, this one restart will briefly stop and restart the Mihomo container (a few seconds, `restart: unless-stopped` brings it back automatically). On a **fresh install** (no containers running yet), there is nothing to disrupt. This is a one-time cost on upgrade, not a repeated one — every restart *after* this one is fully protected. I'm flagging this because my Phase 7 description in the original roadmap overstated the guarantee; it's now stated accurately here and in the script's own comment above `configure_docker_daemon()`.

## Phase 8 — Zashboard → host network mode
**Status: [x] done**

- `create_compose()`: Zashboard service now uses `network_mode: host`, `ports:` removed.
- `install_stack()`'s post-startup checks simplified: Zashboard no longer has a "may legitimately fail to bind, that's OK" retry path, since binding `0.0.0.0:80` in host mode no longer depends on the LAN link being up. A failure to start is now treated as a real failure (matching how Mihomo's startup was already checked).

## Phase 9 — Menu/UX rewiring
**Status: [x] done**

- `wanaccess_menu()`/`wanaccess_add_interactive()`/`wanaccess_remove_interactive()` rewritten for allow-list semantics (was block-list), backed by `nft_add_port`/`nft_del_port` instead of a full rewrite+reload.
- New `lan_allow_menu()`/`lan_allow_add_interactive()`/`lan_allow_remove_interactive()` — same pattern, for LAN.
- `portfwd_add_interactive()`/`portfwd_remove_interactive()` now use `nft_add_portfwd`/`nft_del_portfwd` (map elements) instead of regenerating the whole prerouting chain.
- `firewall_menu()` shows LAN allow-list count, WAN allow-list count, and gained a menu item for the LAN allow-list. (The "pending confirmation" status line and separate "confirm" menu item described in an earlier revision of this file were removed — see Post-review correction #3.)
- `quick_status()` and `full_diagnostics()` updated to read the new table name (`inet gateway`) and show LAN/WAN allow-list counts, IPv6 status, and Docker's iptables setting.

## Phase 10 — Rollback & full-removal path updates
**Status: [x] done**

- `full_remove()`: restores or removes `/etc/docker/daemon.json` based on whether one pre-existed; disables and removes the `gateway-fw-confirm` timer/service if one is pending; deletes the single `inet gateway` table instead of the old two-table names. The existing `rm -rf "$STATE_DIR"` already covers the new `lan-allow.list`/`wan-allow.list`/confirm-backup files — no separate cleanup needed there.
- User-facing summary text in `full_remove()` updated to mention the new artifacts being removed.

---

## Summary of deviations from the originally-approved roadmap

1. **One nftables table instead of two** (`inet gateway` holds filter + NAT) — simpler, same guarantees, since modern nftables supports NAT hooks in `inet`-family tables.
2. **No separate `gateway-nft-restore.service`** — made redundant by always keeping `/etc/nftables.conf` in sync on every state change; one fewer moving part than planned.
3. **LAN policy is default-deny + allow-list** (not default-allow as in the original architecture proposal) — superseded by your explicit follow-up decision; implemented symmetrically with the WAN model.
4. **Docker `live-restore` protection has a one-time gap** on the very first activation on an already-running install (brief Mihomo restart) — the original roadmap claimed zero impact for this phase; corrected here.

None of these change what was approved in spirit — they either simplify the mechanism or reflect your later, more specific decision on LAN policy.

---

## Post-review corrections (reported after Phase 0-10 implementation)

You reported three issues after running the installer for real. Corrections below, in the order you raised them.

### Correction 1 — BLOCKING: LAN clients get DHCP + ping works, but websites don't load and Mihomo shows no connections for them

**Status: [ ] NOT resolved — needs live diagnostics from the actual box, not a guess from here.**

I will not fabricate a fix for this without data. What I *can* do from a code review alone:

**Confirmed-and-fixed while investigating** (see Phase 2/3/4 above): the MSS-clamp ordering bug (dead code after a terminal `accept`). Worth fixing regardless, but on its own it does not explain your symptom — a PMTU/MSS problem would show up as connections that *start* (and appear in Mihomo) but then hang/time out, not as zero visibility in Mihomo's connection list.

**Leading hypothesis, in order of likelihood, given "ping works but nothing shows in Mihomo":**
1. **DNS resolution is failing for LAN clients.** `ping 8.8.8.8` uses a raw IP and needs no DNS; a browser needs a hostname resolved first. If resolution fails, the browser never makes a connection attempt at all — which would explain *both* "site doesn't load" and "nothing appears in Mihomo" (there is nothing to sniff) without requiring any TUN/routing bypass theory. This is the simplest explanation consistent with both symptoms.
2. **Mihomo's TUN isn't intercepting LAN traffic at all** (a real bypass) — possible if `auto-route` didn't successfully install its policy-routing rules on this box, for a reason unrelated to my nftables changes (e.g., a routing-table conflict, TUN device not up, `NET_ADMIN` capability issue in the host-mode container). Note: most ordinary websites are **not supposed to appear as "proxied"** in Mihomo's connections view anyway — only `youtube`/`discord`/`telegram`/`ai`/`category-geoblock-ru` rule-sets route to `PROXY`; everything else is `MATCH,DIRECT`. If Mihomo's connections view is filtered to proxied-only, "I don't see the site in Mihomo" for a non-rule-matched domain could be **expected, correct behavior** — worth ruling out before assuming a bypass bug.
3. Something in the new default-deny **LAN input** policy is unexpectedly blocking DNS (port 53) despite it being in the default allow-list — reviewed the code path and it looks correct (`lan_allow_seed_defaults` includes `tcp 53`/`udp 53`, and I rendered the generated ruleset locally to confirm both appear in `@lan_allow_udp`/`@lan_allow_tcp`), but "looks correct in the generated file" isn't the same as "confirmed correct against the live kernel table" — needs verification per below.

**Diagnostics needed from you (run on the gateway and from a LAN client), please paste the output:**

```bash
# On the gateway — confirm the live ruleset actually matches the rendered file
sudo nft list ruleset

# On a LAN client — does DNS resolve AT ALL via the gateway?
nslookup google.com 192.168.100.1
# or: dig @192.168.100.1 google.com

# On a LAN client — bypass DNS entirely, connect by IP directly, to isolate
# "DNS problem" from "forwarding/NAT/Mihomo problem":
curl -v --resolve example.com:80:93.184.216.34 http://example.com/

# On the gateway — is dnsmasq actually forwarding upstream queries OK?
journalctl -u dnsmasq -n 50 --no-pager

# On the gateway — capture what actually crosses the wire during a failed
# browser request from a LAN client (run this, then try loading a site):
sudo tcpdump -ni lan port 53 or port 80 or port 443 -c 40
sudo tcpdump -ni wan port 53 or port 80 or port 443 -c 40   # or ppp0 if PPPoE

# On the gateway — did Mihomo actually install TUN routing?
ip link show | grep -i -E 'meta|tun'
ip rule show
ip route show table all | grep -i -E 'meta|tun'

# Mihomo's own connections API (ground truth, independent of the Zashboard UI)
curl -s http://127.0.0.1:9090/connections -H "Authorization: Bearer <your CLASH_SECRET>" | head -c 2000
```

Once you paste this output (or tell me which of these already points at the answer), I'll implement the actual fix and update this section.

### Correction 2 — WAN default allow-list must also include TCP 9090

**Status: [x] done.**

`wanaccess_seed_defaults()` now seeds `tcp 22`, `tcp 80`, **`tcp 9090`**. Ports 53 and 7890 remain closed from WAN by default (per your original decision), only 22/80/9090 are open by default, all still individually removable/addable via the WAN allow-list menu.

### Correction 3 — Firewall confirmation must be automatic and inline, not a separate menu/CLI step

**Status: [x] done — mechanism redesigned.**

The systemd-timer-based mechanism (`gateway-fw-confirm.timer`/`.service`, a separate "confirm" menu item, the `confirm-firewall` CLI arg) is **removed entirely**. Replaced with a synchronous, blocking, inline countdown built directly into the same function every risky change already calls:

- `nft_snapshot()` — captures the actual live ruleset (`nft -s list ruleset`, ground truth) immediately before a risky change is made.
- `nft_confirm_or_rollback()` — called immediately after the change is already live. Prints:
  ```
  [!] Правила firewall изменены и требуют подтверждения.
  [!] Проверьте SSH / Zashboard / Mihomo API с другого устройства, не закрывая эту сессию.
  [?] Подтвердить изменения? [y/N]  (откат через 05:00)
  ```
  ...with the `05:00` visibly counting down every second in place (carriage-return redraw). A single `y`/`Y` keypress (no Enter needed) confirms immediately and cancels the rollback. `n`/`N` or the countdown reaching zero triggers an immediate rollback to the snapshot. No systemd unit, no background timer, no separate confirmation step — the whole thing is one blocking function call.
- **Scope decision (documented here since it wasn't explicit in your request):** this wraps every change that can *reduce* reachability — initial install, LAN IP/interface change, NAT on/off, firewall enable, and **removing** a WAN or LAN allow-list entry. It deliberately does **not** wrap *adding* an allow-list entry or a port-forward rule, since those can only expand reachability and cannot themselves cause a lockout. If you'd rather every single change (including additions) go through the countdown, tell me and I'll extend it — right now it's scoped to "can this action reduce what's reachable."
- Verified the countdown mechanism itself (decrementing display, timeout → rollback, keypress → confirm) with an isolated bash test harness (stubbed `nft`/`systemctl`, a FIFO to simulate a delayed keypress) — both the timeout-rollback and keypress-confirm paths behave correctly. This is mechanism-level validation only; it does not substitute for testing the actual rollback content (`nft -s list ruleset` snapshot/restore) against a real ruleset on real hardware.

---

## Post-review corrections, round 2 (reported after applying round 1)

After applying the round-1 fixes, `ping 8.8.8.8` from LAN stopped working entirely, and three more symptoms appeared: the LAN interface wasn't renamed to `lan` (stayed `enp3s0`), LAN clients stopped getting DHCP leases, and Zashboard wasn't immediately reachable after install. You asked me to investigate before touching the original Mihomo/HTTPS question.

### Confirmed and fixed: DHCP (UDP/67) was missing from the LAN default-deny allow-list

**Status: [x] done.** This is a certain, code-provable bug, not a guess: when I flipped LAN access to default-deny in the original implementation, I built the default allow-list from the WAN-facing service list and the ports mentioned in your requirements — and simply missed that the gateway's own DHCP **server** needs to receive on UDP/67 from LAN clients. With LAN now default-deny, the gateway's own firewall was silently dropping every DHCP request before dnsmasq ever saw it. Fixed in `lan_allow_seed_defaults()`, with a self-heal for installs that already created the file without it (it backfills `udp 67 DHCP` into an existing file automatically the next time the firewall is (re)configured — no manual edit needed, just reinstall/reconfigure).

### Not yet resolved: LAN interface not renamed to `lan`

**Status: [ ] NOT resolved — this code path is unchanged by my refactor, and I do not have enough information to diagnose it further without live data.**

I want to be precise about what I did and didn't touch: `netplan_body()`, `write_netplan()`, `configure_network_first()`, `apply_netplan_checked()`, and `choose_iface_manual()` — everything responsible for detecting interfaces and asking netplan to rename them — are **byte-for-byte unchanged** from before this refactor. I did not edit any of that code. So this is either a pre-existing issue that happened not to surface before, or something specific to this box's boot/hardware timing — not a regression I can attribute to a specific line I changed.

That said, this is very likely the **single root cause behind ping, DHCP, and possibly the slow Zashboard start all at once**, and it deserves priority over my DHCP-port fix above: `dnsmasq.conf` says `interface=lan`, and my new firewall rules match `iifname "lan"` — if the physical NIC is actually still named `enp3s0`, **neither dnsmasq nor any of the firewall's LAN-matching rules would ever see traffic from it at all**, regardless of the allow-list contents. That would explain why your manual rename (item 4) didn't fix DHCP either — a live `ip link set enp3s0 name lan` changes the interface's name but does not by itself make already-running `dnsmasq` (or reload nftables) recognize the change without a service restart, and doesn't persist across reboots since it bypasses netplan entirely.

I am not going to guess a fix for the rename itself — I need to see why netplan's MAC-based rename isn't sticking on this specific box. Please run these and paste the output:

```bash
# Actual current interface names, MACs, and link state
ip -br link show

# What netplan is actually configured to do (compare MACs here against the above)
cat /etc/netplan/01-gateway.yaml

# What this script has stored as the LAN/WAN MAC addresses — compare against
# the real MAC of enp3s0 from `ip -br link show` above. (CLASH_SECRET and
# SUBSCRIPTION_URL lines contain secrets — feel free to redact just those two.)
cat /var/lib/mihomo-gateway/gateway.env

# networkd's own view — does it think "lan" exists, or only "enp3s0"?
networkctl list
networkctl status lan 2>&1
networkctl status enp3s0 2>&1

# Boot-time rename attempt/failure, if any, from systemd-networkd's own log
journalctl -u systemd-networkd -b --no-pager | tail -100

# Is dnsmasq actually running, and which interface does it say it bound to?
systemctl status dnsmasq --no-pager -l
journalctl -u dnsmasq -b --no-pager | tail -50

# The live firewall ruleset — confirms both the DHCP-port fix and whether
# "lan"/"wan" as interface names mean anything on this box right now
sudo nft list ruleset
```

Once I can see whether the MAC recorded in `gateway.env` actually matches the live NIC, and what networkd/udev logged about the rename attempt, I'll know whether this is a stale/mismatched MAC (e.g. from repeated reinstall testing during this session), a NIC enumeration timing issue at boot, or something else — and I'll fix the actual cause rather than guessing.

**Zashboard not immediately available** is plausible as a side effect of either of the above (if `enp3s0`/`lan` confusion also affected `${LAN_IP}` reachability at the moment you checked), or as an artifact of the Docker daemon-restart timing from Phase 7 if Zashboard happened to already be running from an earlier attempt when `configure_docker_daemon()`'s one-time `live-restore` activation restart occurred (documented caveat in Phase 7 above). I'm not treating this as resolved either way until the interface issue is sorted out, since it may just be a downstream symptom of it.

### Diagnostic output received — conclusion: the interface rename actually worked; DHCP is actually working

**Status: [x] resolved — was a misdiagnosis on my part, not a real bug** (plus one open question for you, below).

The diagnostics you ran show:
- `ip -br link show`: the interface is named **`lan`**, not `enp3s0`. `networkctl status enp3s0` → `"Interface enp3s0 not found."` — `enp3s0` genuinely doesn't exist anymore; it was renamed successfully.
- `journalctl -u dnsmasq`: a **complete, successful DHCP handshake** — `DHCPDISCOVER(lan)` → `DHCPOFFER` → `DHCPREQUEST` → `DHCPACK(lan) 192.168.100.196 ... DESKTOP-3MMOF19` — DHCP is working.
- `nft list ruleset`: confirms the udp/67 fix is live (`lan_allow_udp` includes `67`) and the MSS-clamp ordering fix is live (clamp rules now run before the terminal `accept`).

So: the "`LAN интерфейс: enp3s0`" line you saw was **not** reporting a failed rename — it's `full_diagnostics()` printing the *original* physical NIC name stored at setup time for MAC-matching purposes, a field that was never meant to update after the rename and was simply a confusing label. I've fixed that display (see below) so this can't cause the same false alarm again.

**One real anomaly remains, and it's the likely explanation for "ping doesn't work":** at the exact moment you captured `ip -br link show`, the LAN interface showed `NO-CARRIER` (cable unplugged), and `journalctl -u systemd-networkd` shows `lan: Lost carrier` at 08:28:08 — about 3 minutes *after* the successful DHCP lease at 08:25:03. That reads as: your test device successfully got an IP over a live cable, then the physical link dropped (cable unplugged/reseated, or a switch-port event) before or during your ping test — not a firewall/software issue. **Could you confirm the LAN cable was actually connected when you tested `ping 8.8.8.8`, and retest with a confirmed live link?**

**Fixed as a result of this investigation (defensive/legibility improvements, not bug fixes to a broken mechanism):**
- `full_diagnostics()`'s network section now clearly labels `LAN_IFACE`/`WAN_IFACE` as "original interface (MAC-match)" and separately reports whether the `lan` interface actually exists, has an address, and — critically — whether its cable is currently connected.
- `quick_status()`'s one-line "Сеть" indicator now also checks for `NO-CARRIER` explicitly. Previously it only checked whether the LAN address was configured, which `ignore-carrier: true` keeps true *even with the cable unplugged* — so a disconnected cable would have shown as "Сеть: OK", exactly the kind of misleading status that caused this confusion.

**Separate observation, not something I changed:** your `nft list ruleset` output shows `wan_allow_tcp` containing **22, 80, 7890, 9090** — port **7890** (Mihomo's proxy port) is currently open to the entire internet. That's not a default either version of this script has ever set (the default is 22/80/9090 only) — it looks like it was added via the WAN allow-list menu at some point, possibly while testing the original Mihomo/HTTPS issue. Worth double-checking whether you want the proxy port reachable from WAN, since an open proxy port is a real exposure (open-relay risk) if it wasn't intentional.

---

## Correction 1 resolved — actual root cause found from real diagnostics

**Status: [x] fix applied, [ ] not yet confirmed on hardware.**

With `nslookup`, `tcpdump` on both `lan` and `wan`, and `ip route show table all` / `ip rule show` from the real box, the actual root cause is now identified with direct evidence, not a guess:

- DNS resolution works fine (`nslookup google.com 192.168.100.1` returned correct results) — ruling out the DNS hypothesis.
- `tcpdump -ni lan`: LAN client SYNs to real destinations are captured entering the gateway.
- `tcpdump -ni wan`, same time window: **those SYNs never appear.** They enter via `lan` and never reach `wan`.
- `ip route show table all`: Mihomo's TUN (`auto-route: true`) has installed a route covering nearly the entire IPv4 address space via the `Meta` TUN device (routing table `2022`), with gaps only at `192.168.100.0/24`, `192.168.1.0/24`, `1.1.1.1/32`, and `8.8.8.8/32` — exactly matching `route-exclude-address` in `mihomo/config.yaml`. This is why `ping 8.8.8.8` specifically has worked this whole time (it's one of only two explicitly excluded destinations) while everything else gets pulled into the TUN.
- `ip rule show`: the rule directing traffic into that table (`not ... iif lo lookup 2022`) doesn't distinguish the host's own traffic from traffic it's forwarding for other LAN devices — both get redirected into the TUN identically.

**Root cause:** `mihomo/config.yaml` had `tun.auto-redirect: false`. `auto-route` alone is sufficient for a machine proxying only its own traffic (simple IP routing tricks work for locally-generated sockets); it is **not** sufficient for a machine acting as a transparent gateway for *other* devices' traffic — that specifically requires the NAT redirect rules `auto-redirect: true` installs, which correctly re-inject genuinely forwarded connections. Without it, a LAN client's forwarded packet gets captured into the TUN and then silently dropped instead of being proxied or passed through DIRECT — exactly matching every symptom (SYN vanishes, nothing appears in Mihomo's connection list since no valid connection is ever established).

**This predates the entire host-networking refactor.** `auto-redirect: false` was already the value in `mihomo/config.yaml` before any of Phases 0-10 — this was never something the nftables/Docker/interface work touched or could have caused. It's also why this exact symptom was present in your very first report, before any of the round-1/round-2 fixes. Per your original instruction ("do not redesign Mihomo unless the network architecture requires a change") — this qualifies: the architecture is specifically "gateway proxying other devices," which requires this setting, not a preference.

**Fix applied:** `mihomo/config.yaml`: `auto-redirect: false` → `auto-redirect: true`.

**How to apply without a full reinstall:** either (a) pull the updated repo and re-run the installer's "Установить/переустановить" (idempotent — re-renders config, restarts containers, doesn't touch anything else), or (b) for a quick manual test first: edit `auto-redirect: false` → `true` directly in `/opt/mihomo-gateway/config/config.yaml` and `docker restart mihomo`.

### Separate confirmed issue found in the same diagnostic dump: Docker's iptables-nft tables were still present

Your `nft list ruleset` output also showed four tables (`ip nat`, `ip filter`, `ip6 nat`, `ip6 filter`) with `DOCKER`/`DOCKER-USER`/`DOCKER-FORWARD` chains and live packet counters — meaning Phase 7's `"iptables": false` setting did **not** fully take effect. Root cause: setting `iptables: false` and restarting the daemon stops Docker from managing these *going forward*, but does not retroactively tear down chains a *previous* daemon run (before the setting existed) already created — they're left behind as orphaned but still-registered netfilter hooks.

Traced through what these specific leftover chains actually do to forwarded LAN traffic: their policy is `accept` and none of their rules match non-`docker0` traffic, so they don't appear to be the cause of the blocked-browsing symptom above — but their continued existence is still a real defect against this refactor's stated goal ("nftables is the single owner of ALL filtering/NAT"). **Fixed:** `configure_docker_daemon()` now also deletes these four tables (identified specifically by their `DOCKER` chain, so nothing unrelated is touched) once, right after the daemon restart that disables `iptables`. This will need one more "Установить/переустановить" (or a manual `sudo nft delete table ip nat` / `ip filter` / `ip6 nat` / `ip6 filter`) to actually apply on your box, since it's a script-level fix, not something that self-heals on its own.

---

## Phase 11 — End-to-end validation

**What was actually validated from this environment:**
- `bash -n install-gateway-docker.sh` — passes (no syntax errors).
- Manual review of every changed function for consistency (no remaining references to removed functions/files — verified by grepping for `write_nftables`, `reload_nftables`, `gateway_filter`, `gateway_nat`, `ip_nonlocal_bind` after the rewrite; all clear).
- Manual review of nftables rule syntax against documented nftables grammar (not executed).

**What could NOT be validated here, and must be run on the actual Ubuntu box before trusting this in production:**
1. `sudo nft -c -f /etc/nftables.conf` after a fresh render — confirms the nftables syntax is actually correct (the design assumes this, and the script itself will refuse to apply bad syntax, but the syntax has not been executed anywhere).
2. A full `sudo bash install-gateway-docker.sh` install run end-to-end on a real or test Ubuntu box.
3. Reboot test: confirm nftables/dnsmasq/docker/containers all come back correctly and in order.
4. WAN cable disconnect/reconnect (DHCP mode): confirm no manual intervention needed.
5. WAN DHCP lease renewal: confirm masquerade keeps working with a changed address.
6. PPPoE connect/reconnect/auto-rollback: confirm `@wan_if` correctly holds `ppp0` and the firewall keeps working through a reconnect.
7. LAN cable disconnect/reconnect: confirm DHCP/DNS keep working.
8. `systemctl restart docker`: confirm Mihomo survives (this is the `live-restore` guarantee — should hold true for every restart *after* the first Phase-7 activation).
9. `systemctl restart nftables`: confirm rules are restored correctly with no manual step.
10. Menu-driven additive edits (add a WAN port, LAN port, port-forward): confirm each takes effect immediately with no reload gap and no confirm prompt, using `nft list ruleset` before/after and an actual connection test.
11. Menu-driven removals (remove a WAN/LAN allow-list port) and structural changes (NAT toggle, firewall enable, LAN IP change): confirm the inline countdown appears, that a deliberate timeout or `n` correctly restores the previous ruleset (`nft list ruleset` before/after), and that `y` correctly keeps the new one.
12. `full_remove()` dry run on a disposable box/VM — confirm the machine returns to a clean pre-gateway state, including cleanup of any leftover `gateway-fw-confirm.timer`/`.service` units from an earlier revision if present.
13. **Blocking:** the Correction 1 diagnostics above, to actually identify and fix why LAN clients can't browse the web.

I did not fabricate results for any of these — they need to be run against the real hardware. I'd recommend running them in the order above (cheapest/lowest-risk first), ideally from a LAN-connected session for the earlier ones so a firewall mistake can't lock you out remotely.
