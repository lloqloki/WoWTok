-- WoWTok: лента в стиле TikTok в окне WoW. Открыть окно: /tiktok
-- Ролики лежат в Media\<id>\ как листы кадров и звук (их делает tools/convert.py),
-- список роликов - в videos.lua. Если роликов нет, лента показывает карточки-заглушки.

local ADDON, ns = ...
local videos = ns and ns.videos

-- Листы кадров есть в двух форматах; переключается командой /tiktok blp или /tiktok jpg
local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
local FORMATS = {
    blp = { prefix = "b", ext = ".blp" },
    jpg = { prefix = "j", ext = ".jpg" },
}
local DEFAULT_FORMAT = "jpg"

-- Размеры окна и ленты (лента 9:16, как вертикальное видео)
local WIN_W, WIN_H = 340, 618
local PAD_X, PAD_TOP, PAD_BOTTOM = 18, 34, 50
local FEED_W = WIN_W - PAD_X * 2 - 8
local FEED_H = WIN_H - PAD_TOP - PAD_BOTTOM - 8

-- Свайп
local SWIPE_MIN = 0.18                  -- доля высоты ленты, после которой карточка перелистывается
local FLICK_PX, FLICK_SEC = 24, 0.25    -- короткий быстрый рывок тоже листает
local SLIDE_SPEED = 12                  -- скорость доезда карточки
local DOUBLE_CLICK = 0.4                -- двойной клик по ролику ставит лайк

-- Лайки: от 100 до 1 000 000 000
local LIKES_MIN, LIKES_MAX = 100, 1000000000

local AUTHORS = {
    "Тралл", "Джайна", "Хоггер", "Сильвана", "Лирой", "Чен", "Иллидан", "Рагнарос",
    "Ониксия", "Вол'джин", "Кэрн", "Тиранда", "Утер", "Мурчаль", "Нефариан", "Гаррош",
}

local CAPTIONS = {
    "когда танк пуллит, а хил ещё пьёт #вов #подземелье",
    "POV: ты выиграл ролл на эпик у гильдмастера #ролл #лут",
    "фармлю репутацию, день 47 #фарм #гринд",
    "показываю самый быстрый маршрут по Тернистой долине #гайд",
    "этот босс сломал нам рейд #рейд #вайп",
    "рыбалка в 4 утра ради одной рыбы #рыбалка",
    "мой первый маунт на 40 уровне #маунт #золото",
    "никогда не делай так на поле боя #пвп",
    "собрал полный сет, смотрите #шмот #трансмог",
    "как я потерял 200 золота на аукционе #аукцион",
    "хантер опять забрал мой лут #хантерлут",
    "тот самый момент с Лироем #мем #классика",
}

local ICONS = {
    "Interface\\Icons\\INV_Misc_QuestionMark",
    "Interface\\Icons\\Ability_Warrior_Charge",
    "Interface\\Icons\\Spell_Fire_Fireball02",
    "Interface\\Icons\\INV_Misc_Head_Dragon_01",
    "Interface\\Icons\\Spell_Nature_Polymorph",
    "Interface\\Icons\\INV_Misc_Fish_02",
    "Interface\\Icons\\Spell_Shadow_DeathCoil",
    "Interface\\Icons\\INV_Sword_39",
    "Interface\\Icons\\Ability_Hunter_BeastCall",
    "Interface\\Icons\\Spell_Holy_Resurrection",
    "Interface\\Icons\\INV_Misc_Coin_01",
    "Interface\\Icons\\INV_Drink_05",
    "Interface\\Icons\\Ability_Mount_RidingHorse",
    "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
}

local ICON_LIKE = "Interface\\Icons\\INV_ValentinesCandy"
local ICON_COMMENT = "Interface\\Icons\\INV_Misc_Note_01"
local WHITE = "Interface\\Buttons\\WHITE8X8"

local db
local frame, feed, profile, navFeed, navProfile
local cards = {}     -- cards[1] на экране, cards[2] соседняя (следующая или предыдущая)
local index = 1      -- номер карточки на экране
local offset = 0     -- сдвиг ленты в пикселях, вверх = плюс
local target         -- куда доезжает лента после свайпа; nil = стоит на месте
local drag           -- текущий свайп: { y = где нажали, t = когда }
local lastClick
local play           -- что сейчас играет: { index = карточка, start = когда начали, handle = звук }

