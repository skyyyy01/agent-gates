# Why mechanism, not discipline

This is the reasoning the whole project rests on. It's short, and it's not
theoretical — every step happened.

## The escalation, in order

**1. The rule went into `CLAUDE.md`.**
Not vaguely. Specifically: *never put a pipe or redirect after that command,
because it truncates the list of files the review covered, and the files that
scroll off never get stamped.* With the consequence spelled out.

Didn't hold.

**2. It went into the journal, and into long-term memory.**
So a fresh session with no context would still load it. Both carriers, on the
same day it first bit.

Didn't hold.

**3. It was rewritten as a mechanical step.**
This is usually the fix. Stop phrasing a rule as something to *remember* and
phrase it as something to *do*: "that command goes on its own line, nothing
after it." No judgement, no recall — just a shape to match.

**That same day: four more violations.**

Every time with the same motive, which is worth stating because it's so
ordinary: *the output is long, I only want a peek.* Not carelessness. A locally
reasonable decision, made five times, against a rule that was already written in
four places.

**4. Conclusion: the discipline forms were exhausted.**

Not "try harder next time" — there was no *next* form left. Written down,
written down again, written down in the place that's read first, and rewritten
as a motor action. What remained wasn't another way to say it. It was to stop
saying it and start denying it.

That's the escalation to a hook that returns `deny`.

## The part that makes this credible

Building the gate, three silent failures happened *in the gate itself*:

1. **The check ran after the file list was computed** — so on a clean working
   tree it never ran at all. Passing, always, for the case that mattered least
   to notice.
2. **A Python indentation error inside the hook was swallowed by
   `2>/dev/null`.** The script errored on every invocation and reported nothing.
   Green.
3. **The test passed `\n` through `echo`**, which interpreted it as a real
   newline. The test was checking a different string than the one it meant to,
   and concluded the gate was broken when it wasn't.

Three bugs, all of the same species: **the failure and the success looked
identical**. That's the species this whole tool exists to fight, and it grew
inside the tool while the tool was being written to fight it.

Which forced one more addition: **the detector reports its own failure.** If the
check can't run, it says so out loud instead of passing quietly. A gate that
can't tell you it's broken is worse than no gate — you'd at least know where you
stand without one.

## What this argument does not claim

It doesn't claim the gate is airtight. [The README lists six known
bypasses](../README.md#known-bypasses), one with no mitigation at all.

It doesn't claim discipline is worthless. Discipline is what gets you the first
four forms, and most rules never need a fifth — you write them down, they hold,
done.

The claim is narrower and, I think, harder to argue with:

> **When a rule has failed in every form discipline can take, writing it down
> once more is not a plan.** At that point the only remaining move is to make
> the wrong action impossible instead of discouraged.

The corollary is the useful part: **you can tell which rules deserve a gate.**
They're the ones you've already written down more than twice. If a rule only
ever needed to be said once, leave it alone — gates have a cost, and spending it
on rules that already work is how a tool becomes bureaucracy.

## Picking your first gate

Go find the rule you've written down three times.

Not the most important rule — the most *re-written* one. Those are different,
and the re-written one is the one that's actually costing you. Importance is
your estimate; repetition is evidence.
