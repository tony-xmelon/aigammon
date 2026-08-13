# Filming the corpus — the one-video route

This is the video alternative to `CHECKLIST.md`'s 33 photographs. One
continuous video, roughly 15–20 minutes, shot on any phone at default video
settings (1080p is plenty). The move log is transcribed from the footage
afterwards and replayed through the rules engine, so nothing needs to be
written down while playing.

## Set up once, then don't touch the phone

- Prop the phone so the rear camera sees the **whole board, both bear-off
  trays included**, from a comfortable angle looking down at the table.
  Leaning it against a stack of books works fine. Landscape.
- Set the board with the home boards **to your right**.
- Wipe the camera lens. Sharpness matters far more than camera height.
- Press record — and from here on, **do not touch the phone** until the
  final act says to knock it.

## Act 1 — Calibrate (10 seconds)

Board at the **starting position**. **No dice anywhere in view.** Hands
away. Hold still for 5–10 seconds.

> Why no dice: a measured failure — dice present during calibration get
> learned as part of the board and become invisible forever after.

## Act 2 — Play (10–15 minutes)

Play a normal game — both sides yourself is fine, any legal moves, no need
to finish. Only one rhythm change from natural play:

- **After each roll:** let the dice sit untouched for ~3 seconds before
  moving any checker.
- **After each completed move:** hands fully out of frame for ~3 seconds.

That 3-second beat is the "stable frame" the pipeline reads — and it is the
rhythm the real Buddy session will have anyway.

Optional but helpful: say the roll out loud ("six three") as you make it.
Play the dice wherever they land; if one cocks against a stack, play on
naturally — that case is wanted data too.

## Act 3 — Change the light (about 3 minutes)

When done playing (or bored):

1. Reset the board to the **starting position**, dice out of view.
2. **Change the lighting** — switch a lamp on, or dim the room. A real
   change, not a nudge.
3. Hold the bare starting position still for 5–10 seconds (this is a fresh
   calibration under the new light).
4. Play another 8–10 moves with the same rhythm.

If a third lighting condition is easy (dimmer still), repeat this act once
more, shorter. If not, two conditions is acceptable.

## Act 4 — Sabotage (30 seconds)

These deliberately break things; they test that the reader refuses instead
of guessing.

1. Slide a book (or hold a hand) covering half the board for 5 seconds,
   then remove it.
2. Turn the lights down to genuinely-too-dark for 5 seconds, then back.
3. Finally: **knock or slide the phone** out of position. Stop recording.

## Afterwards

Get the video file onto the dev machine (or anywhere reachable) and say
where it is. Everything else — frame extraction, move transcription,
ground-truth sidecars, the accuracy scoreboard — happens on this side.

Optional extra credit, separate short video: Act 1 + a few minutes of Act 2
on a **different physical board**. Boards vary more than lighting does, and
a second board is the single most valuable addition. Skip if there is no
second board.
