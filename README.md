# Fire TV Remote Driver for Control4

A Control4 DriverWorks driver that enables full control of Amazon Fire TV devices over your local network. This driver implements the Fire TV Remote Control protocol (reverse-engineered from the official Fire TV Remote iOS app).

## Features

- **Full Navigation** - D-pad controls (Up, Down, Left, Right, Select)
- **System Controls** - Home, Back, and Menu buttons
- **Media Playback** - Play, Pause, Stop, Fast Forward, Rewind
- **Text Input** - Send text directly to Fire TV keyboards for search
- **Auto Wake** - Automatically wake sleeping Fire TV devices before sending commands
- **Persistent Pairing** - Pair once, credentials persist across controller reboots
- **Control4 Integration** - Use in programming, scenes, and with Control4 remotes

## Requirements

### Control4 System
- Control4 OS 2.10.6 or later
- Composer Pro for installation and configuration

### Fire TV Device
- Amazon Fire TV Stick (any generation)
- Amazon Fire TV Cube
- Fire TV Edition Smart TV
- Must be on the same network as Control4 controller

### Network Requirements
- Port 8009 (HTTP) - DIAL protocol for wake functionality
- Port 8080 (HTTPS) - REST API for all control commands

## Installation

1. Download the `fire_tv_remote.c4z` driver file from [Releases](../../releases)
2. In Composer Pro, go to **Driver > Add/Update Driver** and select the `.c4z` file
3. In System Design, add "Fire TV Remote" to your project
4. Enter your Fire TV's IP address in the **Fire TV IP Address** property

## Pairing

The driver requires a one-time pairing process (similar to the official Fire TV Remote app):

1. Ensure your Fire TV is powered on and at the home screen
2. Enter the Fire TV's IP address in the driver properties
3. Click **Start Pairing** - a 4-digit PIN will appear on your TV
4. Enter the PIN in the **PIN Code** property field
5. Click **Verify PIN** - the Pairing Status will change to "Paired"

The pairing credentials are saved and persist across reboots.

## Available Commands

### Navigation
| Command | Description |
|---------|-------------|
| Up | Navigate up |
| Down | Navigate down |
| Left | Navigate left |
| Right | Navigate right |
| Select | Confirm selection / OK |

### System
| Command | Description |
|---------|-------------|
| Home | Go to home screen |
| Back | Go back |
| Menu | Open context menu |

### Media
| Command | Description |
|---------|-------------|
| PlayPause | Toggle play/pause |
| Play | Start playback |
| Pause | Pause playback |
| Stop | Stop playback |
| FastForward | Skip forward (1-300 seconds) |
| Rewind | Skip backward (1-300 seconds) |

### Text Input
| Command | Description |
|---------|-------------|
| SendText | Send a string of text |
| SendCharacter | Send a single character |

### Utility
| Command | Description |
|---------|-------------|
| Wake | Wake Fire TV remote receiver |
| TestConnection | Test connectivity |
| RefreshDeviceInfo | Refresh device info |
| ClearPairing | Remove saved credentials |

## Driver Properties

| Property | Description | Editable |
|----------|-------------|----------|
| Fire TV IP Address | IP address of your Fire TV | Yes |
| Fire TV Name | Device name (auto-populated) | No |
| Connection Status | Current connection state | No |
| Pairing Status | Current pairing state | No |
| Controller Name | Name shown on TV during pairing | Yes |
| PIN Code | Enter PIN shown on Fire TV | Yes |
| Command Timeout | HTTP timeout (5-30 seconds) | Yes |
| Auto Wake | Wake device before commands | Yes |
| Debug Mode | Enable detailed logging | Yes |

## Building from Source

```bash
./build.sh
```

This packages all source files into `fire_tv_remote.c4z`.

## Project Structure

```
├── driver.xml          # Control4 driver manifest
├── driver.lua          # Main driver entry point
├── firetv.lua          # Fire TV protocol implementation
├── http.lua            # HTTP request utilities
├── timers.lua          # Timer management
├── json.lua            # JSON encode/decode library
├── icons/              # Device icons (16x16, 32x32)
├── www/documentation/  # In-Composer documentation
└── build.sh            # Build script
```

## Troubleshooting

**Cannot connect to Fire TV:**
- Verify the IP address is correct
- Check that Fire TV is powered on
- Ensure both devices are on the same network
- Check firewall rules for ports 8009 and 8080

**PIN not appearing:**
- Make sure Fire TV is at the home screen
- Try clicking **Start Pairing** again
- Enable Debug Mode to check logs

**Commands not working:**
- Verify Pairing Status shows "Paired"
- Enable **Auto Wake** if Fire TV goes to sleep
- Use **Test Connection** to verify connectivity

## Protocol Details

This driver implements the Fire TV Remote Control protocol:

- **Wake**: `POST http://<ip>:8009/apps/FireTVRemote`
- **PIN Request**: `POST https://<ip>:8080/v1/FireTV/pin/display`
- **PIN Verify**: `POST https://<ip>:8080/v1/FireTV/pin/verify`
- **Commands**: `POST https://<ip>:8080/v1/FireTV?action=<key>`
- **Media**: `POST https://<ip>:8080/v1/media?action=<action>`
- **Text**: `POST https://<ip>:8080/v1/FireTV/text`

All API calls require headers:
- `x-api-key: 0987654321`
- `x-client-token: <token>` (obtained during pairing)

## License

Copyright 2024. All rights reserved.

## Author

Zane St. John
