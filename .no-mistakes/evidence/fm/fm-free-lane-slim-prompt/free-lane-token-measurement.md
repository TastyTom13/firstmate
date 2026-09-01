# Free-lane slim prompt: measured request size against a mock Groq endpoint

Mock OpenAI-compatible server on 127.0.0.1:8731 records each captured chat-completion
request and estimates prompt tokens the way Groq does (chars / 4, messages + tool defs).
Real pi 0.84.3. Working directory is the firstmate repo (AGENTS.md = 73,059 chars),
and $PI_CODING_AGENT_DIR trust.json trusts it, so .pi/extensions/*.ts are discoverable.
Groq free tier caps 8,000 tokens/minute.

| run | command | est. prompt tokens | tool defs | under 8k cap |
|---|---|---|---|---|
| before (pre-fix dispatch shape) | `pi --provider groq --model openai/gpt-oss-120b -p "hi"` | 23673 | 6 | NO |
| after (this change) | `bin/fm-free-lane-run.sh groq -p "hi"` | 84 | 0 | yes |

## Captured request, before
{
  "estimated_prompt_tokens": 23673,
  "message_chars": 90973,
  "tool_def_chars": 3718,
  "n_messages": 2,
  "n_tools": 6,
  "system_preview": "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n\nAvailable tools:\n- read: Read"
}
## Captured request, after
{
  "estimated_prompt_tokens": 84,
  "message_chars": 335,
  "tool_def_chars": 0,
  "n_messages": 2,
  "n_tools": 0,
  "system_preview": "You are a one-shot text generator running on a free-tier model. Respond with only the requested content, nothing else: no tool calls, no preamble, no explanation of your process, no follow-up question"
}
## Documented per-call overrides, each run through the runner in the same repo

| override passed after the lane name | observed effect | est. tokens |
|---|---|---|
| `--system-prompt "CALLER OWN PROMPT"` | system message is the caller's, not the slim default | 38 |
| `--tools read` | 1 built-in tool re-registered | 3851 |
| `-e .pi/extensions/fm-branch-supervision.ts` | 1 extension tool registered despite --no-extensions | 186 |
| `--tools fm_branch_outcomes` | 0 tools, as documented: --tools cannot re-register an undiscovered extension tool | 84 |

System prompt actually delivered, after the fix:

```
You are a one-shot text generator running on a free-tier model. Respond with only the requested content, nothing else: no tool calls, no preamble, no explanation of your process, no follow-up question
```
