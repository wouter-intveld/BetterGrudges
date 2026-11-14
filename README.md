# BetterGrudges

A friendly book of grudges for the World of Warcraft Forever client. It
remembers the players you meet, the ones who wronged you and the ones who
helped, and reminds you when you see them again.

## What it writes down by itself

- **Grudges:** a player who kills you, noting when they caught you while you
  were busy fighting something else, and a player who beats you in a duel.
- **Settling the score:** an honourable kill on someone you hold a grudge
  against avenges your oldest grudge against them; winning a duel back settles
  a duel grudge. Settled grudges stay on the page, greyed out and marked settled.
- **Kindnesses:** a player who offers you a resurrection, and a player who
  buffs you in the open world (at most once a day per player, so cities and
  dungeons don't fill the book).

Hover over a player and the tooltip tells you what you have against them, and
what you owe them.

## Marks

Players in the book get a small medallion on your target and focus frames and
beside their nameplate: crossed swords on red for an open grudge, a heart on
green for a kindness. It works with Blizzard's frames (also as
BetterBlizzFrames styles them), ElvUI, Shadowed Unit Frames, PitBull and
EllesmereUI, and with any nameplate addon. Nameplate marks show in the open
world only, since the game keeps addons away from enemy nameplates in
instances.

Under Options > AddOns > BetterGrudges (or right-click the minimap button) you
choose where marks show, whether kindnesses get one, and their size.

## The book

Open it with `/grudge` or the minimap button.

- Everyone you have met on the left, with their race portrait and class
  colour, open grudges first. A search box finds a name; Add starts a page for
  a new player, with your target's name already filled in.
- Their page on the right, newest entry first.
- Buttons below the page write a grudge, a kindness or a note, forgive all
  their grudges, or tear the page out.

## Writing your own

Right-click a player (their portrait, a nameplate, a party or raid frame, or
their name in chat) and choose **Add to the book**. A grudge comes with
ready-made reasons, one click each: rude, ninja looter, stole my objective,
tagged my mob, ganked me, left the group. Or write your own.

## Commands

| Command | Action |
| --- | --- |
| `/grudge` | Open the book |
| `/grudge config` | Open the settings |
| `/grudge <name>` | Open their page (`target` works as a name) |
| `/grudge <name> <text>` | Write a note on their page |
| `/grudge forgive <name>` | Settle all their open grudges |
| `/grudge remove <name>` | Tear their page out of the book |
| `/grudge list` | List the book in chat |
| `/grudge quiet` | Stop printing new entries to chat |
| `/grudge minimap` | Hide or show the minimap button |
| `/grudge marks` | Hide or show the marks on unit frames and nameplates |

The book is shared by all your characters, one book per realm.

## Good to know

This client keeps the combat log from addons, so BetterGrudges works from
what it can see: the player who had you targeted when you died counts as your
killer, and your kills come from the honourable-kill message, so low-level
players you defeat aren't noted.