-- Случайное число 0..1, зависящее только от номера карточки:
-- у одной и той же карточки лайки и подпись всегда одинаковые.
local function Rand(seed, salt)
    local x = (seed * 7919 + salt * 104729) % 2147483647
    if x == 0 then x = 1 end
    for _ = 1, 3 do x = (x * 16807) % 2147483647 end
    return x / 2147483647
end

local function Pick(list, seed, salt)
    return list[1 + math.floor(Rand(seed, salt) * #list)]
end

-- Данные карточки i. Если есть ролики, лента крутит их по кругу; иначе это заглушка.
local function Item(i)
    local v, seed = nil, i
    if videos and #videos > 0 then
        seed = ((i - 1) % #videos) + 1
        v = videos[seed]
    end
    -- у ролика берём настоящие лайки; если их нет, выдумываем:
    -- степень от 2 до 9, числа равномерно разбросаны от сотен до миллиарда
    local likes = v and v.likes or 0
    if likes < LIKES_MIN then likes = math.floor(10 ^ (2 + 7 * Rand(seed, 1))) end
    likes = math.max(LIKES_MIN, math.min(LIKES_MAX, likes))
    if v then
        return {
            key = v.id, video = v, likes = likes, comments = v.comments or 0,
            author = v.author or "tiktok", caption = v.caption or "", r = 0, g = 0, b = 0,
        }
    end
    return {
        key = i,
        likes = likes,
        comments = math.floor(likes * (0.002 + 0.02 * Rand(i, 2))),
        author = Pick(AUTHORS, i, 3),
        caption = Pick(CAPTIONS, i, 4),
        icon = Pick(ICONS, i, 5),
        r = 0.05 + 0.15 * Rand(i, 6),
        g = 0.05 + 0.15 * Rand(i, 7),
        b = 0.05 + 0.15 * Rand(i, 8),
    }
end

-- 950 -> "950", 15300 -> "15.3K", 2000000 -> "2M", 1000000000 -> "1B"
local function Short(n)
    if n < 1000 then return tostring(n) end
    local value, suffix
    if n >= 999950000 then value, suffix = n / 1e9, "B"
    elseif n >= 999950 then value, suffix = n / 1e6, "M"
    else value, suffix = n / 1e3, "K" end
    local text = string.format("%.1f", value):gsub("%.0$", "")
    return text .. suffix
end

local function Sound(name, fallback)
    local id = SOUNDKIT and SOUNDKIT[name] or fallback
    if id then pcall(PlaySound, id) end
end

local function Tooltip(button, text)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(text)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function LikedCount()
    local n = 0
    for _ in pairs(db.liked) do n = n + 1 end
    return n
end

local function RefreshProfile()
    if not profile then return end
    SetPortraitTexture(profile.portrait, "player")
    local className, class = UnitClass("player")
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    profile.name:SetText(UnitName("player") or "?")
    if color then profile.name:SetTextColor(color.r, color.g, color.b) end
    local race = UnitRace("player")
    profile.info:SetText(string.format("Уровень %d, %s, %s", UnitLevel("player") or 0, race or "?", className or "?"))
    local guild = GetGuildInfo("player")
    profile.guild:SetText(guild and ("<" .. guild .. ">") or (GetRealmName() or ""))
    profile.stats[3].value:SetText(Short(LikedCount()))
end

-- Формат листов ролика: выбранный командой, если он у ролика есть, иначе первый из имеющихся
local function FormatOf(v)
    if not v.formats then return db.format end
    for _, name in ipairs(v.formats) do
        if name == db.format then return name end
    end
    return v.formats[1]
end

local function SheetPath(v, sheet)
    local f = FORMATS[FormatOf(v)] or FORMATS[DEFAULT_FORMAT]
    return MEDIA .. v.id .. "\\" .. f.prefix .. string.format("%03d", sheet + 1) .. f.ext
end

-- Показывает на карточке кадр f ролика (счёт с нуля): нужный лист и нужную клетку на нём
local function ShowFrame(card, f)
    local v = card.video
    local perSheet = v.cols * v.rows
    local sheet = math.floor(f / perSheet)
    if card.sheet ~= sheet then
        card.sheet = sheet
        card.tex:SetTexture(SheetPath(v, sheet))
        -- следующий лист грузим заранее, чтобы на стыке листов картинка не моргала
        card.pre:SetTexture(SheetPath(v, (sheet + 1) % v.sheets))
    end
    local k = f % perSheet
    local col, row = k % v.cols, math.floor(k / v.cols)
    local size, half = v.sheetSize, 0.5 / v.sheetSize   -- полпикселя внутрь: соседние кадры не подмешиваются
    card.tex:SetTexCoord(col * v.cellW / size + half, (col + 1) * v.cellW / size - half,
        row * v.cellH / size + half, (row + 1) * v.cellH / size - half)
    card.frame = f
end

local function RefreshLike(card)
    local it = card.item
    local liked = db.liked[it.key] and true or false
    card.like.count:SetText(Short(it.likes + (liked and 1 or 0)))
    card.like.icon:SetDesaturated(not liked)
    card.like.glow:SetShown(liked)
end

-- Заполняет карточку данными ролика с номером i
local function Fill(card, i)
    local it = Item(i)
    local isVideo = it.video ~= nil
    card.index, card.item, card.video = i, it, it.video
    card.bg:SetColorTexture(it.r, it.g, it.b, 1)
    card.tex:SetShown(isVideo)
    card.pre:SetShown(isVideo)
    card.icon:SetShown(not isVideo)
    card.slot:SetShown(not isVideo)
    card.title:SetShown(not isVideo)
    card.hint:SetShown(not isVideo)
    if isVideo then
        card.sheet = nil
        ShowFrame(card, 0)
    else
        card.icon:SetTexture(it.icon)
        card.title:SetText("Видео #" .. i)
    end
    card.author:SetText("@" .. it.author)
    card.caption:SetText(it.caption)
    card.sound:SetText("оригинальный звук - " .. it.author)
    card.comment.count:SetText(Short(it.comments))
    RefreshLike(card)
    SetPortraitTexture(card.avatar.portrait, "player")
end

local function ToggleLike(card, onlyOn)
    local key = card.item.key
    if onlyOn and db.liked[key] then return end
    db.liked[key] = (not db.liked[key]) or nil
    RefreshLike(card)
    Sound("IG_MAINMENU_OPTION_CHECKBOX_ON", 856)
    if profile and profile:IsShown() then RefreshProfile() end
end

local function StopPlayback()
    if play and play.handle then pcall(StopSound, play.handle) end
    play = nil
end

local function StartSound(v)
    if not v.audio or db.muted then return nil end
    local ok, willPlay, handle = pcall(PlaySoundFile, MEDIA .. v.id .. "\\a.ogg", "Master")
    return ok and willPlay and handle or nil
end

-- Вызывается каждый кадр игры: двигает ролик на текущей карточке по времени
local function UpdateVideo()
    local card = cards[1]
    local v = card.video
    if not v then
        if play then StopPlayback() end
        return
    end
    local now = GetTime()
    if not play or play.index ~= index then    -- перелистнули или лента только что открылась
        StopPlayback()
        play = { index = index, start = now, handle = StartSound(v) }
    end
    local t = now - play.start
    if t >= v.frames / v.fps then               -- ролик кончился: заново, как в TikTok
        if play.handle then pcall(StopSound, play.handle) end
        play.start, play.handle, t = now, StartSound(v), 0
    end
    local f = math.min(v.frames - 1, math.floor(t * v.fps))
    if f ~= card.frame then ShowFrame(card, f) end
end

-- Расставляет карточки по текущему сдвигу ленты
local function Layout()
    local cur, other = cards[1], cards[2]
    cur:ClearAllPoints()
    cur:SetPoint("TOPLEFT", feed, "TOPLEFT", 0, offset)
    local neighbor
    if offset > 0 then neighbor = index + 1
    elseif offset < 0 and index > 1 then neighbor = index - 1 end
    if neighbor then
        if other.index ~= neighbor then Fill(other, neighbor) end
        other:ClearAllPoints()
        other:SetPoint("TOPLEFT", feed, "TOPLEFT", 0, offset > 0 and offset - FEED_H or offset + FEED_H)
        other:Show()
    else
        other:Hide()
    end
end

-- Лента доехала: если перелистнули, соседняя карточка становится текущей
local function Settle()
    if target == FEED_H then
        index = index + 1
        cards[1], cards[2] = cards[2], cards[1]
    elseif target == -FEED_H then
        index = index - 1
        cards[1], cards[2] = cards[2], cards[1]
    end
    offset, target = 0, nil
    db.index = index
    if cards[1].index ~= index then Fill(cards[1], index) end
    cards[1]:Show()
    Layout()
end

local function CursorY()
    local _, y = GetCursorPosition()
    return y / feed:GetEffectiveScale()
end

local function EndDrag()
    local held = GetTime() - drag.t
    local moved = offset
    drag = nil
    local flick = held < FLICK_SEC and math.abs(moved) > FLICK_PX
    if moved > FEED_H * SWIPE_MIN or (flick and moved > 0) then
        target = FEED_H
    elseif index > 1 and (moved < -FEED_H * SWIPE_MIN or (flick and moved < 0)) then
        target = -FEED_H
    else
        target = 0
    end
    -- без движения это клик; два клика подряд ставят лайк
    if math.abs(moved) < 4 and held < 0.3 then
        local now = GetTime()
        if lastClick and now - lastClick < DOUBLE_CLICK then
            lastClick = nil
            ToggleLike(cards[1], true)
        else
            lastClick = now
        end
    end
end

local function OnFeedUpdate(_, elapsed)
    UpdateVideo()
    if drag then
        if not IsMouseButtonDown("LeftButton") then EndDrag() return end
        local d = CursorY() - drag.y
        if d < 0 and index == 1 then d = d * 0.25 end   -- выше первой карточки ничего нет: тянется туго
        offset = math.max(-FEED_H, math.min(FEED_H, d))
        Layout()
    elseif target then
        offset = offset + (target - offset) * math.min(1, elapsed * SLIDE_SPEED)
        if math.abs(target - offset) < 1 then Settle() else Layout() end
    end
end

local function StopMotion()
    drag = nil
    if target then
        offset = target
        Settle()
    elseif offset ~= 0 then
        offset = 0
        Layout()
    end
end

local function IconButton(parent, texture, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexture(texture)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetSize(size * 66 / 36, size * 66 / 36)
    border:SetPoint("CENTER", 0, -1)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.count:SetPoint("TOP", b, "BOTTOM", 0, -3)
    return b
end

local function ShowPage(name)
    local isFeed = name ~= "profile"
    feed:SetShown(isFeed)
    profile:SetShown(not isFeed)
    navFeed:SetEnabled(not isFeed)
    navProfile:SetEnabled(isFeed)
    if not isFeed then RefreshProfile() end
end

local function MakeCard()
    local c = CreateFrame("Frame", nil, feed)
    c:SetSize(FEED_W, FEED_H)

    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()

    -- видео: кадр из листа, растянутый на всю карточку (лежит под затемнением и подписями)
    c.pre = c:CreateTexture(nil, "BACKGROUND", nil, 1)   -- точка под видео: заранее грузит следующий лист
    c.pre:SetSize(1, 1)
    c.pre:SetPoint("CENTER")
    c.tex = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.tex:SetAllPoints()

    -- заглушка на случай, когда роликов нет
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(72, 72)
    c.icon:SetPoint("CENTER", 0, 50)
    c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    c.slot = c:CreateTexture(nil, "OVERLAY")
    c.slot:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    c.slot:SetSize(132, 132)
    c.slot:SetPoint("CENTER", c.icon, "CENTER", 0, -2)
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.title:SetPoint("TOP", c.icon, "BOTTOM", 0, -14)
    c.hint = c:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    c.hint:SetPoint("TOP", c.title, "BOTTOM", 0, -6)
    c.hint:SetText("Здесь будет ролик")

    -- затемнение под подписью
    local shade = c:CreateTexture(nil, "BORDER")
    shade:SetPoint("BOTTOMLEFT")
    shade:SetPoint("BOTTOMRIGHT")
    shade:SetHeight(120)
    shade:SetColorTexture(0, 0, 0, 0.45)

    -- слева внизу: автор, подпись, звук
    c.sound = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.sound:SetPoint("BOTTOMLEFT", 12, 12)
    c.sound:SetWidth(FEED_W - 80)
    c.sound:SetJustifyH("LEFT")
    c.caption = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.caption:SetPoint("BOTTOMLEFT", c.sound, "TOPLEFT", 0, 6)
    c.caption:SetWidth(FEED_W - 80)
    c.caption:SetJustifyH("LEFT")
    c.author = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.author:SetPoint("BOTTOMLEFT", c.caption, "TOPLEFT", 0, 6)

    -- справа внизу: комментарии, над ними лайк, над ним аватар
    c.comment = IconButton(c, ICON_COMMENT, 40)
    c.comment:SetPoint("BOTTOMRIGHT", -14, 34)
    c.comment:SetScript("OnClick", function()
        UIErrorsFrame:AddMessage("Комментарии пока недоступны.", 1.0, 0.1, 0.1, 1.0)
    end)
    Tooltip(c.comment, "Комментарии")

    c.like = IconButton(c, ICON_LIKE, 40)
    c.like:SetPoint("BOTTOM", c.comment, "TOP", 0, 30)
    c.like.glow = c.like:CreateTexture(nil, "OVERLAY")
    c.like.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    c.like.glow:SetBlendMode("ADD")
    c.like.glow:SetAllPoints()
    c.like:SetScript("OnClick", function() ToggleLike(c) end)
    Tooltip(c.like, "Нравится")

    c.avatar = CreateFrame("Button", nil, c)
    c.avatar:SetSize(44, 44)
    c.avatar:SetPoint("BOTTOM", c.like, "TOP", 0, 18)
    c.avatar.portrait = c.avatar:CreateTexture(nil, "ARTWORK")
    c.avatar.portrait:SetAllPoints()
    c.avatar:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    c.avatar:SetScript("OnClick", function() ShowPage("profile") end)
    Tooltip(c.avatar, "Профиль")

    return c
end

local function MakeProfile(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetPoint("TOPLEFT", 4, -4)
    p:SetPoint("BOTTOMRIGHT", -4, 4)
    p:Hide()

    p.portrait = p:CreateTexture(nil, "ARTWORK")
    p.portrait:SetSize(72, 72)
    p.portrait:SetPoint("TOP", 0, -22)
    p.name = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.name:SetPoint("TOP", p.portrait, "BOTTOM", 0, -10)
    p.info = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.info:SetPoint("TOP", p.name, "BOTTOM", 0, -6)
    p.guild = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    p.guild:SetPoint("TOP", p.info, "BOTTOM", 0, -4)

    -- три счётчика в ряд
    p.stats = {}
    local labels = { "Подписки", "Подписчики", "Понравилось" }
    local cell = FEED_W / 3
    for n = 1, 3 do
        local s = {}
        s.value = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        s.value:SetPoint("TOP", p, "TOPLEFT", cell * (n - 0.5), -178)
        s.value:SetText("0")
        s.label = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        s.label:SetPoint("TOP", s.value, "BOTTOM", 0, -3)
        s.label:SetText(labels[n])
        p.stats[n] = s
    end

    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.35)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 12, -226)
    line:SetPoint("TOPRIGHT", -12, -226)

    -- заглушка
    local icon = p:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    icon:SetSize(56, 56)
    icon:SetPoint("TOP", 0, -276)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetDesaturated(true)
    icon:SetAlpha(0.7)
    local head = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    head:SetPoint("TOP", icon, "BOTTOM", 0, -14)
    head:SetText("Здесь пока пусто")
    local text = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    text:SetPoint("TOP", head, "BOTTOM", 0, -8)
    text:SetWidth(FEED_W - 40)
    text:SetText("Профиль в разработке. Ваши ролики появятся здесь позже.")

    return p
end

local function Build()
    frame = CreateFrame("Frame", "WoWTokFrame", UIParent, "BackdropTemplate")
    frame:Hide()   -- новое окно сразу видимо; прячем, чтобы первое открытие прошло как обычное (со звуком)
    frame:SetSize(WIN_W, WIN_H)
    local pos = db.pos
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("CENTER")
    end
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetToplevel(true)
    frame:SetScript("OnShow", function() Sound("IG_CHARACTER_INFO_OPEN", 839) end)
    frame:SetScript("OnHide", function() Sound("IG_CHARACTER_INFO_CLOSE", 840) end)
    tinsert(UISpecialFrames, "WoWTokFrame")   -- закрывается по Esc

    -- шапка как у диалоговых окон WoW
    local header = frame:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetSize(256, 64)
    header:SetPoint("TOP", 0, 12)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    title:SetText("WoWTok")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- окно двигается за шапку: остальная площадь занята свайпами
    local grip = CreateFrame("Frame", nil, frame)
    grip:SetPoint("TOPLEFT", 0, 12)
    grip:SetPoint("TOPRIGHT", -32, 12)
    grip:SetHeight(44)
    grip:EnableMouse(true)
    grip:RegisterForDrag("LeftButton")
    grip:SetScript("OnDragStart", function() frame:StartMoving() end)
    grip:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint(1)
        db.pos = { point, relPoint, x, y }
    end)

    -- рамка вокруг ленты
    local inset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    inset:SetPoint("TOPLEFT", PAD_X, -PAD_TOP)
    inset:SetPoint("BOTTOMRIGHT", -PAD_X, PAD_BOTTOM)
    inset:SetBackdrop({
        bgFile = WHITE,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    inset:SetBackdropColor(0, 0, 0, 1)
    inset:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    feed = CreateFrame("Frame", nil, inset)
    feed:SetPoint("TOPLEFT", 4, -4)
    feed:SetPoint("BOTTOMRIGHT", -4, 4)
    if feed.SetClipsChildren then feed:SetClipsChildren(true) end
    feed:EnableMouse(true)
    feed:EnableMouseWheel(true)
    feed:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        StopMotion()
        drag = { y = CursorY(), t = GetTime() }
    end)
    feed:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and drag then EndDrag() end
    end)
    feed:SetScript("OnMouseWheel", function(_, delta)
        if drag or target then return end
        if delta < 0 then target = FEED_H
        elseif index > 1 then target = -FEED_H end
    end)
    feed:SetScript("OnUpdate", OnFeedUpdate)
    feed:SetScript("OnHide", function()
        StopMotion()
        StopPlayback()   -- ушли из ленты или закрыли окно: звук выключается
    end)

    cards[1], cards[2] = MakeCard(), MakeCard()
    profile = MakeProfile(inset)

    -- нижние кнопки
    local navW = (WIN_W - PAD_X * 2 - 6) / 2
    navFeed = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    navFeed:SetSize(navW, 22)
    navFeed:SetPoint("BOTTOMLEFT", PAD_X, 20)
    navFeed:SetText("Лента")
    navFeed:SetScript("OnClick", function() ShowPage("feed") end)
    navProfile = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    navProfile:SetSize(navW, 22)
    navProfile:SetPoint("BOTTOMRIGHT", -PAD_X, 20)
    navProfile:SetText("Профиль")
    navProfile:SetScript("OnClick", function() ShowPage("profile") end)

    Fill(cards[1], index)
    Layout()
    ShowPage("feed")
end

local function Toggle()
    if not db then return end
    if not frame then
        Build()
        frame:Show()
    else
        frame:SetShown(not frame:IsShown())
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("UNIT_PORTRAIT_UPDATE")
events:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg ~= ADDON then return end
        WoWTokDB = WoWTokDB or {}
        db = WoWTokDB
        db.liked = db.liked or {}
        if not FORMATS[db.format] then db.format = DEFAULT_FORMAT end
        index = math.max(1, math.floor(tonumber(db.index) or 1))
    elseif arg == "player" and frame then
        SetPortraitTexture(cards[1].avatar.portrait, "player")
        SetPortraitTexture(cards[2].avatar.portrait, "player")
        RefreshProfile()
    end
end)

local function Say(text)
    print("|cffffd100WoWTok:|r " .. text)
end

-- /tiktok - открыть или закрыть; /tiktok blp, /tiktok jpg - формат кадров; /tiktok sound - звук роликов
local function Slash(msg)
    msg = string.lower(msg or ""):match("^%s*(.-)%s*$")
    if msg == "" then
        Toggle()
    elseif not db then
        return
    elseif FORMATS[msg] then
        db.format = msg
        for _, card in ipairs(cards) do
            if card.video then
                card.sheet = nil
                ShowFrame(card, card.frame or 0)
            end
        end
        Say("формат кадров - " .. msg)
    elseif msg == "sound" or msg == "звук" then
        db.muted = (not db.muted) or nil
        StopPlayback()   -- ролик начнётся заново, уже с новым режимом звука
        Say(db.muted and "звук роликов выключен" or "звук роликов включён")
    else
        Say("команды: /tiktok, /tiktok blp, /tiktok jpg, /tiktok sound")
    end
end

SLASH_WOWTOK1 = "/tiktok"
SLASH_WOWTOK2 = "/тикток"
SLASH_WOWTOK3 = "/wowtok"
SlashCmdList["WOWTOK"] = Slash
