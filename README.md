# FastSSHTunnel

A native macOS SSH tunnel manager. Save multiple SSH profiles, browse in Firefox through a SOCKS tunnel, and optionally forward a local port to a Windows PC for Remote Desktop.

Use **Save Connection** at the bottom of a connection's settings (or **⌘S**)
to save it and see a confirmation. Edits also continue to save automatically.
Connection details are organized into **Connection**, **Authentication**,
**Firefox**, **Device SSH**, **Remote Desktop**, and **Static Port** tabs. Tunnel controls and Save Connection stay
available while switching between tabs.

Use the **Search tunnels** box above the sidebar list to filter by name, host,
or username. The **+** button beside **Tunnels** adds a new connection and
clears the search so the new connection is visible.
The **−** button immediately beside **+** deletes the selected tunnel, stops
its SSH process, and removes its remembered password. It is disabled when no
tunnel is selected. The window title displays **FastSSHTunnel** as static text.

Select a tunnel in the sidebar; a checkmark identifies the selected tunnel.
Use the **…** menu beside **Tunnels** to export that named tunnel as a JSON
file or **Import Profile** from one. Each import creates a separate tunnel
and assigns new local ports for SOCKS, Remote Desktop, or static forwarding if the exported ports
conflict with existing tunnels.
The file includes the identity-file path. Set up the password or select the
private key separately on the destination Mac.

Use **Back Up All Tunnels** in the same menu to save every tunnel profile and
its remembered SSH password in one encrypted `.fastsshbackup` file. Keep the
backup passphrase so you can unlock it later. **Restore Backup** asks for the
passphrase and confirms before replacing the current profiles and remembered
passwords. Restored tunnels start disconnected. The backup includes identity-file
paths. SSH private keys and Firefox browsing data are managed separately.

The **Public IP (this Mac)** bar at the top shows this Mac's current public
IPv4 or IPv6 address. It checks on launch, every minute while the window is
open, and when the app becomes active. Use the refresh button to check again
or the copy button to copy the address. Failed lookups show **Unavailable**.
The check uses `https://api64.ipify.org?format=json` over the Mac's network
connection, with HTTP/SOCKS proxies disabled for that request. A system VPN
can affect the address. No tunnel settings or passwords are sent, and the
public IP is not saved in preferences. Xcode previews use a sample address.

Closing the window keeps the app and its tunnels running. Click the Dock icon
to bring the window back, including when it is minimized. You can also use
**Window → Show FastSSHTunnel** (**⌘0**).
Use **Quit FastSSHTunnel** (**⌘Q**) to stop all active tunnels and close their
forwarded ports.

## Run it

Open `Package.swift` in Xcode and run the `FastSSHTunnel` scheme, or run:

```sh
swift run FastSSHTunnel
```

To see the interface beside your code in Xcode, select
`Sources/FastSSHTunnel/FastSSHTunnelApp.swift` and click **Show Canvas** in the
upper-right toolbar (or **Editor → Canvas**), then restart the preview if it
is paused. For this Swift package executable, if Xcode reports that previews
require `ENABLE_DEBUG_DYLIB`, select **Editor → Canvas → Use Legacy Previews
Execution**, then **Refresh Canvas**. The **FastSSHTunnel** preview includes a sample tunnel. Preview
edits stay in memory and do not read or change saved passwords or start SSH.

To produce a double-clickable `FastSSHTunnel.app` in `dist/`:

```sh
zsh Scripts/build-app.sh
```

The script replaces the executable with a fresh file, packages the app icon,
signs the completed app for local use, and verifies its signature. This
prevents code-signing launch crashes when rebuilding an app that has already
been opened. Quit the app and reopen `dist/FastSSHTunnel.app` after rebuilding
to use the new version.

Each successful run also increments the build number shown in **About
FastSSHTunnel** (for example, `1.0 (2)`). The last successful number is saved in
`Resources/Info.plist`, so deleting `dist/` or the build cache does not reset it.
The release version stays at `1.0` until it is changed separately. Use this
packaging script after app changes to get an updated build number.

The app icon is regenerated from `Resources/SSHLightningPipeMinimalIcon.png`
using macOS `sips` and `iconutil`, including the small list-view sizes and
their Retina versions. To regenerate just `Resources/AppIcon.icns`, run
`zsh Scripts/build-icon.sh`.

