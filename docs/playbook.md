# Raid Night playbook

From day 0 to launch and weekly live ops. Put this file at `docs/playbook.md`.

**How it works:** you tell Claude Code `Run Phase N from docs/playbook.md`. The orchestrator
reads this file and the progress ledger, dispatches agents in parallel, loops every task
through tests, review and merge until the phase's exit checks pass, then **stops at a human
gate** with a report. You decide; then you run the next phase.

```
You: "Run Phase N"  ──▶  orchestrator loop (autonomous)  ──▶  exit checks pass  ──▶  HUMAN GATE  ──▶  You: "Run Phase N+1"
```

---

## 1. Kickoff prompt (paste into Claude Code at the repo root)

> You are the orchestrator for Raid Night. Read CLAUDE.md, docs/playbook.md and
> docs/progress.md (create it from section 3 if missing). Run **Phase N** exactly as section 2
> describes: dispatch ready tasks to their agents in parallel, drive each through its done
> checks, review and merge, keep docs/progress.md current, and stop at the phase's human gate
> with the gate report. Make technical decisions yourself under the decision policy in
> section 2, logging each one in docs/decisions-log.md. Only stop me for the items the policy
> lists under "Ask Kian" and at human gates.

To resume after any interruption, paste the same prompt. The ledger makes it restartable.

---

## 2. The orchestrator loop

Repeat until every task in the phase is `Done`:

1. **Read state.** Load `docs/progress.md`. A task is _ready_ when its status is `Todo` and
   every task in its `Depends` column is `Done`.
2. **Dispatch.** Start up to **4** ready tasks at once, each as its named subagent
   (`.claude/agents/<agent>.md`) in its own git worktree, branch `agent/<agent>/<task-id>`.
   Give it the task prompt from this file, prefixed with the template in section 4.
   Mark it `In progress` with the branch name.
3. **Check.** When an agent reports done, verify its **Done when** list yourself:
   `lune run tests/run.luau`, `stylua --check src tests tools`, `selene src`, and
   `luau-analyze src/Shared/*.luau src/Shared/Data/*.luau`, plus the task's own checks.
4. **Review.** If the task touches contracts, `Escrow.luau`, `Profile.luau`, persistence or
   purchases, run the `reviewer` subagent. Blocking findings go back to the same agent.
5. **Integrate.** Hand passing PRs to the `integration` agent: merge into `integration`,
   rerun tests, sync with Rojo, playtest in Studio per the PR's plan. Only the integration
   agent drives Studio. Merge one PR at a time.
6. **Record.** Update the ledger: `Done` with the PR link, or back to `Todo` with the reason.
7. **Decide or escalate.** When an agent raises a question (including a contract change),
   apply the decision policy below. Decide it yourself if you can, log it, and unblock.
   Escalate only "Ask Kian" items, or a task that fails its checks **3 times** after you
   changed approach: mark it `Blocked`, write the question in the ledger, and keep running
   tasks that do not depend on it. If nothing can run, stop and report.

When all tasks are `Done`: run the phase's **Exit checks**. If they pass, stop and post the
**Gate report** (section 5). If they fail, create fix tasks, add them to the ledger, and loop.

### Hard rules for the orchestrator

- Never cross a human gate, even if every check is green.
- Contract changes (`Types.luau`, `Net.luau`, `Config.luau` shape, `Profile.luau` schema) are
  yours to approve under the decision policy: batch them, have the `data` agent apply them,
  require a `reviewer` pass, update docs/contracts.md, then unblock dependents.
- Never spend credits beyond the phase budget, buy ads, publish publicly, change prices on a
  live game, or touch a live place.
- Keep PRs under ~400 changed lines; split bigger tasks.
- If the escrow simulation ever fails on `integration`, stop everything else and fix it first.

### Decision policy

You are the technical decision-maker. Kian is the product owner. Decide like a senior engineer
who has read the design doc, and write down why.

**Decide yourself (then log):**

- Implementation, architecture, data shapes, remotes, Config shape and values within the
  design doc's ranges, schema changes that ship with a migration and tests
