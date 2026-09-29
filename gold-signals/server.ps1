# Local server for Gold 1m Signals: serves index.html and forwards AI recommendation
# requests to NVIDIA's API, so the API key never reaches the browser.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$port = 8787
$utf8 = New-Object Text.UTF8Encoding $false

$envFile = Join-Path $root '.env'
if (Test-Path $envFile) {
  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*)$' -and -not [Environment]::GetEnvironmentVariable($matches[1])) {
      [Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim().Trim('"', "'"))
    }
  }
}
# NVIDIA is used when its key is set, otherwise OpenRouter (both speak the OpenAI chat API).
if ($env:NVIDIA_API_KEY) {
  $provider = 'NVIDIA'; $apiKey = $env:NVIDIA_API_KEY; $apiUrl = 'https://integrate.api.nvidia.com/v1/chat/completions'
  $model = if ($env:NVIDIA_MODEL) { $env:NVIDIA_MODEL } else { 'deepseek-ai/deepseek-v4.1-flash' }
} else {
  $provider = 'OpenRouter'; $apiKey = $env:OPENROUTER_API_KEY; $apiUrl = 'https://openrouter.ai/api/v1/chat/completions'
  $model = if ($env:OPENROUTER_MODEL) { $env:OPENROUTER_MODEL } else { 'deepseek/deepseek-v4.1-flash' }
}

$system = @'
You are a specialised intraday chart analyst for gold (XAU/USD) on the 1-minute timeframe.
You receive a JSON snapshot: recent closed candles (UTC), EMA/RSI/ATR readings, 60-minute high/low,
the app's rule-based signal and its backtest statistics.

This is 1-minute SCALPING. Give ONE recommendation for a trade entered now, at the open of the
next 1-minute candle, and closed within 1-15 minutes. Rules:
- Base everything only on the data given. Never invent prices or news.
- Read the last 5-15 candles most closely (momentum, wicks, micro swing highs/lows); use the
  EMA200, 60m high/low and 4h ATR average only as context.
- entry = last_price. Stop 1.0-2.0 x ATR from entry, behind the nearest micro swing.
  Target 1.5-3.0 x ATR, before the next obvious level. Reward:risk at least 1.5.
- BUY: stop_loss below entry, take_profit above. SELL: the opposite.
- If candles are choppy, momentum conflicts with trend, or ATR is far below its average, answer WAIT with null levels.
- valid_for_minutes (1-3) is how long the entry stays valid before the setup must be re-read.
- confidence is 0-100 and should rarely exceed 75 on a 1-minute chart.

Reply with ONLY this JSON object, no markdown:
{"action":"BUY|SELL|WAIT","confidence":0,"entry":0,"stop_loss":0,"take_profit":0,
 "holding_minutes":0,"valid_for_minutes":1,"summary":"one sentence","reasons":["..."],"risks":["..."],
 "invalidation":"what price action would cancel this idea"}
'@

function Send($ctx, [int]$code, [string]$type, [byte[]]$bytes) {
  $r = $ctx.Response
  $r.StatusCode = $code; $r.ContentType = $type; $r.ContentLength64 = $bytes.Length
  $r.OutputStream.Write($bytes, 0, $bytes.Length); $r.Close()
}
function SendError($ctx, [int]$code, [string]$msg) {
  Send $ctx $code 'application/json' ($utf8.GetBytes((@{ error = $msg } | ConvertTo-Json -Compress)))
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "Gold 1m Signals: http://localhost:$port/   (close this window to stop)"
Write-Host "AI: $provider / $model"
if (-not $apiKey) { Write-Host 'No API key: add OPENROUTER_API_KEY or NVIDIA_API_KEY to gold-signals\.env, then restart.' -ForegroundColor Yellow }

try {
  while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(500)) {}  # lets Ctrl+C stop the loop
    $ctx = $task.GetAwaiter().GetResult()
    try {
      $path = $ctx.Request.Url.AbsolutePath
      if ($ctx.Request.HttpMethod -eq 'POST' -and $path -eq '/api/recommend') {
        if (-not $apiKey) { SendError $ctx 500 'No API key. Add OPENROUTER_API_KEY or NVIDIA_API_KEY to gold-signals\.env and restart start.bat.'; continue }
        $snapshot = (New-Object IO.StreamReader($ctx.Request.InputStream, $utf8)).ReadToEnd()
        $req = @{
          model = $model; temperature = 0.3; top_p = 0.95; max_tokens = 12000; stream = $false
          messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $snapshot })
        }
        # Short reasoning keeps answers fast enough for a 1-minute chart.
        if ($provider -eq 'OpenRouter') { $req.reasoning = @{ effort = 'low' } }
        $body = $req | ConvertTo-Json -Depth 5 -Compress
        $resp = Invoke-WebRequest -UseBasicParsing -Method Post -TimeoutSec 120 `
          -Uri $apiUrl -Headers @{ Authorization = "Bearer $apiKey"; 'X-Title' = 'Gold 1m Signals' } `
          -ContentType 'application/json' -Body $utf8.GetBytes($body)
        Send $ctx 200 'application/json' $resp.RawContentStream.ToArray()
      }
      elseif ($path -eq '/' -or $path -eq '/index.html') {
        Send $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $root 'index.html')))
      }
      else { SendError $ctx 404 'Not found' }
    }
    catch {
      $msg = $_.Exception.Message
      if ($_.Exception.Response) { try { $msg = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {} }
      Write-Host "Request failed: $msg" -ForegroundColor Red
      try { SendError $ctx 502 $msg } catch {}
    }
  }
}
finally { $listener.Stop() }
