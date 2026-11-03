# HD texture pack

Upscales Silent Storm's model, world and terrain textures with an AI upscaler and stores them where the engine's own
loose-file override finds them: `<game folder>/hd/Textures/<id>`. The engine registers `hd` as a resource directory
after `res` and before any mods (`Game/Main.cpp`, `Main/ModManager.cpp`), so each HD file replaces one texture in
`res/Textures.res`, mods still win, and deleting the folder (or Settings > Graphics > HD textures off) restores the
original exactly. Nothing in `res` is modified.

## What is replaced, and why not the rest

The game writes the list itself: console command `texture_manifest <file>` (`Main/GTexture.cpp`) prints one line per
texture record: `id usage width height dxt bump cube terrain protectedAtlas`.

| Kind | Treatment | Reason |
|---|---|---|
| 3D model and world textures | 2x, original pixel format, full mip chain | normalised texture coordinates: any size works |
| Ground spots (roads, mud, grass patches) | 2x | stretched images, baked by the terrain baker |
| Terrain tiles (`terrain` = 1) | 4x, each square variant upscaled with a wrap-around border | they tile; the 1024 terrain bake magnifies them 4x |
| Interface art and font atlases (UI texture and typeface records) | never | drawn with pixel coordinates; a larger texture would show its top-left quarter |
| Bump maps | never | an upscaler invents detail, which in a normal map is noise |
| Terrain masks (`terrain` = 2) | never | blend weights |
| Cube-map faces | never | all six faces must change together |

## Building

```
# 1. manifest (from a running game: Settings test hook or the developer console)
cmd texture_manifest /private/tmp/texture_manifest.tsv
# 2. pack (resumable; about an hour on an M3 Pro)
port/tools/texpack/build_hd_pack.sh "<game folder>" /private/tmp/texture_manifest.tsv [/private/tmp/s2hd]
```

Upscaler: `upscayl-bin` (ncnn + Vulkan through MoltenVK) with the 4x-UltraSharp model (CC BY-NC-SA 4.0, fine for this
noncommercial port). Chosen after a side-by-side on real textures: realesrgan-x4plus flattened a grass tile to one
colour, Remacri drew wiry grass, UltraSharp kept the blades and wood grain. Override with `UPSCALER`, `MODELS`, `MODEL`.

`s2texpack` (built with the game, `port/tools/texpack/texpack.mm`) reads the package with the engine's own FileIO code,
decodes DXT with squish, and writes HD files in the original MMP layout: 24-byte header, then every mip level, largest
first, ending at the same smallest level as the original (Nival's DXT chains stop at 4x4).

## Safety and resume (policy v2)

Regenerate old eight-column manifests with the rebuilt game. Nine columns are required, including
`protectedAtlas`; UI art and every `CTypeface` atlas are protected. Older manifests could upscale font
atlases without updating glyph coordinates, scrambling all text.

`build_hd_pack.sh` calls `hd_pack.py`, which validates every existing MMP header and full mip payload.
Unsafe overrides move to `<work>/quarantine` without deletion. Textures already at the 2048 size cap
stay original. Database references absent from the source archive are reported separately. The
builder uses a fixed work list and at most two attempts per failed batch, retains original extracted
PNGs across interruptions, and exits nonzero on missing/corrupt output. A complete pack skips the upscaler.

Audit without rebuilding:

```
python3 port/tools/texpack/hd_pack.py "<game folder>" <manifest.tsv> <work dir> --audit --texpack <s2texpack>
python3 -m unittest discover -s port/tools/texpack -p 'test_*.py' -v
```

## Diagnostics

`S2_LOG_TEXTURES=1` prints every texture the game loads (`[texture] <id>` for the GPU path, `[swtexture] <id> WxH`
for the terrain baker's CPU path).

## Verified pack, 2026-10-25

The full GOG pack contains 4,006 eligible enlarged textures after removing 18 font/UI atlas overrides.
All 4,006 pass header, dimensions and complete mip-payload validation. Seven database IDs have no
corresponding source entry in Textures.res and retain the original loader behavior: 7598, 7611,
7628, 7629, 7630, 7660, 7661. Texture 5887 already reaches the 2048 cap and remains original.
The completion report distinguishes these from failed conversions and a no-op resume returns success.
