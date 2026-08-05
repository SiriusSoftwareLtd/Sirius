# Sirius

Sirius is an open-source Roblox client interface: a smartBar, character actions, a playerlist,
per-experience settings, local music playback, ScriptSearch, and a set of detections that warn
you about high latency, degraded performance and loud audio.

| File | Purpose |
| --- | --- |
| [`source.lua`](source.lua) | The client itself. This is what the loadstring runs. |
| [`boost.lua`](boost.lua) | Applies Boost cosmetics to the Roblox player list. Loaded by `source.lua` at startup. |
| [`prompt.lua`](prompt.lua) | Standalone warning-prompt module, also consumed by Rayfield. |

## Running

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/SiriusSoftwareLtd/Sirius/request/source.lua"))()
```

Sirius feature-detects everything it needs from the executor. Missing functions degrade the
relevant feature rather than stopping startup — `setfpscap`, `identifyexecutor`, `getcustomasset`
(Music), `getconnections` (Anti Idle), `hookmetamethod` (Anti Kick), `request` (ScriptSearch,
webhook logging and the interception prompts) and the filesystem functions (settings persistence)
are all optional.

## Developing

The toolchain is pinned with [Rokit](https://github.com/rojo-rbx/rokit) and matches Rayfield-gen2.

```sh
rokit install                  # StyLua, selene, luau-lsp
selene generate-roblox-std     # writes roblox.yml, which sirius.yml chains from
selene source.lua boost.lua prompt.lua
stylua --check source.lua boost.lua prompt.lua
```

For a type/syntax pass:

```sh
curl -sSL -o globalTypes.d.luau \
  https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
luau-lsp analyze --definitions=globalTypes.d.luau --no-strict-dm-types source.lua boost.lua prompt.lua
```

CI runs all three on every push.

`source.lua` also has a Studio path: `RunService:IsStudio()` makes it look for the interface as a
sibling of the script rather than calling `game:GetObjects`, so the UI can be worked on without an
executor.

## Notes

- `sirius.yml` is the selene standard library: Roblox's, plus the executor globals Sirius
  feature-detects. `roblox.yml` is generated and gitignored.
- Settings live in `Sirius/settings.srs` as a flat `{ id = value }` map. Files written by 1.27 and
  earlier used a nested tree; those are still read and migrated on first launch.
- See [`AUDIT.md`](AUDIT.md) for the 1.28 bug audit and what remains outstanding.
