# Ward

A menu-bar app that keeps you on task. It watches what's actually in front of you and
steps in when it isn't study — not just *which site*, but *which video*.

Everything runs on this Mac. No account, no server, no extension, nothing downloaded
at runtime. The language model it uses for judging titles is the one already built
into macOS.

---

## Getting it running

```bash
~/Ward/build.sh --install
```

That compiles it, wraps it in `Ward.app`, installs it to `/Applications` and launches
it. A shield appears in your menu bar.

A fresh copy opens with a short welcome that walks through the permissions and offers
to block a few of the apps you have open. It appears only when there is no rulebook on
disk yet, so upgrading never shows it.

Then grant two permissions — Ward opens the first panel for you:

| Permission | Where | What breaks without it |
|---|---|---|
| **Accessibility** | Privacy & Security → Accessibility | Ward can't read window titles. Nothing works. |
| **Automation** | Privacy & Security → Automation → Ward | Ward can't read exact URLs or redirect a tab. It falls back to hiding the browser. |

One optional extra, for judging videos by their **tags and description** rather than
the title alone:

- **Safari** — Settings → Advanced → "Show features for web developers", then
  Develop → Allow JavaScript from Apple Events
- **Chrome / Brave / Edge / Arc** — View → Developer → Allow JavaScript from Apple Events

Without it Ward just uses the title, which handles most cases anyway.

---

## How something gets blocked

A page is checked in this order. The first rule that fires wins.

1. **Not a web page** → left alone.
2. **Allowed site** → allowed, whatever else it says.
3. **Blocked URL pattern** (regex) → blocked.
4. **Blocked site** → blocked.
5. **Judged by content** → the interesting one, below.
6. Anything else → allowed.

For a site in the *judge by content* list (YouTube and friends), the title — plus
tags and description if deep reading is on — goes through:

1. **Never-allowed phrase** → blocked outright. Game names live here. This beats
   everything, so `Minecraft Redstone Tutorial` is blocked despite the word *tutorial*.
2. **Only an allow phrase matched** → allowed.
3. **Only a block phrase matched** → blocked.
4. **Both matched** → the model breaks the tie. `Past Paper Walkthrough: Edexcel Maths`
   is study; the same rule stops a generic academic word from rescuing a distraction.
5. **Neither matched** → the model decides.

### What the model actually does

macOS ships sentence embeddings — a way of turning a sentence into 512 numbers where
similar meanings land near each other. Ward embeds your example sentences once, embeds
the video title, and measures which side it's nearer to.

```
"minecraft survival gameplay part 12"   →  gaming 1.026   study 1.224   lean +0.198
"How to Solve Quadratic Equations"      →  gaming 1.284   study 1.125   lean -0.159
```

**Lean** is the whole thing: positive means it reads like a distraction. A title is
blocked when its lean is above the **threshold** on the Content tab. Lower the
threshold to block more.

The default is `+0.03`, deliberately on the permissive side. In testing, clear study
material lands between `-0.03` and `-0.19`, clear distraction between `+0.05` and
`+0.35`, and genuinely ambiguous things cluster near zero. A false block on real
revision material is far more annoying than a false allow, and the never-allowed list
catches the obvious cases deterministically anyway.

You are not stuck with the defaults. The **Content** pane opens with a box where you
paste any title and watch where it lands on a scale from study to distraction — the
dot is the title, the line is your threshold. Drag the threshold past the dot and the
verdict flips. Every phrase and example sentence is editable right underneath.

---

## Getting around

Ward is a normal app: Dock icon, Cmd-Tab, menu bar. Settings → General can demote it to
menu-bar-only if you'd rather it stayed out of the way.

| Shortcut | |
|---|---|
| `⌘,` | Settings |
| `⌘⇧D` | Dashboard |
| `⌘+` / `⌘−` | Zoom in / out |
| `⌘0` | Back to 100% |
| `⌥⌘S` | Toggle sidebar |

Zoom changes the type size and re-lays the window out rather than magnifying it, so text
stays sharp at every step from 80% to 200%. The setting persists.

A sidebar, five panes:

| Pane | What's in it |
|---|---|
| **Overview** | On/off, permission status, what Ward is looking at right now, recent blocks |
| **Apps** | Which apps get blocked, and whether they're quit, hidden, or just flagged |
| **Sites** | Allowed, blocked, judged-by-content, and URL patterns |
| **Content** | The title tester, the threshold, and every phrase and example the model uses |
| **Session** | The commitment lock |

