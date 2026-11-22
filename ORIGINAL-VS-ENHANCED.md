# Silent Storm for Mac: Original vs Enhanced, and what differs from 2003

Checked against this repository's code on 2026-11-03; the game rules section was added on 2026-11-21 with the merge of the reconstruction's November commits. Four parts:

1. What the **Original / Enhanced switch** changes.
2. Enhanced options that are **neutral by default**, so they change nothing until you move them.
3. What differs from the **2003 Windows game in both modes**, because it's the Mac version.
4. What is **still missing or unproven**.

**One limit:** "Original" means the original art and period settings on the new Mac renderer. It is not a pixel-exact copy of the 2003 game on a 2003 graphics card, and it has never been compared side by side with the real Windows release.

---

## 1. What the switch changes

Switch with F9 (fn-F9 on a MacBook keyboard), ⌘G, the Original / Enhanced control at the top right of the game, or Settings (⌘,). A short notice says which look is coming. Everything changes live, without reloading the map. Enhanced restores whatever you last set while in Enhanced; the values below are the defaults.

### New effects that Enhanced adds

| Feature | Original | Enhanced (default) | What it does |
|---|---|---|---|
| Ambient occlusion | Off | On, strength 0.85, radius 0.7 | Soft contact shadows in corners and where objects meet |
| Bloom | Off | On, strength 0.5, threshold 0.8 | Bright things glow softly |
| HDR highlights | Off | On, 0.6 of the display's headroom | Highlights brighter than white. Only on HDR displays, such as a MacBook Pro's XDR panel |
| Sharpening | 0 | 0.25 | Contrast-adaptive sharpening on the final image |

### Textures and terrain

| Feature | Original | Enhanced (default) | What it does |
|---|---|---|---|
| HD textures | Off, shipped art | On, when an HD texture pack is present | Sharper surfaces. The pack isn't included: you build it from your own game files with an upscaler (Real-ESRGAN was used) and `port/tools/texpack`, into `hd/Textures` in the game folder. Interface and font art keep their original pixels. Without a pack, Enhanced uses the original textures |
| Near terrain detail | 256 | 1024 | Ground texture bake, 4× sharper per side |
| Anisotropic filtering | As the game asks | 16× on every texture | Surfaces stay sharp at shallow angles |
| Engine anisotropic setting | 1 | 2 | The game's own filtering level |

### Lighting and rendering quality

| Feature | Original | Enhanced (default) | What it does |
|---|---|---|---|
| World render scale | 1× | 2× | Draws the 3D world at twice the pixels and shrinks it, smoothing edges and leaves |
| Sun shadow map | 1024 | 4096 | Sharper sun shadows, 4× per side |
| Light cache resolution | 64 | 256 | More detailed cached lighting |
| Sky light samples | 2 | 4 | Better sky lighting |

### Resolution

Original runs at 1024x768. Enhanced restores the resolution you last chose in Enhanced, so raising it there leaves Original at 1024x768.

---

## 2. Enhanced options that are neutral by default

The switch manages these too, but by default they match Original, so they make no visible difference until you change them in Settings while in Enhanced.

### Mac-only options

| Option | Default | Range |
|---|---|---|
| Upscaler | Bilinear, same as Original | MetalFX spatial, bilinear, nearest |
| FXAA anti-aliasing | Off | On or off |
| Distance haze | 0 | 0 to 1 |
| Texture sharpness (LOD bias) | 0 | -2 to 2 |
| Brightness | 0 | -0.25 to 0.25 |
| Contrast | 1 | 0.5 to 1.5 |
| Saturation | 1 | 0 to 2 |
| Vibrance | 0 | -1 to 1 |
| Temperature | 0 | -1 to 1 |
| Tint | 0 | -1 to 1 |
| Vignette | 0 | 0 to 1 |
| Film grain | 0 | 0 to 1 |
| Effects comparison view | Off | Debug views of the effects |

### Original game options, the same in both modes

By default all of these are on or at their high setting, and the switch leaves them alone: shadows, cached lighting, fog (per pixel), specular highlights, point-light highlights, soft sun shadows, soft lighting, decals, bump-mapped lighting, bump mapping on everything, precise point-light shadows, particles, weather effects, texture compression, full texture detail, 32-bit textures, gamma 1, no FSAA, fastest mode off.

---

## 3. What differs from the 2003 Windows game in both modes

The switch deliberately leaves all of this alone, so it applies to Original too.

### Platform