- Anti-exploit, rate limits, server authority, edge cases, error handling
- Gameplay details the design doc leaves open, if they follow its intent (fairness rules,
  timings, UI layout, onboarding steps, copy)
- Which agent owns what when ownership is unclear; splitting or reordering tasks

**Principles, in priority order, when choosing:**

1. Never duplicate or lose player data or purchases.
2. Never trust the client.
3. Stay inside Roblox policy (paid random items, feeds, text filtering, maturity).
4. Fair to the player being raided: loss stings but never wipes or traps anyone.
5. Prefer reversible: Config values over code, optional fields over migrations, kill
   switches on anything risky.
6. Close future exploits now when it is cheap (example: mark rescue-egg critters untradeable
   before trading exists).
7. Simplest thing that passes the phase gate.

**Ask Kian (mark Blocked):**

- Anything that spends money or credits beyond the phase budget, or needs an account,
  Creator Dashboard step, or key only he has
- Publishing, visibility, prices, or anything on a live game
- Changing a design-doc pillar: loss rules beyond the table's numbers, monetization model,
  theme, what is sold, notification strategy
- Anything with legal, policy or employment doubt
- A disagreement between the reviewer and an agent that two rounds did not settle
- Every human gate

**Log format** (`docs/decisions-log.md`, newest first, one entry per decision):

```
### D-014 · 2026-11-03 · raids is the master kill switch
Context: reviewer note on PR #2. Decision: async and revenge raids need raids AND asyncRaids;
switches never stop escrow recovery. Why: one flip stops all theft during an incident.
Reversible: yes (Config).
```

Kian reads the log in the gate report and can overturn any decision; the orchestrator then
turns the reversal into tasks.

---

## 3. Progress ledger (`docs/progress.md`)

The orchestrator creates and owns this file. Format:

```markdown
# Progress

Current phase: 1 · Last updated: 2026-11-20

| Task | Agent       | Depends | Status      | Branch / PR            | Attempts | Notes |
| ---- | ----------- | ------- | ----------- | ---------------------- | -------- | ----- |
| P1.1 | data        | —       | Done        | #12                    | 1        |       |
| P1.2 | matchmaking | P1.1    | In progress | agent/matchmaking/P1.2 | 1        |       |

## Blocked (needs Kian)

- P1.4: needs a decision on ...

## Gate history

- Phase 0 gate: passed 2026-11-14 (notes)
```

Statuses: `Todo`, `In progress`, `In review`, `Done`, `Blocked`.

---

## 4. Task prompt template (prepended to every task)

> You are the `<agent>` agent. Task `<id>`: `<title>`. Read CLAUDE.md and your agent file first.
> Work only in your owned paths, in this worktree and branch. If you need a contract change
> or a file outside your lane, stop and report it instead of making it. Finish with a PR into
> `integration` containing: what changed, how you tested it, a Studio playtest plan for the
> integration agent, and anything handed to another owner. Done when: `<done-when list>`.

## 5. Gate report format (posted at every gate)

- **Phase:** N · **Tasks:** done / total · **PRs merged:** list
- **Exit checks:** each with pass/fail
- **What to test yourself:** steps, accounts, time needed
- **Known issues:** with severity
- **Decisions made this phase:** one line each from docs/decisions-log.md, so you can overturn any
- **Open questions for you:** the Blocked list (should be short: "Ask Kian" items only)
- **Next phase preview:** first 4 tasks it will start

---

## Human gates at a glance

