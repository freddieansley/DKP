--[[
    dkp - Pork Bucks event attendance and points tracker (Ashita v4)

    Install:  <Ashita>/addons/dkp/dkp.lua      Load:  /addon load dkp
    Window:   opens on load. /dkp shows or hides it. Everything is done from the window.

    roster.txt (in the addon folder): the NAME column of the DKP sheet, copied from A4 down,
    one name per line, in the same order as the sheet. New attendees are added to the bottom.

    Output in <Ashita>/addons/dkp/logs/ when an event ends:
      <date>_<type>_<name>_paste.txt : paste into cell E1 of a freshly inserted column E.
                                       One column for the event, plus one "BID <ITEM>" column
                                       per winning bid (negative amount on the winner's row).
      <date>_<type>_<name>.csv       : full detail per player (autosaved every minute).

    Failsafe: the running event is saved to state.lua every few seconds and after every button.
    If you disconnect, crash, or reload the addon, the window offers to resume it.

    Rules
      Dynamis / Sky : +1 on time, +1 per hour attended (partial hours round up), +1 complete run
      HNM           : +1 per window, +1 claim, +1 kill (given to everyone present at that moment)
]]--

addon.name    = 'dkp';
addon.author  = 'Porkinit';
addon.version = '2.1';
addon.desc    = 'Pork Bucks event attendance and points tracker.';
addon.link    = '';

require('common');
local chat  = require('chat');
local imgui = require('imgui');

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------
local cfg = {
    poll_sec     = 5,   -- how often the alliance list is checked
    ontime_min   = 5,   -- joined within this many minutes of Start Event = on time
    grace_min    = 5,   -- minutes past the hour that do NOT count as an extra hour (0 = strict round up)
    autosave_sec = 60,  -- how often the detail CSV is rewritten while an event is running
    state_sec    = 10,  -- how often the running event is saved to state.lua (the crash failsafe)
};

-- Event menus. "label" is what shows in the dropdown, "short" is the sheet column header
-- (the date is put in front of it automatically, e.g. 15NOV FAF). Edit freely.
local TYPES = {
    {
        id = 'dynamis', label = 'Dynamis', mode = 'timed',
        events = {
            { label = "San d'Oria",  short = 'DYNA SANDY'  },
            { label = 'Bastok',      short = 'DYNA BASTOK' },
            { label = 'Windurst',    short = 'DYNA WINDY'  },
            { label = 'Jeuno',       short = 'DYNA JEUNO'  },
            { label = 'Beaucedine',  short = 'DYNA BEAUC'  },
            { label = 'Xarcabard',   short = 'DYNA XARC'   },
            { label = 'Valkurm',     short = 'DYNA VALK'   },
            { label = 'Buburimu',    short = 'DYNA BUBU'   },
            { label = 'Qufim',       short = 'DYNA QUFIM'  },
            { label = 'Tavnazia',    short = 'DYNA TAV'    },
        },
    },
    {
        id = 'sky', label = 'Sky', mode = 'timed',
        events = {
            { label = 'Sky farming / gods', short = 'SKY'   },
            { label = 'Kirin',              short = 'KIRIN' },
        },
    },
    {
        id = 'hnm', label = 'HNM', mode = 'hnm',
        events = {
            { label = 'Fafnir / Nidhogg',            short = 'FAF'     },
            { label = 'Behemoth / King Behemoth',    short = 'BEHE'    },
            { label = 'Adamantoise / Aspidochelone', short = 'ADA'     },
            { label = 'King Arthro',                 short = 'KA'      },
            { label = 'King Vinegarroon',            short = 'KV'      },
            { label = 'Simurgh',                     short = 'SIM'     },
            { label = 'Shikigami Weapon',            short = 'SHIKI'   },
            { label = 'Tiamat',                      short = 'TIAMAT'  },
            { label = 'Jormungand',                  short = 'JORM'    },
            { label = 'Vrtra',                       short = 'VRTRA'   },
            { label = 'Cerberus',                    short = 'CERB'    },
            { label = 'Khimaira',                    short = 'KHIM'    },
            { label = 'Hydra',                       short = 'HYDRA'   },
        },
    },
};

local ev = nil;      -- the running event (nil when idle)
local dirty = false; -- true when something changed that should be saved to state.lua right away

local ui = {
    open     = { true },
    type     = 1,           -- index into TYPES
    event    = 1,           -- index into TYPES[type].events
    custom   = T{ '' },     -- optional custom event name
    complete = { false },   -- "complete run" checkbox
    samezone = { false },
    sel      = nil,         -- selected player name
    bonus    = T{ 1 },
    bid      = T{ 0 },
    item     = T{ '' },
    addname  = T{ '' },
    confirm  = nil,         -- 'end', 'cancel' or 'discard' while waiting for a second click
    saved    = nil,         -- unfinished event found in state.lua, waiting for a decision
    status   = '',          -- last action, shown at the bottom of the window
};

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------
local function msg(s)
    ui.status = s;
    dirty = true; -- every action reports through here, so every action triggers a state save
    print(chat.header(addon.name):append(chat.message(s)));
end

local function err(s)
    ui.status = 'Error: ' .. s;
    print(chat.header(addon.name):append(chat.error(s)));
end

local function trim(s)
    return (tostring(s or ''):gsub('%z.*$', ''):gsub('^%s+', ''):gsub('%s+$', ''));
end

local function fix_name(s)
    return s:sub(1, 1):upper() .. s:sub(2):lower();
end

local function fmt_time(secs)
    return string.format('%d:%02d', math.floor(secs / 3600), math.floor((secs % 3600) / 60));
end

local function get_player(name)
    local p = ev.players[name];
    if (p == nil) then
        p = {
            name = name, job = '', secs = 0, first = nil, present = false,
            ontime = false, complete = false,
            windows = 0, claim = 0, kill = 0,
            bonus = 0, spent = 0, items = { },
        };
        ev.players[name] = p;
    end
    return p;
end

local function sorted_players()
    local list = { };
    for _, p in pairs(ev.players) do list[#list + 1] = p; end
    table.sort(list, function (a, b) return a.name < b.name; end);
    return list;
end

-- Returns earned points and hour points for a player.
local function points(p)
    if (ev.mode == 'timed') then
        local hours = 0;
        if (p.secs > 0) then
            hours = math.max(1, math.ceil((p.secs - cfg.grace_min * 60) / 3600));
        end
        return (p.ontime and 1 or 0) + hours + (p.complete and 1 or 0) + p.bonus, hours;
    end
    return p.windows + p.claim + p.kill + p.bonus, 0;
end

----------------------------------------------------------------------------------------------------
-- Attendance
----------------------------------------------------------------------------------------------------

-- Returns { name = job } for everyone currently counted as present, or nil if the
-- client is zoning / party data is not ready (the poll is retried later).
local function scan()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil or party:GetMemberIsActive(0) ~= 1) then
        return nil;
    end

    local myzone = party:GetMemberZone(0);
    local seen = { };
    for i = 0, 17 do
        if (party:GetMemberIsActive(i) == 1) then
            local name = party:GetMemberName(i);
            local zone = party:GetMemberZone(i);
            if (name ~= nil and name ~= '' and (not ev.samezone or zone == myzone)) then
                local job = '';
                if (zone == myzone) then
                    local id = party:GetMemberMainJob(i);
                    if (id ~= nil and id > 0) then
                        job = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', id) or '';
                    end
                end
                seen[name] = job;
            end
        end
    end

    -- Players added by hand (outside the alliance) stay present until removed.
    for name, _ in pairs(ev.manual) do
        seen[name] = seen[name] or '';
    end
    return seen;
end

local function poll(now)
    local seen = scan();
    if (seen == nil) then
        return false;
    end

    local dt = now - ev.last_poll;
    ev.last_poll = now;

    for _, p in pairs(ev.players) do
        p.prev = p.present;
        p.present = false;
    end

    for name, job in pairs(seen) do
        local p = get_player(name);
        if (p.first == nil) then
            p.first = now;
            p.ontime = (now - ev.start) <= cfg.ontime_min * 60;
        end
        if (job ~= '') then p.job = job; end
        if (p.prev) then p.secs = p.secs + dt; end
        p.present = true;
    end
    return true;
end

----------------------------------------------------------------------------------------------------
-- Files
----------------------------------------------------------------------------------------------------
local function csv(v)
    v = tostring(v);
    if (v:find('[,"\n]')) then
        v = '"' .. v:gsub('"', '""') .. '"';
    end
    return v;
end

local function logs_dir()
    local dir = addon.path .. 'logs\\';
    if (not ashita.fs.exists(dir)) then
        ashita.fs.create_dir(dir);
    end
    return dir;
end

local function write_csv()
    local path = logs_dir() .. ev.base .. '.csv';
    local f = io.open(path, 'w');
    if (f == nil) then
        err('Could not write ' .. path);
        return false;
    end

    f:write('Date,Event,Type,Player,Job,Minutes,OnTime,HourPts,Complete,Windows,Claim,Kill,Bonus,Earned,Spent,Net,Items\n');
    for _, p in ipairs(sorted_players()) do
        local earned, hours = points(p);
        local row = {
            os.date('%Y-%m-%d', ev.start), ev.name, ev.type, p.name, p.job,
            math.floor(p.secs / 60), p.ontime and 1 or 0, hours, p.complete and 1 or 0,
            p.windows, p.claim, p.kill, p.bonus, earned, p.spent, earned - p.spent,
            table.concat(p.items, '; '),
        };
        for i = 1, #row do row[i] = csv(row[i]); end
        f:write(table.concat(row, ',') .. '\n');
    end
    f:close();
    return true;
end

-- Reads roster.txt. Returns the rows (blank lines kept so rows stay aligned with the sheet)
-- and a lookup of UPPERCASE name -> row number.
local function load_roster()
    local rows, index = { }, { };
    local f = io.open(addon.path .. 'roster.txt', 'r');
    if (f ~= nil) then
        for line in f:lines() do
            local name = (line:gsub('^\239\187\191', ''):gsub('^%s+', ''):gsub('%s+$', ''));
            rows[#rows + 1] = name;
            if (name ~= '' and index[name:upper()] == nil) then
                index[name:upper()] = #rows;
            end
        end
        f:close();
    end
    while (#rows > 0 and rows[#rows] == '') do
        rows[#rows] = nil;
    end
    return rows, index;
end

-- Writes the tab-separated block that is pasted into the sheet at E1.
-- Returns true plus the list of names that were not on the roster (now appended to it).
local function write_paste()
    local rows, index = load_roster();

    -- Anyone not on the roster goes to the bottom, alphabetically.
    local added = { };
    for _, p in ipairs(sorted_players()) do
        local key = p.name:upper();
        if (index[key] == nil) then
            rows[#rows + 1] = key;
            index[key] = #rows;
            added[#added + 1] = key;
        end
    end
    if (#added > 0) then
        local rf = io.open(addon.path .. 'roster.txt', 'w');
        if (rf == nil) then
            err('Could not update ' .. addon.path .. 'roster.txt');
            return false, added;
        end
        rf:write(table.concat(rows, '\n') .. '\n');
        rf:close();
    end

    -- Columns, left to right: newest bid first, the event itself last (the sheet keeps newest on the left).
    local cols = { };
    for i = #ev.bids, 1, -1 do
        local b = ev.bids[i];
        local col = { head = 'BID ' .. b.item:upper(), vals = { } };
        col.vals[index[b.name:upper()]] = -b.bid;
        cols[#cols + 1] = col;
    end
    local evcol = { head = os.date('%d%b', ev.start):upper() .. ' ' .. ev.short, vals = { } };
    for _, p in pairs(ev.players) do
        local earned = points(p);
        if (earned ~= 0) then
            evcol.vals[index[p.name:upper()]] = earned;
        end
    end
    cols[#cols + 1] = evcol;

    -- Row 1 = headers, rows 2-3 = blank (BANK and NAME header rows), row 4+ = one row per roster line.
    local lines = { };
    local cells = { };
    for c = 1, #cols do cells[c] = cols[c].head; end
    lines[1] = table.concat(cells, '\t');
    lines[2] = string.rep('\t', #cols - 1);
    lines[3] = lines[2];
    for r = 1, #rows do
        for c = 1, #cols do
            local v = cols[c].vals[r];
            cells[c] = (v ~= nil) and tostring(v) or '';
        end
        lines[#lines + 1] = table.concat(cells, '\t');
    end

    local path = logs_dir() .. ev.base .. '_paste.txt';
    local f = io.open(path, 'w');
    if (f == nil) then
        err('Could not write ' .. path);
        return false, added;
    end
    f:write(table.concat(lines, '\n') .. '\n');
    f:close();
    return true, added;
end

----------------------------------------------------------------------------------------------------
-- Failsafe: the running event is mirrored to state.lua so it survives a disconnect or crash
----------------------------------------------------------------------------------------------------
local STATE_FILE = addon.path .. 'state.lua';
local STATE_TEMP = addon.path .. 'state.tmp';

local function serialize(v, out)
    local t = type(v);
    if (t == 'table') then
        out[#out + 1] = '{';
        for k, val in pairs(v) do
            if (type(k) == 'number') then
                out[#out + 1] = '[' .. tostring(k) .. ']=';
            else
                out[#out + 1] = string.format('[%q]=', tostring(k));
            end
            serialize(val, out);
            out[#out + 1] = ',';
        end
        out[#out + 1] = '}';
    elseif (t == 'string') then
        out[#out + 1] = string.format('%q', v);
    elseif (t == 'number' or t == 'boolean') then
        out[#out + 1] = tostring(v);
    else
        out[#out + 1] = 'nil';
    end
end

-- Written to a temp file first, then swapped in, so a crash mid-write cannot corrupt the save.
local function save_state()
    if (ev == nil) then return; end
    ev.saved_at = os.time();
    ev.complete_checked = ui.complete[1];

    local out = { 'return ' };
    serialize(ev, out);
    local f = io.open(STATE_TEMP, 'w');
    if (f == nil) then return; end
    f:write(table.concat(out));
    f:close();
    os.remove(STATE_FILE);
    os.rename(STATE_TEMP, STATE_FILE);
end

local function clear_state()
    os.remove(STATE_FILE);
    os.remove(STATE_TEMP);
end

-- Returns the saved event, or nil if there is none (or it cannot be read).
local function load_state()
    for _, path in ipairs({ STATE_FILE, STATE_TEMP }) do
        local chunk = loadfile(path);
        if (chunk ~= nil) then
            local ok, t = pcall(chunk);
            if (ok and type(t) == 'table' and type(t.players) == 'table'
                and type(t.start) == 'number' and type(t.base) == 'string') then
                t.manual = t.manual or { };
                t.bids = t.bids or { };
                t.window_count = t.window_count or 0;
                t.last_poll = t.last_poll or t.saved_at or t.start;
                return t;
            end
        end
    end
    return nil;
end

----------------------------------------------------------------------------------------------------
-- Actions (called by the window buttons)
----------------------------------------------------------------------------------------------------
local function start_event(t, name, short)
    local now = os.time();
    ev = {
        type = t.id, mode = t.mode, name = name, short = short,
        start = now, last_poll = now, last_try = now, last_save = now,
        players = { }, manual = { }, bids = { }, samezone = ui.samezone[1],
        window_count = 0,
        base = string.format('%s_%s_%s', os.date('%Y-%m-%d_%H%M', now), t.id,
            (name:gsub('[^%w%-]+', '_'))),
    };
    ui.complete[1] = false;
    ui.confirm = nil;
    ui.sel = nil;
    poll(now);
    local n = 0;
    for _ in pairs(ev.players) do n = n + 1; end
    msg(string.format('Started %s %s with %d present.', t.label, name, n));
    save_state();
end

-- skip_poll: used when finishing a recovered event as it was saved, without a fresh attendance check.
local function end_event(skip_poll)
    if (not skip_poll) then
        poll(os.time());
    end
    if (ev.mode == 'timed' and ui.complete[1]) then
        for _, p in pairs(ev.players) do
            if (p.present) then p.complete = true; end
        end
    end

    local ok = write_csv();
    local added = { };
    if (ok) then
        ok, added = write_paste();
    end
    if (not ok) then
        print(chat.header(addon.name):append(chat.error('Event kept open so nothing is lost. Fix the file problem and end it again.')));
        return;
    end

    local base = ev.base;
    ev = nil;
    clear_state();
    if (#added > 0) then
        print(chat.header(addon.name):append(chat.message(
            'Not on roster.txt, added to the bottom. Add these to the sheet in this order: ' .. table.concat(added, ', '))));
    end
    msg('Saved logs\\' .. base .. '_paste.txt - paste at E1 of a new column E.'
        .. ((#added > 0) and string.format(' %d new name(s) to add to the sheet (see chat).', #added) or ''));
end

local function cancel_event()
    local name = ev.name;
    ev = nil;
    clear_state();
    msg('Cancelled ' .. name .. '. Nothing was added to the sheet files.');
end

-- HNM: +1 window / claim / kill to everyone present right now.
local function award(field, word)
    poll(os.time());
    local n = 0;
    for _, p in pairs(ev.players) do
        if (p.present) then
            p[field] = p[field] + 1;
            n = n + 1;
        end
    end
    if (field == 'windows') then
        ev.window_count = ev.window_count + 1;
        msg(string.format('Window %d: +1 to %d present.', ev.window_count, n));
    else
        msg(string.format('%s: +1 to %d present.', word, n));
    end
end

local function add_manual(name)
    poll(os.time()); -- settle everyone's time before the roster changes
    ev.manual[name] = true;
    poll(os.time());
    msg(name .. ' added (stays present until removed).');
end

local function remove_manual(name)
    poll(os.time());
    ev.manual[name] = nil;
    poll(os.time());
    msg(name .. ' removed. Time and points so far are kept.');
end

-- Recovery: continue a saved event. Everyone who was present at the last save and is still
-- present now is credited for the time in between (the run kept going while you were away).
local function resume_event(saved)
    ev = saved;
    ev.last_try = 0;
    ui.saved = nil;
    ui.confirm = nil;
    ui.sel = nil;
    ui.complete[1] = ev.complete_checked == true;
    ui.samezone[1] = ev.samezone == true;
    msg('Resumed ' .. ev.name .. '.');
end

-- Recovery: the run is already over. Save the event exactly as it stood at the last save.
local function finish_saved(saved)
    ev = saved;
    ui.saved = nil;
    ui.confirm = nil;
    ui.sel = nil;
    ui.complete[1] = ev.complete_checked == true;
    ui.samezone[1] = ev.samezone == true;
    end_event(true);
end

local function give_bonus(name, amount)
    if (name == nil) then
        poll(os.time());
        local n = 0;
        for _, p in pairs(ev.players) do
            if (p.present) then p.bonus = p.bonus + amount; n = n + 1; end
        end
        msg(string.format('%+d bonus to %d present.', amount, n));
    else
        local p = get_player(name);
        p.bonus = p.bonus + amount;
        msg(string.format('%+d bonus to %s.', amount, p.name));
    end
end

local function record_bid(name, bid, item)
    local p = get_player(name);
    p.spent = p.spent + bid;
    p.items[#p.items + 1] = string.format('%s (%d)', item, bid);
    ev.bids[#ev.bids + 1] = { name = p.name, bid = bid, item = item };
    msg(string.format('%s wins %s for %d.', p.name, item, bid));
end

----------------------------------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------------------------------
local function draw_recovery(now)
    local sv = ui.saved;
    local n = 0;
    for _ in pairs(sv.players) do n = n + 1; end

    imgui.Text('Unfinished event found');
    imgui.Text(string.format('%s, started %s, %d players tracked', sv.name, os.date('%d %b %H:%M', sv.start), n));
    imgui.Text(string.format('Last saved %s ago (h:mm)', fmt_time(now - (sv.saved_at or sv.start))));
    imgui.Spacing();

    if (ui.confirm == 'discard') then
        if (imgui.Button('Yes, discard it', { 200, 28 })) then
            ui.saved = nil;
            ui.confirm = nil;
            clear_state();
            msg('Discarded the unfinished event.');
        end
        imgui.SameLine();
        if (imgui.Button('Go back', { 200, 28 })) then ui.confirm = nil; end
        return;
    end

    if (imgui.Button('Resume (run is still going)', { 410, 30 })) then
        resume_event(sv);
        return;
    end
    imgui.TextDisabled('Members still in the alliance get credit for the time you were gone.');
    imgui.Spacing();
    if (imgui.Button('Finish it as saved (run is over)', { 410, 30 })) then
        finish_saved(sv);
        return;
    end
    imgui.TextDisabled('Writes the sheet files using attendance up to the last save.');
    imgui.Spacing();
    if (imgui.Button('Discard', { 410, 24 })) then ui.confirm = 'discard'; end
end

local function draw_setup()
    local t = TYPES[ui.type];

    imgui.Text('Event type');
    imgui.PushItemWidth(260);
    if (imgui.BeginCombo('##dkp_type', t.label)) then
        for i, v in ipairs(TYPES) do
            if (imgui.Selectable(v.label, i == ui.type)) then
                ui.type = i;
                ui.event = 1;
            end
        end
        imgui.EndCombo();
    end
    t = TYPES[ui.type];

    imgui.Text('Event');
    if (imgui.BeginCombo('##dkp_event', t.events[ui.event].label)) then
        for i, v in ipairs(t.events) do
            if (imgui.Selectable(v.label, i == ui.event)) then
                ui.event = i;
            end
        end
        imgui.EndCombo();
    end

    imgui.Text('Or type a custom name (optional)');
    imgui.InputText('##dkp_custom', ui.custom, 32);
    imgui.PopItemWidth();

    imgui.Checkbox('Only count members in my zone', ui.samezone);
    imgui.Spacing();

    if (imgui.Button('Start Event', { 260, 32 })) then
        local custom = trim(ui.custom[1]);
        if (custom ~= '') then
            start_event(t, custom, custom:upper());
        else
            local e = t.events[ui.event];
            start_event(t, e.label, e.short);
        end
    end

    imgui.Spacing();
    if (t.mode == 'timed') then
        imgui.TextDisabled('+1 on time, +1 per hour (rounded up), +1 complete run');
    else
        imgui.TextDisabled('+1 per window, +1 claim, +1 kill');
    end
end

local function draw_running(now)
    local list = sorted_players();
    local here = 0;
    for _, p in ipairs(list) do
        if (p.present) then here = here + 1; end
    end

    imgui.Text(string.format('%s   running %s   %d/%d present', ev.name, fmt_time(now - ev.start), here, #list));

    if (ev.mode == 'hnm') then
        if (imgui.Button(string.format('Window +1 (%d so far)', ev.window_count))) then award('windows', 'Window'); end
        imgui.SameLine();
        if (imgui.Button('Claim +1')) then award('claim', 'Claim'); end
        imgui.SameLine();
        if (imgui.Button('Kill +1')) then award('kill', 'Kill'); end
    else
        imgui.Checkbox('Complete run (+1 to everyone present when the event ends)', ui.complete);
    end
    if (imgui.Checkbox('Only count members in my zone', ui.samezone)) then
        ev.samezone = ui.samezone[1];
    end

    -- Roster
    imgui.Separator();
    imgui.BeginChild('##dkp_roster', { 0, 220 }, true);
    for _, p in ipairs(list) do
        local earned = points(p);
        local line = string.format('%-15s %-3s %5s  +%d', p.name, p.job, fmt_time(p.secs), earned);
        if (p.spent > 0) then line = line .. string.format('  -%d', p.spent); end
        if (ev.mode == 'timed' and p.ontime) then line = line .. '  on time'; end
        if (ev.manual[p.name]) then
            if (imgui.Button('Remove##dkp_rm_' .. p.name)) then
                remove_manual(p.name);
            end
            imgui.SameLine();
        end
        if (p.present) then
            imgui.Text(line);
        else
            imgui.TextDisabled(line .. '  (gone)');
        end
    end
    imgui.EndChild();

    -- Player actions
    if (ev == nil) then return; end
    if (ui.sel ~= nil and ev.players[ui.sel] == nil) then ui.sel = nil; end

    imgui.PushItemWidth(180);
    if (imgui.BeginCombo('Player##dkp_sel', ui.sel or '(pick a player)')) then
        for _, p in ipairs(list) do
            if (imgui.Selectable(p.name, p.name == ui.sel)) then
                ui.sel = p.name;
            end
        end
        imgui.EndCombo();
    end

    imgui.InputInt('Bonus points##dkp_bonus', ui.bonus);
    if (imgui.Button('Give bonus to player')) then
        if (ui.sel == nil) then err('Pick a player first.');
        elseif (ui.bonus[1] == 0) then err('Bonus is 0.');
        else give_bonus(ui.sel, ui.bonus[1]); end
    end
    imgui.SameLine();
    if (imgui.Button('Give bonus to all present')) then
        if (ui.bonus[1] == 0) then err('Bonus is 0.');
        else give_bonus(nil, ui.bonus[1]); end
    end

    imgui.Spacing();
    imgui.InputText('Item won##dkp_item', ui.item, 64);
    imgui.InputInt('Winning bid##dkp_bid', ui.bid);
    if (imgui.Button('Record winning bid')) then
        local item = trim(ui.item[1]);
        if (ui.sel == nil) then err('Pick the winning player first.');
        elseif (item == '') then err('Type the item name.');
        elseif (ui.bid[1] <= 0) then err('Bid must be more than 0.');
        else
            record_bid(ui.sel, ui.bid[1], item);
            ui.item[1] = '';
            ui.bid[1] = 0;
        end
    end

    imgui.Spacing();
    imgui.InputText('##dkp_addname', ui.addname, 20);
    imgui.SameLine();
    if (imgui.Button('Add player outside alliance')) then
        local name = trim(ui.addname[1]);
        if (name == '') then err('Type the player name.');
        else
            add_manual(fix_name(name));
            ui.addname[1] = '';
        end
    end
    imgui.PopItemWidth();

    -- End / cancel, each needs a second click.
    imgui.Separator();
    if (ui.confirm == nil) then
        if (imgui.Button('End Event', { 150, 28 })) then ui.confirm = 'end'; end
        imgui.SameLine();
        if (imgui.Button('Cancel Event', { 150, 28 })) then ui.confirm = 'cancel'; end
    else
        local label = (ui.confirm == 'end') and 'Yes, end and save' or 'Yes, discard event';
        if (imgui.Button(label, { 150, 28 })) then
            local what = ui.confirm;
            ui.confirm = nil;
            if (what == 'end') then end_event(); else cancel_event(); end
        end
        imgui.SameLine();
        if (imgui.Button('Go back', { 150, 28 })) then ui.confirm = nil; end
    end
end

ashita.events.register('d3d_present', 'dkp_present', function ()
    local now = os.time();

    if (ev ~= nil) then
        if (now - ev.last_try >= cfg.poll_sec) then
            ev.last_try = now;
            poll(now);
        end
        if (now - ev.last_save >= cfg.autosave_sec) then
            ev.last_save = now;
            write_csv();
        end
        if (dirty or now - (ev.saved_at or 0) >= cfg.state_sec) then
            dirty = false;
            save_state();
        end
    end

    if (not ui.open[1]) then return; end

    imgui.SetNextWindowSize({ 440, 0 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('Pork Bucks##dkp', ui.open, ImGuiWindowFlags_AlwaysAutoResize)) then
        if (ev == nil and ui.saved ~= nil) then
            draw_recovery(now);
        elseif (ev == nil) then
            draw_setup();
        else
            draw_running(now);
        end
        if (ui.status ~= '') then
            imgui.Separator();
            imgui.TextDisabled(ui.status);
        end
    end
    imgui.End();
end);

----------------------------------------------------------------------------------------------------
-- /dkp shows or hides the window
----------------------------------------------------------------------------------------------------
ashita.events.register('command', 'dkp_command', function (e)
    local args = e.command:args();
    if (#args == 0) then return; end
    local root = args[1]:lower();
    if (root ~= '/dkp' and root ~= '/pb') then return; end
    e.blocked = true;
    ui.open[1] = not ui.open[1];
end);

----------------------------------------------------------------------------------------------------
-- Load / unload
----------------------------------------------------------------------------------------------------
ashita.events.register('load', 'dkp_load', function ()
    local _, index = load_roster();
    local n = 0;
    for _ in pairs(index) do n = n + 1; end
    msg(string.format('Loaded. %d names in roster.txt. /dkp shows or hides the window.', n));

    ui.saved = load_state();
    if (ui.saved ~= nil) then
        ui.open[1] = true;
        msg('Unfinished event found: ' .. ui.saved.name .. '. Choose what to do with it in the window.');
    end
end);

ashita.events.register('unload', 'dkp_unload', function ()
    if (ev ~= nil) then
        write_csv();
        save_state();
    end
end);
