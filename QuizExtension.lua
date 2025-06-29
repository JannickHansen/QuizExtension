-- extensions/QuizExtension.lua

-- 1) Load the Tracker’s built-in JSON parser
local json = dofile("ironmon_tracker/Json.lua")

-- Pokémon names lookup
local PokemonNames = {}
if PokemonData and PokemonData.Pokemon then
  for idx, entry in ipairs(PokemonData.Pokemon) do
    PokemonNames[idx] = entry.name
  end
end

local function QuizExtension()
  --------------------------------
  -- 1) Metadata
  --------------------------------
  local self = {}
  self.version        = "1.0"
  self.name           = "Quiz Extension"
  self.author         = "Poc"
  self.description    = "Displays a multiple-choice quiz after a run ends."
  self.github         = "YourUsername/QuizExtension"
  self.url            = string.format("https://github.com/%s", self.github)

  --------------------------------
  -- 2) State
  --------------------------------
  local templates      = {}
  self.Buttons         = {}
  self.currentT        = nil
  self.options         = {}
  self.correctIndex    = nil
  self.correctCount    = 0
  self.totalQuestions  = 1
  self.answered        = false
  self.countdownStart  = nil  -- time when countdown began

  --------------------------------
  -- 3) Startup
  --------------------------------
  function self.startup()
    print("[QuizExtension] startup, Tracker=", Tracker)

    -- load questions.json
    local f, err = io.open("extensions/questions.json", "r")
    if f then
      local raw = f:read("*a")
      f:close()
      templates = json.decode(raw) or {}
      print(string.format("[QuizExtension] loaded %d question templates", #templates))
    else
      print("[QuizExtension] could not open questions.json:", err)
    end

    -- register view
    if Program and Program.registerView then
      Program.registerView(self)
      print("[QuizExtension] registered view")
    end

    -- inject Quiz button
    if GameOverScreen and GameOverScreen.Buttons and not GameOverScreen.Buttons.QuizMe then
      local ext = self
      local w, h = 48, 16
      local baseX = Constants.SCREEN.WIDTH + Constants.SCREEN.MARGIN
      local availW = Constants.SCREEN.RIGHT_GAP - (Constants.SCREEN.MARGIN * 2)
      local x = baseX + availW - w
      local y = Constants.SCREEN.MARGIN + 58 - h - 2

      GameOverScreen.Buttons.QuizMe = {
        type          = Constants.ButtonTypes.ICON_BORDER,
        image         = Constants.PixelImages.NOTEPAD,
        getText       = function() return "Quiz" end,
        box           = { x, y, w, h },
        clickableArea = { x, y, w, h },
        onClick       = function()
          ext:loadRandom()
          Program.changeScreenView(ext)
        end,
      }

      GameOverScreen.refreshButtons()
      print("[QuizExtension] Quiz button injected into GameOverScreen")
    end
  end

  --------------------------------
  -- 4) New question
  --------------------------------
  function self.loadRandom()
    if #templates == 0 then
      return
    end

    local tpl = templates[ math.random(#templates) ]
    self.currentT = tpl

    -- reset state
    self.answered = false
    self.correctCount = 0
    self.totalQuestions = 1
    self.countdownStart = nil

    print(string.format(
      "[QuizExtension] loadRandom picked template ID=%s text=<%s>",
      tostring(tpl.id), tostring(tpl.text)
    ))

    self:buildOptions(tpl)
    print(string.format(
      "[QuizExtension] counter reset to %d/%d",
      self.correctCount, self.totalQuestions
    ))
  end

  --------------------------------
  -- Helpers: pickOne, pickMany
  --------------------------------
  local function pickOne(tbl)
    return tbl[ math.random(#tbl) ]
  end

  local function pickMany(tbl, n)
    local out = {}
    local used = {}
    local max = math.min(n, #tbl)

    while #out < max do
      local candidate = tbl[ math.random(#tbl) ]
      if not used[candidate] then
        used[candidate] = true
        table.insert(out, candidate)
      end
    end

    return out
  end

  --------------------------------
  -- 5) Build options
  --------------------------------
  function self:buildOptions(tpl)
    print(string.format(
      "[QuizExtension] buildOptions tpl → type=%s key=%s id=%s",
      tostring(tpl.type), tostring(tpl.key), tostring(tpl.id)
    ))

    -- ensure Tracker.Data.allPokemon exists
    if type(Tracker) ~= "table"
      or not Tracker.Data
      or not Tracker.Data.allPokemon then
      print("[QuizExtension] ERROR: Tracker.Data.allPokemon not available")
      self.options = {}
      return
    end

    -- only multiple/pokemon
    if tpl.type ~= "multiple" or tpl.key ~= "pokemon" then
      print(string.format(
        "[QuizExtension] skipping buildOptions, tpl.type=%s tpl.key=%s",
        tpl.type, tpl.key
      ))
      self.options = {}
      return
    end

    -- collect seen IDs
    local seenIDs = {}
    for id,_ in pairs(Tracker.Data.allPokemon) do
      local num = tonumber(id)
      if num then
        table.insert(seenIDs, num)
      else
        print(string.format(
          "[QuizExtension] WARNING: allPokemon key %q not a number",
          id
        ))
      end
    end
    print(string.format(
      "[QuizExtension] found %d seen IDs",
      #seenIDs
    ))

    -- fallback if no seen
    if #seenIDs == 0 then
      print("[QuizExtension] No seen Pokémon – using fallback options")
      local full = {}
      for i = 1, 151 do
        table.insert(full, i)
      end
      local pool = pickMany(full, 4)
      self.options = {}
      for _, id in ipairs(pool) do
        table.insert(
          self.options,
          PokemonNames[id] or ("#" .. id)
        )
      end
      print(string.format(
        "[QuizExtension] fallback options: %s",
        table.concat(self.options, ",")
      ))
      return
    end

    -- unseen IDs
    local seenSet = {}
    for _, id in ipairs(seenIDs) do
      seenSet[id] = true
    end

    local unseen = {}
    for id = 1, 151 do
      if not seenSet[id] then
        table.insert(unseen, id)
      end
    end
    print(string.format(
      "[QuizExtension] unseen count: %d",
      #unseen
    ))

    -- pick correct and distractors
    local correctID, distractors
    if tpl.id == 1 then
      correctID = pickOne(unseen)
      distractors = pickMany(seenIDs, 3)
    else
      correctID = pickOne(seenIDs)
      distractors = pickMany(unseen, 3)
    end
    print(string.format(
      "[QuizExtension] correctID=%d distractors=%s",
      correctID, table.concat(distractors, ",")
    ))

    -- assemble pool and shuffle
    local pool = { correctID }
    local used = { [correctID] = true }

    for _, d in ipairs(distractors) do
      table.insert(pool, d)
      used[d] = true
    end

    while #pool < 4 do
      local cand = math.random(1, 151)
      if not used[cand] then
        used[cand] = true
        table.insert(pool, cand)
      end
    end

    for i = #pool, 2, -1 do
      local j = math.random(i)
      pool[i], pool[j] = pool[j], pool[i]
    end

    -- map to names and track correct index
    self.options = {}
    self.correctIndex = nil
    for i, id in ipairs(pool) do
      local name = PokemonNames[id] or ("#" .. id)
      table.insert(self.options, name)
      if id == correctID then
        self.correctIndex = i
      end
    end

    print(string.format(
      "[QuizExtension] options: %s",
      table.concat(self.options, ",")
    ))
  end

  --------------------------------
  -- 6) Setup buttons
  --------------------------------
  function self.setupButtons(botBox)
    self.Buttons = {}
    local h = 16
    local spacing = 4
    local totalH = #self.options * h + (#self.options - 1) * spacing
    local startY = botBox.y + math.floor((botBox.height - totalH) / 2)
    local w = botBox.width - 8
    local x = botBox.x + 4

    for i, name in ipairs(self.options) do
      local y = startY + (i - 1) * (h + spacing)
      self.Buttons["Opt" .. i] = {
        type          = Constants.ButtonTypes.ICON_BORDER,
        getText       = function() return name end,
        box           = { x, y, w, h },
        clickableArea = { x, y, w, h },
        onClick       = function() self:onPick(i) end,
        textColor     = "Lower box text",
        boxColors     = { "Lower box border", "Lower box background" }
      }
    end
  end

  --------------------------------
  -- 7) Handle pick
  --------------------------------
  function self:onPick(idx)
    print("[QuizExtension] You chose index", idx, "->", self.options[idx])
    if idx == self.correctIndex then
      self.correctCount = self.correctCount + 1
      print("[QuizExtension] Correct! count now", self.correctCount, "/", self.totalQuestions)
    else
      print("[QuizExtension] Incorrect. count remains", self.correctCount, "/", self.totalQuestions)
    end
    self.answered = true
    self.countdownStart = os.time()
  end

  --------------------------------
  -- 8) Draw & input
  --------------------------------
  function self.drawScreen()
    Drawing.drawBackgroundAndMargins()

    local x0, y0 = Constants.SCREEN.WIDTH + Constants.SCREEN.MARGIN,
                   Constants.SCREEN.MARGIN
    local w0, h0 = Constants.SCREEN.RIGHT_GAP - (Constants.SCREEN.MARGIN * 2),
                   58

    -- upper box
    local topBox = {
      x      = x0,
      y      = y0,
      width  = w0,
      height = h0,
      text   = Theme.COLORS["Default text"],
      border = Theme.COLORS["Upper box border"],
      fill   = Theme.COLORS["Upper box background"],
      shadow = Utils.calcShadowColor(Theme.COLORS["Upper box background"]) }

    gui.defaultTextBackground(topBox.fill)
    gui.drawRectangle(
      topBox.x, topBox.y,
      topBox.width, topBox.height,
      topBox.border, topBox.fill)

    -- question text
    local yy = topBox.y + 2
    Drawing.drawText(
      topBox.x + 2, yy,
      Utils.toUpperUTF8("Quiz Time!"),
      Theme.COLORS["Intermediate text"],
      topBox.shadow)
    yy = yy + Constants.SCREEN.LINESPACING

    if self.currentT then
      for _, line in ipairs(Utils.getWordWrapLines(self.currentT.text, 30)) do
        Drawing.drawText(
          topBox.x + 2, yy,
          line,
          topBox.text,
          topBox.shadow)
        yy = yy + Constants.SCREEN.LINESPACING
      end
    end

    -- bottom row in upper box: counter, correct label, countdown
    local bottomY = topBox.y + topBox.height - Constants.SCREEN.LINESPACING

    -- left: counter
    local cntText = string.format("%d/%d", self.correctCount, self.totalQuestions)
    Drawing.drawText(
      topBox.x + 4, bottomY,
      cntText,
      topBox.text,
      topBox.shadow)

    -- center: correct answer label
    if self.answered and self.correctIndex then
      local ans = self.options[self.correctIndex]
      local correctLabel = string.format("Correct: %s", ans)
      local midX = topBox.x + 5 + math.floor((topBox.width - (#correctLabel * 6)) / 2)
      Drawing.drawText(
        midX, bottomY,
        correctLabel,
        topBox.text,
        topBox.shadow)
    end

    -- right: countdown
    if self.answered and self.countdownStart then
      local elapsed = os.time() - self.countdownStart
      local rem = 4 - elapsed
      if rem < 0 then rem = 0 end
      local countLabel = tostring(rem)
      local labelX = topBox.x + topBox.width - (#countLabel * 6) - 4
      Drawing.drawText(
        labelX, bottomY,
        countLabel,
        topBox.text,
        topBox.shadow)
    end

    -- lower box for answer buttons
    local botBox = {
      x      = x0,
      y      = y0 + h0,
      width  = w0,
      height = Constants.SCREEN.HEIGHT - h0 - 10,
      text   = Theme.COLORS["Lower box text"],
      border = Theme.COLORS["Lower box border"],
      fill   = Theme.COLORS["Lower box background"],
      shadow = Utils.calcShadowColor(Theme.COLORS["Lower box background"]) }

    gui.defaultTextBackground(botBox.fill)
    gui.drawRectangle(
      botBox.x, botBox.y,
      botBox.width, botBox.height,
      botBox.border, botBox.fill)

    -- answer buttons
    self.setupButtons(botBox)
    for _, btn in pairs(self.Buttons) do
      Drawing.drawButton(btn, botBox.shadow)
    end
  end

  function self.checkInput(x, y)
    Input.checkButtonsClicked(x, y, self.Buttons)
  end

  --------------------------------
  -- 9) Cleanup
  --------------------------------
  function self.unload()
    print("[QuizExtension] unload")
    self.Buttons = {}
  end

  return self
end

return QuizExtension