| Gate           | When                | What you decide                                    |
| -------------- | ------------------- | -------------------------------------------------- |
| G0             | Before Phase 0      | Roblox outside-activity and DevEx policy cleared   |
| Style lock     | During Phase 0      | Pick the 3-4 style reference images                |
| Phase 0 gate   | End of Phase 0      | Is live stealing fun with 4 friends?               |
| Asset Gate 1   | Every critter batch | Approve concept art before any 3D                  |
| Asset Gate 2   | Every critter batch | Approve the model in Studio                        |
| Phase 1 gate   | End of Phase 1      | Async raid + revenge feel right in a real playtest |
| Phase 2 gate   | End of Phase 2      | Closed test of ~200: D1 25%+                       |
| Go public      | Start of Phase 3    | Publish publicly (unpromoted)                      |
| Phase 3 gate   | End of Phase 3      | D1 30%+, 2.0 sessions per user, zero dupes         |
| Launch         | Phase 4             | Launch date, ad budget, creator deals              |
| Every Saturday | Phase 5             | Approve the week's event before it ships           |

---

# Phase 0: Prototype (weeks 1-3)

**Goal:** find out if grabbing a critter and running it home is fun, live, with friends.
**Entry:** G0 cleared; `docs/setup.md` done; Studio smoke test prints `[RaidNight] server started`.
**Parallelism:** keep it low (2 at once). Speed of iteration matters more than throughput.
**Credits budget:** style exploration only.

| Task | Agent       | Depends    | Title                                                             |
| ---- | ----------- | ---------- | ----------------------------------------------------------------- |
| P0.1 | integration | —          | CI and repo protections                                           |
| P0.2 | raid        | —          | Greybox map: 8 den plots, pads, borders                           |
| P0.3 | data        | —          | Minimal save: profile load/save with ProfileStore, kill switches  |
| P0.4 | economy     | P0.3       | Income, collect, egg conveyor, 10 placeholder critters            |
| P0.5 | raid        | P0.2, P0.4 | Live stealing: grab, carry, tag-to-drop, escape, lockdown         |
| P0.6 | ui          | P0.4       | Minimal HUD: Glow, storage bar, collect, egg buy, carried critter |
| P0.7 | assets      | —          | Style exploration images (Stage 0), stop for style lock           |
| P0.8 | integration | P0.5, P0.6 | 2-client playtest + friends playtest kit                          |

**P0.1 CI and repo protections.** Add `.github/workflows/ci.yml` from Appendix D. Confirm it
runs green on a PR. Document branch protection steps for `main` and `integration` in the PR
(Kian applies them). _Done when:_ CI runs tests, format, lint and type checks on PRs.

**P0.2 Greybox map.** Build a night-lit greybox map with 8 den plots, 6 pads each, a visible
border per den, spawn points, and a central plaza for future events. Plain parts and
lighting only. _Done when:_ 8 players spawn into their own dens; plots reassign on leave.

**P0.3 Minimal save + kill switches.** Implement DataService loading and saving profiles with
ProfileStore, `Profile.new` as template, `Profile.migrate` on load, release on leave. Add
boolean kill switches to Config under a new `Flags` table (`raids`, `asyncRaids`,
`purchases`, `trading`, `notifications`), readable by every service; this is a contract
change, so propose it first. _Done when:_ data survives rejoin in Studio; flags gate their
features.

**P0.4 Income and eggs.** IncomeService: collect, place critter on pad, egg conveyor that
sells eggs for Glow (Commons and Uncommons only), using Economy.luau and a server Random.
Placeholder critters are colored shapes sized by tier with a glow part. _Done when:_ buying,
placing and collecting work; DenChanged pushes update the client.

**P0.5 Live stealing.** In RaidService: walk into another den, grab a pad critter, carry it
(speed from `RaidRules.carrySpeedMultiplier`), owner tags you to drop it, escape by crossing
your border, 45 s lockdown with cooldown. All server-authoritative. _Done when:_ a 2-client
Studio test can steal, drop, recover and escape; exploits from the client are rejected.

**P0.6 Minimal HUD.** Glow counter, storage bar with local prediction, collect button, egg
buy prompt, carried-critter indicator, lockdown button. Phone layout first. _Done when:_
playable on a phone-sized emulator without overlapping UI.

**P0.7 Style exploration.** Generate 6-10 images from the style bible's STYLE block using 3
different critters. Log costs. **Stop** and present them for the style lock gate.
_Done when:_ Kian picks references, saved to `assets/clean/_style/`.

