# Buddy Mode — on-device test protocol

**This is the acceptance test for Buddy Mode.** Everything else the mode has —
1072 app tests, 521 `board_vision` tests including the scored corpus, a clean
analyzer on seven packages — runs on a machine with no camera, no microphone,
no gyroscope and no backgammon board. None of it can tell you whether a phone
pointed at your board plays a game of backgammon with you.

So this document is the part of the gate a person has to walk through, holding
a phone, at a real board. Run it **once per release** that touches Buddy Mode,
on **each device family you ship to** (one Android, one iPhone).

It has two parts, and the order is load-bearing:

- **Part 1 — the open questions.** Eight things that ship as *arithmetic rather
  than measurement*, in priority order. The first one is a correctness question
  that can invalidate everything measured after it, so it runs before anything
  else. Items 2–8 are numbers and behaviours that want their first contact with
  reality.
- **Part 2 — the scripted match.** A calibration and one short game against
  Buddy, with twelve checkpoints covering every path the mode has: dice, plays,
  dictation, corrections, objections, an outage, a recalibration, the cube, a
  dance, and the match landing in History.

Write your answers down. Several of these are numbers that go back into the
source as a measured value replacing a guess, and "it seemed fine" is not a
value.

---

## Before you start

**Kit**

- A real backgammon board — ideally the **folding case** kind, because that is
  the harder calibration (eight handles rather than four) and it is what most
  people own. If you have two boards, run Part 2 on both.
- Two dice you actually throw. Not placed — thrown.
- A phone stand, a stack of books, or anything that holds the phone still
  looking down at the board. Buddy is built for a phone that is *put somewhere*,
  not held.
- A room where you can change the light: a lamp you can switch off, a curtain.

**Build**

```powershell
# Android
cd app; flutter run --release -d <device>
# iOS
cd app; flutter run --release -d <device>
```

A **release** build, not debug: the frame pipeline does real floating-point work
per frame and debug-mode Dart is roughly an order of magnitude slower at it.
Timing anything in Part 1 on a debug build measures the debug build.

**Settings to check first** (Settings → Buddy Mode)

- *How Buddy talks* — leave at **Terse** for the run; it is the shorter line and
  the easier one to hear a mistake in. Item 12 in Part 2 switches it.
- *Listen for the dice* — **on**. It is what Part 1 item 3 measures.

**Turn the volume up.** Half of Buddy's output is speech; a muted phone turns
this protocol into a test of the screen only.

---

# Part 1 — the eight open questions

## 1. The preview↔frame mapping — BLOCKING, run this first

**Why it is here.** Every overlay on the calibration screen — the handles, the
derived point columns, the loupe, the belief drawn over the board — maps a
normalized *frame* coordinate straight onto the *preview box*. That is correct
only if the preview shows the whole sensor frame, the same way up, unmirrored
and unletterboxed. `CameraPreview`'s own `AspectRatio` is deliberately squelched
by a `Positioned.fill` (it stretches rather than letterboxes), and **there is no
rotation or mirroring handling anywhere in Buddy Mode.** The assumption is
stated in full at `_CalibrationScreenState._preview`
(`app/lib/screens/buddy/calibration_screen.dart`) and again at
`PhoneBuddyCamera.preview` (same file — the plugin edge lives at the bottom of
it).

**Why it is first.** If sensor and preview disagree, the failure is **silent**:
the outline still looks plausible, the calibration may well succeed, and every
column is simply in the wrong place. Every number you measure in items 2–8 would
then be a number about a broken coordinate frame.

**What to do**

1. Home → **Play with Buddy** → **Calibrate the board**, and get to the
   **corners** stage (the one with the draggable handles).
2. In **landscape**, drag one handle onto a corner of the felt you can name —
   say the near-left one. Let go.
3. Now watch that handle while you *nudge the phone* a few degrees and let it
   settle. Then drag it again, deliberately, to the corner one over.
4. Repeat in **portrait**.

**Pass (landscape)** — the handle sits on the corner you put it on and stays
there. The twelve derived column lines down each half land on the twelve points,
not between them. Dragging moves the handle in the same direction as your
finger, at the same speed.

**Fail** — any of: the handle lands somewhere other than where you dropped it;
it moves the wrong way, or mirrored left-right; the column lines are rotated 90°
against the points; the outline is a plausible quadrilateral but the columns are
systematically offset.

**Portrait is expected to fail loudly** — a preview turned on its side. That is
a known and acceptable outcome for the MVP if landscape is right; **landscape is
the aiming that matters** and the one Buddy is designed around. Record what
portrait actually did, because "loudly" is the claim being tested: a portrait
failure that is *silent* (plausible-looking, quietly wrong) is a worse finding
than one that is obvious, and it changes what the mode must do about it.

