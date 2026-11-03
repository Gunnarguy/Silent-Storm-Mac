# Silent Storm for Mac

A native macOS port of **Silent Storm** (2003), the turn-based tactics game by **Nival**. It runs on Apple silicon with no Wine or emulation: Metal for graphics, Core Audio for sound, and a small companion app, Silent Storm Gold, to launch it and explore the game's data.

This is a non-commercial fan project. It contains no game files: you need your own copy of Silent Storm (GOG or Steam).

## Credits

All of the game belongs to **Nival**. This port exists only because:

- **Nival** released the Silent Storm source code for study and modification: [nival/Silent-Storm](https://github.com/nival/Silent-Storm). Thank you, Nival.
- **Nikita Metelkov ([met-nikita](https://github.com/met-nikita))** rebuilt that source into a behaviour-equivalent version of Silent Storm v1.2, from the v1.1 debug symbols and the v1.2 executable: [met-nikita/Silent-Storm-Reconstruction](https://github.com/met-nikita/Silent-Storm-Reconstruction). Nearly 300 commits of careful reconstruction. Everything here is built on that work, and its history is kept in spirit: the engine code outside `port/` and `hub/` is theirs and Nival's. Their own README is kept as [README.reconstruction.md](README.reconstruction.md) ([Русский](README.reconstruction.ru.md)).
- **Drikus Roor** translated the reconstruction's README into English.
- Bundled libraries: zlib, libpng and squish, each under its own licence in `third_party/`. The FMOD, Bink and LifeStudio headers there are interface headers from the reconstruction project.

The macOS work is the `port/` folder (the Metal renderer, Core Audio, input, the Mac window and Settings), the companion app in `hub/`, and changes through the engine where the port needed them.

## Licence

The game, its source and its identity belong to Nival and are used under Nival's licence ([LICENSE.md](LICENSE.md), copied from [nival/Silent-Storm](https://github.com/nival/Silent-Storm/blob/main/LICENSE.md)): **non-commercial use only**. That applies to this repository too. Please don't sell builds, bundle it with anything paid, or attach donations to it. Nival can withdraw that licence; if they do, this repository comes down.

This project is not affiliated with or endorsed by Nival.

## What the Mac version adds

- Native Apple silicon build, Metal renderer, Retina and HDR displays, VSync and frame pacing
- **Original / Enhanced** graphics, switched live with **F9** or **⌘G**: the 2003 look, or ambient occlusion, bloom, higher-resolution shadows and supersampling
- A native **Settings** window (**⌘,**) with every option described, including ones the original game hid
- **F1** or **⌘/** shows every key, read from your own key bindings
- **MacBook keys**: Command stands in for keys a laptop lacks (⌘8/5/4/6/1/3 aim like the numpad, ⌘↑/⌘↓ change floors, ⌘S and ⌘L quick save and load, and more)
- **Faster enemy and ally turns**: 2×, 3× or 4× with **F2** or **⌘T**. The other sides decide exactly as at normal speed; your own turns stay normal
- **Weapon comparison on hover**: a gun's tooltip compares it with the one in the soldier's hands, using the game's own hit formula for that soldier (skills, perks, wounds, pose, familiarity) at three ranges. Hold Shift for every stat
- Silent Storm Gold: launch the game, read your live squad, and browse every character, voice line, weapon, perk, mission, sound, model, texture and database table

## Building

Requirements: Apple silicon, Xcode with its command-line tools, CMake 3.24 or later and Ninja. The game runs on macOS 14 or later; the companion app needs macOS 26 and Swift 6.2.

```bash
cmake -S port -B build -G Ninja
cmake --build build
```

The game is `build/Silent Storm.app`. On first launch it asks for your Silent Storm folder (from GOG or Steam) and copies the game data into `~/Library/Application Support/Silent Storm`.

The companion app:

```bash
cd hub
swift build -c release
```

## Status

The Allied campaign plays, as it does in the reconstruction it builds on. Some behaviour may still differ from the 2003 release; reports are welcome as issues.
