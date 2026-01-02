# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Control4 DriverWorks driver for controlling Amazon Fire TV devices. It implements the Fire TV Remote Control protocol (reverse-engineered from the official Fire TV Remote iOS app) in Lua, targeting Control4 OS 2.10.6+.

## Build Command

Create the installable driver package:
```bash
zip -r fire_tv_remote.c4z driver.xml driver.lua icons www -x "*.DS_Store"
```

## Architecture

### Driver Structure
- `driver.xml` - Control4 driver manifest defining properties, commands, actions, connections, and proxy bindings
- `driver.lua` - Main Lua implementation with all protocol logic
- `icons/` - Device icons (16x16 and 32x32 PNG)
- `www/documentation/` - HTML documentation shown in Composer

### Key Protocol Details

**Fire TV API Endpoints:**
- Port 8009 (HTTP): DIAL protocol for waking the Fire TV Remote receiver app
- Port 8080 (HTTPS): REST API for all control commands (uses self-signed cert)

**Authentication Flow:**
1. Wake device via `POST http://<ip>:8009/apps/FireTVRemote`
2. Request PIN via `POST https://<ip>:8080/v1/FireTV/pin/display`
3. Verify PIN via `POST https://<ip>:8080/v1/FireTV/pin/verify` → returns client token
4. All subsequent calls require `x-api-key: 0987654321` and `x-client-token: <token>` headers

**mDNS Discovery:**
- Service type: `_amzn-wplay._tcp.local.`
- Multicast address: 224.0.0.251:5353
- Device info extracted from TXT records (`fn`/`n` for name, `md` for model)

### driver.lua Organization

| Section | Purpose |
|---------|---------|
| Constants | API ports, timing values, binding IDs |
| Global State | `g_FireTV`, `g_Discovery`, `g_DiscoveredDevices`, `g_Timers` |
| JSON Library | Embedded JSON encode/decode (OS 2.10.6 compatible) |
| mDNS Discovery | DNS packet building/parsing, multicast handling |
| Timer Utilities | Named timer management via `SetTimer`/`KillTimer` |
| HTTP Handling | `HttpGet`/`HttpPost` wrappers for C4:url* functions |
| Fire TV Protocol | Wake, pairing, key commands, media control, text input |
| Driver Lifecycle | `OnDriverInit`, `OnDriverLateInit`, `OnDriverDestroyed` |
| Property/Command Handling | `OnPropertyChanged`, `ExecuteCommand` |
| Proxy Communication | `ReceivedFromProxy` for Control4 room integration |

### Control4 APIs Used
- `C4:urlGet/urlPost` - HTTP requests
- `C4:CreateNetworkConnection/NetConnect/SendToNetwork` - UDP multicast for mDNS
- `C4:UpdateProperty/UpdatePropertyList` - UI property updates
- `C4:SetTimer` - Async timing
- `C4:FireEvent` - Trigger driver events
- `PersistData` - Persistent storage across reboots

### D-pad vs System Keys
- **D-pad keys** (up/down/left/right/select): Require `keyDown` then `keyUp` with 50ms delay
- **System keys** (home/back/menu): Single press, no keyDown/keyUp needed
