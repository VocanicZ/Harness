// opencode-ralph.js — the goal loop for an OpenCode lane (#261): ralph-loop's contract as an OpenCode
// plugin. opencode_launch loads it from the engine by path (the lane's inline config) and names, in
// OPENCODE_HARNESS_LOOP, the script Codex's Stop hook and the Harness-driven loop already run
// (scripts/lib.sh GOAL_LOOP_PY). When the lane's session goes idle (`session.idle`) after a turn that
// ended cleanly, the agent's last reply goes through that script: while
// <worktree>/.claude/ralph-loop.local.md (write_state) exists and the reply does not carry its
// <promise>, it answers {"decision":"block","reason":<next prompt>} and this plugin sends that prompt
// into the same session, as the same agent and model the last prompt ran with. On the promise, or at
// max_iterations, the script removes the state file (the done signal cli_done reads) and the session
// stays idle. A sub-agent's session (one with a parent) is not the lane's. A turn that ended in an
// error (a usage limit, a transient API error, an interrupt) is left to the Harness watchdog, which
// parks or nudges it: re-prompting it here would only burn iterations. OpenCode 1.19 raises
// `session.error` before `session.idle` but saves the error on the message only after it, so the
// error is told by that event, not by the message; the session going busy again clears it.
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { join } from "node:path"

export const HarnessRalph = async ({ client, directory }) => {
  const state = join(directory, ".claude", "ralph-loop.local.md")
  const loop = process.env.OPENCODE_HARNESS_LOOP
  const errored = new Set()
  return {
    event: async ({ event }) => {
      const id = event.properties?.sessionID
      if (!id || !loop) return
      if (event.type === "session.error") errored.add(id)
      if (event.type === "session.status" && event.properties.status?.type === "busy") errored.delete(id)
      if (event.type !== "session.idle") return
      if (errored.delete(id) || !existsSync(state)) return
      try {
        const session = (await client.session.get({ path: { id } })).data
        if (!session || session.parentID) return
        const msgs = (await client.session.messages({ path: { id } })).data || []
        const last = msgs.filter((m) => m.info?.role === "assistant").pop()
        if (!last || last.info.error) return
        const asked = msgs.filter((m) => m.info?.role === "user").pop()?.info || {}
        const reply = (last.parts || []).filter((p) => p.type === "text" && !p.synthetic).map((p) => p.text).join("\n")
        const out = spawnSync("python3", [loop], {
          cwd: directory,
          input: JSON.stringify({ cwd: directory, session_id: id, last_assistant_message: reply }),
          encoding: "utf8",
        }).stdout
        if (!out || !out.trim()) return
        const next = JSON.parse(out)
        if (next.decision !== "block" || !next.reason) return
        const body = { parts: [{ type: "text", text: next.reason }] }
        if (asked.agent) body.agent = asked.agent
        if (asked.model?.providerID && asked.model?.modelID) body.model = { providerID: asked.model.providerID, modelID: asked.model.modelID }
        await client.session.promptAsync({ path: { id }, body })
      } catch (e) {
        await client.app
          .log({ body: { service: "harness-ralph", level: "error", message: String(e?.stack || e) } })
          .catch(() => {})
      }
    },
  }
}
