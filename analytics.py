import audit_log

_CLASSIFICATIONS = ("ai_generated", "human_authored", "uncertain")


def get_summary() -> dict:
    entries = audit_log.get_entries(limit=0)
    total = len(entries)

    if total == 0:
        return {"total_submissions": 0}

    counts = {c: 0 for c in _CLASSIFICATIONS}
    conf_sums = {c: 0.0 for c in _CLASSIFICATIONS}
    appeal_counts = {c: 0 for c in _CLASSIFICATIONS}
    total_appeals = 0
    high_confidence_count = 0
    verified_human_count = 0

    for entry in entries:
        attribution = entry.get("attribution", "uncertain")
        confidence = entry.get("confidence", 0.0)
        status = entry.get("status", "classified")

        if attribution in counts:
            counts[attribution] += 1
            conf_sums[attribution] += confidence

        if confidence >= 0.80 and attribution in ("ai_generated", "human_authored"):
            high_confidence_count += 1

        if entry.get("appeal_reasoning"):
            total_appeals += 1
            if attribution in appeal_counts:
                appeal_counts[attribution] += 1

        if status == "verified_human":
            verified_human_count += 1

    detection_patterns = {
        c: {
            "count": counts[c],
            "pct": round(counts[c] / total * 100, 1),
            "avg_confidence": round(conf_sums[c] / counts[c], 2) if counts[c] else 0.0,
        }
        for c in _CLASSIFICATIONS
    }

    human_authored_count = counts["human_authored"]

    return {
        "total_submissions": total,
        "detection_patterns": detection_patterns,
        "high_confidence_rate": round(high_confidence_count / total, 2),
        "appeal_rate": {
            "total_appeals": total_appeals,
            "rate": round(total_appeals / total, 3),
            "by_classification": appeal_counts,
        },
        "certificate_conversion": {
            "human_authored_submissions": human_authored_count,
            "certificates_issued": verified_human_count,
            "conversion_rate": (
                round(verified_human_count / human_authored_count, 2)
                if human_authored_count else 0.0
            ),
        },
    }
