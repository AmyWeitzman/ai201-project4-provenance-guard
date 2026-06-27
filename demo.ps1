# Provenance Guard -- live demo script
# Start the server first: python app.py
# Then run: powershell -ExecutionPolicy Bypass -File demo.ps1

$BASE = "http://127.0.0.1:5000"

function Show-Step($label) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  $label" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    Read-Host "  [Enter to run]" | Out-Null
}

function Call($method, $path, $body) {
    if ($body) {
        $json = $body | ConvertTo-Json -Compress
        $resp = Invoke-WebRequest -Method $method -Uri "$BASE$path" `
            -ContentType "application/json" -Body $json -ErrorAction SilentlyContinue
    } else {
        $resp = Invoke-WebRequest -Method $method -Uri "$BASE$path" -ErrorAction SilentlyContinue
    }
    Write-Host "HTTP $($resp.StatusCode)" -ForegroundColor Yellow
    $resp.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5
}

# -- 1. HIGH-CONFIDENCE AI TEXT --------------------------------------------------
Show-Step "1 / 7  |  High-confidence AI submission"
# Expect: ai_generated, confidence ~0.97, all 3 signal scores, label text
Write-Host "POST /submit" -ForegroundColor Magenta
Write-Host "Submitting text:" -ForegroundColor Gray
Write-Host "  `"Artificial intelligence demonstrates unprecedented sophistication in contemporary computational environments. Technologists characterize implementations as transformative developments incorporating sophisticated algorithmic methodologies. Furthermore, collaborative partnerships between governmental organizations and private corporations necessitate comprehensive regulatory frameworks.`"" -ForegroundColor White
Write-Host ""
$r1 = Invoke-WebRequest -Method POST -Uri "$BASE/submit" `
    -ContentType "application/json" -Body (@{
    text = "Artificial intelligence demonstrates unprecedented sophistication in contemporary computational environments. Technologists characterize implementations as transformative developments incorporating sophisticated algorithmic methodologies. Furthermore, collaborative partnerships between governmental organizations and private corporations necessitate comprehensive regulatory frameworks."
    creator_id = "demo-alice"
} | ConvertTo-Json) -ErrorAction SilentlyContinue

Write-Host "HTTP $($r1.StatusCode)" -ForegroundColor Yellow
$r1.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5
$aiContentId = ($r1.Content | ConvertFrom-Json).content_id

# -- 2. LOW-CONFIDENCE HUMAN TEXT ------------------------------------------------
Show-Step "2 / 7  |  Lower-confidence human submission (contrast)"
# Expect: human_authored, confidence ~0.54, all 3 signals differ from above
Write-Host "POST /submit" -ForegroundColor Magenta
Write-Host "Submitting text:" -ForegroundColor Gray
Write-Host "  `"ok so i finally tried that new ramen place downtown and honestly? underwhelming. the broth was fine but they put WAY too much sodium in it and i was thirsty for like three hours after. wouldn't go back.`"" -ForegroundColor White
Write-Host ""
$r2 = Invoke-WebRequest -Method POST -Uri "$BASE/submit" `
    -ContentType "application/json" -Body (@{
    text = "ok so i finally tried that new ramen place downtown and honestly? underwhelming. the broth was fine but they put WAY too much sodium in it and i was thirsty for like three hours after. wouldn't go back."
    creator_id = "demo-bob"
} | ConvertTo-Json) -ErrorAction SilentlyContinue

Write-Host "HTTP $($r2.StatusCode)" -ForegroundColor Yellow
$r2.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5
$humanContentId = ($r2.Content | ConvertFrom-Json).content_id

# -- 3. CODE SUBMISSION ----------------------------------------------------------
Show-Step "3 / 7  |  Code submission -- different content type + signals"
# Expect: content_type=code, code-specific signal names
$codeText = "def avg(nums):\n    # TODO: handle empty\n    return sum(nums)/len(nums)\n\ndef process(data):\n    res = []\n    for x in data:\n        if x > 0:\n            res.append(avg([x, x*2]))\n    return res"
Write-Host "POST /submit  (content_type=code)" -ForegroundColor Magenta
Write-Host "Submitting code (content_type=code):" -ForegroundColor Gray
Write-Host "  def avg(nums):" -ForegroundColor White
Write-Host "      # TODO: handle empty" -ForegroundColor White
Write-Host "      return sum(nums)/len(nums)" -ForegroundColor White
Write-Host "" -ForegroundColor White
Write-Host "  def process(data):" -ForegroundColor White
Write-Host "      res = []" -ForegroundColor White
Write-Host "      for x in data:" -ForegroundColor White
Write-Host "          if x > 0:" -ForegroundColor White
Write-Host "              res.append(avg([x, x*2]))" -ForegroundColor White
Write-Host "      return res" -ForegroundColor White
Write-Host ""
$r3 = Invoke-WebRequest -Method POST -Uri "$BASE/submit" `
    -ContentType "application/json" -Body (@{
    text = $codeText
    creator_id = "demo-carol"
    content_type = "code"
} | ConvertTo-Json) -ErrorAction SilentlyContinue

Write-Host "HTTP $($r3.StatusCode)" -ForegroundColor Yellow
$r3.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5

# -- 4. APPEAL -------------------------------------------------------------------
Show-Step "4 / 7  |  Appeal -- creator contests the AI verdict"
# Uses the AI-flagged submission; expect status -> under_review
Write-Host "POST /appeal/{content_id}" -ForegroundColor Magenta
Write-Host "Creator reasoning:" -ForegroundColor Gray
Write-Host "  `"I am an economics researcher and wrote this passage for a policy brief. My academic training produces formal prose that may resemble AI output stylistically, but this is my original analysis and reflects my own views on regulatory frameworks.`"" -ForegroundColor White
Write-Host ""
$r4 = Invoke-WebRequest -Method POST -Uri "$BASE/appeal/$aiContentId" `
    -ContentType "application/json" -Body (@{
    creator_id = "demo-alice"
    reasoning = "I am an economics researcher and wrote this passage for a policy brief. My academic training produces formal prose that may resemble AI output stylistically, but this is my original analysis and reflects my own views on regulatory frameworks."
} | ConvertTo-Json) -ErrorAction SilentlyContinue

Write-Host "HTTP $($r4.StatusCode)" -ForegroundColor Yellow
$r4.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5

# -- 5a. AUDIT LOG ---------------------------------------------------------------
Show-Step "5a / 7  |  Audit log -- 3 entries, appeal visible"
# Expect: 3 entries each with timestamp, attribution, confidence
# Entry 1 has status=under_review and appeal_reasoning
Write-Host "GET /log" -ForegroundColor Magenta
Call GET "/log"

# -- 5b. RATE LIMITING -----------------------------------------------------------
Show-Step "5b / 7  |  Rate limiting -- rapid fire until 429"
Write-Host "POST /submit  (x12 rapid fire)" -ForegroundColor Magenta
Write-Host "Sending 12 requests fast (limit is 10/min total across session)...`n" -ForegroundColor Gray
$shortText = "This is a test submission with enough characters to pass the minimum length requirement for the API."
for ($i = 1; $i -le 12; $i++) {
    $body = @{ text = $shortText; creator_id = "demo-spammer" } | ConvertTo-Json -Compress
    try {
        $r = Invoke-WebRequest -Method POST -Uri "$BASE/submit" `
            -ContentType "application/json" -Body $body -ErrorAction Stop
        $statusCode = [int]$r.StatusCode
    } catch {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    $color = if ($statusCode -eq 429) { "Red" } else { "Green" }
    Write-Host "  Request $i  ->  HTTP $statusCode" -ForegroundColor $color
}

# -- 6. PROVENANCE CERTIFICATE ---------------------------------------------------
Show-Step "6 / 7  |  Provenance certificate -- verified_human label"
# Requires humanContentId to be human_authored (ramen text should qualify)
Write-Host "POST /certify" -ForegroundColor Magenta
$r6 = Invoke-WebRequest -Method POST -Uri "$BASE/certify" `
    -ContentType "application/json" -Body (@{
    content_id  = $humanContentId
    creator_id  = "demo-bob"
    process_statement = "I wrote this after a genuinely disappointing dinner out. I specifically went because a friend recommended it, and I was let down by how salty everything was. I wrote the note the same evening while still thinking about it. The all-lowercase style and casual punctuation is how I actually text and write personal notes, not something I stylized intentionally."
} | ConvertTo-Json) -ErrorAction SilentlyContinue

Write-Host "HTTP $($r6.StatusCode)" -ForegroundColor Yellow
$r6.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5

# -- 7. ANALYTICS ----------------------------------------------------------------
Show-Step "7 / 7  |  Analytics dashboard -- detection patterns + appeal rate + certificate conversion"
Write-Host "GET /analytics" -ForegroundColor Magenta
$analyticsResp = Invoke-WebRequest -Method GET -Uri "$BASE/analytics" -ErrorAction SilentlyContinue
Write-Host "HTTP $($analyticsResp.StatusCode)" -ForegroundColor Yellow
$a = $analyticsResp.Content | ConvertFrom-Json

Write-Host ""
Write-Host "  Total submissions: $($a.total_submissions)" -ForegroundColor White
Write-Host "  High-confidence rate: $($a.high_confidence_rate * 100)%" -ForegroundColor White

Write-Host ""
Write-Host "  DETECTION PATTERNS" -ForegroundColor Cyan
Write-Host "  ------------------" -ForegroundColor Cyan
Write-Host ("  {0,-22} {1,6} {2,8} {3,16}" -f "Classification", "Count", "Pct", "Avg Confidence") -ForegroundColor Cyan
Write-Host ("  {0,-22} {1,6} {2,8} {3,16}" -f "---------------------", "-----", "-------", "---------------") -ForegroundColor DarkGray
foreach ($key in @("ai_generated", "human_authored", "uncertain")) {
    $p = $a.detection_patterns.$key
    Write-Host ("  {0,-22} {1,6} {2,7}% {3,16}" -f $key, $p.count, $p.pct, $p.avg_confidence) -ForegroundColor White
}

Write-Host ""
Write-Host "  APPEAL RATE" -ForegroundColor Cyan
Write-Host "  -----------" -ForegroundColor Cyan
Write-Host ("  {0,-30} {1}" -f "Total appeals", $a.appeal_rate.total_appeals) -ForegroundColor White
Write-Host ("  {0,-30} {1}" -f "Appeal rate", "$($a.appeal_rate.rate * 100)%") -ForegroundColor White
Write-Host ("  {0,-30} {1}" -f "Appeals on ai_generated", $a.appeal_rate.by_classification.ai_generated) -ForegroundColor White
Write-Host ("  {0,-30} {1}" -f "Appeals on human_authored", $a.appeal_rate.by_classification.human_authored) -ForegroundColor White

Write-Host ""
Write-Host "  CERTIFICATE CONVERSION" -ForegroundColor Cyan
Write-Host "  ----------------------" -ForegroundColor Cyan
Write-Host ("  {0,-30} {1}" -f "Human-authored submissions", $a.certificate_conversion.human_authored_submissions) -ForegroundColor White
Write-Host ("  {0,-30} {1}" -f "Certificates issued", $a.certificate_conversion.certificates_issued) -ForegroundColor White
Write-Host ("  {0,-30} {1}" -f "Conversion rate", "$($a.certificate_conversion.conversion_rate * 100)%") -ForegroundColor White
Write-Host ""

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Demo complete." -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
