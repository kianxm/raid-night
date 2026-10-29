# Raid Night: Phase 0 friends playtest

Thanks for helping! This is an early build of a game about stealing cute night critters from
your friends' dens. Nothing here is final. The art is plain colored shapes on purpose. We
want to know one thing: **is grabbing a critter and running it home fun?**

## 1. Setup

- **Where to play:** Roblox, on a phone or a PC (a mix is ideal).
- **Join link:** Kian: fill in the join link and access method (private or friends-only
  place; testers must be invited or friended before the link works).
- **Who:** up to 8 players per server. It is best with 4 or 5 friends.
- **How long:** 30 to 45 minutes. Stop whenever you like; we want to hear when and why.
- **Voice chat:** optional. Talking out loud while you play is welcome.
- **Heads up:** this is a prototype. Things may break, and your progress may be wiped
  afterward.

What you will find:

- **Your own den** with 6 pads for critters and an egg station. Walk up to the station for
  the Buy Egg, Collect Glow and Upgrade Den prompts.
- **A free starter egg** to get you going.
- **Glow**, the currency your critters earn over time. It fills a storage bar. Collect it to
  bank it safely. Uncollected Glow in storage can be stolen.
- **Buttons on screen:** Collect, Buy Egg and Lockdown.
- **Real stealing:** walk into another player's den, hold to grab a critter, then carry it
  home across your own border. Heavier critters slow you down. The den's owner can tag you
  to make you drop it.
- **Lockdown:** the owner can lock their den for 45 seconds. New raiders cannot enter, but
  anyone already inside can still leave. Then it needs 120 seconds to recharge.

## 2. What to do

No script. Do what sounds fun, and try some of these:

1. Hatch your free egg and put the critter on a pad. Then watch your Glow grow.
2. Try to steal the rarest critter you see.
3. Get a stolen critter all the way home without dropping it.
4. Defend your den: tag someone who is carrying your critter, or try Lockdown.
5. Get a critter back from whoever took it.

## 3. What we watch

Kian takes notes. You do not need to do anything for this part.

- **Session length:** how long each person plays, and whether it was without being asked.
- **Whether they return unprompted:** do they keep going, or come back after a break?
- **Where they get stuck:** confusion, wandering, rage-quits, silence, laughter.

## 4. Questions after

Five quick ones. Honest answers beat polite ones.

1. What was the most fun moment?
2. When did you want to stop?
3. Did losing a critter feel fair?
4. Would you come back tomorrow, and why?
5. What confused you?

## 5. Pass criteria

From the Phase 0 gate: testers **play 30+ minutes without being asked, and want to keep
stealing**. If most of the group does, Phase 0 passes. If not, we write down what felt wrong,
fix it, and run it again.

---

# For Kian: running the session

Not for testers.

**Before**

- [ ] Latest `integration` build is synced and published to the private test place (publish
      only the test place, never a live one). Join link and access method filled in above.
- [ ] Want a fresh start? Delete the test profiles (store `PlayerProfiles`) in Creator Hub's
      Data Stores manager for the test universe. Otherwise old progress carries over.
- [ ] Kill switches: `Config.Flags.raids = true` (stealing is off without it). Leave
      `asyncRaids`, `purchases`, `trading` and `notifications` as they are (off in Phase 0).
- [ ] You joined once yourself and saw your den, the starter egg and the three HUD buttons.
- [ ] 4 or 5 friends invited, with at least one on a phone.

**During**

- [ ] Note start and stop times for each player, and the time of every quit.
- [ ] Write down quotes, especially laughs, complaints and "wait, how do I...".
- [ ] Do not coach. If someone is stuck, count to ten and note where. Only step in if they
      cannot continue at all, and note that you did.
- [ ] Note any errors, wrong-looking UI on phones, or lag you see.

**After**

- [ ] Ask the 5 questions in section 4, one person at a time if you can.
- [ ] Fill in the results template below.
- [ ] Record the outcome in `docs/progress.md`, under Gate history (for example
      "Phase 0 gate: passed/failed YYYY-MM-DD (notes)"). On a fail, tell the orchestrator what
      felt wrong so it can create fix tasks. Do not start Phase 1 on a fail.

---

# Results template

Copy this block for the session, then one row/block per player.

```
Date:
Build (integration commit):
Players / devices:
Overall: PASS / FAIL (rule: most players played 30+ min unprompted and wanted to keep stealing)
Main stuck points:
Bugs to file (steps, expected, actual):
```

Per player:

```
Player:
Device (phone / PC / tablet):
Minutes played:
Stopped why (still going / bored / stuck / got robbed / time / bug):
Came back unprompted? (yes / no):
Steals made:
Steals suffered:
Q1 Most fun moment:
Q2 When wanted to stop:
Q3 Losing a critter fair?:
Q4 Come back tomorrow, and why:
Q5 Confused by:
Notable quotes:
```
