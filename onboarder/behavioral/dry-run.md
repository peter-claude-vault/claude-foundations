# /onboard-behavioral — dry-run against three hypothetical personas

Three cold-start personas carried over from Phase 1's dry-run, to keep a traceable hypothetical user arc across phases. None of these represent a real person.

---

## Persona 1: The Consultant

*Background from Phase 1: management consultant, lots of client work, custom vault, protected folders, Teams + Gmail + Granola + Asana.*

**Q1 (autonomy):** "When I ask you to do something, how much runway do you want me to take?"
> "Batch. I want to see a plan before anything happens. If you're reorganizing client files, definitely show me first."

→ `autonomy: medium`

**Q2 (exceptions):** "Categories where you always want me to stop and check?"
> "Anything inside the Financials folder. Anything that touches a client deck. And never push to git without asking."

→ `autonomy_exceptions: ["writes to vault/Financials", "edits to client deliverables", "git push"]`

**Q3 (progress):** *(skipped — autonomy is medium, not high)*

**Q4 (communication style):** "Terse, structured, or conversational?"
> "Structured when it's analysis. Terse when it's a confirmation or a status."

→ `communication_style: "structured for analysis, terse for status"`

**Q5 (pushback):** "Challenge assumptions or stay quiet?"
> "Challenge. If I ask you to do something that looks wrong, tell me."

→ `pushback_preference: "challenge assumptions actively"`

**Q6 (tone):** "Emojis, exclamation points, filler?"
> "No emojis. No 'Great question'. Normal punctuation is fine."

→ `tone_rules: ["no emojis", "no filler phrases"]`

**Q7 (cadence):** "Tight loops or long runs?"
> "Long runs for research, tight loops for edits."

→ `cadence: "mixed: long runs for research, tight loops for edits"`

**Q8 (response length):** "When do responses become too long?"
> "If it doesn't fit on one screen, it's probably too long. Executive summary first, detail on request."

→ `response_length_preference: "prefer one-screen summaries, detail on request"`

**Q9 (time rules):** "Quiet hours?"
> "After 7pm and on weekends, no proactive work."

→ `time_rules: ["no proactive work after 7pm local", "no proactive work on weekends"]`

**Q10 (notifications):** "Ping me when long tasks finish?"
> "A terminal bell is enough. No OS-level notifications."

→ `notification_rules: ["terminal bell on long-task completion; no OS notifications"]`

**Q11 (blockers):** "Stop immediately or try alternatives?"
> "Try one alternative, then stop. Don't spiral."

→ `blocker_policy: "try one alternative, then surface the blocker"`

**Q12 (file placement):** "Standard location or always ask?"
> "Always ask if it's in the vault. Temp files, your call."

→ `file_placement_policy: "always ask for vault writes; autonomous for temp files"`

**Q13 (diff):** "Show a diff before writing?"
> "Yes, for anything over 20 lines or any file I've edited in the last hour."

→ `diff_preference: "show diff for changes >20 lines or recently-edited files"`

**Confirmation:** Approves after one correction (changes "executive summary first" to "headline conclusion first").

---

## Persona 2: The Developer

*Background: senior Go engineer, new to the repo's frontend, git-heavy workflow, no vault, lots of development tools.*

**Q1:** "Runway?"
> "High. I'm here to move fast. Clean up afterward is fine."

→ `autonomy: high`

**Q2:** "Exceptions?"
> "Never force-push. Never drop database tables. Never modify CI config without asking."

→ `autonomy_exceptions: ["git push --force", "DROP TABLE", "CI/CD config changes"]`

**Q3:** "Verbosity while running?"
> "One-line progress. Don't narrate every file read."

→ `progress_verbosity: "one-line progress updates"`

**Q4:** "Communication style?"
> "Terse. I read diffs faster than prose."

→ `communication_style: "terse; prefer code over prose"`

**Q5:** "Pushback?"
> "Challenge hard. If my approach is bad, say so."

→ `pushback_preference: "challenge hard; direct disagreement welcome"`

**Q6:** "Emojis, filler?"
> "None. Ever."

→ `tone_rules: ["no emojis", "no filler", "no self-congratulation"]`

**Q7:** "Cadence?"
> "Long runs. Finish the task, come back."

→ `cadence: "long runs; complete task before returning"`

**Q8:** "Response length?"
> "As short as possible. If you need more than three sentences, use a code block or bullet list."

→ `response_length_preference: "≤3 sentences unless code/bullets"`

**Q9:** *(skipped — no time preferences)*

**Q10:** "Notifications?"
> "Terminal bell plus a message in tmux status bar if possible."

→ `notification_rules: ["terminal bell", "tmux status on long-task completion"]`

**Q11:** "Blockers?"
> "Try three alternatives, then stop. Be aggressive about working around problems."

→ `blocker_policy: "try up to three alternatives before surfacing"`

**Q12:** "File placement?"
> "Your call. Follow the repo's conventions."

→ `file_placement_policy: "autonomous; follow repo conventions"`

**Q13:** "Diff?"
> "No diffs. I'll read git diff myself."

→ `diff_preference: "no pre-write diffs; rely on git diff"`

**Confirmation:** Approves on first pass.

---

## Persona 3: The Greenfield User

*Background: generalist knowledge worker, no existing setup, no vault, no MCP servers, no specific tools.*

**Q1:** "Runway?"
> "I'm new to this. I want to see everything before it happens."

→ `autonomy: low`

**Q2:** "Exceptions?"
> "Honestly everything for now. I'll loosen it once I trust you."

→ `autonomy_exceptions: ["confirm all writes", "confirm all external calls"]`

**Q3:** *(skipped — autonomy is low)*

**Q4:** "Communication style?"
> "Explain things. I'd rather learn as we go."

→ `communication_style: "conversational with explanations"`

**Q5:** "Pushback?"
> "Yes — I want you to tell me when I'm asking for the wrong thing."

→ `pushback_preference: "challenge with explanations"`

**Q6:** "Emojis, filler?"
> "Whatever. I don't care."

→ `tone_rules: []`

**Q7:** "Cadence?"
> "Tight loops. One thing at a time."

→ `cadence: "tight loops; one step then wait"`

**Q8:** "Response length?"
> "Whatever you need to explain clearly."

→ `response_length_preference: "no hard limit; favor clarity"`

**Q9:** *(skipped)*

**Q10:** "Notifications?"
> "No — I'm watching the terminal anyway."

→ `notification_rules: ["none"]`

**Q11:** "Blockers?"
> "Stop immediately. I want to learn what went wrong."

→ `blocker_policy: "stop and surface immediately"`

**Q12:** "File placement?"
> "Always ask."

→ `file_placement_policy: "always ask"`

**Q13:** "Diff?"
> "Always show me the diff."

→ `diff_preference: "show diff on every write"`

**Confirmation:** Approves after re-reading the full summary twice.

---

## Cross-persona observations

- **Autonomy landed differently in every persona**, which validates that the enum matters. A single default would misfit at least two of the three.
- **Exception lists are all different** (client folders vs. git operations vs. blanket confirmation), which validates the decision to keep exceptions separate from the autonomy enum.
- **The "tight loops vs. long runs" question produced non-obvious answers** — the consultant wanted mixed cadence, which a two-option question would have lost. MI framing paid off.
- **Pushback preference was uniformly strong**, suggesting this field may be low-signal. Worth watching once real users run the skill — if the distribution stays tight, the question is a candidate for removal in a later iteration.
- **No persona needed schema changes** — every answer fits inside `behavioral.*` with `additionalProperties: true`. The schema held.
