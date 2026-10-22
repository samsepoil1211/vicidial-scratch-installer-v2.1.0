# install-vicidial.sh — Production VICIdial Standalone Installer v2.1.0

One script, one server, production-ready. Replaces `main-installer.sh`, `alma-rocky9-ast16.sh`, `alma-rocky9-ast18.sh`, `alma-rocky-centos-8-ast18.sh` and friends with a single hardened, resumable installer.

**Status: live-tested end-to-end on two independent providers (UpCloud, OVH), both AlmaLinux 9 and Rocky Linux 9.** SIP registration and an inbound/outbound test call confirmed working on the UpCloud box. WebRTC/CyburPhone's actual browser handshake has not yet been tested (the SSL/cert code path has been verified).

**Supported OS:** AlmaLinux / Rocky Linux **8 and 9** (x86_64). The script auto-detects the OS and picks the right repos (EPEL per-version, remi per-version, CRB vs PowerTools). Anything else is refused cleanly at preflight. Debian/Ubuntu remain out of scope for the production path (the old alpha scripts stay in the repo for reference).

**Asterisk:** `16.30.1-vici` (default) or `18.21.0-vici` via `--asterisk 18`. chan_sip is enabled either way. (VICIdial renames the `-vici` patch tag on its download server periodically without notice — the script auto-detects and falls back to the newest matching build in the same major.minor series if the configured version 404s.)

---

## Quick start

```bash
cd /usr/src
git clone <this private repo> vicidial-install-scripts
cd vicidial-install-scripts
chmod +x install-vicidial.sh
./install-vicidial.sh
```

Interactive run asks only for the hostname and shows a config summary before touching anything.

### Fully unattended (cloud-init / Hetzner / UpCloud provisioning)

```bash
./install-vicidial.sh --yes --auto-resume \
    --hostname dialer1.example.com \
    --timezone America/New_York \
    --asterisk 16 --php 7.4 \
    --domain dialer1.example.com --email you@example.com \
    --carrier-ips "66.135.28.179,46.19.209.44"
```

**Always pass `--domain` on the first run if you want WebRTC/SSL.** Doing it later requires manually clearing one step marker (see "Adding SSL after the fact" below) — this is a known rough edge, not yet fixed.

With `--auto-resume`, the kernel-update reboot happens automatically and a one-shot systemd unit continues the install after boot. Without it, the script tells you to reboot and simply **resumes from where it stopped when you re-run it** — every step is tracked in `/var/lib/vicidial-installer/`.

---

## Key behaviors

