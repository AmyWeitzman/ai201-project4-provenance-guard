# Provenance Guard — API Contract

This defines the three endpoints and their contracts (what each one accepts, what it returns, and what can go wrong)

---

## POST /submissions

Submit a piece of text for attribution analysis.

**Accepts (request body, JSON):**

```
{
  "text": string (required) - the content to classify; must be at least 50 characters
}
```

**Returns (200, JSON):**

```
{
  "content_id":     string  — system-assigned identifier for this submission; use it to appeal later
  "classification": string  — one of: "ai_generated", "human_authored", "uncertain"
  "confidence":     float   — 0.0 to 1.0; reflects signal agreement, not ground truth certainty
  "label":          string  — the exact transparency label text to show readers
  "signals": {
    "llm_score":          float  — Groq classifier score (0.0 = AI, 1.0 = human)
    "stylometric_score":  float  — heuristic score (0.0 = AI, 1.0 = human)
  }
}
```

**Error responses:**

| Status | When |
| --- | --- |
| 422 | text is missing, empty, or under 50 characters |
| 429 | rate limit exceeded for this IP |
| 503 | Groq is unreachable (stylometric score still returned; classification marked uncertain) |

**Rate limit:** 10 requests per minute per IP. Exceeding this returns 429 immediately, before any analysis runs.

---

## POST /appeals/{content_id}

Contest a classification. The creator provides their reasoning; the system logs it and marks the submission under review. No automatic re-classification occurs.

**Path parameter:**

```
content_id — the ID returned from POST /submissions
```

**Accepts (request body, JSON):**

```
{
  "reasoning": string (required) — the creator's explanation of why the classification is wrong
}
```

**Returns (200, JSON):**

```
{
  "content_id": string — same ID as the path parameter
  "status":     string — will be "under_review"
  "message":    string — human-readable confirmation that the appeal was received
}
```

**Error responses:**

| Status | When |
| --- | --- |
| 404 | content_id not found in the audit log |
| 409 | an appeal already exists for this content_id (can't appeal twice) |
| 422 | reasoning is missing or empty |

---

## GET /log

Retrieve audit log entries. Returns every attribution decision, including signal scores, the label shown, current status, and any appeal that was filed.

**Accepts (query parameters, all optional):**

```
limit  — integer; max number of entries to return (default: 20)
```

**Returns (200, JSON):**

```
{
  "entries": [
    {
      "content_id":       string
      "timestamp":        string  — ISO 8601
      "classification":   string  — "ai_generated", "human_authored", or "uncertain"
      "confidence":       float
      "signals": {
        "llm_score":         float
        "stylometric_score": float
      }
      "label_shown":      string  — the exact label text that was returned to the caller
      "status":           string  — "decided" or "under_review"
      "appeal": {                 — null if no appeal has been filed
        "reasoning":  string
        "filed_at":   string  — ISO 8601
      }
    }
  ]
}
```

**Error responses:**

| Status | When |
| --- | --- |
| 422 | limit is not a positive integer |

---

## Notes on the contract

**content_id** is the thread connecting all three endpoints. A user submits text, gets back a content_id, and uses that same ID to appeal or look up the log entry. Every audit log entry is keyed by it.

**confidence reflects signal agreement, not accuracy.** A 0.90 means both signals strongly agreed — it does not mean the system is 90% likely to be correct. This distinction matters for how the label text is written and how the score is documented.

**The 503 case** (Groq unreachable): does the system fail the whole request, or return a partial result based on the stylometric score alone and mark the classification uncertain? Going with the latter, a degraded response is better than no response for audit and appeals purposes.