- Runs natively on Apple silicon, with no Wine or emulation.
- Graphics run on Metal instead of Direct3D 9.
- Sound runs on Core Audio instead of FMOD. Speech and music use macOS's decoder when the bundled one refuses a file.
- A native Mac Settings window (⌘,) with over 100 options, each described, and a Mac menu bar.
- Retina and HDR support, VSync, triple buffering, a frame-rate limit and a performance overlay.
- Saves, settings and game data live in `~/Library/Application Support/Silent Storm`.
- Bink videos play from MP4 copies made once from the original files (`port/tools/convert_videos.sh`, which needs ffmpeg), decoded by macOS.
- The CD check is gone.
- The companion app, Silent Storm Gold (`hub/`), can read your live squad and visible enemies during a mission, and switch graphics and cheats while you play. The game only reports this to the app; nothing changes unless you press something there.

### Physics

Settings has three presets. Original is the default.

| Setting | Original (2003) | Smooth | Cinematic |
|---|---|---|---|
| Simulation rate | 20 per second | 60 | 120 |
| Solver iterations | 5 | 10 | 16 |
| Extra joint limits (left disabled by the developers) | Off | Off | On |

Ground friction (0.6) and skeleton stiffness (1) stay at the original values.

### Camera and controls

- Mouse wheel zoom: one tick of the original could cross the whole range. Here it takes about 12 ticks end to end (zoom speed 0.3 by default), and trackpad coasting is ignored.
- Settings also expose field of view, closest and farthest zoom, tilt limits, and rotation and scroll speed, with Stock, Wider and Unlocked camera presets.
- Mouse movement keeps fractions of a pixel and stays independent of resolution.
- The game never moves or traps your Mac pointer, and Escape, losing focus and quitting release held keys and buttons. The trade-off is that a long camera drag can stop at the edge of the display.
- Control-click acts as right click. Two-finger scrolling zooms.
- On a MacBook, Command stands in for the keys a laptop lacks: ⌘8, 5, 4, 6, 1 and 3 aim like the numpad, ⌘↑ and ⌘↓ change floors, ⌘← centres the soldier, ⌘= and ⌘- zoom, ⌘S and ⌘L quick save and load, ⌘⇧S and ⌘O open the save and load menus, ⌘P pauses.
- Enemy and ally turns can run at 2×, 3× or 4× (F2 or ⌘T, Settings > Gameplay, or the companion app). The other sides decide exactly as at normal speed, and your own turns stay normal.
- A gun's tooltip compares it with the gun in the soldier's hands, using the game's own hit formula for that soldier, and says whether it suits them. Hold Shift for every stat.
- F1 or ⌘/ shows every key on one sheet, read from the game's own bind file, so an edited bind shows as it is. F1, ⌘/ or Esc closes it. The original game binds nothing to F1 or F9.
- Mute in the background and pause in the background.

### Options the original kept hidden, now in Settings

- Turn behaviour: always turn-based, turn-based on spotting an enemy, turn-based on grenades.
- Interface: hints, tooltips and their delay, status icons, the message log, skipping the intro videos.
- Violence: blood, headshot decapitations.
- The developers' own cheats, each as a switch. They stay on until you turn them off, whether you set them in the game or in the companion app.
- Advanced renderer options and a console log file.

### Game rules and enemy behaviour

The game logic here is met-nikita's reconstruction of v1.2, merged up to its commit `ae4c7f2` of 2026-11-19. Its aim is the retail game's behaviour, checked against the retail executable, and most of what follows is the reconstruction getting closer to retail than earlier builds of this port were. Where it departs from retail on purpose, the list says so.

Matched to retail in the November 2026 merge (187 commits; earlier builds of this port behaved differently):

- Hit chances are cut to a whole number, where they were rounded: 67.6 shows and rolls as 67. Hit rolls run from 1 to 99.
- Cover keeps its fractions through the calculation. The shot itself and the preview on the cursor use different trace masks, as retail does.
- Bursts: later bullets stay near the previous one, and a burst is at least 1 bullet. Rockets use real cover and explode where they collide.
- Enemies aim at the head when their chance is above 50% and the head is more than 5% exposed. Earlier builds always fired at the body.
- Enemies fire a shorter burst when they cannot afford the full one, switch weapons when out of ammunition, and choose targets by threat. Enemy snipers check the pose they will fire from and keep their aim between turns.
- Enemies in a Panzerklein only use the actions retail allows them. Enemy rockets are held when an ally stands near the aim point.
- New enemy and neutral units carry only the equipment listed for the current difficulty.
- Action point costs for hiding, climbing, jumping, doors, ladders, stance changes and turning come from the game's database. With the retail database, one cost differs from earlier builds: the first climb costs 12, was 10.
- Units route around mines their side knows about. Reloads top up a clip from same-type ammunition. A Look order in the direction already faced is free. Criticals end one turn sooner. Fall damage is at least 2.
- Medal points accrue for kills, for disarming traps and for disabling a Panzerklein.
- Voice lines follow retail's rules for who speaks and when. World sounds no longer replay after a skipped cutscene.