**P0.8 Playtest kit.** Write `docs/playtests/phase0.md` from Appendix B, publish the place
privately, and run a 2-client Studio session. _Done when:_ the kit is ready to send.

**Exit checks:** all tests and CI green; 2-client Studio session shows no errors in output.

**Phase 0 gate (human):** Play with 4 friends using the playtest kit. **Pass** if they play
30+ minutes without being asked and want to keep stealing. **Fail** → tell the orchestrator
what felt wrong; it creates fix tasks and reruns Phase 0. Do not start Phase 1 on a fail.

---

# Phase 1: Async core (weeks 4-7)

**Goal:** offline raids and revenge that work, safely.
**Entry:** Phase 0 gate passed.
**Parallelism:** 4.
**Credits budget:** none.

| Task  | Agent       | Depends    | Title                                                                    |
| ----- | ----------- | ---------- | ------------------------------------------------------------------------ |
| P1.1  | data        | —          | EscrowService + `Escrow.Store` + recovery sweep + offline profile access |
| P1.2  | matchmaking | P1.1       | Snapshots, MemoryStore pools, raid locks, presence                       |
| P1.3  | raid        | P1.1, P1.2 | Async raids in pocket dens: traps, guard AI, timer, handoff to escrow    |
| P1.4  | raid        | P1.3       | Replay recording (5 Hz positions + events), stored per raid              |
| P1.5  | ui          | —          | Raid Portal, in-raid HUD, raid log panel (mock data behind Net)          |
| P1.6  | ui          | P1.3, P1.5 | Wire UI to real remotes; revenge button flow                             |
| P1.7  | economy     | —          | Economy simulation tool + tuning proposal                                |
| P1.8  | economy     | P1.7       | Apply approved tuning to Config values                                   |
| P1.9  | matchmaking | P1.2       | Live revenge: presence lookup + join raider's server                     |
| P1.10 | integration | P1.6, P1.9 | Multi-client async raid playtest + soak test                             |

**P1.1 Escrow service.** Implement `Escrow.Store` over DataService and an escrow DataStore;
route defender debits through ProfileStore messages when the defender is online, offline
profile load otherwise; recovery sweep on raider join and every 60 s; duplication alarm.
Do not change Escrow.luau behavior. _Done when:_ EscrowSimulation passes; a Studio test with
a forced server shutdown mid-transfer recovers on rejoin with no dupe.

**P1.2 Snapshots and matchmaking.** SnapshotService on leave and every 120 s; one MemoryStore
sorted map per power band; raid locks with TTL; presence map refreshed every 60 s;
GetRaidTargets returns revenge targets first, then `pickCandidates`. _Done when:_ tests for
any new pure logic; Studio shows targets from a second test account's snapshot.

**P1.3 Async raids.** StartRaid with `RaidRules.canRaid` and lock; build a pocket den far
off-map from the snapshot with pooled models; traps and simple guard AI (patrol, chase,
tag); 3-minute timer; server-authoritative grabs; on escape create the escrow and hand off.
_Done when:_ a raid on an offline test account moves the critter and Glow, sets the shield,
creates a revenge token, and logs on both sides.

**P1.4 Replays.** Record raider position at 5 Hz plus grab, tag, trap and escape events;
compress; store per raidId with a 7-day lifetime. _Done when:_ a 3-minute raid stores under
a few KB and replays correctly in a debug viewer.

**P1.5 Raid UI (mocked).** Raid Portal with 3 targets and revenge targets on top; in-raid
HUD (timer, carried critter, arrow to the escape gate); raid log that opens first on login
when something happened. Mock data behind Net.luau. _Done when:_ screenshots at phone size.

**P1.6 Wire UI.** Replace mocks with real remotes; Revenge button starts a revenge raid.
_Done when:_ full loop works in Studio across two accounts.

**P1.7 Economy simulation.** Write `tools/sim/economy.luau` simulating a player from level 1
to first rebirth with realistic sessions and raids. Report time per den level, Glow held vs
egg price, raid loot as a share of income. Propose Config changes with before/after numbers.
**Stop** for approval. _Done when:_ report attached to the PR.

