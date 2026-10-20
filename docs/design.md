# Agent Widget: Brainstorm

*An iPhone widget that shows what your AI agents are doing at a glance and lets you say "go ahead" on a decision with one tap.*

---

## 1. The idea in one sentence

Your agents work in the background; the widget is the **one place on your phone that tells you which agent needs you, and lets you unblock it without opening a laptop.**

The real value is not "watching progress." It's **removing the wait**: agents stall for hours on a yes/no question while you're away from your desk. The widget turns those stalls into a 2-second tap.

---

## 2. Who it's for and the core moments

| Moment | What the user wants | What the widget shows |
|---|---|---|
| Glance (walking, in a meeting) | "Is anything stuck on me?" | A count + color: `2 need you` / `All running` |
| Decision | "Approve this, quickly but safely" | One question, 2 options, one tap |
| Done | "Did it finish? Did it work?" | ✓ / ✗ and a one-line result |
| Curious | "What's it doing right now?" | Current step + progress, per agent |

Design the widget around the **first two moments**. Progress is nice; decisions are the product.

---

## 3. How it would fit on iOS (what's actually possible)

You'll want several surfaces, each for a different job:

| Surface | Best for | Notes |
|---|---|---|
| **Home Screen widget** (small/medium) | Overview of all agents | Interactive buttons via App Intents (iOS 17+). Refresh is budgeted by the system, so it's *not* real-time on its own. |
| **Lock Screen widget** | "N need you" count | Tiny. A number and an icon. |
| **Live Activity + Dynamic Island** | A single active run, live | Updates by push in near real time. Has buttons. Runs up to ~8 hours, then ends. Best fit for "agent is working right now". |
| **Actionable push notification** | The decision itself | Long-press → Approve / Deny. Works everywhere, even if the widget isn't on screen. |
| **Apple Watch complication** | Glance + approve from wrist | Great follow-on, not v1. |
| **Control Center control** (iOS 18+) | "Pause all agents" kill switch | Cheap to add, high peace of mind. |

**Key takeaway:** a widget alone can't be live. Pair it with **push-driven Live Activities and actionable notifications.** The widget is the dashboard; notifications and Live Activities are the real-time layer.

### Rough architecture

```
Agents (Claude Code, scripts, cloud jobs)
   │  report status / ask a question  (small SDK, hook, or MCP tool)
   ▼
Relay server  ── stores state, decisions, audit log
   │  APNs push (widget reload, Live Activity update, notification)
   ▼
iPhone app + widgets  ── tap "Approve" → App Intent → relay → agent resumes
```

The agent side can be tiny: `ask(question, options, default, timeout)` blocks until you answer or the timeout hits. For Claude Code, a hook (e.g. on permission requests or notifications) can forward to the relay.

---

## 3b. Scope decision: Claude Code sessions only (for now)

*Decided 2026-10-20. Other agents may come later, so keep the relay protocol generic even though only Claude Code talks to it.*

Claude Code already has **hooks**: small scripts it runs at fixed moments in a session. They're the whole integration, so there's no need to change Claude Code itself.

| Claude Code moment (hook) | What the widget shows |
|---|---|
| `SessionStart` | New row: repo, branch, session title. State: Running |
| `PostToolUse` (throttled, e.g. at most every 30 s) | Current step: *"Editing auth.ts"*, *"Running tests"* |
| `PermissionRequest` / `PreToolUse` | **Needs you:** *"Run `npm publish`?"* with Allow / Deny buttons |
| `Notification` (Claude is idle, waiting for your input) | **Needs you:** *"Waiting for your reply"* plus Claude's last line |
| `Stop` | Done ✓ with a one-line summary of what it did |
| `SessionEnd` | Row disappears (or moves to a "Today" history) |

**How the approve button works:** the permission hook sends the question to the relay, then waits. You tap Allow on your phone, the relay answers, and the hook tells Claude Code "allow" or "deny". If nobody answers before the hook's timeout, it falls back to the normal prompt in the terminal, so nothing is ever approved by silence.

**Two kinds of "needs you":**
1. **Permission prompts** (run this command, edit this file). These are yes/no and fit a widget button perfectly. Start here.
2. **Open questions** in chat (*"Should I use Postgres or SQLite?"*). These need a reply, not a button. For v1 show "Waiting for you" and open the session. Later, a small MCP tool like `ask_user(question, options)` lets Claude ask with buttons instead of free text.

**Packaging:** bundle the hooks (and later the MCP tool) as one **Claude Code plugin**, so setup is "install plugin, scan QR code to pair your phone". Settings for which tools count as high risk live in the plugin config.

**Things specific to Claude Code to plan for**
- **Several sessions at once.** You'll often have 3 to 5 sessions across repos. Name rows by repo + branch, not by session ID.
- **Sessions on different machines** (laptop, cloud, a server). Each one reports to the same relay, so the phone sees all of them in one place.
- **Your existing permission settings still apply.** Anything you've already allowed in settings never reaches the phone; only real prompts do. That keeps the widget quiet.
- **Show the exact command or file** in the approval, not Claude's description of it. You're approving `rm -rf build/`, not "cleaning up".
- **Check what already exists.** The Claude apps and Claude Code on the web already send some notifications for remote sessions. Look at what they cover before building, and make the widget the part they don't do (glanceable multi-session view + one-tap approvals for local terminal sessions).

---

## 4. Do's

