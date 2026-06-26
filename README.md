# Provenance Guard

A backend API for attributing creative text content as human-authored or AI-generated. Platforms that host original writing - poetry, short stories, blog posts - can plug this in to classify submissions, surface transparency labels to readers, and handle user appeals.

---

## Architecture Overview

A submission takes the following path from input to label:

A user submits a piece of text (a poem, short story, blog post) to the content submission endpoint. The request first hits the rate limiter, which enforces a per-IP quota to prevent abuse and protect the cost of calling an external LLM. If the limit is exceeded, the request is rejected immediately.

The text then enters the detection pipeline, which runs two independent signals:

- **LLM-based classification (Groq):** The text is sent to Groq, which assesses whether the writing reads as human or AI-generated. This captures holistic semantic and stylistic properties such as tone, voice, and whether ideas develop in a naturally human way.
- **Stylometric heuristics:** Use Python to compute measurable structural statistics such as sentence length variance, vocabulary diversity (type-token ratio), and punctuation density. AI text tends to be more uniform; human writing is more variable. This signal is fully independent from the LLM: one is semantic, one is structural.

Both signals produce a numeric score. The confidence aggregator combines them into a single classification and confidence score. When the two signals agree strongly, confidence is high. When they disagree, a penalty is applied. A score of 0.51 from conflicting signals means something much different than a 0.95 from two signals in agreement.

The classification and confidence score are passed to the label generator, which produces the transparency label shown to readers. High-confidence results get a clear human or AI attribution; low-confidence or conflicting results produce an "uncertain" label. All three variants are written in plain, non-accusatory language.

Before returning the response, the audit logger records the full decision: classification, confidence score, both signal scores, the label shown, and the content's current status. Every submission is logged this way.

If a user believes their content was misclassified, they can submit an appeal. The appeals handler captures their reasoning, appends it to the original log entry without overwriting it, and updates the content's status to "under review." No automated re-classification occurs; a human reviewer reads the log.

1. **Rate limiter** — the request is checked against the per-IP quota before any processing begins. If the limit is exceeded, a 429 is returned immediately.
2. **Input validator** — the request body is validated: `text` (required, min 50 characters) and `user_id` (required) must be present.
3. **Detection pipeline** — two independent signals run on the text:
   - The **LLM classifier** sends the text to Groq and receives a score assessing whether the writing reads as human or AI-generated.
   - The **stylometric analyzer** computes structural statistics directly from the text in pure Python.
4. **Confidence aggregator** — both signal scores are combined into a classification (`ai_generated`, `human_authored`, or `uncertain`) and a confidence score.
5. **Label generator** — the classification and confidence are mapped to one of three plain-language transparency labels.
6. **Audit logger** — the full decision (both signal scores, classification, confidence, label, status) is written to the audit log before the response is returned.
7. **Response** — the caller receives a structured JSON object with `content_id`, `classification`, `confidence`, `label`, and individual signal scores.

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
        | llm_score (0.0-1.0)          | stylometric_score (0.0-1.0)
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
        | appeal record + status -> "under_review"
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

If a user believes their content was misclassified, they submit a `POST /appeal` request. The appeals handler looks up the original decision by `content_id`, appends the user's reasoning to the log entry without overwriting the original verdict, and sets the status to `under_review`.

---

## Detection Signals

### Why three signals, and why these three

The three signals cover three separate layers of analysis: semantic meaning (LLM), text structure (stylometric), and vocabulary (informality). Each is genuinely independent. When all three agree, the confidence is high because three separate observations converged. When they split, the system reverts to uncertainty rather than forcing a decision.

All three scores are returned in the response and logged in the audit record, so a reviewer reading an appeal can see exactly where the signals diverged: "the LLM called it AI and the stylometric agreed, but the informality signal was solidly human" is actionable in a way that a single opaque number is not.

**Voting and weighting:**

Classification uses a majority vote: if 2 or more signals are strictly above 0.5, the content is classified `human_authored`; if 2 or more are strictly below 0.5, it is `ai_generated`; any other split is `uncertain`. Confidence uses a weighted average reflecting each signal's reliability: LLM 0.50, stylometric 0.30, informality 0.20. The LLM carries the most weight because it reads meaning holistically; the informality signal carries the least because its features (contractions, discourse markers) are easily manipulated.