**P1.8 Apply tuning.** Apply the approved values only. _Done when:_ tests green.

**P1.9 Live revenge.** When the raider is online, offer "join their server" via presence and
TeleportService; land next to their den with the revenge token active. _Done when:_ works
across two live Studio servers or a published private test.

**P1.10 Multi-client test and soak.** Run a 4-client session through every raid path. Run a
30-minute soak with repeated raids and forced server shutdowns. _Done when:_ zero errors,
zero dupes, ledger of findings filed as fix tasks.

**Exit checks:** all tests green; EscrowSimulation green on `integration`; soak test clean;
no open `Blocked` items.

**Phase 1 gate (human):** Play async raids and revenge with 2-4 friends over 2-3 days, so
offline raids actually happen. **Pass** if being raided makes people want to come back and
hit back, and nobody feels cheated. **Fail** → name what felt bad (usually loss rules);
the orchestrator turns it into tuning or fix tasks.

---

# Phase 2: Vertical slice (weeks 8-11)

**Goal:** a game strangers can pick up: real art, onboarding, notifications, monetization,
analytics.
**Entry:** Phase 1 gate passed; style locked.
**Parallelism:** 4.
**Credits budget:** set before starting (40 critters × concept + 3D, plus retries).

| Task  | Agent         | Depends   | Title                                                                   |
| ----- | ------------- | --------- | ----------------------------------------------------------------------- |
| P2.1  | assets        | —         | Critter batches 1-8 (5 each): concept → Gate 1 → 3D → cleanup → Gate 2  |
| P2.2  | assets        | —         | World kit: den, pads, vault, traps, plaza, props (briefs + generation)  |
| P2.3  | raid          | P2.2      | Swap greybox for world kit; mobile performance pass                     |
| P2.4  | economy       | P2.1      | Swap placeholder critters for real models; mutation effects in-engine   |
| P2.5  | ui            | —         | Full UI pass per style bible: shop, inventory, den management, settings |
| P2.6  | ui            | P2.5      | Onboarding: first 5 minutes (Appendix C)                                |
| P2.7  | notifications | —         | NotificationService: send rules, launch data, opt-in timing             |
| P2.8  | economy       | —         | Passes and products (no paid randomness), idempotent receipts           |
| P2.9  | data          | —         | Analytics events (Appendix A) and funnels                               |
| P2.10 | raid          | —         | Gear: grapple, smoke, decoy, speed coil, lockpick (live only)           |
| P2.11 | assets        | —         | Audio: alarm sting, escape jingle, music loops, critter idles           |
| P2.12 | integration   | all above | Closed-test build + playtest kit                                        |

**P2.1 Critters.** Follow `docs/asset-pipeline.md` in batches of 5. After concept images,
**stop** for Asset Gate 1; after cleanup and import, **stop** for Asset Gate 2. Legendary,
Mythic and Secret critters get flagged for a human art pass. _Done when:_ all 40 imported
with ids in `assets/clean/<id>/ids.json`.

**P2.2 World kit.** Write briefs for den base, pads, vault door, each trap, plaza and 10
props in the style bible's look; generate, clean up, import. Same gates as critters.
_Done when:_ kit imported and documented.

**P2.3 World swap + performance.** Replace greybox with the kit. Target smooth play on a
low-end phone with 8 full dens: budget parts, use streaming, check memory. _Done when:_
performance numbers in the PR on a phone-class device.

**P2.4 Real critters.** Map species ids to imported models; idle animations; tier glow and
particles; mutation effects (Shiny, Moonlit, Haunted, Golden) as in-engine materials.
_Done when:_ every critter displays correctly in all four mutations.

**P2.5 Full UI.** Restyle all screens per the style bible; add inventory, den management,
settings (music, SFX, reduced motion). All strings in one localization table.
_Done when:_ screenshots of every screen at phone and desktop size.

