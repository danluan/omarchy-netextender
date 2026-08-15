# NetExtender VPN for Omarchy

An Omarchy bar widget for SonicWall NetExtender. It provides a compact,
theme-aware connection form, a workspace-persistent two-factor prompt, and
live session information after login.

## What it stores

| Data | Location |
| --- | --- |
| Server, username, domain, recent servers | The plugin entry in Omarchy's `shell.json` |
| Password | System Secret Service keyring (GNOME Keyring/KWallet), keyed by server + username + domain |
| 2FA code | Memory only for the active login; never stored |

The plugin never passes a password with `netExtender -p`. Its local agent runs
NetExtender in a private pseudo-terminal and answers its password prompt from
the keyring. Server, username, and domain are supplied as literal process
arguments, never through a shell command.

## Requirements

- Omarchy with its Quickshell bar
- `/usr/bin/netExtender`
- `secret-tool` and a working Secret Service provider (normally GNOME Keyring)
- Python 3 (standard library only)
- `ip` from `iproute2`

## Install

Install from the public repository:

```bash
omarchy plugin add https://github.com/danluan/omarchy-netextender.git --enable
omarchy bar move danluan.netextender --section right --after omarchy.network
```

To update an installed copy later:

```bash
omarchy plugin update danluan.netextender
```

## Publishing

The repository contains only the plugin source: it never contains credentials
or the proprietary NetExtender client. After creating the GitHub repository,
publish from this directory with:

```bash
gh auth login --web
git init
git add README.md LICENSE .gitignore Panel.qml manifest.json scripts/netextender-agent
git commit -m "Initial release"
gh repo create omarchy-netextender --public --source=. --remote=origin --push
```

Open the shield icon in the bar. Enter Server, Username, Password, and Domain,
then select **Connect**. The password is saved to the desktop keyring as part
of that action; leave the password box empty on later connections to reuse it.

## Test checklist

1. Open the widget and verify that Server, Username, and Domain remain after
   closing and reopening it.
2. Enter a password, connect, and confirm the password field clears. Confirm
   that no password appears in `shell.json` or in `ps` output.
3. When the server asks for two-factor authentication, verify that the centered
   dialog appears on every Hyprland workspace. Enter a code from the authenticator app.
4. Once connected, confirm the session page shows Client IP, PPP interface,
   sent data, received data, and duration. The counters come from the active
   PPP interface rather than the main network interface.
5. Select **Disconnect**, wait for the state to become Disconnected, and verify
   the PPP interface is gone. Right-clicking the bar icon also disconnects;
   middle-click refreshes the status.
6. Test a wrong password and a wrong 2FA code. The widget should surface the
   error without retaining either value.

## Troubleshooting

- If saving the password fails, start or unlock a Secret Service provider and
  retry. `secret-tool` must be able to open a user keyring.
- The original SonicWall client may phrase the prompt as `One Time Password`,
  `Enter next token`, or an additional verification prompt. The agent accepts
  each of these and opens the same 2FA window.
- For a status issue, run `scripts/netextender-agent status` from this folder.
  It prints non-sensitive JSON only.