### Signal 1: LLM semantic classifier (Groq)

The text is sent to `llama-3.1-8b-instant` via Groq with a prompt that describes the stylistic and structural markers of AI-generated vs. human-written text and asks the model to return a score between 0.0 (AI) and 1.0 (human). The prompt includes few-shot examples to anchor the model's output scale.

**What it measures:** Holistic semantic and stylistic character — tone, voice authenticity, whether ideas develop in a naturally human way, and the presence or absence of the smooth, comprehensive, "assistant-like" quality that LLM output tends to have.

**Why this signal:** Structural features alone cannot capture what makes AI text feel like AI text. The LLM reads the text as a whole, picking up on hedging patterns, how transitions work, word choice at the sentence level — things that are real but hard to count. It is also the only signal that responds to meaning rather than form, which matters for poetry and narrative where sentence structure deliberately varies.

**What it misses:** It can be fooled by deliberate prompting — an AI told to "write casually, with typos" may score as human. It also penalizes polished human writers whose consistent prose looks like well-prompted LLM output. It cannot detect AI content that a human has substantially rewritten, because editing changes the surface texture the model reads. Perhaps most critically: the classifier is itself an LLM, so it has structural blind spots about what AI writing looks like from the outside — it may not recognize patterns that differ between models or that only appear in certain fine-tuned variants.

### Signal 2: Stylometric heuristics (Python)

Three structural statistics are computed directly from the text with no model inference:

- **Sentence length variance:** The standard deviation of word counts across sentences. Human writing varies more - some sentences are fragments, some run long. AI output clusters around a consistent length. Score: `min(std_dev / 15.0, 1.0)`.
- **Average word length:** Shorter average word length indicates human-like writing. AI text tends toward longer, more formal vocabulary ("transformative", "stakeholders", "methodologies"). Score: `max(0, 1.0 - (avg_len - 4) / 4)`.
- **Punctuation density:** Count of expressive punctuation marks (`!`, `?`, `;`, `--`, `...`, `()`) per 100 words. Human writers use these more freely. Score: `min(count_per_100 / 5.0, 1.0)`.

Each sub-score is in [0.0, 1.0] and the three are averaged into a single `stylometric_score`.

**What it measures:** How the text is built structurally, independent of meaning or topic.

**Why this signal:** It runs in pure Python with no API calls, adds no latency, and is completely transparent - every sub-score can be explained in one sentence. It is also complementary to the LLM signal: no opinion about meaning, only form.

**What it misses:** It measures form, not intent. Professional, academic text with long words, uniform sentence length, and no expressive punctuation would score as AI-like. It is also unreliable on very short texts (under ~100 words), where sentence variance is low by definition and word counts are too small for meaningful statistics. Originally this signal included type-token ratio (TTR), but TTR saturates on short texts - nearly every word is unique in a 40-word passage regardless of authorship - so it was replaced with average word length, which is length-invariant.

### Signal 3: Informality / vocabulary (Python)

Three vocabulary-level features are counted directly from the text:

- **Contraction rate:** Contractions ("can't", "it's", "I've", etc.) indicate informal vocabulary. AI text avoids them by default. Score: contractions per 100 words / 3.0, capped at 1.0.
- **First-person pronoun density:** "I", "me", "my", "we", "our" indicate personal voice. AI text tends toward impersonal constructions. Score: first-person pronouns per 100 words / 5.0, capped at 1.0.
- **Discourse marker density:** Words like "honestly", "actually", "anyway", "I mean", "kind of" appear in natural speech and informal writing. AI text almost never uses them unprompted. Score: markers per 100 words / 4.0, capped at 1.0.

The three sub-scores are averaged into a single `informality_score`.

**What it measures:** The vocab of the writing, how conversational vs. formal the vocabulary choices are, independent of both meaning and structural statistics.

**Why this signal:** Vocabulary is independent of the other 2 signals. A text can be structurally varied (high stylometric score) and semantically ambiguous (LLM returns 0.5), yet have zero contractions and zero first-person pronouns, a pattern that strongly suggests AI authorship. This signal catches cases the other two miss.

