# Loop Engineering: the 14-step roadmap from prompter to designer

*2026-07-08 · founders · thought-leader · Claude*

# Loop Engineering: The 14-Step Roadmap From Prompter to Designer

*SnackOnAI | Technical Deep Dive | thought-leader*

---

## The Assumption Everyone Gets Wrong

Most founders believe the progression from "prompt user" to "AI builder" is a knowledge problem. Read enough papers, clone enough repos, ship a RAG pipeline, done. You are now an AI engineer.

That framing is wrong, and it is costing you.

The real progression is a *design sensibility* problem. Specifically, it is the ability to engineer the *failure loop*, not the success path. Anyone can wire up a call to `gpt-4o` and demo it working. The moat is knowing what to do when it doesn't, and building a system that handles that automatically, at scale, without a human in the seat.

That is what Loop Engineering is. And almost no one building AI products today is actually doing it.

---

## What It Actually Does

Loop Engineering is the practice of designing AI systems where the *feedback cycle itself* is the primary engineering artifact, not the model call.

A prompter fires a request and reads the output. A Loop Designer architects:

- A **Planner** that decomposes tasks
- An **Executor** that runs tools or sub-agents
- An **Evaluator** that scores outputs against a structured rubric
- A **Failure Taxonomy** that categorizes why something broke
- A **Memory Store** that persists failure traces across iterations

The 14-step roadmap is not 14 arbitrary skills. It is a progression through four capability tiers, each tier unlocking the next:

```text
Tier 1 (Steps 1–4):   Prompt literacy
Tier 2 (Steps 5–8):   Tool use and orchestration
Tier 3 (Steps 9–11):  Evaluation and failure classification
Tier 4 (Steps 12–14): Loop design, memory, and self-correction
```

Founders typically max out at Tier 2 and call it "agentic AI." It is not. Tier 2 without Tier 3 is a system that fails silently. Tier 3 without Tier 4 is a system that fails loudly but doesn't recover. Tier 4 is the actual product.

---

## The Architecture, Unpacked

```ascii
Prompter ──► [Zero-Shot] ──► [Few-Shot] ──► [Chain-of-Thought] ──► [Tool Use] ──► [Loop Designer]
                                                                        │                          │
                                                               ┌────────▼────────┐      ┌──────────▼──────────┐
                                                               │    Planner      │◄────►│   Memory Store      │
                                                               └────────┬────────┘      └─────────────────────┘
                                                                        │
                                                               ┌────────▼────────┐
                                                               │    Executor     │
                                                               └────────┬────────┘
                                                                        │
                                                               ┌────────▼────────┐
                                                               │   Observation   │
                                                               └────────┬────────┘
                                                                        │
                                                               ┌────────▼────────┐
                                                               │    Evaluator    │──► pass ──► DONE
                                                               └────────┬────────┘
                                                                        │ fail
                                                               ┌────────▼────────┐
                                                               │ Failure Taxonomy│  ◄── THIS is the moat
                                                               │ (hallucination/ │
                                                               │  tool-loop/     │
                                                               │  ctx-exhaust)   │
                                                               └────────┬────────┘
                                                                        │
                                                               re-plan trigger ──► Planner (next iteration)
```

**Figure 1: The Loop Engineering architecture, from naive prompter to full loop designer. The Failure Taxonomy node is the structural differentiator that separates brittle demos from production systems.**

Notice what is *not* in this diagram: the model. The model is infrastructure. The architecture above is the product. Every node except the model is something you design, own, and iterate on. The Failure Taxonomy specifically is where compounding advantage accumulates, because it is built from *your* system's real failure distribution, not a generic benchmark.

Let's break each node down:

**Planner:** Decomposes the incoming task into a sequence of executable sub-steps. In practice this is a structured prompt that outputs a JSON plan. The Planner also receives the Memory Store's failure traces, which means iteration N+1 has information iteration N lacked.

**Executor:** Runs the plan steps against tools (APIs, code interpreters, search, databases). The Executor does not make judgment calls. It executes and surfaces raw observations.

