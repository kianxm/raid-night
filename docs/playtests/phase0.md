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
  bank it. In this build a steal takes the **critter only**, never Glow (stealing stored Glow
  comes later, with offline raids).
- **Buttons on screen:** Collect, Buy Egg and Lockdown.
- **Real stealing:** walk into another player's den and stand near a pad (within about 10
  studs). Hold the Steal prompt (F on PC, hold the button on a phone) for about a second until
  you pick the critter up. Only one critter at a time. You now carry it, and heavier critters
  slow you down (Light 90% of normal speed, Medium 75%, Heavy 60%, Very Heavy 45%). Carry it
  out of that den and across your own border to keep it.
  - **Dropping it:** if the den's owner gets within about 6 studs of you, you drop it and it
    goes back on its pad. You also drop it if you die or leave, or move impossibly fast or high
    (teleport, speed hack, flying). Walking and jumping normally never drops it.
  - **Seeing the result:** while you carry, a "Carrying <critter>" label sits at the top of the
    screen and a name floats over your head. When the carry ends you get a message at the top:
    "You stole <critter>! It's in your den." if you got it home, "Dropped <critter>!" if you
    lost it, or "Steal not confirmed" (with "If it went through, it'll show up in your den.")
    if the game could not confirm it.
  - **Where it lands:** a stolen critter appears on a free pad in your den right away. If all 6
    pads are full it waits in storage and moves onto a pad as soon as one frees up (for
    example when you put a critter in the Vault). Critters in the Vault are never moved.
  - **What you get:** the critter only. No Glow moves, in either direction.
- **Lockdown:** the den's owner presses Lockdown to lock their den for 45 seconds.
  - New raiders cannot walk in: the game pushes them back out.
  - Raiders already inside when it starts can stay or leave, but if they leave while carrying a
    critter, they drop it at the border and it returns to its pad. Once out, they cannot come
    back in until it ends.
  - It only affects live stealing, never the owner.
  - After it ends the owner must wait 2 minutes before locking again (so at most 45 s locked
    in every 165 s). The button shows "Locked 0:45" counting down, then "Ready in 2:00"
    counting down, then goes back to normal.

## 2. What to do

No script. Do what sounds fun, and try some of these:

1. Hatch your free egg and put the critter on a pad. Then watch your Glow grow.
2. Try to steal the rarest critter you see.
3. Get a stolen critter all the way home without dropping it.
4. Defend your den: tag someone who is carrying your critter, or try Lockdown.
5. Steal back a critter that someone took from you (it has to be on a pad in their den).

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
- [ ] **`StudioMemoryProfiles` is NOT set** on the published test place: open
      ServerStorage in the place and make sure the attribute is absent or false. It is a
      Studio-only switch for single-client testing (it makes every profile a throwaway mock). A
      live server ignores it, but keep it off in the file so nobody is confused later.
- [ ] Kill switches: `Config.Flags.raids = true` (stealing is off without it). Leave
      `asyncRaids`, `purchases`, `trading` and `notifications` as they are (off in Phase 0).
- [ ] You joined once yourself and saw your den, the starter egg and the three HUD buttons.
- [ ] Known limits: repeat steals from the same player hit a per-day pair limit (D-022) and
      are refused with no message, and a player can only lose so many critters a day. If a
      tester says "it won't let me", look at the Output for `PairLimit` or the daily cap.
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