**Write down:** landscape pass/fail; portrait's exact failure mode; whether the
device mirrors (front camera is not used, but confirm the rear preview is not
mirrored).

**If landscape fails, stop.** Nothing below is meaningful and the fix is a
rotation/mirroring transform between the sensor frame and the preview box.

---

## 2. The opening seat margin — `kOpeningSeatMargin`

**Why it is here.** Each player throws one die for the opening, and **which die
belongs to whom decides who starts, which is recorded in the game log and spoken
aloud**. Buddy decides it geometrically: board space's `y` runs far→near as the
camera sees it, so the die with the larger `y` is the near-seated player's. But
the dice band is only `y ∈ [0.42, 0.58]` — 0.08 of board height per seat — so a
die that bounced towards the middle is the ordinary case, not an edge case.
`kOpeningSeatMargin = 0.02` (`app/lib/buddy/buddy_session.dart`) is how far
clear of the midline a die must come to rest to be attributed at all. Below it,
Buddy **refuses rather than guesses** and falls back to the pre-seat convention.

The number is derived, not measured: ten cells of `DiceReader`'s own 80-cell band
lattice below it, and under a third of where a thrown die comes to rest above it.

**What to do**

Throw the opening pair **fifteen times**, properly — from the cup, onto the
board, from both sides of the table. After each throw, before touching anything,
note where the two dice actually came to rest relative to the bar/midline.

Then start a Buddy session for real and throw the opening ten times, restarting
the session each time, and record for each throw: did Buddy attribute the dice
to the right players, or did it fall back?

**Pass** — at least 8 of 10 attributed correctly, and **zero** attributed
*incorrectly*. A fallback is a nuisance; a wrong attribution is a corrupted game
record and is the failure that matters.

**Fail** — any wrong attribution, or so many fallbacks that the geometric path
is not carrying its weight.

**Write down:** the count of correct / fallback / wrong, and roughly how far
from the midline the near-midline throws landed. If fallbacks dominate, the
margin is too big; if there is a wrong attribution, it is too small — and either
way the answer is a measured number to replace 0.02.

---

## 3. The six microphone constants, under a real room's AGC

**Why it is here.** The dice-sound trigger separates an **impulse** from a
**sustained** sound, and that is the whole discrimination. It has six constants
(`app/lib/buddy/dice_sound_trigger.dart`), all six of them arithmetic:

| Constant | Ships as | What it does |
|---|---|---|
| `kDiceAttackDecibels` | 12.0 dB | how far over the running room floor a hop must jump to start a candidate |
| `kDiceQuietDecibels` | 6.0 dB | how close to the floor it must fall back for the candidate to fire |
| `kDiceDecayWindow` | 250 ms | how long it has to fall back in — this is the constant carrying the discrimination |
| `kDiceRefractory` | 700 ms | how often, at most, the detector may spend a hint |
| `kRoomFloorTimeConstant` | 1500 ms | how fast the running room floor climbs to meet a room that stays loud |
| **`kDiceFloorDecibels`** | **−45 dBFS** | **the absolute floor; the most device-sensitive of the six** |

`kDiceFloorDecibels` is the one to watch. It is an **absolute** level in dBFS,
and dBFS on a phone microphone is a function of that phone's preamp gain and its
automatic gain control. The three audio-processing options (`autoGain`,
`echoCancel`, `noiseSuppress`) are switched **off explicitly** — all three exist
to flatten sudden changes in level and a sudden change in level is the entire
signal — but a device may still apply gain below the API. So −45 dBFS may be far
too low on one phone and far too high on another, and the symptom differs: too
low and quiet-room rustles fire it, too high and real dice never do.

Nothing is recorded. The audio never leaves the device, never reaches a file,
and is reduced to one number per 16 ms and dropped.

**What to do**

- **True positives.** In a normal room with the phone on its stand, throw the
  dice **twenty times**. Count how many throws visibly shortened the wait —
  the readability/reading response arriving noticeably sooner than a throw with
  the hint off. Run ten of the twenty with *Listen for the dice* **off** in
  Settings as your baseline; the point is the difference, and a stopwatch on
  twenty throws is worth more than an impression.
- **False positives, the budget.** Now leave a session waiting for a throw and
  **do not throw**, for **five minutes**, with the room being a room: talk,
  play music or a television, move a chair, set a glass down, close a door.
  Count the hints that fire. The end-of-session analytics event carries the
  count (`buddy_session_ended`, field `mic_hints`, alongside `mic_state`) if you
  would rather read it than count it.
- **Quiet room.** Repeat for two minutes in a silent room, doing nothing. This
  is `kDiceFloorDecibels`'s test: a silent room should fire **zero**.

**Pass** — throws are heard **most** of the time (this is an optimization, not a
dependency; a miss costs a few hundred milliseconds and nothing else); the noisy
room fires **no more than a handful** over five minutes; the silent room fires
**zero**.

