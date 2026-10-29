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
| Open escrows per raider | `{ [raidId]: createdAt }` | EscrowService | Recovery index; added before the record, removed once terminal |

Escrow storage: DataStore `EscrowRecords`, keys `Escrow_<raidId>` (raidId at most 43 characters)
and `Open_<raiderUserId>`. Forward-only is enforced by `Escrow.canReplace` inside every
`UpdateAsync`. In Studio without API access (`DataService.persistence() == "Memory"`) both live
in server memory, like profiles do.

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

If you change `Escrow.luau`, `RaidRules.recordIncoming` or anything in `appliedTransfers`, the
simulation must still pass, and the `reviewer` agent must sign off.

## Kill switches

`Config.Flags` holds one boolean per feature. `false` turns the feature off everywhere. Services
read `Config.Flags.<name>` directly and check it before acting on a request. Raid and transfer
starts go through the pure `Escrow.canStartTransfer(Config.Flags, kind, isRevenge)`, which
EscrowService and RaidService both call.

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
Raid semantics approved by Kian 2026-10-28 (relayed by the orchestrator in P0.3b).

Defaults turn on only the features that exist. Adding a flag is a contract change.

## Schema changes

1. Add the field with a default in `Profile.new`.
2. Add `migrations[n]` in `Profile.luau` and bump `Config.SCHEMA_VERSION`.
3. Add a test that migrates an old-shape profile.
4. Never remove or rename a persisted field without a migration.
