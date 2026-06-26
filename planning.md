# Provenance Guard — Planning Document

## Architecture

### Flow 1: Submission

```text
POST /submissions
        |
        | raw request
        v
┌───────────────┐
│  Rate Limiter │─── 429 ──► caller (if over limit)
└───────────────┘
        |
        | raw text
        v
┌──────────────────┐
│ Input Validator  │─── 422 ──► caller (if invalid)
└──────────────────┘
        |
        | validated text
        ├──────────────────────────────┐
        v                              v
┌─────────────────┐        ┌──────────────────────┐
│  LLM Classifier │        │ Stylometric Analyzer  │
│    (Groq)       │        │   (pure Python)       │
└─────────────────┘        └──────────────────────┘
        |                              |
        | llm_score (0.0–1.0)          | stylometric_score (0.0–1.0)
        └──────────────┬───────────────┘
                       v
           ┌───────────────────────┐
           │  Confidence           │
           │  Aggregator           │
           └───────────────────────┘
                       |
                       | classification + confidence score
                       v
           ┌───────────────────────┐
           │   Label Generator     │
           └───────────────────────┘
                       |
                       | label text
                       v
           ┌───────────────────────┐
           │    Audit Logger       │
           └───────────────────────┘
                       |
                       | full decision written to log
                       v
           ┌───────────────────────────────────────┐
           │  Response to caller                   │
           │  content_id, classification,          │
           │  confidence, label, signal scores     │
           └───────────────────────────────────────┘
```

A submission passes through a rate limiter and input validator before entering the detection pipeline, where an LLM classifier (Groq) and a stylometric heuristic analyzer run independently on the text. Their scores are combined by a confidence aggregator, which classifies the content and produces a confidence score; that result flows to the label generator, which writes the plain-language transparency label, and finally to the audit logger before the response is returned to the caller.

---

### Flow 2: Appeal

```text
POST /appeals/{content_id}
        |
        | content_id + reasoning
        v
┌──────────────────┐
│  Appeals Handler │─── 404 ──► caller (content_id not found)
│                  │─── 409 ──► caller (appeal already filed)
└──────────────────┘
        |
        | appeal record + status → "under_review"
        v
┌──────────────────┐
│   Audit Logger   │  (appends to existing log entry; does not overwrite)
└──────────────────┘
        |
        | updated log entry confirmed
        v
┌──────────────────────────────┐
│  Response to caller          │
│  content_id, status,         │
│  confirmation message        │
└──────────────────────────────┘
```

When a user believes their content was misclassified, they submit an appeal with their reasoning. The appeals handler looks up the original decision by content ID, appends the appeal record to that log entry without overwriting the original verdict, and sets the status to "under review" so a human reviewer can evaluate the case alongside the full signal breakdown.

---

## Architecture Narrative: The Life of a Piece of Text

A user submits a piece of text (a poem, short story, blog post) to the content submission endpoint. The request first hits the rate limiter, which enforces a per-IP quota to prevent abuse and protect the cost of calling an external LLM. If the limit is exceeded, the request is rejected immediately.

The text then enters the detection pipeline, which runs two independent signals:

- **LLM-based classification (Groq):** The text is sent to Groq, which assesses whether the writing reads as human or AI-generated. This captures holistic semantic and stylistic properties such as tone, voice, and whether ideas develop in a naturally human way.
- **Stylometric heuristics:** Use Python to compute measurable structural statistics such as sentence length variance, vocabulary diversity (type-token ratio), and punctuation density. AI text tends to be more uniform; human writing is more variable. This signal is fully independent from the LLM: one is semantic, one is structural.

Both signals produce a numeric score. The confidence aggregator combines them into a single classification and confidence score. When the two signals agree strongly, confidence is high. When they disagree, a penalty is applied. A score of 0.51 from conflicting signals means something much different than a 0.95 from two signals in agreement.

The classification and confidence score are passed to the label generator, which produces the transparency label shown to readers. High-confidence results get a clear human or AI attribution; low-confidence or conflicting results produce an "uncertain" label. All three variants are written in plain, non-accusatory language.

Before returning the response, the audit logger records the full decision: classification, confidence score, both signal scores, the label shown, and the content's current status. Every submission is logged this way.

If a user believes their content was misclassified, they can submit an appeal. The appeals handler captures their reasoning, appends it to the original log entry without overwriting it, and updates the content's status to "under review." No automated re-classification occurs; a human reviewer reads the log.

---

## Detection Signals

### Signal 1: LLM-based classification (Groq)

**What it measures:** The overall semantic and stylistic character of the text - whether the writing "sounds" human. The model reads the text holistically and assesses qualities like voice authenticity, how ideas develop, whether the prose has the kind of natural roughness or idiosyncrasy that human writers produce.

**Why this differs between human and AI writing:** LLMs trained on human feedback tend to produce writing that is coherent, well-organized, and smooth in a way that is subtly consistent across outputs. Human writing carries more personal register, unexpected word choices, and structural looseness. A model prompted to assess this has seen enough of both to pick up on these holistic patterns without needing to name them explicitly.

