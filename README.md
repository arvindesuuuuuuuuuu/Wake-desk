# WakeDesk

Flutter Android dashboard and authenticated Go agents for Windows and Linux PCs.

## Before installing: BIOS/UEFI power setup

Before installing either agent, enter your PC's BIOS/UEFI setup. The key and menu names vary by device; commonly used startup keys include **Delete** and **F2**. Check your PC's manual for the exact steps.

1. Enable **Wake on LAN**, **Power On By PCI-E**, or the equivalent network wake option if your firmware provides one. The PC must retain standby power to receive a wake packet.
2. If the firmware has an **ErP** or deep power-saving option, check whether enabling it removes standby power from the network adapter. Disable it if it prevents Wake-on-LAN.
3. To boot automatically when power returns after unplugging the PC or switching the AVR back on, set **Restore AC Power Loss**, **AC Back**, or **After Power Failure** to **Power On** or **Always On**. A **Last State** option may leave the PC off if it was off before power was removed. This setting also makes the PC boot after an ordinary power outage.
4. Save the BIOS changes. Test Wake-on-LAN after a normal shutdown, then test power restoration separately by removing and restoring AC power only after the PC has shut down safely.

These are separate features: a Wake-on-LAN packet cannot reach a PC while its plug or AVR is off, and the power restoration setting cannot remotely switch on a manually switched-off AVR. Some systems do not support network wake from a full shutdown, even when the firmware option is enabled.

## Network setup (Windows and Linux)

Connect the PC by **wired Ethernet** and put the phone on the same trusted local network. Do not use guest Wi-Fi or client isolation for the phone. Reserve the PC's LAN IP in your router, and allow inbound **TCP 8787** to the agent only from your trusted LAN. The app needs the PC's LAN IP, wired Ethernet MAC address, and subnet broadcast address. A normal routed VPN or a different subnet may not carry the phone's Wake-on-LAN broadcast.

**Windows:** Open **Device Manager > Network adapters > [wired adapter] > Properties**. In **Advanced**, enable **Wake on Magic Packet** if available. In **Power Management**, enable **Allow this device to wake the computer** and, if offered, **Only allow a magic packet to wake the computer**. Find the address and MAC with `ipconfig /all`. If waking from sleep works but waking after Windows shutdown does not, check the PC's firmware support and Windows Fast Startup behavior. The Windows firewall command for the agent is in the Windows section below.

**Linux:** Find the wired interface and its address, MAC, and broadcast address with `ip -4 addr` and `ip link`. If `ethtool` is installed, run `sudo ethtool <interface>` and check that **Supports Wake-on** includes `g` (magic packet). If NetworkManager manages the wired connection, list profiles with `nmcli connection show --active`, then enable magic-packet wake persistently for the wired profile:

```sh
sudo nmcli connection modify "<wired-profile>" 802-3-ethernet.wake-on-lan magic
```