Deliberate departures from the 2003 game, made by the reconstruction and carried here. Each is marked `ORIGINAL RETAIL BUG FIXED` in the source (23 markers):

| Area | 2003 behaviour | Here |
|---|---|---|
| Action point floor | Skill and perk discounts could make a paid action or a paid shot cost 0, and a negative cost could award points | A paid cost is at least 1 after reductions; a treatment needs at least 1 available point |
| Perks that did not do what their description says | Perk 88 (throw range) scaled velocity; perk 75 (night camouflage) helped the observer; perk 70 applied its melee bonus to an unused value; perk 52 added its lockpicking bonus to the final score; perk 22 left the full preparation cost in place; perk 19 cancelled only part of the movement penalty; perk 30 halved recoil decay; perk 47 reduced the wrong input | Each follows its description |
| Units and movement | A walk-and-open order could kill the unit; a unit interrupted at a blocked ledge was trapped; cancelling during a door opening bypassed the interrupt; a unit could not use items after a ladder; path smoothing could move a stance change to another tile | Fixed |
| Enemy AI | Reactions could run for a dead or unconscious unit; a sniper lost its aim on every refresh; point-blank shots that could not connect were accepted; switching to bare hands stowed the gun from the wrong place | Fixed |
| Bodies and scripts | A fresh kill in a crowded room could vanish; the script command that prepares a shot spent ammunition | Fixed |
| Saves | Some commands and one visitor record were saved as raw memory, which could restore a dangling address | Saved as structured data |
| Interface and sound | A dialogue hit test compared screen pixels with interface units; the sound mixer lost all but 150 ms of a skipped turn | Fixed |

There is no switch for these: Original mode changes graphics, not rules. The reconstruction's commit history has the reasoning for each.

### Bugs fixed that the Windows game or earlier Mac builds had

**Crashes**
- Loading a save made with the objectives window open crashed at the next change of screen. The retail code wrote raw pointers into the save.
- An unarmed enemy's melee destroyed the shared fists and crashed the next to-hit check.
- Quitting after gunfire crashed, because of how objects were destroyed under the Mac compiler.
- Hints, objectives and save thumbnails could crash when the game resolution was bigger than the desktop.
- Sounds the decoder refused could crash the game.
- A crash when quitting while the renderer was still warming up.

**Sound**
- Nearly all speech and most music were silent on the Mac until the decoder fix.

**Graphics**
- Bushes and rain could flash bright white and orange, because their shared 1024 texture atlas overflowed. It is now 4096. Measured in test runs, not yet confirmed in play.
- Garbled text caused by HD versions of font images.
- Dark or black HD textures, and distant textures that shifted brightness.
- A purple line and a one-pixel image shift.
- Flicker from the ambient occlusion pattern.
- Text and buttons sized wrongly at high resolutions.
- Ragdolls at finer physics steps froze while still moving.

**Saves, menus and performance**
- Quickload could pick an empty slot.
- Slot names with spaces can now be saved and loaded from the console and the companion app. Saving used to cut the name at the first space.
- A wasted folder scan on every frame, up to 79% of the main thread on the chapter map.

---

## 4. What is still missing or unproven

Compared by class name with the Windows `game.exe` on 2026-11-02: of its 1,452 classes, 1,431 (98.6%) are found in this source. The other 21 are small helpers and interfaces, not checked one by one. A matching name shows a class exists, not that it behaves identically.

No missing gameplay feature is known. What hasn't been done:

- The game hasn't been played through to the end on the current build.
- Part 3 lists the known changes. It isn't a line-by-line comparison with the Windows game, and that comparison has never been run.
- The game rules list in Part 3 is drawn from the reconstruction's commits and source comments. The enemy behaviour and hit arithmetic in it have been run in automated tests, not judged in play.
- The fixes in the reconstruction this is built on are checked in its own repository, not here.

## What this list can't promise

- The game itself is a reconstruction from Nival's source release and decompiled v1.2 code. Its README ([README.reconstruction.md](README.reconstruction.md)) warns that small behaviour differences from v1.2 may exist, and those aren't individually known.
- Part 1 comes straight from the switch's code and its default values.
- Measured results here come from automated test runs of the game, not from a person playing.
