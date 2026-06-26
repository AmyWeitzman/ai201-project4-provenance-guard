# Provenance Guard — Planning Document

## System Diagrams

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

---

## The False Positive Problem

A false positive here means the system classifies a human writer's work as AI-generated. This is the failure mode that matters most, because it's the one that harms real people.

**The scenario:** A human writer submits a polished short story. Their style is clean and deliberate - consistent sentence rhythm, formal vocabulary, sparse punctuation. They have worked hard to make it read smoothly.

**What each signal sees:**

The LLM signal reads coherent, well-organized prose with no rough edges. That is exactly what AI output looks like. It returns a score leaning toward AI-generated.

The stylometric signal measures low sentence length variance, a narrow type-token ratio, and low punctuation density. Those numbers also match AI writing patterns. It returns a score leaning toward AI-generated.

**Where this breaks down:** Both signals agree - and they are both wrong. Because they agree, the disagreement penalty is never applied. The confidence aggregator returns a high-confidence AI classification. The system is not uncertain; it is confidently wrong.

**What the label says:** The user's readers see: *"This content appears to have been generated by AI. Our system analyzed the text across multiple signals and is highly confident in this assessment."* The word "highly confident" makes this worse, not better. It signals to readers that the system is sure, when in fact the system simply cannot distinguish polished human writing from AI output.

**How the user appeals:** The user submits an appeal with their reasoning - they wrote this, here is their draft history, here are earlier versions. The appeals handler logs the reasoning alongside the original decision and marks the content as "under review." Nothing is automatically corrected. A human reviewer has to read it.

**What this tells us about the design:**

The label language cannot be accusatory, even at high confidence. "Appears to have been generated by AI" is more defensible than "was generated by AI," but it still harms the user in the time between classification and appeal resolution. The appeal mechanism must be easy to find and use - it is the only correction path.

The deeper problem is that the system has no way to distinguish "polished human" from "average AI." The confidence score reflects agreement between signals, not actual certainty about authorship. A 0.90 confidence score means both signals strongly agreed - it does not mean the system is 90% likely to be correct. This distinction needs to be clear in how the label is written and how the score is documented.

This scenario should inform two decisions in implementation: the label text for high-confidence AI results should acknowledge the system's limitations without undermining its purpose, and the threshold for showing "uncertain" rather than a firm verdict should probably be set conservatively so that borderline cases default to uncertainty rather than a wrong confident answer.