**P2.6 Onboarding.** Implement Appendix C. _Done when:_ a new account reaches its first
steal in under 3 minutes with no external help.

**P2.7 Notifications.** Implement the send rules and opt-in timing in NotificationService;
notification strings listed for Kian to create in the Creator Dashboard (**stop** for that);
route launch data to the revenge screen. _Done when:_ a test send lands and Join opens the
revenge screen.

**P2.8 Monetization.** Implement passes and products from the design doc in PurchaseService
with idempotent receipts. List every product with price for Kian to create in the Creator
Dashboard (**stop** for that). No paid randomness. _Done when:_ test purchases grant exactly
once, including after a forced shutdown mid-purchase.

**P2.9 Analytics.** Fire every event in Appendix A; set up funnels for onboarding and the raid
flow; daily economy sources and sinks. _Done when:_ events visible in analytics from a test
session.

**P2.10 Gear.** Five gear items, upgradable with Glow, server-validated. Lockpick works only in
live raids. _Done when:_ each item tested in a 2-client session.

**P2.11 Audio.** Generate and select the alarm sting and escape jingle first (brand sounds),
then music loops and idles. Check commercial-use terms per model. **Stop** for approval of
the two brand sounds. _Done when:_ all audio imported and mixed.

**P2.12 Closed-test build.** Freeze a build; write `docs/playtests/phase2.md` from Appendix B;
set up the private-server or group-only access for ~200 testers. _Done when:_ ready to invite.

**Exit checks:** all tests and CI green; onboarding under 3 minutes; no errors in a 4-client
session; analytics events arriving.

**Phase 2 gate (human):** Run the closed test of ~200 players for at least 7 days.
**Pass** at day-1 retention 25%+ and no data-loss reports. **Fail** → orchestrator proposes
fixes from the analytics funnels; rerun the closed test.

---

# Phase 3: Soft launch (weeks 12-14)

**Goal:** prove the numbers in public before spending on marketing.
**Entry:** Phase 2 gate passed; **Go public** gate approved.
**Parallelism:** 3.

| Task | Agent       | Depends | Title                                                     |
| ---- | ----------- | ------- | --------------------------------------------------------- |
| P3.1 | integration | —       | Publish public, unpromoted; monitoring dashboard          |
| P3.2 | ui          | —       | Replay viewer + clip export                               |
| P3.3 | matchmaking | —       | Nemesis system                                            |
| P3.4 | raid        | —       | Anti-exploit hardening pass + server-side anomaly logging |
| P3.5 | economy     | P3.1    | Weekly tuning from live data (proposals, approval, apply) |
| P3.6 | economy     | P3.1    | Price tests on passes and products                        |
| P3.7 | assets      | —       | Icon + thumbnail sets (3 each) for A/B tests              |
| P3.8 | reviewer    | —       | Full security and policy audit before launch              |

**P3.1 Go public.** Publish with public visibility, no promotion. Build a daily dashboard of
the metrics in the design doc. _Done when:_ dashboard live; daily summary posts to the ledger.

**P3.2 Replays and clips.** Replay viewer from the raid log; export the replay as a shareable
clip. Single clip only: no feed, no autoplay chain, no reward for watching. _Done when:_
a clip exports and shares from a phone.

**P3.3 Nemesis.** Most-frequent raider in 7 days becomes your Nemesis: den sign, bonus for
beating them, used in notification copy. _Done when:_ tests for selection logic; visible in game.

**P3.4 Hardening.** Review every remote for rate limits and validation; add anomaly logs
(impossible speeds, grabs from far away, purchase spam). _Done when:_ reviewer signs off.

**P3.5 Weekly tuning.** Each week: read the dashboard, propose Config changes with expected
effect, **stop** for approval, apply. _Done when:_ ongoing through Phase 3.

**P3.6 Price tests.** One variable per product, two weeks per test, judged on revenue per
daily user. **Stop** before each test starts. _Done when:_ results recorded.

**P3.7 Icons and thumbnails.** 3 icons and 3 thumbnail sets from real gameplay captures plus
generated key art. **Stop** for selection. _Done when:_ A/B tests running.