**Design**
- **Do lead with "needs you."** The first thing the widget shows is the number of agents waiting on you. Everything else is secondary.
- **Do use one status vocabulary everywhere:** Running · Needs you · Done · Failed · Paused. Color + icon, never color alone (accessibility).
- **Do keep the question to one line** with a short context line under it: *"Merge PR #42 into main?" / "3 files, tests green."*
- **Do show what "yes" will do,** not just "Approve." Buttons like `Merge`, `Deploy`, `Send` are safer than a generic `OK`.
- **Do sort by urgency,** not by agent name: waiting > failed > running > done.
- **Do show staleness.** "Updated 4 min ago" so you never trust a frozen widget.

**Behavior**
- **Do give every decision a default and a timeout** chosen by the agent: "If no answer in 30 min → skip / wait / choose safe option."
- **Do make approvals idempotent.** Double taps and retries must not run something twice.
- **Do confirm the result** after a tap: the widget flips to "Approved → running" so you know it landed.
- **Do batch.** If one agent has 3 small questions, group them, or let the agent ask once with a plan.
- **Do keep an audit log** in the app: who approved what, when, from which device.

**Safety**
- **Do tier decisions by risk.** Low risk: one tap from widget. Medium: tap + Face ID. High (deploy to prod, spend money, delete data, send external messages): must open the app and see full details.
- **Do require the phone to be unlocked** for any approval from the Lock Screen.
- **Do include a big, easy "Pause all" control.** A kill switch is the most trust-building feature you can ship.

---

## 5. Don'ts

- **Don't stream logs into the widget.** It's a glance surface. Logs belong in the app.
- **Don't show percentage bars you can't back up.** Agents rarely know "60% done." Use step-based progress (*Step 3 of 5: running tests*) or just a state.
- **Don't notify on every step.** Notify on *needs you*, *failed*, and optionally *done*. Everything else is silent.
- **Don't make "Approve" the only button.** Always offer Deny / Not now. A one-button widget trains you to rubber-stamp.
- **Don't allow high-stakes actions from the Lock Screen** without authentication.
- **Don't rely on widget refresh for real-time.** iOS limits how often widgets reload; use push.
- **Don't let the agent decide its own risk level unchecked.** Let the user set rules ("anything touching `main` or money = high risk").
- **Don't let approvals go stale.** If the state changed after the question was asked (new commit, new data), invalidate the old question instead of applying a yes to something different.
- **Don't tie it to one agent vendor.** A small open protocol lets Claude Code, cron jobs, CI, and custom bots all report in.
- **Don't send secrets or full code through push payloads.** Payloads show on the Lock Screen and pass through Apple's servers. Send IDs; fetch details in-app.

---

## 6. Ideas to make it better

**Make the decision smarter**
1. **"Approve + remember" rules.** After approving the same kind of thing 3 times, offer: *"Auto-approve test-only changes from this agent?"* The widget gets quieter over time.
2. **Preview before approve.** A diff summary, screenshot, or cost estimate one tap away (long-press the widget or expand the Live Activity).
3. **Reply, not just yes/no.** A third option: *"Change it"* opens a quick voice or text reply that goes back to the agent as guidance.
4. **Agent-proposed options.** Instead of yes/no, the agent offers 2 to 3 choices: *"Use Postgres / SQLite / Ask me later."*

**Make it calmer**
5. **Focus-mode aware.** During Sleep or Work focus, only high-risk or blocking questions break through; the rest wait in the widget.
6. **Daily digest.** One evening summary: what ran, what finished, what's waiting, cost spent.
7. **Smart Stack relevance.** Tell iOS when the widget matters so it rises in the Smart Stack only when something needs you.

**Make it trustworthy**
8. **Cost and time meters.** Tokens / dollars / minutes per agent, with a budget limit that auto-pauses.
9. **Undo window.** For reversible actions, a 10-second "Undo" after approving.
10. **Health signal.** If an agent stops reporting, show "Silent for 20 min" instead of a cheerful "Running."

**Make it bigger later**
11. **Apple Watch** approvals with haptics; feels magical for quick yes/no.
12. **Shortcuts / Siri:** *"Hey Siri, what are my agents doing?"* / *"Approve the deploy."*
13. **Team mode:** route a decision to whoever's on call; two-person approval for prod.
14. **Mac menu bar twin** sharing the same backend, so the phone and desktop stay in sync.

---

## 7. Suggested first version (MVP)

Keep it small enough to build and use in a few weekends:

1. **Relay:** a tiny server (e.g. a serverless function + small DB) with three endpoints: `status`, `ask`, `answer`. APNs push on every change.
2. **Agent side:** a 20-line client / Claude Code hook that calls `status` and blocks on `ask`.
3. **iPhone:** a medium Home Screen widget (up to 3 agents, "needs you" first), a Lock Screen count, and actionable notifications with Approve / Deny.
4. **Safety baseline:** Face ID for anything marked medium/high, default + timeout on every question, a "Pause all" button, an audit log.

Add Live Activities second (they're the "wow" moment for a single long run), then rules / auto-approve, then Watch.

**How you'll know it works:** median time from "agent asks" to "agent unblocked" drops from hours to minutes, and you rarely open your laptop just to say yes.

---

## 8. Open questions to decide

- ~~**Which agents first?**~~ Decided: Claude Code sessions only for now (see 3b).
- **Self-hosted or hosted relay?** Self-hosted is more private; hosted is easier.
- **Personal tool or product?** A personal tool can skip accounts and multi-user; a product needs auth, onboarding, and pricing.
- **Where's the line for "one-tap safe"?** Worth writing your own risk rules down before building.
- **Name ideas:** *Nod*, *Go Ahead*, *Greenlight*, *Pulse*, *Standby*.