Timings, the shield, start-at-login and the rules file live in **Settings** (`⌘,`).

Phrase and domain lists are chips, so a rule you added weeks ago is visible at a glance
rather than buried in a scrolling box. Hover one to remove it. The long example-sentence
lists start folded — click the header to open them.

---

## Day to day

**There is no off switch, and no pause.** Both existed once and both were removed —
not hidden, not guarded harder, gone from the menu, the dashboard, the hotkeys and the
schedule. A blocker you can turn off for "just a second" turns off for the rest of the
afternoon; this one can't. See *Staying on* below for the one way out that's left.

**One page, just this once.** When something is blocked and you genuinely need it,
*Just this once…* grants a pass that expires on its own. The scope follows whatever did
the blocking — a site rule earns a site-wide pass, a content rule earns a pass for that
page only, so letting one video through doesn't open all of YouTube. Live passes are
listed on the Overview with the time left and a button to end them early.

**Study hours.** Settings → Behaviour can have Ward switch itself on at set times,
including windows that run past midnight. It only ever switches *on* — a schedule can't
be the off switch in disguise — and it only takes over at a boundary, so overriding it
by hand inside a window sticks.

**Closing the window quits that process — and Ward keeps watching anyway.** Ward is
two processes sharing one app: a plain windowed app that quits like any other when its
window closes, and an invisible background agent that holds the menu bar and takes the
watching back the moment the window is gone. Reopening Ward starts the windowed half
again; Settings → General can take away its Dock icon and the agent's menu bar icon
too, so the whole thing runs completely unseen.

**Shortcuts that work anywhere**, so a correction doesn't mean leaving the video:

| | |
|---|---|
| `⌃⌥⌘B` | Block what I'm looking at |
| `⌃⌥⌘A` | Allow what I'm looking at |
| `⌃⌥⌘P` | Turn Ward back on (there's nothing left for it to turn off) |
| `⌃⌥⌘W` | Bring the window back |

`⌃⌥⌘W` matters most when Ward is running invisible: with no icon to click, reopening the
app only activates it, so the shortcut is the way in. Leave shortcuts enabled if you
turn both icons off.

Ward registers exactly these three combinations with the system. It does not watch your
typing — a global keyboard monitor would have been simpler and is not a reasonable
trade for a convenience shortcut. They can be switched off in Settings → General.

**It tells you when it changes state.** A commitment session finishing gets one
brief confirmation with what it was worth ("50 minutes, 7 stopped along the way")
rather than just going quiet.

**History.** Every block is written to `events.jsonl`, so the record survives a restart.
The History pane shows today and the last seven days, what gets stopped most, why, and
your worst hour — enough to tell whether any of this is helping.

---

## Getting past it

Switching a blocker off takes a second, which is exactly the problem. **Settings →
Behaviour → Getting past Ward** puts something in the way first. Pick one:

| | |
|---|---|
| **Retype a passage** | Copy a block of nonsense words exactly, commas and capitals included. Pasting is detected and clears the field. |
| **Work out a sum** | A chain of arithmetic to carry in your head. Only the exact number is accepted, and a wrong answer starts a fresh one. |
| **Repeat a sequence** | Watch tiles light up, then tap them back. One wrong tile and the round replays. |
| **Sit and wait** | Do nothing. The clock only runs while the window is in front, so switching away doesn't help. |
| **Surprise me** | A different one each time, so you never get quick at any of them. |

### The dial

Difficulty is one slider, labelled as an IQ number from 70 to 200. It is a dial, not a
measurement — it decides how much work stands between you and switching Ward off, and
nothing else.

| IQ | words | sum | memory | wait |
|---|---|---|---|---|
| 70 | 8 | 3 steps, to 25 | 4 at 540ms | 5s |
| 100 | 22 | 5 steps, to 145 | 6 at 450ms | 1m 05s |
| 115 | 33 | 6 steps, to 205 | 8 at 405ms | 1m 35s |
| 145 | 59 | 10 steps, to 325, with squares | 12 at 315ms | 2m 35s |
| 200 | 120 | 17 steps, to 545, with squares | 20 at 150ms | 4m 25s |

The curve is mildly super-linear, so the bottom stays a token gesture, the middle is
already real work, and the top is punishing.

**Every one of the 131 points asks a different batch of questions.** Comma and capital
cadence in the passages, the size of the numbers, and the flash speed all shift on each
individual point, so IQ 130 never hands you an IQ 131 question.

**No question is ever asked twice.** Each generated puzzle is signed and the signature
kept in `puzzles-seen.json`, across restarts. A question you have seen before is one you
can answer from memory, which would defeat the whole thing. Waits are the exception —
there is nothing about "wait 95 seconds" to make unique — and at the very bottom of the
dial the pool of possible sequences is small enough to exhaust, in which case Ward
forgets its oldest rather than refusing to ask anything. There is a counter in Settings
and a button to forget them all.

You also choose which actions have to be earned: turning Ward off, pausing it, or
letting a blocked page through. The `⌃⌥⌘P` shortcut goes through the same gate, so it
isn't a way round.

A challenge is required whenever the action would weaken things, including turning Ward
off while it is merely paused — a pause expires on its own, being switched off does not,
so that is still a weakening. Guarding the off switch while leaving pause open is close
to guarding nothing, and Settings says so with a one-click fix.

**Cancelling always leaves the rules exactly as they were**, so the safe direction is
the easy one. The point is friction against an impulse, not a lock you can't open.

The generator is tested rather than trusted. 1,680 arithmetic chains across the whole
dial are re-derived from the wording of their own printed instructions to prove they are
solvable; values never go negative (where "round down to a multiple of 3" would be
ambiguous) and never grow past the point where nobody would actually do the
multiplication; difficulty never goes backwards as the dial rises; every point differs
from its neighbour; and 300 consecutive questions come back with no repeats.

There's a **Try it** button that runs a dry puzzle so you can see what you're signing
up for; finishing or cancelling it changes nothing.

---

## Practice

A **Practice** pane runs the same puzzles with nothing riding on them. Useful for
finding out what a point on the dial actually feels like before you make your rules
depend on it, and fine as a warm-up between pieces of work.

It keeps its own kind and IQ, separate from the setting that guards your rules, so
playing here can never quietly change what stands between you and switching Ward off.
It scores solved count, current and best streak, average time, and your fastest time
per puzzle kind. Skipping breaks the streak.

Practice draws from the same ledger, so a question you meet here is still never asked
again — including as a real challenge later.

---

## Teaching it

It gets things wrong. When it does, correct it and the correction sticks.

On the **Overview** pane, under whatever Ward is currently looking at, there's a
**Got it wrong?** row with two buttons — or use the same commands straight from the
menu bar without opening the window. One click and:

Ward acts on the layer that actually applies to the page you're on, and names what it
changed:

- **On a site judged page by page** (YouTube and friends), the title joins the model's
  examples, so **similar titles move too**.
- **On any other site**, the phrase and model rules never run at all — so a lesson about
  the title would be stored and never consulted by anything. Ward blocks the **site**
  instead, and tells you so: *"Blocked crazygames.com — it's in Sites → Always blocked."*
  The same in reverse for "should be allowed".

Either way there's an **Undo** next to the result that names exactly what it would take
back.

- The title joins the model's examples for that side, so **similar titles move too**.
  Teaching it that `the problem with forza horizon 6` is a distraction moved
  `The Problem With Modern Cars` by **+0.215** — from allowed to firmly blocked.
- The page you're on is **re-judged immediately**, not just the next one.
- If the correction alone wasn't enough — usually because a phrase rule settles it
  first — Ward says so and offers the specific terms from the title as one-click
  never-allowed phrases. Correcting `How to Build a Gaming PC — Full Tutorial` offers
  `gaming pc`, `build gaming`, `gaming`.

Everything you teach it is listed on the **Content** pane under *Taught: distraction*
and *Taught: study*, and any lesson can be removed. A misclick is one **Undo** away —
the button sits next to the result.

### Why lessons have a reach

A taught title is an arbitrary sentence dropped into the model's example set, and
that turns out to be dangerous if you let it apply everywhere. In this space most
distances sit between 0.4 and 0.7, so being merely the *nearest* example is a weak
signal. Teaching a Forza title as a distraction originally caused
`Cell Division: Mitosis and Meiosis compared` to be blocked — the racing title landed
closer to it (0.502) than any curated distraction example (0.656), on nothing but
sentence shape.

So a lesson only counts within a **reach** — 0.45 by default. Beyond that radius it's
ignored entirely:

| title | distance to the taught one | applies? |
|---|---|---|
| the problem with modern cars | 0.402 | yes |
| cell division mitosis and meiosis | 0.502 | no |
| linear algebra lecture | 0.586 | no |

Corrections are high-precision by design: a lesson can only move things genuinely
close to what you taught. For anything broader, promote a phrase — that's what the
suggested terms are for. The reach is tunable on the Content pane once you've taught
it something.

---

## Keeping the rules honest

A rule that looks active and quietly does nothing is worse than no rule, so Ward calls
these out rather than letting them sit there looking reassuring.

**Content rules only reach the sites judged by content.** Every phrase and example on
the Content pane is skipped entirely on any other host — a "never allowed" phrase is not
a blanket ban. The pane names the sites they apply to, and says plainly when the list is
empty and all of them are inert.

**A schedule that describes no time is ignored, not obeyed.** Deselecting every day used
to switch Ward off with no boundary that could ever turn it back on.

**The last way into the window can't be closed.** Dock icon, menu bar icon and the
shortcut are the only three routes; turning off all three would leave no way to open
Ward at all, so the menu bar icon comes back.

**Deep reading says when it is being refused.** If the browser won't run JavaScript from
another app, the toggle used to read as on while Ward judged on the title alone.

**A blocked app that isn't installed is flagged.** An entry whose identifier resolves to
nothing can never match, and now says so instead of looking blocked.

**A threshold that's too low.** Set it aggressively and you don't find out until a
lecture you needed gets blocked. The Content pane runs a set of unambiguous study
titles through the real pipeline and names any it would stop, with a one-click return
to the default.

**Phrases that can never fire.** Lists grow as you teach, and once "gaming" is a rule,
adding "gaming pc" changes nothing — a title containing the second always contains the
first. New entries like that are refused with the reason, and existing ones are
collected into a *Tidy up* button. The shipped defaults had six.

**Backup.** Settings → Advanced exports the rulebook and imports one back. Merge only
ever adds, and deliberately will not take another file's allow-list, since that is the
one list where adding an entry weakens your rules. A running commitment session and
this machine's interface settings survive either mode.

---

## Apps

Add apps from the running list or from `/Applications`. Ward watches for launches and
also sweeps every few seconds, so a blocked app can't quietly sit in the background.
Choose whether it gets quit, hidden, or merely flagged.

Finder, Dock, System Settings and Ward itself can never be blocked, however the rules
are edited — blocking them would lock you out of your own machine.

---

## Staying on

**Settings → Advanced → Always on** installs a launchd agent that starts Ward at login
and restarts it if it's ever force-quit. It's install-only — the switch adds it, but
taking it away again is the deliberate Terminal command below, not a toggle in the app.

**Commitment session** locks a stretch of time, up to 8 hours. While it's running,
rules can be tightened but not loosened, and neither Ward process will quit for it —
only the system asking, at logout or shutdown, gets past that. It holds against the
obvious ways round it too: Reload is disabled, editing `lockUntil` out of the file and
reloading won't take, and "should be allowed" is refused until the session ends.

### There is no off switch — here's the way out anyway

Turning Ward off, pausing it, and quitting it are all gone: not one button among them
survived past the point where Ward reads as genuinely unable to be switched off by a
moment of wanting to. Force-quitting doesn't help either — the launch agent treats
that as a crash and brings Ward straight back. That's deliberate, and it means the
only way out left is a deliberate one:

```bash
launchctl bootout gui/$UID/app.ward.agent 2>/dev/null
rm -f ~/Library/LaunchAgents/app.ward.agent.plist
python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Ward/rules.json');d=json.load(open(p));d.pop('lockUntil',None);d['enabled']=False;json.dump(d,open(p,'w'),indent=2)"
pkill -x Ward
```

What each line does, in order: stops the background agent that's running right now;
deletes the login agent so nothing brings it back at next login; edits the rulebook on
disk so a reopened Ward starts switched off and out of any commitment session; and
quits both of Ward's processes — the windowed app if it's open, and the agent if the
first line somehow left it standing. Run it from Terminal, not from inside Ward.

To turn it back on later: open Ward and click **Turn Ward on** — on the Overview, or
in the menu once the agent's back — or edit `enabled` back to `true` in `rules.json`
yourself. Reinstalling the login agent is `~/Ward/build.sh --install`, same as day one.

---

## Why rebuilding used to break permissions

An ad-hoc signature's *designated requirement* — how macOS decides that an app is the
same app it saw before — is a hash of the code itself:

```
$ codesign -d -r- /Applications/Ward.app
# designated => cdhash H"8d22d1cebe8841450d17d0a392f89b3faa7428f2"
```

Change one byte and that hash changes, so a rebuilt Ward is a *different application*
as far as the system is concerned. The permission you granted no longer applies. What
makes it genuinely confusing is that System Settings keeps showing a "Ward" entry with
the switch on — that entry belongs to the build you granted, and the switch looks
correct while doing nothing.

Ward never raises the system's "Accessibility Access" dialog by itself — only pressing a
button can, and only the first time. If that dialog ever appears to be stuck in a loop,
it is a *queue* of prompts held by the system's dialog host rather than one dialog
reappearing; `killall UserNotificationCenter` clears the lot (macOS relaunches it on
demand).

Ward detects the stale-entry case and says so on the Overview, with the steps to fix it. To ask
what the system actually tells the app, rather than what a toggle looks like:

```bash
/Applications/Ward.app/Contents/MacOS/Ward --doctor
```

### Stopping it for good

```bash
~/Ward/setup-signing.sh
```

This creates a self-signed code-signing certificate in its own keychain with a
generated password, so the requirement becomes *"this bundle id, signed by this
certificate"* — which survives rebuilds. One step needs an administrator, because
macOS will not sign with an untrusted certificate; `sudo` handles your password and
the script never sees it. Run it once, rebuild, grant Accessibility a final time.

`build.sh` uses the certificate when it is there and falls back to ad-hoc when it
isn't, telling you which it did.

---

## Checking your rules

```bash
~/Ward/check.sh                              # run the suite against your live rules
~/Ward/check.sh "Some Video Title Here"      # judge one title, with the numbers
~/Ward/check.sh --margin 0.03                # try a threshold without saving it
~/Ward/check.sh --learn "taught title" "probe title"   # see how far a lesson spreads
```

The app itself can rasterise its panes without opening a window, which is handy for
checking layout after a UI change:

```bash
/Applications/Ward.app/Contents/MacOS/Ward --render ~/Desktop   # panes to PNG (read-only)
/Applications/Ward.app/Contents/MacOS/Ward --dump-menu          # menu tree + shortcuts
WARD_TIMING=1 /Applications/Ward.app/Contents/MacOS/Ward        # launch phase timings
```

`WARD_TIMING` measures from when the kernel started the process, not from the first
line of Ward's own code, so it catches time spent before `main` as well:

```
[timing]   304.8 ms  dashboard on screen
[timing]   479.7 ms  first tick
```

Worth running after you edit examples — it reads the same `rules.json` the app does,
so it tells you what the app will actually do.

---

## Where things live

| | |
|---|---|
| Rules | `~/Library/Application Support/Ward/rules.json` — plain JSON, hand-editable |
| History | `~/Library/Application Support/Ward/events.jsonl` — one block per line |
| Block page | `~/Library/Application Support/Ward/blocked.html` |
| Login agent | `~/Library/LaunchAgents/app.ward.agent.plist` |
| App | `/Applications/Ward.app` |

`rules.json` decodes leniently: a missing or misspelled key falls back to its default
instead of throwing the whole file away. Edit it freely, then hit **Reload** under
Settings → Advanced → Rules file.

---

## Known limits

Worth knowing before you rely on it:

- **Firefox has no AppleScript support.** Ward reads its window title and lifts the URL
  out of the address bar via Accessibility, but it can't redirect a tab — it hides the
  window instead. Everything works properly in Safari and the Chrome family.
- **This is a speed bump, not a sandbox.** It watches the frontmost window about once a
  second. A determined person can pause it, edit the rules, or quit it between ticks.
  That's the intended trade — it's built to beat drift, not to beat you.
- **Rebuilding resets permissions, unless you run `setup-signing.sh`.** See below.
- **A crash or a force-kill brings Ward back; a deliberate Quit does not.** The launch
  agent restarts it only on an abnormal exit, so "always on" survives something going
  wrong without overriding you when you mean it.
- **Private windows** aren't readable in Safari via AppleScript.
- **Universal binary** needs full Xcode. With Command Line Tools only you get a native
  build for this Mac, which is what `build.sh` falls back to.
