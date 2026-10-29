# Raid Night: Phase 1 playtest kit and soak runbook

Phase 1 is "offline raids and revenge that work, safely". This file has four parts:

1. Before playing (merge order, publish, flags)
2. Single-client Studio pass (integration agent)
3. Soak runbook, P1.10 (integration agent; multi-client parts need Kian)
4. Friends playtest kit, the Phase 1 gate (tester-facing, then notes for Kian)

Updated for the full Phase 1 PR set (#92 to #110, without #96). Steps below are the real plans
of #99 to #110, in the order they are run. Each PR's own "Studio playtest plan" is still the
source of the exact commands; if a plan and this file disagree, the PR wins and this file gets a fix.

---

# 1. Before playing

## Merge order (Kian; merges are refused for agents, D-044)

Two ways to get everything onto `integration`. Pick one.

**Option 1: one go.** Branch `preview/phase1` is `integration` plus every PR below except #96,
merged in the order of the table, with all text conflicts already resolved (see "Conflicts
already resolved"). `lune run tests/run.luau` (EscrowSimulation included), `stylua --check`,
`selene src` and `luau-analyze` are all clean on it. After reviewing the individual PRs:

```
git fetch origin
git switch -c integration-sync origin/integration      # in a clean worktree, not the Rojo checkout
git merge --no-ff origin/preview/phase1
lune run tests/run.luau
git push origin HEAD:integration
```

GitHub should mark each PR merged once its commits reach `integration`; if one stays open, close it.
Delete `preview/phase1` afterwards. If you later decide against one PR, use option 2 for it instead.

**Option 2: PR by PR.** Bottom of each stack first. A stacked PR points at its parent's branch, so
before merging it retarget it to `integration` once the parent has merged. Do not use
`--delete-branch` on a parent while children still point at it.

| Order | PR | Base now | Commands |
| --- | --- | --- | --- |
| 1 | #92 P1.5b | integration | `gh pr merge 92 --merge` |
| 2 | #94 P1.9 | integration | `gh pr merge 94 --merge` |
| 3 | #95 P1.7 | integration | `gh pr merge 95 --merge` |
| 4 | #97 P1.1 | integration | `gh pr merge 97 --merge` |
| 5 | #98 P1.1b | #97 | `gh pr edit 98 --base integration` then `gh pr merge 98 --merge` |
| 6 | #99 P1.4a | integration | `gh pr merge 99 --merge` |
| 7 | #100 P1.3a | integration | `gh pr merge 100 --merge` |
| 8 | #101 P1.3a-world | #100 | `gh pr edit 101 --base integration` then `gh pr merge 101 --merge` |
| 9 | #103 P1.3c | #100 | `gh pr edit 103 --base integration` then `gh pr merge 103 --merge` |
| 10 | #105 P1.9b | #94 | `gh pr edit 105 --base integration` then `gh pr merge 105 --merge` |
| 11 | #106 P1.3b | #101 | `gh pr edit 106 --base integration` then `gh pr merge 106 --merge` |
| 12 | #107 P1.4b | #106 | `gh pr edit 107 --base integration` then `gh pr merge 107 --merge` |
| 13 | #109 P1.3d | #107 | `gh pr edit 109 --base integration` then `gh pr merge 109 --merge` |
| 14 | #110 P1.3e | #109 | `gh pr edit 110 --base integration` then `gh pr merge 110 --merge` |
| 15 | #102 P1.6 | #100 | `gh pr edit 102 --base integration` then `gh pr merge 102 --merge` |
| 16 | #108 P1.6b | #102 | `gh pr edit 108 --base integration` then `gh pr merge 108 --merge` |
| 17 | #104 P1.10a (this kit) | integration | `gh pr merge 104 --merge` |
| later | #96 P1.8 | integration | Economy tuning, Kian's decision (D-045). Not in `preview/phase1`; not needed for the soak. |

Notes:

- Where a PR already targets `integration` the retarget command is a no-op; GitHub retargets
  stacked children by itself when the parent's branch is deleted on merge, so either way is fine.
- #98 needs #97; #101, #103 and #102 need #100; #105 needs #94; #106 needs #101; #107 needs
  #106; #109 needs #107; #110 needs #109; #108 needs #102. Skipping a parent means skipping its
  children.
- After each merge: `lune run tests/run.luau`. After #97, #98, #106 and #109 (they touch escrow
  and profiles) the single-client plan for that PR should run right away (part 2, B and F).

### Conflicts already resolved in `preview/phase1`

Merging in the table order, five merges conflicted on their own. Each was a "keep both" fix; the
same fixes apply if you merge PR by PR in this order.

- #98 `docs/contracts.md`: the Persisted data table's Profile row (P1.1b wording) and Snapshot row
  (P1.9 wording) were edited side by side; the Profile row has the P1.1b text and the Snapshot row
  keeps the P1.9 `DenSnapshots` key.
- #99 `src/Shared/Net.luau`: `GetReplay` (P1.4a comment) and `JoinRevengeServer` (P1.9) both stay in
  `Net.Requests`; `Net.Limits` has both `JoinRevengeServer` and `GetReplay`.
- #100 `src/Shared/Net.luau` and `docs/contracts.md`: P1.3a's `StartRaid`, `GrabCritter` and
  `GetRaidLog` comments with the P1.4a `GetReplay` and P1.9 `JoinRevengeServer` entries; the
  contracts "Async raids" and "Replays" sections both stay.
- #106 `src/Shared/Net.luau` and `docs/contracts.md`: `JoinRevengeServer` kept; the contracts keep
  P1.3b's updated "Async raids" section (before "Replays") and drop the older copy that merge #100 had put
  after "Replays".
- #107 `tests/specs/RaidServiceSource.spec.luau`: the live-revenge test (P1.9b) and the replay
  test (P1.4b) were both appended at the end of the file; both kept.

## Publish a private test (Kian)

Publish only the test place, never a live one.

- [ ] `git checkout integration` in a clean checkout (never switch branches in the main
      checkout that feeds Rojo). `lune run tests/run.luau` is green.
- [ ] `rojo serve`, connect the plugin in Studio, check that Output shows `[RaidNight] server started`.
- [ ] `ServerStorage` attribute `StudioMemoryProfiles` is absent or false in the file. It is
      Studio-only and a live server ignores it, but keep it off.
- [ ] Studio and published test place both have Studio Access to API Services on.
- [ ] Remove any local edits to `ReplicatedStorage.Shared.Config` (the Studio test plans ask for
      a local `asyncRaids = true` edit; never publish it by accident).
- [ ] File > Publish to the private test place. Max players 8.

## Flags (`Config.Flags`)

| Flag | Value for the friends test |
| --- | --- |
| `raids` | `true` (live stealing) |
| `asyncRaids` | `true`, but **only after every pre-P1.1 server has shut down** (D-049) |
| `purchases`, `trading`, `notifications` | leave off |

D-049, in order:

1. Publish the build that ships #97/#98 with `asyncRaids = false`.
2. In the Creator Hub, shut down all running servers of the test place.
3. Confirm no server is running, then publish the second build with `asyncRaids = true`.

An old server could void a Pending async record and lose the critter and Glow. This is the one
rollout step that cannot be rushed or skipped.

Kill switches (`raids`, `asyncRaids`) stop new raids only. Recovery of in-flight records ignores
them (D-002).

---

# 2. Single-client Studio pass (integration agent)

Run once per merge wave in one Play session, after the PRs above are on `integration` and
Rojo is synced. Output window open the whole time; any red error is a finding. Setup for
the whole pass: API access on. Steps A to C and the "Part B" blocks of F (#106, #109) use
DataStore mode (memory switch off); steps D to I and the "Part A" blocks of F use memory mode. The switch is read once at server start, so stop Play between the groups.

Test hooks (Studio only, in `ServerStorage`): `RaidTestHook`, `MatchmakingTestHook`,
`AsyncRaidTestHook`, `ReplayTestHook`. Attributes: `StudioMemoryProfiles`, `StudioAsyncRaids`,
`StudioEscrowPause`.

## Group 1: DataStore mode

**A. Defender profile (P1.1 step 0).** Local Server, 1 player (Player1, UserId -1).
Output shows `[DataService] loaded -1`, no memory warning. Get one or two critters on pads
(rescue egg or bought egg). Stop cleanly.

**B. Transfer and recovery, #97/#98 plan (steps 1 to 5).** Do the plan as written in #98. The
parts that matter:

1. `StudioAsyncRaids = true`, `StudioEscrowPause = "deliveredDebit"`. `transferAsync("p11-sd-1", me, -1, uid, 0)`
   holds at `deliveredDebit`: defender lost the uid, record is `Pending`, you do not have it yet.
2. Stop within 2 minutes. Play again with both attributes unset. Within ~15 s: record
   `Committed`, uid in your profile exactly once, gone from `peekOffline(-1)`, `record.glow`
   equals both sides' `appliedTransfers[raidId].glow` and is not 0.
3. Same with pause `"savedRaider"` (`p11-sd-2`): `Committed`, one copy, Glow credited once.
4. Replaying `p11-sd-1` identically returns `Committed`, changes nothing; with different
   `glowRequested` it returns `Refused`.
5. `StudioAsyncRaids` unset: a new raidId is `Refused` (switched off).

The forced-shutdown recovery check (step B2/B3) is the P1.1 exit check. It is the last thing
to pass in this group; record it explicitly in the status.

**B2. Offline-defender escrow handoff.** Run F's "#106 Part B" and "#109 Part B" here, while the group 1
setup (Local Server as -1 with a Pad critter and `stored = 1000`) is fresh. They read the same
real-save profile as B, so do B first.

**C. P1.3c.** Join, open the raid log; `RaidLogSeenAt` stays at its join value (0 on a fresh
save). Leave and rejoin on real saves: it is now about the first open's time, and "While away"
lists only newer Incoming entries.

## Group 2: memory mode

Set `StudioMemoryProfiles = true`, Play. For asyncRaids, set `Flags.asyncRaids = true` in
the Studio copy of `Shared.Config` only, and revert it afterwards.

**D. Matchmaking (#91).** `mm:Invoke` `seed`, `targets`, `lock`, `block` (raider and defender),
`unblock`, `presence`, `clear`. Revenge row first; blocked players never match; second `lock` contends.

**E. Live revenge (#94 plan).** `raid:Invoke("seed")`, `mm:Invoke("revenge", plot)`, then `join`
`here` (Arrived, token kept), `live`, `away` (Failed TeleportFailed, expected warn), `offline`
(RaiderOffline), forged `arrive` (NoToken), Lockdown then `join here` (border pushes you out),
client `JoinRevengeServer` with the flag off (SwitchedOff; third call in 10 s is Busy), junk
payloads. `clear` both hooks.

**F. Async raid (#101 plan, steps 1 to 12; then #106, #109, #110).** First #101: kill switch,
start, grab and carry, `gate` exploit (TooFast, Retreat), retreat, 3-minute timeout, guards and
traps, refusals (AlreadyRaiding, Blocked both ways, RevengeExpired, valid revenge), client trust
checks, reset mid-raid, live stealing regression, pocket part count (24 for 6 pads, 4 traps, 2
guards). Then the escape handoff, same memory-mode setup, `Flags.asyncRaids = true` in the Studio
copy only (#106 Part A setup block: `mm:Invoke("seed")`, `d = DS.getProfile(-1000101)`, `d.stored = 1000`,
`SnapshotService.saveTest(d)`, `me`; client prints `RaidEnded`):

- **#106 Part A.** 1: `raid:Invoke("start", -1000101)`, grab, gate. Within seconds the server prints
  `async raid <id>: ... moved <species> and <n> Glow`, the client prints `RaidEnded Escaped true nil
  <species> <n>` (n about 250), the critter is in `me.critters` (Inventory, `stolenLockUntil` set),
  `me.glow` rose by n, `d` lost the critter and `d.stored` dropped by n. 2: `d.shieldUntil` is about
  now + 14400, `d.revengeTokens[<raidId>]` targets you with `shieldBypassUsed = false`, `d.raidLog[1]`
  is Incoming `escaped = true`, `d.pairRaidsToday[tostring(me)] == 1`, `d.lossesToday == 1`,
  `d.appliedTransfers[<raidId>].role == "Debit"`, `me.appliedTransfers[<raidId>].glow == n`.
  3: **superseded by #109** (see below): the raider's Outgoing entry and pair count now exist.
  4: start again is `refused: Shielded`. 5: `mm:Invoke("clear")`, `seed`, `stored = 1000`, start, grab,
  move the critter to Inventory on the server before the gate (`for k, c in d.critters do if
  c.placement == "Pad" then c.placement = "Inventory"; c.padIndex = nil end end`), escape: `RaidEnded
  Escaped true nil nil <n>` (Glow only), nothing added to `me`. 6: revenge escape,
  `raid:Invoke("start", -1000102, "studio-revenge")`, grab, escape; the log line says `(revenge)`, the
  record's Glow is about 27.5% of stored, `DS.getProfile(-1000102).raidLog[1].isRevenge == true`.
  7: `mm:Invoke("lock")` reports `first true` once the push arrives (lock held while escrow runs).
  8: Retreat, Timeout and Tagged still push `escaped = false` with no `pending`; live stealing still works.
- **#106 Part B (DataStore mode, offline defender; needs the group 1 setup).** B0: Local Server as
  Player1 (-1), a Pad critter, `p.stored = 1000`, stop cleanly. B1: play as yourself,
  `StudioAsyncRaids = true`, `RaidService.onAsyncEscape({ raidId = "p13b-off-1", raiderUserId = <me>,
  defenderUserId = -1, critterUid = "<uid>", speciesId = "<species>", glowRequested = 250, isRevenge = false,
  snapshotPower = 0 })` prints `true false <species> <n> <now+14400>`. B2: `DS.peekOffline(-1)` lost the
  critter, has the shield and `revengeTokens["p13b-off-1"]`, an Incoming log entry; you hold the
  critter (Inventory) and +n Glow. B3: unset `StudioAsyncRaids` (Config `asyncRaids` false), raidId
  `p13b-off-2`: `false false <species> 0 0`, output `refused (async raids are switched off); nothing
  moved`. B4: repeat B1 exactly: Committed, same outcome, nothing moves twice.
- **#109 Part A (memory).** Extra setup: `ES = require(S.EscrowService)`, `RR`/`MM` from Shared,
  `outgoing(id)` counter (see the PR). 1: after a normal pocket raid, `me.raidLog[1]` is Outgoing
  `-1000101 true <species> <n> false`, `n == me.appliedTransfers[e.raidId].glow`,
  `me.pairRaidsToday["-1000101"] == 1`. 2: `ES.transferAsync("p13d-pair-2", me.UserId, -1000101, nil,
  100, false)` is Committed, pair count 2, then `RR.canRaid(me, snapshot with shieldUntil = 0, 0,
  os.time())` prints `false PairLimit`. 3: `d.stored = 0`, `transferAsync("p13d-empty", ..., 0, false)` is
  Committed, `me.appliedTransfers["p13d-empty"].glow == 0`, no Outgoing entry for it, pair count
  still 2, defender log unchanged. 4: pocket revenge raid (#106 step 6): Outgoing `isRevenge == true`,
  pair count 1, and **with #110 in** `me.revengeTokens["studio-revenge"] == nil` and
  `mm:Invoke("targets")` no longer lists the revenge row (without #110 the token would still be there).
  5: `mm:Invoke("seed")` again, `DS.getProfile(-1000102).stored = 1000`, `ES.transferAsync("p13d-rev",
  me.UserId, -1000102, nil, 275, true, "studio-revenge")` is Committed, token gone, a new revenge start
  is `refused: RevengeExpired`, `me.raidLog[1]` has `isRevenge == true`, glow about 275. 6: repeat
  exactly: Committed, one Outgoing entry, pair count and `me.glow` unchanged; with `"other"` as the last
  argument: `Refused (raidId already used by a different transfer)`. 7: `transferAsync("p13d-bad",
  me.UserId, -1000102, nil, 0, false, "studio-revenge")` prints `Refused only a revenge transfer carries a
  revengeRaidId` and `ES.studioRecord("p13d-bad") == nil`. 8: a live steal adds no Outgoing entry and
  leaves `pairRaidsToday` unchanged.
- **#109 Part B (DataStore, offline defender; B0 as #106 Part B).** B1: seed
  `me.revengeTokens["p13d-tok"] = { raidId = "p13d-tok", targetUserId = -1, expiresAt = os.time() + 86400,
  shieldBypassUsed = false }`, then `ES.transferAsync("p13d-off-1", me.UserId, -1, "<pad uid>", 275, true,
  "p13d-tok")` is Committed; `me.raidLog[1]` Outgoing vs -1 with `isRevenge == true`,
  `me.pairRaidsToday["-1"] == 1`, `p13d-tok` gone. B2: stop, Play again: log entry once, token still gone,
  pair count still 1 (same UTC day). B3: token `p13d-tok2`, same call as `p13d-off-2` against a
  defender with nothing to take (`stored = 0`, no Pad critter): Committed with glow 0, and the token
  is still there; clean it up afterwards.
- **#110 (one step).** As #106 Part A step 6: start the revenge raid, grab, escape. `me.raidLog[1]` is
  Outgoing `isRevenge = true`, `revengeTokens["studio-revenge"]` is spent, and starting another revenge raid
  with the same id is `refused: RevengeExpired`.

**G. Replays (#99 plan, then #107).** #99: `ReplayTestHook` `synthetic` (about 1.4 to 1.8 KB),
`fetch` as a party (900 frames) and as a non-party (nil), client `GetReplay` plus `Replay.decode`,
bad inputs nil, burst rate-limited. #107, same setup as #106 Part A with
`rh = ServerStorage.ReplayTestHook`:

1. A 3-minute raid (`raid:Invoke("start", -1000101)`, grab, drop once on a trap if there is one,
   let it time out): `raid:Invoke("replay")` shows `raid <id>: <bytes> bytes, ~900 frames, <n> events`
   with bytes under 3,000; no `[ReplayStore] replay ... not saved` warning.
2. Client `GetReplay:InvokeServer("<id>")`: `raiderUserId` is you, `defenderUserId = -1000101`,
   `#p.data` equals the bytes; `Replay.decode(p.data)` gives about 900 frames, events in order
   (Grab, Trap or Drop, Timeout).
3. `rh:Invoke("fetch", -1000101, "<id>")` returns the summary (defender is a party);
   `rh:Invoke("fetch", -1000102, "<id>")` and `rh:Invoke("fetch", -1000101, "bogus id!")` return nil.
4. Raid again (`mm:Invoke("clear")`, `seed`), reach the gate: new raidId, events end with `Escape`.
   With the #101 guard added and tagged: events end with `Tag`.
5. During a raid run `require(...Server.Raid.ReplayStore).saveNow = function() error("boom") end`, then
   escape: the raid still commits (F, #106 step 1) and only a `[ReplayStore] replay ... not saved`
   warning appears.
6. Fire `GetReplay` 4 times within 10 s from the client: the 4th returns nil.

**H. Client UI (#102 plan).** Revenge row first; raid from a row (server `endsAt` timer, gate
arrow); refusal toast; all four outcomes; async revenge ("Revenge!" line); live-revenge choice
card (`here`, `away` with "Raid their den instead", `offline`); raid log opens on rejoin with an
unseen entry; `ReportBlocked` sends cleanly. Then the #108 outcome card: a `pending = true`
escape shows "On its way!" (with the species if known and no Glow number when unknown), and a
Glow-only escape (F, #106 step 5) shows "Made it out with Glow!" plus +N Glow. A refused
StartRaid (including PresenceUnknown) still gives the one generic "Can't raid that den now" toast.
Check the Outgoing entry from #109 shows in the raid log after an escape.

**I. Live revenge in RaidService (#105 plan, `asyncRaids` is a local edit again).** Setup:
`StudioMemoryProfiles = true`; `raid` and `mm` hooks. Part A, defaults (`asyncRaids = false`), a
revenge degrades to a plain steal: `plot = raid:Invoke("seed")`, `mm:Invoke("revenge", plot)`,
`mm:Invoke("join", "here")` gives `Arrived ...; token kept true; active true`; hold F on pad 1,
`raid:Invoke("status")` shows the carry with no `revenge`; escape: `transferLive Committed` without
`as revenge`, `last escape: ... escaped true`. Part B, local `Flags.asyncRaids = true`: repeat the
setup, `mm:Invoke("live")` is `active vs -1000001 (studio-live-revenge)`. Drop path: grab pad 1
(Output `grabbed ... (revenge studio-live-revenge)`), `raid:Invoke("chase", true)`, get tagged: no new
`last escape` line, `live` still active, nothing reached escrow. Then `raid:Invoke("home")`, grab pad 1 again
and escape: `raid <guid> as revenge studio-live-revenge handed to EscrowService` then `... transferLive
Committed`, status `... escaped true`, critter in your Inventory. Unchanged rules: right after, `raid:Invoke
("grab", plot, 3)` is `false PostLossSafety`; after 60 s, `raid:Invoke("lockdown")` and standing outside,
the grab is `false LockdownActive` (revenge does not bypass it). **Known gap, expected:** after the
escape `mm:Invoke("live")` still says active, because `transferLive` does not carry the token id yet
(handoff to `data`); report it as expected, not as a bug. Finish with `raid:Invoke("clear")`,
`mm:Invoke("clear")`, revert `asyncRaids`.

## End of the pass

- [ ] Output clean (the Studio teleport warn in E and the known default-place ContentId warn are fine).
- [ ] `StudioMemoryProfiles` left true in the edit place, Config edit reverted, hooks left clean.
- [ ] Findings filed as issues (steps, expected, actual, owner). Ledger updated through the ledger branch.
- [ ] Status posted: merged, broken, blocked, next.

---

# 3. Soak runbook (P1.10)

Goal: 30 minutes of repeated async raids and forced shutdowns on a single server, ending with
zero dupes and zero errors. Run by the integration agent after the single-client pass is clean.
Multi-client parts are listed at the end; they need Kian and are on the deferred list.

## Setup

- DataStore mode, API access on, `StudioMemoryProfiles` unset. `StudioAsyncRaids = true`.
- Defenders: 3 offline real-save profiles. Start a Local Server with 3 players (UserIds -1, -2,
  -3), give each 3 or more critters on pads and some stored Glow, stop cleanly. Re-check with
  `DataService.peekOffline(-n)` in the next session.
- Raider: yourself. Keep your Inventory and pads free enough for the loot (autoPlace handles it).
- Put these helpers on the server command bar (the bar's `require` can give a separate module
  copy, so run them through a temporary Script under ServerScriptService if `peekOffline` returns nil):

```lua
local SS = game:GetService("ServerStorage")
local Services = game:GetService("ServerScriptService").Server.Services
local DataService = require(Services.DataService)
local EscrowService = require(Services.EscrowService)
local ME = game.Players:GetPlayers()[1].UserId
local DEF = { -1, -2, -3 }

-- Every uid across all profiles, with how many profiles own it.
local function owners()
	local seen, dup = {}, {}
	local function add(userId, data)
		for uid in data.critters do
			seen[uid] = (seen[uid] or 0) + 1
			if seen[uid] > 1 then dup[uid] = true end
		end
	end
	add(ME, DataService.getProfile(ME))
	for _, d in DEF do add(d, DataService.peekOffline(d)) end
	return seen, dup
end

-- Per raid: Committed, and glow equal on record, raider and defender.
local function checkRaid(raidId, defender)
	local rec = EscrowService.studioRecord(raidId)
	local mine = DataService.getProfile(ME).appliedTransfers[raidId]
	local theirs = DataService.peekOffline(defender).appliedTransfers[raidId]
	return rec and rec.state == "Committed" and mine and theirs
		and rec.glow == mine.glow and rec.glow == theirs.glow
end
```

Baseline before the first raid: `local base = owners()`; record the total uid count and every
profile's Glow (`stored` and wallet). Total uids across all profiles never changes during the
soak (no hatching, no losses to anyone else).

## Loop (repeat for 30 minutes)

Each cycle takes about 1 to 2 minutes. Use a fresh `raidId` like `soak-<n>`.

1. **Plain async raid.** `transferAsync(raidId, ME, defender, uid, 0)` for a pad critter of the
   next defender. The real pocket path (`raid:Invoke("start", ...)`) cannot
   target these defenders: SnapshotService never snapshots ids at or below 0 in DataStore mode (#106).
   Use `transferAsync`, or `RaidService.onAsyncEscape` as in #106 Part B, which is the same escrow handoff. Wait for `Committed` (seconds). Run `checkRaid`.
2. **Forced shutdown, every third cycle.** Set `StudioEscrowPause` to `deliveredDebit` (or
   `savedRaider` on alternating cycles), start a transfer, wait for the
   `Studio pause: ... waits at <checkpoint>` line, then **Stop** within 2 minutes. Play again with
   the attribute unset and wait ~15 s for recovery. Run `checkRaid` on that raidId.
3. **Rejoin check.** After any restart: Output has `[DataService] loaded <ME>` and no errors; the
   HUD shows the new critter without action from you; the recovery sweep logs no alarm.
4. **Idempotency poke, every fifth cycle.** Call `transferAsync` again with identical arguments
   (`Committed`, nothing changes) and once with different `glowRequested` (`Refused`).
5. **After each cycle** run the dupe check below. Do not continue on a failure; stop and file it.

Rotate defenders so each is raided, and each runs out of critters at different times. When a
defender has no pad critters left, `transferAsync` of a missing uid commits no critter (Glow
only); that is expected, not a dupe. Note it and move on.

## Zero dupes: the exact checks

After every cycle and once at the end:

- [ ] `local seen, dup = owners()`: `next(dup) == nil` (no uid owned by more than one profile).
- [ ] Sum of `seen` values equals the baseline total (no critter appeared or disappeared).
- [ ] Every raid run so far passes `checkRaid`: `Committed`, and `record.glow` equals both
      `appliedTransfers[raidId].glow` entries. This is "Glow conserved per raid".
- [ ] The raider's Glow rose by exactly the sum of those `glow` values, plus income and spends
      you can account for. Do not compare totals loosely; use the per-raid numbers.
- [ ] No record is left `Pending` once both sides are loaded and 60 s have passed. A Pending
      record on an absent party is parked, not failed; note it and finish it by loading that
      profile (Local Server as that player).
- [ ] Output has no line containing "duplicate", "conflicting loot", "already used for a"
      (the duplication alarm), unless step 4's deliberate `Refused` produced it.

## Zero errors

- [ ] Output window: no red errors at any time, including during the Stop/Play cycles.
- [ ] No unexpected warns. Allowed: Studio pause lines, the expected teleport warn, the default
      place ContentId warn.
- [ ] Server output after the final rejoin shows the recovery sweep ran and nothing was left parked.
- [ ] Optional: leave Play running idle for the last 5 minutes. The 60 s sweep should stay quiet.

## Pass and failure

**Pass:** 30 minutes, at least 15 cycles including at least 5 forced shutdowns (some at each
checkpoint), every check above ticked, Output clean. Post the cycle count and the raid ids.

**Fail:** a dupe, a lost critter (a uid in no profile), a Glow mismatch or any error. Capture the
raidId, `studioRecord(raidId)`, both `appliedTransfers` entries, and the last 50 Output lines.
File to `data` (escrow or profile) or `raid` (raid path). Do not retry past a dupe.

## Needs Kian (deferred list, not attempted by the integration agent)

- 4 clients through every raid path: live steal, lockdown, async raid, revenge async, with
  the raid log and Raid Portal on each client, the pocket den part budget with 8 players,
  and a block between two of them.
- Two live servers: live revenge `Teleporting` to `Arrived` (steps 1 to 7 of #94), the
  `EscrowDebit` message path with the defender online in another server, and a rolling
  deploy with old and new servers mixed (do not enable `asyncRaids` first, D-049).
- Phone checks: Raid Portal, in-raid HUD, raid log and outcome card at 667x375 and 844x390.

---

# 4. Phase 1 gate kit

Copy "Message to testers" below into the invite. Everything after it is for Kian.

## Message to testers

> **Raid Night: raid-while-offline test.** This is an early build. Art is plain shapes on
> purpose. We want to know one thing: **does getting raided while you are away make you want to
> come back and hit back?**

### Setup

- **Where:** Roblox on a phone or PC. Kian: fill in the join link and access method (private
  or friends-only; testers must be invited or friended first).
- **Who and when:** 2 to 4 friends over 2 to 3 days. Play when it suits you, one or two short
  sessions a day. Log off normally. Your den earns and can be raided while you are gone.
- **Heads up:** it is a prototype. Progress may be wiped afterward. Egg odds are on screen.

### What to do

No script. Try these:

1. Set up your den, hatch your starter egg and put critters on pads.
2. Raid a friend's den while they are offline (open Raid, pick a target, grab a critter, get
   to the gate before the 3 minutes end).
3. Log off and come back later. Read the raid log: who hit you, what they took.
4. If someone raided you, hit back. Use Revenge from the log or the Raid Portal.
5. Try the replay of a raid on you, if it is available.

## For Kian: running it

**Before**

- [ ] Part 1 done: merged, published, D-049 flag order followed, `asyncRaids = true` live.
- [ ] Soak passed (part 3) on the same build; commit sha written in the results below.
- [ ] Fresh save wanted? Delete the test profiles (`PlayerProfiles`) in the test universe's
      Data Stores manager. Otherwise old progress carries over.
- [ ] Each tester joined once and saw their den and the Raid button. Nobody stuck on onboarding.
- [ ] Known limits to remember when a tester says "it won't let me": raid pair limit, daily loss
      cap, shield after being raided, the raid refusals show a short toast only, and only
      offline dens are async targets (D-043).

**What we watch** (you take notes, do not coach)

- Session length, and whether people return on day 2 and 3 without being asked.
- After being raided: do they open the log? How long until they raid back, or do they ignore it?
- Where they get stuck: Raid Portal, pocket den (gate, traps, guards), carry, revenge button.
- Any sense of cheating: "I did nothing and lost it", surprise at the size of a loss, a raid
  that felt impossible to defend.
- Any lost or duplicated critter, and any Glow that does not add up. File immediately to `data`.
- Errors in the server Output (check after each day), and a spot check of the escrow records
  for any `Pending` older than a few minutes.

**Questions after** (5, ask each person alone)

1. What was the most fun moment?
2. When did you want to stop?
3. Did losing a critter while offline feel fair?
4. Did you go back for revenge? Why or why not?
5. What confused you?

**Pass criteria** (from the Phase 1 gate)

Play async raids and revenge with 2 to 4 friends over 2 to 3 days, so offline raids actually
happen. **Pass** if being raided makes people want to come back and hit back, and nobody feels
cheated. **Fail**: name what felt bad (usually loss rules); the orchestrator turns it into
tuning or fix tasks. Do not start Phase 2 on a fail.

Also required by the Phase 1 exit checks: all tests green, EscrowSimulation green on
`integration`, soak clean, no open `Blocked` items.

**After**

- [ ] Fill in the results template.
- [ ] Record the outcome in `docs/progress.md` under Gate history ("Phase 1 gate: passed/failed YYYY-MM-DD (notes)").
- [ ] On a fail, tell the orchestrator what felt bad so it can create tuning or fix tasks.

## Results template

```
Date:
Build (integration commit):
Players / devices:
Days played:
Overall: PASS / FAIL (rule: raids made people want to return and hit back; nobody felt cheated)
Raids made / raids suffered (total):
Revenge raids made:
Main stuck points:
Bugs to file (steps, expected, actual, owner):
Dupes or lost critters seen (should be none):
```

Per player: device; sessions and minutes; came back day 2/3 unprompted; raids suffered offline;
went back for revenge (and why); answers to Q1 to Q5; notable quotes.