**Blind spots:** This signal is easily fooled by deliberate prompting. A user who asks an LLM to "write like a human, with typos and informal language" may produce output the classifier scores as human. It also penalizes polished human writers - someone with a highly consistent, refined style may read as AI-like. It cannot detect AI content that has been lightly edited by a human, since editing changes the surface texture the model is reading.

---

### Signal 2: Stylometric heuristics

**What it measures:** Structural statistics computed directly from the text: sentence length variance (how much the length of sentences changes across the piece), type-token ratio (the ratio of unique words to total words, a measure of vocabulary diversity), and punctuation density (how often non-standard punctuation like em-dashes, ellipses, or exclamation points appear).

**Why this differs between human and AI writing:** AI-generated text tends to be statistically uniform. Sentences cluster around a similar length, vocabulary stays within a safe and predictable range, and punctuation is conventional. Human writing is messier - some sentences are fragments, some run long, word choice is more idiosyncratic, and punctuation reflects personality. These differences are measurable without any model inference.

**Blind spots:** This signal measures form, not meaning. A human who writes in a deliberately controlled style (academic writing, technical documentation, minimalist fiction) will score as AI-like. Conversely, an AI prompted to produce varied sentence lengths and unusual vocabulary can defeat it. It also has no sense of context - a short poem and a long essay will produce very different raw statistics regardless of authorship, so the signal is more reliable on longer texts.

### Output format and combination

Both signals produce a float between 0.0 and 1.0, where 0.0 = AI-generated and 1.0 = human-authored. Neither signal produces a binary flag - the score is continuous so that uncertainty can be expressed at every step.

**Classification rule:** If both signals score strictly above 0.5, classify as `human_authored`. If both score strictly below 0.5, classify as `ai_generated`. Any other case - one above and one below, or either signal exactly at 0.5 — classifies as `uncertain`. A score of exactly 0.5 means the signal could not lean either way, which is maximum uncertainty.

**Combined confidence score:** Take a weighted average of the two scores - LLM weighted at 0.6, stylometric at 0.4. Then convert to a confidence value by measuring how far the weighted average is from the midpoint (0.5) and scaling to [0.0, 1.0]. A weighted average of 0.9 produces a high confidence human result; a weighted average of 0.1 produces a high confidence AI result; a weighted average near 0.5 produces low confidence regardless of direction. When signals disagree (one above 0.5, one below), subtract an additional penalty proportional to how far apart they are, pushing the score toward 0.5 and surfacing the uncertainty.

---

## Uncertainty Representation

**What a confidence score of 0.6 means:** Both signals leaned in the same direction, but neither strongly. The system has a mild lean - not enough to be trusted for a firm verdict. A 0.6 confidence gets the uncertain label.

**Thresholds:**

| Confidence | Label shown |
| --- | --- |
| ≥ 0.80 | High-confidence AI or high-confidence human (whichever the classification is) |
| 0.60 – 0.79 | Uncertain - system has a lean but not enough to commit |
| < 0.60 | Uncertain - signals were weak, conflicting, or text was too short to read reliably |

The threshold for "uncertain" is set deliberately wide (everything below 0.80). This is because the cost of a wrong confident verdict falls on the user, while the cost of an uncertain verdict is only that the reader gets less information. When in doubt, default to uncertainty.

**What the score is not:** The confidence score reflects signal agreement and distance from the midpoint, not the probability of being correct. A 0.90 means both signals strongly agreed, not that the system is 90% accurate. This distinction is documented and not exposed in the label text.

---

## Transparency Label Design

Three label variants: each label is in plain, non-accusatory language and communicates what the reader should take from it without requiring them to understand the scoring system.

**High-confidence AI** (classification = `ai_generated`, confidence ≥ 0.80):

> "This content shows strong indicators of AI generation. Our system analyzed the writing style and structure across multiple signals and found patterns consistent with AI-produced text."

**High-confidence Human** (classification = `human_authored`, confidence ≥ 0.80):

> "This content shows strong indicators of human authorship. Our system analyzed the writing style and structure across multiple signals and found patterns consistent with human-produced text."

**Uncertain** (classification = `uncertain`, OR confidence < 0.80):

> "Our system was unable to confidently determine whether this content was written by a human or generated by AI. The signals we analyzed were either mixed or not strong enough to make a reliable attribution."

Notes on language choices: "shows strong indicators of" rather than "was generated by": the label describes what the system observed, not what it knows to be true. "Unable to confidently determine" is neutral; it does not suggest the user did anything wrong.

---

## Appeals Workflow

**Who can submit an appeal:** Any user who has the `content_id` for a submission. In a production system this would be gated to the original submitter; in this MVP, possession of the ID is the only check.

**What they provide:** A `reasoning` field (required, non-empty string) - the user's explanation of why they believe the classification is wrong. The system takes the reasoning at face value and flags the decision for human review.

**What the system does on receipt:**

