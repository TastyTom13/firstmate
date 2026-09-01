# Free-lane slim prompt: what the model provider actually receives

A local mock server stood in for Groq's OpenAI-compatible endpoint and reproduced
its chars/4 token estimate over the whole request payload. Real `pi` 0.84.3 was
run from this repo (which has AGENTS.md and CLAUDE.md), one-line prompt `hi`.
Groq's free tier caps 8,000 tokens/minute.

| Run | est. tokens | system prompt chars | tool defs sent |
|---|---|---|---|
| BEFORE - base commit e90e4b5 (`pi --provider groq --model ... -p hi`) | 20,177 | 76,870 | 4 ['read', 'bash', 'edit', 'write'] |
| AFTER - this branch (`bin/fm-free-lane-run.sh groq -p hi`) | 134 | 306 | 0  |
| AFTER + caller `--system-prompt "CALLER OWN PROMPT"` after the lane name | 88 | 121 | 0  |
| AFTER + caller `--tools read` after the lane name | 529 | 1,163 | 1 ['read'] |

## System prompt actually sent (first 200 chars each)

**BEFORE - base commit e90e4b5 (`pi --provider groq --model ... -p hi`)**

```
You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

Available tools:
- read: Read
```

**AFTER - this branch (`bin/fm-free-lane-run.sh groq -p hi`)**

```
You are a one-shot text generator running on a free-tier model. Respond with only the requested content, nothing else: no tool calls, no preamble, no explanation of your process, no follow-up question
```

**AFTER + caller `--system-prompt "CALLER OWN PROMPT"` after the lane name**

```
CALLER OWN PROMPT
Current working directory: /Users/tomas/.no-mistakes/worktrees/a6ca20682364/01M1EASBMEB9Z5QJR6DTKWWVRB

```

**AFTER + caller `--tools read` after the lane name**

```
You are a one-shot text generator running on a free-tier model. Respond with only the requested content, nothing else: no tool calls, no preamble, no explanation of your process, no follow-up question
```

