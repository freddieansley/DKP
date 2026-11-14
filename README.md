# dkp — Pork Bucks attendance tracker (Ashita v4)

An attendance monitor for linkshell events. It watches your alliance list during an event, works out each member's Pork Bucks from the rules below, and writes a file you paste into the DKP spreadsheet.

## What it does and does not do

**Does**

- Reads the alliance list your game client already shows you (names, jobs, zones).
- Shows a window with the live roster, time attended and points.
- Writes text files inside its own folder on your PC.

**Does not**

- Send anything to the game server or inject packets.
- Issue game commands, key presses or chat messages.
- Automate any gameplay (no targeting, claiming, casting or movement).
- Connect to the internet or to the spreadsheet.

## Install

1. Create the folder `Ashita\addons\dkp\`.
2. Put `dkp.lua` in it.
3. Create `roster.txt` in the same folder (see "The roster file").
4. In game: `/addon load dkp`

`/dkp` shows or hides the window. That is the only command.

## Point rules

| Event type | Points |
|---|---|
| Dynamis, Sky | 1 for being on time, 1 per hour attended (a partial hour rounds up), 1 for a complete run |
| HNM | 1 per window attended, 1 for the claim, 1 for the kill |

- **On time** means in the alliance within 5 minutes of clicking Start Event.
- **Per hour** has a 5-minute grace: 3h04m counts as 3 hours, 3h06m counts as 4.
- **Complete run** goes to everyone present when you end the event with the "Complete run" box ticked.
- **HNM points** go to everyone present at the moment you click Window, Claim or Kill.

## Running an event

1. Pick the **event type** and the **event** from the two dropdowns, or type a custom name.
2. Click **Start Event**.
3. During the event:
   - **HNM:** click **Window**, **Claim** and **Kill** as they happen.
   - **Dynamis / Sky:** tick **Complete run** before ending if the run was completed.
   - **Winning bid:** pick the player, type the item and the bid, click **Record winning bid**.
   - **Bonus or penalty:** pick the player, set the points (negative is allowed), click **Give bonus to player**, or **Give bonus to all present**.
   - **Someone outside your alliance:** type their name and click **Add player outside alliance**. They count as present until you click **Remove** next to their name.
4. Click **End Event**, then **Yes, end and save**.

The game client only knows your own alliance (18 people). In a bigger run, anyone outside your alliance has to be added by hand.

## Getting the points into the sheet

When an event ends, two files appear in `Ashita\addons\dkp\logs\`:

| File | Use |
|---|---|
| `<date>_<type>_<event>_paste.txt` | The block to paste into the DKP sheet |
| `<date>_<type>_<event>.csv` | Full detail per player (minutes, each point type, bids), for checking or disputes |

To paste:

1. Open the `_paste.txt` file, select all, copy.
2. In the sheet, insert a new column at **E**.
3. Click cell **E1** and paste.

The first row is the header, for example `15NOV DYNA XARC` or `15NOV FAF`. Each winning bid gets its own column, headed `BID <ITEM>`, with the negative amount on the winner's row.

## The roster file

`roster.txt` tells the addon which row each member is on. It must match the sheet's NAME column exactly, top to bottom.

- **Create it:** copy the NAME column from cell **A4** down and paste it into `roster.txt`, one name per line. Leave blank lines where the sheet has blank rows between names.
- **Keep it current:** whenever you add, remove, reorder or sort rows in the sheet, copy the NAME column into `roster.txt` again. The addon reads the file fresh every time an event ends, so updating it mid-event is fine.
- **New people:** anyone at an event who is not in `roster.txt` is added to the bottom of the file, and the chat log lists them. Add them to the bottom of the sheet in the same order before you paste.

Upper or lower case does not matter. Spelling does.

## If you disconnect or crash

The running event is saved to `state.lua` every 10 seconds and after every button click.

- **Dropped to the title screen, client still open:** the event keeps running and catches up when you are back in.
- **Client closed or crashed:** when the addon loads again, the window offers three choices.

| Choice | Result |
|---|---|
| Resume (run is still going) | Continues the event. Members still in the alliance get credit for the time you were gone. |
| Finish it as saved (run is over) | Writes the sheet files using attendance up to the last save. |
| Discard | Throws the event away. |

## Changing settings

Open `dkp.lua` in a text editor. Everything adjustable is near the top. After saving, run `/addon reload dkp` (not during an event you care about, although the failsafe will offer to resume it).

### Point values and timing: the `cfg` table

| Setting | Default | Meaning |
|---|---|---|
| `pts_ontime` | 1 | Dynamis/Sky: on-time point |
| `pts_hour` | 1 | Dynamis/Sky: points per hour attended |
| `pts_complete` | 1 | Dynamis/Sky: complete-run point |
| `pts_window` | 1 | HNM: points per window |
| `pts_claim` | 1 | HNM: claim point |
| `pts_kill` | 1 | HNM: kill point |
| `ontime_min` | 5 | Minutes after Start Event that still count as on time |
| `grace_min` | 5 | Minutes past the hour that do not count as an extra hour. Set to 0 for strict rounding up. |
| `poll_sec` | 5 | How often the alliance list is checked, in seconds |
| `autosave_sec` | 60 | How often the detail CSV is rewritten during an event |
| `state_sec` | 10 | How often the crash failsafe is saved |

Example: to make a kill worth 2 points, change `pts_kill = 1,` to `pts_kill = 2,`.

### Event menus: the `TYPES` table

Each line in an `events` list is one dropdown entry:

```lua
{ label = 'Fafnir / Nidhogg', short = 'FAF' },
```

- `label` is what the dropdown shows.
- `short` is the column header in the sheet (the date is added in front automatically).

Add, remove or rename lines to change the menus. To add a new event type, copy a whole block (for example the Sky block), give it a new `id` and `label`, and set `mode` to `'timed'` for Dynamis-style rules or `'hnm'` for window/claim/kill rules.

## Files in the addon folder

| File | Purpose |
|---|---|
| `dkp.lua` | The addon |
| `roster.txt` | Your sheet's NAME column, in order |
| `state.lua` | Failsafe copy of the running event; removed when the event ends |
| `logs\` | Paste files and detail CSVs, one pair per event |
