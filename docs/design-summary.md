# Raid Night — design summary

The full design doc lives in Claude (the "Raid Night — Full Scope" doc). This is the condensed
version agents work from. If the two disagree, the full doc wins; flag the difference.

## The pitch

A steal-and-collect game where your den keeps earning, and keeps getting raided, while you
are offline. A notification tells you who hit you; one tap takes you to their den for revenge.
The bet: keep the proven steal loop exactly as players know it, and add async raids plus
revenge to turn a session game into a habit game.

## Theme

A moonlit town of night critters. Stylized low-poly, dark navy world, saturated neon glows,
chunky UI. Two signature sounds: the den-breach alarm sting and the escape heist jingle.
Art rules: `docs/style-bible.md`. Critters: `src/Shared/Data/Critters.luau`.

## Core loop

Collect critters → den earns Glow (even offline) → raided while away → revenge notification →
raid back or raid others → upgrade den and traps → collect more critters.

- 30 seconds: sneak in, grab a critter (heavier = rarer = slower), dodge traps and guards, get it home.
- 5 minutes: collect, place, 1-3 raids, check revenge list, set defenses. Finishable on a phone.
- Daily: storage fills (8 h cap at level 1), raid log on login, daily hatch, revenge bounty.
- Weekly: a themed night event, new critters, one limited Secret critter, same day every week.

## Systems

- **Den:** 8 dens per server. Pads 6 → 30. Vault: never stealable in async raids, earns 50%.
- **Critters:** 7 tiers, 4 mutations (Shiny ×1.5, Moonlit ×2, Haunted ×3, Golden ×5).
- **Income:** lazy accrual into `stored` (stealable); `collect` banks into `glow` (safe).
- **Live stealing:** grab, carry, owner can tag to drop, 45 s lockdown with cooldown.
- **Defenses:** traps on a grid, critters assigned as guards (earn nothing).
- **Gear:** grapple, smoke bomb, decoy, speed coil, lockpick (live raids only).

## Async raids

Offline den → snapshot saved → matchmaker picks a den of similar power → raid in a pocket den
inside the raider's own server (no teleport) → escape → escrow transfer → revenge notification
→ defender raids back (snapshot, or live in the raider's server).

| Rule | Launch value |
| --- | --- |
| Loot per raid | 1 critter + 25% of stored Glow |
| Vault | Never stealable in async raids |
| Shield after a successful raid | 4 hours |
| Critters lost per day | 3 maximum |
| New-player protection | 48 hours, or den level under 5 |
| Same-pair limit | 2 raids per day |
| Revenge bonus | Ignores shield once, +10% loot |

All values live in `src/Shared/Config.luau`.

## Notifications

One per player per day, opted-in players 13+ only. Send on the first critter lost, naming the
raider and the critter, with launch data that opens the revenge screen. Ask for opt-in after
the player's first successful raid. The in-game raid log is the primary surface; notifications
amplify it.

## Monetization

Protection, convenience, status, social moments. Never ransom. No paid randomness at launch.
Passes: VIP 399, vault slot 199, auto-collect 149, raid scout 249, themes and gear skins.
Products: shield 49, Glow packs, timer skips, event pass 399. Phase 2: paid eggs and Blood
Moon summon with full odds disclosure and PolicyService checks.

## Compliance (non-negotiable)

- No reward-driven media feeds (replays are single clips, no autoplay, no reward for watching).
- Paid random items need on-screen odds and PolicyService gating.
- Player text goes through the text filter.
- Lowest content maturity label: cartoon theft and tagging only.
- Anti-harassment: blocked players never match; report button on every raid log entry.

## Build plan

| Phase | Weeks | Gate |
| --- | --- | --- |
| Prototype: greybox, live stealing, income, 10 critters | 1-3 | Fun with 4 friends; they stay 30+ min |
| Async core: snapshots, matchmaking, pockets, traps, escrow, revenge | 4-7 | Zero dupes in 1,000 simulated raids (`EscrowSimulation.spec`) |
| Vertical slice: 40 critters, onboarding, UI, notifications, passes | 8-11 | Closed test of ~200: day-1 retention 25%+ |
| Soft launch: tune, replays, clip export | 12-14 | Day-1 30%, 2.0 sessions per user, zero dupes |
| Launch + weekly ops | 15+ | — |

## Metrics that matter

Sessions per daily user 2.0+ (the core bet), D1 30%+, D7 12%+, revenge rate 30%+, churn after
first critter lost no more than 5 points above baseline, raid success 45-60%, like ratio 85%+.