**Fail** — the silent room firing at all (`kDiceFloorDecibels` too low for this
device); a busy room firing continuously (the detector never leaves its fast
cadence, which burns battery for nothing — the window and the refractory are the
two knobs, and both are constructor parameters); or throws essentially never
heard (`kDiceAttackDecibels` too high, or the device's AGC is flattening the
attack despite the flags).

**Known and accepted:** the detector separates dice from *speech and television*,
not from *other impulses*. A door knock, a clap, a snare drum on the radio all
fire it. That costs one early look at a board that has not changed. Do not
record those as failures — record the rate.

**Write down:** hints per twenty throws (hint on vs off), the wall-clock
difference if any, false positives in five noisy minutes, false positives in two
silent minutes, and the device model. The last one matters more than usual here.

---

## 4. The Android APK build — watched in CI, confirmed here

**Why it is here.** Buddy Mode's `record` dependency (the dice-sound hint) is a
build-time risk that **nothing on the development machine can see**: there is no
local Android toolchain, and a desktop build never reads a Gradle file.
`record_android` 2.1.2 builds itself with **AGP 9.2.1** where
`app/android/settings.gradle.kts` pins **9.0.1**, and it requires **`compileSdk`
36** — which is exactly Flutter 3.44.8's `flutter.compileSdkVersion`, so there
is **zero headroom** above it.

**What to do**

This one is mostly CI's: `.github/workflows/android.yml` assembles a real APK on
every push, so the failure lands there first, as a Gradle error naming the
version it wanted. Your job is to (a) **check the Android workflow is green for
the commit you are testing**, and (b) confirm the APK it produced actually
installs and starts Buddy Mode on a real phone — a build that compiles and an
app that runs are two claims.

**And read the MERGED manifest, which is the only place this next thing is
visible.** `camera_android_camerax` contributes
`<uses-feature android:name="android.hardware.camera.any" />` with **no
`required` attribute, which defaults to TRUE** — and the app's own optional
declarations name *different* features (`android.hardware.camera`,
`…camera.autofocus`, `…microphone`), so none of them cancels it. Left alone, an
app whose camera is optional in both modes that use one would require a camera
to install, and Play would filter it off every camera-less device.
`AndroidManifest.xml` overrides it with `android:required="false"` **plus
`tools:replace="android:required"`** — the plain attribute loses, because the
merger OR-s the two `required` flags together and the plugin's implicit true
wins. `app/test/android_manifest_test.dart` pins the source line including the
`tools:replace`; **nothing in the repository can check that the merger honoured
it**, which is why it is here:

```powershell
# on the APK android.yml produced (or a local `flutter build apk --release`)
aapt dump badging app-release.apk | Select-String "camera"
```

**Pass** — `android.yml` green, APK installs, Buddy Mode's home tile is present
and the calibration screen opens the camera; and the badging dump shows
`uses-feature-not-required:'android.hardware.camera.any'` with **no** bare
`uses-feature:'android.hardware.camera.any'` line beside it. The Play Console's
**device catalogue** on the uploaded artifact says the same thing in the other
direction: the supported-device count must not fall when Buddy Mode ships.

**Fail** — a Gradle failure naming AGP or `compileSdk`. **The fix is to raise the
pin (or the Flutter channel), not to pin the plugin back**: the requirement is
the plugin's own build script, not a preference. Or: a bare
`uses-feature:'android.hardware.camera.any'` in the badging dump, which means
the `tools:replace` did not take and the install base just shrank.

*(While you are in the dump you will also see
`uses-permission:'android.permission.WRITE_EXTERNAL_STORAGE' maxSdkVersion='28'`.
That is `camera_android_camerax`'s, for capture-to-file paths Buddy Mode never
calls — it takes an image stream and converts frames in an isolate. It is
expected, it is capped at API 28, and nothing ever requests it. See the comment
beside it in `AndroidManifest.xml` for why removing it is not worth the cost.)*

**Write down:** the workflow run and its result; the Flutter version CI used;
the two `camera.any` lines from the badging dump, verbatim.

---

## 5. The permission dialogs, landing over the right prompt

**Why it is here.** Both permissions are asked for **in context** — beside the
thing they are for — and that is a claim about *where on screen the system
dialog appears*, which no test can make.

- **Camera** — asked at calibration. Buddy Mode cannot start without it, and a
  refusal must produce a readable explanation rather than a dead preview.
- **Microphone** — asked the first time a throw is actually waited for, so the
  screen should be showing **"Throw the opening dice — one die each."** (or
  "Throw your dice.") behind the dialog. It opens **once** and stays open for
  the session rather than following each turn: starting a PCM stream is an async
  platform call, and a microphone that opened per throw would still be opening
  while the dice landed.

**What to do**

On a device where Buddy Mode has **never run** (or after clearing the app's
permissions in system settings):

