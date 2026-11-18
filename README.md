# Cellar

A native Mac app for running Windows games through Wine, in the spirit of CrossOver, with every setting out in the open.

Cellar is a front end. It contains no CodeWeavers code: it drives Wine builds you install separately, including Wine built from CodeWeavers' public CrossOver source. It is not affiliated with or endorsed by CodeWeavers, Valve or Apple.

**Status:** a personal project. Steam and Deadlock (DirectX 11) have run on an Apple Silicon Mac. DirectX 12 support is experimental.

## Download

Get **Cellar.zip** from [Releases](../../releases), unzip it, and read `Read Me First.txt`. In short:

- Apple Silicon Mac (M1 or later), macOS 15 or later, with Rosetta 2:
  `softwareupdate --install-rosetta --agree-to-license`
- A Wine engine. The recommended one comes inside [Cuvee](https://github.com/YesStonksMan/cuvee/releases), a free, open-source app that ships Wine built from CrossOver 26.3's public source, with DXMT. Install Cuvee; Cellar finds its engine automatically.
- The app is ad-hoc signed, not notarized. The first time, open it, click Done, then go to **System Settings → Privacy & Security → Open Anyway**.

## First game

1. Click **+**, name the bottle, and pick the engine **CrossOver-source Wine (from Cuvee)**. Windows 10, Retina mode off.
2. In **Settings**, set Graphics to **DXMT** and click **Apply**.
3. In **Programs**, open the **Steam** menu → **Install Steam**. Press ▶ on steam, sign in, and install your game.
4. Launch games from Steam, use **Steam → Add Deadlock**, or add any `.exe` with **Add Program…**.

If something fails, the **Log** tab shows everything Wine printed.

## What you control, per bottle

| Setting | What it does |
| --- | --- |
| Wine engine | Which Wine build runs this bottle. Different bottles can use different builds. |
| Windows version | What version of Windows the bottle reports (11, 10, 8.1, 8, 7, XP). |
| Graphics | WineD3D (OpenGL), WineD3D (Vulkan → Metal), DXVK, DXMT, or D3DMetal (only if your engine ships it). |
| MSync / ESync | Faster thread synchronization on builds that support it. |
| Metal HUD / DXVK HUD | On-screen FPS and GPU stats. |
| Retina mode | Renders at full display resolution. |
| WINEDEBUG | Logging level. `-all` is fastest; `+loaddll` helps debug crashes. |
| DLL overrides | Your own `WINEDLLOVERRIDES`, added after the graphics ones. |
| Environment variables | Any extra variables, applied last so they override everything. |
| Programs | Saved launchers with their own arguments. |

Each bottle's settings live in a readable `cellar.json` inside its folder. The **Tools** tab has winecfg, regedit, Task Manager, Explorer, Control Panel, the uninstaller, a command prompt, winetricks, and Stop Everything.

## How rendering works

- **DirectX 9**: WineD3D on OpenGL, with any engine.
- **DirectX 10/11**: DXMT, which translates Direct3D 11 to Metal. On an engine that carries its own DXMT (like Cuvee's), Cellar loads it ahead of Wine's Direct3D the same way CrossOver does, with nothing to install. On other engines, the **Download and Install DXMT** button installs a pinned, checksum-verified release, and an **Engine check** tells you whether that engine can load it. Stock WineHQ builds can't. The fallback is **WineD3D (Vulkan → Metal)**.
- **DirectX 12** (experimental): in a DXMT bottle on a CrossOver-source engine, DirectX 12 programs get VKD3D-Proton with DXVK's DXGI, on its own MoltenVK. Bundled in `Resources/d3d12`.
- **Steam's window**: Steam's interface is Chromium, which draws a black window under stock Wine. CrossOver-source engines fix this inside Wine. On other engines, Cellar swaps in a small wrapper for `steamwebhelper.exe` that starts Valve's helper with GPU rendering turned off.

## Limits

- Games with kernel anti-cheat don't run under Wine on any Mac app.
- Easy Anti-Cheat games (for example Elden Ring) only run offline, by launching the game's own `.exe` with a `steam_appid.txt` next to it.
- Deadlock uses Valve's VAC. Valve doesn't support playing through Wine on macOS, so there's some account risk.
- Check [ProtonDB](https://www.protondb.com) or [AppleGamingWiki](https://www.applegamingwiki.com) before trying a game.

## Build from source

Needs macOS 13 or later and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
./build.sh            # builds build/Cellar.app (Universal: arm64 + x86_64)
./build.sh --install  # also copies it to ~/Applications
```

Or double-click `Install Cellar.command`.

## Where things live

- Bottles: `~/Library/Application Support/Cellar/Bottles/<name>/` (each is a normal `WINEPREFIX`)
- Downloads (DXMT): `~/Library/Application Support/Cellar/Downloads/`
- Deleting a bottle moves it to the Trash.

## Project layout

```
Sources/Cellar/
  CellarApp.swift          app entry, windows
  Models.swift             BottleConfig and friends
  BottleStore.swift        bottle folders on disk
  Engines.swift            engine detection, CrossOver-source engine facts, Rosetta check
  WineRunner.swift         turns settings into env vars, runs Wine, collects logs
  BottleTools.swift        DXVK/DXMT installers, Steam installer and window fix, game scanner
  ContentView.swift, BottleDetailView.swift, ProgramsView.swift,
  BottleSettingsView.swift, ToolsView.swift, LogView.swift, EnginesView.swift
Resources/
  steamwebhelper-wrapper.exe   built from ThirdParty/steamwebhelper-wrapper
  d3d12/                       DirectX 12 runtime (see PROVENANCE.txt)
```

## Third-party components

Each ships with its licence in this repository and inside the app.

- **steamwebhelper wrapper**: MIT, from [notpop/steam-on-m1-wine](https://github.com/notpop/steam-on-m1-wine). Source in `ThirdParty/steamwebhelper-wrapper`.
- **VKD3D-Proton** (LGPL-2.1), **DXVK** (zlib), **MoltenVK** (Apache-2.0) and **Apple's Metal shader converter** (its own licence): from [VKD3D-Proton-MacOS](https://github.com/metalsharp/VKD3D-Proton-MacOS) v4.5. The DLLs are unchanged apart from Wine's 32-byte builtin marker.
- **DXMT** is downloaded at runtime from [3Shain/dxmt](https://github.com/3Shain/dxmt), not stored here.
