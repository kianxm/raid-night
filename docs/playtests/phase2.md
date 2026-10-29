# Raid Night: Phase 2 closed test kit

The Phase 2 gate: about 200 testers, at least 7 days. This file has:

1. Before inviting (Kian's checklist)
2. Tester kit (setup, goals, what we watch, questions, pass criteria)
3. Known placeholders

Sources: playbook Appendix A and B, the Phase 2 PR descriptions (#118, #121 to #136) and
`docs/contracts.md` (Analytics). If a PR description and this file disagree, the PR wins and this
file gets a fix. Nothing here is published or switched on by an agent. Every access and
Creator Dashboard step is Kian's.

---

# 1. Before inviting (Kian)

Do these in order. Do not invite anyone until every box is checked.

## Merge and freeze

- [ ] Phase 2 PRs are merged into `integration` and tests are green (`lune run tests/run.luau`).
- [ ] Freeze the build: note the commit SHA here and publish only that build to the closed-test place. Build SHA: `________`.
- [ ] Publish to the test place only. Never publish over a live public place.

## Notifications (#118)

- [ ] Creator Dashboard > Notifications: create the string `{raider} took your {critter}. Want it back?`
      with parameters `raider` (username) and `critter` (critter name), and the "join experience" action.
      Paste its message id into `MESSAGE_IDS.revenge` in `src/Server/Services/NotificationService.luau`
      (hand to the `notifications` agent; do not edit it yourself).
- [ ] The storage string (`Your den is almost full of Glow. Collect it before it stops earning.`) is optional
      and stays off (`Rules.ENABLED_CATEGORIES.storage = false`, D-062). Skip it unless you decide otherwise.
- [ ] Create an Open Cloud API key with user-notification write scope for this experience and store it as the
      Secret `NotificationsApiKey` (Studio > Home > Game Settings > Security > Secrets, or Creator Dashboard
      Secrets). Never paste the key into code or chat.
- [ ] Decision: set `Config.Flags.notifications = true` for the test? (Default off.) Recommended yes, since
      the revenge notification is the core hook and the test measures it.
- [ ] #118 says the Open Cloud request body was written from memory of the public docs. A real test send must
      land and Join must open the revenge screen (Studio pass below, step 4).

## Passes and products (#127)

Create each in the Creator Dashboard, then give the ids to the `economy` agent to paste into
`Config.Purchases` (`passes.<key>.id`, `products.<key>.id`). An id of 0 means "not created", and
that item is never offered or granted. Prices are the PR's; change them only on purpose.

| Item | Type | Price (Robux) | `Config.Purchases` key | Notes |
| --- | --- | --- | --- | --- |
| VIP | Game pass | 399 | `passes.vip` | +50% Glow while online only. Description must say the Glow bonus is not available everywhere (D-061). |
| Extra vault slot | Game pass | 199 | `passes.vaultSlot` | +1 vault slot |
| Auto-collect | Game pass | 149 | `passes.autoCollect` | Banks den Glow every 30 s while online |
| Raid scout | Game pass | 249 | `passes.raidScout` | Perk effect not built; skip creating it for the test |
| Den theme | Game pass | 149 | `passes.denTheme` | Placeholder; set and art not built |
| Gear skin | Game pass | 99 | `passes.gearSkin` | Placeholder |
| Escape emote | Game pass | 49 | `passes.escapeEmote` | Placeholder |
| Shield (8 h) | Developer product | 49 | `products.shield` | Stacks up to 24 h |
| Lantern Night | Developer product | 149 | `products.lanternNight` | +50% Glow server-wide for 15 min, buyer announced |
| Event pass | Developer product | 399 | `products.eventPass` | Off until `currentEventId` is set and rewards exist; skip |
| Critter accessories | Developer products | 25 to 149 | none yet | Blocked on art (D-057); skip |

- [ ] Decision: `Config.Flags.purchases` for the test. Default is `false`. Turn it on only if you want purchases
      in the test. The `PurchaseSource` spec fails the build if the flag is on while a Glow-factor handoff is
      pending. Check #127's handoffs (a shop remote and `DenState.vaultSlots` in `Net.luau`, plus the
      client LanternNight handler) have landed, or the shop cannot sell anything.
- [ ] If purchases are on: the reviewer policy audit and the PolicyService check (D-028, D-030) are done.
- [ ] Decisions waiting on you from #127: restricted-player refund path, timer skips, event pass rewards, and
      what happens to Lantern Night on a shutdown. None blocks a test with purchases off.
- [ ] If purchases are off, the `purchase` event and "purchases" row below are simply empty.

## Raids on

- [ ] `Config.Flags.asyncRaids` is `false` by default. The test needs offline raids, so confirm it is `true`
      in the frozen build (`raids` is already on). Decide this with the orchestrator.

## Streaming and performance (#125)

- [ ] Confirm `Workspace.StreamingEnabled = true` in the place (a place setting, not in
      `default.project.json`). If off, turn it on and set `StreamingIntegrityMode = MinimumRadiusPause`,
      then repeat the Studio raid steps.
- [ ] Phone-device perf check (#125 step 7): fill 8 dens to 30 pads using test profiles, join on a low-end
      phone, and record from the Developer Console (F9) memory (total, PlaceMemory, GraphicsTexture), FPS in
      the plaza and inside a full den, and server memory and heartbeat with 8 players. Write the numbers in #125.
      If FPS is bad on the phone, tell the orchestrator before inviting.

## Studio pass

- [ ] One single-client Studio pass by `integration` on the frozen build: onboarding under 3 minutes to
      first steal, a raid, a revenge notification test send, no errors in the output window.
      Multi-client steps stay on the deferred list in `docs/progress.md`; the 4-client session in the
      Phase 2 exit checks is a separate item for Kian.
- [ ] Analytics are arriving: set the ServerStorage attribute `StudioAnalyticsLog = true` in Studio to see
      `[Analytics]` lines, then play about 5 minutes in a published test place and check Creator Dashboard >
      Analytics for custom events, the Onboarding funnel and Economy (Roblox can take up to 24 h).

## Access for about 200 testers (Kian)

Roblox's public docs describe these controls; menu names change, so check the page you land on.

1. Creator Dashboard (Creations) > pick the experience > **Publish settings > Manage Audience**
   (Target audience) > **Manage access** (top right). Keep **Playtesters** enabled so only people with Edit
   or Playtest access can play. Leave **Friends** and Public off. This tab invites **early testers**, and
   Studio's File > Invite early testers allows only up to 10, so it covers the team, not 200.
2. For 200 testers use the **Play** permission: Studio > **Collaborate** (mezzanine bar) > search for a group
   > choose **Play** > Save. The collaboration docs say a user-owned experience can grant Play to any user or
   group, and Play means the person may play the game privately. If the experience is group-owned, the
   group owner (or a member with enough rights) adds Play for the testers in the same dialog.
3. Easiest flow: create a Roblox group "Raid Night Testers", set its join to approval or invite only, accept
   about 200 people, then grant that group Play access as in step 2. Remove people from the group to end
   their access.
4. Test it with a non-team alt account in the group before inviting anyone: it can join, and an account
   outside the group cannot.
5. If the dialog does not offer Play for a group, or the 200 limit bites, stop and tell the orchestrator.
   Do not make the place Public to work around it; that is the Phase 3 "Go public" gate.
6. Private servers are not an access control. They are a per-server option on a place that others can
   already reach, so they do not replace steps 1 to 3.

Public docs used: Creator Hub, "Publish experiences and places" (Target audience / Manage access) and
"Collaboration" (Play permission). Neither states a limit on Play users, so verify at 200.

---

# 2. Tester kit (send this part)

## Setup

- Join the **Raid Night Testers** group (invite link: `________`). You then see the game in the group's
  Games tab, or open this link: `________`.
- Install nothing extra. Play on whatever you normally use. Phone testers are very welcome.
- Allow Roblox notifications for the experience when it asks. It asks after your first successful raid.
- Play for 7 days, as you like. A first session of 20 to 30 minutes is plenty. Then come back when you
  feel like it, or when a notification pulls you back. Do not set alarms; that is the point.
- The art and sound are placeholders (see section 3). Please do not judge those.
- Report a lost or missing critter or Glow right away at `________` (form or Discord), with your
  username and roughly when it happened. Do not wait for the survey.

## What to do

Loose goals, no script:

1. Hatch a critter, put it to work, and watch your Glow grow.
2. Try to steal something good from another den.
3. Leave the game for a while, then come back and read your raid log.
4. If someone took a critter from you, try to take it back.
5. Grow your den: new pads, better critters, rebirth if you get there.

## What we watch

We read these in the Creator Dashboard analytics (fields are in `docs/contracts.md`, Analytics).
Roblox can take up to 24 h to show events. Players are never named in events.

| What | Where | Why |
| --- | --- | --- |
| Onboarding funnel: join, first hatch, first collect, first steal, first raid | Analytics > Funnels > Onboarding (one-time funnel, accounts under 7 days old) | Where new players drop in the first 5 minutes. Target: under 3 minutes to first steal. Step breakdown also in `onboarding_step` (labels such as `Step - 3 collect`). |
| Raid flow funnel: portal, target picked, raid started, escaped | Analytics > Funnels > RaidFlow (recurring) | Where raiders give up: not picking a target, not starting, not escaping |
| Day 1 retention (and D7 at the end) | Analytics > Retention | Gate metric |
| Sessions per user and session length | Analytics > Engagement; `session_end` custom event (sessionSeconds, raids, steals) | Do they come back, and do they raid |
| Notification opt-in and join | Analytics > Custom events: `optin_prompted`, `optin_result`, `notification_sent`, `notification_join` | Does the revenge notification bring people back |
| Offline raids | Custom events: `raid_started`, `raid_ended`, `raided_offline`, `revenge_started`, `raid_log_opened` | Is the loop of loss and revenge happening |
| Economy sources and sinks | Analytics > Economy (`Glow`, `DenGlow` flows) | Is the economy inflating or starving |
| Purchases (only if `Flags.purchases` is on) | Analytics > Monetization and custom event `purchase` | Do products sell, and are they granted once |
| Data-loss reports | Tester reports channel (above), plus Developer Console server logs | Zero allowed |

Also watch, by hand: crashes and error spam in Creator Dashboard > Analytics > Performance, the
duplication alarm from EscrowService in server logs, and tester reports about stuck screens.

Note: `raided_offline` for a defender that no server holds is logged on the raider's player, so
its unique-user count means raiders (contracts.md).

## Questions after (5 max)

Send after day 3 and again after day 7.

1. What was the most fun moment?
2. When did you want to stop?
3. Did losing a critter feel fair?
4. Would you come back tomorrow, and why?
5. What confused you?

## Pass criteria (copied from the Phase 2 gate)

Run the closed test of about 200 players for at least 7 days. **Pass** at day-1 retention 25%+ and no
data-loss reports. **Fail**: the orchestrator proposes fixes from the analytics funnels, and the
closed test is rerun.

Also from the Phase 2 exit checks, true before inviting: all tests and CI green; onboarding under
3 minutes; no errors in a 4-client session; analytics events arriving.

---

# 3. Known placeholders

Tell testers about these so nobody reports them as bugs.

- No real art or audio yet (D-057, no art credits). The world uses greybox parts and placeholder
  critters. The world kit seam (#125) and the real-critter seam (#124) fall back automatically, so
  art drops in later with no code change.
- Kit, critter and audio asset ids are empty (`WorldKit` `assetId` is 0 for every piece, critter model
  ids are unset, audio ids are unset). Sounds are silent or stand-ins.
- Passes and products have id 0 until Kian creates them; unfinished items stay hidden: raid scout (perk
  not built), event pass (no event or rewards), accessories (no art), timer skips (not built), den
  theme, gear skin and escape emote (placeholders).
- The storage notification is off. Only the revenge notification sends.