1. Start a Buddy session and reach calibration. **Refuse** the camera.
   → Expect: *"AIGammon does not have permission to use the camera. Allow camera
   access…"*, not a black rectangle.
2. Grant it, and get to the opening throw. Watch **what is on screen behind the
   microphone dialog**.
3. **Refuse** the microphone. Play three or four turns.
4. Restart, grant it, and confirm the system microphone indicator comes on once
   and stays on — it should not blink on and off per turn.

**Pass** — the camera prompt appears at calibration with the preview behind it;
the microphone prompt appears over *"Throw the opening dice"* / *"Throw your
dice"*; a refused microphone changes **nothing** about how the mode plays
(it is an optimization, the mode works identically without it); the indicator is
steady rather than blinking.

**Fail** — a dialog over the wrong screen (worst: the microphone asked at the
home screen or during setup, where there is nothing to explain it); a refused
microphone breaking or degrading play; a camera refusal producing a blank
preview with no explanation.

**Write down:** what each dialog appeared over; the refusal behaviour of both.

---

## 6. The five frame-gate constants — and `kQuietFramesRequired`'s real cadence

**Why it is here.** The frame gate decides when the board is *settled enough to
read*. Four of its constants are properties of a phone sensor, a phone gyroscope
and a room with a board in it, and are marked **Provisional** in
`app/lib/buddy/camera_frame_source.dart`. A fifth is a deliberate budget rather
than a measurement, but is on this list because it is the one you can *feel*.

| Constant | Ships as | Kind | The question for you |
|---|---|---|---|
| `kSceneQuietThreshold` | 0.004 | Provisional | Does a hand over the board clear it (derivation says ~0.098, a hundredfold margin) and does sensor noise stay under it (~0.001)? |
| `kQuietFramesRequired` | 3 | Provisional | **See below — this one has a cadence problem.** |
| `kGyroStillRate` | 0.12 rad/s (~7°/s) | Provisional | Does your phone on your stand read below it? Does a hand adjusting it read above? |
| `kMotionSettleTime` | 350 ms | Provisional | Is that enough for this camera's exposure window *plus* its autofocus hunt after a nudge? |
| `kObservationInterval` | 250 ms | Budget | Does a readability light updating four times a second feel twitchy? |

**`kQuietFramesRequired` — what it actually gates.** Its doc used to reason
"three frames at `kObservationInterval` apart is ~0.75s of nothing happening".
That is wrong. `FrameGate.offer` updates the quiet run on **every offered frame,
before the throttle**, and a device offers at ~30 fps — so three quiet frames is
about **100 ms** on a phone, not 750 ms. No test caught it because every test
offers frames exactly one observation interval apart, which is the single rate
at which the two readings coincide. The consequence is in the nudge's favour:
if a settled board is reachable a tenth of a second after the dice stop, then
the **250 ms throttle**, not the quiet run, is the dominant wait — and that wait
is exactly what `FrameGate.attend` removes.

**What to do**

1. **The frame rate first.** Nothing here means anything without it. A count of
   frames is not a duration until you know the rate. Get the device's actual
   delivery rate (the camera plugin's configured resolution preset drives it;
   watch it in a debug build or read it off the readability light's update
   cadence) and **write it down beside every other answer in this section**.
2. **The mid-placement pause.** Play a few turns and deliberately *pause with
   your hand over the board*, mid-play, for about half a second. Buddy must
   **not** read the board during the pause and fold a half-finished play. Do
   this ten times.
3. **The nudge.** Bump the phone slightly and time how long until the picture is
   trusted again — that is `kGyroStillRate` + `kMotionSettleTime`.
4. **The light.** Just watch the readability indicator for a minute while
   ordinary things happen. Twitchy or steady?

**Pass** — no half-finished play is ever folded during a deliberate pause; a
nudged phone recovers within about a second; the light reads as informative
rather than flickering.

**Fail** — a half-finished play read as a play (raise `kQuietFramesRequired`,
now that you know what a frame costs in milliseconds on this device); a nudge
taking several seconds to recover (raise `kMotionSettleTime`, or the autofocus
is hunting longer than 350 ms on this camera); a light that strobes.

**Write down:** **the frame rate**, then the pause result out of ten, the
recovery time after a nudge, and a verdict on the light. Any number that moves
must be recorded *with the frame rate beside it*.

---

## 7. The VideoRange decode, on a real iPhone

**Why it is here.** iOS and Android hand over YUV on **different signal
ranges**, and neither platform lets the app choose.
`camera_avfoundation` maps `yuv420` to `kCVPixelFormatType_420YpCbCr8BiPlanar`
**VideoRange** with no API to ask for full range; Android's `YUV_420_888` is
forwarded as the sensor made it, full range by convention. Buddy infers which
one from the **plane count** — two planes means the bi-planar iOS format
(`videoRange: true`), three means Android (`videoRange: false`) — in
`YuvFrame.fromCameraImage`.

