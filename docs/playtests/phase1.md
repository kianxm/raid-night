# Raid Night: Phase 1 playtest kit and soak runbook

Phase 1 is "offline raids and revenge that work, safely". This file has four parts:

1. Before playing (merge order, publish, flags)
2. Single-client Studio pass (integration agent)
3. Soak runbook, P1.10 (integration agent; multi-client parts need Kian)
4. Friends playtest kit, the Phase 1 gate (tester-facing, then notes for Kian)

Written before P1.3b, P1.4b and P1.9b were open. Steps that need them are marked
**[needs P1.3b]**, **[needs P1.4b]** or **[needs P1.9b]**. Check the PR list and re-read each
PR's own "Studio playtest plan" before running; if a plan and this file disagree, the PR wins
and this file gets a fix.

---

# 1. Before playing

## Merge order (Kian; merges are refused for agents, D-044)

Stacked PRs merge bottom first. After each base merges, GitHub retargets the next PR to
`integration` (or retarget by hand).

| Order | PR | Notes |
| --- | --- | --- |
| 1 | #97 P1.1a, then #98 P1.1b | Escrow rules, then transport. Highest risk. |
| 2 | #94 P1.9 | Live revenge lookup and join. Independent of the stack. |
| 3 | #92 P1.5b | Raid Portal blank fix (also contained in #102). |
| 4 | #100 P1.3a (1/2), then #101 (2/2), then #103 P1.3c | Contracts, then pocket dens, then `markRaidLogSeen`. |
| 5 | #99 P1.4a | Replay codec and store. |
| 6 | #102 P1.6 | UI wiring; stacked on #100, contains #92 and #94. |
| 7 | P1.3b, P1.4b, P1.9b | Open when ready: escrow handoff, replay hook, live revenge in RaidService. |
| 8 | #95 P1.7, #96 P1.8 | Economy tuning. Kian's decision (D-045); not needed for the soak. |

Skip a PR you do not trust yet, but note that P1.3b needs #98 and #101.

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
the whole pass: API access on. Steps A to C use DataStore mode (memory switch off); steps D to
H use memory mode. The switch is read once at server start, so stop Play between the groups.

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

**F. Async raid (#101 plan, steps 1 to 12).** Kill switch, start, grab and carry, escape, `gate`
exploit (TooFast, Retreat), retreat, 3-minute timeout, guards and traps, refusals (AlreadyRaiding,
Blocked both ways, RevengeExpired, valid revenge), client trust checks, reset mid-raid, live
stealing regression, pocket part count (24 for 6 pads, 4 traps, 2 guards).
**[needs P1.3b]** Escape now moves the critter and Glow: gone from the den, in your profile once,
Glow equals the debit, shield and revenge token on the defender, a log entry each side.

**G. Replays (#99 plan).** `ReplayTestHook` `synthetic` (about 1.4 to 1.8 KB), `fetch` as a party
(900 frames) and as a non-party (nil), client `GetReplay` plus `Replay.decode`, bad inputs nil,
burst rate-limited. **[needs P1.4b]** A real raid leaves a replay, saved at raid end.

**H. Client UI (#102 plan).** Revenge row first; raid from a row (server `endsAt` timer, gate
arrow); refusal toast; all four outcomes; async revenge ("Revenge!" line); live-revenge choice
card (`here`, `away` with "Raid their den instead", `offline`); raid log opens on rejoin with an
unseen entry; `ReportBlocked` sends cleanly. **[needs P1.9b]** a live revenge grab spends the
token only when the raid starts.

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
   next defender. **[needs P1.3b]** Prefer the real path instead: `raid:Invoke("start", defender)`,
   grab, escape. Wait for `Committed` (seconds). Run `checkRaid`.
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
