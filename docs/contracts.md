# Contracts

The shared shapes every agent builds against. Source files are the truth; this page explains
the why. Update it in the same commit as any contract change.

## Files

| File | Contract |
| --- | --- |
| `src/Shared/Types.luau` | Every persisted and shared type |
| `src/Shared/Net.luau` | Remote names, payloads, rate limits |
| `src/Shared/Config.luau` | Every tuning knob |
| `src/Shared/Data/Critters.luau` | Species ids and stats (ids are permanent) |

## Persisted data

| Key | Type | Written by | Notes |
| --- | --- | --- | --- |
| Profile per user | `PlayerProfile` | DataService only (session-locked) | Others send messages |
| Snapshot per user | `DenSnapshot` | SnapshotService | Never includes vault critters |
| Escrow per raidId | `EscrowRecord` | EscrowService | Write-once create, then state moves forward only |
| Open escrows per user | `EscrowOpenIndex` | EscrowService | Both raider and defender; added before the record, removed once terminal |

Profile storage: ProfileStore store `PlayerProfiles`, key `Player_<userId>` (`DataService.luau`).

Studio-only memory and test profiles (decision D-019, details in `DataService.luau`):

- **Memory switch.** Setting the boolean attribute `StudioMemoryProfiles` on `ServerStorage` to
  `true` before pressing Play runs every profile from ProfileStore's mock store, in memory, even
  with Studio API access on. `DataService.persistence()` is then `"Memory"`, so escrow records
  stay in memory too, and nothing is saved. It is read once at start and only when
  `RunService:IsStudio()`; missing or `false` means normal saving. It is a developer setting on
  a server-only service, not a replicated attribute: clients can neither see nor set it.
- **Test profiles.** `DataService.loadTestProfile(userId, profile)` holds a fake in-memory
  profile for RaidService's single-client test hook. It works only in Studio with memory
  persistence, and only for reserved ids (`Profile.isTestUserId`: whole numbers <=
  -1,000,000, clear of real accounts and of Studio Local Server players -1, -2, ...). It is
  never saved, and `saveNow` on it confirms at once. `releaseTestProfile(userId)` works like a
  leave (`onProfileReleasing` runs), and it refuses while an escrow for that id is still open,
  or when EscrowService has not registered its release guard (fail closed).

**Never change the store name or the key format.** ProfileStore would find no save under the
new name and hand every player a fresh template. Everyone silently starts over: the old saves
still exist, but nothing reads them. The same applies to `EscrowRecords` and its keys below,
where a rename would strand every transfer in flight.

Escrow storage: DataStore `EscrowRecords`.

- `Escrow_<raidId>`: the `EscrowRecord`. raidId is at most `Config.Escrow.maxRaidIdLength` (43)
  characters, so the key fits DataStore's 50. Forward-only is enforced by `Escrow.canReplace`
  inside every `UpdateAsync`.
- `Open_<userId>`: that player's `EscrowOpenIndex` (`{ [raidId]: { role, createdAt } }`), for the
  raider and the defender alike. An entry with no record is removed only once it is older than
  15 minutes (its create may still be in progress). Re-adding a listed raid (a retry) moves its
  `createdAt` forward, never back (`Escrow.indexAdd`), so the retry is protected too.
- When `DataService.persistence() == "Memory"` (Studio without API access, or the Studio memory
  switch above) both live in server memory, like profiles do. Profiles and escrow always share
  one mode: a saved profile never holds an escrow entry that only memory knew.
  `persistence()` is `nil` until `DataService.start()` has read the memory switch (and while
  ProfileStore is still checking access). EscrowService takes its mode once, from the first
  non-nil answer, and reads or writes nothing before that, so the shared mode holds whatever
  order services start in.

## Money model