Decoding studio-range bytes as full range does not crash and does not look
obviously broken. It **washes the contrast out and shifts the colours**, which
is precisely the input the colour model learns its checker and felt colours
from. So the failure mode is a calibration that succeeds and then reads the
board slightly wrong, all session.

**What to do**

Calibrate the **same board, in the same light, from the same angle**, on the
**Android phone and the iPhone**, one after the other. At the confirmation step
each device draws its belief over the picture.

**Pass** — both devices produce the same belief of the starting position, and
both calibrations succeed on the first attempt. Colours in the two previews look
like the same board.

**Fail** — the iPhone's preview is visibly washed out or colour-shifted against
the Android's; the iPhone needs more calibration attempts; the iPhone's belief
disagrees with the Android's on the same physical board.

**Write down:** attempts-to-calibrate on each device, and whether the two
beliefs matched. If the iPhone is the odd one out, the plane-count inference is
the place to look.

---

## 8. Backgrounding — the camera coming back after the app goes away

**Why it is here.** A phone propped over a board for a whole match *will* be
interrupted: a notification pulled down, a call, the screen locking, the user
checking something else. **Android takes the camera back when that happens**,
and what the app is left holding is a `CameraController` that still looks like
an object and refers to nothing. Buddy Mode now releases the camera on
`inactive` and re-opens it on `resumed`
(`BuddyCameraLifecycle` in `app/lib/screens/buddy/calibration_screen.dart`), and
`PhoneBuddyCamera.open` re-checks whether the controller it is holding is still
initialized rather than answering `CameraReady` on the strength of it being
non-null.

Both halves are pinned by widget tests against the fake camera. What no test
here can reach is **the plugin actually giving the camera back**, which is the
whole question — and one race inside `open()` that a test host cannot get to:
two of its three abandonment checks are past a `CameraController` that
`flutter test` cannot initialize.

**What to do**

1. Mid-match, with the light green, **background the app for 30 seconds** —
   home button, or pull the notification shade down and leave it. Come back.
2. Repeat it **at the corners stage of a calibration**, with handles you have
   already dragged.
3. The nastier one, for the race: on the **calibration screen**, background the
   app *while the preview is still black* — in the first second after the screen
   opens, before the camera has finished coming up. Come back. Then do it again
   and instead **back out of the screen entirely** during that same first
   second.

**Pass** — after each resume the preview comes back on its own within a second
or two, the readability light returns to green, and **play continues**: the
position, the score, the transcript and whose turn it is are exactly as you left
them, and the next settled frame is answered normally. The dragged corners in
(2) are still where you put them, and the stage has not reset. In (3) nothing is
left running: the phone's camera-in-use indicator goes out, and the app does not
warm up or drain noticeably afterwards.

**Fail** — a preview that stays black after a resume; a readability light stuck
red or stuck on its last verdict with no new frames; "Fix the aim" going through
the flow and coming back to a dead camera; the calibration stage or the handles
resetting; the camera indicator staying **on** after (3)'s back-out, which is
the leaked stream this item exists for.

**Write down:** seconds to recover the preview on each device; whether anything
about the match moved; the camera-indicator result for (3).

---

# Part 2 — the scripted match

One calibration and one short game, twelve checkpoints. Run it end to end
without restarting; several checkpoints are about state carrying across a
disturbance, which a restart would hide.

**Set up:** Home → **Play with Buddy** → match to **3 points**, difficulty
**Expert**, Buddy plays **Black**, your seat **By the phone**, phrasing
**Terse**, and leave *Play without cube* **off** — C11 needs the cube.

---

### C1 — Calibration: the three preconditions

**Do:** Tap **Calibrate the board**. Read the three-item list on the *aiming*
stage and satisfy all three: **dice off the board**, **men in the starting
position**, **the whole playing field in the picture**. Choose **Folding case**.

**You should see:** the three items; a segmented control offering *Flat board* /
*Folding case*, with the folding option explaining that you will place four
extra points on the hinge.

**Failure looks like:** the aiming stage letting you through with dice still on
the felt (a die left on the board is learned as part of the board), or the
folding option not offering the extra handles at the next stage.

---

### C2 — Calibration: eight handles, and the derived columns

**Do:** On the *corners* stage, drag the **four corner handles** onto the
corners of the felt, then the **four hinge-seam handles** onto the seam. Use the
loupe. Then look at the twelve derived lines down each half.

**You should see:** *"Board corner 1 of 4"* … and *"Hinge seam 1 of 4"* … as the
handle labels (screen reader, or long-press); **every one of the twelve lines
down each half landing on a point**, not between them.

**Failure looks like:** four handles only on a folding case; lines systematically
offset by half a point; the **Next** button refusing with *"Those four handles
do not outline a board…"* when the quadrilateral is fine.

