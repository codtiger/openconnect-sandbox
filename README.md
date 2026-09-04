# OpenConnect Sandbox

OpenConnect Sandbox is a native macOS 14+ SwiftUI menu-bar and Dock application for running isolated OpenConnect VPN connections. Each profile exposes its connection through a loopback-only SOCKS5 proxy instead of changing the Mac's system routes or DNS configuration.

Multiple profiles can be connected simultaneously. Each connection uses a different local SOCKS port, allowing separate terminals and applications to use different VPNs at the same time.

## Features

- Native SwiftUI menu-bar and Dock interface
- OpenConnect and OpenConnect-SSO profiles
- Concurrent VPN connections on independent SOCKS5 ports
- Per-profile local TCP forwards
- Terminal-level connection selection through `vpnctl`
- Profile-aware `ssh`, `scp`, and `sftp` commands
- Optional automatic reconnection and connect-on-launch
- Optional launch at login through `SMAppService`
- Password storage in macOS Keychain
- Ephemeral browser sessions for SSO authentication
- Graceful Disconnect, Quit, sleep, crash, and Force Quit cleanup
- No persistent daemon or privileged helper

## Isolation model

Every tunnel uses OpenConnect's userspace script-tunnel mode with `ocproxy`:

```text
openconnect --script-tun --script "ocproxy -D PORT"
```

This means the application deliberately does not:

- create a system TUN interface;
- install or replace routes;
- modify the system DNS configuration;
- invoke `sudo`;
- install a launch daemon;
- expose proxy listeners outside the loopback interface.

Only applications explicitly configured to use a profile's SOCKS proxy send traffic through that VPN. Other applications continue using the Mac's normal network connection.

The current build does not enable Apple's App Sandbox because it must execute the user-installed Homebrew and Python tools. The VPN traffic itself remains isolated in a userspace network stack, and the application does not make persistent system-network changes.
<!--
## Process lifecycle

Each active profile has a transient supervisor process. The GUI owns a control pipe to that supervisor; normal Quit, Disconnect, sleep, a GUI crash, or Force Quit closes the control channel and initiates cleanup.

OpenConnect is first given SIGINT so it can log out cleanly. Remaining process groups are then terminated with bounded SIGTERM and SIGKILL escalation. Because `ocproxy` can move into a separate process group, its exact PID is recorded in a private temporary directory and terminated explicitly as well. Temporary SSO data and PID-tracking files are removed when the connection ends.

Nothing remains registered as a background service. Launch at Login, when enabled, registers only the GUI application through Apple's supported `SMAppService` API. -->

## Requirements

- macOS 14 or newer
- Xcode 16 command-line tools or a compatible Swift toolchain
- OpenConnect and ocproxy:

  ```bash
  brew install openconnect ocproxy
  ```

- Optional browser SSO support:

  ```bash
  pipx install "openconnect-sso[full]"
  ```

The application detects common Homebrew and user-Python installation paths automatically. Tool paths can also be changed in Settings.

## Build and run

```bash
make test
make lifecycle-test
make app
open "dist/OpenConnect Sandbox.app"
```

The packaged application is written to:

```text
dist/OpenConnect Sandbox.app
```

Local builds are ad-hoc signed. To create a Developer ID build:

```bash
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' make app
```

To notarize it, create a `notarytool` Keychain profile and run:

```bash
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='profile-name' \
./Scripts/notarize.sh
```

## Creating profiles

Open the Connections window from the Dock or menu bar and create a profile with:

- a unique name;
- an OpenConnect or OpenConnect-SSO authentication mode;
- the VPN server address;
- the correct VPN protocol;
- a unique SOCKS port between 1024 and 65535;
- optional local port forwards.

For example, two simultaneous profiles could use:

```text
vpn1  -> socks5h://127.0.0.1:11080
vpn2  -> socks5h://127.0.0.1:11081
```

SOCKS and local-forward ports must be unique across all profiles.

## Terminal companion

The packaged CLI is located at:

```text
dist/OpenConnect Sandbox.app/Contents/MacOS/vpnctl
```

It does not start a daemon or read VPN credentials. It communicates only through the saved profile and runtime state maintained by the GUI application.

Available commands:

```text
vpnctl list [--json]
vpnctl status PROFILE
vpnctl env PROFILE | --direct
vpnctl shell PROFILE | --direct [-- SHELL_ARGS...]
vpnctl exec PROFILE | --direct -- PROGRAM [ARG...]
vpnctl ssh PROFILE -- [SSH_ARGUMENTS...]
```

Examples:

```bash
vpnctl list
vpnctl status vpn1
vpnctl shell vpn1
vpnctl exec vpn1 -- curl https://internal.example.com
vpnctl ssh vpn2 -- user@private-server
```

`PROFILE` can be a unique profile name or UUID. Commands that require a VPN refuse to run unless that profile is currently connected.