**What it misses:** It is the easiest signal to fool intentionally - a user who knows the system can sprinkle contractions and "honestly" into AI output to inflate the score. It is also unreliable on formal human writing: an academic paper or legal doc uses none of these features by convention, and will score 0.0 even when written entirely by a human. Short texts (under 10 words) return 0.5 by default.

### What would change for a real deployment

**The stylometric thresholds need calibration data.** The scoring functions use handpicked thresholds (e.g., std_dev of 15 words as the max variance score, average word length of 4 as the human baseline). These were set by reasoning about typical values, not by fitting to labeled examples. In production you would want a labeled dataset of confirmed-human and confirmed-AI texts, measure the actual distributions of each feature per genre, and set thresholds to separate them. The current thresholds almost certainly over- or under-fire on specific types of writing.

**The LLM signal needs a bigger model for borderline cases.** `llama-3.1-8b-instant` handles clear cases well but tends toward 0.5 on anything ambiguous. The easy cases do not need a better model; the hard ones do. A larger model or a classifier fine-tuned specifically on AI-detection would improve sensitivity exactly where it matters.

**The 0.80 confidence threshold is not validated.** Choosing 0.80 as the cutoff for showing a firm label was a judgment call, not a measured one. In production you would need to know the false positive rate at that threshold - how often does the system confidently label human text as AI? The threshold should be derived from that number and what rate is acceptable for the platform, not from intuition.

**Genre-specific calibration matters.** The signals behave differently on poetry, blog posts, and academic writing, but the system treats them the same. A blog post and a legal document use completely different vocabulary and sentence patterns for reasons unrelated to AI. A production system would likely want genre detection upstream, with separate scoring parameters per genre.

---

## Confidence Scoring

All three signals produce a score in [0.0, 1.0] where 0.0 = AI-generated and 1.0 = human-authored.

**Classification rule (majority vote):**

- 2 or more signals strictly above 0.5 -> `human_authored`
- 2 or more signals strictly below 0.5 -> `ai_generated`
- Any other case (split, or signals at exactly 0.5) -> `uncertain`

**Confidence score formula:**

1. Compute a weighted average: `weighted = 0.50 x llm_score + 0.30 x stylometric_score + 0.20 x informality_score`. Weights reflect each signal's reliability: the LLM reads meaning holistically; the informality signal is easiest to manipulate.
2. Convert to confidence: `raw = abs(weighted - 0.5) x 2`. Scales distance from the midpoint to [0, 1].
3. When classification is `uncertain`, apply a disagreement penalty equal to the standard deviation of the three scores: `confidence = max(0, raw - std_dev(scores))`. A wide spread in scores produces a stronger penalty than when signals cluster near a single value.

**The confidence score reflects signal agreement, not accuracy.** A 0.97 confidence means all three signals strongly agreed - it does not mean the system is 97% likely to be correct. This distinction is intentional and is reflected in label language.

**How I validated the scores are meaningful:**

I tested four inputs and checked whether scores varied in the expected direction:

| Input | llm_score | stylometric_score | classification | confidence |
| --- | --- | --- | --- | --- |
| Clearly AI (formal, uniform) | 0.0 | 0.04 | ai_generated | 0.97 |
| Clearly human (casual, informal) | 0.9 | 0.58 | human_authored | 0.55 |
| Borderline formal human | 0.0 | 0.29 | ai_generated | 0.76 |
| Lightly edited AI | 0.8 | 0.44 | uncertain | 0.01 |

The scores vary meaningfully: 0.97 for a text both signals strongly agree is AI-generated vs. 0.55 for a text the LLM scores as human but the stylometric signal only weakly corroborates. The disagreement penalty is working - "lightly edited AI" produces near-zero confidence because the signals are on opposite sides and far apart.

**Two example submissions showing confidence variation:**

**High-confidence case** — text submitted: *"Artificial intelligence demonstrates unprecedented sophistication in contemporary computational environments. Technologists characterize implementations as transformative developments incorporating sophisticated algorithmic methodologies. Furthermore, collaborative partnerships between governmental organizations and private corporations necessitate comprehensive regulatory frameworks."*

```json
{
  "classification": "ai_generated",
  "confidence": 0.97,
  "llm_score": 0.0,
  "stylometric_score": 0.04
}
```

Both signals strongly agree. The LLM reads it as textbook AI output; the stylometric signal finds very long average word length and no expressive punctuation, producing a near-zero score.

