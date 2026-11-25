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
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
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
  result.add("Reply with ONLY {\"transmit\": true, \"message\": \"…\", " &
    "\"notes\": \"…\"} — message at most " & $MaxMessageLen &
    " characters and reaching the runners next tick (transmit false for " &
    "silence, which costs the tide one unit instead of two); notes at " &
    "most " & $MaxKeeperNotes & " characters.")

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
  result.add("Reply with ONLY {\"move\": \"N\", \"notes\": \"…\"} — move " &
    "is one of N, S, E, W, WAIT (N is up, S is down); notes at most " &
    $MaxRunnerNotes & " characters.")

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

proc parseJsonObject*(text: string): JsonNode =
  ## Parses a strict JSON object reply without scraping prose or markdown fences.
  let trimmed = text.strip()
  try:
    result = parseJson(trimmed)
  except CatchableError as error:
    let head = cleanText(trimmed, 160).replace("\n", " ")
    raise newException(LighthouseError,
      "invalid JSON response (" & error.msg & "): " & head)
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
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LighthouseError, "reply cut off at max_tokens " &
      "before any JSON: " & cleanText(result, 160).replace("\n", " "))

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
