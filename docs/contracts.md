# Contracts

The shared shapes and rules every agent builds against. Source files are the truth; the
reasons behind each rule live in `docs/decisions-log.md` (cited as D-0xx), not here. Read the
sections for what you touch. Update this page in the same commit as any contract change.

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
| Profile per user | `PlayerProfile` | DataService only: its sessions, or `updateOffline` while no server holds the key (P1.1) | Others send messages (`sendMessage`) |
| Snapshot per user | `DenSnapshot` | SnapshotService | Never includes vault critters. DataStore `DenSnapshots`, key `Snapshot_<userId>` |
| Escrow per raidId | `EscrowRecord` | EscrowService | Write-once create, then state moves forward only |
| Open escrows per user | `EscrowOpenIndex` | EscrowService | Both raider and defender; added before the record, removed once terminal |
| Replay per raidId | `Replay.encode` string in a record | ReplayStore (raid) | DataStore `RaidReplays`; 7-day lifetime; see Replays |

Profile storage: ProfileStore store `PlayerProfiles`, key `Player_<userId>` (`DataService.luau`).

Optional `PlayerProfile.raidLogSeenAt` (unix seconds): when the player last opened their raid
log, written by DataService when `GetRaidLog` is answered. Missing = never; no migration.
`DataService.markRaidLogSeen(userId, now)` writes it: server `os.time()` only, forward only, a
non-finite `now` is ignored, and only on a profile loaded in that server (`Profile.markRaidLogSeen`).
It never changes the `RaidLogSeenAt` attribute, which keeps its load-time value all session.

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
- **Test sessions** (P1.10d). `DataService.loadTestSession(userId)` starts a real ProfileStore
  session on `Player_<userId>` for a test id (`Profile.isTestUserId`), held by this server and
  saved like a player's, so escrow credits, saves, recovers and sweeps it exactly as a player
  loaded here; it has no Player, den or client. Allowed only when `RunService:IsStudio()`, the
  boolean ServerStorage attribute `StudioTestSessions` is `true` (read on each call) and
  `persistence()` is `"DataStore"`; anything else errors before anything is held (Memory mode
  uses test profiles instead, so the two never meet). `releaseTestSession(userId)` is a leave
  (no escrow guard; recovery finishes an open transfer on the next load) and waits up to 10 s
  for the final save; ProfileStore's BindToClose releases it on stop. Its saves are real: delete
  the `Player_<testId>` (and their `Escrow_`/`Open_`) keys in the Data Stores manager after a
  soak. `ServerStorage.DataTestHook` (Studio only, same switch and id checks) wraps it:
  `"load"`, `"seed"` (Common critters on free pads plus stored Glow, then a confirmed save),
  `"show"` and `"release"`. Soak and test raids use test ids against test ids only; never a
  test id against a real account in DataStore mode (it would really move that player's critter).
- **Escrow playtest switches** (P1.1, ServerStorage attributes, read only when
  `RunService:IsStudio()`): `StudioAsyncRaids = true` makes `EscrowService.canStartTransfer`
  count `asyncRaids` as on (the master `raids` switch still applies), and
  `StudioEscrowPause = "<checkpoint>"` (an Escrow checkpoint name such as `"deliveredDebit"`)
  holds any escrow drive at that step, so a playtest can stop the server mid-transfer.
  Clearing the attribute resumes the drive; the server closing, or 2 minutes, stops it with an
  error instead, so the paused step is never finished from that server and recovery finishes it
  on the next load (#114). A live server never reads either.

Profile writes outside a session (P1.1): `DataService.updateOffline` runs one `UpdateAsync` on
`Player_<userId>` that lands only while ProfileStore's `MetaData.ActiveSession` is empty, runs
`Profile.prepare` on the data first, and keeps ProfileStore's metadata, message queue, `UserIds`
and `RobloxMetaData`. It never takes a session lock (so it never makes a server release and kick
its player). Messages (`DataService.sendMessage`) are `{ topic, data }` tables in ProfileStore's
queue in the same key; `DataService.onMessage(topic, fn)` receives them where the profile is
loaded. Topics: `EscrowDebit` with `data = { raidId }`, a wake-up for an async debit (the
escrow record decides; repeats and late ones change nothing).

**Never change the store name or the key format.** ProfileStore would find no save under the
new name and hand every player a fresh template. Everyone silently starts over: the old saves
still exist, but nothing reads them. The same applies to `EscrowRecords` and its keys below,
where a rename would strand every transfer in flight.

Escrow storage: DataStore `EscrowRecords`. Every write stores the userIds the key is about
(both parties for a record, the owner for an index; decision D-008, for erasure tooling). Only
accounts are named: a negative id (a Studio test id or Local Server player) is left off, as
ProfileStore does, so a live write names exactly its parties.

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

### Phase 2 profile fields (C6, decision D-059)

All optional on `PlayerProfile`: a missing field means its default, so saves from before Phase 2
load unchanged, with no migration and no `SCHEMA_VERSION` bump (`Profile.spec` checks an old
save). Read and write them only through the `Profile` helpers named below: readers turn a corrupt
saved value into the default, writers refuse bad input (writing nothing) and return whether they
wrote, and `now` is always the server's `os.time()`. Nothing yields. A service changes them on a
profile loaded in its own server (`DataService.getProfile`), never on another server's player.

| Field | Type | Missing means | Helpers | Task |
| --- | --- | --- | --- | --- |
| `settings` | `PlayerSettings?` (`musicVolume`, `sfxVolume`: 0-1 in 0.01 steps; `reducedMotion`) | `Profile.SETTINGS_DEFAULTS`: 0.6, 0.8, false (the client's defaults) | `settingsOf`, `cleanSettings(request)`, `applySettings(profile, request)` | P2.5 |
| `onboarding` | `OnboardingState?` (`step`: steps of `ONBOARDING_STEPS` done, 0-6; `completedAt?`) | complete (an old save) | `ONBOARDING_STEPS`, `onboardingStepIndex`, `isOnboardingComplete`, `onboardingStep`, `onboardingStatus`, `advanceOnboardingTo` (server events), `acknowledgeOnboarding` (client acks), `completeOnboarding`; low-level `advanceOnboarding` | P2.6 |
| `successfulRaids` | `number?` | 0 | `successfulRaids`, `countSuccessfulRaid` | P2.7, P2.9 |
| `gear` | `{ [GearId]: number }?` | level 0 (not owned) | `GEAR_IDS`, `isGearId`, `gearLevel`, `setGearLevel` | P2.10 |
| `receipts` | `{ [string]: PurchaseReceipt }?` (`productId`, `at`) | none granted | `hasReceipt`, `recordReceipt`, `MAX_RECEIPTS` (100) | P2.8 |
| `eventPasses` | `{ [string]: number }?` (event id -> granted at) | none owned | `hasEventPass`, `grantEventPass` | P2.8 |
| `accessories` | `{ [string]: number }?` (accessory id -> count) | none owned | `accessoryCount`, `grantAccessory` | P2.8 |

- **Onboarding.** `Profile.new` (the ProfileStore template) is the only place that sets a Phase 2
  field: `onboarding = { step = 0 }`, so a new save starts it. `step` counts the steps of
  `Profile.ONBOARDING_STEPS` done, in order (C6b, below); `ONBOARDING_LAST_STEP` (6) is all of
  them. Steps only move forward, reaching the last sets `completedAt`, and `completeOnboarding` is
  a skip that keeps the step reached. DataService must never reconcile the template into an
  existing save (ProfileStore's `Reconcile`; a source test checks): that would send every existing
  player through onboarding.
- **Settings.** `cleanSettings` takes the client's table as untrusted: all three settings must be
  there with the right types and finite volumes (clamped to 0..1, rounded to 0.01), or the whole
  request is refused; any other key is ignored and never read. `applySettings` saves the cleaned
  three, replacing what was saved. A key never set reads as its default.
- **Successful raids.** The lifetime count of raids and live steals the player escaped from,
  counted once per raid by the raider's own server (`countSuccessfulRaid` returns the new count;
  1 is the first, the notification opt-in trigger). Old saves start at 0.
- **Receipts.** The ProcessReceipt idempotency rule: grant only when `recordReceipt(profile,
  PurchaseId, productId, now)` returns true, in the same step with no yield between, then confirm
  the save (`DataService.saveNow`) before returning `PurchaseGranted`. false on an existing
  PurchaseId is a redelivery: grant nothing, confirm the save, return `PurchaseGranted`. Roblox
  redelivers an ungranted receipt later or when the player rejoins, with no documented time limit,
  so the ledger keeps the newest 100 by count, never by age, and never drops the receipt it just
  recorded.
- **Reused, not added.** First join: `createdAt` (stamped by `Profile.prepare` at the first load;
  days since join for `rebirth`). Purchased shield: `shieldUntil` (`RaidRules.applyPurchasedShield`).
  Rebirth vault slots: `vaultSlots`; the vault slot game pass needs no field (ownership is a
  MarketplaceService check). Raid log visits: `raidLogSeenAt`. Appendix C's 30-minute new-player shield is
  derived from `createdAt` and needs no field (async raids are already blocked for 48 hours by
  new-player protection).
- **Not on the profile.** Notification state (daily send slot, pending Glow loss, opt-in prompt
  time) lives in NotificationService's own `NotificationState_v1` DataStore (D-062): the daily cap
  is written by the raider's server for an offline defender, and a profile field would need a
  second cross-server write to the defender's key. The older `notificationPromptedAt` field stays
  in the shape (no removal without a migration), but nothing writes it.

### Settings and onboarding remotes (C6b, decisions D-059, D-063)

DataService owns the handlers. Additive only: no profile shape change, no migration. Every request
counts against its `Net.Limits` entry per player (`Shared/RateLimit.luau`: fixed 10 s windows on
the server's `os.clock()`; a bad clock or limit fails closed). Every time saved is the server's
`os.time()`. Nothing here forces a save: changes ride the next autosave or the final save on
leave. Handlers never let an error reach the client.

| Remote | Shape | Limit / 10 s | Rules |
| --- | --- | --- | --- |
| `Net.Requests.GetSettings` | `() -> Net.Settings?` | 3 | `Profile.settingsOf`, defaults filled in. Waits up to 20 s (polling every 0.5 s, one wait per player) for a joining player's profile; nil if it did not load, the player left, or refused |
| `Net.Requests.SaveSettings` | `(Net.Settings) -> boolean` | 3 | `Profile.cleanSettings`: a table with all three fields, finite volumes clamped to 0..1 and rounded to 0.01, a boolean `reducedMotion`; extra keys ignored; NaN, inf, wrong types or a missing field refuse it whole (false, nothing saved). true = saved. Over the limit, the latest valid request is kept (one per player) and applied when the window reopens, or right before the final save if the player leaves first, so the last change is never dropped (at most limit + 1 applies per window) |
| `Net.Requests.GetOnboarding` | `() -> Net.OnboardingStatus?` | 3 | `Profile.onboardingStatus`. Same bounded wait as GetSettings |
| `Net.Requests.AckOnboarding` | `(stepId) -> boolean` | 3 | `Profile.acknowledgeOnboarding`: only a `"Client"` step, and only the next one. true = recorded now, or already behind the player (or onboarding is over); false = refused |
| `Net.Pushes.OnboardingChanged` | `(Net.OnboardingStatus)` | | Sent to the player after every step they complete, by a server event or an ack |

`Net.Settings` is `{ musicVolume, sfxVolume, reducedMotion }`, every field present.
`Net.OnboardingStatus` is `{ step, nextStepId?, complete }`: `step` as saved (all 6 for a save from
before onboarding), `nextStepId` the step to guide next (nil once complete), `complete` true once
finished or skipped, and for every save from before onboarding (show no onboarding).

Onboarding steps, `Profile.ONBOARDING_STEPS` (pure, frozen). `OnboardingState.step` saves how many
are done, so the list is persisted meaning: once shipped, never reorder or remove a step or change
an id; a new step goes at the end.

| # | id | Appendix C | Decided by | Done when |
| --- | --- | --- | --- | --- |
| 1 | `hatch` | 1 | Server | The free first egg hatched |
| 2 | `place` | 2 | Server | The player put a critter on a pad |
| 3 | `collect` | 2 | Server | The player banked den Glow |
| 4 | `buyEgg` | 3 | Server | The player bought an egg with Glow |
| 5 | `stealHome` | 4-5 | Server | A stolen critter reached the player's profile (the guided steal's escape) |
| 6 | `raidLogTip` | 5 | Client | The player dismissed the one-line raid log explanation |

Appendix C line 6 (the 30-minute shield) needs no saved state (from `createdAt`; raid's P2.6r) and
line 7 (notification opt-in) is not onboarding.

- **Server events.** Services call `DataService.advanceOnboarding(userId, stepId)` after the real
  event succeeded, with a `"Server"` step id they choose, never anything a client sent. It runs
  `Profile.advanceOnboardingTo` at `os.time()`: forward only, it may jump over earlier steps (the
  player is past them), and it never restarts a finished or skipped onboarding (every save from
  before onboarding counts as finished). A repeat or a passed step changes nothing. It never
  yields or saves, pushes `OnboardingChanged` when it wrote, does nothing for a profile not loaded
  in that server, and returns whether it wrote.
- **Client acknowledgements.** Only `"Client"` steps, only the next one, through `AckOnboarding`.
  The client can never skip ahead or complete a server step.

## Analytics (P2.9, D-059)

Schema: `src/Shared/Analytics.luau` (pure, tested in `Analytics.spec`). Sender:
`src/Server/Services/AnalyticsService.luau`, the only code that calls Roblox's AnalyticsService
(a source guard checks). Nothing new is persisted; no Types, Net or Config change.

- **Calls** (server only, never yield or throw, return whether logged):
  `AnalyticsService.track(playerOrUserId, event, fields)`,
  `AnalyticsService.step(playerOrUserId, "RaidFlow", "TargetPicked")` (the one funnel step with no
  event), `AnalyticsService.economy(playerOrUserId, flowId, amount, endingBalance)`, and
  `AnalyticsService.trackNotification(event, fields)` for NotificationService's `track`. A userId
  must be a player in this server: Roblox logs every event on a Player.
- **Fields are closed.** `Analytics.validate` refuses an unknown event or field, a missing field, a
  wrong type, a string outside its enum, an `id` that is not a short server identifier
  (`^%a[%w_]*$`, at most 32), and NaN, infinite, negative, out-of-range or non-whole numbers. No
  field carries a user id, a name, a raidId or player-typed text; the Player is the only identity.
- **Shape on the wire.** One number (`value`) and at most three custom fields
  (`CustomField01..03`), rendered `"<Label> - <value>"`; numbers shown in a field are bucketed so no
  event passes Roblox's 8,000 combinations (the spec checks every event).
- **Funnels.** Onboarding (Roblox one-time onboarding funnel, accounts under 7 days from
  `createdAt`): Join, FirstHatch, FirstCollect, FirstSteal, FirstRaid. RaidFlow (recurring, one
  funnel session per portal trip): Portal, TargetPicked, RaidStarted, Escaped. Steps come from
  events (`Analytics.funnelSteps`), so callers fire only the event.
- **Economy.** Currencies `Glow` (banked) and `DenGlow` (stored). Flow ids in `Analytics.ECONOMY`;
  amount > 0, endingBalance >= 0 (the balance of that currency after the change).
- **Budget.** Per player a burst of 20, then 15 a minute (`Analytics.take`), under Roblox's
  120 + 20 x CCU per minute; `session_end` and `purchase` skip it.
- **Studio.** Roblox records nothing from Studio. Set the ServerStorage boolean attribute
  `StudioAnalyticsLog` to `true` to make the server call the API and print every accepted call
  (`[Analytics] ...`); without it Studio sends and prints nothing. Refusals always warn.

| Event | Fields (value first) | Fired by |
| --- | --- | --- |
| `onboarding_step` | secondsSinceJoin; step 1-5 | onboarding API (C6b) |
| `egg_bought` | price; tier, denLevel | economy |
| `critter_placed` | (count); tier, placement | economy |
| `glow_collected` | amount; storageFill (stored / cap before the collect) | economy |
| `raid_portal_opened` | targetsOffered; revengeAvailable | matchmaking (GetRaidTargets) |
| `raid_started` | targetPower; mode `Async`/`Live`, revenge | raid |
| `raid_ended` | glow; escaped, tierTaken (tier or `None`), durationSeconds, mode | raid |
| `raided_offline` | glowLost; tierLost, revenge, attributedTo | EscrowService, Async debit saved |
| `raid_log_opened` | entriesSinceLastVisit | DataService.markRaidLogSeen |
| `revenge_started` | hoursSinceRaided; fromNotification, mode | raid |
| `notification_sent` | (count); category, result `Sent`/`Throttled` | notifications |
| `notification_join` | (count); category | notifications |
| `optin_prompted` / `optin_result` | (count); trigger / accepted | notifications |
| `purchase` | price (Robux); product (server key) | economy (PurchaseService) |
| `rebirth` | count; daysSinceJoin (from `createdAt`) | economy |
| `session_end` | sessionSeconds; raids (started), steals (escapes with a critter) | DataService / AnalyticsService on leave |

`raided_offline` is logged on the defender when they are in the server that saved the debit,
otherwise on the raider (`attributedTo = "Raider"`), since a profile no server holds has no Player.

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
- **The Glow-factor helper (P2.8).** Server code accrues and collects only through
  `IncomeService.accrue(profile, now)` and `IncomeService.collect(profile, now)`, and a player's
  factor changes only through `IncomeService.setGlowInputs(userId, change, now)`, which accrues
  at the old factor first (see Purchases below). A profile that is not the one loaded in this
  server for its player accrues at factor 1 (offline income is unboosted). A source guard
  (`PurchaseSource.spec`) fails if `Economy.accrue`, `Economy.collect` or their boosted forms
  appear in `src/Server` outside the helper's markers.
- **P2.8 gate.** Three factor-1 accrues of online players remain, each a handoff listed in the
  guard's `PENDING` (the guard fails when one lands until it is removed from the list):
  `EscrowService` (the escrow store's `loadProfile`), `DataService.seedTestSession` (Studio
  only), and snapshots (`SnapshotService` building through `Matchmaking.buildSnapshot`). The
  guard also fails if `Config.Flags.purchases` is on while any remain. `Escrow.debitAbsentProfile`
  accrues an absent (offline) defender at factor 1, which is correct while VIP is online-only.

## Escrow

```
Pending ──debitDefender + markDebited──▶ Debited ──creditRaider + markCommitted──▶ Committed
   └──void (before any debit)──▶ Voided
```

Each arrow is two single-key writes; every step is idempotent by `raidId`
(`appliedTransfers` on each profile). Invariants, enforced by
`tests/specs/EscrowSimulation.spec.luau`:

1. A critter uid exists in exactly one place: one profile, or in flight for one raid.
2. Glow is conserved. A Live debit takes up to `glowRequested` from `stored`. An Async debit
   (P1.1) takes the raid's share (`RaidRules.lootGlow`'s share, revenge bonus included) of
   `stored` as it is at the debit, which the server accrues to the debit first (Money model; for
   a defender no server holds, `Escrow.debitAbsentProfile` inside the one atomic write):
   the record's `glowRequested` (the snapshot's figure) is only the estimate the raid showed.
   Neither ever takes more than is stored, and the raider is credited exactly what was debited.
3. Repeating any step changes nothing after the first success.
4. Daily loss limits hold at the debit, by the record's `kind` (decision D-031):
   - Live: a live debit takes a critter that is still on its pad exactly when the den is not
     protected at that debit (`RaidRules.liveProtectedAtDebit`, read with the critter still in
     the den; the line is in Live loss rules). The debit that crosses the line lands, so the
     losses before any live steal were always under the line measured at that steal.
   - Async: no async debit takes a critter once the defender has lost
     `Config.Limits.maxLossesPerDay` critters that UTC day (live losses count toward it too).
5. An empty live commit grants nothing (decision D-033). A Live debit that takes no critter
   (the den is protected, or the critter is gone) and no Glow still writes its
   `appliedTransfers` entry, so it stays idempotent. It skips `RaidRules.recordIncoming`
   entirely: no shield, no revenge token, no `pairRaidsToday` increment (the raider's pair slot
   is not used up) and no "escaped" incoming raid-log entry. A Live debit that takes only Glow,
   and every Async debit, empty or not, still records all four.
6. The raider's side of an Async credit (P1.3d). `Escrow.creditRaider` on an Async record that
   moved something (a critter or Glow) also records, in the same write as its `appliedTransfers`
   entry and from the record and the credit only:
   - the raider's Outgoing raid-log entry and one `pairRaidsToday` count against the defender
     (`RaidRules.recordOutgoing`, with `escaped = true`, the species and Glow credited, and
     `isRevenge`), so `canRaid`'s pair limit counts async raids;
   - for a revenge record with a `revengeRaidId`, that token removed from the raider's
     `revengeTokens`, if it is still there and targets this defender: one revenge raid per token
     (D-054). Matchmaking's revenge targets, `StartRaid` (`RevengeExpired`) and live revenge
     (P1.9, `NoToken`) then simply stop offering it.

   An empty Async credit (nothing moved) records none of them (the D-033 pattern; a raid that
   took nothing never counts toward the pair limit, D-053), so a failed or empty revenge raid
   keeps its token. A Live credit records none of them
   either: live raids are unchanged (live token spend is backlog, D-052). A repeat, a late or
   recovered credit, or a retry changes nothing, since a credit runs once per raidId.

`EscrowRecord.kind` (`"Live"` or `"Async"`) is set when the record is created and never changes
(`Escrow.canReplace`). Missing means `"Live"`: every record written before the field existed
is a Phase 0 live steal, so it needed no migration. `EscrowService.transferLive` creates
`"Live"` records; `EscrowService.transferAsync` (P1.1, an async raid's escape) creates `"Async"`
records, and its `glowRequested` is the snapshot's `RaidRules.lootGlow` estimate.

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

`EscrowRecord.revengeRaidId: string?` (P1.3d, additive) names the raider's revenge token that an
Async revenge raid uses: its key in the raider's `revengeTokens`, which is the raidId of the raid
on them that granted it. A credit that moved something removes that token (invariant 6, D-054).

- **Set once.** `EscrowService.transferAsync` takes it as an optional 7th argument, from the
  raid's server state (the token StartRaid accepted), and `Escrow.create` as an optional 10th.
  It must be nil, or a string of 1 to `Config.Escrow.maxRaidIdLength` characters on an Async
  record with `isRevenge = true` (`Escrow.checkRevengeRaidId`, which `Escrow.create` asserts).
  `transferAsync` refuses anything else before any read or write.
- **Never changes.** `Escrow.sameTransfer` compares it, so a retry must pass the same one, and
  `Escrow.canReplace` never fills it in, changes it or drops it.
- **Missing means no token is spent:** records written before the field existed, non-revenge
  and Live records, and a revenge raid whose caller passes none. No migration.

Only the call that creates a Live record, and its same-server retries while the server awaits
them (kept `createNonce`), debits the defender (`Escrow.advance`). That call sets
`EscrowRecord.createNonce` (a GUID; optional, missing on older records, no migration) so that a
create which landed but whose response was lost is still recognised as its own on retry
(`Escrow.decideCreate`) and driven forward instead of voided. The nonce never changes once
written (`Escrow.canReplace`). Every later path is `Escrow.recover`, which never debits a Live
record afresh. It runs on either party's load, with the parties loaded in that server:

- Live `Pending`, defender loaded: their saved debit moves the record to `Debited`. No debit:
  first a confirmed save by the session that still holds the defender's lock, without an entry
  for the raid (`Store.saveProfileWithoutEntry`), then `Voided` (nothing moved). A server whose
  lock was taken by another server cannot produce that save, so it never voids.
- Async `Pending` (P1.1): never voided. Any path, from any server, as often as it runs, delivers
  the debit: with the defender loaded there, debit and save their profile; otherwise
  `Store.debitAbsent` (optional in `Escrow.Store`, required for Async records), which writes the
  debit to the defender's saved profile in one atomic write that lands only while no server
  holds it and returns the saved entry, or, when a server holds it, asks that server by message
  and returns nil (that server's recovery delivers it). Then `Debited` as above.
  `Escrow.debitDefender` is idempotent by raidId, so a debit delivered twice, late, or by two
  servers lands once, and its daily loss rule is judged where it lands.
- `Debited`, raider loaded: credit, then `Committed`.

Retrying `EscrowService.transferLive` (P0.5): call again with IDENTICAL arguments (raidId,
raider, defender, critterUid, glowRequested, isRevenge, liveBaseRate). Once a record is stored,
the same raidId with any other argument returns `Refused` ("raidId already used by a different
transfer"). While
the server still waits on a retry of the raid (an earlier call returned `InFlight`), the retry
reuses that call's `createNonce`. So a create that landed but lost its response is still the
call's own, and the steal continues (`Escrow.advance`) instead of being voided.

Decision D-012's race (a debit by message, or to an offline profile, landing after a void) is
closed by the Async rule above: no Async record is ever voided, so a late debit has no void to
race. Live records keep the void, and only their creating call debits them. Cancelling an async
raid after its record exists would need a void that a later debit must refuse (a tombstone
written inside the void proof save); nothing does that today.

`appliedTransfers` entries are pruned after `Config.Escrow.appliedTransferRetentionSeconds`, but
only by EscrowService after reading the player's `Open_` index, and never for a raidId still
listed there. `Profile.prepare` does not prune them.

If you change `Escrow.luau`, `RaidRules.recordIncoming`, `RaidRules.recordOutgoing`,
`RaidRules.recordLiveLoss`, `RaidRules.liveProtected`, `RaidRules.liveProtectedAtDebit` or
anything in `appliedTransfers`, the simulation must still pass, and the `reviewer` agent must sign
off.

## Matchmaking

Snapshots (SnapshotService) are saved on leave and every `Config.Snapshot.intervalSeconds` while
online, built from a copy of the profile (the live profile is not accrued). Optional
`DenSnapshot.blockedUserIds` is the owner's last reported Roblox block list; missing blocks
nobody, so no migration. Until a session's first report, the previous snapshot's list is kept.

MemoryStore (MatchmakingService). In `Memory` persistence (D-019) all of it lives in server
memory instead, so test ids never reach a real pool.

| Structure | Key | Value | TTL |
| --- | --- | --- | --- |
| Sorted map `Pool_<band>` per `Matchmaking.powerBand` | userId | `Matchmaking.encodeEntry` array; sortKey `lastActiveAt` | `Config.Matchmaking.activeWithinSeconds` |
| Hash map `RaidLocks` | defender userId | `{ raiderUserId, raidId, released? }` | `Config.Raid.lockTtlSeconds` (released: 10 s) |
| Hash map `Presence` | userId | `{ jobId, placeId, at }` | 2.5 x `Config.Matchmaking.presenceRefreshSeconds` |

- Only offline dens are listed: an entry is written when a leave snapshot saves and removed
  when the player's profile loads again.
- One raider per defender: `MatchmakingService.acquireLock` / `releaseLock` are single
  `UpdateAsync` calls (`Matchmaking.lockAfterAcquire` / `lockAfterRelease`). A retry with the same
  raidId keeps the lock; an unreadable lock counts as held. Acquire refuses while
  `Config.Flags.raids` is off and fails closed during a MemoryStore backoff; release is never gated.
- `Net.Requests.GetRaidTargets` returns `{}` unless `Config.Flags.raids` and `asyncRaids` are
  on. Rows: revenge targets first (`Matchmaking.revengeTargets`: any power band, at most
  `Config.Matchmaking.maxRevengeTargets`, pair limit counts), then `pickCandidates`.
  `RaidTarget.revengeRaidId` is set on revenge rows (pass it to StartRaid); `topTier` is the
  highest tier on the den's pads. No row ever shows exact Glow.
- Blocked players never match, either direction: the raider's reported list, and each target's
  snapshot `blockedUserIds`. A target whose snapshot cannot be read is not shown.
- `Net.Requests.ReportBlocked` (RemoteEvent, `{ number }`): distinct positive whole userIds, at
  most `Config.Matchmaking.maxBlockedUserIds`; anything else is ignored.
- Limits per 10 s: `Net.Limits.GetRaidTargets` 3 (and one call at a time per player),
  `Net.Limits.ReportBlocked` 2, `Net.Limits.JoinRevengeServer` 2.

Live revenge (P1.9): join the server of the raider who robbed you while they are online.

- `RaidTarget.raiderOnline: boolean?` is set on revenge rows: true when the raider is in this
  server or has a fresh `Presence` row for another server of this place (cached 15 s). A hint
  for showing the button; missing or false means offline or unknown.
- `Net.Requests.JoinRevengeServer` (RemoteFunction, `(revengeRaidId) -> Net.RevengeJoinStatus`),
  one call at a time and one teleport in flight per player. The server checks, from its own
  state only: `Escrow.canStartTransfer(Config.Flags, "Live", true)` (so `raids` and
  `asyncRaids`), then `Matchmaking.liveRevengeToken` on the caller's own profile (token held,
  unexpired, not self, the live pair limit `min(maxRaidsPerPairPerDay, maxStealsPerPairPerDay)`
  not reached), and no block either way (session reports, else snapshot lists; unreadable
  refuses as `Busy`). Raider in this server: the caller lands at once. Otherwise
  `Matchmaking.presenceRoute` must say `Teleport` and the server calls `TeleportAsync` with
  `TeleportOptions.ServerInstanceId` = the presence `jobId`.
- `Net.RevengeJoinStatus` `{ state, revengeRaidId, targetUserId?, reason? }`: `Teleporting`,
  `Arrived` or `Failed`. Reasons: `SwitchedOff`, `Invalid`, `NoToken`, `Expired`,
  `Unavailable` (blocked, either way; never says which), `PairLimit`, `Busy`, `RaiderOffline`,
  `ServerFull`, `ServerGone`, `TeleportFailed`. On the last five the UI offers the async revenge
  raid (`StartRaid(targetUserId, revengeRaidId)`) instead.
- `Net.Pushes.RevengeJoinStatus` (same payload): a `Failed` after `Teleporting`
  (TeleportInitFailed), and the landing server's `Arrived` or `Failed`.
- Teleport data is `{ liveRevengeRaidId }` and only a hint (`Matchmaking.readRevengeHint`):
  clients can forge it. After the arriving player's profile loads, the landing server repeats
  every check on that profile and needs the raider in THIS server with a loaded profile and a
  den. Then the character lands on the street in front of the raider's den
  (`Matchmaking.revengeLanding`, outside every den) and the revenge is active in server memory.
- A token is never spent by any of this, including a failed teleport. It is spent only when a
  revenge raid starts. `MatchmakingService.getLiveRevenge(player)` re-checks everything (no
  yield) on every call. Lockdown still blocks entry (D-013) and the live loss rules apply
  unchanged.

## Kill switches

`Config.Flags` holds one boolean per feature. `false` turns the feature off everywhere. Services
read `Config.Flags.<name>` directly and check it before acting on a request. Raid and transfer
starts go through the pure `Escrow.canStartTransfer(Config.Flags, kind, isRevenge)`.
EscrowService and RaidService must call it before starting any raid or transfer.

| Flag | Gates | Default |
| --- | --- | --- |
| `raids` | Master switch: starting any raid or escrow transfer of any kind (live, async, revenge) | `true` |
| `asyncRaids` | Additionally gates async raids and revenge raids (new `Async` transfers, and any transfer with `isRevenge`); needs `raids` on too | `false` |
| `purchases` | Robux products and passes (PurchaseService: offers, perks, receipts), and Robux-linked Glow multipliers (`Economy.glowBoostFactor`'s `purchasesEnabled`, D-032) | `false` |
| `trading` | Trading (post-launch) | `false` |
| `notifications` | Experience notifications (NotificationService) | `false` |

Unknown transfer kinds are always refused. Switches block STARTING new raids and transfers only.
Escrow recovery and transfers already in flight are never gated: records in `Pending` or
`Debited` always advance to completion, so turning a flag off cannot strand loot in flight.
Raid semantics approved by Kian 2026-10-28 (decision D-002).

Defaults turn on only the features that exist. Adding a flag is a contract change.

Rollout (D-049): `asyncRaids` is flipped only after every server running pre-P1.1 code is shut
down, since such a server would recover an Async record under the Live rules and could void it.

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
- Live revenge steal (P1.9b): a grab in the den of the player's active live revenge target
  (`MatchmakingService.getLiveRevenge`, never client data; `RaidRules.liveRevengeAgainst`) is a
  revenge: the grab's kill switch is `Escrow.canStartTransfer(Config.Flags, "Live", true)`, and
  nothing else changes (Lockdown, live loss rules, Glow 0). At the escape the revenge is read
  again (`RaidRules.liveRevengeAtEscape`); `transferLive` gets `isRevenge = true` only if the same
  revenge is still active, else the carry escapes as a plain live steal. RaidService never
  touches a revenge token.

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
| `protectionLossShare` | 0.5 | Share of the den's Glow/s that, while today's live losses reach it, protects the den from live steals (Live loss rules, rule 3) |

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

## Async raids

Raids on an offline den, rebuilt from its snapshot in a pocket den far off-map in the raider's
own server (RaidService + `Raid/AsyncRaid.luau`; rules in `RaidRules`, "Async raids").

- `Net.Requests.StartRaid` `(targetUserId, revengeRaidId?) -> RaidStart?` (nil = refused),
  `Net.Limits.StartRaid` per 10 s and one call at a time. The server re-checks everything the
  target list did, from the snapshot: `Escrow.canStartTransfer(Config.Flags, "Async", isRevenge)`,
  blocks both ways, the owner not online (a player here, or presence younger than
  `RaidRules.Pocket.presenceFreshSeconds`: raided live instead), `RaidRules.canRaid`, at least one
  Pad critter. A revenge id must be a token in the raider's own profile against that target.
  Then it takes the defender's raid lock, released on every end.
- `RaidStart`: `raidId`, `targetUserId`, `endsAt` (server time, `workspace:GetServerTimeNow()`,
  start + `Config.Raid.durationSeconds`), `gatePosition` (Vector3), `critters`
  (`{ PocketCritter }`: uid, speciesId, mutation, padIndex, position; Pad critters only),
  `isRevenge`. Nothing in it carries Glow or the owner's block list.
- `Net.Requests.GrabCritter` (RemoteEvent `(raidId, critterUid)`, `Net.Limits.GrabCritter`), or the
  pocket pad's prompt. The server checks the timer, one carry at a time, that the uid is a Pad
  critter of the raid's own snapshot copy that the pocket laid out, and range from the server
  root part to the server pad (`Config.LiveRaid.grabRange`). Vault critters are never in a
  snapshot, so never stealable.
- Carry speed is `RaidRules.carryWalkSpeed`, times any trap slow. Too fast (movement budget) or
  too high while carrying, or a Trapdoor, puts the critter back on its pad; the raid goes on.
- `Net.Pushes.RaidEnded` ends every async raid, with `reason`: `"Escaped"` (gate while carrying;
  `escaped` is true only once the loot has moved), `"Timeout"`, `"Tagged"` (a guard),
  `"Retreat"` (gate with nothing), `"Left"`, `"Error"`. The raider is sent back to their den.
  For `"Escaped"` the push comes once escrow answers (`RaidRules.asyncEscapeOutcome`, P1.3b):
  - `escaped = true`: the loot is in the raider's profile. `speciesId` and `glow` are what was
    credited (the raider's `appliedTransfers` entry), never the snapshot's figure. `speciesId` is
    nil when only Glow moved (the critter had left its pad, or the den hit its daily loss cap).
  - `pending = true` (additive, optional): escrow is still delivering, usually because the owner
    is online in another server. It lands on its own and never voids; `speciesId` and `glow` are
    the carried critter and the estimate. Show "on its way"; DenChanged shows the truth.
  - `escaped = false` and no `pending`: nothing moved (Refused). `speciesId` is what was carried,
    `glow` is 0.
- `Net.Requests.GetRaidLog` `() -> { RaidLogEntry }`: the player's own log, newest first.
- Raid code never writes a profile. An escape goes to `RaidService.onAsyncEscape`, which calls
  `EscrowService.transferAsync` (Async kind). The escrow debit writes the defender's shield,
  revenge token, pair count and Incoming log entry (`RaidRules.recordIncoming`). The escrow
  credit writes the raider's Outgoing log entry and pair count (`RaidRules.recordOutgoing`) and,
  on a revenge raid, removes the named revenge token (Escrow invariant 6, P1.3d, D-054), but
  only when something moved. A revenge escape passes the raid's `revengeRaidId` as
  `transferAsync`'s 7th argument.
- StartRaid fails closed when the owner's presence cannot be read (`PresenceUnknown`), and also
  honours, until the den's next snapshot, the shield of an escape this server just completed.

## Replays

Raid replays (`src/Shared/Replay.luau`, pure; `src/Server/Raid/ReplayStore.luau`). A replay never
affects a raid's result: saving runs on its own thread, inside `pcall`, and a failure only warns.
Every async raid is recorded (P1.4b, `Raid/AsyncRaid.luau`): the raider's server position from
the 10 Hz raid tick (so one frame per 0.2 s), plus `Grab` (species id), `Drop` (why), `Trap`
(trap kind), and a closing `Escape`, `Timeout` or `Tag` (`RaidRules.replayEndEvent`). Origin is
the pocket den's floor-top centre and `startedAt` is server time (`workspace:GetServerTimeNow()`)
at entry. Every end, Retreat and Left included, hands it to `ReplayStore.save` (never `saveNow`).

Format version 1, `"R1.<frames>.<events>"`, printable URL-safe base64 plus `~` and `.`:

- One raider track at `Replay.HZ` (5) frames per second; frame `i` is `startedAt + i / 5`.
  Positions are relative to the pocket den origin, quantized to `Replay.QUANTUM` (0.5 studs), so
  every decoded position is within 0.25 studs of the recorded one, with no drift.
- Frames are zigzag varints of the delta from the previous frame (the first from the origin);
  `dy` is written only when non-zero, and `~n` is n frames standing still. A missed server tick
  is interpolated, so the frame index is always time.
- Events: kind `Grab`, `Drop`, `Tag`, `Trap`, `Escape` or `Timeout`, with a frame index and an
  optional arg (`[%w_]`, at most 32 characters: species id, trap kind, guard id).
- Bounded: at most `Replay.MAX_FRAMES` (1000) frames and 64 events. A 3-minute raid is about
  1.8 KB. `Replay.decode` returns nil for anything malformed and never errors.
- A new format bumps `Replay.VERSION` and the prefix. Decoders keep reading every older version
  still inside the 7-day lifetime.

Storage: DataStore `RaidReplays` (the profiles' mode, D-019: in memory under `Memory`).

| Key | Value |
| --- | --- |
| `Replay_<raidId>` | `{ v, raidId, raiderUserId, defenderUserId, startedAt, savedAt, data }`, saved with both userIds as the key's user ids |
| `Index_<raiderUserId>` | `{ [raidId]: savedAt }` of that raider's replays |

- Lifetime: served for 7 days (`Replay.LIFETIME_SECONDS`) after `savedAt`, refused after.
- Cleanup is a lazy per-raider sweep. Each save updates the raider's index first
  (`Replay.indexAfterSave`: drops expired entries and the oldest past 64), then writes the replay,
  then deletes the dropped replays. A failed index write skips the replay, so every stored
  replay is indexed. An expired replay found on a read is deleted too.
- raidId must pass `Replay.isRaidId` (`[%w_-]`, at most `Config.Escrow.maxRaidIdLength`).

`Net.Requests.GetReplay` is `(raidId) -> Net.ReplayPayload?` (`{ raidId, version, raiderUserId,
defenderUserId, startedAt, data }`), limited by `Net.Limits.GetReplay` (3 per 10 s) and one call
at a time per player. Only the raider and the defender named in the stored record (written by the
server from its own raid state) get it; anything else, including a missing, expired or unsaved
replay, returns nil. The client decodes `data` with `Replay.decode`.

## Live loss rules

Live steals only (D-031, amended by D-034, D-036, D-037). They replace the daily count cap for
live steals; async raids keep `Config.Limits.maxLossesPerDay` (D-031). `lossesToday` still
counts every loss, live and async. Values live in `Config.LiveRaid` (table above).

1. **Post-loss safety.** After a live loss, nobody can grab from that den for
   `postLossSafetySeconds`. RaidService keeps the timer in server memory, never persisted. A
   grab is also refused while any carry from that den is under way (carried, or in escrow and
   not settled).
2. **Same-pair limit.** At most `maxStealsPerPairPerDay` live steals per UTC day by one raider
   from one owner, counting the owner's `pairRaidsToday` entry for that raider plus their steals
   still in flight.
3. **Value-based daily protection.** A loss is the stolen critter's `Economy.critterRate` at the
   debit (its mutation, the defender's rebirths, where it sat). The day's **base** is
   `Economy.denRate(defender)` when the first loss's grab was accepted (the record's
   `liveBaseRate`, D-034), or just before its debit when the record has none. The base never
   changes that day. The den is protected while

   `liveLossRateToday >= protectionLossShare × max(liveLossBaseRate, Economy.denRate(den now))`

   and at the escrow debit the `max` also includes the record's `liveBaseRate` (D-037). So:
   - The base is a floor: shrinking the den never lowers the line.
   - Refilling the den (including `Economy.autoPlace`, D-027) raises the line and can lift
     protection; a shrink during a carry cannot make that carry's debit take nothing.
     Protection can switch off and on during the day; only the UTC day roll clears it.
   - The rate is the whole unboosted `denRate`: pads, plus the Vault at
     `Config.Income.vaultMultiplier`. Inventory and Guard count for nothing, and boosts never
     change protection (D-032).
   - The steal that crosses the line lands; nothing after it does while the line holds.
4. **Escrow.** Live steals move critters through `Escrow.luau` via `EscrowService.transferLive`,
   on two profiles loaded in one server (only async debits cross servers, P1.1). The rules are
   checked at the grab and again at the debit. A live debit that takes nothing grants nothing
   (Escrow invariant 5, D-033).

Profile fields, both belonging to `lossDay` and reset to nil when the day rolls
(`RaidRules.resetDailyIfNeeded`, on load and before every debit). Missing means no live loss
today, so the den is not protected; no migration and no `SCHEMA_VERSION` bump, and
`Profile.spec` checks an old save:

| Field | Meaning |
| --- | --- |
| `liveLossBaseRate: number?` | The day's base (rule 3); the protection line's floor |
| `liveLossRateToday: number?` | The summed Glow/s of the critters lost to live steals today |

Pure rules in `RaidRules` (the server always decides):

- `liveProtected(profile, now)`: read-only; true when `lossDay` is today and rule 3's line
  holds, on the profile as it is at the call.
  Used by `canGrabLive` (every hold frame) and RaidService's `LiveProtected` attribute and steal
  prompts (every 0.5 s). A NaN in either field, or in the den's rate, counts as protected; a
  missing field means not protected, however small the den.
- `liveProtectedAtDebit(profile, now, grabRate?)`: the same with `grabRate` (the record's
  `liveBaseRate`) in the `max`. Only `Escrow.debitDefender` calls it, with the targeted critter
  still in the den. A `grabRate` that is not a finite number >= 0 counts as none
  (`Escrow.create` refuses those anyway, via `Escrow.checkLiveBaseRate`).
- `recordLiveLoss(defender, critter, now, grabBaseRate?)`: called by `Escrow.debitDefender` for a
  Live debit that takes a critter, before the critter leaves the profile. On the day's first
  loss it sets the base from `grabBaseRate` when that is a finite number >= 0, else from
  `denRate`; then it adds the critter's rate. Errors if the critter is already gone.
- `liveGrabReadyAt(lastLiveLossAt)` = `lastLiveLossAt + postLossSafetySeconds`, on the input's
  clock.
- `canGrabLive` does not check `maxLossesPerDay`. After `CritterBusy` it refuses with
  `LiveProtected`, then `PairLimit`, then `PostLossSafety` (when `inFlightForOwner > 0`, or when
  `now < liveGrabReadyAt(lastLiveLossAt)`, which also refuses a NaN). `lastLiveLossAt` is an
  optional `LiveGrab` input on `now`'s clock; nil means no loss this server session.

RaidService measures the grab-time base, `Economy.denRate(ownerProfile)`, when it accepts the
grab request (before the hold starts and before `BeingRaidedLive` reaches the owner), and passes
it as `transferLive`'s last argument on every attempt. It shows the state with the display-only
den attributes `LiveProtected` and `LiveGrabReadyAt` (Replicated attributes).

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
| Player | `RaidLogSeenAt` | number | Unix seconds the player last opened their raid log, as of this session's profile load; 0 = never |
| Den Model `Den<plot>` | `Plot` | number | The den's plot index |
| Den Model | `OwnerUserId` | number | Owner's userId; 0 when unowned |
| Den Model | `LockdownUntil` | number | When the current Lockdown ends; absent or past = none active |
| Den Model | `LockdownReadyAt` | number | When the owner can start the next Lockdown; absent or past = ready |
| Den Model | `LiveProtected` | boolean | `RaidRules.liveProtected` for the owner now: no live steals while true. Can flip during the day (D-036); false from the UTC day roll; absent = false |
| Den Model | `LiveGrabReadyAt` | number | When grabs reopen after the den's last live loss (`RaidRules.liveGrabReadyAt`, D-031); absent or past = open |
| Pad Part | `PadIndex` | number | The pad's number |
| Critter Model | `CritterUid`, `SpeciesId`, `Tier` | string | Which critter this model draws |
| Critter Model | `PadIndex`, `OwnerUserId` | number | Where it sits and whose it is |

## Eggs

`Config.Economy.eggMaxTier` is the highest tier a bought egg can hatch. Tiers up to it keep
their `Config.EggOdds` ratios, renormalized to sum to 1 (`Economy.rollTierUpTo`). It was
`"Uncommon"` through Phase 1 (Common 0.6875, Uncommon 0.3125); Phase 2 raised it to `"Mythic"`
(D-003, P2.4), so a bought egg hatches at the published `EggOdds` weights (Common 55%, Uncommon
25%, Rare 12%, Epic 6%, Legendary 1.8%, Mythic 0.2%), tested in `Config.spec`. Secret critters are
event-only and never in `EggOdds`. The rescue egg rolls from its own Common-only table (from
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

## Purchases

P2.8 (decisions D-028, D-029, D-030, D-032, D-061). Nothing sold is random, nothing grants Glow
for Robux, and nothing sells back a stolen critter. Everything is off while
`Config.Flags.purchases` is false.

### Catalog: `Config.Purchases` (additive Config table, D-059)

| Key | Meaning |
| --- | --- |
| `vipBoostsOffline` | `false` (D-061 (2)): VIP's Glow bonus counts online only; the offline gap accrues at 1. `true` pays the gap at the VIP factor on join (never Lantern Night) |
| `autoCollectSeconds` | 30: how often the auto-collect pass banks stored Glow while online |
| `currentEventId` | the event the event pass is sold for; `""` = none, so not offered |
| `passes.<key>` | `{ id, price, robuxLinked, offerRestricted }`: `vip`, `vaultSlot`, `autoCollect`, `raidScout`, `denTheme`, `gearSkin`, `escapeEmote` |
| `products.<key>` | the same plus `kind` (`Economy.PRODUCT_KINDS`: `shield`, `lanternNight`, `eventPass`, `accessory`) and, for accessories, `accessoryId` (a permanent save key in `PlayerProfile.accessories`) |

- `id` 0 = not created in the Creator Dashboard: never offered, granted or checked.
- `robuxLinked`: the item raises or protects Glow. Its effect applies only to a player whose
  PolicyService `ArePaidRandomItemsRestricted` is known `false`; restricted or unknown fails
  closed. For VIP only the Glow bonus is linked (`glowBoostFactor`).
- `offerRestricted`: whether a restricted (or unknown) player is offered it at all. A receipt for
  an item the player may not get answers `NotProcessedYet` and grants nothing.
- Reversing a D-061 default is one value: an item's `robuxLinked` or `offerRestricted`, or
  `vipBoostsOffline`. `Purchases.spec` pins the audit: every Glow-raising item is `robuxLinked`,
  Lantern Night is not offered to restricted players, no product kind is random or grants Glow.

Pure rules (Economy): `purchaseOffered(item, policy)`, `perkActive(item, owns, policy)`
(policy = `{ paidRandomRestricted?, purchasesEnabled }`), `productById(productId)`,
`vaultCapacity(profile, extraVaultSlots?)` and `place(..., isLocked?, extraVaultSlots?)` (the
vault slot pass adds an unsaved slot; a lower capacity never moves a critter out of the Vault),
`extendLanternNight(endsAt, now)` (a purchase extends a running Lantern Night by
`lanternNightSeconds`; the bonus never stacks).

### Glow factor state

`Economy.GlowFactorState` = `{ inputs = { vip, paidRandomRestricted?, lanternNightUntil }, joined }`,
one per player in IncomeService. The factor is derived from the inputs at each moment, never
stored. `Economy.changeGlowInputs` (only called by `IncomeService.setGlowInputs`) accrues at the
old inputs, then applies a change; a bad value fails closed (`vip` false, restriction unknown, no
Lantern Night). `Economy.accrueBoosted`: the first accrue of a newly loaded profile pays the
offline gap at `offlineGlowFactor` (1 at launch) and marks it joined; later ones pay the online
factor, split at `lanternNightUntil` when the period spans it, so Lantern Night ends without a
timer. A new state starts with the restriction unknown, so the factor is 1 until PolicyService
answers. IncomeService does the final accrue in `DataService.onProfileReleasing`.

### ProcessReceipt

`Economy.processReceipt(steps)` orders the steps; PurchaseService supplies them:

1. `Profile.hasReceipt`: a redelivery grants nothing, and answers `PurchaseGranted` only after
   `DataService.saveNow` confirms saved data holding the receipt, else `NotProcessedYet`.
2. May it be granted now (known product, `purchaseOffered`, the grant possible: a shield below
   the stack cap, an event running and its pass not owned, a valid accessory id)? No:
   `NotProcessedYet`, nothing written.
3. `Profile.recordReceipt`: false here is bad input (step 1 caught redeliveries):
   `NotProcessedYet`, nothing granted.
4. The grant, in the same step as the record, no yield between.
5. `DataService.saveNow` confirming `receipts[PurchaseId]` in the saved data, then
   `PurchaseGranted`; a failed save is `NotProcessedYet`.

The player not in the server, the profile not loaded, or an error anywhere: `NotProcessedYet`.
`Purchases.spec` simulates forced shutdowns at every step with redeliveries: each purchase is
granted exactly once.

### Lantern Night announcement

`Net.Pushes.ServerAnnouncement` fired to all clients with kind `"LanternNight"` and payload
`{ buyerUserId: number, buyerName: string (display name), endsAt: number (unix seconds) }` on
every purchase (start or extension). The boost lives in the server's memory; a shutdown ends it.

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