**Observation:** The raw output from the Executor, unprocessed. Keeping this separate from the Evaluator is intentional. You want the Evaluator operating on clean signal, not already-interpreted output.

**Evaluator:** Scores the observation against the original task. The key design decision here is *structured output*. A boolean pass/fail is not enough. You need the failure category.

**Failure Taxonomy:** The categories you define here directly determine the quality of your re-plan. "It failed" tells the Planner nothing. "It failed because the tool returned a malformed JSON and the Executor had no fallback handler" tells the Planner exactly what to fix.

**Memory Store:** Persists the failure trace across iterations. This is the Reflexion primitive. Without it, each iteration starts blind.

---

## The Code, Annotated

```python
import openai, json

def reflexion_loop(task: str, max_iterations: int = 5) -> str:
    memory: list[str] = []          # ← persistent failure trace store (Reflexion primitive #3)
    actor_prompt_base = task

    for iteration in range(max_iterations):
        # --- ACTOR: generate candidate solution ---
        reflection_context = "\n".join(memory) if memory else "No prior attempts."
        actor_prompt = (
            f"Task: {actor_prompt_base}\n"
            f"Prior failure traces:\n{reflection_context}\n"
            f"Produce your best solution now."
        )
        response = openai.chat.completions.create(
            model="gpt-4o",
            messages=[{"role": "user", "content": actor_prompt}]
        )
        candidate = response.choices[0].message.content

        # --- EVALUATOR: structured pass/fail with failure category ---
        eval_prompt = (
            f"Task: {actor_prompt_base}\n"
            f"Candidate solution:\n{candidate}\n"
            "Return JSON: {\"pass\": bool, \"failure_category\": str, \"failure_detail\": str}"
            # ← failure_category forces taxonomy: 'logic_error'|'hallucination'|'incomplete'|'tool_misuse'
            # THIS is the trick: structured failure forces the next actor prompt
            # to address a *specific* failure mode, not retry blindly
        )
        eval_response = openai.chat.completions.create(
            model="gpt-4o",
            messages=[{"role": "user", "content": eval_prompt}]
        )
        verdict = json.loads(eval_response.choices[0].message.content)

        if verdict["pass"]:
            return candidate

        # --- MEMORY WRITE: append structured failure trace ---
        failure_trace = (
            f"Iteration {iteration + 1} failed. "
            f"Category: {verdict['failure_category']}. "
            f"Detail: {verdict['failure_detail']}."
            # ← THIS is the trick: the memory entry is structured, not free-form.
            # Structured traces give the Planner parseable signal on the next pass.
            # Free-form "it didn't work" degrades into noise by iteration 3.
        )
        memory.append(failure_trace)

    return f"Max iterations reached. Last candidate:\n{candidate}"
```

**Figure 2: A minimal Reflexion loop in Python. The two `# ← THIS is the trick` annotations mark the two decisions that separate this from a naive retry loop: structured failure taxonomy in the Evaluator, and structured trace writes to memory.**

Two design choices here that look minor but are not:

**Choice 1:** The `failure_category` enum is constrained. You do not let the Evaluator free-form describe the failure. You force it into `logic_error`, `hallucination`, `incomplete`, or `tool_misuse`. This means the Actor's next prompt can be conditionally constructed. A `hallucination` failure triggers a "cite your sources" instruction. A `tool_misuse` failure triggers a "here is the correct tool schema" injection.

**Choice 2:** The memory write is structured. `f"Iteration {iteration + 1} failed. Category: X. Detail: Y."` By iteration 4, the Actor has a clean, machine-readable failure history, not a blob of free-text that the model has to re-interpret.

---

## It In Action

**Task:** "Write a Python function that fetches the current Bitcoin price from CoinGecko and returns it as a float."

**Iteration 1:**

- Actor produces a function using `requests.get("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd")`
- Evaluator runs the function (via code interpreter tool)
- Output: `AttributeError: 'NoneType' object has no attribute 'get'` because the response JSON structure was assumed incorrectly
- Verdict: `{"pass": false, "failure_category": "logic_error", "failure_detail": "Response JSON ac
