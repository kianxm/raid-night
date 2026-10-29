# Decisions log

Technical decisions made under the playbook's decision policy (section 2), newest first. Kian
can overturn any entry; the orchestrator then turns the reversal into tasks.

### D-063 · 2026-10-29 · C6 follow-ups: who wires remotes, accessories stay with the buyer, gear 0 = not owned
Context: data on #123. Decision: (1) data writes the server handlers and Net remotes for settings
and onboarding (C6b, stacked on C6); onboarding steps advance server-side from real events, the
client may only acknowledge client-only tips. (2) Accessories are owned per player; a worn
accessory is a binding on the owner's profile, so a stolen critter arrives bare and the
accessory stays in the buyer's inventory; nothing in Escrow carries it. (3) Gear level 0 means not
owned; gear is bought and upgraded with Glow (P2.10). (4) Appendix C's free 30-minute shield and
the tutorial den are raid's (new task P2.6r): live steals must respect a new-player window from
createdAt (Config key), and escapes call Profile.countSuccessfulRaid then onSuccessfulRaid.
Why: rule 4 / principle 1 (a stolen purchase is a lost purchase); server authority. Reversible: yes.

### D-062 · 2026-10-29 · Notification state lives in its own DataStore; storage-full sends stay off
Context: P2.7 (#118). Decision: NotificationService keeps last-sent day, pending loss and
opt-in-prompted time in its own `NotificationState_v1` DataStore keyed by user id, not in the
profile, so a raider's server can apply the daily cap for an offline defender without touching
another profile. Only the "first critter lost" notification is on; a storage-full category is
built but switched off in NotificationRules until Kian approves (notification strategy is his).
Why: rule 4 (never write another player's profile), design pillar. Reversible: yes.

### D-061 · 2026-10-29 · P2.8 product defaults while Kian's questions are open
Context: three open product questions (Blocked list) and P2.8 starts tonight. Decision: build
the safe side of each, all behind Config so a reversal is one value: (1) every product that
raises or protects Glow is classified Robux-linked and fails closed (factor 1 / not offered)
for players whose PolicyService info restricts paid random items, until the per-product audit
says otherwise; (2) VIP's 1.5x applies to online earning only, offline accrue stays unboosted
(the playbook's default); (3) Lantern Night is hidden from restricted players and the VIP
description says the Glow bonus isn't available everywhere. Nothing is created in the Creator
Dashboard; product list and prices go to Kian. Why: principle 3 (policy) and 5 (reversible).
Reversible: yes (Config).

### D-060 · 2026-10-29 · Phase 2 Studio checks run on preview/phase2 by temporary sync
Context: merges wait for Kian (D-058), Rojo serves the main checkout. Decision: as D-055, the
integration agent syncs preview/phase2's changed scripts into the open, unsaved edit place for a
single-client pass, restores the originals, saves and publishes nothing, test ids only (D-056).
If Studio MCP doesn't respond, the run goes to Needs Kian. Multi-client checks join the deferred
list. Why: catch runtime errors before morning without touching Kian's checkout. Reversible: yes.

### D-059 · 2026-10-29 · One Phase 2 profile-field batch (C6), owners add remotes in their PRs
Context: settings, onboarding, notifications, gear, purchases and analytics each need saved
state; Profile.luau is data's file. Decision: data adds every Phase 2 profile field in one PR
(C6), all optional with safe defaults, no migration, reviewer at xhigh. Dependent tasks stack on
C6. New remotes, Types and Config tables that a task needs go in that task's own PR (precedent
#100), additive only, mirrored in docs/contracts.md, with a reviewer pass. Why: one schema
review instead of six; tasks don't wait on each other. Reversible: yes (optional fields).

### D-058 · 2026-10-29 · Phase 2 merge path: stacked PRs and preview/phase2
Context: `gh pr merge` is refused again in unattended runs (tried on ledger #116; D-044).
Decision: every PR targets integration; a task that needs another's code stacks on its branch;
the Phase 2 ledger stacks on #116; before the gate the integration agent builds `preview/phase2`
(all PRs merged in order, conflicts resolved, checks green, no PR). Kian merges. Why: work
continues without a merge; the preview proves the stack. Reversible: yes.

### D-057 · 2026-10-29 · Phase 2 runs on placeholder art and sound
Context: no Higgsfield credits (Kian). Decision: P2.1 and P2.11 generation are Blocked; P2.2
writes briefs and prompts only. P2.3 and P2.4 no longer wait on art: they build a seam that loads
an asset id per piece/species when one exists in `assets/clean/<id>/ids.json` (or a Config/data
table) and falls back to today's procedural placeholders, so real models drop in with no code
change. Sound hooks ship with empty ids (no sound plays) in P2.5. Asset Gates 1-2 happen when
credits return. Why: everything but the art can be finished and tested now. Reversible: yes.

### D-056 · 2026-10-29 · Studio test sessions write test-id keys to the place's DataStores (amends D-019)
Context: the soak needs forced shutdowns in DataStore mode, which only accepted a real loaded
raider, so the overnight run used Kian's account (D-055). Decision: in Studio only (IsStudio +
`ServerStorage.StudioTestSessions` + test id <= -1,000,000 + DataStore mode), DataService can hold
a real ProfileStore session for a test id; escrow recovers it like a player. Escrow writes leave
negative ids out of UserIds. Test raids use test ids against test ids only. Delete the
`Player_-100000x`, `Escrow_soak-*` and `Open_-100000x` keys after a soak. Why: soak without real
accounts. Reviewer approved (#112). Reversible: yes.

### D-055 · 2026-10-29 · Studio check of preview/phase1 by temporary script sync
Context: no Phase 1 server code had run in Roblox, and merges wait for Kian (D-044). Decision: the
integration agent synced preview/phase1's 27 changed scripts into the open, unsaved edit place
(HttpEnabled on temporarily), recorded originals, and restored them afterwards; Rojo and the main
checkout untouched, nothing saved or published. Outcome: groups A and B1 passed; the Studio MCP
play control wedged after the first forced stop, so the rest is unrun. One deviation: the test
transfer used Kian's real account as the raider (Studio DataStore, not a live game); left Pending
and recorded under Needs Kian. Why: catch runtime errors before morning. Reversible: yes.

### D-054 · 2026-10-29 · One revenge raid per token
Context: data on #109: "spending" a token only marked its shield bypass used, so a second +10%
revenge raid stayed possible within the pair limit. Decision: an Async credit that moves
something removes the named revenge token; a failed or empty revenge raid keeps it. Live revenge
still doesn't spend (D-052). Why: revenge is one answer to one raid; the bonus can't be farmed.
Reversible: yes (one line).

### D-053 · 2026-10-29 · Failed raids don't count toward the pair limit; raider-side commit is core
Context: raid on #106. Decision: only an escape that moves something counts toward the same-pair
daily limit (as live steals); timeout, tag and retreat don't. The raider-side raid-log entry, the
raider's pair count and the async revenge-token spend are P1.3's own done-when ("logs on both
sides"), so data adds them to the raider credit now (P1.3d), applied once per raidId and never on
an empty commit. Why: a failed raid takes nothing from the defender (shield and loss cap still
apply); a revenge loop that never spends its token isn't the designed loop. Reversible: yes.

### D-052 · 2026-10-29 · Live revenge token spend waits for the playtest
Context: raid on #105. Live revenge escapes as a revenge transfer, but transferLive can't name the
token to spend, so the token stays after a live revenge commits. Decision: hardening backlog, not
a new escrow contract tonight. Repeat revenges against the same raider stay limited by the live
pair limit (2/day) and token expiry; nothing is duplicated or lost. Why: D-039 pre-playtest
scope; the playtest shows whether repeat revenge matters. Reversible: yes.

### D-051 · 2026-10-29 · Raid UI refusal and revenge-join details
Context: ui on #102. Decision: the client doesn't check Config.Flags itself; any refused
StartRaid shows "Can't raid that den now" (no distinct "raids are off" copy until the server
returns a reason). On a retryable live-join failure the UI offers "Raid their den instead"
rather than starting the async raid automatically. The block list comes from
StarterGui:GetCore("GetBlockedUserIds") plus the block/unblock core events (the documented
client route). Why: the server stays the only judge; the player chooses the fallback.
Reversible: yes.

### D-050 · 2026-10-29 · Async raid details (P1.3a)
Context: raid on #100/#101. Decision: (1) MatchmakingService.noteRaided runs on escape with the
snapshot's power, not at StartRaid, so a failed raid doesn't hide a den for 4 h; (2) reaching the
gate without a critter ends the raid and takes nothing (no walk-in, walk-out Glow); (3) guard and
trap tuning lives in RaidRules.Pocket until it moves to Config (as D-021); (4) raidLogSeenAt is
an optional Profile field written by the server when GetRaidLog is called (no migration). Why:
fairness to the defender and simplest thing for the gate. Reversible: yes.

### D-049 · 2026-10-29 · Escrow fix round on #97/#98; asyncRaids waits for old servers to die
Context: reviewer APPROVED #97 and #98 at xhigh with suggestions. Decision: one fix round for the
two Glow dupe/loss-adjacent items (a stale session's same-second debit writing its loot into the
record; one sweep error stopping recovery) plus cheap lines in the same round (Refused instead of
InFlight when nothing was written; Escrow.void refuses Async; a spec for accrue-inside-the-write).
asyncRaids is turned on only after every pre-P1.1 server has shut down, because old servers void
Pending records of any kind. Other suggestions go to the hardening backlog. Why: principle 1;
the rest fails safe. Reversible: yes.

### D-048 · 2026-10-29 · Replay fetch limit and 7-day cleanup
Context: raid on #99. Decision: GetReplay is limited to 3 per 10 s; DataStores have no expiry, so
each raider keeps an index of their replays and every new save deletes their expired ones and
any beyond 64; a save whose index write fails is skipped, and reads refuse replays older than
7 days. Why: replays are a nice-to-have that must never cost raid results or DataStore budget.
Reviewer approved. Reversible: yes.

### D-047 · 2026-10-29 · Async escrow records are never voided; cleanup deferred
Context: data on #97/#98. Decision: close D-012 #6 by never voiding Async records (any server may
redeliver the debit; it applies once per raidId) instead of a void tombstone. Deleting finished
escrow records (D-008) moves to the hardening backlog (storage growth only). Async debits accrue
the defender's offline income to debit time, take the loot share of what's stored then, and
credit the raider exactly that. asyncRaids turns on only in a deploy after P1.1 ships. Why: an
escaped raid always completes, with no void race (principle 1). Reviewer checks idempotency.
Reversible: yes.

### D-046 · 2026-10-29 · P1.3 and P1.4 split so they start before P1.1 lands
Context: P1.1 (escrow) is the long pole; most of P1.3 and P1.4 doesn't touch escrow. Decision:
P1.3a builds StartRaid (lock, flags, block and presence re-checks), the pocket den, traps,
guards, timer and server grabs from integration, ending at one named escape hook; P1.3b wires
that hook to EscrowService (transfer, shield, revenge token, logs), stacked on P1.1. P1.4a
writes the replay codec and store in new files; P1.4b records during raids after P1.3. Why:
fills the idle slots without two agents editing one file. Reversible: yes (process).

### D-045 · 2026-10-29 · P1.7 tuning waits for Kian; P1.8 prepared
Context: economy on #95 proposes upgradeCostBase 100→500, eggPriceBase 50→150, eggPriceGrowth
1.12→1.32. Each serves a quoted design target, but no design-doc numeric range covers them and
they set a first-rebirth pace (~3 weeks) the design never defines. Decision: not approved under
D-041; P1.8 applies the values in a stacked PR that merges only if Kian approves. Async loot
reading leave-time stored Glow is a bug, not tuning: sent to P1.1 (debit accrues to debit time).
Why: pacing is a product call; the PR makes it a one-click approval. Reversible: yes.

### D-044 · 2026-10-29 · Merges wait for Kian; dependent work stacks on PR branches
Context: from #92 on, the session's permission check refuses every `gh pr merge` ("Merge
Without Review"), even after a reviewer pass and for docs-only ledger PRs. Decision: no merge is
worked around. A task whose dependency is an open PR branches from that PR's branch and targets
it (stacked PR); Phase 1's chain is linear (P1.1 → P1.3 → P1.4/P1.6, P1.7 → P1.8), so no
combining merges are needed. Checks and reviews run on the PR branches. Studio runs for unmerged
code wait until Kian merges, because Rojo serves the main checkout on `integration`. Ledger
updates stay on the open ledger PR. Kian merges in the order listed in the gate report.
Why: respect the permission boundary and still finish the code. Reversible: yes (process).

### D-043 · 2026-10-29 · Only offline dens are async raid targets
Context: matchmaking on #91. Decision: GetRaidTargets lists a den as an async target only while
its owner is offline (presence absent); online owners are raided live in their own server. A
Studio-only hook may skip the asyncRaids flag for playtests (IsStudio + Memory persistence +
test ids); live remotes always respect Config.Flags. Why: one den is never raided live and async
at once; the hook can't reach a live game. Reviewer approved. Reversible: yes.

### D-042 · 2026-10-29 · P1.2 runs alongside P1.1; tools/sim goes to economy
Context: P1.2 lists P1.1 as a dependency, but snapshots, pools, locks and presence live in
matchmaking's own files and only read DataService as it is. Decision: start P1.2 in parallel
with P1.1; it must not depend on new P1.1 code. P1.3 still waits for both. `tools/sim/**` is
owned by economy (P1.7). Why: P1.1 is the critical path; this fills the fourth slot without
sharing files. Reversible: yes (process).

### D-041 · 2026-10-29 · Phase 1 runs unattended overnight (Kian)
Context: Kian started Phase 1 and is away overnight. Decision: the orchestrator makes every
technical call under the decision policy and logs it here. Steps that need a human or a live
environment (multi-client or two-server runs, a private publish, Creator Dashboard) are skipped
and listed under "Needs Kian" in the gate report; ready tasks keep running. P1.7's tuning stop is
approved by the orchestrator when every proposed value sits inside the design doc's ranges
(Config only, reversible); anything outside them waits for Kian. Irreversible choices that could
go either way are prepared, not taken. Why: keep the phase moving without crossing Kian's
decisions. Reversible: yes (Kian can overturn any entry at the gate).

### D-039 · 2026-10-29 · Process speed-ups (Kian)
Context: ~24 h of Phase 0 produced 77 PRs, 25 of them ledger-only; the live-protection chain
(P0.5g to C5, ~3,200 lines, D-033 to D-037) was reviewer rounds on edge cases that lose nothing,
before any multiplayer playtest. Decision: (1) pre-playtest scope: until a phase's human
playtest, fix only duplication or loss, client trust and policy; other exploit or fairness edge
cases go to the hardening backlog in progress.md. Principle 6 now means "a few lines in an open
PR". (2) Reviewer severity bar: only those classes, or a broken change, block; suggestions never
start a fix round; re-reviews check only earlier blockers; one fix round per PR unless it's a loss
path; no review for UI, copy, assets or docs-only PRs. (3) Effort: `reviewer` and `data` default to
high, spawned at xhigh only for Escrow, Profile, DataService, EscrowService or purchases. (4) One
ledger PR per merge wave, auto-merged. (5) PRs up to ~800 lines when they must be reviewed as one
unit. (6) Studio once per merge wave, single client; escrow and profile PRs still get their own
run. (7) contracts.md keeps rules, not reasons; agents read only the sections they touch. Why:
same safety on the risky code, much less churn everywhere else. Reversible: yes (process).

### D-038 · 2026-10-28 · Critter personalities and the three-animation set (Kian)
Context: art direction change before Asset Gate 1 (no concept images generated yet). Decision:
every critter has a distinct personality expression that still reads as cute; Commons simple and
cheerful, Rare and above more attitude; never sad, crying, injured or frightened. New required
`CritterSpecies.personality` (one or two words, at most 6 share one), assigned for all 40 and
checked by `CritterCatalog.validate`; every prompt gets a tier-aware expression line and AVOID
names distressed expressions. Each critter animates a happy den idle, a sneaky carried walk and
a gotcha pose when stolen; base art keeps one expression. Three idle lines that read as fear
(crumb_rat, mirror_cat, abyss_angler "panics"/"startles") were reworded. Why: a style decision
inside the approved direction (0006). Reversible: yes (static design data; no persisted change).

### D-037 · 2026-10-28 · The live debit also counts the grab-time rate
Context: data on #79: after a refill reopens a den (D-036), the owner, alerted at carry start,
could shrink it mid-carry so the debit sees protection and takes nothing. Decision: at the
escrow debit, protection is measured against max(liveLossBaseRate, current denRate, the record's
liveBaseRate when finite and >= 0); grabs, the den attribute and prompts are unchanged. Why:
every accepted carry lands, which keeps D-034's intent (principle 6). Reviewer approved.
Reversible: yes.

### D-036 · 2026-10-28 · Live protection measures against max(base, current den rate) (Kian)
Context: data on #73, reviewer on #73/#71: D-034 doesn't stop a planned shrink (empty the den
but one Common, lose it to an alt or after a dropped carry, refill: a day of live protection).
Decision: option (b). A den is live-protected only while today's live losses reach
protectionLossShare of max(liveLossBaseRate, Economy.denRate(den now)). Refilling the den lifts
protection; a real loss still protects (the den's rate drops with it). Applies everywhere
liveProtected is used (grab, escrow debit, den attribute). Scheduled as C5 (data); reviewer pass.
Reversible: yes.

### D-035 · 2026-10-28 · Grab refusal reasons stay unshown in Phase 0
Context: ui on #70: the refusal copy for LiveProtected / PostLossSafety is built and tested, but
no remote delivers a grab refusal reason to the client (GrabCritter has no reply). Decision: no
new Net push now; the den markers ("Protected today", "Safe for m:ss") already explain the two
new refusals, and the deferred list already asks testers whether refusals need a message. If
they do, add a `GrabRefused` push (Net + contracts.md + reviewer) and hook the existing copy.
Why: principle 7, and a contract change for copy the testers may not need. Reversible: yes.

### D-034 · 2026-10-28 · Live protection base is the den's rate at the grab (Kian)
Context: reviewer on #64: measured at the first live debit, the base can be shrunk during the
carry (the owner is alerted at the grab and can move high earners to Inventory/Vault), buying
full-day protection with one cheap loss. Decision: option (b). The base is Economy.denRate of
the den at the moment of the grab, before the owner can be alerted. Orchestrator details:
RaidService measures it when the grab is accepted (the earliest server event the owner can see),
keeps it with the carry and passes it to EscrowService.transferLive; the Live EscrowRecord gains
optional `liveBaseRate: number?`, set at create and never changed (retries pass the same value),
finite and >= 0 or refused at create. At the debit, the day's first live loss uses the record's
liveBaseRate; a record without it (older records, async) falls back to denRate at the debit.
Reviewer pass (contract). Reversible: yes (optional field).

### D-033 · 2026-10-28 · Empty live commits grant nothing
Context: reviewer on #65. Decision: when a live debit takes nothing (den protected) and Glow is
0, still write the appliedTransfers entry (idempotency), but skip the defender's shield, revenge
token, pairRaidsToday increment and "escaped" raid-log entry. Pin it in the simulation. Why: an
empty steal must not use up the raider's pair slot or hand the defender rewards (principle 4).
Rare after D-031 (grabs refuse protected dens and in-flight carries). Reversible: yes.

### D-032 · 2026-10-28 · Robux-linked multiplier mechanics
Context: reviewer on #59. Decisions: (1) the multiplier is pure (Economy.glowBoostFactor) and
fails closed: unknown PolicyService result = restricted; (2) kill switch: Robux-linked
multipliers apply only while Config.Flags.purchases is on; (3) earned = species rate × mutation
× placement × rebirth × (1 + applicable Config.Boosts bonuses), applied through accrue's factor;
(4) the storage cap uses the unboosted rate, so a boost ending never leaves stored Glow above the
cap; (5) accrue at the old factor before the factor changes (boost start/end, VIP ownership or
policy result arriving, joining/leaving a boosted server); (6) the restriction flag, VIP
ownership and Lantern Night state come only from the server. Open product/policy questions for
Kian are in docs/progress.md Blocked. Reversible: yes.

### D-031 · 2026-10-28 · Live loss rules: value-based daily protection (Kian)
Decision (replaces the count-based cap for live steals): (1) after a live loss the den can't be
grabbed from for 60 s (Config.LiveRaid.postLossSafetySeconds); (2) live same-pair limit 2 per day
(maxStealsPerPairPerDay); (3) daily live protection is value-based: when today's live losses
reach 50% (protectionLossShare) of the den's Glow per second, measured at its first live loss of
the day, the den is protected for the rest of the UTC day; optional profile fields
liveLossBaseRate and liveLossRateToday, reset daily, no migration; (4) live steals move critters
through Escrow.luau on the two in-server profiles until P1.1. All values in Config, server-
enforced, display-only attributes, reviewer pass. Scheduled as part of P0.5 (P0.5g data, P0.5h
raid, P0.5i ui). Phase 3 tuning item P3.9 (churn after first loss, raid success rate, like
ratio). Kit question added: "Did you chase the thief after being robbed?".
Orchestrator details: applies to live steals only; async keeps maxLossesPerDay until Phase 1;
loss value = the stolen critter's Glow/s (Economy.critterRate) at debit; enforced at grab (also
refused while a carry from that den is in flight) and again at escrow debit (EscrowRecord gains
optional kind, missing = Live); the 60 s timer is server memory (live steals are same-server).
Reversible: yes.

### D-030 · 2026-10-28 · Robux-linked Glow multipliers are off for policy-restricted players (Kian)
Decision: Lantern Night stays a Glow multiplier. All Robux-bought Glow multipliers (VIP 1.5×
and Lantern Night) are Robux-linked. For a player whose PolicyService info restricts paid
random items, they never apply: VIP keeps its non-Glow perks, and other players' Lantern Nights
don't boost them, so their Glow stays earn-only and eggs stay purchasable. Egg odds are shown
everywhere. Both products stay gated on the reviewer policy audit and the PolicyService check
in P2.8. Amends D-028. Orchestrator details: boosts multiply the rebirth-adjusted rate (earned =
base × rebirth × (1 + applicable bonuses)); the bonuses stack additively (VIP +50% and Lantern
Night +50% = 2.0×), values in Config.Boosts; pure multiplier logic tested per policy flag
(C2, P0.12). Reversible: yes.

### D-029 · 2026-10-28 · Three more launch products, no randomness (Kian)
Decision: add to the launch catalog (design-summary, PurchaseService): server boost "Lantern
Night" (99-199 Robux, +50% Glow earned server-wide for 15 min, buyer announced; the open policy
check below is answered by D-030), critter
accessories (25-149, direct sale, cosmetic only), escape emotes (pass, 49-149). No randomness.
Open policy check (orchestrator flag): Lantern Night sells extra Glow earning for Robux while
Glow buys random eggs (D-028's reason for earn-only Glow); it ships only after a reviewer policy
audit and PolicyService checks in P2.8. Accessories and emotes never change stats. Prices are
ranges until the Phase 3 price tests. Reversible: yes.

### D-028 · 2026-10-28 · Glow is earn-only at launch; egg odds on screen from Phase 0 (Kian)
Decision: no Glow packs at launch; no product grants Glow for Robux. Glow packs move to the
Phase 2 paid-randomness mini-phase, shipped with PolicyService region checks and a reviewer
audit. Egg odds are shown on screen for every egg from Phase 0, read from Config.EggOdds after
the eggMaxTier renormalization (rescue egg: Common 100%). Updated design-summary, decision
0005, contracts.md, playbook, PurchaseService header. Why: Glow buys eggs, so selling Glow would
make eggs paid random items (CLAUDE.md rule 6). Reversible: yes, in the Phase 2 mini-phase.
Amended by D-030: Robux-bought Glow multipliers (VIP 1.5×, Lantern Night) are allowed but never
apply to players whose PolicyService info restricts paid random items.

### D-027 · 2026-10-28 · Phase 0: Inventory critters auto-fill free pads; fix steal feedback before the gate
Context: the P0.8 Studio pass found stolen critters (and eggs bought with full pads) land in
Inventory, which has no UI in Phase 0 (#43), and the raider sees no steal result (#41).
Decision: Economy.autoPlace moves Inventory critters onto free usable pads (oldest first; never
Vault, never locked, never displacing) on every den push; the HUD toasts RaidEnded. Both are
fixed before the gate because the gate asks whether stealing is fun. Revisit auto-place when
P2.5 adds an inventory UI. #42 (test-hook Lockdown state survives clear) is test-only and
deferred. Reversible: yes.

### D-026 · 2026-10-28 · Small escrow/data follow-ups go to P1.1
Decision: the #38 reviewer suggestions (a source guard that raw memory/DataStore access only
appears in read/update; pcall the storage() call in transferLive; "DataService not started"
error text), recovery refreshing the raider's HUD when a late InFlight commits, and the rebirth
lock check (applyRebirth must skip or refuse locked critters when rebirth is wired) are
recorded as P1.1 TODOs, not more Phase 0 rounds. Why: none is reachable in Phase 0; simplest
thing that passes the gate. Reversible: yes.

### D-025 · 2026-10-28 · Carry anti-cheat: lag-tolerant budget
Decision: keep the 1 s freeze rule (phone lag must not drop honest carriers) instead of capping
the budget below the 12-stud den gap. Guarantee: over any window a carrier moves at most
(v + 2) + refill·v·T studs (moveRefill lowered to 1.1); an escape needs an earlier sample on the
street, and that flag resets whenever the carrier is back inside the defender's den; carriers
above 16 studs drop; tags use X/Z distance; Lockdown push-backs shift the carry's last position
by the server's push so nothing the client moved is forgiven. Reviewer-checked. Reversible: yes.

### D-024 · 2026-10-28 · P0.4c runs as a third agent briefly
Decision: the ~20-line swap fix (reviewer B2 on #29) runs alongside the raid fix round and
P0.5e, above Phase 0's parallelism of 2. Why: it gates the #29 merge and is tiny.

### D-023 · 2026-10-28 · Rescue-egg critters stay stealable live
Context: reviewer on P0.5 (steal → free rescue egg → steal loop). Decision: untradeable means
no trading or gifting (D-005); live steals may take rescue critters. The loop is capped by
maxLossesPerDay and the same-pair limit (D-022). Kian may overturn. Reversible: yes.

### D-022 · 2026-10-28 · Same-pair limit and in-flight count for live grabs
Decision: live grabs refuse when the owner's lossesToday + carries in flight reach the daily
cap, and when the raider/owner pair is at maxRaidsPerPairPerDay (with in-flight). Shield and
new-player protection stay async-only in Phase 0; a short live grace for new players moves to
Phase 2 onboarding (P2.6). Why: stops one player taking all of a victim's losses in minutes
(principle 4). Reversible: yes.

### D-021 · 2026-10-28 · Movement-budget values stay in RaidRules for Phase 0
Decision: the carry anti-speed budget parameters live in RaidRules.Live until the next contract
batch moves them to Config.LiveRaid; grabRange moves now (D-018). Reversible: yes.

### D-020 · 2026-10-28 · Live steals report through RaidEnded
Decision: when a carry ends, the raider gets Net.Pushes.RaidEnded { raidId (escrow id, or ""
for a drop), escaped = Committed only, speciesId, glow 0 }. No new remote. Why: the raider
needs to know if a steal worked; reuses an existing contract. Reversible: yes.

### D-019 (revised 2026-10-28) · Studio-only test profiles, Memory persistence only
Revision after the reviewer's B4 on #32: test profiles are allowed only when the whole server
runs in Memory persistence (Studio-only switch to ProfileStore's mock store), with reserved ids
<= -1_000_000 (Studio's Local Server players use -1, -2, ...). The earlier "escrow in memory for
negative ids while API access is on" would have saved a real profile pointing at a memory-only
record. Original entry below.

### D-019 · 2026-10-28 · Studio-only test profiles; test escrow never persists
Decision: DataService.loadTestProfile/releaseTestProfile work only in Studio and only for
userId <= 0, in memory; any escrow with a party userId <= 0 keeps its record and index in
memory, even with Studio API access on. Why: single-client testing of the full steal path
(D-010) without fake data ever reaching a DataStore (principle 1). Reversible: yes.

### D-018 · 2026-10-28 · Grab range in Config
Decision: Config.LiveRaid.grabRange = 10 studs (was a RaidRules constant). Why: tuning knobs
live in Config (principle 5). Reversible: yes.

### D-016 · 2026-10-28 · DenState.eggCost deferred to the Phase 2 UI pass
Context: economy proposed adding eggCost to Net.DenState so the HUD stops mirroring the rescue
rule. Decision: defer to P2.5. The client copy is display-only and matches the server after
P0.4b; a three-lane contract change is not worth it for the Phase 0 gate. Reversible: yes.

### D-015 · 2026-10-28 · Phase 0 live steals take the critter only
Decision: transferLive glowRequested = 0 for live steals in Phase 0; stored Glow is only taken by
async raids (Phase 1). Why: simplest loop for the "is stealing fun" gate. Reversible: yes.

### D-014 · 2026-10-28 · P0.5 does not wait on P0.4b
Decision: start P0.5 right after C1. P0.5 identifies critters from the defender's profile and
server pad positions, never model attributes, so the IncomeService cleanup in P0.4b is not a
prerequisite. Why: critical path. Reversible: n/a.

### D-013 · 2026-10-28 · Lockdown blocks revenge raiders too
Context: reviewer on #22. Decision: an active Lockdown blocks entry for every live raider,
revenge included. Why: revenge skipping a shield does not mean skipping the owner's active
defense; one simple rule. Reversible: yes.

### D-012 · 2026-10-28 · #11 re-review suggestions done now, in P0.3a
Context: reviewer approved #11 with 7 non-blocking suggestions. Decision: do 1-5 and 7 in P0.3a
(index timestamp refresh on re-add, prove session ownership before voiding, retry party from
the record, per-call create nonce, identical-arguments retry rule, test gaps); record 6 (async
debits by message will race the void rule; EscrowRecord has no kind) as a P1.1 TODO. Why:
principle 6, cheap to close now. Reversible: yes.

### D-011 · 2026-10-28 · Lockdown cooldown counts from the end
Decision: LockdownReadyAt = LockdownUntil + lockdownCooldownSeconds, so a den is locked at most
45 s in every 165 s. Why: fair to raiders (principle 4); lockdowns cannot be chained.
Reversible: yes (Config + one formula).

### D-010 · 2026-10-28 · Multi-client testing deferred; single-client harness for P0.5
Context: Kian has no testers now and will test with people once, at the end. Decision: keep all
multi-client checks in one deferred list in docs/progress.md; P0.5 ships a Studio-only test
hook (guarded by RunService:IsStudio()) that seeds a dummy defender den so one client can
exercise grab, carry, tag, escape, lockdown and the escrow handoff. Why: keep verifying as we go
without needing people. Reversible: yes.

### D-009 · 2026-10-28 · C1 runs in parallel with the P0.3b fix round
Context: C1 was queued behind #11 only to avoid edit conflicts in Types, Config and
contracts.md. Decision: start C1 now with a second data agent; it stays out of Escrow,
EscrowService and DataService and keeps its edits in separate spots; whichever merges second
rebases. Why: C1 is on the critical path to P0.5. Reversible: yes.

### D-008 · 2026-10-28 · Deferred to Phase 1: escrow GDPR ids and record cleanup
Context: reviewer suggestions on PR #11. Decision: return userIds from escrow UpdateAsync
transforms for erasure tooling, and clean up terminal escrow records, in Phase 1 (P1.1).
Why: no async raids or real players yet; simplest thing that passes the Phase 0 gate.
Reversible: yes.

### D-007 · 2026-10-28 · Escrow open-index becomes a contract; raidId length in Config
Context: reviewer on PR #11. Decision: `Types.EscrowOpenIndex` for `Open_<userId>` values,
indexing both raider and defender; `Config.Escrow.maxRaidIdLength`. Pruning of
`appliedTransfers` never removes an entry whose raidId is still open; a defender's load settles
their own Pending live records (debited → record Debited; not debited → Voided).
Why: the reviewer showed loss and duplication paths when a 7-day prune met an open escrow
(principle 1). Reversible: yes (additive type, Config value).

### D-006 · 2026-10-28 · PR size exceptions for escrow
Context: PR #11 is ~700 lines. Decision: accept; EscrowService must be reviewed as one unit.
Fix rounds may split the simulation extension into a stacked PR. Reversible: n/a.

### D-005 · 2026-10-28 · Critter.untradeable (Kian)
Decision: optional `untradeable: boolean?` on Critter, missing = tradeable, no migration. Set on
rescue-egg critters; survives escrow transfer. Any future trading or gifting code must refuse
it (reviewer checks). Reversible: yes (optional field).

### D-004 · 2026-10-28 · Rescue egg kept, with guards (Kian)
Decision: a free egg when a player owns no critters and banked + stored Glow (after accruing)
is below the egg price. Rolls from a fixed Common-only table, independent of `eggMaxTier`.
Reversible: yes.

### D-003 · 2026-10-28 · Live-stealing contract batch (Kian)
Decision: Net request `Lockdown` () -> boolean, limit 3 per 10 s. Display-only attributes
`CarryingUid`, `CarryingSpecies` (Player) and `LockdownUntil`, `LockdownReadyAt` (den); the
server keeps its own state and never reads them. `Config.LiveRaid` {lockdownSeconds 45,
lockdownCooldownSeconds 120, tagRange 6, grabHoldSeconds 1}. Lockdown blocks entry only
(raiders inside can leave; a carried critter drops at the border), live raids only,
server-enforced. `Config.Economy.eggMaxTier = "Uncommon"`, renormalized odds; Phase 2 raises it
to Mythic. Reversible: yes (Config).

### D-002 · 2026-10-28 · raids is the master kill switch (Kian)
Context: reviewer S2 on PR #2. Decision: any raid (live, async, revenge) needs `raids`; async
and revenge (including live revenge) also need `asyncRaids`; unknown kinds refused. Switches
block new raids only; escrow recovery and in-flight transfers always complete. Why: one flip
stops all theft during an incident. Reversible: yes (Config).

### D-001 · 2026-10-28 · Ledger edits happen in a worktree
Context: switching branches in the main checkout made Kian's `rojo serve` sync stale code into
Studio. Decision: orchestrator commits go through a worktree, never the main checkout.
Reversible: yes.
