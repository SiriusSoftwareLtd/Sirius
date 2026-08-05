# Sirius — 1.28 Bug Audit

Audit performed against `2105096` (1.27, last touched 2026-05-13). Reference baselines:
`SiriusSoftwareLtd/Rayfield` (Build 1.749) and `SiriusSoftwareLtd/Rayfield-gen2` (1.1.0).

Everything in "Fixed" landed in 1.28. "Outstanding" is what was deliberately not attempted.

⚠️ **None of this has been run against a live Roblox client.** It is verified by `selene`
(0 errors, 0 warnings), `luau-lsp analyze` (no syntax errors, no undefined globals) and code
review. The behavioural changes — particularly noclip, spectate, settings migration and the
interception hooks — want a smoke test on a real executor before this is announced.

---

## Fixed — startup and runtime killers

**`setfpscap` called unguarded on the startup path.** `start()` → `windowFocusChanged(true)` →
`setfpscap(...)`. Absent on several mobile/ARM executors, and an uncaught error there killed the
entire script before any UI or event was wired up. Now resolved through the same `optional()`
feature-detection every other executor global goes through, and `start()` itself runs inside a
pcall that reports through a notification instead of dying silently.

**`identifyexecutor()` called unguarded, once per second.** Inside `UpdateHome`, which meant on an
executor without it the whole function threw every tick — ping, player counts, friend counts and
the server panel all silently stopped updating.

**Hard CoreGui indexing in the update loop.** `coreGui.RobloxPromptGui.promptOverlay` was a hard
index inside `while task.wait(1)` with no pcall. One miss ended the loop permanently: no clock, no
Home refresh, no anti-idle, no latency or FPS warnings, no disconnect detection — with the
interface still on screen looking healthy. Now `FindFirstChild` chains, and the whole tick body is
wrapped so a single bad tick logs and recovers instead of ending the session. Same treatment for
`coreGui.RobloxGui.Backpack`, which threw on the very first smartBar open.

**Clearing any keybind broke all keyboard input.** The keybind editor sets `current = nil` when the
box is emptied; the two trailing `Enum.KeyCode[...]` lookups had no nil guard, so after that every
keypress threw and took out all keybinds, the smartBar toggle and ScriptSearch. Both now go
through `keyCodeFromName`.

**Two keybinds threw on every press.** `checkAction` matched the *setting* name against the
*action* name and always returned a table even on a miss, so the caller's `if action then` guard
never fired. `'NoClip'` vs `'Noclip'` and `'ESP'` vs `'Extrasensory Perception'` never matched.
Keybind settings now carry an explicit `actionIndex`, and the shared `applyActionVisual` drives
both the grid buttons and the keybinds.

**`GetRoleInGroup` on every join, in every experience.** A yielding web call, run for every
`PlayerAdded` regardless of whether the place was group-owned, sitting *above* the friend-
notification block — so an error or a rate limit silently swallowed the rest of the handler. Now
gated on group ownership, pcall'd, and moved off-thread.

---

## Fixed — wrong behaviour and data loss

**Focusing a webhook field truncated and saved it.** Long values displayed shortened
(`https://discord.com/api/w..`) and `FocusLost` wrote the box contents straight back. Clicking into
a field and out again permanently replaced the stored URL with its truncated form. Display and
stored value are now separate: `Focused` restores the full value, `truncateForDisplay` is
presentation only.

**Removing a track deleted two queue entries.** The removal loop iterated every *field* of each
queue entry; `sound` and `instanceName` both hold the filename, so each match fired twice and
`table.remove` ran twice — silently dropping the following track. It also mutated the queue while
iterating it. Replaced with a single indexed pass matched on one field.

**Music filename truncation tested the wrong string.** `string.len(newAudio.FileName.Text)` read
the cloned template's placeholder rather than the filename, so truncation fired off a constant.

**`sortPlayers` skipped half the list.** `table.remove` while iterating the same array with
`ipairs`, so every removal shifted the list under the iterator — leaving Template/Placeholder
frames in the sort and mis-ordering the rest.

**Field of view drifted on every Home open/close.** Open added 5, then re-read the camera 0.25s
later *mid-tween* and subtracted 40 from that moving value; close added a flat 35 back. Home now
captures the FOV on entry and restores that exact value.

**Moderator Detection could never fire.** It gated on `siriusValues.currentCreator`, only ever
assigned inside `syncExperienceInformation`, which only ran when `enableExperienceSync` was true —
and that was hardcoded `false`. Creator identity is now resolved directly at startup.

**Re-running Sirius stacked the interception hooks.** Each run captured whatever was currently in
`getgenv()` and wrapped it, so a second run wrapped Sirius' own wrapper: two prompts per request,
three on the third run. The pristine functions are now stashed under a `siriusOriginals` sentinel
and re-read on every run, the same approach Rayfield uses for `rayfieldCached`.