- `stored`: Glow in the den. Accrues lazily. Stealable (25% per raid, capped by what is there).
- `glow`: banked Glow. Never stealable. Loot lands here (safe once home).
- Always `Economy.accrue` before changing placements or den level.
- **Earned.** One critter earns its species base × mutation × placement × rebirth Glow per
  second (`Economy.critterRate`). Placement is 1 on a Pad, `Config.Income.vaultMultiplier` in
  the Vault, and 0 as a Guard or in Inventory. A den earns the sum (`Economy.denRate`).
  Robux-linked boosts (D-030, D-032) multiply what is earned:
  earned = base × mutation × placement × rebirth × factor. The factor is
  `Economy.glowBoostFactor(...)` (see Robux-linked Glow multipliers), and it applies only
  through `Economy.accrue(profile, now, factor?)` and `Economy.collect(profile, now, factor?)`.
- **The factor is clamped.** It defaults to 1. A factor outside
  `[1, Economy.maxGlowBoostFactor()]` (1 + `vipGlowBonus` + `lanternNightGlowBonus`, so 2.0 at
  launch) counts as 1: nil, 0, negatives, NaN, inf, 1e300. So a bad value can never remove
  Glow, stop earning, or pay more than every boost together.
- **Cap rule.** The storage cap never uses the factor. It is the unboosted
  `denRate(profile) × storageCapSeconds(denLevel)` (`Economy.storageCap`). A boost fills
  storage faster, never deeper, so a boost ending never leaves stored Glow above the cap and
  nothing is clawed back. Accrue never removes Glow already stored, even if the cap shrank.
- **Timing rule.** Treat the factor like the rate: always call
  `Economy.accrue(profile, now, oldFactor)` before the factor changes. That covers Lantern
  Night starting or ending, VIP ownership becoming known (or bought mid-session), the
  PolicyService result arriving, and the player joining or leaving a server with an active
  Lantern Night. Accrual pays one factor for the whole elapsed period, so a late accrue at the
  new factor would boost (or un-boost) time already earned. Economy functions that accrue
  internally (`place`, `autoPlace`, `upgradeDen`, `buyEgg`, and `collect` without a factor)
  use factor 1. A server running a boost therefore accrues with the factor first, and their
  internal accrue is then a no-op because no time has passed.
- **A NaN `now` changes nothing.** `accrue` returns 0 and leaves `stored` and
  `storedUpdatedAt` as they were.
- `Net.DenState.ratePerSecond` and `storageCap` are unboosted (`denRate`, `storageCap`).
  Showing a boosted rate would be a contract change.
- **P2.8 gate.** `EscrowService` and `Matchmaking` still accrue at factor 1. Both must pass
  the player's factor, or accrue after a call that did, before `Config.Flags.purchases` turns
  on. This is a hard gate for P2.8, not an optional TODO.

## Escrow

```
Pending ──debitDefender + markDebited──▶ Debited ──creditRaider + markCommitted──▶ Committed
   └──void (before any debit)──▶ Voided
```

Each arrow is two single-key writes; every step is idempotent by `raidId`
(`appliedTransfers` on each profile). Invariants, enforced by
`tests/specs/EscrowSimulation.spec.luau`:

1. A critter uid exists in exactly one place: one profile, or in flight for one raid.
2. Glow is conserved.
3. Repeating any step changes nothing after the first success.
4. Daily loss limits hold at the debit, by the record's `kind` (decision D-031):
   - Live: a live debit takes a critter that is still on its pad exactly when the den is not
     protected at that debit (`RaidRules.liveProtectedAtDebit`, read with the critter still in
     the den). The line is `protectionLossShare` of the largest of the day's base, the den's
     Glow/s just before the debit (D-036) and the record's `liveBaseRate` when it is a finite
     number >= 0 (D-037). The debit that crosses the line lands, so the losses before any live
     steal were always under the line measured at that steal. Refilling the den moves the line
     up and reopens it, and shrinking it during a carry cannot make that carry's debit refuse.
     The day's first live loss sets the base from the record's `liveBaseRate` when it has one
     (D-034, below).
   - Async: no async debit takes a critter once the defender has lost
     `Config.Limits.maxLossesPerDay` critters that UTC day (live losses count toward it too).