If Xcode was recently installed but has not finished setup, you can build with
the existing Command Line Tools without changing your system's selection:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools zsh Scripts/build-app.sh
```

The build script automatically uses the installed macOS 26.5 SDK when the
standalone Command Line Tools are selected. This avoids the missing SwiftUI
macro plugin in the macOS 27 setup. With that setup, run directly using:

```sh
swift run --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk FastSSHTunnel
```

Warnings about missing `CommandLineTools/Developer` library and framework
search paths do not prevent this app from linking. A successful build ends
with `Build complete!`.

## Authentication

Enter the server's SSH password in **Password (optional)**. It stays masked
and is kept in memory until the app quits. To remember it for future launches,
enable **Remember password in macOS Keychain** and click **Save Connection**.
Uncheck Remember and save to remove a previously remembered password. Changing
the SSH host, username, or SSH port requires entering the password for that
destination. Deleting a connection also removes its saved Keychain password.

To connect without a password, select an SSH identity file in the app. Each
profile requires either a password or a selected SSH key to connect.

For a new SSH server, the app shows its host key fingerprint before authenticating
to that server. Compare it with a fingerprint from your server administrator,
then choose **Trust and Connect** to save the key in OpenSSH's known hosts and
continue. **Cancel** stops the connection. OpenSSH rejects changed host keys.

The app uses OpenSSH's `SSH_ASKPASS` mechanism with a protected local Unix
socket for host key confirmation and password prompts. The password is never
placed in process arguments, environment variables, helper files, or connection
preferences. The server must support password authentication or a
keyboard-interactive password prompt to use a saved password. Key-based tunnel
connections use keys or ssh-agent and continue without password or key
passphrase prompts.
For `ProxyJump` connections, verify jump host keys separately and authenticate
using keys or ssh-agent. The saved destination password is not supplied to jump hosts.

## Firefox behavior

“Open in Firefox” starts a dedicated Firefox profile for that tunnel. Its proxy settings are isolated from your normal Firefox profile and route DNS through SOCKS5. WebRTC is restricted to the proxy. Firefox needs to be installed in `/Applications` (or Firefox Developer Edition in `/Applications`). Close existing tunnel Firefox windows before reopening them after changing a tunnel's SOCKS port or updating the app so the new settings take effect.

## SSH to another device

In **SSH to another device**, enter a device hostname or IP address reachable
from the tunnel server, its username, and its SSH port. Connect the tunnel,
then click **Open SSH in Terminal**. The device settings are saved with the
tunnel, so you can change them to connect to other devices.

Terminal opens an interactive SSH session through the connected tunnel's
SOCKS5 proxy. Terminal asks you to verify an unfamiliar device fingerprint
before you enter its password or key passphrase. Default local SSH keys and
ssh-agent are also supported. The tunnel server's
password is not reused for the device. This session uses the literal device
address and ignores `~/.ssh/config` so configured proxies or shared connections
cannot bypass the selected tunnel. Keep the tunnel connected while using SSH.

## Remote Desktop

1. Select an SSH connection and open the **Remote Desktop** tab.
2. Turn on **Enable Remote Desktop forwarding**. Enter the Windows PC's
   hostname or IP address as seen from the SSH server. The default Windows PC
   port is `3389` and the default local port on your Mac is `13389`.
3. Click **Connect**, then **Open Remote Desktop**. You can also enter the
   displayed address (for example, `127.0.0.1:13389`) as the PC name in
   Windows App or Microsoft Remote Desktop.

Keep the SSH tunnel connected during the Remote Desktop session. Enter your
Windows credentials in the Microsoft client. To apply changes to forwarding
on a running tunnel, disconnect and reconnect.

## Static port forwarding

Open the **Static Port** tab and enable forwarding. Enter a destination host and
port reachable from the SSH server, and choose the local port on this Mac.
Connect the tunnel, then point your application at the displayed local address
(for example, `127.0.0.1:15432`). Ports must be between 1 and 65535 and local
ports must not conflict with other tunnel listeners. Disconnect and reconnect
to apply changes to a running tunnel.

## Live tunnel traffic

**Tunnel status** is pinned at the top of the connection details pane. Its
connection buttons and live counters stay visible while the settings scroll.

While a tunnel is connected, **Tunnel status** shows **TX · Sent** and
**RX · Received**, with packet totals, packets per second, transferred bytes,
and bytes per second. Counters update once per second and reset on reconnect.
They measure the encrypted TCP connection owned by this tunnel's SSH process,
including SSH protocol traffic and keepalives. Local SOCKS, Remote Desktop, and static forwarding
client sockets are excluded to avoid counting transfers twice. Each tunnel has
its own counters.

The app uses macOS's built-in `nettop` sampler; no administrator password or
packet capture is needed. If counters are unavailable, the status section
shows a message and the tunnel keeps working.

## Security notes

- The SOCKS5, Remote Desktop, and static forwarding listeners bind to `127.0.0.1` on this Mac.
- Tunnel records, including private-key *paths*, are stored in this Mac user's preferences. Remembered SSH passwords are stored in macOS Keychain and can be included in a passphrase-protected backup. Private-key contents are never stored.
- Delete old profiles from the sidebar when they are no longer needed.

## Troubleshooting logs

Choose **Diagnostics → Export Debug Logs…** to save a text file containing the
most recent 500 diagnostic events, app and macOS versions, timestamps, and tunnel
identifiers. The history persists across app restarts. Passwords, connection
settings, and raw SSH output are not included; SSH errors are classified into
general categories, so unrecognized details are omitted. Review the file before
sharing it. Events are recorded from the time this feature is installed.