*(If Part 1 item 1 failed in landscape, this is where it shows.)*

---

### C3 — Calibration: seat, capture, confirm

**Do:** Answer **"Which half is your home board?"** with **The near half**. Hold
the phone still through the capture. Read the belief drawn over your board.

**You should see:** *"Hold the phone still. Buddy is waiting for the…"* during
capture; then *"Is this your board?"* with **thirty checkers drawn over the
picture in the starting position**, on the right points, in the right colours —
learned from your board, since there are no colour constants anywhere in the
pipeline.

**Failure looks like:** a belief with the wrong count anywhere (2 on the 24, 5
on the 13, 3 on the 8, 5 on the 6, per side); the two colours swapped; checkers on the wrong
half (the seat answer being ignored). Tap **Start over** — a mis-detected
calibration is meant to be cheap.

---

### C4 — The opening throw, and the mic dialog

**Do:** Each side throws **one** die. Watch what the system microphone dialog
appears over. Grant it.

**You should hear:** the throw named — *"You rolled 6-3."*-shaped, or a reroll
prompt *"Both 4 — roll again."* if the dice tie.

**You should see:** *"Throw the opening dice — one die each."* behind the
permission dialog; the roll appearing in the spoken-line transcript, since every
spoken line is mirrored on screen.

**Failure looks like:** the microphone asked for anywhere but here; the opening
attributed to the wrong player (**Part 1 item 2** — note it and carry on, the
game record is now wrong but the protocol is not over); a roll read as a face
you did not throw.

---

### C5 — Your turn: dice read and confirmed

**Do:** Throw both dice on your half. Do **not** move yet.

**You should hear:** *"You rolled 5-2."* — within about a second of the dice
settling.