### Selecting a VPN in an existing terminal

Use `eval` because `vpnctl env` prints shell statements that must modify the current shell:

```bash
eval "$(vpnctl env vpn1)"
```

That environment exports:

- `ALL_PROXY` and `all_proxy`;
- the common HTTP, HTTPS, and FTP proxy variables;
- `NO_PROXY` for loopback addresses;
- the selected profile ID and proxy URL;
- a bundle-local command path for proxied OpenSSH commands.

Select a different profile in another terminal:

```bash
eval "$(vpnctl env NYIT)"
```

Restore direct networking and the original `PATH` with:

```bash
eval "$(vpnctl env --direct)"
```

You can install a convenient user-owned symlink after copying the app to `/Applications`:

```bash
mkdir -p "$HOME/.local/bin"
ln -s "/Applications/OpenConnect Sandbox.app/Contents/MacOS/vpnctl" "$HOME/.local/bin/vpnctl"
```

## SSH, SCP, and SFTP

OpenSSH does not honor `ALL_PROXY`. To prevent an ordinary `ssh` command from bypassing the selected VPN, the packaged application contains local `ssh`, `scp`, and `sftp` shims. Environments produced by `vpnctl env`, `vpnctl shell`, and the app's Open Shell action place these shims at the front of `PATH`.

The shims validate that the selected profile is connected and invoke the system OpenSSH executable with a SOCKS5 `ProxyCommand`:

```text
/usr/bin/nc -x 127.0.0.1:PORT -X 5 -G 15 %h %p
```

The 15-second connection timeout prevents unreachable targets from hanging indefinitely. You can also bypass the shell environment and select a profile explicitly:

```bash
vpnctl ssh vpn1 -- user@internal-host
```

<!-- ## Authentication

### OpenConnect

Passwords may be stored in macOS Keychain and are sent to OpenConnect over standard input. Optional one-time codes remain only in memory and are cleared after connection startup.

### OpenConnect SSO

The application runs `openconnect-sso` only to perform browser authentication and return the VPN session cookie. The cookie remains in memory and is sent to a separate non-root OpenConnect process over standard input.

By default, each SSO attempt uses:

- a fresh temporary XDG configuration/cache/data directory;
- an off-the-record Qt WebEngine profile;
- no injected username, password, or TOTP secret.

This prevents identity-provider and Duo browser cookies from persisting between sessions. The tradeoff is that the identity provider may request username, password, and MFA approval on every new connection. Standard `openconnect-sso` can remember credentials and browser state, but this application intentionally defaults to the non-persistent behavior.

Do not enter a temporary six-digit MFA code into an `openconnect-sso` prompt labelled **TOTP secret**. That prompt expects a permanent base32 TOTP seed and may save it in the system keyring.

## Additional OpenConnect arguments

Advanced arguments can be entered one per line. Arguments capable of replacing the isolation script, creating a normal interface, daemonizing, supplying credentials on the command line, loading configuration files, or executing host-checker wrappers are rejected. -->

<!-- ## Troubleshooting

### Port is already in use

Choose a different SOCKS/local-forward port or identify the listener with:

```bash
lsof -nP -iTCP:11080 -sTCP:LISTEN
```

The app distinguishes a port conflict between profiles from a port already occupied by another process.

### A profile is not found

List the exact saved names and states:

```bash
vpnctl list
```

Profile matching is case-insensitive, but the name must be unique. `vpnctl env PROFILE` also requires that the GUI application is running and the selected profile is connected.

### A command ignores the VPN

Not every application honors proxy environment variables. Prefer a program's explicit SOCKS5 configuration, use `vpnctl exec`, or create a local port forward. DNS should be resolved through the proxy by using `socks5h://`, not `socks5://`.

### SSH does not connect

Use a shell opened by the app, evaluate `vpnctl env PROFILE`, or invoke `vpnctl ssh PROFILE -- ...`. Running the system `/usr/bin/ssh` directly without a `ProxyCommand` bypasses the proxy variables. -->

## Tests

Run the unit suite with:

```bash
make test
```

Run the lifecycle integration test with:

```bash
make lifecycle-test
```

The lifecycle fixture simulates a proxy descendant that creates its own process group and ignores normal termination signals. The test verifies that loss of the GUI control pipe still removes that descendant.

## Limitations

- Only SOCKS-aware TCP applications, the bundled OpenSSH shims, and configured local TCP forwards are routed through a profile.
- UDP applications and programs that ignore proxy configuration are not transparently captured.
- Direct authentication currently supports a password plus one optional one-time code; unusual multi-step terminal authentication forms may require browser SSO.
- No software can perform graceful cleanup during power loss. Because this app does not modify persistent routes or DNS settings, rebooting cannot leave VPN network configuration behind.