| Area | Behavior |
|---|---|
| **Resumable** | Each step records completion; re-running after any failure or reboot skips finished steps. `--reset` starts over. |
| **Reboot checkpoint** | If `dnf update` installs a new kernel, the script refuses to build DAHDI against a stale kernel and stops at a reboot checkpoint (DAHDI module build requires `kernel-devel` matching the *running* kernel). |
| **Credentials** | By default, strong random passwords are generated for the `cron`, `custom` DB users and the web admin `6666`. The `confcron` AMI secret is synced to match whatever `install.pl` already wrote to `servers.ASTmgrSECRET` (see fix #14 below — it is NOT independently randomized). Everything lands in `/root/vicidial-install-report.txt` (mode 600). `--legacy-creds` restores the classic `cron/1234` convention for fleets whose tooling expects it. |
| **DB security** | MariaDB binds to 127.0.0.1, grants are `localhost`-only, anonymous users and the test DB are dropped. `--db-remote-subnet '10.0.0.%'` opens it up for cluster builds. AMI binds to loopback. |
| **Firewall** | firewalld enabled with web + RTP (10000-20000/udp). SIP 5060 is restricted to `--carrier-ips` when given; otherwise it opens with a loud warning. |
| **No chmod 777** | Recording spool is `asterisk:apache` 775. `/etc/astguiclient.conf` is `root:apache` 640 — NOT 600 (see fix #13: the web UI must read this file). Root SSH login is left untouched unless `--permit-root-ssh`. |
| **Logging** | Everything is logged to `/var/log/vicidial-install.log`; failures print the exact line and command. |
| **Idempotent config** | Crontab is written fresh (never appended twice), PHP overrides go in `/etc/php.d/99-vicidial.ini`, boot sequence is a proper `vicidial-boot.service` systemd unit instead of the rc.local chain. |

## What was fixed vs. the old scripts

1. `#!/bin/sh` with bashisms → proper bash, `set -Eeuo pipefail`, ERR trap, full logging.
2. Interactive `read` pauses mid-install → single upfront config + `--yes` for unattended runs.
3. EPEL 8 **and** 9 both installed regardless of OS → version-correct repos only.
4. MySQL step prompted for a password mid-heredoc → root connects via unix_socket; idempotent `CREATE ... IF NOT EXISTS`; schema never reloaded over an existing DB.
5. MariaDB config contained options removed/renamed in 10.5 (`thread_concurrency`, `max_tmp_tables`, `table_cache`, `key_buffer`) → corrected, plus `key_buffer_size` auto-sized by RAM.
6. lame 3.99.5 (fails on gcc ≥ 10) → EPEL package first, lame 3.100 source fallback.
7. DAHDI: patched `dahdi-9.5-fix` with automatic fallback to official `dahdi-linux-complete-3.4.0`; modules load at boot via `modules-load.d`.
8. Giant hardcoded confbridge INSERT with `10.10.10.15` → generated loop with the server's real IP, `INSERT IGNORE` (idempotent).
9. World-open DB grants (`'cron'@'%'` / 1234), AMI `confcron` secret `1234`, `PermitRootLogin yes`, `chmod -R 777` → all removed or gated behind explicit flags.
10. tmpfs on the live monitor dir kept (big IO win on cloud VPS) but now a flag: `--no-tmpfs`. Recordings move out of tmpfs every 3 minutes via the mix cron; a crash loses at most ~3 minutes of unmixed audio.
11. certbot renewal script that stopped firewalld entirely → renewal helper that opens/closes only port 80.
12. Post-install verification: services, schema table count, DB user login, Asterisk binary, DAHDI module, web UI probe — with a final report + go-live checklist.

### Found during live testing (not caught by syntax/lint review alone)

13. **`/etc/astguiclient.conf` permissions broke the web UI.** It was `chmod 600` (root-only) for security, but VICIdial's own `dbconnect_mysqli.php` (running as the `apache` user) reads this file directly to get its DB credentials — that's standard, expected VICIdial behavior. With 600, Apache couldn't read it, every `$VARDB_*` PHP variable came back empty, and `mysqli_connect('', '', '', ...)` silently fell back to the anonymous MySQL user, producing `MySQL connect ERROR: Access denied for user ''@'localhost'`. **Fix:** `chown root:apache` + `chmod 640`.
14. **`confcron` AMI user had an orphaned random secret.** Every `astguiclient` perl script (`AST_update.pl`, `AST_VDauto_dial.pl`, `AST_conf_update_screen.pl`, etc.) reads its AMI login secret from the single `servers.ASTmgrSECRET` database column — there is no separate column for `confcron`. `install.pl` sets that column to `1234` to match the `cron`/`updatecron`/`listencron`/`sendcron`/`sipcron` AMI users it creates in `manager.conf`. The installer was giving `confcron` its *own* random secret in `manager.conf` only, which nothing in VICIdial's codebase ever looks up — so `AST_conf_update_screen.pl` sent an empty secret and failed AMI auth every 60 seconds (`manager.c: authenticate: ... failed to authenticate as 'confcron'`, repeating in the Asterisk log forever). **Fix:** `confcron`'s secret is now read from `servers.ASTmgrSECRET` after `install.pl` runs, matching the existing convention, instead of being independently randomized.
15. **DAHDI fails to build on current EL9 kernels (5.14.0-6xx+) out of the box.** The `dahdi-9.5-fix` zip was patched against an older kernel baseline. On a live AlmaLinux 9.7/9.8 box this produced a chain of build failures, each requiring source inspection to fix correctly (not guessed):
    - `wctc4xxp` (TC400B transcoder) and `wcte12xp` (T1/E1 card): wrong/nonexistent `from_timer()` struct member → directories removed, their `obj-$(DAHDI_BUILD_ALL)$(CONFIG_DAHDI_*)` lines commented out of `linux/drivers/dahdi/Kbuild` (deleting the directory alone leaves a dangling Kbuild reference and a different, more confusing "No such file or directory" error).
    - `wcte13xp`, `wcte43x` and 9 other legacy PCI/USB card families (`wct4xxp`, `wctdm24xxp`, `wcaxx`, `wctdm`, `wcb4xxp`, `wct1xxp`, `wcte11xp`, `wcfxo`, `xpp`/Astribank, `opvxa1200`): same `from_timer()` issue or simply hardware nobody runs on a cloud VM → all excluded the same way via Kbuild.
    - `dahdi-sysfs.c` and `dahdi-sysfs-chan.c` (core DAHDI, **not** optional — cannot be excluded): `struct bus_type.match()` callbacks used the pre-6.x signature `int (*)(struct device *, struct device_driver *)`; EL9's current kernel backports the upstream change to `int (*)(struct device *, const struct device_driver *)`. **Fix:** added `const` to both `span_match()` and `chan_match()` — a genuine 2-line source patch, verified by a clean `make` (exit 0) on a live kernel before being folded into the script.
16. **Asterisk's `jansson` dependency downloads live from GitHub during `./configure` and can fail hard.** `--with-jansson-bundled` fetches `jansson-2.14.tar.bz2` from `raw.githubusercontent.com` at configure time; on one VPS this endpoint was consistently unreachable (curl exit 4) even though the rest of the network — including the *same host* for pjproject's tarball — worked fine. **Fix:** install `jansson-devel` (a standard, always-available EL8/9 RPM) and configure with `--with-jansson=/usr` (the correct path-based flag — a bare `--with-jansson` is not a recognized option at all and silently falls through to the same bundled/download behavior, which cost real debugging time before `./configure --help` was checked directly). `pjproject` has no EL RPM equivalent and stays bundled; its download from the same host has been reliable in testing.
17. Several `set -e`/`pipefail` interactions that only surface under real execution, not `bash -n`/shellcheck: `((counter++))` returning non-zero (and killing the script) when the result is zero; `tr ... /dev/urandom | head -c N` triggering SIGPIPE in the producer when the consumer closes early; `--reset` continuing to run with stale in-memory config instead of exiting. All fixed.
18. OS detection (`PRETTY_NAME`, `EL`) and IP detection only ran inside the skippable `preflight`/early steps — fine on a first run, but referencing `$PRETTY_NAME` under `nounset` on any **resumed** run (where `preflight` is skipped) crashed immediately. **Fix:** `detect_os`/`detect_ip` now run unconditionally at the very top of `main()`, before the step framework, so these variables are always populated regardless of which steps get skipped.
19. EL9's EPEL does not carry `perl-IO-Scalar` or `perl-Term-ReadKey` as RPMs (confirmed via `dnf`'s "No match for argument") — a single bad name in a 29-package `dnf install` aborted the entire transaction, including packages that *were* available. **Fix:** both are dropped from the RPM list (they're already in `cpanfile` and install fine via `cpm`), and a new `pkg_soft()` helper warns-and-continues instead of hard-failing for package lists with known distro-specific gaps (the previous `pkg()` call's `|| warn ...` was actually unreachable dead code, since `pkg()` itself calls `fail`/`exit 1` internally).

## Known rough edges (not yet fixed)

- **Adding `--domain` on a *second* run doesn't work on its own.** If the first run completes without `--domain`, the `ssl_webrtc` step marks itself `done` even though it did nothing (it just printed "No --domain given — skipping" and exited the step successfully). A later run with `--domain` sees the step is already `done` and skips it too — silently, with no warning that SSL was never actually configured. **Workaround:** `rm -f /var/lib/vicidial-installer/step.ssl_webrtc.done` before the second run. This should be fixed properly (only mark `ssl_webrtc` done when a domain was actually given, or treat "skipped because no domain" as a distinct state from "configured successfully") — flagged for the next revision.
- **WebRTC/CyburPhone's actual browser-to-Asterisk handshake has not been tested.** The cert-issuance and `wss://8089` config code path is verified working (a real Let's Encrypt cert was issued successfully), but no one has confirmed a browser softphone actually registers and completes a call over it yet.
- **A fully hands-off run of this exact final script, start to finish, has not happened.** Both live tests needed at least one manual mid-install intervention, because that's how the bugs above were *found*. The fixes are all folded back into the single script now, but the complete, untouched script has not itself been run top-to-bottom without a human watching the log.