**You should see:** the roll on screen, and the **Dice** button available if you
want to type it instead. Buddy asking you to type it (*"Buddy cannot find the
dice. Type the roll instead."*) is a **documented fallback, not a failure** —
dice ship as the weakest link in the perception stack. Count how often it
happens across the game; that count is the finding.

**Failure looks like:** a **wrong** roll read confidently. That is the one that
matters: a fallback costs a tap, a misread costs the game.

---

### C6 — Your turn: the play observed and acknowledged

**Do:** Make a legal play on the board. Move the checkers the way you always do
— unhurriedly, hand over the board, done.

**You should hear:** the play read back, terse — *"13/8, 24/22"*, with **no
full stop**: terse `describePlay` joins hop notations and stops, and a spoken
line that ends in one came from somewhere else.

**You should see:** the belief mirror update to match your board.

**Failure looks like:** nothing said at all (the gate never found a settled
frame — check the readability light for the named cause); a **half-finished**
play folded while your hand was still over the board (**Part 1 item 6**); an
ambiguous read offering *"Which play was it?"* with the wrong candidates. A
disambiguation prompt with the *right* candidates is a working path, not a
failure — tap the right one.

---

### C7 — Buddy's turn: dictation, then a deliberate misplacement

**Do:** Throw for Buddy when asked. Listen to the dictated play. Then **place
one of its checkers deliberately wrong** — right checker, wrong destination,
one point off — and let go.

**You should hear:** first *"I rolled 5-2 — play 13/8, 24/22"* (no full stop —
see C6), then, after you
misplace it, ***"That isn't quite it."*** followed by the fix naming the
discrepancy.

**You should see:** the correction in the transcript; the belief mirror still
showing the **correct** expected position, not your wrong one.

**Do next:** put it right. **You should hear nothing** — a board being correct is
the ordinary case and is deliberately not narrated; the next line (a roll, a
play, a double) is the acknowledgement.

**Then:** get it wrong **three times in a row**
(`kPlacementAttemptsBeforeMirror`). On the third, the screen escalates.

**You should see, on the escalation:**

- the **belief mirror becomes the big picture** — it and the camera preview swap
  sizes, so the position Buddy is holding is what you are looking at;
- a **bright ring** on the points the dictated play touched and the camera
  disagrees about. Only those: the session claimed a hand went to those regions
  and nothing wider, so a ring anywhere else is a bug. (A region the game says
  is **bare** cannot be ringed — the ring hangs on a checker — so a discrepancy
  of the "something is standing where nothing should be" kind is named in the
  sentence and not drawn. That is by design; note it if you see it.)
- the prompt naming **what the camera sees against what the game holds**, in the
  region's own words — e.g. *"Buddy still cannot see its move — the 8-point: the
  camera sees nothing, the game says White 2."*;
- **two buttons: "Skip this check" and "I've fixed it".**

**Do next, and this is the half that matters:** try both.

1. **"I've fixed it"** — put the checker right first, then tap it. The
   escalation comes down and the camera takes the question back; the next
   settled frame verifies and play carries on with **nothing spoken** (a board
   being correct is not narrated). Tap it *without* fixing anything and the
   escalation should come back three frames later, with the correction spoken
   again.
2. **"Skip this check"** — with the board **actually correct** and Buddy still
   unable to see it. This is the case the real corpus measures at **1 in 6**: a
   folding case whose rim stands proud of the felt hides a man at the *base* of
   a near-half point from the camera and from nobody else. You should hear
   ***"I'll take your word for it. I could not see that one land, so if we have
   come apart it will show up as a play I cannot read."*** and play should go
   straight on to the next throw.

**Failure looks like:** a wrong placement silently accepted (the worst failure in
the mode — the physical board and the game state have now diverged with nobody
told); a correction naming the wrong checker; the escalation never arriving;
**the escalation arriving with no way out of it** — a placement that cannot
verify used to close every forward path at once (no dice, no Double, a
non-interactive mirror, and a recalibration that landed straight back here), so
if either button is missing or dead, that is a blocker rather than a note.
Also a failure: play NOT continuing after a skip, or the position moving when
you skip — the game advanced when Buddy chose the move, and a skip discards a
question about the felt, not a decision about the game.

---

### C8 — An illegal play, and the objection

**Do:** On your turn, deliberately make an **illegal** play — move a checker to
a point the opponent holds with two or more, or play only one die when both are
playable.

**You should hear:** ***"That isn't a legal play."*** followed by the reason —
e.g. that it leaves a die unplayed.

**You should see:** the objection in the transcript; the game state **unchanged**
— Buddy waits for the board to change rather than folding anything.

**Do next:** put it right and confirm play resumes normally.

**Failure looks like:** an illegal play accepted; an objection with no reason; the
objection repeating on a loop after you have corrected it.

---

### C9 — A readability outage: cover the board

**Do:** Mid-game, **put a book over half the board** and leave it for ten
seconds. Then take it off. Then, separately, **switch the lamp off** for ten
seconds.

**You should hear:** the drop to red spoken **once, not nagged** — e.g. *"It is
too dark to read the board…"*. Then, on recovery, ***"I can see the board
again."***

**You should see:** the readability light going amber/red with the **cause
named**; perception answers suppressed while red; the authoritative game state
**untouched** — you resume exactly where you paused, nothing lost.

**Failure looks like:** repeated nagging while the condition persists; a red with
no cause named; the game state changing during the outage; the light staying red
after the condition clears.

*(A hand over the board is meant to be **amber** and transient — Buddy carries
on. A lamp switched off is **red**. These are different by design. How reliably
the first holds is one of the things this checkpoint is measuring rather than
confirming: on the synthetic corpus an occluder sweep of 84 shots comes back
`calibrationStale` — red, "the board is not where it was" — on **18 of them,
all on the blue-red palette**, and all of them through the colour-cast check
rather than the geometry one. Red is the safe direction (answers suppressed,
nothing touched), and the cost is a needless trip to "Fix the aim". **Write down
what your board's colours actually did**, because a board whose felt and
checkers are close in hue is the case that behaves like the blue-red one.)*

*(One more known regime, recorded rather than fixed: past a **strong enough
colour cast** — a lamp swapped outright rather than dimmed — the routing bit
inverts. `geometryMatches` gives out, the light falls back to the luma ratio
alone, and the verdict is red with `tooBright`/`tooDark` and
`requiresRecalibration` **false**, which does not clear by dimming. If you swap
the bulb and get a red that will not route you to recalibration, that is this,
and it is a named open limitation rather than a new finding.)*

---

### C10 — Recalibration mid-game: nudge the board

**Do:** With a game in progress, **nudge the physical board** a couple of
centimetres. Then use **Fix the aim** and nudge the corners back.

**You should hear:** the calibration-lost line — the board not being where it
was when Buddy learned it, spoken once.

**You should see:** the light red with the cause naming a moved board; a
**Fix the aim** action in the app bar and a button on the surface; the
recalibration screen opening **on the corners stage with the handles already
where they were** — the fast path, not a fresh calibration. After confirming,
**the game continues from exactly where it was**, score and position intact.

**Failure looks like:** a nudged board going unnoticed (the geometry check is not
working); recalibration restarting the game or losing the score; the handles
starting from scratch.

---

### C11 — The cube, by voice and by button

**Do:** Play on until Buddy doubles, or double it yourself with the **Double**
button. Keep the physical cube on the table and turn it yourself — the physical
cube is your ritual to maintain, Buddy never looks at it.

**You should hear:** ***"I double — take or drop?"*** when Buddy doubles;
*"You take."* / *"I drop."* on the answer.

**You should see:** **Take** and **Drop** buttons when Buddy doubles; the
**Double** button gated exactly as in the digital game — refusing before the
opening throw, off-turn, after rolling, in the Crawford game, and when the other
side owns the cube, each with its own reason in a snackbar.

**Failure looks like:** the Double button available when the digital game would
refuse; a cube action spoken but not reflected in the score; the Crawford rule
not gating.

---

### C12 — A dance, then the match end

**Do:** If a dance occurs naturally (on the bar, all entry points blocked), that
is the checkpoint. If it does not, set one up on the board deliberately.

**You should hear:** ***"No play — your turn passes."*** for your dance, or
*"No play, so it is back to you."* for Buddy's.

**Then play the match out** (3 points; concede games if you need to get there).

**You should hear:** each game's result — *"You win 2 points."* — and then the
match: ***"You win the match."*** or *"That is the match to me."*

**Finally:** back out to Home → **History**.

**You should see:** the finished match as a **History row** with the right score;
opening it replays it move by move; the **post-game analysis** runs and flags
blunders and cube errors — through the standard persistence path, exactly as a
digital match does.

**Failure looks like:** a dance not announced (the turn silently passing); the
match not appearing in History; analysis failing or empty; a score in History
disagreeing with what you heard.

---

### C12b — the phrasing switch (30 seconds)

**Do:** Settings → Buddy Mode → **Friendly**, and start a second short session
just far enough to hear one dictated play.

**You should hear:** *"Move one checker from 13 to 8, and one from 24 to 22."*
instead of *"Play 13/8, 24/22"*. The **friendly** line is a finished sentence and
ends in a full stop; the terse one is notation and does not.

**Failure looks like:** the setting not taking effect until an app restart; a
friendly line reading *"Play move one checker from 13 to 8"* (a verb doubled in
front of a finished sentence).

---

# Recording the result

Copy this into the release notes for the run, filled in.

```
Device:            (model, OS version)
Build:             (version+build, debug/release)
Board:             (flat / folding, colours)
Light:             (daylight / lamp / dim)

PART 1
1. preview↔frame   landscape: PASS/FAIL   portrait: (what it did)
2. opening seat    correct __ / fallback __ / WRONG __   (of 10)
3. microphone      hints per 20 throws: __ (on) vs __ (off)
                   false positives: __ in 5 noisy min, __ in 2 silent min
                   kDiceFloorDecibels verdict:
4. Android APK     workflow run: ____  result: ____  installs+runs: Y/N
5. permissions     camera over: ______  mic over: ______  refusal ok: Y/N
6. frame gate      FRAME RATE: __ fps   pause folded early: __ / 10
                   nudge recovery: __ s   light: steady / twitchy
7. VideoRange      Android attempts: __   iPhone attempts: __   beliefs match: Y/N
8. backgrounding   preview back in __ s (match) / __ s (calibration)
                   match state intact: Y/N   stage+handles intact: Y/N
                   camera indicator off after a back-out mid-open: Y/N

PART 2 (pass / fail / note)
C1  three preconditions           ____
C2  eight handles + columns       ____
C3  seat, capture, belief         ____
C4  opening throw + mic dialog    ____
C5  dice read                     ____   (tap-to-enter fallbacks this game: __)
C6  play observed                 ____
C7  dictation + correction loop   ____
    placement verification: verified first try __ / corrected then verified __
                            mirror escalated __ / SKIPPED as unseeable __
                            (of __ dictated turns this game)
C8  illegal play objection        ____
C9  readability outage            ____
C10 mid-game recalibration        ____
C11 cube by voice + button        ____
C12 dance + match end + History   ____
C12b phrasing switch              ____

VERDICT:  SHIP / SHIP WITH NOTES / BLOCKED
Numbers that must go back into the source:
```

**What "SHIP" requires.** Part 1 item 1 in landscape, and every Part 2
checkpoint whose failure would corrupt the game state — C4's attribution, C5's
misreads, C6's premature folds, C7's silent acceptance, C8's objection, C10's
score surviving a recalibration. C7's two escalation buttons are on that list
too, for a different reason: they are not about corrupting state, they are the
only way out of a placement that cannot verify, and without them the match is
over. Everything else is a number to write down and a judgement to make.

**The placement row is the one to read first.** `PerceptionTargets`
`placementVerification` promises 0.95 and the real corpus scores **1 in 6**,
with a known mechanism and no fix yet — so the four counts under C7 are the
first field reading of that gap. *Skipped as unseeable* is the interesting
number: it is the rate at which a correctly placed board could not be confirmed,
which is what the queued perception work has to move. The app counts it too, as
`buddy_fallback_used` / `placement_skipped`.

**Where the numbers go.** Items 2, 3 and 6 each name constants that currently
ship with arithmetic rather than a measurement. A number that moves gets changed
**at the constant**, with the measurement and the device it came from written in
its doc comment — and, for `kQuietFramesRequired`, **with the frame rate beside
it**, because a count of frames means nothing without one.