**Lower-confidence case** — text submitted: *"ok so i finally tried that new ramen place downtown and honestly? underwhelming. the broth was fine but they put WAY too much sodium in it and i was thirsty for like three hours after."*

```json
{
  "classification": "human_authored",
  "confidence": 0.55,
  "llm_score": 0.9,
  "stylometric_score": 0.58
}
```

Both signals lean human, but neither strongly. The stylometric score of 0.58 is only slightly above the 0.5 midpoint — the text is short, the sentence variance is limited, and the punctuation density is low. The result is a correct classification with moderate confidence and the uncertain label.

---

## Transparency Labels

A confidence threshold of 0.80 is required to show a firm verdict. Below that threshold, all results show the uncertain label regardless of classification direction.

**High-confidence AI** (classification = `ai_generated`, confidence >= 0.80):

> "This content shows strong indicators of AI generation. Our system analyzed the writing style and structure across multiple signals and found patterns consistent with AI-produced text."

**High-confidence Human** (classification = `human_authored`, confidence >= 0.80):

> "This content shows strong indicators of human authorship. Our system analyzed the writing style and structure across multiple signals and found patterns consistent with human-produced text."

**Uncertain** (classification = `uncertain`, OR confidence < 0.80):

> "Our system was unable to confidently determine whether this content was written by a human or generated by AI. The signals we analyzed were either mixed or not strong enough to make a reliable attribution."

The label language uses "shows strong indicators of" rather than "was generated by" — the system describes what it observed, not what it knows to be true. This matters: the system can be wrong, and the label should not make accusations.

---

## Rate Limiting

Applied to `POST /submit` only. `/appeal` and `/log` are not rate-limited.

**Limits:** 10 requests per minute, 100 requests per day, per IP address.

**Reasoning:**

- A writer submitting their own work will rarely exceed a few submissions per session. 10 per minute is generous for human-paced use — it would take deliberate effort to hit.
- Every submission calls the Groq API, which adds latency and counts against the free-tier token budget. Unlimited submissions would bottleneck on the upstream API anyway.
- 100 per day accommodates a heavy user batch-submitting a full portfolio without enabling overnight automated flooding.
- The per-minute limit is the real abuse guard. A script in a tight loop hits the wall immediately; a person typing and submitting work never would.

**Evidence — rate limit in action** (12 rapid requests, limit is 10/min):

```text
200
200
200
200
200
200
200
200
200
200
429
429
```

Requests 1-10 succeed. Requests 11-12 return `429 Too Many Requests`.

---

## Audit Log

Every attribution decision is written to `audit_log.json` as a structured, newline-delimited JSON entry. Appeals are appended to the original entry in-place — the original decision is preserved and the appeal fields are added alongside it.

Each entry captures: `content_id`, `user_id`, `timestamp`, `attribution`, `confidence`, `llm_score`, `stylometric_score`, `status`, and (when filed) `appeal_reasoning` and `appeal_timestamp`.

**Three log entries from `GET /log`:**

```json
{
  "content_id": "cdcd2fe7-4aa5-4c5a-9849-9d27bde93830",
  "user_id": "demo-user-1",
  "timestamp": "2026-06-26T02:26:09.915746+00:00",
  "attribution": "ai_generated",
  "confidence": 0.97,
  "llm_score": 0.0,
  "stylometric_score": 0.04,
  "status": "classified"
}
```

```json
{
  "content_id": "3c154853-80f0-49b8-a6ca-57d8a5ff2967",
  "user_id": "demo-user-2",
  "timestamp": "2026-06-26T02:26:17.017954+00:00",
  "attribution": "human_authored",
  "confidence": 0.55,
  "llm_score": 0.9,
  "stylometric_score": 0.58,
  "status": "classified"
}
```

```json
{
  "content_id": "0ec50a68-b08f-42c1-a7fb-080caa8a3af7",
  "user_id": "demo-user-3",
  "timestamp": "2026-06-26T02:26:23.986448+00:00",
  "attribution": "ai_generated",
  "confidence": 0.76,
  "llm_score": 0.0,
  "stylometric_score": 0.29,
  "status": "under_review",
  "appeal_reasoning": "I am an economics PhD student and wrote this passage myself for a blog post. My academic training produces formal prose that may resemble AI output stylistically, but this is my original analysis.",
  "appeal_timestamp": "2026-06-26T02:26:32.154500+00:00"
}
```