1. Looks up the `content_id` in the audit log. Returns 404 if not found.
2. Checks that no appeal has already been filed for this entry. Returns 409 if one exists.
3. Appends an appeal record to the existing log entry - the original classification, confidence, and signal scores are preserved unchanged.
4. Sets the entry's `status` from `decided` to `under_review`.
5. Returns a confirmation response with the updated status.

No automated re-classification occurs. The system does not re-run signals on appeal.

**What a human reviewer sees when they open the appeal queue (GET /log filtered to `under_review`):**

- The original classification and confidence score
- Both signal scores (llm_score and stylometric_score) that produced the verdict
- The exact label text that was shown to readers
- The user's appeal reasoning and when it was filed
- The original submission timestamp

The reviewer evaluates whether the classification was reasonable and whether the appeal has merit.

---

## Anticipated Edge Cases

### Edge case 1: A poem that uses repetition and simple vocabulary

A user submits a piece that relies on anaphora (i.e., deliberate, heavy repetition of a phrase at the start of each line) and intentionally plain language.

The stylometric signal sees: very low type-token ratio (the same words repeat constantly), low sentence length variance (lines are structurally parallel), conventional punctuation. Every number looks like AI output. The LLM signal might recognize the repetition as a stylistic device, or it might read the deliberate simplicity as the kind of "clean" prose that AI produces.

The likely result: both signals lean AI, the system returns a high-confidence AI classification, and the poet's work gets flagged. The creator has to file an appeal, and a human reviewer has to recognize that the stylistic features driving the classification are in fact the entire artistic point.

This case cannot be fixed without understanding the text's intent, which neither signal can assess.

### Edge case 2: An AI-generated draft that was substantially rewritten by a human

A user uses an LLM to generate a rough draft, then rewrites it heavily, changing word choices, breaking up sentences, adding personal anecdotes, cutting the smooth transitions. By the time they submit it, the prose reflects their voice more than the original output.

The stylometric signal now sees human-like variance, because the rewriting introduced it. The LLM signal may still detect something structurally AI-like underneath, or it may read the surface texture as human. The signals are likely to disagree, which pushes the result toward uncertain.

This is actually the system working as intended - the content is genuinely hybrid, and uncertain is the honest answer. But it means creators who use AI as a drafting tool and then do substantial creative work on top will consistently get the uncertain label, even if their contribution was the majority of the creative work. The label text handles this: "unable to confidently determine" does not accuse anyone of anything.

---

## AI Tool Plan

### M3: Submission endpoint + first signal (LLM classifier)

**Spec sections to provide:** The Architecture diagram (Flow 1), the Detection Signals section (Signal 1 only), and the API contract for `POST /submissions`.

**What to ask the AI tool to generate:** A Flask app skeleton with a single `POST /submissions` route that accepts a text body and returns a stub response, plus a standalone `classify_with_llm(text: str) -> float` function that sends the text to Groq and parses the response into a score between 0.0 and 1.0. 

**How to verify before wiring up:** Call `classify_with_llm()` directly on three inputs - a clearly AI-sounding paragraph (smooth, coherent, zero rough edges), a clearly human-sounding one (informal, idiosyncratic, uneven), and a borderline case. Check that the scores go in the expected direction and that the function doesn't crash when Groq returns an unexpected format. 

---

### M4: Second signal + confidence scoring

**Spec sections to provide:** The Architecture diagram (Flow 1), the Detection Signals section (Signal 2 + the Output format and combination subsection), and the Uncertainty Representation section including the threshold table.

**What to ask the AI tool to generate:** A standalone `compute_stylometric_score(text: str) -> float` function that computes sentence length variance, type-token ratio, and punctuation density and returns a combined score in [0.0, 1.0], plus an `aggregate_confidence(llm_score: float, stylometric_score: float) -> dict` function that implements the weighted average, classification rule (strictly above/below 0.5), and disagreement penalty.

**What to check:** Run the aggregator on four combinations - both signals high (should be high-confidence human), both signals low (should be high-confidence AI), signals split (should be uncertain with confidence < 0.6), both exactly 0.5 (should be uncertain). Also check that a 0.95 agreement produces a meaningfully higher confidence than a 0.6 agreement.

---

### M5: Production layer — labels, appeals, and audit log

**Spec sections to provide:** The Architecture diagrams (both Flow 1 and Flow 2), the Transparency Label Design section (all three variants with exact text), the Appeals Workflow section, and the API contract for `POST /appeals/{content_id}` and `GET /log`.

**What to ask the AI tool to generate:** A `generate_label(classification: str, confidence: float) -> str` function that returns the correct label text for each of the three variants, the `POST /appeals/{content_id}` endpoint with 404/409 error handling, and the `GET /log` endpoint that returns the full audit log.

**How to verify:** Hit the submission endpoint with inputs that should produce each of the three labels and confirm the exact label text matches the spec - not just the classification, but the full string. Then file an appeal against one of the logged entries and call `GET /log` to confirm the appeal is present and the status is `under_review`. Attempt a second appeal on the same entry and confirm a 409 is returned.
