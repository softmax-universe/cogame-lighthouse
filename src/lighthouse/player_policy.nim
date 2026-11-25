## Lighthouse model and prompt policy. Only player processes import
## this module; the game owns rules, visibility, resolution, and replay.

import
  std/[json, os, strutils],
  bitworld/runtime,
  curly,
  sim,
  rules, prompts
export prompts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  TranscriptLen = 5
  MoveHistoryLen = 6
  StandingMaxAge = 3

type
  LlmTransport = enum
    ltSidecar, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    sidecarEndpoint: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int


proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "lighthouse llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc newLlmClient*(model: string, maxOutputTokens, timeoutSeconds: int): LlmClient =
  result = LlmClient(
    model: model,
    maxOutputTokens: maxOutputTokens,
    timeoutSeconds: timeoutSeconds
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    let envModel = getEnv("COWORLD_LLM_MODEL").strip()
    result.model =
      if envModel.len > 0: envModel
      else: "anthropic/claude-haiku-4.5"
    result.curl = newCurly()
    echo "lighthouse llm: sidecar transport ", result.sidecarEndpoint,
      ", model ", result.model
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "lighthouse llm: anthropic transport, model ", result.model
  else:
    raise newException(LighthouseError,
      "no LLM credentials configured (set COWORLD_LLM_ENDPOINT or ANTHROPIC_API_KEY)")

# ---- Prompt building --------------------------------------------------------

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc floodCountdown(sim: Sim): tuple[silent, talking: int] =
  let rows = sim.tideRows()
  if rows >= sim.config.height:
    return (0, 0)
  let next = sim.config.tideDelay + (rows + 1) * sim.config.tidePeriod
  let need = max(next - sim.clock, 0)
  (need, (need + 1) div 2)

proc keeperPrompt*(sim: Sim, prompt: string): string =
  result.add("Tick " & $sim.tick & " of " & $sim.config.maxTicks &
    ". You are the KEEPER.\n\n")
  result.add("THE MAZE (# wall, . floor, ~ water, K key, E exit with the " &
    "gate shut, O exit with the gate open, 1/2/3 a runner):\n" &
    sim.keeperView() & "\n\n")
  result.add("YOUR RUNNERS:\n")
  for index in 0 ..< Runners:
    let seat = index + 1
    var line = $seat & ". " & sim.names[seat] & " — "
    case sim.status[index]
    of rsActive:
      line.add("at (" & $sim.pos[index].x & ", " & $sim.pos[index].y &
        "), carrying " & $sim.keysHeld[index] & " key" &
        (if sim.keysHeld[index] == 1: "" else: "s") & ", last move " &
        $sim.lastMove[index] &
        (if sim.blocked[index]: " (BUMPED a wall or the water)" else: ""))
    of rsEscaped:
      line.add("OUT of the maze, safe.")
    of rsDrowned:
      line.add("taken by the tide.")
    result.add(line & "\n")
  let countdown = sim.floodCountdown()
  result.add("\nTHE TIDE: " & $sim.tideRows() & " row" &
    (if sim.tideRows() == 1: "" else: "s") & " flooded; the water line is " &
    "at y=" & $sim.waterLine() & " (every tile with y >= " &
    $sim.waterLine() & " is under water). The clock is " & $sim.clock &
    " of " & $sim.floodClock() & ".\n")
  if sim.tideRows() >= sim.config.height:
    result.add("The whole board is under water.\n")
  else:
    result.add("The next row floods in " & $countdown.silent &
      " tick(s) if you stay silent, in " & $countdown.talking &
      " tick(s) if you transmit every tick.\n")
  result.add("\nKEYS: " & $sim.keysCollected & " of " &
    $sim.config.keyCount & " collected; the gate is " &
    (if sim.gateOpen: "OPEN" else: "shut") & ".\n\n")
  result.add("YOUR NOTES:\n" &
    (if sim.notes[KeeperSeat].len > 0: sim.notes[KeeperSeat]
     else: "(none)") & "\n\n")
  var transcript: seq[string]
  let first = max(0, sim.messages.len - TranscriptLen)
  for index in first ..< sim.messages.len:
    transcript.add("tick " & $sim.messages[index][0] & ": \"" &
      sim.messages[index][1] & "\"")
  result.add("YOUR LAST TRANSMISSIONS:\n" &
    (if transcript.len > 0: transcript.join("\n")
     else: "(you have not spoken yet)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with one JSON object: " &
    "{\"transmit\":true,\"message\":\"...\"} (at most " & $MaxMessageLen &
    " characters, delivered next tick) or {\"transmit\":false}.")

proc runnerPromptFromView(view: JsonNode, prompt: string): string =
  result.add("Tick " & $view["tick"].getInt() & " of " &
    $view["maxTicks"].getInt() & ". You are a RUNNER and you are blind.\n\n")
  result.add("YOUR 3x3 WINDOW (you are @ in the middle; # wall, . floor, " &
    "~ water, K key, E exit with the gate shut, O exit with the gate " &
    "open, 1/2/3 another runner):\n")
  for line in view["window"]:
    result.add(line.getStr() & "\n")
  let held = view["keysHeld"].getInt()
  result.add("\nYOU HOLD " & $held & " key" &
    (if held == 1: "" else: "s") & ". The team has " &
    $view["keysCollected"].getInt() & " of " & $view["keyCount"].getInt() &
    " keys; the gate is " &
    (if view["gateOpen"].getBool(): "OPEN — get to the exit" else: "shut") &
    ".\n\n")
  let inbox = view["inbox"].getStr()
  result.add("THE KEEPER SAID THIS TICK: " &
    (if inbox.len > 0: "\"" & inbox & "\"" else: "(silence)") & "\n")
  let standing = view["standing"].getStr()
  let age = view["standingAge"].getInt()
  if standing.len > 0 and age >= 0:
    result.add("YOUR STANDING ORDER (" & $age & " tick(s) old): \"" &
      standing & "\"\n")
  else:
    result.add("YOUR STANDING ORDER: (none yet)\n")
  var history: seq[string]
  let moveHistory = view["moveHistory"]
  let first = max(0, moveHistory.len - MoveHistoryLen)
  for index in first ..< moveHistory.len:
    history.add(moveHistory[index].getStr())
  result.add("\nYOUR LAST MOVES: " &
    (if history.len > 0: history.join(", ") else: "(none yet)") & "\n\n")
  let notes = view["notes"].getStr()
  result.add("YOUR NOTES:\n" &
    (if notes.len > 0: notes else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Choose N, S, E, W, or WAIT (N is up, S is down). " &
    "Reply with one JSON object: {\"move\":\"N\"}.")

proc keeperSimFromView(view: JsonNode): Sim =
  ## Rebuild only the keeper-visible rule state used by the prompt and
  ## lantern policy. No other player's private notes enter this object.
  result.config.maxTicks = view["maxTicks"].getInt()
  result.config.keyCount = view["keyCount"].getInt()
  result.config.tideDelay = view["tideDelay"].getInt()
  result.config.tidePeriod = view["tidePeriod"].getInt()
  for row in view["maze"]:
    result.grid.add(row.getStr())
  result.config.height = result.grid.len
  result.config.width = result.grid[0].len
  result.exitAt = (view["exit"][0].getInt(), view["exit"][1].getInt())
  for tile in view["keysOnFloor"]:
    result.keysOnFloor.add((tile[0].getInt(), tile[1].getInt()))
  result.names.add(view["alias"].getStr())
  for index in 0 ..< view["runners"].len:
    let runner = view["runners"][index]
    result.names.add(runner["alias"].getStr())
    result.status[index] = parseEnum[RunnerStatus](runner["status"].getStr())
    result.pos[index] = (
      runner["position"][0].getInt(), runner["position"][1].getInt())
    result.keysHeld[index] = runner["keysHeld"].getInt()
    result.lastMove[index] = parseMoveToken(runner["lastMove"].getStr())
    result.blocked[index] = runner["blocked"].getBool()
  result.keysCollected = view["keysCollected"].getInt()
  result.gateOpen = view["gateOpen"].getBool()
  result.tick = view["tick"].getInt()
  result.clock = view["clock"].getInt()
  result.notes[KeeperSeat] = view["notes"].getStr()
  for entry in view["messages"]:
    result.messages.add((entry["tick"].getInt(), entry["text"].getStr()))
  if view["lastMessageClock"].getInt() >= 0:
    result.events.add(GameEvent(kind: evTick,
      tick: result.messages[^1][0],
      clock: view["lastMessageClock"].getInt()))
  if view["keyJustCollected"].getBool():
    result.events.add(GameEvent(kind: evKey,
      tick: result.tick - 1, keysCollected: result.config.keyCount))

proc scriptedActionFromView*(view: JsonNode): Decision =
  ## A bundled scripted player computes its own action from the ordinary
  ## private observation; the game uses its full Sim only for a timeout.
  if view["role"].getStr() == "keeper":
    return lanternAction(keeperSimFromView(view))
  result.scripted = true
  result.move = mvWait
  let window: array[3, string] = [
    view["window"][0].getStr(), view["window"][1].getStr(),
    view["window"][2].getStr()]
  let alias = view["alias"].getStr()
  var order = orderedDirection(view["inbox"].getStr(), alias)
  if not order.found and view["standingAge"].getInt() in 0 .. StandingMaxAge:
    order = orderedDirection(view["standing"].getStr(), alias)
  if order.found:
    if order.move == mvWait:
      return
    if passable(window, order.move):
      result.move = order.move
      return
    for candidate in [turnRight(order.move), turnLeft(order.move),
        turnBack(order.move)]:
      if passable(window, candidate):
        result.move = candidate
        return
    return
  var heading = mvNorth
  for index in countdown(view["moveHistory"].len - 1, 0):
    let token = view["moveHistory"][index].getStr().split(' ')[0]
    if token != $mvWait:
      heading = parseMoveToken(token)
      break
  for candidate in [turnLeft(heading), heading, turnRight(heading),
      turnBack(heading)]:
    if passable(window, candidate):
      result.move = candidate
      return

proc promptsFromView*(selection: PromptSelection, view: JsonNode, prompt: string):
    tuple[system, user: string] =
  let keeper = view["role"].getStr() == "keeper"
  result.system = selection.renderPrompt(view["alias"].getStr(), keeper)
  if keeper:
    result.user = keeperPrompt(keeperSimFromView(view), prompt)
  else:
    result.user = runnerPromptFromView(view, prompt)

# ---- Sidecar / Anthropic transport ------------------------------------------

proc rawReplyPreview(text: string): string =
  let flat = text.replace("\r\n", "\n").replace("\n", " ").strip()
  if flat.len <= 800:
    return cleanText(flat, 800)
  let head = cleanText(flat, 380)
  let tailStart = max(0, flat.len - 380)
  let tail = cleanText(flat[tailStart .. ^1], 380)
  head & " ... " & tail

proc tryParseJsonObj(candidate: string): tuple[ok: bool, node: JsonNode] =
  let s = candidate.strip()
  if not s.startsWith("{") or not s.endsWith("}"):
    return (false, nil)
  try:
    let parsed = parseJson(s)
    if parsed.kind == JObject:
      return (true, parsed)
  except CatchableError:
    discard
  (false, nil)

proc containsJsonObject(text: string): bool =
  ## Detects whether plain text contains any complete JSON object {...}
  ## so competing answers are rejected as ambiguous.
  var i = 0
  while i < text.len:
    if text[i] == '{':
      var depth = 0
      var inStr = false
      var escaped = false
      var j = i
      while j < text.len:
        let ch = text[j]
        if inStr:
          if escaped:
            escaped = false
          elif ch == '\\':
            escaped = true
          elif ch == '"':
            inStr = false
        else:
          if ch == '"':
            inStr = true
          elif ch == '{':
            inc depth
          elif ch == '}':
            dec depth
            if depth == 0:
              if tryParseJsonObj(text[i .. j]).ok:
                return true
              break
        inc j
    inc i
  false

proc parseJsonObject*(text: string): JsonNode =
  ## Parses a native JSON object reply:
  ## 1. Bare JSON object directly.
  ## 2. A uniquely marked complete Markdown JSON block (```json ... ``` or
  ##    a single unmarked ``` ... ``` block containing a JSON object), even
  ##    with prose or non-JSON fences (e.g. a 3x3 window diagram) around it.
  ## 3. An unambiguous explicit final native JSON object on its own line(s)
  ##    at the end of the reply.
  ## Rejects multiple competing answers, incomplete JSON, unclosed fences,
  ## non-JSON language fences, and prose without a real decision.
  let trimmed = text.strip()
  if trimmed.len == 0:
    raise newException(LighthouseError, "invalid JSON response (empty reply)")

  if trimmed.startsWith("{") and trimmed.endsWith("}"):
    let bare = tryParseJsonObj(trimmed)
    if bare.ok:
      return bare.node

  type FencedBlock = object
    lang: string
    body: string

  var blocks: seq[FencedBlock] = @[]
  var outside = ""
  var pos = 0
  var lastCloseEnd = 0
  while true:
    let openIdx = trimmed.find("```", pos)
    if openIdx < 0:
      outside.add(trimmed[pos .. ^1])
      break
    outside.add(trimmed[pos ..< openIdx])
    outside.add("\n")
    let closeIdx = trimmed.find("```", openIdx + 3)
    if closeIdx < 0:
      raise newException(LighthouseError,
        "incomplete markdown code fence: " & rawReplyPreview(trimmed))
    let rawBlock = trimmed[openIdx + 3 ..< closeIdx]
    let nl = rawBlock.find('\n')
    var lang = ""
    var body = ""
    if nl >= 0:
      let header = rawBlock[0 ..< nl].strip()
      let headerLower = header.toLowerAscii()
      if header.len == 0:
        lang = ""
        body = rawBlock[nl + 1 .. ^1].strip()
      elif headerLower == "json":
        lang = "json"
        body = rawBlock[nl + 1 .. ^1].strip()
      elif header.startsWith("{"):
        lang = ""
        body = rawBlock.strip()
      elif headerLower.len >= 4 and headerLower[0 ..< 4] == "json" and
          (headerLower.len == 4 or headerLower[4] in {' ', '\t'}):
        lang = "json"
        body = rawBlock.strip()[4 .. ^1].strip()
      else:
        lang = headerLower
        body = rawBlock[nl + 1 .. ^1].strip()
    else:
      let single = rawBlock.strip()
      let singleLower = single.toLowerAscii()
      if single.startsWith("{"):
        lang = ""
        body = single
      elif singleLower.len >= 4 and singleLower[0 ..< 4] == "json" and
          (singleLower.len == 4 or singleLower[4] in {' ', '\t'}):
        lang = "json"
        body = single[4 .. ^1].strip()
      else:
        lang = singleLower
        body = ""
    blocks.add(FencedBlock(lang: lang, body: body))
    pos = closeIdx + 3
    lastCloseEnd = pos

  var jsonTagged: seq[FencedBlock] = @[]
  var unmarkedJson: seq[JsonNode] = @[]
  for blk in blocks:
    if blk.lang == "json":
      jsonTagged.add(blk)
    elif blk.lang == "":
      let parsed = tryParseJsonObj(blk.body)
      if parsed.ok:
        unmarkedJson.add(parsed.node)

  if jsonTagged.len > 1 or (jsonTagged.len == 1 and unmarkedJson.len > 0) or
      unmarkedJson.len > 1:
    raise newException(LighthouseError,
      "multiple competing JSON blocks: " & rawReplyPreview(trimmed))

  if jsonTagged.len == 1:
    if containsJsonObject(outside):
      raise newException(LighthouseError,
        "multiple competing JSON objects: " & rawReplyPreview(trimmed))
    try:
      result = parseJson(jsonTagged[0].body)
    except CatchableError as error:
      raise newException(LighthouseError,
        "invalid JSON in markdown json block (" & error.msg & "): " &
        rawReplyPreview(trimmed))
    if result.kind != JObject:
      raise newException(LighthouseError, "response must be a JSON object")
    return result

  if unmarkedJson.len == 1:
    if containsJsonObject(outside):
      raise newException(LighthouseError,
        "multiple competing JSON objects: " & rawReplyPreview(trimmed))
    return unmarkedJson[0]

  # Explicit final native JSON object on its own line(s) at the end of the reply.
  let tailRaw = trimmed[lastCloseEnd .. ^1]
  let tail = tailRaw.strip()
  if tail.endsWith("}"):
    var lineStart = 0
    while lineStart < tail.len:
      var trimmedStart = lineStart
      while trimmedStart < tail.len and tail[trimmedStart] in {' ', '\t'}:
        inc trimmedStart
      if trimmedStart < tail.len and tail[trimmedStart] == '{':
        let parsed = tryParseJsonObj(tail[trimmedStart .. ^1])
        if parsed.ok:
          let beforeFinal = outside[0 ..< max(0, outside.len - tailRaw.len)] &
            tail[0 ..< trimmedStart]
          if containsJsonObject(beforeFinal):
            raise newException(LighthouseError,
              "multiple competing JSON objects: " & rawReplyPreview(trimmed))
          return parsed.node
      let nextNl = tail.find('\n', lineStart)
      if nextNl < 0:
        break
      lineStart = nextNl + 1

  try:
    result = parseJson(trimmed)
  except CatchableError as error:
    raise newException(LighthouseError,
      "invalid JSON response (" & error.msg & "): " & rawReplyPreview(trimmed))
  if result.kind != JObject:
    raise newException(LighthouseError, "response must be a JSON object")

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "model": client.model,
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  headers["anthropic-version"] = AnthropicVersion
  if client.transport == ltSidecar:
    if slot >= 0:
      headers["X-Coworld-Player-Slot"] = $slot
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    headers["x-api-key"] = client.apiKey
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one reply, or a LighthouseError describing why there is none.
  if error.len > 0:
    raise newException(LighthouseError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    raise newException(LighthouseError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    raise newException(LighthouseError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LighthouseError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LighthouseError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens":
    try:
      discard parseJsonObject(result)
    except LighthouseError:
      raise newException(LighthouseError, "incomplete model decision at output token limit")

# ---- Decisions --------------------------------------------------------------

proc choosePromptAction*(client: LlmClient, selection: PromptSelection, view: JsonNode,
    prompt: string, seat: int): Decision =
  let prompts = promptsFromView(selection, view, prompt)
  var batch: RequestBatch
  let request = client.requestFor(prompts.system, prompts.user, seat)
  batch.post(request.url, request.headers, request.body, $seat)
  let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
  let answer = client.textOf(responses[0].response,
    responses[0].error, request.url)
  parseReply(seat, parseJsonObject(answer))
