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
4. No defender loses more than `Config.Limits.maxLossesPerDay` critters per UTC day.

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
raider, defender, critterUid, glowRequested, isRevenge). Once a record is stored, the same raidId
with any other argument returns `Refused` ("raidId already used by a different transfer"). While
the server still waits on a retry of the raid (an earlier call returned `InFlight`), the retry
reuses that call's `createNonce`. So a create that landed but lost its response is still the
call's own, and the steal continues (`Escrow.advance`) instead of being voided.

Phase 1 (P1.1, decision D-012): the void rule assumes only the creating call debits. A debit
delivered by ProfileStore message, or applied to an offline profile, could land after a void and
strand the loot, and `EscrowRecord` has no `kind` field to tell live from async. Both must be
solved before any async transport ships.

`appliedTransfers` entries are pruned after `Config.Escrow.appliedTransferRetentionSeconds`, but
only by EscrowService after reading the player's `Open_` index, and never for a raidId still
listed there. `Profile.prepare` does not prune them.

If you change `Escrow.luau`, `RaidRules.recordIncoming` or anything in `appliedTransfers`, the
simulation must still pass, and the `reviewer` agent must sign off.

## Kill switches

`Config.Flags` holds one boolean per feature. `false` turns the feature off everywhere. Services
read `Config.Flags.<name>` directly and check it before acting on a request. Raid and transfer
starts go through the pure `Escrow.canStartTransfer(Config.Flags, kind, isRevenge)`.
EscrowService and RaidService must call it before starting any raid or transfer.

| Flag | Gates | Default |
| --- | --- | --- |
| `raids` | Master switch: starting any raid or escrow transfer of any kind (live, async, revenge) | `true` |
| `asyncRaids` | Additionally gates async raids and revenge raids (new `Async` transfers, and any transfer with `isRevenge`); needs `raids` on too | `false` |
| `purchases` | Robux products (PurchaseService) | `false` |
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

## Replicated attributes

Attributes the server sets on Instances so clients can draw state without a remote. All are
server-written and display-only:

- The server keeps the authoritative state in its own tables. It never reads `CarryingUid`,
  `CarryingSpecies`, `LockdownUntil` or `LockdownReadyAt`, and no gameplay or data decision
  ever comes from an attribute.
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
| Pad Part | `PadIndex` | number | The pad's number |
| Critter Model | `CritterUid`, `SpeciesId`, `Tier` | string | Which critter this model draws |
| Critter Model | `PadIndex`, `OwnerUserId` | number | Where it sits and whose it is |

## Eggs

`Config.Economy.eggMaxTier` (`"Uncommon"` at launch) is the highest tier a bought egg can hatch.
Tiers up to it keep their `Config.EggOdds` ratios, renormalized to sum to 1
(`Economy.rollTierUpTo`): Common 0.6875 and Uncommon 0.3125 today, tested in `Config.spec`.
Phase 2 raises it to `"Mythic"`. The rescue egg rolls from its own Common-only table (from
P0.4b) and ignores `eggMaxTier` (decision D-004).

Glow is earn-only at launch (D-028): no product may grant Glow for Robux. The "Lantern Night"
server boost (D-029) multiplies Glow earned in play (+50% for everyone in the server, 15 min);
it never grants Glow directly, and it needs a reviewer policy audit and PolicyService checks
before it ships (does a Robux-bought earning boost make Glow eggs paid random items?). Glow buys eggs, so
Glow packs would make every egg a paid random item; they ship only in the Phase 2
paid-randomness mini-phase with on-screen odds, PolicyService region checks and a reviewer
audit. Egg odds are shown on screen for every egg from Phase 0, from Economy's odds helpers
(Config.EggOdds after the eggMaxTier renormalization; rescue egg: Common 100%).

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
