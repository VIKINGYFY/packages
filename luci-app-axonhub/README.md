# luci-app-axonhub

OpenWrt LuCI entry and `procd` service for the AxonHub native binary.

## Package layout

- `../axonhub`: downloads the official release archive for the target architecture and installs `/usr/bin/axonhub`.
- `luci-app-axonhub`: installs the LuCI view, UCI configuration, RPC methods and `procd` init script.
- `luci-i18n-axonhub-zh-cn`: installs the compiled Simplified Chinese translation catalog.

The binary package supports `aarch64`, `x86_64` and `loongarch64`. The release hashes come from the official AxonHub `v1.0.0-beta5` checksums.

## Data directory

On first installation, `/etc/uci-defaults/luci-axonhub` selects the writable persistent filesystem with the largest total size. Volatile, read-only and non-POSIX filesystems are excluded. The resulting UCI value is `<mountpoint>/axonhub`; if no suitable data mount exists, it falls back to `/etc/axonhub`.

LuCI lists only the persistent paths found by the storage scan and selects the largest filesystem by default. AxonHub stores its SQLite database and application settings in this directory. Selecting another path without moving the existing database creates a fresh AxonHub instance.

For the tested MT7986 router, the expected default is:

```text
/mnt/mmcblk0p6/axonhub
```

## Port and logs

On first installation, an unused TCP port is selected randomly from
`20000-59999` and saved to UCI. The port remains stable across service and
router restarts and can be changed in LuCI.

AxonHub writes to `<data directory>/axonhub.log`, next to `axonhub.db`, instead of the
OpenWrt system log. File logs rotate at 20 MiB with at most three backups. LuCI
offers disabled, daily, weekly and monthly cleanup schedules implemented as
standard cron expressions at 03:00. The cleanup task only truncates AxonHub's dedicated
log and never clears the system log. System-log output is available as an
opt-in setting.

## Build

Copy both package directories into an OpenWrt package feed, update/install feeds, then select:

```text
Network -> Web Servers/Proxies -> axonhub
LuCI -> Applications -> luci-app-axonhub
LuCI -> Languages -> Simplified Chinese (zh_Hans)
```

Build with:

```sh
make package/axonhub/clean package/axonhub/compile V=s
make package/luci-app-axonhub/clean package/luci-app-axonhub/compile V=s
```

Install the generated `luci-i18n-axonhub-zh-cn` package together with the
application package when testing the Simplified Chinese interface.

## Migrating the direct-run test database

The direct test was run from `/tmp/axonhub`, which is volatile. Before rebooting the router:

1. Stop the foreground AxonHub process cleanly with `Ctrl+C`.
2. Install the packages but leave the service disabled.
3. Confirm the LuCI-selected data directory.
4. Copy `axonhub.db`, `axonhub.db-wal` and `axonhub.db-shm` if present into that directory while AxonHub is stopped.
5. Enable AxonHub in LuCI and use **Save & Apply**.

The service uses SQLite WAL mode and an absolute database path. It also defaults to `GOMEMLIMIT=512MiB` and `GOMAXPROCS=2` so that the router retains resources for networking.