5. An empty live commit grants nothing (decision D-033). A Live debit that takes no critter
   (the den is protected, or the critter is gone) and no Glow still writes its
   `appliedTransfers` entry, so it stays idempotent. It skips `RaidRules.recordIncoming`
   entirely: no shield, no revenge token, no `pairRaidsToday` increment (the raider's pair slot
   is not used up) and no "escaped" incoming raid-log entry. A Live debit that takes only Glow,
   and every Async debit, empty or not, still records all four.

`EscrowRecord.kind` (`"Live"` or `"Async"`) is set when the record is created and never changes
(`Escrow.canReplace`). Missing means `"Live"`: every record written before the field existed
is a Phase 0 live steal, so it needed no migration. `EscrowService.transferLive` creates
`"Live"` records.

`EscrowRecord.liveBaseRate: number?` (decision D-034) is the defender den's Glow/s
(`Economy.denRate`) when the raider's grab was accepted, before the owner could be alerted.
It is the base for the defender's first live loss of the day, and at its own debit it is a
floor of the protection line (D-037; Live loss rules, below).

- **Set once.** `Escrow.create` takes it as an optional last argument, for Live records only.
  It must be nil or a finite number >= 0: NaN, inf, negatives and non-numbers fail
  `Escrow.checkLiveBaseRate`, which `Escrow.create` asserts. `EscrowService.transferLive`
  checks it first and returns `Refused` before any write, so a bad value never crashes a
  transfer half-way.
- **Rounded at create.** The stored value is rounded to the nearest 0.001 Glow/s. A short
  decimal survives the DataStore's JSON round trip exactly, so a retry's fresh record still
  equals the stored one, even if a future tuning value makes den rates long decimals.
- **Never changes.** It is part of the transfer's identity: `Escrow.sameTransfer` compares it
  exactly, and a missing value matches only a missing one. So `Escrow.canReplace` never lets a
  write fill it in, change it or drop it, and a retry with another value is refused.
- **Missing means no grab-time measurement:** records written before the field existed, and
  Async records. The debit then measures the den itself, as it did before D-034. No migration.

Only the call that creates a record, and its same-server retries while the server awaits them
(kept `createNonce`), debits the defender (`Escrow.advance`). That call sets
`EscrowRecord.createNonce` (a GUID; optional, missing on older records, no migration) so that a
create which landed but whose response was lost is still recognised as its own on retry
(`Escrow.decideCreate`) and driven forward instead of voided. The nonce never changes once
written (`Escrow.canReplace`). Every later path is `Escrow.recover`, which never debits afresh.
It runs on either party's load, with the parties loaded in that server:

- `Pending`, defender loaded: their saved debit moves the record to `Debited`. No debit: first a
  confirmed save by the session that still holds the defender's lock, without an entry for the
  raid (`Store.saveProfileWithoutEntry`), then `Voided` (nothing moved). A server whose lock was
  taken by another server cannot produce that save, so it never voids.
- `Debited`, raider loaded: credit, then `Committed`.

