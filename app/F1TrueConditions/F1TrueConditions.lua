-- F1 True Conditions v2.0 — real F1 session conditions as Pure Planner presets
--
-- Auto mode (default on for VRC Formula Alpha cars):
--   * At session load the app writes the matching plan to Pure Planner's Plans\last_used.json
--     BEFORE Pure Planner starts (apps load alphabetically: F1TrueConditions < PurePlanner). With the
--     Pure controller set to "Load last used plan" (Content Manager default) Pure Planner then
--     starts on it natively.
--   * Hotlap / practice / qualifying → the real Qualifying session. Race → the real Race.
--   * When the AC session changes (practice → qualifying → race weekend) the new plan is pushed to
--     Pure Planner through its controller state and confirmed by reading back Pure's live air temp.
-- Pit window ("F1 Weather — Pits"): shown in the setup screen while in the pits.

local APP_DIR     = ac.dirname()
local DB_BUNDLED  = APP_DIR .. '\\data\\f1_weather_db.csv'
local DB_CACHE    = APP_DIR .. '\\data\\f1_weather_db_online.csv'
local SEG_BUNDLED = APP_DIR .. '\\data\\f1_weather_segments.csv'       -- Q1/Q2/Q3 conditions
local SEG_CACHE   = APP_DIR .. '\\data\\f1_weather_segments_online.csv'
local OVR_BUNDLED = APP_DIR .. '\\data\\f1_weather_overrides.csv'      -- hand-made visual corrections
local OVR_CACHE   = APP_DIR .. '\\data\\f1_weather_overrides_online.csv'
-- URL of the shared database everyone downloads (one line; set by the mod author in data\\db_url.txt)
local OFFICIAL_URL = ((io.load(APP_DIR .. '\\data\\db_url.txt', '') or ''):match('^%s*(%S+)') or '')
if OFFICIAL_URL:find('YOUR_', 1, true) then OFFICIAL_URL = '' end   -- placeholder not filled in yet
local PLANS_DIR   = ac.getFolder(ac.FolderID.ExtRoot) .. '\\config-ext\\PurePlanner\\Plans\\'
local LAST_USED   = PLANS_DIR .. 'last_used.json'
local SUBFOLDER   = 'F1 True Conditions'
-- the app was called "F1 Real Weather" before v1.9: both installed = two apps fighting over Pure Planner
local OLD_APP = (function()
  local ok, found = pcall(function()
    return io.fileExists(ac.getFolder(ac.FolderID.ACAppsLua) .. '\\F1RealWeather\\F1RealWeather.lua')
  end)
  return ok and found == true
end)()
local OLD_APP_MSG = 'Old "F1 Real Weather" app found: delete apps\\lua\\F1RealWeather'

local CAR_ID = ''
-- qualifying tyre grip per segment (Q1 / Q2 / Q3), fixed in release builds
local TYRE_PCT = { 95, 98, 100 }
local grip, gripUpdate, reloadTrack
local pitAllowed, drawWatermark
local tyre = { applied = 0, t = 1, text = '', pct = 100, seg = nil }   -- live tyre grip per Q segment
local trackKnown = false        -- the loaded AC track matches an F1 circuit (else the app is off for this load)
pcall(function() CAR_ID = (ac.getCarID(0) or ''):lower() end)

local settings = ac.storage({
  dbUrl       = '',            -- personal override; empty = use data\\db_url.txt
  autoUpdate  = true,          -- download the shared database at every start
  realTime    = true,          -- Stamp plan at the real local start time (else Daycycle, keeps sim time)
  autoDetect  = true,          -- select circuit from the loaded AC track
  autoTrigger = true,          -- manual Apply also pushes the plan into Pure Planner
  autoApply   = true,          -- apply automatically at load / session change
  autoAnyCar  = false,         -- false: only for cars whose id contains carFilter
  carFilter   = 'vrc_formula_alpha',
  autoYear    = 0,             -- 0 = latest season available for the circuit
  pitPanel    = true,          -- show the weather panel in the pit / setup screen
  pitX        = 40,
  pitY        = 160,
  pitSize     = 1.0,
  watermark   = true,          -- 'F1 True Conditions running' watermark at the top of the screen
  watermarkAlpha = 0.45,
  qSeg        = 1,             -- qualifying segment to use: 1 = Q1, 2 = Q2, 3 = Q3           -- personal size multiplier on top of screen-resolution scaling
})

---------------------------------------------------------------------------------------------------
-- Circuits: OpenF1 circuit name → display name + keywords to match AC track folder names
---------------------------------------------------------------------------------------------------
local CIRCUITS = {
  ['Sakhir']             = { 'Bahrain',        { 'bahrain', 'sakhir' } },
  ['Jeddah']             = { 'Jeddah',         { 'jeddah', 'saudi' } },
  ['Melbourne']          = { 'Melbourne',      { 'melbourne', 'albert', 'albertpark' } },
  ['Shanghai']           = { 'Shanghai',       { 'shanghai', 'china' } },
  ['Suzuka']             = { 'Suzuka',         { 'suzuka' } },
  ['Miami']              = { 'Miami',          { 'miami' } },
  ['Imola']              = { 'Imola',          { 'imola' } },
  ['Monte Carlo']        = { 'Monaco',         { 'monaco', 'monte' } },
  ['Catalunya']          = { 'Barcelona',      { 'barcelona', 'catalunya', 'montmelo' } },
  ['Montreal']           = { 'Montreal',       { 'montreal', 'villeneuve', 'canada' } },
  ['Spielberg']          = { 'Red Bull Ring',  { 'spielberg', 'redbull', 'red_bull', 'rbr', 'austria' } },
  ['Silverstone']        = { 'Silverstone',    { 'silverstone' } },
  ['Hungaroring']        = { 'Hungaroring',    { 'hungaroring', 'hungary' } },
  ['Spa-Francorchamps']  = { 'Spa',            { 'spa', 'francorchamps' } },
  ['Zandvoort']          = { 'Zandvoort',      { 'zandvoort' } },
  ['Monza']              = { 'Monza',          { 'monza' } },
  ['Baku']               = { 'Baku',           { 'baku', 'azerbaijan' } },
  ['Singapore']          = { 'Singapore',      { 'singapore', 'marina_bay', 'marinabay' } },
  ['Austin']             = { 'Austin (COTA)',  { 'austin', 'cota', 'americas' } },
  ['Mexico City']        = { 'Mexico City',    { 'mexico', 'hermanos' } },
  ['Interlagos']         = { 'Interlagos',     { 'interlagos', 'sao_paulo', 'saopaulo', 'brazil' } },
  ['Las Vegas']          = { 'Las Vegas',      { 'vegas' } },
  ['Lusail']             = { 'Lusail',         { 'lusail', 'losail', 'qatar' } },
  ['Yas Marina Circuit'] = { 'Abu Dhabi',      { 'yas', 'abu_dhabi', 'abudhabi' } },
  ['Madring']            = { 'Madrid',         { 'madring', 'madrid' } },
  ['Kuala Lumpur']       = { 'Sepang',         { 'sepang', 'malaysia', 'kuala' } },
}

-- country flags: AC ships them as content\gui\NationFlags\<ISO3>.png (48×48, flag in the middle)
local CIRCUIT_ISO = {
  ['Sakhir'] = 'BHR', ['Jeddah'] = 'SAU', ['Melbourne'] = 'AUS', ['Shanghai'] = 'CHN', ['Suzuka'] = 'JPN',
  ['Miami'] = 'USA', ['Imola'] = 'ITA', ['Monte Carlo'] = 'MCO', ['Catalunya'] = 'ESP', ['Montreal'] = 'CAN',
  ['Spielberg'] = 'AUT', ['Silverstone'] = 'GBR', ['Hungaroring'] = 'HUN', ['Spa-Francorchamps'] = 'BEL',
  ['Zandvoort'] = 'NLD', ['Monza'] = 'ITA', ['Baku'] = 'AZE', ['Singapore'] = 'SGP', ['Austin'] = 'USA',
  ['Mexico City'] = 'MEX', ['Interlagos'] = 'BRA', ['Las Vegas'] = 'USA', ['Lusail'] = 'QAT',
  ['Yas Marina Circuit'] = 'ARE', ['Madring'] = 'ESP', ['Kuala Lumpur'] = 'MYS',
}
-- fallback for circuits added later: OpenF1 country name → ISO3
local COUNTRY_ISO = {
  ['Bahrain'] = 'BHR', ['Saudi Arabia'] = 'SAU', ['Australia'] = 'AUS', ['China'] = 'CHN', ['Japan'] = 'JPN',
  ['United States'] = 'USA', ['Italy'] = 'ITA', ['Monaco'] = 'MCO', ['Spain'] = 'ESP', ['Canada'] = 'CAN',
  ['Austria'] = 'AUT', ['United Kingdom'] = 'GBR', ['Great Britain'] = 'GBR', ['Hungary'] = 'HUN',
  ['Belgium'] = 'BEL', ['Netherlands'] = 'NLD', ['Azerbaijan'] = 'AZE', ['Singapore'] = 'SGP', ['Mexico'] = 'MEX',
  ['Brazil'] = 'BRA', ['Qatar'] = 'QAT', ['United Arab Emirates'] = 'ARE', ['Malaysia'] = 'MYS',
  ['Portugal'] = 'PRT', ['Turkey'] = 'TUR', ['Germany'] = 'DEU', ['France'] = 'FRA', ['South Africa'] = 'ZAF',
  ['Argentina'] = 'ARG', ['Korea'] = 'KOR', ['India'] = 'IND', ['Russia'] = 'RUS', ['Thailand'] = 'THA',
}
local FLAG_DIR = ''
pcall(function() FLAG_DIR = ac.getFolder(ac.FolderID.Root) .. '\\content\\gui\\NationFlags\\' end)
local flagCache = {}
local function flagPath(circuit, country)
  local key = tostring(circuit) .. '|' .. tostring(country)
  if flagCache[key] == nil then
    local iso = CIRCUIT_ISO[circuit or ''] or COUNTRY_ISO[country or '']
    local path = iso and FLAG_DIR ~= '' and (FLAG_DIR .. iso .. '.png') or false
    if path and not pcall(function() if not io.fileExists(path) then error('missing') end end) then path = false end
    flagCache[key] = path
  end
  return flagCache[key] or nil
end

local function displayName(circuit)
  local c = CIRCUITS[circuit]
  return c and c[1] or circuit
end