Reconnect the wired profile or reboot before testing. Other Linux network managers have their own persistent Wake-on-LAN settings. Restrict TCP 8787 with the firewall used by your distribution; Wake-on-LAN itself is received by the network adapter while the OS is asleep or off. Test the agent connection while the PC is running, then test Power On from sleep and shutdown separately. [Windows adapter power settings](https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapterpowermanagement), [Linux `ethtool`](https://manpages.debian.org/unstable/ethtool/ethtool.8.en.html), [NetworkManager setting](https://www.networkmanager.dev/docs/api/latest/nm-settings-nmcli.html).

## Windows agent

### Windows control panel

Extract `dist/PC-Control-Windows.zip` to a permanent folder, then double-click `pc-agent-gui.exe`. Keep the agent executable and PowerShell scripts in the same folder. Go and Flutter are not needed to use the packaged Windows app.

Click **Start agent**. Choose your network adapter under **Phone connection**, then copy its Agent URL, MAC address, broadcast address, and access token into the Android app. The control panel shows running status, Windows uptime, and recent activity. **Stop agent** stops an agent launched by this panel or the PC Control scheduled task.

Closing the window hides it to the system tray. Click its tray icon to reopen it. **Exit control panel** exits the GUI; an already running agent continues in the background. **Enable startup** registers the agent to run at sign-in. **Disable startup** removes that registration while leaving the running agent available. Keep the extracted folder in place after enabling startup.

New settings are stored in `%LOCALAPPDATA%\PCControl\config.json`, with credentials restricted to the current user and SYSTEM. The GUI first checks for `config.json` beside its executable, then for an existing configuration referenced by the PC Control startup task. You can also pass `-config "C:\path\config.json"`. Stop the agent before editing its listen address or generating a replacement token; click **Save settings** before starting it again. Update the Android app's token after changing it. Existing TLS certificate settings are preserved; edit their paths in the configuration file while the agent is stopped.

The Windows firewall and Wake-on-LAN setup described below still apply. The control panel does not alter firewall rules automatically. Its URL field reflects the configured listen address; a loopback-only address cannot be reached from your phone.

Copy buttons give field-specific feedback without recording the token. **Show token** reveals or masks the token, including while the agent is running. Running connection fields are read-only but selectable. Generated tokens are drafts until **Save settings** is clicked; **Discard changes** restores the saved configuration. The updated agent supports authenticated graceful stopping, so **Stop agent** also works after exiting and reopening the control panel. Older agents use the original process or scheduled-task stop behavior until restarted with the updated executable.

`agent/verify-gui.ps1` checks real clipboard contents, token masking, generation/save/discard, an isolated startup task, live status, log controls, hide/restore, and stopping after reopening. It uses a temporary configuration and port and restores the clipboard. It never invokes PC shutdown, restart, sleep, or lock.

To build the Windows package from source:

```powershell
cd agent
.\build-gui.ps1
```

This creates `pc-agent-gui.exe`, the headless agent, and `dist/PC-Control-Windows.zip`. The GUI uses the native Windows [Walk toolkit](https://github.com/lxn/walk). The build embeds its Common Controls and DPI manifest.

Requires Go 1.22+ and Windows 10/11. From PowerShell:

```powershell
cd agent
.\install.ps1
```

This builds the executable, generates a random access token in `agent/config.json`, restricts the file to your account and SYSTEM, and registers a background task at sign-in. It starts the task immediately. The task runs as the current user, because locking Windows requires an interactive session. The agent is unavailable before sign-in or after sign-out. To remove the task, run `uninstall.ps1`.

Allow inbound TCP 8787 only on your trusted private network. In an elevated PowerShell window:

```powershell
New-NetFirewallRule -DisplayName 'PC Control Agent' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8787 -Profile Private -RemoteAddress LocalSubnet
```

The installer listens on `0.0.0.0:8787`. Set `listen` in the config to a specific interface for tighter binding. The executable defaults to loopback if `listen` is omitted. Keep `config.json` private; never commit or share its token. A manual foreground run is `go run . -config config.json`.

## Linux agent (systemd)

On the Linux PC, install Go 1.22+ and build the headless agent from `agent/`:

```sh
cd agent
go test ./...
go build -o pc-agent-linux .
sudo sh ./install-linux.sh
```

The installer copies the binary to `/usr/local/bin/wakedesk-agent`, creates `/etc/wakedesk/config.json` with a random token if no config exists, and enables `wakedesk-agent.service`. It preserves an existing config and token. It binds to port 8787 on all interfaces; restrict inbound access to your trusted LAN using your Linux firewall. View the token with `sudo cat /etc/wakedesk/config.json` and enter it in the Android Connection settings. Use the Linux PC's LAN IP as the Agent URL, for example `http://192.168.1.50:8787`. For manual pairing, find its wired MAC and broadcast address with `ip -4 addr` and `ip link`. The Windows QR control panel is not part of the Linux build.

The included `agent/pc-agent-linux` is built for Linux x86-64. If your Linux PC uses another CPU architecture, run the build command on that PC instead.

```sh
sudo systemctl status wakedesk-agent
sudo journalctl -u wakedesk-agent -n 50 --no-pager
sudo systemctl restart wakedesk-agent
```

The Linux service uses `systemctl` for shutdown, restart, and suspend, and `loginctl lock-sessions` for Lock. Lock requires a graphical session that supports systemd-logind's lock request; some desktops or screen lockers may ignore it. The service runs as root so power actions can run without an interactive authorization prompt. Keep the access token private, limit the port to your trusted network, and use HTTPS or a private VPN outside that network. `POST /v1/agent/stop` stops the service until it is started again; the unit only restarts after a failure. Power On still sends Wake-on-LAN from the Android phone and requires the PC to have standby power and a wired network connection. A PC disconnected from AC power cannot receive a wake packet.

## Android app

### Saved PCs

The Android dashboard's **Control PC** selector chooses which saved PC receives status checks, power commands, and Wake-on-LAN packets. Tap **Add PC** to configure another Windows or Linux device manually or scan its pairing QR code. Saving selects the new PC. **Connection settings** edits the selected PC. Each PC's credentials are kept in Android secure storage, and the selected PC is remembered across app restarts. Existing single-PC settings are preserved as the first device. Install an agent on each PC you want to control.

### QR pairing

On Windows, choose the network adapter reachable from your phone and click **Show QR code** under Phone connection. On Android, open Connection and tap **Scan PC QR code**, allow camera access, and scan the Windows code. The PC name, URL, access token, MAC, and broadcast address fill automatically. Tap **Connect** to save securely and check the connection. Canceling the scanner leaves your settings unchanged; manual entry remains available.

Keep both devices on the same trusted network. The QR contains your saved access token, grants control of the PC, and should never be shared or screenshotted. It is generated locally in memory, not uploaded or saved as a file. Save or discard pending Windows edits before pairing. Scan again after changing the token or network address. QR pairing does not configure firewall rules or enable Wake-on-LAN hardware settings.

Install Flutter and the Android SDK command-line tools, accept Android licenses, then:

```powershell
cd mobile
flutter pub get
flutter run
# Or produce an APK for local installation:
flutter build apk --debug
```

Flutter was installed for this workspace at `C:\Users\Administrator\flutter-sdk`; add its `bin` directory to PATH or invoke `flutter.bat` with its full path.

Open Connection settings and enter the PC nickname, agent URL (for example `http://192.168.1.50:8787`), token from `config.json`, Ethernet MAC address, and subnet broadcast address (for example `192.168.1.255` on a /24 network). `ipconfig /all` shows the PC's address and physical address. Reserve the PC's IP address in your router. Settings, including the token, use Android secure storage; backups are disabled.

Status refreshes every five seconds while the app is active. Uptime is host OS uptime, not agent runtime. Offline means the app cannot reach the agent; it does not prove the computer is powered off. Shutdown, restart, and sleep require confirmation. Windows may block shutdown/restart to protect unsaved work. Sleep is acknowledged when its helper starts, not when hardware enters sleep. A lost connection during a command does not establish whether the command ran; the app never retries it automatically.

## Wake-on-LAN and transport

Power On sends a UDP magic packet directly from the phone, independently of the agent. Enable Wake-on-LAN in BIOS/UEFI and the Ethernet adapter's power settings. Keep the PC connected to power and wired Ethernet. Whether wake from full shutdown works depends on hardware and Windows Fast Startup settings. Phone and PC normally need to share a local network; guest Wi-Fi isolation or router broadcast filtering can prevent delivery. Sending a packet does not confirm a successful wake.

HTTP is supported for a trusted LAN, but its bearer token is unencrypted in transit. Do not port-forward this API to the internet. For encrypted transport, configure `tls_cert` and `tls_key` in `config.json` and use an HTTPS URL with a certificate trusted by Android. Certificate checks are never disabled. A private VPN is another option for API access; ordinary routed VPNs generally do not carry Wake-on-LAN broadcasts.

## API and verification

All endpoints require `Authorization: Bearer <token>`.

| Method | Path | Request / response |
| --- | --- | --- |
| GET | `/v1/status` | `{"name":"DESKTOP","addresses":["192.168.1.50"],"uptime_seconds":3600}` |
| POST | `/v1/commands` | `{"command":"lock"}`; accepts `shutdown`, `restart`, `sleep`, `lock` |
| POST | `/v1/agent/stop` | Stops only the agent API; returns `{"status":"stopping"}` |

Successful commands return `{"status":"requested"}`. Invalid requests return 400, authentication failures 401, incorrect methods 405, and immediate OS operation failures 500. There is no arbitrary command execution endpoint.

```powershell
cd agent
go test ./...
go vet ./...
cd ../mobile
flutter analyze
flutter test
```

Tests inject a fake command executor; they never shut down, restart, sleep, or lock the development machine. Hardware actions and wake need a real Windows PC and Android device for end-to-end testing. Release distribution still requires configuring your own Android signing key.