Retrying `EscrowService.transferLive` (P0.5): call again with IDENTICAL arguments (raidId,
raider, defender, critterUid, glowRequested, isRevenge, liveBaseRate). Once a record is stored,
the same raidId with any other argument returns `Refused` ("raidId already used by a different
transfer"). While
the server still waits on a retry of the raid (an earlier call returned `InFlight`), the retry
reuses that call's `createNonce`. So a create that landed but lost its response is still the
call's own, and the steal continues (`Escrow.advance`) instead of being voided.

Phase 1 (P1.1, decision D-012): the void rule assumes only the creating call debits. A debit
delivered by ProfileStore message, or applied to an offline profile, could land after a void and
strand the loot. This must be solved before any async transport ships. Recovery can now tell
live from async by `EscrowRecord.kind` (D-031).

`appliedTransfers` entries are pruned after `Config.Escrow.appliedTransferRetentionSeconds`, but
only by EscrowService after reading the player's `Open_` index, and never for a raidId still
listed there. `Profile.prepare` does not prune them.

If you change `Escrow.luau`, `RaidRules.recordIncoming`, `RaidRules.recordLiveLoss`,
`RaidRules.liveProtected`, `RaidRules.liveProtectedAtDebit` or anything in `appliedTransfers`,
the simulation must still pass, and the `reviewer` agent must sign off.

## Kill switches

`Config.Flags` holds one boolean per feature. `false` turns the feature off everywhere. Services
read `Config.Flags.<name>` directly and check it before acting on a request. Raid and transfer
starts go through the pure `Escrow.canStartTransfer(Config.Flags, kind, isRevenge)`.
EscrowService and RaidService must call it before starting any raid or transfer.

| Flag | Gates | Default |
| --- | --- | --- |
| `raids` | Master switch: starting any raid or escrow transfer of any kind (live, async, revenge) | `true` |
| `asyncRaids` | Additionally gates async raids and revenge raids (new `Async` transfers, and any transfer with `isRevenge`); needs `raids` on too | `false` |
| `purchases` | Robux products (PurchaseService), and Robux-linked Glow multipliers (`Economy.glowBoostFactor`'s `purchasesEnabled`, D-032) | `false` |
| `trading` | Trading (post-launch) | `false` |
| `notifications` | Experience notifications (NotificationService) | `false` |

Unknown transfer kinds are always refused. Switches block STARTING new raids and transfers only.
Escrow recovery and transfers already in flight are never gated: records in `Pending` or
`Debited` always advance to completion, so turning a flag off cannot strand loot in flight.
Raid semantics approved by Kian 2026-10-28 (decision D-002).

Defaults turn on only the features that exist. Adding a flag is a contract change.

## Schema changes

1. Add the field with a default in `Profile.new`.
2. Add `migrations[n]` in `Profile.luau` and bump `Config.SCHEMA_VERSION`.
3. Add a test that migrates an old-shape profile.
4. Never remove or rename a persisted field without a migration.

An optional field whose absence means the old behavior needs neither a migration nor a
`SCHEMA_VERSION` bump, but it does need an old-save test (e.g. `untradeable`, D-005).

## Live raids

Live stealing happens in an online owner's den (RaidService, decision D-003).

- Carrying or dropping a critter never changes any profile; only an escape committed through
  Escrow (`EscrowService.transferLive`) moves ownership. A dropped critter goes back to its pad.
- Phase 0 live steals take the critter only, no stored Glow (D-015).
- `Net.Limits.GrabCritter` (5 per 10 s) also limits live grab starts from the steal prompt.
- `Net.Pushes.BeingRaidedLive` (raiderUserId) goes to the den owner when a raider grabs.
- `Net.Pushes.RaidEnded` goes to the raider whenever a live carry ends (decision D-020). In the
  `RaidEnd` payload, `escaped` is true only when `transferLive` returned `Committed`. `raidId` is
  the escrow raidId, or `""` for a drop before escape. `speciesId` is set, and `glow` is 0.

Tuning lives in `Config.LiveRaid`:

| Key | Launch value | Meaning |
| --- | --- | --- |
| `lockdownSeconds` | 45 | How long a Lockdown lasts |
| `lockdownCooldownSeconds` | 120 | Wait after a Lockdown ENDS before the owner can start another |
| `tagRange` | 6 | Studs: how close the owner must be to tag a raider |
| `grabHoldSeconds` | 1 | How long a raider holds the grab to pick a critter up |
| `grabRange` | 10 | Studs from the raider's root part to the pad centre: how close a raider must be to start a grab and to keep holding it (D-018) |
| `postLossSafetySeconds` | 60 | After a live loss, nobody can grab from that den this long (D-031) |
| `maxStealsPerPairPerDay` | 2 | Live steals between the same two players per UTC day (D-031) |
| `protectionLossShare` | 0.5 | Share of the den's Glow/s that, while today's live losses reach it, protects the den from live steals. Measured against the larger of the day's base and the den's Glow/s now; at the escrow debit, also the record's grab-time rate (D-031, D-036, D-037) |

The last three are Kian's launch values, tuned in Phase 3 from live data (P3.9).

`Net.Requests.Lockdown` is `() -> boolean` (true if a Lockdown started), limited by
`Net.Limits.Lockdown` (3 per 10 s). Lockdown rules:

- Only the den's owner can start one, and it applies to live raids only.
- It blocks ENTRY only. Raiders already inside can leave, but a carried critter drops at the
  border.
- Lockdown blocks every live raider, revenge included (D-013).
- The cooldown counts from the END of a Lockdown (decision D-011). For a Lockdown started at
  server time `start`: `LockdownUntil = start + lockdownSeconds` (when it ends) and
  `LockdownReadyAt = LockdownUntil + lockdownCooldownSeconds` (the earliest the owner can start
  the next one). A den is locked at most 45 s in every 165 s.
- Duration and cooldown are enforced server-side from the server's own state. The client only
  asks; `LockdownUntil` and `LockdownReadyAt` below are for display.

## Live loss rules

Decision D-031 (Kian), scheduled as P0.5g (data), P0.5h (raid), P0.5i (ui). These rules apply
to live steals only, and they replace the daily count cap for them. Async raids keep
`Config.Limits.maxLossesPerDay` until Phase 1. `lossesToday` still counts every loss, live and
async, for the raid log and the async cap. Values live in `Config.LiveRaid` (table above).

1. **Post-loss safety.** After a live loss, nobody can grab from that den for
   `postLossSafetySeconds` (60 s). The timer is server memory in RaidService and is never
   persisted: live steals happen within one server. A grab is also refused while any carry from
   that den is under way (carried, or in escrow and not settled), so a crowd grabbing together
   cannot beat the timer or the protection check.
2. **Same-pair limit.** A raider can make at most `maxStealsPerPairPerDay` (2) live steals per
   UTC day from the same owner, counting the owner's shared `pairRaidsToday` entry for that
   raider and any of their steals still in flight.
3. **Value-based daily protection.** Live losses are measured in Glow per second. A loss is the
   stolen critter's `Economy.critterRate` at the debit, counting its mutation, the defender's
   rebirths, and where it sat before the steal. The base is `Economy.denRate(defender)` for
   the day's first live loss, measured when that steal's grab was accepted, before the owner
   could be alerted (decision D-034, Kian). It travels in the record's `liveBaseRate`. So an
   owner who moves high earners to Inventory or the Vault during the carry cannot shrink the
   base and buy protection with one cheap loss. A record without
   `liveBaseRate` falls back to `denRate` just before the debit, with the stolen critter
   still in the den. The base never changes during the day, whatever later records carry or
   the den does.

   The den is protected from live steals while today's live losses reach
   `protectionLossShare` (50%) of the larger of the base and the den's Glow/s right now
   (`Economy.denRate`, decision D-036, Kian):

   `liveLossRateToday >= protectionLossShare × max(liveLossBaseRate, Economy.denRate(den now))`

   - **The base is a floor.** Shrinking the den (moving critters to Inventory, Guard or the
     Vault) never lowers the line below the base, so it cannot buy protection after a small
     loss.
   - **Refilling lifts protection.** The line rises with the den's rate. A planned shrink buys
     nothing: an owner who empties the den but one Common before the grab gets an honest but
     tiny base. After they lose that Common (to an alt, or a dropped carry they let land),
     they are protected only while the den stays that small. Putting the earners back lifts
     protection, and so can any other refill, such as an egg that `Economy.autoPlace` puts on
     a free pad (D-027). After a real loss, a refill lifts it once the den earns more than
     `1 / protectionLossShare` (twice) what it lost today.
   - **A real loss still protects.** The den's rate drops with the stolen critter, so losing
     the den's best critter protects it at once. Stealing a few Commons from a rich den never
     does.
   - **The rate is the den's whole `denRate`:** pad critters, plus Vault critters at
     `Config.Income.vaultMultiplier`. Inventory and Guard critters earn nothing and count for
     nothing. It is the unboosted rate (D-032), so a boost starting or ending never changes
     protection.
   - **It can switch off and on during the day,** as the den is refilled or shrunk. The steal
     that crosses the line lands, and nothing after it does while the line holds. Only the UTC
     day roll clears it for good (both fields reset).
   - **A shrink during the carry cannot refuse the steal** (decision D-037). At the escrow
     debit the line also counts the record's grab-time rate (`liveBaseRate`, measured when
     the grab was accepted, before the owner could be alerted):
     `liveLossRateToday >= protectionLossShare × max(liveLossBaseRate, Economy.denRate(den now), record.liveBaseRate)`.
     The grab was accepted only while the den was open against the den as it was then. So an
     owner who refilled, was alerted by the grab and moved earners off during the carry cannot
     make the debit take nothing. The grab-time rate only raises the line. A record without a
     valid one is checked against the den as it is at the debit.
     `canGrabLive` and the den attribute are unchanged: at a grab, the den's rate now is the
     grab-time rate.
4. **Escrow.** Live steals keep moving critters through `Escrow.luau`, on the two profiles
   loaded in one server, via `EscrowService.transferLive`. They switch to the cross-server
   path when P1.1 adds it. The rules are checked when the grab starts and again at the debit,
   where a `"Live"` record takes no critter from a den protected at the debit (D-037 line). A live debit that takes
   nothing at all grants the defender nothing (Escrow invariant 5, D-033).

The state is stored on the profile as two optional `PlayerProfile` fields:

| Field | Meaning |
| --- | --- |
| `liveLossBaseRate: number?` | The den's Glow/s for its first live loss today: at that steal's grab (the record's `liveBaseRate`), or just before its debit when the record has none. It is the protection line's floor (D-036) |
| `liveLossRateToday: number?` | The summed Glow/s of the critters lost to live steals today |

Both belong to `lossDay` and are set back to nil when the day rolls
(`RaidRules.resetDailyIfNeeded`, which runs on load and before every debit). Missing means
there has been no live loss today, so there is no migration and no `SCHEMA_VERSION` bump.
`Profile.spec` checks that an old save loads unprotected.

The pure rules live in `RaidRules`, and the server always decides:

- `liveProtected(profile, now)` is read-only. It is true when the profile's `lossDay` is today and
  `liveLossRateToday >= protectionLossShare * max(liveLossBaseRate, Economy.denRate(profile))`
  (D-036). It reads the profile as it is at the call, so every caller sees a refill or a shrink
  at once: `canGrabLive` (every hold frame) and RaidService's `LiveProtected` attribute and steal
  prompts (every 0.5 s). A NaN in either field, or in the den's rate, counts as protected. A
  missing field (no live loss today, or a save from before D-031) means not protected, however
  small the den.
- `liveProtectedAtDebit(profile, now, grabRate?)` is the same check with `grabRate` (the record's
  `liveBaseRate`) also in the `max` (D-037). Only `Escrow.debitDefender` calls it, with the
  targeted critter still in the den. A `grabRate` that is nil, or anything but a finite number
  >= 0, counts as none (`Escrow.create` refuses those anyway), and the answer is then
  `liveProtected`'s. The NaN and missing-field rules for the profile fields are unchanged.
- `recordLiveLoss(defender, critter, now, grabBaseRate?)` is called by `Escrow.debitDefender` for
  a Live debit that takes a critter, before the critter leaves the profile, with the record's
  `liveBaseRate`. On the day's first loss it sets the base to `grabBaseRate`. When that is nil,
  or anything but a finite number >= 0, it measures `denRate` instead. Then it adds the
  critter's rate. Later losses that day never change the base. It errors if the critter is
  already gone.
- `liveGrabReadyAt(lastLiveLossAt)` returns `lastLiveLossAt + postLossSafetySeconds`, on
  whatever clock the input uses.
- `canGrabLive` no longer checks `maxLossesPerDay`. After `CritterBusy` it refuses with
  `LiveProtected`, then `PairLimit`, then `PostLossSafety`: when `inFlightForOwner > 0`, or
  when `now < liveGrabReadyAt(lastLiveLossAt)`, which also refuses a NaN. `lastLiveLossAt` is a
  new optional `LiveGrab` input on the same clock as `now`; nil means no loss this server
  session.

RaidService (P0.5h) measures the grab-time base: `Economy.denRate(ownerProfile)` when it
accepts the grab request, before the hold starts and before `BeingRaidedLive` reaches the owner.
It keeps that value with the carry and passes it as `transferLive`'s last argument on every
attempt (D-034). So every new live record carries a grab-time base. Records without one are
older records or async ones, and their debit falls back to `denRate` at the debit.

RaidService (P0.5h) shows the state with the den attributes `LiveProtected` and
`LiveGrabReadyAt` (see Replicated attributes). They are for display only: the server decides
from the profile and its own timer.

## Replicated attributes

Attributes the server sets on Instances so clients can draw state without a remote. All are
server-written and display-only:

- The server keeps the authoritative state in its own tables. It never reads `CarryingUid`,
  `CarryingSpecies`, `LockdownUntil`, `LockdownReadyAt`, `LiveProtected` or `LiveGrabReadyAt`,
  and no gameplay or data decision ever comes from an attribute.
- Clients must never be trusted for them. A client can change an attribute locally; the change
  does not replicate and must never matter.
- Times are server time from `workspace:GetServerTimeNow()`, so every client reads one clock.

| Instance | Attribute | Type | Meaning |
| --- | --- | --- | --- |
| Player | `Plot` | number | Plot index of the player's den; absent when they have none |
| Player | `CarryingUid` | string | uid of the critter being carried; `""` (or absent) when not carrying |
| Player | `CarryingSpecies` | string | Species id of that critter; `""` (or absent) when not carrying |
| Den Model `Den<plot>` | `Plot` | number | The den's plot index |
| Den Model | `OwnerUserId` | number | Owner's userId; 0 when unowned |
| Den Model | `LockdownUntil` | number | When the current Lockdown ends; absent or past = none active |
| Den Model | `LockdownReadyAt` | number | When the owner can start the next Lockdown; absent or past = ready |
| Den Model | `LiveProtected` | boolean | `RaidRules.liveProtected` for the owner right now: no live steals while it is true (D-031). It can turn false and true again during the day as the owner refills or shrinks the den (D-036), and is false from the UTC day roll; absent = false |
| Den Model | `LiveGrabReadyAt` | number | When grabs reopen after the den's last live loss (`RaidRules.liveGrabReadyAt`, D-031); absent or past = open |
| Pad Part | `PadIndex` | number | The pad's number |
| Critter Model | `CritterUid`, `SpeciesId`, `Tier` | string | Which critter this model draws |
| Critter Model | `PadIndex`, `OwnerUserId` | number | Where it sits and whose it is |

## Eggs

`Config.Economy.eggMaxTier` (`"Uncommon"` at launch) is the highest tier a bought egg can hatch.
Tiers up to it keep their `Config.EggOdds` ratios, renormalized to sum to 1
(`Economy.rollTierUpTo`): Common 0.6875 and Uncommon 0.3125 today, tested in `Config.spec`.
Phase 2 raises it to `"Mythic"`. The rescue egg rolls from its own Common-only table (from
P0.4b) and ignores `eggMaxTier` (decision D-004).

Glow is earn-only at launch (D-028, amended by D-030): no product ever grants Glow directly.
Robux-bought Glow multipliers (VIP, and the "Lantern Night" server boost from D-029) only
multiply Glow earned in play, and they follow the Robux-linked rule in the next section: they
never apply to a player whose PolicyService info restricts paid random items. Glow buys eggs, so
Glow packs would make every egg a paid random item; they ship only in the Phase 2
paid-randomness mini-phase with on-screen odds, PolicyService region checks and a reviewer
audit. Egg odds are shown on screen for every egg from Phase 0, from Economy's odds helpers
(Config.EggOdds after the eggMaxTier renormalization; rescue egg: Common 100%).

## Robux-linked Glow multipliers

Decision D-030. Lantern Night is a Glow multiplier. All Robux-bought Glow multipliers (VIP 1.5×,
Lantern Night) are Robux-linked. For a player whose PolicyService info restricts paid random
items, they never apply: VIP keeps its non-Glow perks; other players' Lantern Nights don't boost
them; so their Glow stays earn-only and eggs stay purchasable for them. Egg odds are shown
everywhere. Both products are gated on the reviewer policy audit and the PolicyService check in
P2.8. Bonuses stack additively (Config.Boosts). The policy check must fail closed: if
PolicyService can't be read for a player, treat them as restricted (no Robux-linked
multiplier). The multiplier is computed by Economy (pure, tested) and applied through
Economy.accrue's factor (economy's P0.12).