---------------------------------------------------------------------------------------------------
-- Pure weather presets used here (ids + rain parameters from Pure Planner's default table)
---------------------------------------------------------------------------------------------------
local WEATHER_NAMES = {
  [15] = 'Clear', [16] = 'Few clouds', [17] = 'Scattered clouds', [18] = 'Broken clouds',
  [19] = 'Overcast', [21] = 'Mist', [23] = 'Haze', [3] = 'Light drizzle', [4] = 'Drizzle',
  [6] = 'Light rain', [7] = 'Rain', [8] = 'Heavy rain', [0] = 'Light thunderstorm', [1] = 'Thunderstorm',
}
--                 rain_amount, probability, variance, wetness, water
local RAIN_PRESET = {
  [3] = { 0.001, 0.6, 0.6, 0.005, 0.1 },
  [4] = { 0.02,  0.8, 0.5, 0.04,  0.5 },
  [6] = { 0.05,  0.6, 0.8, 0.05,  0.3 },
  [7] = { 0.125, 0.8, 0.6, 0.125, 0.6 },
  [8] = { 0.6,   0.9, 0.4, 0.6,   1.0 },
  [0] = { 0.1,   0.5, 0.7, 0.1,   0.2 },
  [1] = { 0.2,   0.7, 0.5, 0.15,  0.4 },
}

---------------------------------------------------------------------------------------------------
-- CSV database
---------------------------------------------------------------------------------------------------
local function parseCsvLine(line)
  local out, i, n = {}, 1, #line
  while i <= n + 1 do
    if line:sub(i, i) == '"' then
      local buf, j = {}, i + 1
      while j <= n do
        local ch = line:sub(j, j)
        if ch == '"' then
          if line:sub(j + 1, j + 1) == '"' then buf[#buf + 1] = '"'; j = j + 2
          else j = j + 1; break end
        else buf[#buf + 1] = ch; j = j + 1 end
      end
      out[#out + 1] = table.concat(buf)
      i = j + 1
    else
      local j = line:find(',', i, true) or (n + 1)
      out[#out + 1] = line:sub(i, j - 1)
      i = j + 1
    end
  end
  return out
end

local NUMERIC = {
  year = true, stamp_ts = true, air_c = true, track_c = true, humidity_pct = true, pressure_hpa = true,
  wind_kmh = true, wind_dir_deg = true, rain = true, rain_frac = true, cloud_pct = true, precip_mm = true,
  pure_weather = true, air_min = true, air_max = true, track_min = true, track_max = true, round = true,
  segment = true, best_lap_s = true, mist_pct = true, grip_pct = true,
}

local function isSessionRow(r) return r.circuit and r.circuit ~= '' and r.year and r.session end
local function isSegmentRow(r) return r.session_key and r.session_key ~= '' and (r.segment or 0) >= 1 and r.air_c end

local function parseCsv(text, keep, noNumeric)
  keep = keep or isSessionRow
  local rows, header = {}, nil
  for line in (text .. '\n'):gmatch('([^\r\n]*)\r?\n') do
    if line ~= '' then
      local f = parseCsvLine(line)
      if not header then
        header = f
      else
        local r = {}
        for k = 1, #header do
          local key, v = header[k], f[k]
          if NUMERIC[key] and not (noNumeric and noNumeric[key]) then v = tonumber(v) end
          r[key] = v
        end
        if keep(r) then rows[#rows + 1] = r end
      end
    end
  end
  return rows
end

local db = { rows = {}, circuits = {}, byName = {}, source = '' }

local function indexDb(rows, source)
  local byCircuit = {}
  for _, r in ipairs(rows) do
    local c = byCircuit[r.circuit]
    if not c then
      c = { name = r.circuit, display = (r.display ~= nil and r.display ~= '') and r.display or displayName(r.circuit),
            years = {}, byYear = {}, keywords = {} }
      local seen = {}
      local function addKw(k) k = k:lower():gsub('^%s+', ''):gsub('%s+$', ''); if k ~= '' and not seen[k] then seen[k] = true; c.keywords[#c.keywords + 1] = k end end
      for k in ((r.track_keywords or '') .. ';'):gmatch('([^;]*);') do addKw(k) end
      for _, k in ipairs(CIRCUITS[r.circuit] and CIRCUITS[r.circuit][2] or {}) do addKw(k) end
      if #c.keywords == 0 then addKw(r.circuit:gsub('[%s%-]+', '_')) end
      byCircuit[r.circuit] = c
    end
    if not c.byYear[r.year] then c.byYear[r.year] = {}; c.years[#c.years + 1] = r.year end
    table.insert(c.byYear[r.year], r)
  end
  local list = {}
  for _, c in pairs(byCircuit) do
    table.sort(c.years, function(a, b) return a > b end)
    for _, s in pairs(c.byYear) do table.sort(s, function(a, b) return (a.stamp_ts or 0) < (b.stamp_ts or 0) end) end
    list[#list + 1] = c
  end
  table.sort(list, function(a, b) return a.display < b.display end)
  db.rows, db.circuits, db.byName, db.source = rows, list, byCircuit, source
end

-- Qualifying segments (Q1/Q2/Q3, SQ1/SQ2/SQ3): separate file, attached to their session row as r.segs
local QUALI = { ['Qualifying'] = true, ['Sprint Qualifying'] = true, ['Sprint Shootout'] = true }
local segDb = { rows = {}, source = '' }

local function attachSegments(segRows, source)
  local byKey = {}
  for _, g in ipairs(segRows) do
    byKey[g.session_key] = byKey[g.session_key] or {}
    byKey[g.session_key][g.segment] = g
  end
  for _, r in ipairs(db.rows) do
    local s = byKey[tostring(r.session_key)]
    r.segs, r._eff = nil, nil
    if s and QUALI[r.session] then
      local have = {}
      for i = 1, 3 do if s[i] then have[#have + 1] = i end end
      if #have > 0 then
        -- a segment missing from the timing feed (e.g. Canada 2026 Q1/SQ1) is copied from the nearest
        -- one that exists (ties: the earlier one), at that segment's usual time of day; no real best lap
        local gapMin = r.session == 'Qualifying' and 21 or 17          -- typical end-to-end gap between segments
        local prefix = r.session == 'Qualifying' and 'Q' or 'SQ'
        local list = {}
        for i = 1, 3 do
          if s[i] then
            list[i] = s[i]
          else
            local src = nil
            for _, j in ipairs(have) do
              if not src or math.abs(j - i) < math.abs(src - i) then src = j end
            end
            local g = {}
            for k, v in pairs(s[src]) do g[k] = v end
            g.segment, g.label = i, prefix .. i
            g.copiedFrom = s[src].label or (prefix .. src)
            g.best_lap, g.best_lap_s, g.best_driver = '', nil, ''
            if tonumber(g.stamp_ts) then
              g.stamp_ts = tonumber(g.stamp_ts) + (i - src) * gapMin * 60
              g.local_start = os.date('!%Y-%m-%d %H:%M', g.stamp_ts)
            end
            list[i] = g
          end
        end
        r.segs = list
      end
    end
  end
  segDb.rows, segDb.source = segRows, source
end

local function loadSegments()
  local cached = parseCsv(io.load(SEG_CACHE, '') or '', isSegmentRow)
  local bundled = parseCsv(io.load(SEG_BUNDLED, '') or '', isSegmentRow)
  if #cached > 0 and #cached >= #bundled then attachSegments(cached, 'online copy') else attachSegments(bundled, 'bundled') end
end

-- The row actually applied: for qualifying with segments, the chosen Q1/Q2/Q3 overrides the
-- start-of-session values (time, temperatures, wind, rain, track state).
local SEG_FIELDS = { 'air_c', 'track_c', 'humidity_pct', 'wind_kmh', 'wind_dir_deg', 'rain', 'rain_frac',
                     'pure_weather', 'local_start', 'stamp_ts', 'source', 'track_state', 'best_lap', 'best_driver', 'mist_pct' }
local STATE_TEXT = { rain = 'raining', wet = 'wet, no rain', damp = 'damp', drying = 'drying', dry = 'dry' }
local function stateText(g)
  if g.track_state == 'wet' and g.rain == 1 then return 'raining' end
  return STATE_TEXT[g.track_state] or (g.rain == 1 and 'raining' or 'dry')
end

-- Overrides (data\f1_weather_overrides.csv, also downloaded next to the shared CSV): hand-made
-- corrections for what the timing feed can't see, e.g. haze. Columns:
--   year, event, session, segment, when, car, pure_weather, mist_pct, grip_pct, note
-- car = part of the car id ('vrc_formula_alpha_2026'), empty or * = any car.
-- grip_pct = ROAD/CURB friction of the track's surfaces.ini in % (109 → FRICTION=1.09), see gripUpdate.
-- surfaces = which surface KEYs get it, ';'-separated (default ROAD;CURB;CURBS), e.g. ROAD;CURBS;ASPHALT.
-- event = part of the circuit / display / meeting name or a track keyword ('sepang');
-- session and segment empty or * = all; later lines win. Empty value = keep the data's value.
-- when = dry (default: no rain falling), rain (raining), any. So a dry haze line never touches
-- a rainy session/segment; add a separate 'rain' line to tune those.
local isOvrRow = function(r) return r.year and r.event and r.event ~= '' end
local ovr = { rows = {}, source = '' }

local function ovrMatches(o, r, segLabel)
  if o.year ~= r.year then return false end
  local car = (o.car or ''):lower()
  if car ~= '' and car ~= '*' and not CAR_ID:find(car, 1, true) then return false end
  local ev = o.event:lower()
  local hay = ((r.display or '') .. '|' .. (r.circuit or '') .. '|' .. (r.meeting or '') .. '|' .. (r.track_keywords or '')):lower()
  if not hay:find(ev, 1, true) then return false end
  local ses = (o.session or ''):lower()
  if ses ~= '' and ses ~= '*' and ses ~= (r.session or ''):lower() then return false end
  local seg = tostring(o.segment or ''):upper()
  if seg ~= '' and seg ~= '*' then
    if not segLabel then return false end
    if seg ~= segLabel:upper() and ('Q' .. seg) ~= segLabel:upper() and ('SQ' .. seg) ~= segLabel:upper() then return false end
  end
  return true
end

local function clearEff() for _, r in ipairs(db.rows or {}) do r._eff = nil end end

local function loadOverrides()
  local raw = { segment = true }                 -- 'Q2', 'SQ1', '2' …
  local cached = parseCsv(io.load(OVR_CACHE, '') or '', isOvrRow, raw)
  local bundled = parseCsv(io.load(OVR_BUNDLED, '') or '', isOvrRow, raw)
  local online = (io.load(OVR_CACHE, '') or '') ~= ''
  if online then ovr.rows, ovr.source = cached, 'online copy' else ovr.rows, ovr.source = bundled, 'bundled' end
  clearEff()
end

-- The row actually applied: a copy of the session row, with the chosen Q1/Q2/Q3 merged in for
-- qualifying (time, temperatures, wind, rain, track state) and the overrides on top.
-- index in r.segs of segment number num (1 = Q1 …); a missing segment falls back to the next one
-- that exists (no Q1 data → Q2), else the last one
local function segIdx(r, num)
  if not r or not r.segs then return 0 end
  num = num or settings.qSeg or 1
  for k, g in ipairs(r.segs) do if g.segment == num then return k end end
  for k, g in ipairs(r.segs) do if (g.segment or 0) > num then return k end end
  return #r.segs
end

local function effRow(r, segIndex)
  if not r then return r end
  local i = 0
  if r.segs then i = segIndex or segIdx(r) end
  r._eff = r._eff or {}
  if not r._eff[i] then
    local e = {}
    for k, v in pairs(r) do if k ~= 'segs' and k ~= '_eff' then e[k] = v end end
    if i > 0 then
      local g = r.segs[i]
      for _, k in ipairs(SEG_FIELDS) do if g[k] ~= nil and g[k] ~= '' then e[k] = g[k] end end
      e.segLabel = g.label
    end
    -- raining or not is decided by the data, before any override
    if not e.track_state or e.track_state == '' then e.track_state = RAIN_PRESET[e.pure_weather] and 'rain' or 'dry' end
    if e.track_state == 'wet' and e.rain == 1 then e.track_state = 'rain' end
    local raining = e.track_state == 'rain'
    for _, o in ipairs(ovr.rows) do
      local when = (o.when or ''):lower()
      if when == '' or when == '*' then when = 'dry' end
      local fits = when == 'any' or (when == 'rain') == raining
      if fits and ovrMatches(o, e, e.segLabel) then
        if o.pure_weather then
          -- sky only: dry stays dry. In rain the type sets the rain strength, so only rain types count there.
          if not raining or RAIN_PRESET[o.pure_weather] then e.pure_weather = o.pure_weather end
        end
        if o.mist_pct then e.mist_pct = o.mist_pct end
        if o.grip_pct then e.grip_pct = o.grip_pct end
        if o.surfaces and o.surfaces ~= '' then e.grip_surfaces = o.surfaces end
        e.overridden = true
      end
    end
    r._eff[i] = e
  end
  return r._eff[i]
end

-- use the downloaded copy unless the bundled file (e.g. a newer app release) has more sessions
local function loadDb()
  local cached = parseCsv(io.load(DB_CACHE, '') or '')
  local bundled = parseCsv(io.load(DB_BUNDLED, '') or '')
  if #cached >= 5 and #cached >= #bundled then indexDb(cached, 'online copy') else indexDb(bundled, 'bundled') end
  loadSegments()
  loadOverrides()
end
loadDb()

---------------------------------------------------------------------------------------------------
-- Minimal JSON encoder (Pure Planner plan files are JSON)
---------------------------------------------------------------------------------------------------
local function jsonEncode(v)
  local t = type(v)
  if t == 'nil' then return 'null'
  elseif t == 'boolean' then return v and 'true' or 'false'
  elseif t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return '0' end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.6g', v)
  elseif t == 'string' then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif t == 'table' then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i = 1, #v do parts[i] = jsonEncode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys, parts = {}, {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = jsonEncode(k) .. ':' .. jsonEncode(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

---------------------------------------------------------------------------------------------------
-- Plan building
---------------------------------------------------------------------------------------------------
local PLAN_TYPE = { day = 1, timed = 2, stamp = 3 }
local PLAN_FOLDER = { [1] = 'Daycycle', [2] = 'Timed', [3] = 'Stamp' }

local function clamp(v, a, b) v = tonumber(v) or a; return math.max(a, math.min(b, v)) end

-- Fixed track surfaces (no rain falling): wetness, standing water
local SURFACE = {
  wet    = { 0.10, 0.30 },   -- rain stopped recently: still fully wet
  damp   = { 0.05, 0.10 },
  drying = { 0.02, 0.00 },   -- dry line forming
}

-- Everything is frozen for the whole AC session (all *_dyn = false, no rain variance), so a
-- segment plays like a snapshot of its final laps and lap times stay comparable.
local mistPct
-- Pure mist in % (override from the overrides file, else automatic from humidity)
mistPct = function(r)
  if r.mist_pct then return clamp(r.mist_pct, 0, 100) end
  local hum = clamp((r.humidity_pct or 50) / 100, 0, 1)
  return hum > 0.93 and clamp((hum - 0.93) / 0.07 * 30, 0, 30) or 0
end

local function buildWeather(r)
  local id = r.pure_weather or 16
  local state = r.track_state
  if state == nil or state == '' then state = RAIN_PRESET[id] and 'rain' or 'dry' end
  if state == 'wet' and r.rain == 1 then state = 'rain' end        -- v1.6 files used 'wet' for raining
  local rain, prob, var, wetness, water = 0, 0, 0, 0, 0
  if state == 'rain' then
    local rp = RAIN_PRESET[id] or RAIN_PRESET[6]
    rain, prob, var, wetness, water = rp[1], 1, 0, rp[4], rp[5]
  elseif SURFACE[state] then
    wetness, water = SURFACE[state][1], SURFACE[state][2]
  end
  local hum = clamp((r.humidity_pct or 50) / 100, 0, 1)
  local w = {
    index            = id,
    rain_amount      = rain,
    rain_probability = prob,
    rain_variance    = var,
    rain_wetness     = wetness,
    rain_water       = water,
    wind_direction   = clamp(r.wind_dir_deg or 0, 0, 360),
    wind_strength    = clamp(r.wind_kmh or 0, 0, 150),
    humidity         = hum,
    mist             = mistPct(r) / 100,
    temp_air         = clamp(r.air_c, 0, 45),
    temp_road        = clamp(r.track_c, 0, 80),
    trans_auto = true, trans_look_A = 0.5, trans_look_B = 1, trans_data_A = 0.5, trans_data_B = 1,
    temp_air_dyn = false, temp_road_dyn = false, humidity_dyn = false, mist_dyn = false,
    rain_amount_dyn = false, rain_wetness_dyn = false, rain_water_dyn = false,
  }
  for _, k in ipairs({ 'rain_amount', 'rain_probability', 'rain_variance', 'rain_wetness', 'rain_water', 'humidity',
                       'mist', 'temp_air', 'temp_road', 'wind_direction', 'wind_strength' }) do
    w[k .. '_range'] = 0
  end
  return w
end

-- realTime → Stamp plan at the real local start (sim clock jumps there);
-- otherwise a Daycycle plan: same conditions all day, sim time untouched.
local function buildPlan(r, realTime)
  local typ, ts, dur
  if realTime then
    typ, ts, dur = PLAN_TYPE.stamp, r.stamp_ts, 4 * 3600
  else
    typ, ts, dur = PLAN_TYPE.day, math.floor((ac.getSim().timestamp or 0) / 86400) * 86400, 86400
  end
  return {
    control = { type = typ, loop = not realTime, timemulti = 1 },
    container = { { data = { timestamp = ts, duration = dur, weather = buildWeather(r) } } },
  }
end

local function safeName(s)
  return (tostring(s or ''):gsub('[\\/:%*%?"<>|]', ''):gsub('%s+', '_'))
end

-- plan path relative to the Pure Planner Plans folder, without .json (what PURE.initPlan expects)
local function planRelPath(r, realTime)
  return string.format('%s\\%s\\%d\\%02d_%s_%s', realTime and 'Stamp' or 'Daycycle', SUBFOLDER, r.year, r.round or 0,
    safeName(r.display or displayName(r.circuit)), safeName(r.session) .. (r.segLabel and ('_' .. r.segLabel) or ''))
end

local function writePlan(r, realTime, alsoLastUsed)
  local rel = planRelPath(r, realTime)
  local file = PLANS_DIR .. rel .. '.json'
  local json = jsonEncode(buildPlan(r, realTime))
  io.createDir(file:match('^(.*)\\[^\\]+$'))
  local ok = io.save(file, json) ~= false
  if alsoLastUsed then io.save(LAST_USED, json) end
  return ok, rel, file
end

---------------------------------------------------------------------------------------------------
-- Link to Pure Planner's shared controller state (the struct Pure Planner registers itself)
---------------------------------------------------------------------------------------------------
local link = { conn = nil, sync = nil, msg = {}, val = {}, nameMSG = 'PurePlanner_ControllerStateMSG',
               nameVAL = 'PurePlanner_ControllerStateVAL' }

local function linkConnect()
  local struct = ac.load('PurePlanner_ControllerStateSTRUCT')
  if type(struct) ~= 'string' or #struct < 10 then link.conn = nil; return false end
  local sync = ac.load('PurePlanner_ControllerStateSYNC')
  if link.conn and sync == link.sync then return true end
  local ok, c = pcall(ac.connect, struct, true, ac.SharedNamespace.Shared)
  if not ok or not c then link.conn = nil; return false end
  local nMsg = tonumber(struct:match('StateMSG%[(%d+)%]')) or 0
  local nVal = tonumber(struct:match('StateVAL%[(%d+)%]')) or 0
  link.msg, link.val = {}, {}
  local okScan = pcall(function()
    for i = 0, nMsg - 1 do
      local e = c[link.nameMSG][i]; if not e then break end
      local n = ffi.string(e.name)
      if n == '' then break end
      link.msg[n] = i
    end
    for i = 0, nVal - 1 do
      local e = c[link.nameVAL][i]; if not e then break end
      local n = ffi.string(e.name)
      if n == '' then break end
      link.val[n] = i
    end
  end)
  if not okScan then link.conn = nil; return false end
  link.conn, link.sync = c, sync
  return link.msg['PURE.initPlan'] ~= nil and link.val['PureCtrl.restarted'] ~= nil
end

local function linkGetString(name)
  local i = link.msg[name]; if not i or not link.conn then return nil end
  return ffi.string(link.conn[link.nameMSG][i].strValue)
end
local function linkSetString(name, s)
  local i = link.msg[name]; if i and link.conn then link.conn[link.nameMSG][i].strValue = s end
end
local function linkGetValue(name)
  local i = link.val[name]; if not i or not link.conn then return nil end
  return link.conn[link.nameVAL][i].dValue
end
local function linkSetValue(name, v)
  local i = link.val[name]; if i and link.conn then link.conn[link.nameVAL][i].dValue = v end
end

---------------------------------------------------------------------------------------------------
-- Sync engine: write plan, then make sure Pure Planner is actually running it
---------------------------------------------------------------------------------------------------
-- phases: idle → waiting (for Pure's own start-up load) → pushing (initPlan+restart) → confirmed | failed
local sync = { row = nil, rel = nil, phase = 'idle', t = 0, tries = 0, restore = nil, pureAir = nil, msg = '' }

-- Pure Planner publishes the temperatures it is currently driving; both must match the plan
local function isApplied(r)
  if not linkConnect() then return false end
  local air, road = linkGetValue('weather.temp.ambient'), linkGetValue('weather.temp.road')
  sync.pureAir = air
  return air ~= nil and road ~= nil
    and math.abs(air - clamp(r.air_c, 0, 45)) < 0.2 and math.abs(road - clamp(r.track_c, 0, 80)) < 0.2
end

-- viaStartup: true at session load (Pure Planner will read last_used.json by itself first)
local function applyRow(r, viaStartup)
  r = effRow(r)
  local ok, rel, file = writePlan(r, settings.realTime, true)
  if not ok then sync.phase, sync.msg = 'failed', 'Could not write ' .. file; return end
  sync.row, sync.rel, sync.t, sync.tries = r, rel, 0, 0
  sync.phase = viaStartup and 'waiting' or 'pushing'
  sync.msg = viaStartup and 'Waiting for Pure Planner to start…' or 'Sending to Pure Planner…'
end

local function pushNow()
  if not linkConnect() then return false end
  if (linkGetValue('ctrl.type') or 0) > 0 then
    sync.phase, sync.msg = 'failed', 'Pure runs its static controller. Pick "Pure Planner" as weather controller in CM.'
    return false
  end
  if sync.restore == nil then sync.restore = linkGetString('PURE.initPlan') or '' end
  linkSetString('PURE.initPlan', sync.rel)
  linkSetValue('PureCtrl.restarted', 1)
  sync.tries = sync.tries + 1
  return true
end

local function finishPush()
  if sync.restore ~= nil and link.conn then linkSetString('PURE.initPlan', sync.restore) end
  sync.restore = nil
end

local function syncUpdate(dt)
  if sync.phase == 'idle' or sync.phase == 'confirmed' or sync.phase == 'failed' or sync.phase == 'off' then return end
  sync.t = sync.t + dt
  if isApplied(sync.row) then
    finishPush()
    sync.phase, sync.msg = 'confirmed', string.format('Pure Planner is running it (air %.1f °C)', sync.pureAir)
    return
  end
  if sync.phase == 'checking' then
    if sync.t > 60 then
      sync.phase = 'failed'
      sync.msg = 'Pure Planner did not switch. Saved as Plans\\' .. sync.rel .. '.json — load it in Pure Planner.'
    end
    return
  end
  if sync.phase == 'waiting' then
    -- give Pure Planner up to 12 s to start on last_used.json by itself, then push
    if sync.t > 12 then sync.phase, sync.t = 'pushing', 0 end
    return
  end
  -- pushing
  if not link.conn and not linkConnect() then
    if sync.t > 20 then sync.phase, sync.msg = 'failed', 'Pure Planner not found. Is Pure the active weather in CM?' end
    return
  end
  if sync.tries == 0 then
    if pushNow() then sync.pushT = 0 end
    return
  end
  sync.pushT = (sync.pushT or 0) + dt
  if sync.pushT < 1.0 then
    linkSetString('PURE.initPlan', sync.rel)      -- hold the name while Pure Planner picks it up
  elseif sync.pushT > 6 then
    if sync.tries < 3 then
      if pushNow() then sync.pushT = 0 end
    else
      finishPush()
      sync.phase, sync.t = 'checking', 0
      sync.msg = 'Sent to Pure Planner, waiting for it to take effect…'
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Selection helpers
---------------------------------------------------------------------------------------------------
local sel = { circuit = nil, year = nil, idx = 1 }
local pit = { lastWindowDraw = -10, overlay = false, tried = false, menuT = 0, open = false }   -- pit-screen panel state
local detectedTrack, carId = '', ''
pcall(function() carId = (ac.getCarID(0) or ''):lower() end)

local function detectTrack()
  local id, full = '', ''
  pcall(function() id = (ac.getTrackID() or '') end)
  pcall(function() full = (ac.getTrackFullID('_') or '') end)
  detectedTrack = id
  local hay = (id .. ' ' .. full):lower()
  for _, c in ipairs(db.circuits) do
    for _, kw in ipairs(c.keywords or {}) do
      if hay:find(kw, 1, true) then return c end
    end
  end
  return nil
end

local function findIdx(list, sessionName)
  for i, r in ipairs(list) do if r.session == sessionName then return i end end
  return nil
end

local function selectCircuit(c, year, sessionName)
  sel.circuit = c
  sel.year = c and (year and c.byYear[year] and year or c.years[1]) or nil
  sel.idx = 1
  if c and sel.year then
    local list = c.byYear[sel.year]
    sel.idx = findIdx(list, sessionName or 'Race') or findIdx(list, 'Qualifying') or 1
  end
end

local function currentRow()
  if not sel.circuit or not sel.year then return nil end
  local list = sel.circuit.byYear[sel.year]
  return list and list[sel.idx]
end

-- AC session → real F1 session: race → Race, everything else (hotlap, practice, qualify) → Qualifying
local function acSessionType()
  local t = 0
  pcall(function() t = ac.getSim().raceSessionType or 0 end)
  return t
end
local function wantedSession(t) return t == ac.SessionType.Race and 'Race' or 'Qualifying' end
local SESSION_LABEL = { [0] = 'Session', [1] = 'Practice', [2] = 'Qualifying', [3] = 'Race', [4] = 'Hotlap',
                        [5] = 'Time attack', [6] = 'Drift', [7] = 'Drag' }

local function carMatches()
  if settings.autoAnyCar then return true end
  local f = (settings.carFilter or ''):lower()
  return f ~= '' and carId:find(f, 1, true) ~= nil
end

local autoState = { active = false, circuit = nil, reason = '' }

local function autoApply(viaStartup)
  if not trackKnown then
    autoState.active, autoState.reason = false, 'Track "' .. detectedTrack .. '" is not an F1 circuit — off for this session'
    sync.phase, sync.msg = 'off', 'Track not recognised — F1 True Conditions is off'
    return
  end
  if not settings.autoApply then
    autoState.active, autoState.reason = false, 'F1 True Conditions is off'
    sync.phase, sync.msg = 'off', 'F1 True Conditions is off — Pure Planner keeps its current plan'
    return
  end
  if not carMatches() then autoState.active, autoState.reason = false, 'Car ' .. carId .. ' is not a match'; return end
  local c = detectTrack()
  if not c then autoState.active, autoState.reason = false, 'No F1 circuit matches track "' .. detectedTrack .. '"'; return end
  local year = settings.autoYear ~= 0 and settings.autoYear or nil
  selectCircuit(c, year, wantedSession(acSessionType()))
  local r = currentRow()
  if not r then return end
  autoState.active, autoState.circuit, autoState.reason = true, c, ''
  applyRow(r, viaStartup)
end

---------------------------------------------------------------------------------------------------
-- Start-up + session tracking
---------------------------------------------------------------------------------------------------
trackKnown = detectTrack() ~= nil
if settings.autoDetect then selectCircuit(detectTrack()) end
if not sel.circuit then selectCircuit(db.circuits[1]) end      -- main window browsing only
autoApply(true)
-- (automatic database download is started at the end of the file, once refreshDb exists)

---------------------------------------------------------------------------------------------------
-- Track grip (overrides file, grip_pct): written as FRICTION of the ROAD and CURB surfaces in the
-- track's own data\surfaces.ini (109 → FRICTION=1.09). AC reads that file only while loading the
-- track, so a new value is used from the NEXT time the track is loaded (the panel says so).
-- The original file is kept as surfaces.ini.f1tc_original and its values are put back when no
-- grip override applies, when the app is switched off, and in online sessions (servers compare
-- the file's checksum).
---------------------------------------------------------------------------------------------------
local DEFAULT_SURFACES = 'ROAD;CURB;CURBS'      -- surface KEYs changed when the override has no 'surfaces'
local SURF_FILE = ''
pcall(function() SURF_FILE = ac.getTrackDataFilename('surfaces.ini') or '' end)
local SURF_BACKUP = SURF_FILE .. '.f1tc_original'

-- friction of ROAD/CURB sections: returns { [sectionName] = {key=..., friction=...} }
local function readFrictions(text)
  local out, cur = {}, nil
  for line in ((text or '') .. '\n'):gmatch('([^\r\n]*)\r?\n') do
    local sec = line:match('^%s*%[([^%]]+)%]')
    if sec then cur = sec; out[cur] = {} elseif cur then
      local k, v = line:match('^%s*([%w_]+)%s*=%s*([^;]-)%s*$')
      if k == 'KEY' then out[cur].key = v:upper() elseif k == 'FRICTION' then out[cur].friction = tonumber(v) end
    end
  end
  return out
end

-- value = number → FRICTION of every section whose KEY is in keys; table section → number → those sections
local function writeFrictions(text, value, keys)
  local info = readFrictions(text)
  local lines, cur = {}, nil
  for line in ((text or '') .. '\n'):gmatch('([^\r\n]*)\r?\n') do
    local sec = line:match('^%s*%[([^%]]+)%]')
    if sec then cur = sec end
    local k = cur and line:match('^%s*FRICTION%s*=')
    local f = nil
    if k and info[cur] then
      if type(value) == 'table' then f = value[cur]
      elseif keys and keys[info[cur].key or ''] then f = value end
    end
    if f then line = string.format('FRICTION=%s', (string.format('%.4f', f):gsub('0+$', ''):gsub('%.$', ''))) end
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == '' do table.remove(lines) end
  return table.concat(lines, '\r\n') .. '\r\n'
end

local function keySet(list)
  local t = {}
  for k in ((list ~= nil and list ~= '' and list or DEFAULT_SURFACES) .. ';'):gmatch('([^;]*);') do
    k = k:gsub('^%s+', ''):gsub('%s+$', ''):upper(); if k ~= '' then t[k] = true end
  end
  return t
end

-- friction of the first section with one of these keys (ROAD first)
local function surfFriction(text, keys)
  local info, best = readFrictions(text), nil
  for _, s in pairs(info) do
    if s.friction and keys[s.key or ''] then
      if s.key == 'ROAD' then return s.friction end
      best = best or s.friction
    end
  end
  return best
end

grip = { loadedText = nil, loaded = nil, target = nil, text = '', pending = false, lowStart = false, needsReload = false, t = 1, last = false }
pcall(function() grip.loadedText = io.load(SURF_FILE, nil) end)    -- the file as this session loaded it

gripUpdate = function(dt)
  grip.t = grip.t + dt
  if grip.t < 0.5 then return end
  grip.t = 0
  if SURF_FILE == '' then return end
  local sim = ac.getSim()
  local online = sim and sim.isOnlineRace
  local r = settings.autoApply and trackKnown and sync.row or nil
  local target = (not online) and r and r.grip_pct and clamp(r.grip_pct, 50, 150) / 100 or nil
  local keys = keySet(r and r.grip_surfaces)
  grip.target = target
  grip.loaded = grip.loadedText and surfFriction(grip.loadedText, keys)
  grip.pending = target ~= nil and (grip.loaded == nil or math.abs(grip.loaded - target) > 0.0005)
  -- qualifying wants a fully rubbered track from lap one (CM 'Optimum'), not one that gains grip per lap
  grip.road = sim and sim.roadGrip or nil
  grip.lowStart = (not online) and r ~= nil and QUALI[r.session] == true and grip.road ~= nil and grip.road < 0.995
  grip.needsReload = grip.pending or grip.lowStart
  grip.text = online and 'track file not changed online'
    or target and (grip.pending and 'used from the next track load' or 'active') or ''
  local want = target and string.format('%.4f|%s', target, (r and r.grip_surfaces or '')) or 'none'
  if want == grip.last then return end                    -- write only when the wanted value changes
  grip.last = want
  local cur = io.load(SURF_FILE, nil)
  if not cur then grip.text = 'surfaces.ini not found'; return end
  local new = cur
  if io.fileExists(SURF_BACKUP) then                     -- start from the original frictions
    local orig = {}
    for sec, s in pairs(readFrictions(io.load(SURF_BACKUP, ''))) do orig[sec] = s.friction end
    new = writeFrictions(new, orig)
  end
  if target then
    if not io.fileExists(SURF_BACKUP) then io.save(SURF_BACKUP, cur) end
    if not surfFriction(cur, keys) then grip.text = 'no ROAD/CURB surface in surfaces.ini (set "surfaces")' end
    new = writeFrictions(new, target, keys)
  end
  if new and new ~= cur and not io.save(SURF_FILE, new) then grip.text = 'could not write surfaces.ini' end
end

-- Reload the track (AC restarts on the same race.ini, like the VRC track zone editor does).
-- Two clicks: the first arms the button for 3 s, the second restarts.
-- In qualifying the restart also sets Content Manager's track to 'Optimum' (100 % grip, no rubbering in).
local OPTIMUM_INI = '[DYNAMIC_TRACK]\nSESSION_START=100\nRANDOMNESS=0\nSESSION_TRANSFER=100\nLAP_GAIN=1\n'
reloadTrack = function()
  if not (grip.confirmUntil and os.clock() < grip.confirmUntil) then grip.confirmUntil = os.clock() + 3; return end
  grip.confirmUntil = nil
  local r = sync.row
  local ini = (r and QUALI[r.session]) and OPTIMUM_INI or nil
  if not pcall(ac.restartAssettoCorsa, ini) then grip.text = 'reload not available: go back to Content Manager and drive again' end
end

---------------------------------------------------------------------------------------------------
-- Qualifying tyre grip per segment (Q1 95 %, Q2 98 %, Q3 100 % by default): the track rubbers in
-- during real qualifying, so earlier segments get less grip. Done live with physics.setGripDecrease
-- on the player's car (no reload). Needs the track to allow apps to change physics
-- ([_SCRIPTING_PHYSICS] ALLOW_APPS=1 in its surfaces.ini). Offline only.
---------------------------------------------------------------------------------------------------
local PHYS_ALLOWED = false
do
  local inSec = false
  for line in ((grip.loadedText or '') .. '\n'):gmatch('([^\r\n]*)\r?\n') do
    local sec = line:match('^%s*%[([^%]]+)%]')
    if sec then inSec = sec:upper() == '_SCRIPTING_PHYSICS'
    elseif inSec and line:upper():match('^%s*ALLOW_APPS%s*=%s*1') then PHYS_ALLOWED = true end
  end
end

local function tyreUpdate(dt)
  tyre.t = tyre.t + dt
  if tyre.t < 0.5 then return end
  tyre.t = 0
  local sim = ac.getSim()
  local online = sim and sim.isOnlineRace
  local r = settings.autoApply and trackKnown and sync.row or nil
  local seg = r and r.segLabel and tonumber(tostring(r.segLabel):match('(%d)$')) or nil
  local pct = 100
  if seg and not online then
    pct = TYRE_PCT[seg] or 100
  end
  tyre.pct, tyre.seg = pct, seg
  local dec = clamp(1 - pct / 100, 0, 0.5)
  if not seg then tyre.text = 'only in qualifying segments'
  elseif online then tyre.text = 'not changed online'
  elseif not PHYS_ALLOWED and dec > 0 then tyre.text = 'this track doesn\'t allow apps to change grip'
  else tyre.text = string.format('%s: tyres at %g %%', r.segLabel, pct) end
  if math.abs(dec - tyre.applied) > 0.0005 then
    local ok = pcall(function() physics.setGripDecrease(0, ac.Wheel.All, dec) end)
    if ok then tyre.applied = dec elseif dec > 0 then tyre.text = 'grip change not available on this track' end
  end
end

-- text of the red reload note
local function reloadNote()
  if grip.pending and grip.target then
    return string.format('Reload track for %g %% grip', grip.target * 100) .. (grip.lowStart and ' (Optimum)' or '')
  end
  return string.format('Track at %.0f %% grip — reload at Optimum for qualifying', (grip.road or 0) * 100)
end

-- the pit panel is only for the pit lane / the start of a session before driving
pitAllowed = function()
  local ok, res = pcall(function()
    local car = ac.getCar(0)
    if not car then return true end
    return car.isInPitlane or car.isInPit or (car.distanceDrivenSessionKm or 0) < 0.05
  end)
  return not ok or res == true
end

local lastSessionIndex, lastSessionType = nil, nil
pcall(function() lastSessionIndex = ac.getSim().currentSessionIndex end)
lastSessionType = acSessionType()

function script.update(dt)
  local idx
  pcall(function() idx = ac.getSim().currentSessionIndex end)
  local t = acSessionType()
  if (idx ~= nil and idx ~= lastSessionIndex) or t ~= lastSessionType then
    local changed = wantedSession(t) ~= wantedSession(lastSessionType or 0)
    lastSessionIndex, lastSessionType = idx, t
    if changed and autoState.active then autoApply(false) end
  end
  syncUpdate(dt)
  gripUpdate(dt)
  tyreUpdate(dt)

  -- pit / setup screen: open our setup window; if CSP doesn't show it, draw it as an overlay
  local inMenu = false
  pcall(function() inMenu = ac.getSim().isInMainMenu end)
  local allowed = inMenu and settings.pitPanel and pitAllowed()
  if allowed ~= pit.open then                -- open in the pits / before driving, closed otherwise
    pit.open = allowed
    pcall(ac.setWindowOpen, 'pit', allowed)
  end
  if allowed then
    pit.menuT = pit.menuT + dt
    -- Setup tab: CSP draws our setup window itself. Info tab: drawn as an overlay, but only when CSP
    -- reports the Info section (never on Drive / Lap times / Telemetry, where the setup window isn't drawn either)
    pit.overlay = pit.section == 'info' and pit.menuT > 0.3 and os.clock() - (pit.lastWindowDraw or -10) > 0.5
  else
    pit.menuT, pit.overlay, pit.section = 0, false, nil
  end
end

---------------------------------------------------------------------------------------------------
-- Manual actions
---------------------------------------------------------------------------------------------------
local function applyManual(r)
  if settings.autoTrigger then
    applyRow(r, false)
  else
    local ok, rel = writePlan(r, settings.realTime, false)
    sync.row, sync.rel = r, rel
    sync.phase, sync.msg = ok and 'confirmed' or 'failed', ok and ('Saved Plans\\' .. rel .. '.json') or 'Could not save plan'
  end
end

local function exportAll()
  local n = 0
  for _, r in ipairs(db.rows) do if writePlan(r, true, false) then n = n + 1 end end
  sync.phase, sync.msg = 'confirmed', string.format('Exported %d Stamp presets to Plans\\Stamp\\%s', n, SUBFOLDER)
end

local refreshing, lastUpdate = false, nil
local function dbUrl() return (settings.dbUrl ~= '' and settings.dbUrl) or OFFICIAL_URL end

local function rowChanged(a, b)
  if not a or not b then return a ~= b end
  for _, k in ipairs({ 'air_c', 'track_c', 'humidity_pct', 'wind_kmh', 'wind_dir_deg', 'pure_weather', 'rain', 'source',
                       'track_state', 'stamp_ts', 'mist_pct' }) do
    if a[k] ~= b[k] then return true end
  end
  return false
end

-- silent = automatic start-up update (no status message unless something changes)
local function refreshDb(silent)
  local url = dbUrl()
  if url == '' then if not silent then sync.phase, sync.msg = 'failed', 'No shared database URL set.' end; return end
  refreshing = true
  web.get(url, function(err, response)
    refreshing = false
    if err or not response or not response.body or (response.status and response.status >= 400) then
      if not silent then sync.phase, sync.msg = 'failed', 'Download failed: ' .. tostring(err or response and response.status) end
      return
    end
    local rows = parseCsv(response.body)
    if #rows < 5 then if not silent then sync.phase, sync.msg = 'failed', 'Download is not a valid F1 weather CSV.' end; return end
    io.save(DB_CACHE, response.body)
    -- the Q1/Q2/Q3 file sits next to the main CSV
    local segUrl = url:gsub('f1_weather_db%.csv', 'f1_weather_segments.csv')
    refreshing = true
    web.get(segUrl, function(err2, resp2)
    refreshing = false
    if not err2 and resp2 and resp2.body and not (resp2.status and resp2.status >= 400)
       and #parseCsv(resp2.body, isSegmentRow) > 0 then
      io.save(SEG_CACHE, resp2.body)
    end
    local ovrUrl = url:gsub('f1_weather_db%.csv', 'f1_weather_overrides.csv')
    refreshing = true
    web.get(ovrUrl, function(err3, resp3)
    refreshing = false
    if not err3 and resp3 and resp3.body and not (resp3.status and resp3.status >= 400)
       and (resp3.body:find('event', 1, true)) then
      io.save(OVR_CACHE, resp3.body)
    end
    lastUpdate = os.date('%H:%M')
    local keepC, keepY, cur = sel.circuit and sel.circuit.name, sel.year, currentRow()
    local keepS = cur and cur.session
    indexDb(rows, 'online copy')
    trackKnown = detectTrack() ~= nil      -- a new circuit may only be recognisable with the new data
    loadSegments()
    loadOverrides()
    selectCircuit(db.byName[keepC] or detectTrack() or db.circuits[1], keepY, keepS)
    -- a new circuit (first race there) may only be recognisable with the new data
    if autoState.active or (settings.autoApply and not autoState.active and carMatches()) then
      local wasWaiting = sync.phase == 'waiting'
      local before = sync.row
      if autoState.active then
        local r = currentRow()
        if r and rowChanged(before, effRow(r)) then applyRow(r, wasWaiting) end
      else
        autoApply(false)
      end
    elseif not silent then
      sync.phase, sync.msg = 'confirmed', string.format('Database updated: %d sessions, %d qualifying segments.', #rows, #segDb.rows)
    end
    end)
    end)
  end)
end

local function resetToBundled()
  io.save(DB_CACHE, '')
  io.save(SEG_CACHE, '')
  io.save(OVR_CACHE, '')
  loadDb()
  selectCircuit(detectTrack() or db.circuits[1])
  sync.phase, sync.msg = 'confirmed', 'Using bundled database.'
end

---------------------------------------------------------------------------------------------------
-- Shared drawing helpers
---------------------------------------------------------------------------------------------------
local C = {
  panel   = rgbm(0.07, 0.08, 0.10, 0.92),
  panel2  = rgbm(0.12, 0.13, 0.16, 1),
  line    = rgbm(1, 1, 1, 0.08),
  text    = rgbm(0.92, 0.93, 0.95, 1),
  muted   = rgbm(0.60, 0.63, 0.68, 1),
  accent  = rgbm(0.96, 0.62, 0.04, 1),     -- amber
  good    = rgbm(0.45, 0.85, 0.55, 1),
  warn    = rgbm(1.00, 0.55, 0.35, 1),
  wet     = rgbm(0.45, 0.70, 1.00, 1),
  cool    = rgbm(0.50, 0.72, 1.00, 1),
  mild    = rgbm(0.50, 0.85, 0.60, 1),
  warm    = rgbm(0.98, 0.75, 0.30, 1),
  hot     = rgbm(1.00, 0.48, 0.28, 1),
}

local function tempColor(v, track)
  local x = track and v / 1.5 or v
  return x < 15 and C.cool or x < 24 and C.mild or x < 30 and C.warm or C.hot
end

local DIRS = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }
local function compass(d) return DIRS[(math.floor(((d or 0) + 22.5) / 45) % 8) + 1] end
local function fmt(v, f) return v and string.format(f, v) or '–' end

local function statusColor()
  return sync.phase == 'confirmed' and C.good or sync.phase == 'failed' and C.warn or C.muted
end

local function pill(label, active, width, color)
  ui.pushStyleColor(ui.StyleColor.Button, active and (color or C.accent) or C.panel2)
  ui.pushStyleColor(ui.StyleColor.ButtonHovered, active and (color or C.accent) or rgbm(0.2, 0.21, 0.25, 1))
  ui.pushStyleColor(ui.StyleColor.ButtonActive, color or C.accent)
  ui.pushStyleColor(ui.StyleColor.Text, active and rgbm(0.05, 0.05, 0.06, 1) or C.text)
  local clicked = ui.button(label, vec2(width, 30))
  ui.popStyleColor(4)
  return clicked
end

---------------------------------------------------------------------------------------------------
-- Pit window (setup screen) — styled after the CSP / VRC setup panels:
-- glass background, white semibold text, dim labels, thin separators, one column per session.
---------------------------------------------------------------------------------------------------
local V = {
  bg      = rgbm(0.09, 0.09, 0.11, 0.85),   -- only used when drawn as overlay (no SETUP glass behind)
  text    = rgbm(1, 1, 1, 1),
  dim     = rgbm(0.72, 0.72, 0.74, 1),
  faint   = rgbm(0.44, 0.44, 0.44, 1),
  line    = rgbm(1, 1, 1, 0.10),
  colSel  = rgbm(1, 1, 1, 0.07),
  good    = rgbm(0.35, 0.85, 0.45, 1),
  warn    = rgbm(1.00, 0.45, 0.35, 1),
  wet     = rgbm(0.45, 0.72, 1.00, 1),
  red     = rgbm(0.92, 0.08, 0.12, 1),     -- VRC secondary #EB141F
  redFill = rgbm(0.92, 0.08, 0.12, 0.10),
}
local F = {}
pcall(function()
  F.regular = ui.DWriteFont('Default'):weight(ui.DWriteFont.Weight.SemiBold)
  F.bold    = ui.DWriteFont('Default'):weight(ui.DWriteFont.Weight.Bold)
end)
local function pushF(f) if f then ui.pushDWriteFont(f) end end
local function popF(f) if f then ui.popDWriteFont() end end
-- text shrinks (down to 70 %) instead of being cut off when it is wider than its cell
local function txt(text, size, p1, p2, align, color)
  local room = p2.x - p1.x - 4
  local ok, m = pcall(ui.measureDWriteText, text, size)
  if ok and m and m.x > room and room > 0 then size = math.max(size * 0.7, size * room / m.x) end
  ui.dwriteDrawTextClipped(text, size, p1, p2, align or ui.Alignment.Center, ui.Alignment.Center, false, color or V.text)
end

-- short sky names for the narrow pit-panel columns
local SKY_SHORT = {
  [15] = 'Clear', [16] = 'Few clouds', [17] = 'Scattered', [18] = 'Broken', [19] = 'Overcast', [21] = 'Mist',
  [23] = 'Haze', [3] = 'Lt drizzle', [4] = 'Drizzle', [6] = 'Light rain', [7] = 'Rain', [8] = 'Heavy rain',
  [0] = 'Lt storm', [1] = 'Storm',
}

local SHORT = { ['Sprint Qualifying'] = 'Sprint Q', ['Sprint'] = 'Sprint', ['Qualifying'] = 'Qualifying', ['Race'] = 'Race' }
local ROWS = {
  { 'Air (°C)',       function(r) return fmt(r.air_c, '%.1f') end },
  { 'Track (°C)',     function(r) return fmt(r.track_c, '%.1f') end },
  false,
  { 'Humidity (%)',   function(r) return fmt(r.humidity_pct, '%.0f') end },
  { 'Wind (km/h)',    function(r) return fmt(r.wind_kmh, '%.1f') .. ' ' .. compass(r.wind_dir_deg) end },
  false,
  { 'Sky',            function(r) return SKY_SHORT[r.pure_weather] or WEATHER_NAMES[r.pure_weather] or tostring(r.pure_weather) end },
  { 'Haze / mist',    function(r) local m = mistPct(r); return m >= 1 and string.format('%d %%', math.floor(m + 0.5)) or '–' end },
  { 'Track grip',     function(r) return r.grip_pct and string.format('%g %%', r.grip_pct) or '–' end },
  { 'Track',          function(r)
      local st = r.track_state
      if st == 'rain' or (st == 'wet' and r.rain == 1) then return r.source == 'forecast' and 'Rain likely' or 'Raining' end
      if st == 'wet' then return 'Wet' elseif st == 'damp' then return 'Damp' elseif st == 'drying' then return 'Drying' end
      if r.source == 'forecast' then return r.rain == 1 and 'Rain likely' or 'Dry' end
      return r.rain == 1 and 'Raining' or 'Dry' end },
  { 'Time (local)',   function(r) return r.local_start and r.local_start:sub(12, 16) or '–' end },
  { 'Real best lap',  function(r) return (r.best_lap and r.best_lap ~= '') and (r.best_lap .. ' ' .. (r.best_driver or '')) or '–' end },
  { 'Data',           function(r) return r.source == 'forecast' and 'Forecast' or 'Timing' end },
}
-- Base layout is designed at 1440p; everything is multiplied by pitScale() so the panel keeps
-- the same proportions at 1080p (x0.75) and 4K (x1.5). settings.pitSize adds a personal tweak.
local BASE = { W = 560, ROW = 26, HEAD = 44, COLHEAD = 30, SEG = 28, FOOT = 34, M = 14, GAP = 9, LABEL = 130, RELOAD = 40 }

local function pitScale()
  local h = 1440
  pcall(function() h = ac.getUI().windowSize.y end)
  return math.max(0.5, math.min(2.5, (h / 1440) * (settings.pitSize or 1)))
end

local function pitSize(S)
  local n = 0
  for _, rr in ipairs(ROWS) do n = n + (rr and BASE.ROW or BASE.GAP) end
  local h = BASE.M + BASE.HEAD + BASE.COLHEAD + BASE.SEG + n + 8 + BASE.FOOT + BASE.M
  if not trackKnown then h = BASE.M + BASE.HEAD + 30 + BASE.M end   -- just the 'not recognised' line
  if trackKnown and grip.needsReload then h = h + BASE.RELOAD end    -- 'reload track' bar
  return vec2(math.floor(BASE.W * S), math.floor(h * S))
end
local function pitHeight() return pitSize(pitScale()).y end

-- small iOS-style switch; returns true when clicked
local function drawSwitch(id, pos, S, on)
  local w, h = 38 * S, 20 * S
  ui.setCursor(pos)
  local clicked = ui.invisibleButton(id, vec2(w, h))
  local hov = ui.itemHovered()
  ui.drawRectFilled(pos, vec2(pos.x + w, pos.y + h), on and V.red or rgbm(1, 1, 1, hov and 0.28 or 0.18), h / 2)
  local r = h / 2 - 3 * S
  local cx = on and (pos.x + w - h / 2) or (pos.x + h / 2)
  ui.drawCircleFilled(vec2(cx, pos.y + h / 2), r, V.text, 20)
  return clicked
end

local function setEnabled(on)
  if on and not trackKnown then return end
  settings.autoApply = on
  if on then
    autoApply(false)
    if not autoState.active then local r = currentRow(); if r then applyManual(r) end end
  else
    finishPush()
    sync.phase, sync.msg = 'off', 'F1 True Conditions is off — Pure Planner keeps its current plan'
  end
end

local function drawPit(size, isOverlay)
  local S = pitScale()
  local M, ROW, HEAD, COLHEAD, FOOT, GAP = BASE.M * S, BASE.ROW * S, BASE.HEAD * S, BASE.COLHEAD * S, BASE.FOOT * S, BASE.GAP * S
  local fs = function(v) return math.floor(v * S + 0.5) end
  if isOverlay then ui.drawRectFilled(vec2(0, 0), size, V.bg, 12 * S) end
  pushF(F.regular)

  -- header: title + on/off switch
  local c = trackKnown and sel.circuit or nil
  local r = c and currentRow() or nil
  local on = settings.autoApply and trackKnown
  local title = c and (c.display .. (r and ('  ·  ' .. (r.meeting or '') .. ' ' .. r.year) or '')) or 'F1 True Conditions'
  local swW, swH = 38 * S, 20 * S
  if isOverlay then
    ui.setCursor(vec2(0, 0))
    ui.invisibleButton('##f1tcdrag', vec2(size.x - swW - M * 2, M + HEAD - 6 * S))
    if ui.itemActive() then
      local d = ui.mouseDelta()
      settings.pitX, settings.pitY = settings.pitX + d.x, settings.pitY + d.y
    end
  end
  local titleX = M
  local flag = r and flagPath(r.circuit, r.country)
  if flag then
    local fh = 32 * S                       -- square image, the flag itself is ~2/3 of its height
    local fy = M + (28 * S - fh) / 2
    ui.drawImage(flag, vec2(M - 2 * S, fy), vec2(M - 2 * S + fh, fy + fh), on and rgbm(1, 1, 1, 1) or rgbm(1, 1, 1, 0.6))
    titleX = M + fh + 6 * S
  end
  txt(title, fs(18), vec2(titleX, M), vec2(size.x - swW - M * 2, M + 28 * S), ui.Alignment.Start, on and V.text or V.dim)
  if drawSwitch('##f1tcOnOff', vec2(size.x - M - swW, M + (28 * S - swH) / 2), S, on) and trackKnown then setEnabled(not on) end
  if ui.itemHovered() then ui.setTooltip(not trackKnown and 'Track not recognised — F1 True Conditions is off for this session' or on and 'F1 True Conditions on — click to turn off' or 'F1 True Conditions off — click to turn on') end

  if not c then
    txt(not trackKnown and 'Track not recognised — off for this session' or (autoState.reason ~= '' and autoState.reason or 'No F1 circuit for this track'), fs(14),
      vec2(M, M + HEAD), vec2(size.x - M, M + HEAD + 30 * S), ui.Alignment.Start, V.dim)
    popF(F.regular); return
  end

  local list = c.byYear[sel.year] or {}
  local labelW = BASE.LABEL * S
  local colW = (size.x - M * 2 - labelW) / math.max(#list, 1)
  local top = M + HEAD
  local SEGH = BASE.SEG * S
  local bottomOfTable = top + COLHEAD + SEGH
  for _, rr in ipairs(ROWS) do bottomOfTable = bottomOfTable + (rr and ROW or GAP) end

  -- clickable column headers; the chosen session gets a red box
  for i, s in ipairs(list) do
    local x0 = M + labelW + (i - 1) * colW
    local chosen = on and i == sel.idx
    ui.setCursor(vec2(x0, top))
    if ui.invisibleButton('##col' .. i, vec2(colW, COLHEAD)) then
      sel.idx = i
      if on then applyManual(s) end
    end
    local hovered = ui.itemHovered()
    if chosen then
      ui.drawRectFilled(vec2(x0 + 3 * S, top), vec2(x0 + colW - 3 * S, bottomOfTable), V.redFill, 6 * S)
      ui.drawRect(vec2(x0 + 3 * S, top), vec2(x0 + colW - 3 * S, bottomOfTable), V.red, 6 * S, nil, 2 * S)
    elseif hovered then
      ui.drawRect(vec2(x0 + 3 * S, top), vec2(x0 + colW - 3 * S, bottomOfTable), V.line, 6 * S, nil, 1 * S)
    end
    pushF(F.bold)
    txt(SHORT[s.session] or s.session, fs(14), vec2(x0, top), vec2(x0 + colW, top + COLHEAD), ui.Alignment.Center,
      (chosen or hovered) and V.text or V.dim)
    popF(F.bold)
  end
  -- Q1 / Q2 / Q3 selector under each qualifying column that has segment data
  local segY = top + COLHEAD + 3 * S
  txt('Segment', fs(13), vec2(M + 4 * S, segY), vec2(M + labelW, segY + SEGH - 6 * S), ui.Alignment.Start, V.faint)
  for i, s in ipairs(list) do
    local x0 = M + labelW + (i - 1) * colW
    if s.segs then
      -- always Q1 / Q2 / Q3; a segment without data is greyed out and can't be picked
      local n = 3
      local byNum = {}
      for _, g in ipairs(s.segs) do byNum[g.segment] = g end
      local curNum = s.segs[segIdx(s)].segment
      local pad, gap = 8 * S, 3 * S
      local pw = (colW - pad * 2 - gap * (n - 1)) / n
      for k = 1, n do
        local p1 = vec2(x0 + pad + (k - 1) * (pw + gap), segY)
        local p2 = vec2(p1.x + pw, segY + SEGH - 6 * S)
        local g = byNum[k]
        ui.setCursor(p1)
        if ui.invisibleButton('##seg' .. i .. '_' .. k, vec2(pw, p2.y - p1.y)) and g then
          settings.qSeg = k
          sel.idx = i
          if on then applyManual(s) end
        end
        local hov = ui.itemHovered()
        local active = g and on and i == sel.idx and k == curNum
        if active then ui.drawRectFilled(p1, p2, V.red, 4 * S)
        elseif g then ui.drawRect(p1, p2, hov and V.dim or V.line, 4 * S, nil, 1)
        else ui.drawRect(p1, p2, rgbm(1, 1, 1, 0.05), 4 * S, nil, 1) end
        local lbl = 'Q' .. k
        txt(lbl, fs(12), p1, p2, ui.Alignment.Center, not g and V.faint or ((active or hov) and V.text or (k == curNum and V.text or V.dim)))
        if hov and g and g.copiedFrom then
          local tp = TYRE_PCT[k] or 100
          ui.setTooltip(string.format('No %s data in the official timing feed: conditions copied from %s%s', g.label, g.copiedFrom,
            tp < 100 and string.format(',\ngrip slightly lowered (tyres at %g %%)', tp) or ''))
        elseif hov and not g then
          ui.setTooltip(string.format('No %s data for this session (not in the official timing feed)', (s.session == 'Qualifying' and 'Q' or 'SQ') .. k))
        elseif hov then
          ui.setTooltip(string.format('%s final laps %s  ·  air %s °C, track %s °C  ·  %s%s', g.label or '', (g.local_start or ''):sub(12, 16),
            fmt(g.air_c, '%.1f'), fmt(g.track_c, '%.1f'), stateText(g),
            (g.best_lap and g.best_lap ~= '') and ('\nReal best lap: ' .. g.best_lap .. ' ' .. (g.best_driver or '')) or ''))
        end
      end
    end
  end
  ui.drawLine(vec2(M, top + COLHEAD + SEGH), vec2(size.x - M, top + COLHEAD + SEGH), V.line, 1)

  -- rows
  local y = top + COLHEAD + SEGH
  for _, rr in ipairs(ROWS) do
    if not rr then
      ui.drawLine(vec2(M, y + GAP / 2), vec2(size.x - M, y + GAP / 2), V.line, 1)
      y = y + GAP
    else
      txt(rr[1], fs(14), vec2(M + 4 * S, y), vec2(M + labelW, y + ROW), ui.Alignment.Start, V.dim)
      for i, s in ipairs(list) do
        local x0 = M + labelW + (i - 1) * colW
        local e = effRow(s)
        local wetSurface = e.rain == 1 or e.track_state == 'wet' or e.track_state == 'damp' or e.track_state == 'drying'
        local col = (rr[1] == 'Track' and wetSurface) and V.wet or ((on and i == sel.idx) and V.text or V.dim)
        if rr[1] == 'Track grip' and on and i == sel.idx and grip.needsReload then col = V.warn end
        txt(rr[2](e), fs(14), vec2(x0, y), vec2(x0 + colW, y + ROW), ui.Alignment.Center, col)
      end
      y = y + ROW
    end
  end

  -- track grip waiting for a reload: red note + Reload track button (same as the VRC zone editor)
  if grip.needsReload then
    y = y + 8 * S
    ui.drawLine(vec2(M, y), vec2(size.x - M, y), V.line, 1)
    local RH = BASE.RELOAD * S
    local bw, bh = 128 * S, 26 * S
    local b1 = vec2(size.x - M - bw, y + (RH - bh) / 2)
    local b2 = vec2(b1.x + bw, b1.y + bh)
    txt(reloadNote(), fs(13), vec2(M + 4 * S, y),
      vec2(b1.x - 8 * S, y + RH), ui.Alignment.Start, V.warn)
    ui.setCursor(b1)
    if ui.invisibleButton('##f1tcReload', vec2(bw, bh)) then reloadTrack() end
    local hov = ui.itemHovered()
    local armed = grip.confirmUntil and os.clock() < grip.confirmUntil
    ui.drawRectFilled(b1, b2, armed and V.red or rgbm(0.92, 0.08, 0.12, hov and 0.85 or 0.65), 4 * S)
    txt(armed and 'Click to confirm' or 'Reload track', fs(13), b1, b2, ui.Alignment.Center, V.text)
    if hov then ui.setTooltip('Restarts Assetto Corsa on this track so the new grip is loaded' ..
      ((sync.row and QUALI[sync.row.session]) and ' (track set to Optimum for qualifying)' or '')) end
    y = y + RH - 8 * S
  end

  -- footer: Pure Planner status (green when Pure confirms it)
  y = y + 8 * S
  ui.drawLine(vec2(M, y), vec2(size.x - M, y), V.line, 1)
  local sc = sync.phase == 'confirmed' and V.good or sync.phase == 'failed' and V.warn or V.dim
  ui.drawCircleFilled(vec2(M + 6 * S, y + FOOT / 2), 4 * S, sc)
  if OLD_APP then sc = V.warn end
  local footMsg = sync.msg ~= '' and sync.msg or 'Not applied yet'
  txt(OLD_APP and OLD_APP_MSG or footMsg, fs(13), vec2(M + 18 * S, y),
    vec2(size.x - M, y + FOOT), ui.Alignment.Start, sc)
  popF(F.regular)
end

-- CSP setup window (manifest ID "pit"); resized live to the current scale
local lastPitSize = nil
function windowPit(dt)
  if not pitAllowed() then return end
  pit.lastWindowDraw = os.clock()
  local want = pitSize(pitScale())
  if not lastPitSize or lastPitSize.x ~= want.x or lastPitSize.y ~= want.y then
    pcall(ac.setWindowSizeConstraints, 'pit', want, want)
    lastPitSize = want
  end
  drawPit(ui.windowSize(), false)
end

---------------------------------------------------------------------------------------------------
-- Main window: full browser + settings
---------------------------------------------------------------------------------------------------
local function row(label, value)
  ui.textColored(label, C.muted)
  ui.sameLine(110)
  ui.text(value)
end

function windowMain(dt)
  ui.textColored(string.format('%d sessions · %d circuits · %s DB', #db.rows, #db.circuits, db.source), C.muted)
  ui.textColored('Car: ' .. carId .. (carMatches() and '  (auto)' or ''), C.muted)
  if detectedTrack ~= '' then ui.textColored('Track: ' .. detectedTrack, C.muted) end
  ui.separator()
  if OLD_APP then ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.35, 0.3, 1)); ui.textWrapped(OLD_APP_MSG .. ' (it would load weather too)'); ui.popStyleColor(); ui.separator() end

  ui.setNextItemWidth(ui.availableSpaceX())
  ui.combo('##circuit', sel.circuit and sel.circuit.display or 'Circuit', ui.ComboFlags.HeightLarge, function()
    for _, c in ipairs(db.circuits) do
      if ui.selectable(c.display .. '  (' .. c.name .. ')', sel.circuit == c) then selectCircuit(c) end
    end
  end)

  if sel.circuit then
    ui.setNextItemWidth(90)
    ui.combo('##year', tostring(sel.year or ''), ui.ComboFlags.None, function()
      for _, y in ipairs(sel.circuit.years) do
        if ui.selectable(tostring(y), sel.year == y) then
          local cur = currentRow()
          selectCircuit(sel.circuit, y, cur and cur.session)
        end
      end
    end)
    ui.sameLine()
    local list = sel.circuit.byYear[sel.year] or {}
    local cur = list[sel.idx]
    ui.setNextItemWidth(ui.availableSpaceX())
    ui.combo('##session', cur and cur.session or 'Session', ui.ComboFlags.None, function()
      for i, r in ipairs(list) do
        if ui.selectable(r.session, sel.idx == i) then sel.idx = i end
      end
    end)
  end

  local base = currentRow()
  if base and base.segs then
    ui.setNextItemWidth(ui.availableSpaceX())
    local cur = segIdx(base)
    ui.combo('##qseg', 'Segment: ' .. (base.segs[cur].label or ('Q' .. cur)), ui.ComboFlags.None, function()
      for k, g in ipairs(base.segs) do
        local txtLine = string.format('%s  %s  ·  %s °C / %s °C  ·  %s', g.label or ('Q' .. k), (g.local_start or ''):sub(12, 16),
          fmt(g.air_c, '%.1f'), fmt(g.track_c, '%.1f'), stateText(g))
        if ui.selectable(txtLine, k == cur) then settings.qSeg = g.segment or k end
      end
    end)
  end
  local r = effRow(base)
  ui.separator()
  if r then
    ui.textColored((r.meeting or '') .. (r.segLabel and ('  ·  ' .. r.segLabel) or ''), C.accent)
    row('Local start', (r.local_start or '') .. '  (UTC' .. (r.gmt_offset or '') .. ')')
    row('Air', fmt(r.air_c, '%.1f °C') .. '   range ' .. fmt(r.air_min, '%.1f') .. '–' .. fmt(r.air_max, '%.1f'))
    row('Track', fmt(r.track_c, '%.1f °C') .. '   range ' .. fmt(r.track_min, '%.1f') .. '–' .. fmt(r.track_max, '%.1f'))
    row('Humidity', fmt(r.humidity_pct, '%.0f %%'))
    row('Wind', fmt(r.wind_kmh, '%.1f km/h') .. ' from ' .. compass(r.wind_dir_deg))
    row('Sky', (WEATHER_NAMES[r.pure_weather] or tostring(r.pure_weather)) ..
      (r.cloud_pct and string.format('  (%d%% cloud)', r.cloud_pct) or ''))
    local m = mistPct(r)
    row('Haze / mist', (m >= 1 and string.format('%d %%', math.floor(m + 0.5)) or 'none') .. (r.overridden and '  (override)' or ''))
    row('Track grip', (r.grip_pct and string.format('%g %% (FRICTION %.2f)', r.grip_pct, r.grip_pct / 100) or 'track default') ..
      (grip.loaded and string.format('  ·  loaded %.2f', grip.loaded) or '') .. ((grip.text ~= '' and not grip.pending) and ('  ·  ' .. grip.text) or ''))
    if r.segLabel then row('Tyre grip', tyre.text) end
    if grip.needsReload then
      ui.textColored(reloadNote(), V.warn)
      local armed = grip.confirmUntil and os.clock() < grip.confirmUntil
      if ui.button(armed and 'Click again to reload the track' or 'Reload track', vec2(ui.availableSpaceX(), 28)) then reloadTrack() end
    end
    if r.best_lap and r.best_lap ~= '' then row('Real best lap', r.best_lap .. '  ' .. (r.best_driver or '')) end
    row('Track', r.segLabel and (stateText(r) .. ' (fixed for the session)') or (r.rain == 1 and 'raining at start' or 'dry at start') ..
      ((r.rain_frac or 0) > 0 and string.format(', wet %d%% of session', math.floor(r.rain_frac * 100 + 0.5)) or ''))
    row('Data', r.source == 'forecast' and 'Forecast (updates until the session, track temp estimated)' or 'Official timing weather station')
    if ui.button('Apply to Pure Planner', vec2(ui.availableSpaceX(), 32)) then applyManual(base) end
  end

  if sync.msg ~= '' then
    ui.pushStyleColor(ui.StyleColor.Text, statusColor())
    ui.textWrapped(sync.msg)
    ui.popStyleColor()
  end

  ui.separator()
  ui.textColored('Automatic', C.accent)
  if ui.checkbox('F1 True Conditions on (auto-load at session start / change)', settings.autoApply) then
    setEnabled(not settings.autoApply)
  end
  if ui.checkbox('Any car (off: only ' .. settings.carFilter .. '*)', settings.autoAnyCar) then settings.autoAnyCar = not settings.autoAnyCar end
  ui.setNextItemWidth(120)
  ui.combo('Season##auto', settings.autoYear == 0 and 'Latest' or tostring(settings.autoYear), ui.ComboFlags.None, function()
    if ui.selectable('Latest', settings.autoYear == 0) then settings.autoYear = 0 end
    for _, y in ipairs({ 2026, 2025, 2024, 2023 }) do
      if ui.selectable(tostring(y), settings.autoYear == y) then settings.autoYear = y end
    end
  end)
  if autoState.reason ~= '' then ui.textColored(autoState.reason, C.muted) end
  if ui.checkbox('Show weather panel in the pits', settings.pitPanel) then settings.pitPanel = not settings.pitPanel end
  if ui.checkbox('Show "F1 True Conditions running" watermark', settings.watermark) then settings.watermark = not settings.watermark end
  if settings.watermark then
    ui.setNextItemWidth(ui.availableSpaceX())
    local v, changed = ui.slider('##wmAlpha', (settings.watermarkAlpha or 0.45) * 100, 10, 100, 'Watermark opacity: %.0f%%')
    if changed then settings.watermarkAlpha = v / 100 end
  end
  ui.setNextItemWidth(160)
  local ps, psChanged = ui.slider('Pit panel size##pitsize', settings.pitSize * 100, 60, 160, '%.0f%%')
  if psChanged then settings.pitSize = ps / 100 end

  ui.separator()
  if ui.checkbox('Use real session date & time (Stamp)', settings.realTime) then settings.realTime = not settings.realTime end
  if ui.itemHovered() then
    ui.setTooltip('On: Stamp plan at the real local start time (sim clock jumps there).\nOff: Daycycle plan, keeps your sim time — conditions only.')
  end
  if ui.checkbox('Push manual Apply into Pure Planner', settings.autoTrigger) then settings.autoTrigger = not settings.autoTrigger end
  if ui.button('Detect track') then
    local c = detectTrack()
    if c then selectCircuit(c, nil, wantedSession(acSessionType())) end
  end
  ui.sameLine()
  if ui.button('Export all as presets') then exportAll() end

  ui.separator()
  ui.textColored('Shared database', C.accent)
  ui.textColored(dbUrl() ~= '' and dbUrl() or 'No URL (data\\db_url.txt is empty)', C.muted)
  ui.textColored(string.format('%d sessions (%s)%s', #db.rows, db.source, lastUpdate and ('  ·  updated ' .. lastUpdate) or ''), C.muted)
  if ui.checkbox('Download updates at start', settings.autoUpdate) then settings.autoUpdate = not settings.autoUpdate end
  if ui.button(refreshing and 'Downloading…' or 'Update now') and not refreshing then refreshDb(false) end
  ui.sameLine()
  if ui.button('Use bundled') then resetToBundled() end
  ui.text('Own URL (optional, overrides the shared one)')
  ui.setNextItemWidth(ui.availableSpaceX())
  local txt, changed = ui.inputText('##dburl', settings.dbUrl, ui.InputTextFlags.None)
  if changed then settings.dbUrl = txt end
end

-- watermark: small translucent line at the top centre while F1 True Conditions drives the conditions
drawWatermark = function()
  local scr = ac.getUI().windowSize
  local S = pitScale()
  local w, h = 620 * S, 26 * S
  local r = sync.row
  local what = (r.display ~= nil and r.display ~= '' and r.display or r.circuit or '') .. ' ' .. tostring(r.year or '') ..
    '  ·  ' .. (r.session or '') .. (r.segLabel and (' ' .. r.segLabel) or '')
  local a = clamp(settings.watermarkAlpha or 0.45, 0.1, 1)
  ui.transparentWindow('f1tcWatermark', vec2((scr.x - w) / 2, 10 * S), vec2(w, h), true, false, function()
    pushF(F.regular)
    ui.dwriteDrawTextClipped('TRUE CONDITIONS RUNNING  ·  ' .. what, math.floor(14 * S + 0.5), vec2(0, 0), vec2(w, h),
      ui.Alignment.Center, ui.Alignment.Center, false, rgbm(1, 1, 1, a))
    popF(F.regular)
  end)
end

-- which race-menu section is open ('info'|'setup'|'telemetry'|'time'), as reported by CSP
pcall(function() ac.onOpenMainMenu(function(section) pit.section = section end) end)

-- pit overlay fallback (registered last so it sees drawPit / pitHeight)
pcall(function()
  ui.onExclusiveHUD(function(mode)
    if mode == 'game' and settings.watermark and settings.autoApply and trackKnown and sync.row and not grip.needsReload then
      drawWatermark()
    end
    if mode == 'menu' and pit.overlay and settings.pitPanel and pitAllowed() then
      local sz = pitSize(pitScale())
      ui.transparentWindow('f1tcPitOverlay', vec2(settings.pitX, settings.pitY), sz, true, true, function()
        drawPit(sz, true)
      end)
    end
  end)
end)

-- download the shared database once per start (after everything above exists)
if settings.autoUpdate then refreshDb(true) end
