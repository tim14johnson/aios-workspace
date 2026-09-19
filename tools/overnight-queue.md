# AiOS Overnight Queue

Run with: `./tools/overnight-queue.sh`
Servers start once and stay up for the whole run.

Each line: `- [ ] <path-to-brief.md> | <workspace-path>`
Workspace defaults to `/Volumes/AiOS Repository/code` if omitted.
Completed items get a timestamp appended and are left in place as a record.

---

## Queue

<!-- Add briefs here. The queue runner processes them top-to-bottom. -->
- [ ] /tmp/aios-overnight/ffa-calendar-brief.md | /Volumes/AiOS Repository/code
- [ ] /tmp/aios-overnight/fix-cover-letter-and-compute-worker.md | /Volumes/AiOS Repository/code
- [ ] /tmp/aios-overnight/ffa-dashboard-brief.md | /Volumes/AiOS Repository/code

## Done

<!-- Completed entries move here automatically with timestamps. -->