The restriction is `ArePaidRandomItemsRestricted` in the player's PolicyService info.

`Economy.glowBoostFactor({ vip, lanternNight, paidRandomRestricted?, purchasesEnabled })`
(type `Economy.GlowBoostInputs`) turns a player's boosts into one factor. The fields are named,
not positional, so the two policy booleans cannot be swapped. It returns 1 (no boost) when:

- `paidRandomRestricted` is not `false`. `true` or nil both count: nil means PolicyService
  has not answered or could not be read, and that fails closed.
- `purchasesEnabled` is not `true`. Callers pass `Config.Flags.purchases`, the kill switch.
- `vip` or `lanternNight` is missing or not a boolean, or the inputs are not a table.

Otherwise it returns 1 + `vipGlowBonus` (if `vip`) + `lanternNightGlowBonus` (if
`lanternNight`), added together. Every input comes only from the server: the restriction from
PolicyService, VIP ownership from MarketplaceService, and Lantern Night from the server's own
timer. None ever comes from a client request.

Values live in `Config.Boosts`:

| Key | Launch value | Meaning |
| --- | --- | --- |
| `vipGlowBonus` | 0.5 | VIP pass: +50% Glow (1.5× on its own) |
| `lanternNightGlowBonus` | 0.5 | Lantern Night: +50% Glow for everyone in the server who isn't restricted |
| `lanternNightSeconds` | 900 | How long one Lantern Night lasts (15 min) |