The third entry shows the full appeal flow: `status` updated from `classified` to `under_review`, original classification preserved, appeal reasoning and timestamp appended.

---

## Known Limitations

**Formal human writing is systematically misclassified as AI.**

Professional or academic text tends to have long average word length, uniform sentence structure, and conventional punctuation - all of which the stylometric signal scores as AI-like. If the LLM signal also reads the polished, formal tone as "assistant-like," both signals agree and the confidence score is high. The system returns a confident wrong answer.

Limitation: The features both signals use to detect AI text are the same features that distinguish formal human writing from casual writing. The system cannot tell the difference between "AI-smooth" and "professionally polished."

The only recovery path is the appeals workflow, which means the user bears the burden of contesting a classification the system was confident about. This is a real harm to real people, and any production deployment would need to account for it, probably by narrowing the claim the label makes ("this text has structural properties associated with AI output" rather than "this appears to be AI-generated").

---

## Spec Reflection

**Where the spec helped:** Writing out the false positive problem before touching any code forced a decision I would have deferred: the label language. Naming the scenario made it clear that "appears to have been generated by AI" is a meaningfully different claim than "was generated by AI." That distinction ended up in the actual label text. Without the planning section, I would likely have written an accusatory label and not noticed the problem until much later.

**Where implementation diverged:** The planning doc specified type-token ratio (TTR) as one of the three stylometric sub-scores. During testing, I discovered that TTR is unreliable on short texts - on a 40-word passage, nearly every word is unique regardless of authorship, so both AI and human text score near 1.0 (human-like). The signal was adding noise rather than signal. I replaced TTR with average word length; AI text genuinely uses longer, more formal vocabulary than casual human writing, and this holds on short texts as well as long ones.

---

## AI Usage

**Instance 1: Generating the LLM signal function and improving the prompt.**

I asked the AI tool to generate a `classify_with_llm(text: str) -> float` function that sends text to Groq and returns a score between 0.0 and 1.0. The initial output worked but the underlying prompt was too generic - it just asked the model to rate the text without giving it criteria. When I tested it on clearly AI-generated text, the model returned 0.5 (uncertain) every time. I diagnosed this by printing the raw Groq response, confirming it was a genuine 0.5, not a parse error. I then rewrote the prompt myself to add specific distinguishing criteria (AI text has "uniform sentence length, filler phrases like 'it is important to note'"; human text has "personal asides, typos, informal phrasing") and added three concrete few-shot examples with expected scores. After that revision, the same model scored clearly AI text at 0.0 and clearly human text at 0.9.

**Instance 2: Generating the stylometric analyzer.**

I asked the AI tool to implement `compute_stylometric_score(text: str) -> float` using sentence length variance, type-token ratio, and punctuation density. The generated code was structurally correct. When I ran it against all four test inputs, I found that TTR was returning 1.0 (maximum human-like) for both AI and human text on short passages, completely drowning out the other two signals. I diagnosed this by printing the individual sub-scores and seeing that TTR = 0.88 for both the clearly AI text and the clearly human text. I replaced TTR with average word length, which led to significant improvement - AI text now scores 0.04 on the stylometric signal, human text scores 0.58.

---

## API Endpoints

### `POST /submit`

**Request body:**

```json
{
  "text": "string (required, min 50 characters)",
  "user_id": "string (required)"
}
```

**Response:**

```json
{
  "content_id": "uuid",
  "classification": "ai_generated | human_authored | uncertain",
  "confidence": 0.97,
  "label": "This content shows strong indicators of AI generation...",
  "signals": {
    "llm_score": 0.0,
    "stylometric_score": 0.04
  }
}
```

### `POST /appeal`

**Request body:**

```json
{
  "content_id": "uuid from /submit response",
  "user_reasoning": "string (required)"
}
```

**Response:**

```json
{
  "content_id": "uuid",
  "status": "under_review",
  "message": "Your appeal has been received and will be reviewed by our team."
}
```

### `GET /log`

Returns the most recent audit log entries as structured JSON.

---

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env
# Add your GROQ_API_KEY to .env
python app.py
```