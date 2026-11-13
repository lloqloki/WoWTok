-- Проверка WoWTok.lua вне игры: поддельный API WoW + сценарии.
-- Сборщик (build_test.py) ставит перед этим файлом строку: local ADDON_SRC = [==[ ...код аддона... ]==]

local out, fails, total = {}, 0, 0
local function check(name, cond, extra)
    total = total + 1
    if cond then
        out[#out + 1] = "ok    " .. name
    else
        fails = fails + 1
        out[#out + 1] = "FAIL  " .. name .. (extra ~= nil and ("  [" .. tostring(extra) .. "]") or "")
    end
end

-- ================= поддельный API =================
local now, cursorY, mouseDown = 100, 400, false
local allFrames, played, uiErrors = {}, {}, {}
local sounds, stopped, printed = {}, {}, {}
local mockGuild = nil
local SCALE = 0.8

local function class(base)
    local c = setmetatable({}, { __index = base })
    c.__index = c
    return c
end

local LAYERS = { BACKGROUND = true, BORDER = true, ARTWORK = true, OVERLAY = true, HIGHLIGHT = true }
local FONTS = {
    GameFontNormal = true, GameFontNormalLarge = true, GameFontHighlight = true, GameFontHighlightSmall = true,
    GameFontHighlightLarge = true, GameFontDisable = true, GameFontDisableSmall = true,
}
local POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local Region = class(nil)
function Region:SetSize(w, h) assert(type(w) == "number" and type(h) == "number", "SetSize") self._w, self._h = w, h end
function Region:SetWidth(w) assert(type(w) == "number", "SetWidth") self._w = w end
function Region:SetHeight(h) assert(type(h) == "number", "SetHeight") self._h = h end
function Region:SetPoint(point, a, b, c, d)
    assert(POINTS[point], "SetPoint: bad point " .. tostring(point))
    local p = { point = point, x = 0, y = 0 }
    if type(a) == "number" then
        assert(type(b) == "number", "SetPoint: y missing")
        p.x, p.y = a, b
    elseif a ~= nil then
        assert(type(a) == "table" and a._kind, "SetPoint: relativeTo is not a region")
        assert(POINTS[b], "SetPoint: bad relative point " .. tostring(b))
        p.rel, p.relPoint = a, b
        if c ~= nil then
            assert(type(c) == "number" and type(d) == "number", "SetPoint: bad offsets")
            p.x, p.y = c, d
        end
    end
    self._points[#self._points + 1] = p
end
function Region:ClearAllPoints() self._points = {} end
function Region:SetAllPoints() self._points = { { point = "ALL", x = 0, y = 0 } } end
function Region:IsShown() return self._shown end
function Region:IsVisible() return self._shown and (not self._parent or self._parent:IsVisible()) end
function Region:_fire(visible)
    if self._scripts then
        local h = self._scripts[visible and "OnShow" or "OnHide"]
        if h then h(self) end
    end
    if self._children then
        for _, c in ipairs(self._children) do
            if c._shown then c:_fire(visible) end
        end
    end
end
function Region:SetShown(v)
    assert(type(v) == "boolean", "SetShown needs a boolean, got " .. type(v))
    local was = self:IsVisible()
    self._shown = v
    local is = self:IsVisible()
    if was ~= is then self:_fire(is) end
end
function Region:Show() self:SetShown(true) end
function Region:Hide() self:SetShown(false) end
function Region:SetAlpha(a) assert(type(a) == "number", "SetAlpha") end
function Region:GetParent() return self._parent end

local Texture = class(Region)
function Texture:SetTexture(t) assert(type(t) == "string", "SetTexture") self._tex = t end
function Texture:SetColorTexture(r, g, b, a)
    assert(type(r) == "number" and type(g) == "number" and type(b) == "number", "SetColorTexture")
    self._color = { r, g, b, a }
end
function Texture:SetTexCoord(...) assert(select("#", ...) == 4, "SetTexCoord") self._coords = { ... } end
function Texture:SetDesaturated(v) assert(type(v) == "boolean", "SetDesaturated needs a boolean") self._desat = v end
function Texture:SetBlendMode(m) assert(m == "ADD" or m == "BLEND", "SetBlendMode") end

local FontString = class(Region)
function FontString:SetText(t)
    assert(type(t) == "string" or type(t) == "number", "SetText got " .. type(t))
    self._text = tostring(t)
end
function FontString:GetText() return self._text end
function FontString:SetJustifyH(j) assert(j == "LEFT" or j == "RIGHT" or j == "CENTER", "SetJustifyH") end
function FontString:SetTextColor(r, g, b) assert(type(r) == "number" and type(g) == "number" and type(b) == "number", "SetTextColor") end

local function newRegion(cls, kind, parent)
    local r = setmetatable({ _kind = kind, _parent = parent, _points = {}, _shown = true }, cls)
    return r
end

local FRAME_SCRIPTS = {
    OnShow = true, OnHide = true, OnUpdate = true, OnEvent = true, OnMouseDown = true, OnMouseUp = true,
    OnMouseWheel = true, OnDragStart = true, OnDragStop = true, OnEnter = true, OnLeave = true,
}

local Frame = class(Region)
function Frame:CreateTexture(name, layer)
    assert(LAYERS[layer], "CreateTexture: bad layer " .. tostring(layer))
    return newRegion(Texture, "Texture", self)
end
function Frame:CreateFontString(name, layer, font)
    assert(LAYERS[layer], "CreateFontString: bad layer " .. tostring(layer))
    assert(FONTS[font], "CreateFontString: unknown font " .. tostring(font))
    return newRegion(FontString, "FontString", self)
end
function Frame:SetScript(name, fn)
    assert(FRAME_SCRIPTS[name] or (self._kind == "Button" and name == "OnClick"), "unknown script " .. tostring(name))
    assert(fn == nil or type(fn) == "function", "SetScript: handler is not a function")
    self._scripts[name] = fn
end
function Frame:GetScript(name) return self._scripts[name] end
function Frame:EnableMouse(v) assert(type(v) == "boolean") end
function Frame:EnableMouseWheel(v) assert(type(v) == "boolean") end
function Frame:SetMovable(v) assert(type(v) == "boolean") self._movable = v end
function Frame:SetClampedToScreen(v) assert(type(v) == "boolean") end
function Frame:SetToplevel(v) assert(type(v) == "boolean") end
function Frame:SetClipsChildren(v) assert(type(v) == "boolean") self._clips = v end
function Frame:RegisterForDrag(b) assert(b == "LeftButton") end
function Frame:StartMoving() assert(self._movable, "StartMoving on a non-movable frame") end
function Frame:StopMovingOrSizing() end
function Frame:GetPoint(i)
    local p = self._points[i or 1]
    return p.point, p.rel, p.relPoint or p.point, p.x, p.y
end
function Frame:GetEffectiveScale() return SCALE end
function Frame:RegisterEvent(e) assert(type(e) == "string") self._events[e] = true end

local Button = class(Frame)
function Button:SetText(t) assert(type(t) == "string") self._text = t end
function Button:SetEnabled(v) assert(type(v) == "boolean", "SetEnabled needs a boolean") self._enabled = v end
function Button:IsEnabled() return self._enabled end
function Button:SetHighlightTexture(t, mode) assert(type(t) == "string") end
function Button:SetPushedTexture(t) assert(type(t) == "string") end

local TEMPLATES = { BackdropTemplate = true, UIPanelCloseButton = true, UIPanelButtonTemplate = true }

function CreateFrame(kind, name, parent, template)
    assert(kind == "Frame" or kind == "Button", "CreateFrame: kind " .. tostring(kind))
    assert(template == nil or TEMPLATES[template], "CreateFrame: unknown template " .. tostring(template))
    assert(parent == nil or (type(parent) == "table" and parent._kind), "CreateFrame: bad parent")
    local f = newRegion(kind == "Button" and Button or Frame, kind, parent)
    f._scripts, f._events, f._children, f._enabled, f._name = {}, {}, {}, true, name
    if template == "BackdropTemplate" then
        f.SetBackdrop = function(self, t) assert(type(t) == "table") end
        f.SetBackdropColor = function(self, r, g, b) assert(type(r) == "number") end
        f.SetBackdropBorderColor = function(self, r, g, b) assert(type(r) == "number") end
    end
    if parent then parent._children[#parent._children + 1] = f end
    if name then _G[name] = f end
    allFrames[#allFrames + 1] = f
    return f
end

function GetTime() return now end
function GetCursorPosition() return 0, cursorY end
function IsMouseButtonDown(b) assert(b == "LeftButton") return mouseDown end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_CHARACTER_INFO_OPEN = 839, IG_CHARACTER_INFO_CLOSE = 840 }
function PlaySound(id) assert(type(id) == "number") played[#played + 1] = id end
function UnitName(u) assert(u == "player") return "Локи" end
function UnitClass(u) assert(u == "player") return "Друид", "DRUID" end
function UnitRace(u) assert(u == "player") return "Ночной эльф", "NightElf" end
function UnitLevel(u) assert(u == "player") return 60 end
function GetGuildInfo(u) assert(u == "player") return mockGuild end
function GetRealmName() return "Forever" end
RAID_CLASS_COLORS = { DRUID = { r = 1, g = 0.49, b = 0.04 } }
function SetPortraitTexture(tex, unit)
    assert(type(tex) == "table" and tex._kind == "Texture", "SetPortraitTexture: not a texture")
    tex._portrait = unit
end
tinsert = table.insert
function PlaySoundFile(path, channel)
    assert(type(path) == "string" and channel == "Master", "PlaySoundFile")
    sounds[#sounds + 1] = path
    return true, 1000 + #sounds
end
function StopSound(handle) assert(type(handle) == "number", "StopSound") stopped[#stopped + 1] = handle end
print = function(text) printed[#printed + 1] = tostring(text) end
UIErrorsFrame = { AddMessage = function(self, msg) assert(type(msg) == "string") uiErrors[#uiErrors + 1] = msg end }
GameTooltip = { SetOwner = function() end, SetText = function() end, Show = function() end, Hide = function() end }

-- запуск аддона с чистого листа, как после входа в игру или /reload
local function boot(saved, videos)
    allFrames, played, uiErrors = {}, {}, {}
    sounds, stopped, printed = {}, {}, {}
    mouseDown = false
    WoWTokDB, WoWTokFrame, __T = saved, nil, nil
    UISpecialFrames, SlashCmdList = {}, {}
    UIParent = CreateFrame("Frame")
    local chunk, err = load(ADDON_SRC .. "\n__T = { Short = Short, Item = Item }", "=WoWTok.lua")
    assert(chunk, err)
    chunk("WoWTok", { videos = videos })
end

local function fire(event, ...)
    for _, f in ipairs(allFrames) do
        if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
    end
end

local function tick(n, dt)
    for _ = 1, n do
        now = now + dt
        for _, f in ipairs(allFrames) do
            if f._scripts.OnUpdate and f:IsVisible() then f._scripts.OnUpdate(f, dt) end
        end
    end
end

local function click(b)
    assert(b:IsVisible(), "click on an invisible button")
    assert(b:IsEnabled(), "click on a disabled button")
    b._scripts.OnClick(b, "LeftButton")
end

local function find()
    local h = {}
    for _, f in ipairs(allFrames) do
        if f._scripts.OnMouseWheel then h.feed = f end
        if f.stats then h.profile = f end
        if f._scripts.OnDragStop then h.grip = f end
        if f._kind == "Button" and f._text == "Лента" then h.navFeed = f end
        if f._kind == "Button" and f._text == "Профиль" then h.navProfile = f end
    end
    return h
end

local function visibleCards(feed)
    local n, cur = 0, nil
    for _, c in ipairs(feed._children) do
        if c:IsShown() then n, cur = n + 1, c end
    end
    return n, cur
end

-- номер карточки на экране, если лента стоит ровно; иначе nil и причина
local function state(h)
    local n, cur = visibleCards(h.feed)
    if n ~= 1 then return nil, "visible cards: " .. n end
    local p = cur._points[1]
    if #cur._points ~= 1 or math.abs(p.y) > 0.001 or p.point ~= "TOPLEFT" then return nil, "card offset " .. tostring(p and p.y) end
    return cur.index, cur
end

local function down(h) mouseDown = true h.feed._scripts.OnMouseDown(h.feed, "LeftButton") end
local function up(h, noEvent)
    mouseDown = false
    if not noEvent then h.feed._scripts.OnMouseUp(h.feed, "LeftButton") end
end

-- свайп на dist единиц интерфейса (плюс = вверх) за secs секунд
local function swipe(h, dist, secs, noMouseUp)
    local steps = math.max(1, math.floor(secs / 0.016 + 0.5))
    down(h)
    for _ = 1, steps do
        cursorY = cursorY + dist * SCALE / steps
        tick(1, secs / steps)
    end
    up(h, noMouseUp)
    tick(200, 0.016)
end

local function wheel(h, delta, n, dt)
    h.feed._scripts.OnMouseWheel(h.feed, delta)
    tick(n or 200, dt or 0.016)
end

local function tap(h)
    down(h) tick(1, 0.05) up(h) tick(1, 0.05)
end

local function parse(s)
    local num, suf = tostring(s):match("^(%d+%.?%d*)([KMB]?)$")
    if not num then return nil end
    return tonumber(num) * ({ [""] = 1, K = 1e3, M = 1e6, B = 1e9 })[suf], suf
end

-- ================= сценарии =================
local function main()
    local FEED_H = 618 - 34 - 50 - 8

    boot(nil)
    check("команда /tiktok зарегистрирована", SLASH_WOWTOK1 == "/tiktok" and type(SlashCmdList.WOWTOK) == "function")
    SlashCmdList.WOWTOK("")
    fire("UNIT_PORTRAIT_UPDATE", "player")
    check("/tiktok до загрузки сохранений ничего не ломает", WoWTokFrame == nil)
    fire("ADDON_LOADED", "SomeOtherAddon")
    check("загрузка чужого аддона игнорируется", WoWTokDB == nil)
    fire("ADDON_LOADED", "WoWTok")
    check("сохранения созданы", type(WoWTokDB) == "table" and type(WoWTokDB.liked) == "table")
    check("формат кадров по умолчанию - jpg", WoWTokDB.format == "jpg", WoWTokDB.format)
    check("окно не строится, пока не позвали", WoWTokFrame == nil)

    SlashCmdList.WOWTOK("")
    local win = WoWTokFrame
    check("/tiktok открывает окно", win ~= nil and win:IsVisible())
    check("окно закрывается по Esc", UISpecialFrames[1] == "WoWTokFrame")
    check("звук открытия", played[#played] == 839, played[#played])
    local h = find()
    check("найдены лента, профиль, шапка, кнопки", h.feed and h.profile and h.grip and h.navFeed and h.navProfile)
    check("лента обрезает карточки по рамке", h.feed._clips == true)

    local idx, card = state(h)
    check("первая карточка - #1", idx == 1 and card.title:GetText() == "Видео #1", card)
    check("открыта лента, кнопка 'Лента' неактивна",
        h.feed:IsVisible() and not h.profile:IsVisible() and not h.navFeed:IsEnabled() and h.navProfile:IsEnabled())
    check("на карточке есть автор, подпись и звук",
        card.author:GetText():sub(1, 1) == "@" and #card.caption:GetText() > 5 and card.sound:GetText():find("оригинальный звук", 1, true) ~= nil)

    -- свайпы
    swipe(h, 200, 0.4)
    idx, card = state(h)
    check("свайп вверх листает на #2", idx == 2 and card.title:GetText() == "Видео #2", card)
    check("место в ленте запоминается", WoWTokDB.index == 2, WoWTokDB.index)
    swipe(h, -200, 0.4)
    idx, card = state(h)
    check("свайп вниз возвращает на #1", idx == 1, card)
    swipe(h, -300, 0.4)
    idx, card = state(h)
    check("выше первой карточки листать некуда", idx == 1, card)
    swipe(h, 60, 0.6)
    idx, card = state(h)
    check("короткое медленное движение возвращает карточку", idx == 1, card)
    swipe(h, 40, 0.1)
    idx, card = state(h)
    check("быстрый рывок вверх листает дальше", idx == 2, card)
    swipe(h, -40, 0.1)
    idx, card = state(h)
    check("быстрый рывок вниз листает назад", idx == 1, card)
    swipe(h, 200, 0.4, true)
    idx, card = state(h)
    check("отпустили мышь за окном - свайп всё равно завершается", idx == 2, card)

    down(h)
    cursorY = cursorY + 80
    tick(1, 0.016)
    local n = visibleCards(h.feed)
    local a, b = h.feed._children[1], h.feed._children[2]
    local cur, nxt = a, b
    if a.index ~= 2 then cur, nxt = b, a end
    check("во время свайпа видны обе карточки", n == 2 and nxt.index == 3, n)
    check("карточка едет за курсором с учётом масштаба интерфейса", math.abs(cur._points[1].y - 100) < 0.001, cur._points[1].y)
    check("следующая карточка идёт вплотную снизу", math.abs(nxt._points[1].y - (100 - FEED_H)) < 0.001, nxt._points[1].y)
    cursorY = cursorY - 80
    tick(1, 0.5)
    up(h)
    tick(200, 0.016)
    idx, card = state(h)
    check("вернули курсор на место - остались на #2", idx == 2, card)

    wheel(h, -1)
    idx, card = state(h)
    check("колесо вниз листает дальше", idx == 3, card)
    wheel(h, 1)
    idx, card = state(h)
    check("колесо вверх листает назад", idx == 2, card)

    -- лайки
    local before = card.like.count:GetText()
    local base = __T.Item(2).likes
    check("счётчик лайков совпадает с данными карточки", before == __T.Short(base), before)
    check("лайк изначально выключен", card.like.icon._desat == true and not card.like.glow:IsShown() and WoWTokDB.liked[2] == nil)
    click(card.like)
    check("клик по лайку включает его",
        WoWTokDB.liked[2] == true and card.like.icon._desat == false and card.like.glow:IsShown()
        and card.like.count:GetText() == __T.Short(base + 1), card.like.count:GetText())
    check("звук лайка", played[#played] == 856, played[#played])
    click(card.like)
    check("второй клик снимает лайк",
        WoWTokDB.liked[2] == nil and card.like.count:GetText() == before and card.like.icon._desat == true and not card.like.glow:IsShown())
    tap(h)
    check("одиночный клик по ролику лайк не ставит", WoWTokDB.liked[2] == nil)
    tap(h)
    check("двойной клик по ролику ставит лайк", WoWTokDB.liked[2] == true)
    tick(60, 0.016)
    tap(h)
    tap(h)
    check("повторный двойной клик лайк не снимает", WoWTokDB.liked[2] == true)
    tick(60, 0.016)
    idx, card = state(h)
    check("клики не сдвинули ленту", idx == 2, card)

    -- комментарии
    local cbefore = card.comment.count:GetText()
    click(card.comment)
    check("комментарии не работают: только сообщение",
        #uiErrors == 1 and card.comment.count:GetText() == cbefore and h.feed:IsVisible() and state(h) == 2, uiErrors[1])

    -- профиль
    click(card.avatar)
    check("аватар открывает профиль",
        h.profile:IsVisible() and not h.feed:IsVisible() and h.navFeed:IsEnabled() and not h.navProfile:IsEnabled())
    check("в профиле данные персонажа",
        h.profile.name:GetText() == "Локи" and h.profile.info:GetText() == "Уровень 60, Ночной эльф, Друид"
        and h.profile.guild:GetText() == "Forever", h.profile.info:GetText())
    check("в профиле портрет игрока", h.profile.portrait._portrait == "player")
    check("счётчик 'Понравилось' = 1", h.profile.stats[3].value:GetText() == "1", h.profile.stats[3].value:GetText())
    mockGuild = "Орда Навсегда"
    fire("UNIT_PORTRAIT_UPDATE", "player")
    check("гильдия показывается, если она есть", h.profile.guild:GetText() == "<Орда Навсегда>", h.profile.guild:GetText())
    fire("UNIT_PORTRAIT_UPDATE", "target")
    click(h.navFeed)
    check("кнопка 'Лента' возвращает ленту", h.feed:IsVisible() and not h.profile:IsVisible() and state(h) == 2)
    click(h.navProfile)
    check("кнопка 'Профиль' открывает профиль", h.profile:IsVisible() and not h.feed:IsVisible())
    click(h.navFeed)

    -- закрытие посреди свайпа
    down(h)
    cursorY = cursorY + 150
    tick(1, 0.016)
    SlashCmdList.WOWTOK("")
    check("/tiktok второй раз закрывает окно", not win:IsVisible() and played[#played] == 840)
    mouseDown = false
    SlashCmdList.WOWTOK("")
    tick(5, 0.016)
    idx, card = state(h)
    check("закрыли посреди свайпа - лента открылась ровно", win:IsVisible() and idx == 2, card)

    -- перенос окна
    h.grip._scripts.OnDragStart(h.grip)
    win._points = { { point = "TOPLEFT", rel = UIParent, relPoint = "TOPLEFT", x = 50, y = -60 } }
    h.grip._scripts.OnDragStop(h.grip)
    local pos = WoWTokDB.pos
    check("положение окна сохраняется", type(pos) == "table" and pos[1] == "TOPLEFT" and pos[2] == "TOPLEFT" and pos[3] == 50 and pos[4] == -60)

    -- 400 карточек колесом при низком fps (карточка доезжает за один кадр)
    local okAll, bad, kinds = true, nil, {}
    for step = 1, 400 do
        wheel(h, -1, 1, 0.1)
        local i, c = state(h)
        if i ~= 2 + step then okAll, bad = false, "step " .. step .. ": " .. tostring(c) break end
        local v, suf = parse(c.like.count:GetText())
        local cv = parse(c.comment.count:GetText())
        if not v or v < 100 or v > 1.0001e9 or not cv or cv > v or c.title:GetText() ~= "Видео #" .. i then
            okAll, bad = false, "card " .. i .. ": " .. tostring(c.like.count:GetText()) .. " / " .. tostring(c.comment.count:GetText())
            break
        end
        kinds[suf] = true
    end
    check("400 карточек подряд: номера по порядку, лайки от 100 до 1 млрд", okAll, bad)
    check("встречаются и сотни, и тысячи (K), и миллионы (M)", kinds[""] and kinds.K and kinds.M)

    -- формулы напрямую
    local S = __T.Short
    local cases = {
        { 100, "100" }, { 999, "999" }, { 1000, "1K" }, { 1049, "1K" }, { 15300, "15.3K" }, { 999949, "999.9K" },
        { 999950, "1M" }, { 2000000, "2M" }, { 4500000, "4.5M" }, { 999949999, "999.9M" }, { 999950000, "1B" },
        { 1000000000, "1B" }, { 1000000001, "1B" },
    }
    local okShort, badShort = true, nil
    for _, c in ipairs(cases) do
        if S(c[1]) ~= c[2] then okShort, badShort = false, c[1] .. " -> " .. tostring(S(c[1])) end
    end
    check("сокращение чисел (K, M, B)", okShort, badShort)

    local okItems, badItem, decades, lo, hi = true, nil, {}, math.huge, 0
    for i = 1, 30000 do
        local it = __T.Item(i)
        local l = it.likes
        if l < 100 or l > 1000000000 or l ~= math.floor(l) or it.comments < 0 or it.comments > l
            or not it.author or not it.caption or not it.icon then
            okItems, badItem = false, "item " .. i .. ": likes " .. tostring(l)
            break
        end
        local d = math.floor(math.log(l) / math.log(10))
        decades[d] = (decades[d] or 0) + 1
        if l < lo then lo = l end
        if l > hi then hi = l end
    end
    check("30000 карточек: лайки всегда целые, от 100 до 1 000 000 000", okItems, badItem)
    local spread = true
    for d = 2, 8 do
        if (decades[d] or 0) < 30000 * 0.08 then spread = false end
    end
    check("лайки разбросаны по всем порядкам (сотни ... сотни миллионов)", spread, "min " .. lo .. " max " .. hi)
    check("у одной карточки лайки всегда одни и те же", __T.Item(7).likes == __T.Item(7).likes and __T.Item(7).caption == __T.Item(7).caption)

    -- перезагрузка интерфейса: всё сохранённое возвращается
    local saved = WoWTokDB
    boot(saved)
    fire("ADDON_LOADED", "WoWTok")
    SlashCmdList.WOWTOK("")
    h = find()
    idx, card = state(h)
    check("после /reload лента открывается на той же карточке", idx == 402 and saved.index == 402, card)
    local p = WoWTokFrame._points[1]
    check("после /reload окно на сохранённом месте", p.point == "TOPLEFT" and p.rel == UIParent and p.x == 50 and p.y == -60)
    saved.index = 3
    boot(saved)
    fire("ADDON_LOADED", "WoWTok")
    SlashCmdList.WOWTOK("")
    h = find()
    wheel(h, 1)
    idx, card = state(h)
    check("после /reload лайк на #2 на месте",
        idx == 2 and card.like.glow:IsShown() and card.like.icon._desat == false
        and card.like.count:GetText() == __T.Short(__T.Item(2).likes + 1), card)

    -- испорченные сохранения
    for _, case in ipairs({ { { index = "abc" }, 1 }, { { index = -5 }, 1 }, { { index = 3.7 }, 3 }, { {}, 1 } }) do
        boot(case[1])
        fire("ADDON_LOADED", "WoWTok")
        SlashCmdList.WOWTOK("")
        idx = state(find())
        check("сохранения с index=" .. tostring(case[1].index) .. " открываются на #" .. case[2], idx == case[2], idx)
    end

    -- ================= ролики =================
    local function vid(id, frames, sheets, audio, likes, author, caption)
        return { id = id, frames = frames, sheets = sheets, fps = 10, cols = 8, rows = 4, cellW = 256, cellH = 456,
            sheetSize = 2048, audio = audio, likes = likes, comments = 2741, author = author, caption = caption }
    end
    local vids = {
        vid("111", 40, 2, true, 591200, "alice", "первый"),
        vid("222", 20, 1, false, 5, "bob", ""),
        vid("333", 70, 3, true, 1000000, "carol", "третий"),
    }
    local M = "Interface\\AddOns\\WoWTok\\Media\\"
    local function near(a, b) return math.abs(a - b) < 1e-9 end
    local function coordsOf(c, col, row)
        local k, half = c.tex._coords, 0.5 / 2048
        return near(k[1], col * 256 / 2048 + half) and near(k[2], (col + 1) * 256 / 2048 - half)
            and near(k[3], row * 456 / 2048 + half) and near(k[4], (row + 1) * 456 / 2048 - half)
    end

    boot({ format = "blp" }, vids)
    fire("ADDON_LOADED", "WoWTok")
    check("сохранённый формат blp не сбрасывается", WoWTokDB.format == "blp", WoWTokDB.format)
    SlashCmdList.WOWTOK("")
    h = find()
    idx, card = state(h)
    check("ролик: вместо заглушки показано видео",
        idx == 1 and card.tex:IsShown() and not card.title:IsShown() and not card.icon:IsShown() and not card.hint:IsShown(), card)
    check("ролик: первый лист и первый кадр", card.tex._tex == M .. "111\\b001.blp" and coordsOf(card, 0, 0), card.tex._tex)
    check("ролик: следующий лист грузится заранее", card.pre._tex == M .. "111\\b002.blp", card.pre._tex)
    check("ролик: автор, подпись, настоящие лайки и комментарии",
        card.author:GetText() == "@alice" and card.caption:GetText() == "первый"
        and card.like.count:GetText() == "591.2K" and card.comment.count:GetText() == "2.7K", card.like.count:GetText())
    tick(1, 0.01)
    check("ролик: звук запускается с началом ролика", #sounds == 1 and sounds[1] == M .. "111\\a.ogg", sounds[1])
    tick(25, 0.05)     -- прошло 1.25 с: кадр 12 = пятая клетка второго ряда
    check("ролик: через 1.25 с показан кадр 12", card.frame == 12 and coordsOf(card, 4, 1), card.frame)
    tick(40, 0.05)     -- 3.25 с: кадр 32 = первый кадр второго листа
    check("ролик: на кадре 32 включается второй лист",
        card.frame == 32 and card.tex._tex == M .. "111\\b002.blp" and coordsOf(card, 0, 0) and card.pre._tex == M .. "111\\b001.blp", card.tex._tex)
    SlashCmdList.WOWTOK("jpg")
    check("/tiktok jpg переключает кадры на JPEG, не сбивая ролик",
        WoWTokDB.format == "jpg" and card.tex._tex == M .. "111\\j002.jpg" and card.frame == 32 and #printed == 1, card.tex._tex)
    SlashCmdList.WOWTOK(" BLP ")
    check("/tiktok blp возвращает родной формат", WoWTokDB.format == "blp" and card.tex._tex == M .. "111\\b002.blp", card.tex._tex)
    tick(18, 0.05)     -- 4.15 с при длине 4 с: ролик начался заново
    check("ролик: в конце начинается заново вместе со звуком",
        #sounds == 2 and stopped[#stopped] == 1001 and card.frame <= 1 and card.tex._tex == M .. "111\\b001.blp", card.frame)

    local frameBefore = card.frame
    click(card.like)
    check("лайк на ролике не сбивает кадр и хранится по id ролика",
        WoWTokDB.liked["111"] == true and card.frame == frameBefore and card.like.count:GetText() == "591.2K" and card.like.glow:IsShown(),
        card.like.count:GetText())

    swipe(h, 200, 0.4)
    idx, card = state(h)
    check("свайп: следующий ролик, звук прежнего остановлен",
        idx == 2 and card.tex._tex == M .. "222\\b001.blp" and stopped[#stopped] == 1002 and #sounds == 2, card)
    local v2likes = parse(card.like.count:GetText())
    check("ролик без лайков получает выдуманные (не меньше 100), пустая подпись не мешает",
        v2likes and v2likes >= 100 and card.caption:GetText() == "" and card.author:GetText() == "@bob", card.like.count:GetText())
    check("ролик без звука играет молча, кадры идут", card.frame and card.frame >= 1 and #sounds == 2, card.frame)
    wheel(h, -1)
    idx, card = state(h)
    check("третий ролик со звуком", idx == 3 and card.author:GetText() == "@carol" and #sounds == 3 and sounds[3] == M .. "333\\a.ogg", card)
    wheel(h, -1)
    idx, card = state(h)
    check("после последнего ролика лента идёт по кругу: снова первый, лайк на месте",
        idx == 4 and card.author:GetText() == "@alice" and card.like.glow:IsShown() and sounds[#sounds] == M .. "111\\a.ogg", card)

    local nSounds, nStopped = #sounds, #stopped
    click(card.avatar)
    check("ушли в профиль - звук ролика остановлен", #stopped == nStopped + 1 and stopped[#stopped] == 1000 + nSounds)
    tick(20, 0.05)
    check("в профиле ролик не играет", #sounds == nSounds)
    click(h.navFeed)
    tick(1, 0.05)
    check("вернулись в ленту - ролик начинается заново", #sounds == nSounds + 1 and card.frame == 0, card.frame)
    SlashCmdList.WOWTOK("")
    check("закрыли окно - звук остановлен", stopped[#stopped] == 1000 + #sounds and not WoWTokFrame:IsVisible())
    SlashCmdList.WOWTOK("sound")
    SlashCmdList.WOWTOK("")
    nSounds = #sounds
    tick(30, 0.05)
    idx, card = state(h)
    check("/tiktok sound выключает звук, картинка идёт", WoWTokDB.muted == true and #sounds == nSounds and card.frame >= 10, card.frame)
    SlashCmdList.WOWTOK("sound")
    tick(1, 0.05)
    check("/tiktok sound второй раз включает звук", WoWTokDB.muted == nil and #sounds == nSounds + 1)
    SlashCmdList.WOWTOK("чтото")
    check("неизвестная команда показывает подсказку", printed[#printed]:find("команды", 1, true) ~= nil, printed[#printed])

    -- ролик, у которого есть только один формат
    local only = vid("444", 40, 2, false, 1000, "dave", "")
    only.formats = { "jpg" }
    boot({ format = "blp" }, { only })
    fire("ADDON_LOADED", "WoWTok")
    SlashCmdList.WOWTOK("")
    h = find()
    idx, card = state(h)
    check("ролик только в jpg показывается в jpg, даже если выбран blp",
        card.tex._tex == M .. "444\\j001.jpg" and card.pre._tex == M .. "444\\j002.jpg", card.tex._tex)
    SlashCmdList.WOWTOK("jpg")
    SlashCmdList.WOWTOK("blp")
    check("переключение формата не ломает ролик с одним форматом", card.tex._tex == M .. "444\\j001.jpg", card.tex._tex)

    -- настоящий список роликов из videos.lua
    if REAL_VIDEOS_SRC then
        local nsReal = {}
        assert(load(REAL_VIDEOS_SRC, "=videos.lua"))("WoWTok", nsReal)
        local list = nsReal.videos or {}
        local okReal, badReal = #list > 0, nil
        for _, v in ipairs(list) do
            if type(v.id) ~= "string" or v.frames < 1 or v.sheets ~= math.ceil(v.frames / (v.cols * v.rows))
                or v.cols * v.cellW > v.sheetSize or v.rows * v.cellH > v.sheetSize
                or type(v.author) ~= "string" or type(v.caption) ~= "string" then
                okReal, badReal = false, v.id
            end
        end
        check("videos.lua: роликов " .. #list .. ", данные согласованы", okReal, badReal)
        boot(nil, list)
        fire("ADDON_LOADED", "WoWTok")
        SlashCmdList.WOWTOK("")
        h = find()
        local v1 = list[1]
        tick(1, 0.01)
        tick(math.floor((v1.frames / v1.fps - 0.3) / 0.05), 0.05)
        idx, card = state(h)
        check("videos.lua: первый ролик доигрывает до последнего листа",
            card.tex._tex == M .. v1.id .. "\\j" .. string.format("%03d", v1.sheets) .. ".jpg" and card.frame >= v1.frames - 6, card.tex._tex)
        local okFmt = true
        for _, v in ipairs(list) do
            if type(v.formats) ~= "table" or v.formats[1] ~= "jpg" or #v.formats ~= 1 then okFmt = false end
        end
        check("videos.lua: у всех роликов только jpg", okFmt)
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    fails = fails + 1
    out[#out + 1] = "ERROR " .. tostring(err)
end
out[#out + 1] = string.format("RESULT: %d checks, %d failed", total, fails)
return table.concat(out, "\n")