## All options

Run `./install-vicidial.sh --help`. Highlights:

```
--asterisk 16|18        --php 7.4|8.2        --timezone TZ
--legacy-creds          --admin-pass PASS    --db-remote-subnet '10.0.0.%'
--no-webphone           --no-dynportal       --with-cockpit   --with-g729
--no-tmpfs              --no-sngrep
--domain FQDN --email X --carrier-ips "a,b"  --permit-root-ssh
--yes --auto-resume --skip-update --reset
```

## After installation

1. **Reboot** (the installer offers to). First boot starts the keepalive screens.
2. Read `/root/vicidial-install-report.txt` — credentials and go-live checklist.
3. Log in at `http://SERVER_IP/vicidial/admin.php` (user `6666`).
4. Add your carrier under Admin → Carriers and test an outbound call.
5. **If the install was run without `--domain` and you want WebRTC/SSL now** (see "Known rough edges" above for why this step is needed): first confirm the domain actually resolves to this server's IP —

   ```
   nslookup yourdomain.ddns.net
   ```

   If that returns the right IP, delete the stale step marker and re-run the installer with `--domain` and `--email` — this is the exact pattern, with a real example:

   ```
   rm -f /var/lib/vicidial-installer/step.ssl_webrtc.done
   ./install-vicidial.sh --domain dial1211.ddns.net --email debjit@beltalk.net
   ```

   Every other step is already marked done, so this skips straight to issuing the Let's Encrypt cert and configuring `wss://8089` for WebRTC — nothing else gets touched or re-installed. If DNS doesn't resolve correctly yet, certbot fails cleanly and SSL stays skipped (it won't break anything else); fix DNS and run the same two commands again.

## Known external dependencies

- `download.vicidial.com` — Asterisk-vici tarball (version auto-fallback included, see fix #16), asterisk-perl (hard requirement)
- `svn.eflo.net` — VICIdial trunk (retried 5× with backoff)
- `raw.githubusercontent.com` — pjproject source (bundled build; jansson no longer depends on this host, see fix #16)
- `cybur-dial.com` / `dialer.one` — patched DAHDI and DynPortal (both have fallbacks or degrade gracefully; consider mirroring these to your own storage box for fleet installs)

---
*Debjit Pal — Systems & VoIP Infrastructure Engineer, Beltalk Technologies Pvt. Ltd.*
