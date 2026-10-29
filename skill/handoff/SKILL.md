---
name: handoff
description: Write a handoff document another agent can resume this work from — what the task is, what is done, what is left, and how to verify it. Use on a HARNESS CHECKPOINT, or when asked to hand off, checkpoint or pause work for another agent or host.
---
<!-- harness-skill: shipped by Harness (skill/handoff) -->

# handoff — write the document the next agent resumes from

The next agent starts with NONE of your context: no conversation, no scratch files, no shell state,
often not even this host. It gets your pushed branch, the issue, and the document you write here.
Write it for that reader.

1. **Push first.** Commit ALL work in progress (a WIP commit is fine) and push the branch, unless the
   instruction that sent you here says there is no branch. Unpushed work is lost work.
2. **Write the document** to a file outside the repo (e.g. `mktemp`), in this shape:

   ```markdown
   <first line exactly as your instruction gives it, e.g. <!-- harness-handoff issue=N branch=B -->>
   ## Handoff: <one-line task summary>

   **Goal:** what "done" means — the acceptance criteria, in your words, each marked done / not done.
   **State:** branch, last pushed commit (`git rev-parse --short HEAD`), whether a PR is open (number).
   **Done so far:** what changed and where (`path:line`), and why each non-obvious choice was made.
   **Left to do:** the next concrete steps, in order. The very next command to run goes first.
   **Verify with:** the exact test/build commands, and which failures were already red on the base
     branch before you started (so the next agent does not chase them).
   **Watch out for:** dead ends already tried, traps, decisions made that should not be re-litigated.
   ```

   Facts only, no narrative of the session. Name files, functions, commands and issue/PR numbers
   exactly; a reader cannot ask you what "the helper" meant.
3. **Post it** where the instruction says — for a Harness checkpoint, as a GitHub issue comment
   (`gh issue comment <issue> -R <owner/repo> --body-file <file>`). The marker line must be the
   comment's FIRST line, byte for byte: the resume path keys on it.
4. Then do the rest of what the instruction asked (label swap, promise, exit). Do NOT merge or close.
