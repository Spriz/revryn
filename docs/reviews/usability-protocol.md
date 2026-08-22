# Representative-user activation study protocol (release gate 3)

BC-US-166 requires qualitative evidence: representative prospective users
explaining the commercial-to-accounting flow in their own words, with
confusion points recorded. Telemetry is already emitting per-step
`[:billing_core, :demo, :step_completed]` timings; this protocol adds the
human half. Two to four participants suffice for the gate.

## Participant profile

Runs a B2B SaaS or agency billing through e-conomic (or their accountant
does); has never seen Revryn.

## Session script (~30 minutes, recorded with consent)

1. **Setup (2 min).** Fresh browser; the facilitator does not touch the
   keyboard. Start at `/register`.
2. **Task 1 — activate (10 min).** "Create an account and get to a point
   where you understand what this product would do for your billing."
   (Expected path: passkey registration → guided demo workspace.)
   Facilitator notes every hesitation >10 s and every misclick.
3. **Task 2 — explain back (10 min).** At the demo's close phase, ask:
   "In your own words: what happened between the subscription and the
   number that ended in e-conomic?" Record the explanation verbatim.
   Pass signal: they connect subscription → invoice → credit →
   monthly close → voucher without prompting.
4. **Task 3 — recover (5 min).** Trigger the provider-failure drill
   ("Curious how failures are handled?") and ask them to resolve it.
   Pass signal: they reach the operations inbox and retry unaided.
5. **Debrief (3 min).** "What would stop you from connecting your real
   e-conomic agreement today?"

## Evidence to file

- Recording + verbatim Task-2 explanation per participant
- Confusion-point list mapped to screens (file issues per point)
- The session's telemetry step timings (already captured server-side)

File results as `docs/reviews/usability-evidence-<date>.md`; the gate
closes when Task 2's pass signal holds for the majority of participants
and every confusion point has an issue or a fix.