**P3.8 Audit.** Reviewer audits duplication paths, client trust, purchases, text filtering,
policy compliance and kill switches. _Done when:_ no blocking findings.

**Exit checks:** zero duplication alarms for 14 days; audit clean; all tests green.

**Phase 3 gate (human):** **Pass** at D1 30%+, 2.0+ sessions per daily user, revenge rate
30%+, like ratio 85%+, zero dupes. **Fail** → iterate in Phase 3; do not launch on weak
retention, because paid traffic will not fix it.

---

# Phase 4: Launch (week 15)

**Goal:** a launch spike that the game can hold.
**Entry:** Phase 3 gate passed; **Launch** gate approved (date, ad budget, creators).

| Task | Agent       | Depends   | Title                                                          |
| ---- | ----------- | --------- | -------------------------------------------------------------- |
| P4.1 | assets      | —         | Creator kit: clips, key art, codes, talking points             |
| P4.2 | economy     | —         | Meteor Shower launch event config + Founders badge             |
| P4.3 | integration | P4.2      | Launch build freeze, rollback plan, launch-day runbook dry run |
| P4.4 | ui          | —         | Creator codes redemption + tracking                            |
| P4.5 | integration | all above | Launch day (Appendix E)                                        |

Ads are bought by Kian. Agents prepare creatives and tracking only.

**Exit checks:** launch day ran per Appendix E; no Sev-1 incidents open.

**Launch gate (human):** after 72 hours, decide: scale ads, hold, or fix first.

---

# Phase 5: Weekly live ops (week 16 onward)

**Goal:** ship something new every Saturday morning (US time), forever.

### Weekly cycle

| Day     | Who              | What                                                                    |
| ------- | ---------------- | ----------------------------------------------------------------------- |
| Mon     | orchestrator     | Read last week's dashboard; propose this week's event, critters, tuning |
| Mon     | **Kian**         | Approve the plan                                                        |
| Tue-Wed | assets + economy | New critters through the asset pipeline; event config                   |
| Wed-Thu | raid / ui        | Event mechanics and UI, if any                                          |
| Thu     | integration      | Freeze; full test pass; multi-client playtest                           |
| Fri     | **Kian**         | Approve the build; orchestrator prepares clip, title tag, thumbnail     |
| Sat     | integration      | Ship; watch dashboard and alarms for 2 hours                            |

Keep a 3-week buffer of finished critters and event configs. Events are data (spawn tables,
odds, lighting, music), so a new event should take a day to configure.

### First weeks after launch

| Week | Event                                                     | New system                                                                    |
| ---- | --------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 2    | Blood Moon (72 h, mutation odds up, first Secret critter) | Nemesis goes live if not already                                              |
| 3    | Fog Night (traps hidden, stealth bonus)                   | Crews (up to 4) + crew leaderboard                                            |
| 4    | Raid the Creator                                          | Creator den event tooling                                                     |
| 5    | —                                                         | Trading beta (two-step confirm, 7-day new-account lock, PolicyService gating) |

Phase 2 paid randomness (Robux eggs, Blood Moon summon) is its own mini-phase: odds panel,
live odds during boosts, PolicyService gating, reviewer audit, **human gate** before shipping.

---

# Appendix A: Analytics events

| Event                             | Fired when                         | Key fields                                   |
| --------------------------------- | ---------------------------------- | -------------------------------------------- |
| `onboarding_step`                 | Each onboarding step completes     | step, seconds since join                     |
| `egg_bought`                      | Egg purchased                      | tier, price, den level                       |
| `critter_placed`                  | Critter placed                     | tier, placement                              |
| `glow_collected`                  | Collect                            | amount, storage fill share                   |
| `raid_portal_opened`              | Portal opened                      | targets offered, revenge available           |
| `raid_started`                    | Raid starts                        | async or live, revenge, target power         |
| `raid_ended`                      | Raid ends                          | escaped, tier taken, glow, duration          |
| `raided_offline`                  | Debit lands on an offline defender | tier lost, glow lost                         |
| `raid_log_opened`                 | Log opened                         | entries since last visit                     |
| `revenge_started`                 | Revenge raid starts                | hours since being raided, from notification? |
| `notification_sent`               | Send succeeds or throttles         | category, result                             |
| `notification_join`               | Join with launch data              | category                                     |
| `optin_prompted` / `optin_result` | Prompt shown / answered            | trigger, accepted                            |
| `purchase`                        | Receipt granted                    | product, price                               |
| `rebirth`                         | Rebirth                            | count, days since join                       |
| `session_end`                     | Leave                              | session length, raids, steals                |

