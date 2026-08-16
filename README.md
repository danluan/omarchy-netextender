# NetExtender VPN for Omarchy

> [!WARNING]
> This plugin is experimental and under active development. Features and
> configuration may change, and some NetExtender environments may not yet be
> supported.

An Omarchy bar plugin for connecting to SonicWall NetExtender. It provides a
compact connection form, secure password storage, two-factor authentication,
certificate verification prompts, and live VPN session information.

## Features

- Connect and disconnect from the Omarchy bar
- Store passwords in the desktop Secret Service keyring
- Handle verification codes without storing them
- Review, accept, or permanently trust server certificates
- Display the client IP, PPP interface, traffic, and connection duration

## Requirements

- Omarchy with the Quickshell bar
- SonicWall NetExtender CLI at `/usr/bin/netExtender`
- `secret-tool` with a working Secret Service provider
- Python 3 and `iproute2`

## Install

```bash
omarchy plugin add https://github.com/danluan/omarchy-netextender.git --enable
omarchy bar move danluan.netextender --section right --after omarchy.network
```

## Usage

Open the NetExtender icon in the bar, enter the server, username, password,
and domain, then select **Connect**. Saved passwords remain in the system
keyring and are reused on later connections.

If NetExtender cannot verify the server certificate, the plugin lets you view
its details, accept it for the current connection, reject it, or save its
fingerprint with **Always Trust**.

Use **Disconnect** to end the VPN session. Right-clicking the bar icon also
disconnects, while middle-clicking refreshes the displayed status.

## Update

```bash
omarchy plugin update danluan.netextender
```

## Data storage

| Data | Location |
| --- | --- |
| Server, username, domain, and recent profiles | Omarchy `shell.json` |
| Password | Desktop Secret Service keyring |
| Verification code | Memory only; never stored |
| Permanently trusted certificate | NetExtender `~/.netextender` configuration |

The plugin does not pass passwords through command-line arguments. Its local
agent communicates with NetExtender through a private pseudo-terminal.