**A malformed allowlist bricked every HTTP request.** `JSONDecode` on `allowedLinks.srs` with no
pcall, on the hot path of the request hook. One truncated write and every `request()` in the
session threw. Same failure class Rayfield fixed in `669be03`.

**The security prompt blocked its caller forever.** `repeat task.wait() until decision ~= nil` with
no timeout, in a synchronous hook. Now denies after 60s, and also bails if the prompt is destroyed.

**Request hook robustness.** It indexed `data.Url` before checking `data` was a table, installed
itself even when the executor had no request function to fall back on (so the replacement called
`nil`), decoded the Discord RPC body without a pcall, and returned nothing on the deny path where
callers expect a response table. Detection also widened to `syn.request` / `fluxus.request` /
`http.request`, matching Rayfield.

**Anonymous Client used names as Lua patterns.** Display names containing `-`, `.`, `(` or `%`
either mismatched or errored. It also lowercased the whole label and restored only the first
character's case. Replaced with `replacePlain`, a case-insensitive literal replace.

**`fetchFromCDN` and `fetchIcon` always returned nil** — both `return`ed from inside their own
pcall closure. `fetchFromCDN` is fixed and the startup sound it feeds is re-enabled; `fetchIcon`
had no callers and was removed.

**`checkFolder` created the child before the parent** (`Assets/Icons` before `Assets`).

**`updateSlider` precedence.** `data.callback and not setValue or forceValue` parses as
`(callback and not setValue) or forceValue` — a forced update on a callback-less slider called
`nil`. Also fixed the two slider callbacks that checked `if character` and then dereferenced
`humanoid`.

**`sortActions` threw on a Humanoid-less character**, aborting `start()` and leaving the interface
half-built.

**Settings persistence rewritten.** The whole `siriusSettings` tree was serialised, including
Color3 values and the keybind callback functions. Now only `{ id = current }` is persisted, values
are type-checked on load, and files written by 1.27 and earlier are read and migrated.

**`checkSetting`'s category-scoped form** returned after examining only the first category. All
reads now go through `settingValue`, which returns a default rather than indexing nil.

**`promptModerator` re-connected its buttons on every invocation** — after N detections one click
on Leave fired N times. Connected once at load.

**`teleportTo` looked up `workspace:FindFirstChild(player.Name)`** instead of `player.Character`,
which fails in any experience that reparents or renames characters. It also snapped you to an
identity rotation; your orientation is now preserved.

**`game:Shutdown()` called bare from two user-facing buttons.** Client availability is
executor-dependent. Now `leaveExperience()`, guarded, with a TeleportService fallback.

**`MarketplaceService:GetProductInfo` on the click thread.** Resolved once at startup instead.

**ScriptSearch:** `loadstring(result.script)` with no nil check (the search endpoint doesn't always
return a body), no compile/runtime error reporting, no response-shape validation, and
`scriptCreated` was set even when `createScript` threw.

**`serverhop` threw straight out of the click handler** when the games API was rate-limited.

**boost.lua — the unsupported-executor check was inverted.** `string.find(keyword, exec)` asks
whether the executor name appears *inside* the blocklist keyword; keywords are short and executor
names longer, so it never matched and the blocklist never blocked anything.

**boost.lua — the pcall result was discarded.** On a malformed response `boosts` held the error
*string* and `getBooster` went straight into `pairs()` on it, throwing for every player. The
per-player linear scan over all boosts is now a direct table index.

**prompt.lua** — `GetObjects` unguarded, and a second click during the close animation invoked the
callback twice and destroyed an already-destroyed prompt.

---

## Fixed — leaks and performance

**Descendant tracking was O(n²) and unconditional.** `table.find` — a linear scan — was run
against every instance the experience ever created, and `cachedText`/`cachedIds`/`soundInstances`
were append-only. The startup `game:GetDescendants()` sweep also ran unconditionally even with
both consumers switched off. Membership is now hash-set based, registration is gated on whether
Spatial Shield or Anonymous Client is actually on, and turning either on mid-session backfills.

**Noclip walked the character every physics step.** `character:GetDescendants()` ~60×/sec whether
or not noclip was on. The BasePart list is now cached and maintained by `DescendantAdded`/
`DescendantRemoving`, writes only happen while noclip is active plus once on the trailing edge,
and `noclipDefaults` — which pinned a fresh set of dead part references on every respawn — is
cleared per character.

**Teardown restored almost nothing.** The exit path released the ESP folder, the DescendantAdded
hook and the anonymous text, and left behind every per-frame connection, the blur, the FPS cap,
the muted master volume, CanCollide overrides and the CoreGui states. Connections are now tracked
in one table and released together, and the global state Sirius changed is put back.

