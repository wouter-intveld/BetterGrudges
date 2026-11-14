local ADDON = ...
local TITLE = "|cffcda552Better|rGrudges"

local DEFAULTS = {
    quiet = false, -- don't print new entries to chat
    realms = {},   -- realm -> player name -> record (see Record)
}

-- Entry kinds. A grudge stays open until a matching win settles it.
local KIND = {
    killedMe = { grudge = true, settledBy = "killedThem", text = "killed you" },
    duelLost = { grudge = true, settledBy = "duelWon", text = "bested you in a duel" },
    killedThem = { text = "fell to you" },
    duelWon = { text = "lost a duel to you" },
    rez = { kind = true, text = "offered you a resurrection" },
    buff = { kind = true, text = "buffed you with %s" },
    note = { text = "%s" },
    grudgeNote = { grudge = true, settledBy = "killedThem", text = "%s" },
    kindNote = { kind = true, text = "%s" },
}

local db
local myName -- set at login
local lastRez = {} -- name -> time, so a recast isn't noted twice
local RefreshBook -- the book window, defined below; redrawn whenever the book changes

local function Print(msg)
    print(TITLE .. ": " .. msg)
end

local function Notify(msg)
    if not db.quiet then Print(msg) end
end

local function Book()
    local realm = GetRealmName()
    db.realms[realm] = db.realms[realm] or {}
    return db.realms[realm]
end

-- The player's record, created on first meeting. name is "Name" on your own
-- realm and "Name-Realm" for others.
local function Record(name, guid)
    local book = Book()
    local p = book[name]
    if not p then
        p = { entries = {} }
        book[name] = p
    end
    if guid and not p.class then
        local _, class = GetPlayerInfoByGUID(guid)
        p.class = class
    end
    return p
end

local function Describe(e)
    local text = KIND[e.k].text:format(e.s or "")
    if e.busy then text = text .. " while you were fighting something else" end
    if e.z and e.z ~= "" then text = text .. " in " .. e.z end
    return text
end