Additive means VIP plus Lantern Night is 1 + 0.5 + 0.5 = 2.0×, not 1.5 × 1.5. Adding or removing
a key is a contract change; `Config.spec` checks the keys and that every value is non-negative.

## Tradeability

`Critter.untradeable: boolean?` (decision D-005) marks a critter that can never be traded or
gifted, such as one from a rescue egg. Missing means tradeable, so this optional field needed no
migration and no `SCHEMA_VERSION` bump; `Profile.spec` checks that an old save reads as
tradeable.

- `Profile.isTradeable(critter, now)` is the minimum check: false if `untradeable` is set, or
  while `stolenLockUntil` is in the future. Trading adds its own rules when it is designed (e.g.
  no trade back to the critter's previous owner, which would be ransom).
- Any future trading or gifting code must refuse a critter for which `Profile.isTradeable` is
  false. The `reviewer` checks for this on every trading or gifting PR.
- Raids are not trades: escrow moves an untradeable critter like any other, and the flag survives
  the transfer (tested in `Profile.spec`).

## Critter personality

`CritterSpecies.personality: string` (decision D-038) is one or two lowercase words (each word
letters, optionally one hyphen inside), such as
`"smug"`, naming the one expression a critter's art shows. It is static design data in
`Data/Critters.luau`, never persisted, so adding it needed no migration. The asset pipeline turns
it into the expression line of every prompt (`tools/assets/build_prompts.luau`); game code may
show it as flavor text but must not branch on it.

`CritterCatalog.validate()` enforces the style bible: every species has one, at most
`CritterCatalog.MAX_SHARED_PERSONALITY` (6) species share one, and none uses a word in
`CritterCatalog.FORBIDDEN_PERSONALITY_WORDS` (sad, crying, injured, frightened and similar).
The same words are refused in `idle`, which feeds the den idle animation. `validate(list?)` takes
an optional species list so tests can check that it rejects bad data.