**`UpdateHome` ran every second whether or not Home was visible** — including a paginated
`GetFriendsAsync` every 25s for a panel that may never have been opened.

**`playNext` recursed once per track** (not in tail position, so the stack grew for the length of
the queue). Now iterative, and an unreadable file is skipped rather than stalling the queue.

**Blocking remote loads on the startup path.** The analytics `reporter.lua` fetch was a bare
`HttpGet` with no timeout. Now uses Rayfield's `loadWithTimeout`, and is sampled to ~1 in 10
launches to match Rayfield's current behaviour. `boost()` uses the same helper.

**`closeHome` restored interfaces by name**, re-enabling anything that happened to share a name
with something it hid, via a nested loop that walked the whole PlayerGui once per cached entry.
It now stores instances.

**`openPanel`/`closePanel` claimed the debounce before their guard clauses** and returned with it
stuck true, which would lock every panel, Home, Settings, Music and ScriptSearch for the session.
Latent — no current caller reaches it — but one refactor away from live.

---

## Fixed — dead code and honesty

- Removed the 228-line commented-out neon module.
- Removed Experience Sync, the five `games` entries, `rawTree` (pointed at a branch of this repo
  that doesn't exist), and the `neonModule`/`senseRaw` URLs (retired `shlexware` org). All 404'd.
- **Kill** was never implemented — the handler played a colour animation and raised a *"Simulating
  Kill Notification"* toast. Killing another player is server-authoritative; the button is now
  hidden rather than faked.
- **Spectate** was the same kind of stub and *is* implementable client-side, so it now actually
  spectates: camera subject swap, toggle to restore, and it releases if the target leaves.
- **Chat Spy** is built on `DefaultChatSystemChatEvents`, which Roblox retired. It cannot be
  reimplemented on TextChatService — whispers route through channels the client never receives.
  Rather than appearing switched on while doing nothing, Sirius now detects the chat version and
  says so once. `SetCore("ChatMakeSystemMessage")` falls back to `DisplaySystemMessage`.
- Webhook posting was duplicated across three call sites, each firing at the `"No Webhook"`
  placeholder when logging was on but no URL had been set. One `postWebhook` with URL validation.
- Deprecated APIs: `obj.className` → `ClassName`, `ins:getDescendants()` → `GetDescendants()`.
- **`Player:GetMouse()` removed.** Sliders used `mouse.X` and `mouse.Move`, which never fire for
  touch — sliders did not work on mobile at all. Now `UserInputService`, matching what
  `makeDraggable` already did. `InputEnded` also accepts touch releases.
- `cloneref` is now used for every service handle where the executor provides it.
- Added a `useStudio` path so the interface can be developed without an executor.
- Executor list extended with the current generation (wave, solara, xeno, swift, codex, etc).

## Fixed — repo

`rokit.toml`, `.luaurc`, `selene.toml`, `sirius.yml` (selene std: Roblox + the executor globals),
`stylua.toml`, `.gitignore`, a CI workflow running format/lint/analyze, and a real README.

---

## Outstanding — deliberately not done

**Module split.** `source.lua` is still one ~4,900-line file. Rayfield-gen2 splits into ~50 modules
under `src/`. That is the right destination, but it is a rewrite, not a fix, and it cannot be
validated without a live client. Doing it in the same change as the bug fixes would have made both
unreviewable. The natural seams already exist in the file: settings, notifications, panels,
character actions, playerlist, music, security, analytics.

**Tests.** gen2 has unit and integration tests under a Lune shim with a coverage baseline. Sirius
has no test harness. Worth adding alongside the module split, since most of what is testable here
is currently tangled with UI construction.

**License inconsistency.** `LICENSE` is MIT © 2024 "Sirius", the `source.lua` header says
"© 2026 Corridon Capital. All Rights Reserved.", and Rayfield-gen2 is MPL-2.0 © Corridon Capital.
Three different answers. Not something to decide in a bugfix pass.

**Pro/Essential scaffolding.** `Pro` is hardcoded `true` and `Essential` is never defined, so every
`minimumLicense` gate, the "This feature is locked" notifications, the `LicenseDisplay` badges and
the `script_key` check are unreachable branches. Removing them touches settings-panel layout, so it
wants its own change.

**`BodyVelocity`/`BodyGyro`/`BodyAngularVelocity`** (flight, fling) are deprecated in favour of
`LinearVelocity`/`AlignOrientation`/`AngularVelocity`. A behavioural change to flight feel that
needs in-game testing to tune.

**Formatting.** `stylua` config is committed and CI checks it, applied as its own commit so the
bugfix diff stayed readable.

**The `Region` field on the Home panel** is still a hardcoded `"Unable to retrieve region"`
placeholder.