local function Add(name, guid, kind, extra)
    name = Ambiguate(name, "none")
    local p = Record(name, guid)
    local e = { t = time(), k = kind, z = GetZoneText() }
    for key, value in pairs(extra or {}) do e[key] = value end
    p.entries[#p.entries + 1] = e
    p.seen = e.t

    -- A win settles the oldest open grudge of its kind.
    for _, old in ipairs(p.entries) do
        local def = KIND[old.k]
        if def.settledBy == kind and not old.done then
            old.done = e.t
            e.avenged = true
            break
        end
    end
    RefreshBook()
    return p, e
end

local function Counts(p)
    local open, settled, kindness = 0, 0, 0
    for _, e in ipairs(p.entries) do
        local def = KIND[e.k]
        if def.grudge then
            if e.done then settled = settled + 1 else open = open + 1 end
        elseif def.kind then
            kindness = kindness + 1
        end
    end
    return open, settled, kindness
end

local function Summary(p)
    local open, settled, kindness = Counts(p)
    local parts = {}
    if open > 0 then parts[#parts + 1] = ("|cffff5050%d grudge%s|r"):format(open, open == 1 and "" or "s") end
    if settled > 0 then parts[#parts + 1] = ("|cff999999%d settled|r"):format(settled) end
    if kindness > 0 then parts[#parts + 1] = ("|cff50ff50%d kindness%s|r"):format(kindness, kindness == 1 and "" or "es") end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

-- One entry as a coloured line: open grudges red, kindnesses green, settled grey.
local function EntryLine(e)
    local line = date("%Y-%m-%d", e.t) .. "  " .. Describe(e)
    if e.done then return "|cff999999" .. line .. " [settled]|r" end
    if KIND[e.k].grudge then return "|cffff5050" .. line .. "|r" end
    if KIND[e.k].kind then return "|cff50ff50" .. line .. "|r" end
    return line
end

-- Everyone in the book whose name contains filter: open grudges first, then
-- the most recently met.
local function SortedPages(filter)
    local list = {}
    for name, p in pairs(Book()) do
        if filter == "" or name:lower():find(filter, 1, true) then
            local summary = Summary(p) or (#p.entries > 0 and "notes" or "empty page")
            list[#list + 1] = { name = name, open = (Counts(p)), seen = p.seen or 0, summary = summary }
        end
    end
    table.sort(list, function(a, b)
        if a.open ~= b.open then return a.open > b.open end
        return a.seen > b.seen
    end)
    return list
end

local function Forgive(name)
    local n = 0
    for _, e in ipairs(Book()[name].entries) do
        if KIND[e.k].grudge and not e.done then
            e.done, n = time(), n + 1
        end
    end
    RefreshBook()
    Print(n > 0 and ("%s: %d grudge%s forgiven. Generous."):format(name, n, n == 1 and "" or "s")
        or (name .. " has no open grudges."))
end

local function Remove(name)
    Book()[name] = nil
    RefreshBook()
    Print(name .. "'s page is torn out of the book.")
end

---------------------------------------------------------------------------
-- Recording. This client keeps the combat log from addons, so everything
-- here comes from unit state, your own buffs and chat messages.
---------------------------------------------------------------------------

-- Units that can be checked by name: what you're looking at, and every nameplate.
local function EachUnit(fn)
    for _, unit in ipairs({ "target", "focus", "mouseover" }) do fn(unit) end
    for i = 1, 40 do fn("nameplate" .. i) end
end

-- Your killer is the hostile player who had you targeted when you died; a
-- creature with you targeted too means you were busy with it.
local function OnPlayerDead()
    local killers, seen, busy = {}, {}, nil
    EachUnit(function(unit)
        if not (UnitExists(unit) and UnitIsUnit(unit .. "target", "player") and UnitCanAttack("player", unit)) then return end
        if UnitIsPlayer(unit) then
            local guid = UnitGUID(unit)
            if guid and not seen[guid] then
                seen[guid] = true
                killers[#killers + 1] = { name = GetUnitName(unit, true), guid = guid }
            end
        else
            busy = true
        end
    end)
    for _, k in ipairs(killers) do
        local p = Add(k.name, k.guid, "killedMe", { busy = busy })
        Notify(("%s killed you. Noted in the book (%s)."):format(k.name, Summary(p)))
    end
end

-- Buffs other players put on you, in the open world only and once a day per
-- player: cities and dungeons would fill the book.
local function OnPlayerAura(_, info)
    if not (info and info.addedAuras) or IsInInstance() then return end
    for _, aura in ipairs(info.addedAuras) do
        local src = aura.sourceUnit
        if aura.isHelpful and src and UnitIsPlayer(src) and not UnitIsUnit(src, "player")
            and not UnitCanAttack("player", src) then
            local name, guid = Ambiguate(GetUnitName(src, true), "none"), UnitGUID(src)
            local p = Record(name, guid)
            local today = date("%Y-%m-%d")
            if p.buffDay ~= today then
                p.buffDay = today
                Add(name, guid, "buff", { s = aura.name })
            end
        end
    end
end

-- "%1$s has defeated %2$s in a duel" -> a pattern, and which argument each capture is.
local function GlobalPattern(fmt)
    local order = {}
    local pat = fmt:gsub("%%(%d*)%$?[sd]", function(n)
        order[#order + 1] = n ~= "" and tonumber(n) or #order + 1
        return "\0"
    end)
    pat = pat:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%z", "(.+)")
    return "^" .. pat .. "$", order
end

-- "Name dies, honorable kill Rank: ...": a player you or your group killed.
local HONOR_PATTERNS = {}
for _, fmt in ipairs({ COMBATLOG_HONORGAIN, COMBATLOG_HONORGAIN_NO_RANK }) do
    if fmt then HONOR_PATTERNS[#HONOR_PATTERNS + 1] = { GlobalPattern(fmt) } end
end

local function OnHonorGain(msg)
    for _, h in ipairs(HONOR_PATTERNS) do
        local caps = { msg:match(h[1]) }
        if caps[1] then
            local args = {}
            for i, n in ipairs(h[2]) do args[n] = caps[i] end
            local victim = args[1]
            local _, e = Add(victim, nil, "killedThem")
            if e.avenged then Notify(victim .. ": grudge avenged!") end
            return
        end
    end
end

local DUEL_PATTERNS = {}
for _, fmt in ipairs({ DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT }) do
    if fmt then
        local pat, order = GlobalPattern(fmt)
        DUEL_PATTERNS[#DUEL_PATTERNS + 1] = { pat = pat, order = order }
    end
end

local function OnSystemMessage(msg)
    for _, d in ipairs(DUEL_PATTERNS) do
        local caps = { msg:match(d.pat) }
        if caps[1] then
            local args = {}
            for i, n in ipairs(d.order) do args[n] = caps[i] end
            local winner, loser = args[1], args[2] -- both formats: %1 wins, %2 loses
            if winner == myName and loser then
                local _, e = Add(loser, nil, "duelWon")
                if e.avenged then Notify(loser .. ": duel grudge settled!") end
            elseif loser == myName and winner then
                Add(winner, nil, "duelLost")
                Notify(winner .. " bested you in a duel. Noted in the book.")
            end
            return
        end
    end
end

local function OnResurrectRequest(name)
    if not name or (lastRez[name] and GetTime() - lastRez[name] < 60) then return end
    lastRez[name] = GetTime()
    Add(name, nil, "rez")
    Notify(name .. " offered you a resurrection. You owe them one.")
end

---------------------------------------------------------------------------
-- Tooltip: one line on players in the book
---------------------------------------------------------------------------
local function OnUnitTooltip(tooltip)
    local _, unit = tooltip:GetUnit()
    if not (unit and UnitIsPlayer(unit)) or UnitIsUnit(unit, "player") then return end
    local p = Book()[Ambiguate(GetUnitName(unit, true), "none")]
    local summary = p and Summary(p)
    if summary then tooltip:AddLine("Grudges: " .. summary) end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
-- A name typed in any case, or "target", to the key it has in the book.
local function FindName(arg)
    if arg:lower() == "target" then
        if UnitIsPlayer("target") then return Ambiguate(GetUnitName("target", true), "none"), UnitGUID("target") end
        return nil
    end
    local lower = arg:lower()
    for name in pairs(Book()) do
        if name:lower() == lower then return name end
    end
    -- A new name: each word capitalised, as the game writes them.
    return (arg:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- "<name> <text>" split into name and text. Names on this client can have a
-- space, so the longest run of leading words that is a name in the book wins.
local function SplitName(msg)
    local words = {}
    for word in msg:gmatch("%S+") do words[#words + 1] = word end
    if words[1]:lower() == "target" then
        local name, guid = FindName("target")
        return name, guid, table.concat(words, " ", 2)
    end
    local book = Book()
    for i = #words, 2, -1 do
        local name = FindName(table.concat(words, " ", 1, i))
        if book[name] then return name, nil, table.concat(words, " ", i + 1) end
    end
    return FindName(words[1]), nil, table.concat(words, " ", 2)
end

local function PrintBook()
    local list = SortedPages("")
    if #list == 0 then
        Print("the book is empty. A peaceful life.")
        return
    end
    Print("the book (/grudge <name> opens a page):")
    for _, g in ipairs(list) do print(("  %s: %s"):format(g.name, g.summary)) end
end

local ShowBook -- the book window, defined below

SLASH_BETTERGRUDGES1 = "/grudge"
SLASH_BETTERGRUDGES2 = "/grudges"
SlashCmdList.BETTERGRUDGES = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local first, rest = msg:match("^(%S*)%s*(.-)$")
    local cmd = first:lower()
    if cmd == "" then
        ShowBook()
    elseif cmd == "list" then
        PrintBook()
    elseif cmd == "help" then
        Print("commands:")
        print("  /grudge - open the book")
        print("  /grudge list - everyone in the book, in chat")
        print("  /grudge <name> - open their page (\"target\" works as a name)")
        print("  /grudge <name> <text> - write a note on their page")
        print("  /grudge forgive <name> - settle all their open grudges")
        print("  /grudge remove <name> - tear their page out of the book")
        print("  /grudge quiet - don't print new entries")
    elseif cmd == "quiet" then
        db.quiet = not db.quiet
        Print("new entries " .. (db.quiet and "muted" or "printed"))
    elseif cmd == "remove" then
        local name = rest ~= "" and FindName(rest)
        if not (name and Book()[name]) then
            Print("usage: /grudge remove <name>")
            return
        end
        Remove(name)
    elseif cmd == "forgive" then
        local name = rest ~= "" and FindName(rest)
        if not (name and Book()[name]) then
            Print("usage: /grudge forgive <name>")
            return
        end
        Forgive(name)
    else
        local name, guid
        name, guid, rest = SplitName(msg)
        if not name then
            Print("your target isn't a player.")
        elseif rest == "" then
            if Book()[name] then ShowBook(name) else Print(name .. " isn't in the book.") end
        else
            Add(name, guid, "note", { s = rest })
            Print("noted on " .. name .. "'s page.")
        end
    end
end

---------------------------------------------------------------------------
-- Right-click menu: "Add to the book" on a player asks for a note.
---------------------------------------------------------------------------
StaticPopupDialogs.BETTERGRUDGES_NOTE = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 200,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(self, data)
        local text = (self.EditBox or self.editBox):GetText():match("^%s*(.-)%s*$")
        if text ~= "" then
            local p = Add(data.name, data.guid, data.kind, { s = text })
            Print(("noted on %s's page (%s)."):format(data.name, Summary(p) or "notes"))
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local popup = self:GetParent()
        StaticPopupDialogs.BETTERGRUDGES_NOTE.OnAccept(popup, popup.data)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

-- A new page, from the book's Add button. Your target's name is filled in.
StaticPopupDialogs.BETTERGRUDGES_NEW = {
    text = "Add a player to the book:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 60,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local box = self.EditBox or self.editBox
        if UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
            box:SetText(Ambiguate(GetUnitName("target", true), "none"))
            box:HighlightText()
        end
    end,
    OnAccept = function(self)
        local text = (self.EditBox or self.editBox):GetText():match("^%s*(.-)%s*$")
        if text == "" then return end
        local name, guid = FindName(text)
        if not name then return end
        if not guid and UnitIsPlayer("target") and Ambiguate(GetUnitName("target", true), "none") == name then
            guid = UnitGUID("target")
        end
        Record(name, guid)
        ShowBook(name)
    end,
    EditBoxOnEnterPressed = function(self)
        local popup = self:GetParent()
        StaticPopupDialogs.BETTERGRUDGES_NEW.OnAccept(popup)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

StaticPopupDialogs.BETTERGRUDGES_REMOVE = {
    text = "Tear %s's page out of the book?",
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, name) Remove(name) end,
}

local CHOICES = {
    { label = "|cffff5050Grudge|r", kind = "grudgeNote", prompt = "A grudge against %s:" },
    { label = "|cff50ff50Kindness|r", kind = "kindNote", prompt = "A kindness from %s:" },
    { label = "Note", kind = "note", prompt = "A note on %s:" },
}

local function AskEntry(choice, name, guid)
    StaticPopup_Show("BETTERGRUDGES_NOTE", choice.prompt:format(Ambiguate(name, "none")), nil,
        { name = name, guid = guid, kind = choice.kind })
end

local function AddMenuEntry(_, root, context)
    local unit = context and context.unit
    local name, guid
    if unit and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
        name, guid = GetUnitName(unit, true), UnitGUID(unit)
    elseif context and context.name and not unit then
        name = context.server and context.server ~= "" and (context.name .. "-" .. context.server) or context.name
    end
    if not name then return end
    root:CreateDivider()
    local book = root:CreateButton("Add to the book")
    for _, choice in ipairs(CHOICES) do
        book:CreateButton(choice.label, function() AskEntry(choice, name, guid) end)
    end
end

-- The player menus: unit frames, nameplates, party and raid, and names in chat.
if Menu and Menu.ModifyMenu then
    for _, tag in ipairs({ "MENU_UNIT_PLAYER", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_PARTY",
        "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_FRIEND", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS" }) do
        Menu.ModifyMenu(tag, AddMenuEntry)
    end
end

---------------------------------------------------------------------------
-- The book window: players on the left, the chosen page on the right.
-- Built the first time it opens.
---------------------------------------------------------------------------
local ROW_H, LIST_W, PAGE_W = 32, 190, 400
local ui, selected

local function ClassColour(class)
    local c = class and RAID_CLASS_COLORS[class]
    return c and c.colorStr or "ffffffff"
end

-- A scroll frame that scrolls with the mouse wheel, and its content frame.
local function Scroller(parent, width)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width, 1)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, content:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 2)))
    end)
    return scroll, content
end

local function ListRow(i)
    local row = ui.rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, ui.listContent)
    row:SetSize(LIST_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.15)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 6, -3)
    row.name:SetPoint("RIGHT", -4, 0)
    row.name:SetJustifyH("LEFT")
    row.tally = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.tally:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.tally:SetPoint("RIGHT", -4, 0)
    row.tally:SetJustifyH("LEFT")
    row:SetScript("OnClick", function(self)
        selected = self.player
        RefreshBook()
    end)
    ui.rows[i] = row
    return row
end

local function PageLine(i)
    local fs = ui.lines[i]
    if not fs then
        fs = ui.pageContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetWidth(PAGE_W - 10)
        fs:SetJustifyH("LEFT")
        ui.lines[i] = fs
    end
    return fs
end

local function CreateBook()
    -- The game's own window frame, as the spellbook uses: bronze on this client.
    local f = CreateFrame("Frame", "BetterGrudgesBook", UIParent, "PortraitFrameTemplate")
    f:SetSize(LIST_W + PAGE_W + 50, 460)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "BetterGrudgesBook") -- Escape closes it
    if f.SetTitle then f:SetTitle(TITLE .. ": the book") end
    if f.SetPortraitToAsset then f:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Book_09") end
    ui = { frame = f, rows = {}, lines = {}, buttons = {} }

    local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    search:SetSize(LIST_W - 52, 20)
    search:SetPoint("TOPLEFT", 22, -66) -- below the portrait
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function() RefreshBook() end)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 2, 0)
    hint:SetText("Search")
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost", function(self) hint:SetShown(self:GetText() == "") end)
    ui.search = search

    local add = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    add:SetSize(44, 22)
    add:SetPoint("LEFT", search, "RIGHT", 6, 0)
    add:SetText("Add")
    add:SetScript("OnClick", function() StaticPopup_Show("BETTERGRUDGES_NEW") end)
    add:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Add a player to the book")
        GameTooltip:Show()
    end)
    add:SetScript("OnLeave", GameTooltip_Hide)

    local list
    list, ui.listContent = Scroller(f, LIST_W)
    list:SetPoint("TOPLEFT", 14, -92)
    list:SetPoint("BOTTOMLEFT", 14, 12)
    list:SetWidth(LIST_W)
    ui.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ui.empty:SetPoint("TOP", list, "TOP", 0, -20)
    ui.empty:SetWidth(LIST_W - 20)

    local split = f:CreateTexture(nil, "ARTWORK")
    split:SetColorTexture(1, 0.82, 0, 0.25)
    split:SetWidth(1)
    split:SetPoint("TOPLEFT", LIST_W + 20, -32)
    split:SetPoint("BOTTOMLEFT", LIST_W + 20, 12)

    local x = LIST_W + 32
    ui.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.name:SetPoint("TOPLEFT", x, -34)
    ui.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sub:SetPoint("TOPLEFT", ui.name, "BOTTOMLEFT", 0, -4)

    local page
    page, ui.pageContent = Scroller(f, PAGE_W)
    page:SetPoint("TOPLEFT", x, -76)
    page:SetPoint("BOTTOMRIGHT", -14, 44)
    ui.page = page

    -- Add, forgive and tear out, for the page shown.
    local prev
    local function Button(label, width, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(width, 22)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("BOTTOMLEFT", x - 4, 14) end
        b:SetText(label)
        b:SetScript("OnClick", function() if selected then onClick(selected) end end)
        ui.buttons[#ui.buttons + 1] = b
        prev = b
        return b
    end
    for _, choice in ipairs(CHOICES) do
        Button(choice.label, 72, function(name) AskEntry(choice, name) end)
    end
    ui.forgive = Button("Forgive", 72, Forgive)
    Button("Tear out", 80, function(name) StaticPopup_Show("BETTERGRUDGES_REMOVE", name, nil, name) end)

    f:SetScript("OnShow", function() RefreshBook() end)
end

RefreshBook = function()
    if not (ui and ui.frame:IsShown()) then return end
    local book = Book()
    local list = SortedPages(ui.search:GetText():lower())
    if selected and not book[selected] then selected = nil end
    if not selected and list[1] then selected = list[1].name end

    for i, g in ipairs(list) do
        local row = ListRow(i)
        row.player = g.name
        row.name:SetText("|c" .. ClassColour(book[g.name].class) .. g.name .. "|r")
        row.tally:SetText(g.summary)
        row.selected:SetShown(g.name == selected)
        row:Show()
    end
    for i = #list + 1, #ui.rows do ui.rows[i]:Hide() end
    ui.listContent:SetHeight(math.max(1, #list * ROW_H))
    ui.empty:SetText(#list == 0 and (next(book) and "No one by that name." or "The book is empty. A peaceful life.") or "")

    local p = selected and book[selected]
    for _, b in ipairs(ui.buttons) do b:SetEnabled(p ~= nil) end
    for _, fs in ipairs(ui.lines) do fs:Hide() end
    if not p then
        ui.name:SetText("")
        ui.sub:SetText("")
        return
    end
    ui.forgive:SetEnabled((Counts(p)) > 0)
    ui.name:SetText("|c" .. ClassColour(p.class) .. selected .. "|r")
    local class = p.class and (p.class:sub(1, 1) .. p.class:sub(2):lower() .. ", ") or ""
    ui.sub:SetText(class .. (Summary(p) or "notes only") .. (p.seen and (", last met " .. date("%Y-%m-%d", p.seen)) or ""))

    -- Newest first: what happened last is what you want to know.
    local y = 0
    for i = #p.entries, 1, -1 do
        local fs = PageLine(#p.entries - i + 1)
        fs:SetText(EntryLine(p.entries[i]))
        fs:SetPoint("TOPLEFT", 0, -y)
        fs:Show()
        y = y + fs:GetStringHeight() + 6
    end
    ui.pageContent:SetHeight(math.max(1, y))
    ui.page:SetVerticalScroll(0)
end

ShowBook = function(name)
    if not ui then CreateBook() end
    if name then
        selected = name
        ui.frame:Show()
        RefreshBook()
    else
        ui.frame:SetShown(not ui.frame:IsShown())
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local handlers = {
    UNIT_AURA = OnPlayerAura,
    CHAT_MSG_COMBAT_HONOR_GAIN = OnHonorGain,
    PLAYER_DEAD = OnPlayerDead,
    CHAT_MSG_SYSTEM = OnSystemMessage,
    RESURRECT_REQUEST = OnResurrectRequest,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        frame:UnregisterEvent("ADDON_LOADED")
        BetterGrudgesDB = BetterGrudgesDB or {}
        db = BetterGrudgesDB
        for key, value in pairs(DEFAULTS) do
            if db[key] == nil then db[key] = type(value) == "table" and CopyTable(value) or value end
        end
        myName = UnitName("player")
        for name in pairs(handlers) do
            if name == "UNIT_AURA" then frame:RegisterUnitEvent(name, "player") else frame:RegisterEvent(name) end
        end
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
        return
    end
    handlers[event](...)
end)