Funnels: onboarding (join → first hatch → first collect → first steal → first raid);
raid flow (portal → target picked → raid started → escaped).

# Appendix B: Playtest kit template

1. **Setup** (what to install, how to join, how long to play)
2. **What to do** (3-5 loose goals, never a script: "try to steal the rarest critter you see")
3. **What we watch** (session length, whether they return unprompted, where they get stuck)
4. **Questions after** (5 max): What was the most fun moment? When did you want to stop?
   Did losing a critter feel fair? Would you come back tomorrow, and why? What confused you?
5. **Pass criteria** (copied from the phase gate)

# Appendix C: Onboarding (first 5 minutes)

1. Spawn in your den at night; a free critter hatches immediately (0:00-0:30)
2. Place it; watch Glow tick up; first collect (0:30-1:00)
3. Buy a second egg with the Glow (1:00-1:30)
4. A guided first steal from a tutorial den next door (1:30-3:00)
5. Get your critter home; celebration; raid log explained in one line (3:00-3:30)
6. Free 30-minute shield so the new player is never raided during onboarding; new-player
   protection covers the next 48 hours anyway
7. Notification opt-in is NOT asked here; it comes after the first real raid

# Appendix D: CI workflow (`.github/workflows/ci.yml`)

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main, integration]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/cache@v4
        with:
          path: ~/.cargo/bin
          key: tools-${{ runner.os }}-lune-stylua-v1
      - name: Install tools
        run: |
          command -v lune || cargo install lune --locked
          command -v stylua || cargo install stylua --locked
          curl -sSL -o luau.zip https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
          unzip -o -q luau.zip -d "$HOME/luau" && echo "$HOME/luau" >> "$GITHUB_PATH"
      - name: Tests
        run: lune run tests/run.luau
      - name: Format
        run: stylua --check src tests tools
      - name: Type check
        run: luau-analyze src/Shared/*.luau src/Shared/Data/*.luau
```

Add `selene src` once the Roblox std generation works in CI (`selene generate-roblox-std`).

# Appendix E: Launch-day runbook

**T-24 h:** build frozen on `main`; kill switches tested; rollback place version noted;
creators briefed; ads scheduled (not live).
**T-0:** publish; post clips; creators go live; ads on at low budget.
**T+0 to T+6 h:** integration watches every 15 minutes: errors, duplication alarm, DataStore
and MemoryStore throttling, server memory, purchase failures, like ratio.
**Rollback triggers:** any duplication alarm, data loss report, or purchase failures above a
trickle → flip the relevant kill switch first (`asyncRaids`, `trading`, `purchases`), then
roll back the place version if needed.
**T+72 h:** gate report to Kian: retention, sessions per user, revenue per daily user,
top player complaints.

# Appendix F: Incident runbook

| Severity | Example                                          | First action                                                                    |
| -------- | ------------------------------------------------ | ------------------------------------------------------------------------------- |
| Sev-1    | Duplication, data loss, purchases not granted    | Kill switch now; stop all other work; fix; reviewer sign-off before re-enabling |
| Sev-2    | Raids failing, notifications broken, big exploit | Kill switch for that feature; fix within 24 h                                   |
| Sev-3    | Visual bugs, balance complaints                  | Next weekly update                                                              |

Every Sev-1 and Sev-2 gets a short write-up in `docs/incidents/` with cause and the test that
now prevents it.
